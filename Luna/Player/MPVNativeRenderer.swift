//
//  MPVNativeRenderer.swift
//  Luna
//
//  GPU-first libmpv renderer for iOS. Normal playback renders through
//  libmpv's OpenGL render API; the sample-buffer path is reserved for PiP.
//

import UIKit
import Libmpv
import AVFoundation
import CoreMedia
import CoreVideo

protocol PlayerRenderer: AnyObject {
    var isPausedState: Bool { get }

    func start() throws
    func stop()
    func load(url: URL, with preset: PlayerPreset, headers: [String: String]?)
    func reloadCurrentItem()
    func applyPreset(_ preset: PlayerPreset)
    func prepareInitialSeek(to seconds: Double?)

    func play()
    func pausePlayback()
    func togglePause()
    func seek(to seconds: Double)
    func seek(by seconds: Double)
    func setSpeed(_ speed: Double)
    func getSpeed() -> Double

    func getAudioTracksDetailed() -> [(Int, String, String)]
    func getAudioTracks() -> [(Int, String)]
    func getCurrentAudioTrackId() -> Int
    func setAudioTrack(id: Int)

    func getSubtitleTracks() -> [(Int, String)]
    func getCurrentSubtitleTrackId() -> Int
    func setSubtitleTrack(id: Int)
    func disableSubtitles()
    func refreshSubtitleOverlay()
    func loadExternalSubtitles(urls: [String], enforce: Bool)
    func applySubtitleStyle(_ style: SubtitleStyle)
}

struct SubtitleStyle {
    let foregroundColor: UIColor
    let strokeColor: UIColor
    let strokeWidth: CGFloat
    let fontSize: CGFloat
    let isVisible: Bool

    static let `default` = SubtitleStyle(
        foregroundColor: .white,
        strokeColor: .black,
        strokeWidth: 1.0,
        fontSize: 38.0,
        isVisible: false
    )
}

protocol MPVNativeRendererDelegate: AnyObject {
    func renderer(_ renderer: MPVNativeRenderer, didUpdatePosition position: Double, duration: Double)
    func renderer(_ renderer: MPVNativeRenderer, didChangePause isPaused: Bool)
    func renderer(_ renderer: MPVNativeRenderer, didChangeLoading isLoading: Bool)
    func renderer(_ renderer: MPVNativeRenderer, didBecomeReadyToSeek: Bool)
    func renderer(_ renderer: MPVNativeRenderer, didFailWithError message: String)
    func rendererDidChangeTracks(_ renderer: MPVNativeRenderer)
    func renderer(_ renderer: MPVNativeRenderer, subtitleTrackDidChange trackId: Int)
}

#if os(iOS)
import GLKit
import OpenGLES
import Darwin

private typealias MPVOpenGLGetProcAddress = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?

private let lunaMPVOpenGLESHandle = dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_LAZY)

private let lunaMPVGetOpenGLProcAddress: MPVOpenGLGetProcAddress = { _, name in
    guard let name else { return nil }
    return dlsym(lunaMPVOpenGLESHandle, name)
}

private struct LunaMPVOpenGLInitParams {
    var get_proc_address: MPVOpenGLGetProcAddress?
    var get_proc_address_ctx: UnsafeMutableRawPointer?
}

private struct LunaMPVOpenGLFBO {
    var fbo: Int32
    var w: Int32
    var h: Int32
    var internal_format: Int32
}

private final class MPVOpenGLView: GLKView {
    weak var renderer: MPVNativeRenderer?

    override func draw(_ rect: CGRect) {
        renderer?.drawOpenGLFrame()
    }
}

private final class MPVPiPBridge {
    private let displayLayer: AVSampleBufferDisplayLayer
    private let renderQueue = DispatchQueue(label: "mpv.pip.sample-buffer.render", qos: .userInitiated)
    private let renderQueueKey = DispatchSpecificKey<Void>()
    private var pixelBufferPool: CVPixelBufferPool?
    private var pixelBufferPoolAuxAttributes: CFDictionary?
    private var formatDescription: CMVideoFormatDescription?
    private var poolWidth = 0
    private var poolHeight = 0
    private var didFlushForFormatChange = false
    private var dimensionsArray = [Int32](repeating: 0, count: 2)
    private var renderParams = [mpv_render_param](repeating: mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil), count: 5)
    private let bgraFormatCString: [CChar] = Array("bgra\0".utf8CString)
    private let maxBufferedFrames = 4

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        renderQueue.setSpecific(key: renderQueueKey, value: ())
    }

    func reset(removingDisplayedImage: Bool) {
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.pixelBufferPool = nil
            self.pixelBufferPoolAuxAttributes = nil
            self.formatDescription = nil
            self.poolWidth = 0
            self.poolHeight = 0
            self.didFlushForFormatChange = false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if #available(iOS 18.0, *) {
                    self.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: removingDisplayedImage, completionHandler: nil)
                } else if removingDisplayedImage {
                    self.displayLayer.flushAndRemoveImage()
                } else {
                    self.displayLayer.flush()
                }
            }
        }
    }

    func render(context: OpaquePointer, videoSize: CGSize) {
        renderQueue.async { [weak self] in
            self?.renderOnQueue(context: context, videoSize: videoSize)
        }
    }

    private func renderOnQueue(context: OpaquePointer, videoSize: CGSize) {
        guard let targetSize = targetRenderSize(for: videoSize) else { return }
        let width = Int(targetSize.width)
        let height = Int(targetSize.height)
        guard width > 0, height > 0 else { return }

        if poolWidth != width || poolHeight != height {
            recreatePixelBufferPool(width: width, height: height)
        }

        var pixelBuffer: CVPixelBuffer?
        var status: CVReturn = kCVReturnError
        if let pool = pixelBufferPool {
            status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                kCFAllocatorDefault,
                pool,
                pixelBufferPoolAuxAttributes,
                &pixelBuffer
            )
        }

        if status != kCVReturnSuccess || pixelBuffer == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue!,
                kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!,
                kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue!,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
            ]
            status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        }

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            Logger.shared.log("[MPVPiPBridge] failed to allocate pixel buffer status=\(status)", type: "Error")
            return
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return
        }

        dimensionsArray[0] = Int32(width)
        dimensionsArray[1] = Int32(height)
        let stride = Int32(CVPixelBufferGetBytesPerRow(buffer))

        dimensionsArray.withUnsafeMutableBufferPointer { dimsPointer in
            bgraFormatCString.withUnsafeBufferPointer { formatPointer in
                withUnsafePointer(to: stride) { stridePointer in
                    renderParams[0] = mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(dimsPointer.baseAddress))
                    renderParams[1] = mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(mutating: formatPointer.baseAddress))
                    renderParams[2] = mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(mutating: stridePointer))
                    renderParams[3] = mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: baseAddress)
                    renderParams[4] = mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                    let result = renderParams.withUnsafeMutableBufferPointer { buffer -> Int32 in
                        guard let baseAddress = buffer.baseAddress else { return -1 }
                        return mpv_render_context_render(context, baseAddress)
                    }
                    if result < 0 {
                        Logger.shared.log("[MPVPiPBridge] mpv software PiP render failed \(result)", type: "Error")
                    }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        enqueue(buffer: buffer)
    }

    private func targetRenderSize(for videoSize: CGSize) -> CGSize? {
        guard videoSize.width > 0, videoSize.height > 0 else { return nil }
        let maxWidth: CGFloat = 1280
        let maxHeight: CGFloat = 720
        let scale = min(maxWidth / videoSize.width, maxHeight / videoSize.height, 1.0)
        return CGSize(width: max(1, floor(videoSize.width * scale)), height: max(1, floor(videoSize.height * scale)))
    }

    private func recreatePixelBufferPool(width: Int, height: Int) {
        pixelBufferPool = nil
        formatDescription = nil
        poolWidth = width
        poolHeight = height

        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue!,
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue!,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!
        ]
        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: maxBufferedFrames
        ]
        let auxAttrs: [CFString: Any] = [
            kCVPixelBufferPoolAllocationThresholdKey: maxBufferedFrames
        ]

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, attrs as CFDictionary, &pool)
        if status == kCVReturnSuccess {
            pixelBufferPool = pool
            pixelBufferPoolAuxAttributes = auxAttrs as CFDictionary
        } else {
            Logger.shared.log("[MPVPiPBridge] failed to create pixel buffer pool status=\(status)", type: "Error")
        }
    }

    private func enqueue(buffer: CVPixelBuffer) {
        let needsFlush = updateFormatDescriptionIfNeeded(for: buffer)
        guard let description = formatDescription else { return }

        let presentationTime = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let result = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )

        guard result == noErr, let sampleBuffer else {
            Logger.shared.log("[MPVPiPBridge] failed to create sample buffer result=\(result)", type: "Error")
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if needsFlush {
                if #available(iOS 18.0, *) {
                    self.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
                } else {
                    self.displayLayer.flushAndRemoveImage()
                }
                self.didFlushForFormatChange = true
            } else if self.didFlushForFormatChange {
                if #available(iOS 18.0, *) {
                    self.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
                } else {
                    self.displayLayer.flush()
                }
                self.didFlushForFormatChange = false
            }

            if self.displayLayer.controlTimebase == nil {
                var timebase: CMTimebase?
                if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase) == noErr, let timebase {
                    CMTimebaseSetRate(timebase, rate: 1.0)
                    CMTimebaseSetTime(timebase, time: presentationTime)
                    self.displayLayer.controlTimebase = timebase
                }
            }

            if #available(iOS 18.0, *) {
                self.displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
            } else {
                self.displayLayer.enqueue(sampleBuffer)
            }
        }
    }

    private func updateFormatDescriptionIfNeeded(for buffer: CVPixelBuffer) -> Bool {
        var needsFlush = false
        let width = Int32(CVPixelBufferGetWidth(buffer))
        let height = Int32(CVPixelBufferGetHeight(buffer))
        let pixelFormat = CVPixelBufferGetPixelFormatType(buffer)

        if let description = formatDescription {
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            let currentFormat = CMFormatDescriptionGetMediaSubType(description)
            if dimensions.width == width, dimensions.height == height, currentFormat == pixelFormat {
                return false
            }
        }

        var newDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &newDescription
        )
        if status == noErr, let newDescription {
            formatDescription = newDescription
            needsFlush = true
        } else {
            Logger.shared.log("[MPVPiPBridge] failed to create format description status=\(status)", type: "Error")
        }
        return needsFlush
    }
}

final class MPVNativeRenderer: PlayerRenderer {
    enum RendererError: Error {
        case mpvCreationFailed
        case mpvInitialization(Int32)
        case renderContextCreation(Int32)
        case glContextCreationFailed
    }

    private enum RenderMode {
        case openGL
        case pictureInPicture
    }

    private struct MPVTrackInfo {
        let id: Int
        let type: String
        let title: String
        let lang: String
        let selected: Bool
    }

    private let displayLayer: AVSampleBufferDisplayLayer
    private let glContext: EAGLContext
    private let glView: MPVOpenGLView
    private let pipBridge: MPVPiPBridge
    private let eventQueue = DispatchQueue(label: "mpv.native.events", qos: .utility)
    private let stateQueue = DispatchQueue(label: "mpv.native.state", attributes: .concurrent)
    private let eventQueueGroup = DispatchGroup()

    private var mpv: OpaquePointer?
    private var renderContext: OpaquePointer?
    private var currentMode: RenderMode = .openGL
    private var openGLAPIType = Array("opengl\0".utf8CString)
    private var softwareAPIType = Array("sw\0".utf8CString)
    private var openGLRenderParams = [mpv_render_param](repeating: mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil), count: 4)

    private var currentPreset: PlayerPreset?
    private var currentURL: URL?
    private var currentHeaders: [String: String]?
    private var pendingInitialSeek: Double?
    private var videoSize: CGSize = .zero
    private var cachedDuration: Double = 0
    private var cachedPosition: Double = 0
    private var isPaused = true
    private var isLoading = false
    private var isRunning = false
    private var isStopping = false
    private var isReadyToSeek = false
    private var isRenderScheduled = false
    private var lastForegroundRenderTime: CFTimeInterval = 0
    private var lastPiPRenderTime: CFTimeInterval = 0
    private let foregroundFrameInterval: CFTimeInterval
    private let pipFrameInterval: CFTimeInterval = 1.0 / 24.0
    private var lastAppliedSubtitleStyle: SubtitleStyle = .default

    weak var delegate: MPVNativeRendererDelegate?

    var isPausedState: Bool {
        isPaused
    }

    init(displayLayer: AVSampleBufferDisplayLayer) {
        guard let context = EAGLContext(api: .openGLES3) ?? EAGLContext(api: .openGLES2) else {
            fatalError("Unable to create EAGL context for MPV")
        }

        self.displayLayer = displayLayer
        self.glContext = context
        self.glView = MPVOpenGLView(frame: .zero, context: context)
        self.pipBridge = MPVPiPBridge(displayLayer: displayLayer)

        let screen = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }
            .first ?? UIScreen.main
        let maxFPS = max(1, min(screen.maximumFramesPerSecond, 60))
        self.foregroundFrameInterval = 1.0 / CFTimeInterval(maxFPS)

        glView.renderer = self
        glView.backgroundColor = .black
        glView.isOpaque = true
        glView.enableSetNeedsDisplay = false
        glView.drawableColorFormat = .RGBA8888
        glView.drawableDepthFormat = .format24
        glView.drawableStencilFormat = .format8
        glView.drawableMultisample = .none

        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        displayLayer.isHidden = true
        displayLayer.opacity = 0.0
    }

    deinit {
        stop()
    }

    func getRenderingView() -> UIView {
        glView
    }

    func start() throws {
        guard !isRunning else { return }
        guard let handle = mpv_create() else {
            throw RendererError.mpvCreationFailed
        }
        mpv = handle

        setOption(name: "terminal", value: "no")
        setOption(name: "msg-level", value: "status")
        setOption(name: "keep-open", value: "yes")
        setOption(name: "idle", value: "yes")
        setOption(name: "vo", value: "libmpv")
        setOption(name: "profile", value: "fast")
        setOption(name: "hwdec", value: "videotoolbox")
        setOption(name: "vd-lavc-dr", value: "yes")
        setOption(name: "demuxer-thread", value: "yes")
        setOption(name: "cache", value: "yes")
        setOption(name: "demuxer-max-bytes", value: "80M")
        setOption(name: "demuxer-readahead-secs", value: "10")
        setOption(name: "video-sync", value: "audio")
        setOption(name: "interpolation", value: "no")
        setOption(name: "sub-auto", value: "fuzzy")
        setOption(name: "subs-fallback", value: "yes")
        setOption(name: "sub-ass-override", value: "no")
        setOption(name: "sub-use-margins", value: "yes")
        applySubtitleStyle(lastAppliedSubtitleStyle)

        let initStatus = mpv_initialize(handle)
        guard initStatus >= 0 else {
            throw RendererError.mpvInitialization(initStatus)
        }

        mpv_request_log_messages(handle, "warn")
        try createOpenGLRenderContext()
        observeProperties()
        installWakeupHandler()
        ensureAudioSessionActive()
        isRunning = true
    }

    func stop() {
        if isStopping { return }
        if !isRunning, mpv == nil { return }
        isRunning = false
        isStopping = true

        destroyRenderContext()
        pipBridge.reset(removingDisplayedImage: true)

        var handleForShutdown: OpaquePointer?
        handleForShutdown = mpv
        if let handle = handleForShutdown {
            mpv_set_wakeup_callback(handle, nil, nil)
            command(handle, ["quit"])
            mpv_wakeup(handle)
        }

        eventQueueGroup.wait()

        if let handle = handleForShutdown {
            mpv_destroy(handle)
        }
        mpv = nil
        isReadyToSeek = false
        isPaused = true
        isLoading = false
        cachedDuration = 0
        cachedPosition = 0
        updateVideoSize(width: 0, height: 0)
        isStopping = false
    }

    func load(url: URL, with preset: PlayerPreset, headers: [String: String]? = nil) {
        currentPreset = preset
        currentURL = url
        currentHeaders = headers
        cachedPosition = 0
        cachedDuration = 0
        isReadyToSeek = false
        setLoading(true)

        guard let handle = mpv else { return }
        ensureAudioSessionActive()

        apply(commands: preset.commands, on: handle)
        command(handle, ["stop"])
        updateHTTPHeaders(headers)
        applySubtitleStyle(lastAppliedSubtitleStyle)

        let target = url.isFileURL ? url.path : url.absoluteString
        command(handle, ["loadfile", target, "replace"])
    }

    func reloadCurrentItem() {
        guard let url = currentURL, let preset = currentPreset else { return }
        load(url: url, with: preset, headers: currentHeaders)
    }

    func applyPreset(_ preset: PlayerPreset) {
        currentPreset = preset
        guard let handle = mpv else { return }
        apply(commands: preset.commands, on: handle)
    }

    func prepareInitialSeek(to seconds: Double?) {
        pendingInitialSeek = seconds.map { max(0, $0) }
    }

    func prepareForPictureInPictureStart() {
        guard isRunning, currentMode != .pictureInPicture else { return }
        Logger.shared.log("[MPVNativeRenderer] switching to capped sample-buffer PiP render path", type: "Player")
        destroyRenderContext()
        currentMode = .pictureInPicture
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.glView.isHidden = true
            self.displayLayer.isHidden = false
            self.displayLayer.opacity = 1.0
        }
        do {
            try createSoftwareRenderContext()
            scheduleRender()
        } catch {
            Logger.shared.log("[MPVNativeRenderer] failed to enter PiP render mode: \(error)", type: "Error")
            delegate?.renderer(self, didFailWithError: "MPV PiP render bridge failed")
        }
    }

    func finishPictureInPicture() {
        guard isRunning, currentMode != .openGL else { return }
        Logger.shared.log("[MPVNativeRenderer] restoring OpenGL render path after PiP", type: "Player")
        destroyRenderContext()
        pipBridge.reset(removingDisplayedImage: true)
        currentMode = .openGL
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.displayLayer.isHidden = true
            self.displayLayer.opacity = 0.0
            self.glView.isHidden = false
        }
        do {
            try createOpenGLRenderContext()
            scheduleRender()
        } catch {
            Logger.shared.log("[MPVNativeRenderer] failed to restore OpenGL render path: \(error)", type: "Error")
            delegate?.renderer(self, didFailWithError: "MPV foreground render restore failed")
        }
    }

    private func createOpenGLRenderContext() throws {
        guard let handle = mpv else { return }
        var status: Int32 = 0
        performOnMainSync {
            EAGLContext.setCurrent(glContext)
            var initParams = LunaMPVOpenGLInitParams(get_proc_address: lunaMPVGetOpenGLProcAddress, get_proc_address_ctx: nil)
            status = openGLAPIType.withUnsafeMutableBufferPointer { apiPointer in
                withUnsafeMutablePointer(to: &initParams) { initPointer in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(apiPointer.baseAddress)),
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(initPointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                    ]
                    return params.withUnsafeMutableBufferPointer { buffer -> Int32 in
                        guard let baseAddress = buffer.baseAddress else { return -1 }
                        return mpv_render_context_create(&renderContext, handle, baseAddress)
                    }
                }
            }
            EAGLContext.setCurrent(nil)
        }
        guard status >= 0, renderContext != nil else {
            throw RendererError.renderContextCreation(status)
        }
        installRenderUpdateCallback()
    }

    private func createSoftwareRenderContext() throws {
        guard let handle = mpv else { return }
        let status = softwareAPIType.withUnsafeMutableBufferPointer { apiPointer -> Int32 in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(apiPointer.baseAddress)),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
            ]
            return params.withUnsafeMutableBufferPointer { buffer -> Int32 in
                guard let baseAddress = buffer.baseAddress else { return -1 }
                return mpv_render_context_create(&renderContext, handle, baseAddress)
            }
        }
        guard status >= 0, renderContext != nil else {
            throw RendererError.renderContextCreation(status)
        }
        installRenderUpdateCallback()
    }

    private func destroyRenderContext() {
        guard let context = renderContext else { return }
        if currentMode == .openGL {
            performOnMainSync {
                EAGLContext.setCurrent(glContext)
                mpv_render_context_set_update_callback(context, nil, nil)
                mpv_render_context_free(context)
                EAGLContext.setCurrent(nil)
            }
        } else {
            mpv_render_context_set_update_callback(context, nil, nil)
            mpv_render_context_free(context)
        }
        renderContext = nil
        isRenderScheduled = false
    }

    private func installRenderUpdateCallback() {
        guard let context = renderContext else { return }
        mpv_render_context_set_update_callback(context, { userdata in
            guard let userdata else { return }
            let instance = Unmanaged<MPVNativeRenderer>.fromOpaque(userdata).takeUnretainedValue()
            instance.scheduleRender()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func observeProperties() {
        guard let handle = mpv else { return }
        let properties: [(String, mpv_format)] = [
            ("dwidth", MPV_FORMAT_INT64),
            ("dheight", MPV_FORMAT_INT64),
            ("duration", MPV_FORMAT_DOUBLE),
            ("time-pos", MPV_FORMAT_DOUBLE),
            ("pause", MPV_FORMAT_FLAG),
            ("sid", MPV_FORMAT_NONE),
            ("aid", MPV_FORMAT_NONE),
            ("track-list", MPV_FORMAT_NONE)
        ]

        for (name, format) in properties {
            _ = name.withCString { pointer in
                mpv_observe_property(handle, 0, pointer, format)
            }
        }
    }

    private func installWakeupHandler() {
        guard let handle = mpv else { return }
        mpv_set_wakeup_callback(handle, { userdata in
            guard let userdata else { return }
            let instance = Unmanaged<MPVNativeRenderer>.fromOpaque(userdata).takeUnretainedValue()
            instance.processEvents()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func scheduleRender() {
        guard isRunning, !isStopping else { return }
        switch currentMode {
        case .openGL:
            scheduleOpenGLRender()
        case .pictureInPicture:
            schedulePiPRender()
        }
    }

    private func scheduleOpenGLRender() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning, !self.isStopping, self.currentMode == .openGL else { return }
            let now = CACurrentMediaTime()
            let remaining = self.foregroundFrameInterval - (now - self.lastForegroundRenderTime)
            if remaining > 0 {
                guard !self.isRenderScheduled else { return }
                self.isRenderScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                    guard let self else { return }
                    self.isRenderScheduled = false
                    self.glView.display()
                }
                return
            }
            self.glView.display()
        }
    }

    private func schedulePiPRender() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning, !self.isStopping, self.currentMode == .pictureInPicture else { return }
            let now = CACurrentMediaTime()
            let remaining = self.pipFrameInterval - (now - self.lastPiPRenderTime)
            if remaining > 0 {
                guard !self.isRenderScheduled else { return }
                self.isRenderScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                    guard let self else { return }
                    self.isRenderScheduled = false
                    self.renderPiPFrame()
                }
                return
            }
            self.renderPiPFrame()
        }
    }

    fileprivate func drawOpenGLFrame() {
        guard isRunning, !isStopping, currentMode == .openGL, let context = renderContext else { return }
        guard glView.bounds.width > 0, glView.bounds.height > 0 else { return }

        lastForegroundRenderTime = CACurrentMediaTime()
        EAGLContext.setCurrent(glContext)
        glView.bindDrawable()

        let updateFlags = UInt32(mpv_render_context_update(context))
        if updateFlags & MPV_RENDER_UPDATE_FRAME.rawValue != 0 {
            var framebuffer: GLint = 0
            glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &framebuffer)
            glViewport(0, 0, GLsizei(glView.drawableWidth), GLsizei(glView.drawableHeight))

            var fbo = LunaMPVOpenGLFBO(
                fbo: Int32(framebuffer),
                w: Int32(glView.drawableWidth),
                h: Int32(glView.drawableHeight),
                internal_format: 0
            )
            var flipY: Int32 = 1

            withUnsafeMutablePointer(to: &fbo) { fboPointer in
                withUnsafeMutablePointer(to: &flipY) { flipPointer in
                    openGLRenderParams[0] = mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPointer))
                    openGLRenderParams[1] = mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPointer))
                    openGLRenderParams[2] = mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                    let result = openGLRenderParams.withUnsafeMutableBufferPointer { buffer -> Int32 in
                        guard let baseAddress = buffer.baseAddress else { return -1 }
                        return mpv_render_context_render(context, baseAddress)
                    }
                    if result < 0 {
                        Logger.shared.log("[MPVNativeRenderer] OpenGL render failed \(result)", type: "Error")
                    }
                }
            }
            mpv_render_context_report_swap(context)
        }

        if updateFlags > 0 {
            scheduleRender()
        }
    }

    private func renderPiPFrame() {
        guard isRunning, !isStopping, currentMode == .pictureInPicture, let context = renderContext else { return }
        lastPiPRenderTime = CACurrentMediaTime()
        let updateFlags = UInt32(mpv_render_context_update(context))
        if updateFlags & MPV_RENDER_UPDATE_FRAME.rawValue != 0 {
            pipBridge.render(context: context, videoSize: currentVideoSize())
        }
        if updateFlags > 0 {
            scheduleRender()
        }
    }

    private func handleEvent(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_VIDEO_RECONFIG:
            refreshVideoState()
        case MPV_EVENT_FILE_LOADED:
            handleFileLoaded()
        case MPV_EVENT_PROPERTY_CHANGE:
            if let property = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee.name {
                refreshProperty(named: String(cString: property))
            }
        case MPV_EVENT_SHUTDOWN:
            Logger.shared.log("[MPVNativeRenderer] mpv shutdown", type: "Player")
        case MPV_EVENT_LOG_MESSAGE:
            if let logPointer = event.data?.assumingMemoryBound(to: mpv_event_log_message.self) {
                let component = String(cString: logPointer.pointee.prefix)
                let text = String(cString: logPointer.pointee.text)
                let lower = text.lowercased()
                if lower.contains("error") {
                    Logger.shared.log("mpv[\(component)] \(text)", type: "Error")
                } else if lower.contains("warn") || lower.contains("warning") || lower.contains("deprecated") {
                    Logger.shared.log("mpv[\(component)] \(text)", type: "Warn")
                }
            }
        default:
            break
        }
    }

    private func handleFileLoaded() {
        isReadyToSeek = true
        setLoading(false)
        if let seek = pendingInitialSeek {
            seek(to: seek)
            pendingInitialSeek = nil
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.renderer(self, didBecomeReadyToSeek: true)
            self.delegate?.rendererDidChangeTracks(self)
        }
    }

    private func processEvents() {
        eventQueueGroup.enter()
        let group = eventQueueGroup
        eventQueue.async { [weak self] in
            defer { group.leave() }
            guard let self else { return }
            while !self.isStopping {
                guard let handle = self.mpv else { return }
                guard let eventPointer = mpv_wait_event(handle, 0) else { return }
                let event = eventPointer.pointee
                if event.event_id == MPV_EVENT_NONE { break }
                self.handleEvent(event)
                if event.event_id == MPV_EVENT_SHUTDOWN { break }
            }
        }
    }

    private func refreshVideoState() {
        guard let handle = mpv else { return }
        var width: Int64 = 0
        var height: Int64 = 0
        getProperty(handle: handle, name: "dwidth", format: MPV_FORMAT_INT64, value: &width)
        getProperty(handle: handle, name: "dheight", format: MPV_FORMAT_INT64, value: &height)
        updateVideoSize(width: Int(width), height: Int(height))
    }

    private func refreshProperty(named name: String) {
        guard let handle = mpv else { return }
        switch name {
        case "duration":
            var value = Double(0)
            if getProperty(handle: handle, name: name, format: MPV_FORMAT_DOUBLE, value: &value) >= 0 {
                cachedDuration = max(0, value)
                publishProgress()
            }
        case "time-pos":
            var value = Double(0)
            if getProperty(handle: handle, name: name, format: MPV_FORMAT_DOUBLE, value: &value) >= 0 {
                cachedPosition = max(0, value)
                publishProgress()
            }
        case "pause":
            var flag: Int32 = 0
            if getProperty(handle: handle, name: name, format: MPV_FORMAT_FLAG, value: &flag) >= 0 {
                let newPaused = flag != 0
                if newPaused != isPaused {
                    isPaused = newPaused
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.delegate?.renderer(self, didChangePause: newPaused)
                    }
                }
            }
        case "sid":
            let current = getCurrentSubtitleTrackId()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.renderer(self, subtitleTrackDidChange: current)
                self.delegate?.rendererDidChangeTracks(self)
            }
        case "aid", "track-list":
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.rendererDidChangeTracks(self)
            }
        default:
            break
        }
    }

    private func publishProgress() {
        let position = cachedPosition
        let duration = cachedDuration
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.renderer(self, didUpdatePosition: position, duration: duration)
        }
    }

    private func setLoading(_ loading: Bool) {
        guard isLoading != loading else { return }
        isLoading = loading
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.renderer(self, didChangeLoading: loading)
        }
    }

    private func updateVideoSize(width: Int, height: Int) {
        let size = CGSize(width: max(width, 0), height: max(height, 0))
        stateQueue.async(flags: .barrier) {
            self.videoSize = size
        }
    }

    private func currentVideoSize() -> CGSize {
        stateQueue.sync { videoSize }
    }

    private func ensureAudioSessionActive() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            Logger.shared.log("[MPVNativeRenderer] failed to activate AVAudioSession: \(error)", type: "Error")
        }
    }

    private func setOption(name: String, value: String) {
        guard let handle = mpv else { return }
        _ = value.withCString { valuePointer in
            name.withCString { namePointer in
                mpv_set_option_string(handle, namePointer, valuePointer)
            }
        }
    }

    private func setProperty(name: String, value: String) {
        guard let handle = mpv else { return }
        let status = value.withCString { valuePointer in
            name.withCString { namePointer in
                mpv_set_property_string(handle, namePointer, valuePointer)
            }
        }
        if status < 0 {
            Logger.shared.log("[MPVNativeRenderer] failed to set property \(name)=\(value) status=\(status)", type: "Warn")
        }
    }

    private func clearProperty(name: String) {
        guard let handle = mpv else { return }
        let status = name.withCString { namePointer in
            mpv_set_property(handle, namePointer, MPV_FORMAT_NONE, nil)
        }
        if status < 0 {
            Logger.shared.log("[MPVNativeRenderer] failed to clear property \(name) status=\(status)", type: "Warn")
        }
    }

    private func updateHTTPHeaders(_ headers: [String: String]?) {
        guard let headers, !headers.isEmpty else {
            clearProperty(name: "http-header-fields")
            return
        }

        let headerString = headers
            .filter { !$0.key.isEmpty && !$0.value.isEmpty }
            .map { key, value in "\(key): \(value)" }
            .joined(separator: "\r\n")

        if headerString.isEmpty {
            clearProperty(name: "http-header-fields")
        } else {
            setProperty(name: "http-header-fields", value: headerString)
        }
    }

    private func apply(commands: [[String]], on handle: OpaquePointer) {
        for command in commands where !command.isEmpty {
            self.command(handle, command)
        }
    }

    private func command(_ handle: OpaquePointer, _ args: [String]) {
        guard !args.isEmpty else { return }
        _ = withCStringArray(args) { pointer in
            mpv_command_async(handle, 0, pointer)
        }
    }

    private func getStringProperty(handle: OpaquePointer, name: String) -> String? {
        var result: String?
        name.withCString { pointer in
            if let cString = mpv_get_property_string(handle, pointer) {
                result = String(cString: cString)
                mpv_free(cString)
            }
        }
        return result
    }

    @discardableResult
    private func getProperty<T>(handle: OpaquePointer, name: String, format: mpv_format, value: inout T) -> Int32 {
        name.withCString { pointer in
            withUnsafeMutablePointer(to: &value) { mutablePointer in
                mpv_get_property(handle, pointer, format, mutablePointer)
            }
        }
    }

    @inline(__always)
    private func withCStringArray<R>(_ args: [String], body: (UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> R) -> R {
        var cStrings = [UnsafeMutablePointer<CChar>?]()
        cStrings.reserveCapacity(args.count + 1)
        for arg in args {
            cStrings.append(strdup(arg))
        }
        cStrings.append(nil)
        defer {
            for pointer in cStrings where pointer != nil {
                free(pointer)
            }
        }

        return cStrings.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) { rebound in
                body(UnsafeMutablePointer(mutating: rebound))
            }
        }
    }

    private func fetchTrackList() -> [MPVTrackInfo] {
        guard let handle = mpv else { return [] }

        var node = mpv_node()
        let status = "track-list".withCString { pointer in
            mpv_get_property(handle, pointer, MPV_FORMAT_NODE, &node)
        }
        guard status >= 0 else { return [] }
        defer { mpv_free_node_contents(&node) }

        guard node.format == MPV_FORMAT_NODE_ARRAY, let list = node.u.list else { return [] }

        var tracks: [MPVTrackInfo] = []
        tracks.reserveCapacity(Int(list.pointee.num))

        for index in 0..<Int(list.pointee.num) {
            let item = list.pointee.values[index]
            guard item.format == MPV_FORMAT_NODE_MAP, let map = item.u.list else { continue }

            var id = -1
            var type = ""
            var title = ""
            var lang = ""
            var selected = false

            for entryIndex in 0..<Int(map.pointee.num) {
                guard let keyPointer = map.pointee.keys[entryIndex] else { continue }
                let key = String(cString: keyPointer)
                let value = map.pointee.values[entryIndex]

                switch key {
                case "id":
                    if value.format == MPV_FORMAT_INT64 {
                        id = Int(value.u.int64)
                    }
                case "type":
                    if value.format == MPV_FORMAT_STRING, let cString = value.u.string {
                        type = String(cString: cString)
                    }
                case "title":
                    if value.format == MPV_FORMAT_STRING, let cString = value.u.string {
                        title = String(cString: cString)
                    }
                case "lang":
                    if value.format == MPV_FORMAT_STRING, let cString = value.u.string {
                        lang = String(cString: cString)
                    }
                case "selected":
                    if value.format == MPV_FORMAT_FLAG {
                        selected = value.u.flag != 0
                    }
                default:
                    break
                }
            }

            guard id >= 0, !type.isEmpty else { continue }
            tracks.append(MPVTrackInfo(id: id, type: type, title: displayTitle(title: title, lang: lang, fallbackId: id), lang: lang, selected: selected))
        }

        return tracks
    }

    private func displayTitle(title: String, lang: String, fallbackId: Int) -> String {
        if !title.isEmpty {
            if !lang.isEmpty {
                let lowerTitle = title.lowercased()
                let langName = languageName(for: lang)
                if !lowerTitle.contains(lang.lowercased()), !langName.isEmpty, !lowerTitle.contains(langName.lowercased()) {
                    return "\(title) (\(lang))"
                }
            }
            return title
        }

        if !lang.isEmpty {
            let langName = languageName(for: lang)
            return langName.isEmpty ? lang.uppercased() : langName
        }

        return "Track \(fallbackId)"
    }

    private func languageName(for code: String) -> String {
        switch code.lowercased() {
        case "jpn", "ja", "jp": return "Japanese"
        case "eng", "en", "us", "uk": return "English"
        case "spa", "es", "esp": return "Spanish"
        case "fre", "fra", "fr": return "French"
        case "ger", "deu", "de": return "German"
        case "ita", "it": return "Italian"
        case "por", "pt": return "Portuguese"
        case "rus", "ru": return "Russian"
        case "chi", "zho", "zh": return "Chinese"
        case "kor", "ko": return "Korean"
        default: return ""
        }
    }

    private func getTrackIdProperty(_ name: String) -> Int {
        guard let handle = mpv else { return -1 }
        if let value = getStringProperty(handle: handle, name: name) {
            let lower = value.lowercased()
            if lower == "no" || lower == "auto" {
                return -1
            }
            if let intValue = Int(value) {
                return intValue
            }
        }

        var id: Int64 = -1
        let status = getProperty(handle: handle, name: name, format: MPV_FORMAT_INT64, value: &id)
        return status >= 0 ? Int(id) : -1
    }

    // MARK: - Playback controls

    func play() {
        ensureAudioSessionActive()
        setProperty(name: "pause", value: "no")
    }

    func pausePlayback() {
        setProperty(name: "pause", value: "yes")
    }

    func togglePause() {
        isPaused ? play() : pausePlayback()
    }

    func seek(to seconds: Double) {
        guard let handle = mpv else { return }
        command(handle, ["seek", String(max(0, seconds)), "absolute", "exact"])
    }

    func seek(by seconds: Double) {
        guard let handle = mpv else { return }
        command(handle, ["seek", String(seconds), "relative", "exact"])
    }

    func setSpeed(_ speed: Double) {
        setProperty(name: "speed", value: String(min(max(speed, 0.25), 3.0)))
    }

    func getSpeed() -> Double {
        guard let handle = mpv else { return 1.0 }
        var speed = Double(1.0)
        getProperty(handle: handle, name: "speed", format: MPV_FORMAT_DOUBLE, value: &speed)
        return speed
    }

    // MARK: - Tracks

    func getAudioTracksDetailed() -> [(Int, String, String)] {
        fetchTrackList()
            .filter { $0.type == "audio" }
            .map { ($0.id, $0.title, $0.lang) }
    }

    func getAudioTracks() -> [(Int, String)] {
        getAudioTracksDetailed().map { ($0.0, $0.1) }
    }

    func getCurrentAudioTrackId() -> Int {
        let id = getTrackIdProperty("aid")
        if id >= 0 { return id }
        return fetchTrackList().first(where: { $0.type == "audio" && $0.selected })?.id ?? -1
    }

    func setAudioTrack(id: Int) {
        setProperty(name: "aid", value: String(id))
    }

    func getSubtitleTracks() -> [(Int, String)] {
        fetchTrackList()
            .filter { $0.type == "sub" }
            .map { ($0.id, $0.title) }
    }

    func getCurrentSubtitleTrackId() -> Int {
        getTrackIdProperty("sid")
    }

    func setSubtitleTrack(id: Int) {
        setProperty(name: "sid", value: String(id))
        setProperty(name: "sub-visibility", value: "yes")
    }

    func disableSubtitles() {
        setProperty(name: "sid", value: "no")
        setProperty(name: "sub-visibility", value: "no")
    }

    func refreshSubtitleOverlay() {
        applySubtitleStyle(lastAppliedSubtitleStyle)
    }

    func loadExternalSubtitles(urls: [String], enforce: Bool = false) {
        guard let handle = mpv else { return }
        for (index, url) in urls.enumerated() {
            guard !url.isEmpty else { continue }
            let title = "Subtitle \(index + 1)"
            let flag = enforce ? "select" : "auto"
            command(handle, ["sub-add", url, flag, title])
        }
    }

    func applySubtitleStyle(_ style: SubtitleStyle) {
        lastAppliedSubtitleStyle = style
        setProperty(name: "sub-visibility", value: style.isVisible ? "yes" : "no")
        setProperty(name: "sub-font-size", value: String(Int(max(10, min(style.fontSize, 72)))))
        setProperty(name: "sub-color", value: mpvColor(style.foregroundColor))
        setProperty(name: "sub-border-color", value: mpvColor(style.strokeColor))
        setProperty(name: "sub-border-size", value: String(format: "%.2f", max(0, min(style.strokeWidth * 1.5, 5.0))))
        setProperty(name: "sub-shadow-offset", value: "0")
        setProperty(name: "sub-ass-override", value: "no")
    }

    private func mpvColor(_ color: UIColor) -> String {
        var red: CGFloat = 1
        var green: CGFloat = 1
        var blue: CGFloat = 1
        var alpha: CGFloat = 1
        let resolved = color.resolvedColor(with: UITraitCollection.current)
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "#%02X%02X%02X%02X",
            Int(max(0, min(red, 1)) * 255),
            Int(max(0, min(green, 1)) * 255),
            Int(max(0, min(blue, 1)) * 255),
            Int(max(0, min(alpha, 1)) * 255)
        )
    }
}

private func performOnMainSync(_ block: () -> Void) {
    if Thread.isMainThread {
        block()
    } else {
        DispatchQueue.main.sync(execute: block)
    }
}

#else

final class MPVNativeRenderer: PlayerRenderer {
    enum RendererError: Error {
        case unavailable
    }

    weak var delegate: MPVNativeRendererDelegate?

    init(displayLayer: AVSampleBufferDisplayLayer) { }
    func getRenderingView() -> UIView { UIView() }
    func start() throws { throw RendererError.unavailable }
    func stop() { }
    func load(url: URL, with preset: PlayerPreset, headers: [String: String]?) { }
    func reloadCurrentItem() { }
    func applyPreset(_ preset: PlayerPreset) { }
    func prepareInitialSeek(to seconds: Double?) { }
    func prepareForPictureInPictureStart() { }
    func finishPictureInPicture() { }
    func play() { }
    func pausePlayback() { }
    func togglePause() { }
    func seek(to seconds: Double) { }
    func seek(by seconds: Double) { }
    func setSpeed(_ speed: Double) { }
    func getSpeed() -> Double { 1.0 }
    func getAudioTracksDetailed() -> [(Int, String, String)] { [] }
    func getAudioTracks() -> [(Int, String)] { [] }
    func getCurrentAudioTrackId() -> Int { -1 }
    func setAudioTrack(id: Int) { }
    func getSubtitleTracks() -> [(Int, String)] { [] }
    func getCurrentSubtitleTrackId() -> Int { -1 }
    func setSubtitleTrack(id: Int) { }
    func disableSubtitles() { }
    func refreshSubtitleOverlay() { }
    func loadExternalSubtitles(urls: [String], enforce: Bool = false) { }
    func applySubtitleStyle(_ style: SubtitleStyle) { }
    var isPausedState: Bool { true }
}

#endif
