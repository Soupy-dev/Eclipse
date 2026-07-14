// GPU-first libmpv renderers for iOS. Inline playback uses MoltenVK/CAMetalLayer,
// while AVSampleBufferDisplayLayer is reserved for PiP handoff.

import UIKit
import Libmpv
import AVFoundation
import CoreMedia
import CoreVideo
import Metal
#if ECLIPSE_MPVKIT_MOLTENVK_INLINE_RENDERER && ECLIPSE_MPVKIT_SAMPLE_BUFFER_PIP_BRIDGE
import MPVKitSampleBufferGPL
#endif

/// True when the user has opted to override embedded ASS subtitle styling on a MoltenVK (sample-buffer / gpu-next)
/// renderer.
private func subtitlePerformanceModeActive(isMetalRenderer: Bool) -> Bool {
    guard isMetalRenderer, ExperimentalFeatureState.canUseExperimentalMPVPlayback else { return false }
    return UserDefaults.standard.bool(forKey: ExperimentalFeatureState.mpvIgnoreSpecialSubtitleStylesKey)
}

private func experimentalSubtitleASSOverrideValue(isMetalRenderer: Bool) -> String {
    guard isMetalRenderer,
          ExperimentalFeatureState.canUseExperimentalMPVPlayback else {
        return "yes"
    }
    // `force` (rather than `yes`) makes libass drop the embedded script's own styles/effects in favour of the app's
    // flat subtitle style.
    return subtitlePerformanceModeActive(isMetalRenderer: isMetalRenderer) ? "force" : "no"
}

/// Raise (or restore) the shared AVAudioSession's preferred output channel count so multichannel (5.1/7.1) PCM can
/// reach routes.
private func eclipseApplyPreferredOutputChannels(log: (String) -> Void) {
    let session = AVAudioSession.sharedInstance()
    guard session.category == .playback else { return }
    let maxChannels = session.maximumOutputNumberOfChannels
    let desired = Settings.shared.mpvSurroundSoundEnabled ? maxChannels : min(2, maxChannels)
    guard desired >= 1, desired != session.preferredOutputNumberOfChannels else { return }
    do {
        try session.setPreferredOutputNumberOfChannels(desired)
        let route = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
        log("audio: preferred output channels=\(desired) (max=\(maxChannels) surround=\(Settings.shared.mpvSurroundSoundEnabled) route=\(route.isEmpty ? "none" : route))")
    } catch {
        log("audio: failed to set preferred output channels desired=\(desired) max=\(maxChannels): \(error)")
    }
}

/// Installs a single process-wide observer that re-applies the preferred multichannel output count
/// whenever the audio route changes (e.g. plugging into an HDMI/USB receiver mid-playback). iOS can
/// reset the preference across route changes, so re-applying keeps surround engaged.
private final class EclipseAudioRouteWatcher {
    static let shared = EclipseAudioRouteWatcher()
    private var token: NSObjectProtocol?

    func ensureInstalled() {
        guard token == nil else { return }
        token = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { _ in
            eclipseApplyPreferredOutputChannels(log: { Logger.shared.log("[MPVAudio] \($0)", type: "MPV") })
        }
    }
}

enum PlayerRendererPictureInPictureError: Error {
    case preparationTimedOut
}

@MainActor
protocol PlayerRenderer: AnyObject {
    var isPausedState: Bool { get }
    var supportsBitmapSubtitleTracks: Bool { get }
    var prefersPictureInPictureLayerActivationBeforeStart: Bool { get }

    func getRenderingView() -> UIView
    func renderingLayoutDidChange(containerSize: CGSize)
    func start() throws
    func stop()
    func waitUntilStopped() async
    func load(url: URL, with preset: PlayerPreset, headers: [String: String]?)
    func reloadCurrentItem()
    func applyPreset(_ preset: PlayerPreset)
    func prepareInitialSeek(to seconds: Double?)
    func performanceOverlaySnapshot() -> String
    func beginForegroundUIStallRecovery(reason: String)

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
    func getSubtitleTracksDetailed() -> [(Int, String, String, Bool)]
    func getCurrentSubtitleTrackId() -> Int
    func setSubtitleTrack(id: Int)
    func disableSubtitles()
    func refreshSubtitleOverlay()
    func loadExternalSubtitles(urls: [String], names: [String]?, enforce: Bool)
    func applySubtitleStyle(_ style: SubtitleStyle)

    /// Sets the mpv audio-filter chain (the `af` property) for "comfort"/anime-like audio
    /// processing. Pass an empty string to clear all filters (passthrough). No-op on renderers
    /// that don't support runtime audio filters.
    func applyAudioFilterChain(_ chain: String)

    func canStartSampleBufferPictureInPicture() -> Bool
    func preparePictureInPicture() async throws
    func prepareForPictureInPictureStart()
    func finishPictureInPicture()
    func finishPictureInPictureAndWait(restoringInlinePlayback: Bool) async -> Bool
    func primePictureInPictureFrames(reason: String)
    func activatePictureInPictureLayer()
    func isPictureInPicturePrimed() -> Bool
    func updatePictureInPictureRenderSize(_ size: CGSize)
    func waitForPictureInPictureTimelineUpdate() async
    func setPictureInPictureStopRequestHandler(_ handler: ((String) -> Void)?)
    func resumeForegroundRendering(reason: String)
    func pictureInPictureDebugSnapshot() -> String
}

extension PlayerRenderer {
    /// Default: renderers that don't support runtime mpv audio filters (e.g. the legacy MoltenVK
    /// renderer or non-mpv backends) ignore the comfort-audio chain.
    func applyAudioFilterChain(_ chain: String) {}

    /// Legacy renderer compatibility: one immediate preparation attempt, one bounded retry, and
    /// a readiness wait. The MPVKit GPU bridge overrides this with its generation-scoped async API.
    func preparePictureInPicture() async throws {
        prepareForPictureInPictureStart()
        primePictureInPictureFrames(reason: "async-prepare")
        if isPictureInPicturePrimed() { return }

        try await Task.sleep(nanoseconds: 100_000_000)
        primePictureInPictureFrames(reason: "async-prepare-retry")
        let deadline = CACurrentMediaTime() + 0.9
        while !isPictureInPicturePrimed(), CACurrentMediaTime() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard isPictureInPicturePrimed() else {
            throw PlayerRendererPictureInPictureError.preparationTimedOut
        }
    }

    func updatePictureInPictureRenderSize(_ size: CGSize) { _ = size }

    func waitForPictureInPictureTimelineUpdate() async {
        await Task.yield()
    }

    func waitUntilStopped() async {
        await Task.yield()
    }

    /// Renderers without a generation-scoped restoration handshake must never report a proven
    /// inline restore. Keep the synchronous cleanup for source compatibility, then fail closed.
    func finishPictureInPictureAndWait(restoringInlinePlayback: Bool) async -> Bool {
        _ = restoringInlinePlayback
        finishPictureInPicture()
        return false
    }

    func setPictureInPictureStopRequestHandler(_ handler: ((String) -> Void)?) {
        _ = handler
    }
}

struct SubtitleStyle {
    let foregroundColor: UIColor
    let strokeColor: UIColor
    let strokeWidth: CGFloat
    let fontSize: CGFloat
    let verticalOffset: CGFloat
    let isVisible: Bool
    /// YouTube-style translucent box drawn behind the text for legibility.
    var closedCaptionBackground: Bool = false

    static let `default` = SubtitleStyle(
        foregroundColor: .white,
        strokeColor: .black,
        strokeWidth: 1.0,
        fontSize: 38.0,
        verticalOffset: -6.0,
        isVisible: false,
        closedCaptionBackground: false
    )
}

extension SubtitleStyle: Equatable {
    static func == (lhs: SubtitleStyle, rhs: SubtitleStyle) -> Bool {
        lhs.foregroundColor.isEqual(rhs.foregroundColor) &&
        lhs.strokeColor.isEqual(rhs.strokeColor) &&
        lhs.strokeWidth == rhs.strokeWidth &&
        lhs.fontSize == rhs.fontSize &&
        lhs.verticalOffset == rhs.verticalOffset &&
        lhs.isVisible == rhs.isVisible &&
        lhs.closedCaptionBackground == rhs.closedCaptionBackground
    }
}

private func mpvSubtitlePosition(for verticalOffset: CGFloat, maxPosition: CGFloat = 150) -> String {
    let defaultOffset: CGFloat = -6.0
    // sub-pos is a percentage where 100 == the bottom of the OSD canvas.
    let position = max(0, min(maxPosition, 100 + (verticalOffset - defaultOffset)))
    return String(format: "%.0f", position)
}

/// The software sample-buffer renderer applies `sub-font-size` verbatim and skips the viewport up-scaling the GPU
/// paths apply.
private func sampleBufferBumpedSubtitleFontSize(_ fontSize: CGFloat) -> CGFloat {
    // Mirrors the font-size ladder offered in the player UI / Settings.
    // The software sample-buffer path renders subtitles smaller than the GL/MoltenVK paths, so we
    // shift the chosen size up the ladder to compensate (bumped twice on user request).
    let ladder: [CGFloat] = [20, 24, 30, 34, 38, 42, 46]
    let bump = 4
    let nearestIndex = ladder.indices.min(by: {
        abs(ladder[$0] - fontSize) < abs(ladder[$1] - fontSize)
    }) ?? 0
    let targetIndex = nearestIndex + bump
    if targetIndex < ladder.count {
        return ladder[targetIndex]
    }
    // Past the top of the ladder, keep growing by the ~4pt top step per extra tier.
    return ladder[ladder.count - 1] + CGFloat(targetIndex - (ladder.count - 1)) * 4
}

protocol MPVNativeRendererDelegate: AnyObject {
    func renderer(_ renderer: PlayerRenderer, didUpdatePosition position: Double, duration: Double)
    func renderer(_ renderer: PlayerRenderer, didChangePause isPaused: Bool)
    func renderer(_ renderer: PlayerRenderer, didChangeLoading isLoading: Bool)
    func renderer(_ renderer: PlayerRenderer, didBecomeReadyToSeek: Bool)
    func renderer(_ renderer: PlayerRenderer, didFailWithError message: String)
    func rendererDidChangeTracks(_ renderer: PlayerRenderer)
    func renderer(_ renderer: PlayerRenderer, subtitleTrackDidChange trackId: Int)
}

#if os(iOS)
#if ECLIPSE_ENABLE_OPENGL_RENDERER
import GLKit
import OpenGLES
import Darwin

private typealias MPVOpenGLGetProcAddress = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?

private let eclipseMPVOpenGLESHandle = dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_LAZY)
private let eclipseGLBGRA = GLenum(0x80E1)
private let eclipseMPVPiPOpenGLFlipY: Int32 = 0

private let eclipseMPVGetOpenGLProcAddress: MPVOpenGLGetProcAddress = { _, name in
    guard let name else { return nil }
    return dlsym(eclipseMPVOpenGLESHandle, name)
}

private struct EclipseMPVOpenGLInitParams {
    var get_proc_address: MPVOpenGLGetProcAddress?
    var get_proc_address_ctx: UnsafeMutableRawPointer?
}

private struct EclipseMPVOpenGLFBO {
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

private final class MPVMoltenVKLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }

    @available(iOS 16.0, *)
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                DispatchQueue.main.async {
                    super.wantsExtendedDynamicRangeContent = newValue
                }
            }
        }
    }
}

private final class MPVMoltenVKView: UIView {
    override class var layerClass: AnyClass {
        MPVMoltenVKLayer.self
    }

    var metalLayer: MPVMoltenVKLayer {
        layer as! MPVMoltenVKLayer
    }

    /// Multiplier (0.1...1.0) applied on top of the native screen scale when sizing the MoltenVK drawable.
    var renderScale: CGFloat = 1.0 {
        didSet {
            guard abs(oldValue - renderScale) > 0.001 else { return }
            synchronizeDrawableSize()
        }
    }

    @discardableResult
    func synchronizeDrawableSize() -> CGSize {
        let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        let resolvedScale = scale > 0 ? scale : UIScreen.main.scale
        let effectiveScale = resolvedScale * max(0.1, min(1.0, renderScale))
        let nextDrawableSize = CGSize(
            width: max(1, bounds.width * effectiveScale),
            height: max(1, bounds.height * effectiveScale)
        )
        metalLayer.contentsScale = resolvedScale
        metalLayer.drawableSize = nextDrawableSize
        return nextDrawableSize
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        synchronizeDrawableSize()
    }
}

private final class MPVForegroundDisplayLinkTarget: NSObject {
    weak var renderer: MPVNativeRenderer?

    init(renderer: MPVNativeRenderer) {
        self.renderer = renderer
    }

    @objc func displayLinkDidFire(_ link: CADisplayLink) {
        guard let renderer else {
            link.invalidate()
            return
        }
        renderer.handleForegroundDisplayLink(link)
    }
}

private final class MPVPiPBridge {
    private let displayLayer: AVSampleBufferDisplayLayer
    private var pixelBufferPool: CVPixelBufferPool?
    private var pixelBufferPoolAuxAttributes: CFDictionary?
    private var formatDescription: CMVideoFormatDescription?
    private var textureCache: CVOpenGLESTextureCache?
    private var poolWidth = 0
    private var poolHeight = 0
    private var didFlushForFormatChange = false
    private let maxBufferedFrames = 4
    private var lastLoggedRenderSize: CGSize = .zero
    private var enqueuedFrameCount = 0
    private var renderAttemptCount = 0
    private var renderSuccessCount = 0
    private var renderFailureCount = 0
    private var renderSkipCount = 0
    private var allocationFailureCount = 0
    private var textureFailureCount = 0
    private var framebufferFailureCount = 0
    private var lastRenderResult: Int32 = 0
    private var lastRenderSourceSize: CGSize = .zero
    private var lastRenderTargetSize: CGSize = .zero
    private var lastRenderTimestamp: CFTimeInterval = 0
    private var lastEnqueueTimestamp: CFTimeInterval = 0
    private var performanceWindowStart: CFTimeInterval = CACurrentMediaTime()
    private var performanceWindowEnqueuedCount = 0
    private var lastEnqueueFramesPerSecond: Double = 0

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
    }

    func reset(removingDisplayedImage: Bool) {
        let resetOnMain = { [weak self] in
            guard let self else { return }
            self.pixelBufferPool = nil
            self.pixelBufferPoolAuxAttributes = nil
            self.formatDescription = nil
            self.poolWidth = 0
            self.poolHeight = 0
            self.didFlushForFormatChange = false
            self.lastLoggedRenderSize = .zero
            self.resetDiagnosticCounters()
            self.enqueuedFrameCount = 0
            if let textureCache = self.textureCache {
                CVOpenGLESTextureCacheFlush(textureCache, 0)
                self.textureCache = nil
            }
            self.displayLayer.controlTimebase = nil
            if #available(iOS 18.0, *) {
                self.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: removingDisplayedImage, completionHandler: nil)
            } else if removingDisplayedImage {
                self.displayLayer.flushAndRemoveImage()
            } else {
                self.displayLayer.flush()
            }
        }
        if Thread.isMainThread {
            resetOnMain()
        } else {
            DispatchQueue.main.async(execute: resetOnMain)
        }
    }

    func resetDiagnosticsForNewAttempt() {
        if Thread.isMainThread {
            resetDiagnosticCounters()
            enqueuedFrameCount = 0
        } else {
            DispatchQueue.main.sync {
                resetDiagnosticCounters()
                enqueuedFrameCount = 0
            }
        }
    }

    private func resetDiagnosticCounters() {
        renderAttemptCount = 0
        renderSuccessCount = 0
        renderFailureCount = 0
        renderSkipCount = 0
        allocationFailureCount = 0
        textureFailureCount = 0
        framebufferFailureCount = 0
        lastRenderResult = 0
        lastRenderSourceSize = .zero
        lastRenderTargetSize = .zero
        lastRenderTimestamp = 0
        lastEnqueueTimestamp = 0
        performanceWindowStart = CACurrentMediaTime()
        performanceWindowEnqueuedCount = 0
        lastEnqueueFramesPerSecond = 0
    }

    func waitForPendingRenders() {
    }

    func clearPrimedFrameState() {
        if Thread.isMainThread {
            enqueuedFrameCount = 0
        } else {
            DispatchQueue.main.sync { enqueuedFrameCount = 0 }
        }
    }

    func hasEnqueuedFrame() -> Bool {
        if Thread.isMainThread {
            return enqueuedFrameCount > 0
        }
        var result = false
        DispatchQueue.main.sync {
            result = enqueuedFrameCount > 0
        }
        return result
    }

    func renderOpenGL(
        context: OpaquePointer,
        glContext: EAGLContext,
        videoSize: CGSize,
        playbackPosition: Double,
        render: @escaping (inout EclipseMPVOpenGLFBO, inout Int32) -> Int32
    ) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.renderOpenGL(context: context, glContext: glContext, videoSize: videoSize, playbackPosition: playbackPosition, render: render)
            }
            return
        }

        guard let targetSize = targetRenderSize(for: videoSize) else {
            renderSkipCount += 1
            if renderSkipCount <= 3 || renderSkipCount % 30 == 0 {
                Logger.shared.log("[MPVPiPBridge] OpenGL render skipped invalid source size=\(String(format: "%.0fx%.0f", videoSize.width, videoSize.height)) skips=\(renderSkipCount)", type: "MPV")
            }
            return
        }
        let width = Int(targetSize.width)
        let height = Int(targetSize.height)
        guard width > 0, height > 0 else {
            renderSkipCount += 1
            if renderSkipCount <= 3 || renderSkipCount % 30 == 0 {
                Logger.shared.log("[MPVPiPBridge] OpenGL render skipped invalid target size=\(width)x\(height) skips=\(renderSkipCount)", type: "MPV")
            }
            return
        }
        renderAttemptCount += 1
        lastRenderSourceSize = videoSize
        lastRenderTargetSize = targetSize
        lastRenderTimestamp = CACurrentMediaTime()
        if lastLoggedRenderSize != targetSize {
            lastLoggedRenderSize = targetSize
            Logger.shared.log("[MPVPiPBridge] OpenGL render target size=\(width)x\(height) source=\(String(format: "%.0fx%.0f", videoSize.width, videoSize.height)) flipY=\(eclipseMPVPiPOpenGLFlipY)", type: "MPV")
        } else if renderAttemptCount <= 3 || renderAttemptCount % 60 == 0 {
            Logger.shared.log("[MPVPiPBridge] OpenGL render attempt count=\(renderAttemptCount) target=\(width)x\(height) source=\(String(format: "%.0fx%.0f", videoSize.width, videoSize.height)) flipY=\(eclipseMPVPiPOpenGLFlipY)", type: "MPV")
        }

        if poolWidth != width || poolHeight != height {
            recreatePixelBufferPool(width: width, height: height)
        }

        guard let cache = ensureTextureCache(glContext: glContext) else { return }

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
                kCVPixelBufferOpenGLESCompatibilityKey: kCFBooleanTrue!,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
            ]
            status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        }

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            allocationFailureCount += 1
            Logger.shared.log("[MPVPiPBridge] failed to allocate OpenGL pixel buffer status=\(status)", type: "MPV")
            return
        }

        var texture: CVOpenGLESTexture?
        let textureStatus = CVOpenGLESTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            buffer,
            nil,
            GLenum(GL_TEXTURE_2D),
            GLint(GL_RGBA),
            GLsizei(width),
            GLsizei(height),
            eclipseGLBGRA,
            GLenum(GL_UNSIGNED_BYTE),
            0,
            &texture
        )

        guard textureStatus == kCVReturnSuccess, let texture else {
            textureFailureCount += 1
            Logger.shared.log("[MPVPiPBridge] failed to create OpenGL texture status=\(textureStatus)", type: "MPV")
            return
        }

        EAGLContext.setCurrent(glContext)
        let textureTarget = CVOpenGLESTextureGetTarget(texture)
        let textureName = CVOpenGLESTextureGetName(texture)
        glBindTexture(textureTarget, textureName)
        glTexParameteri(textureTarget, GLenum(GL_TEXTURE_MIN_FILTER), GLint(GL_LINEAR))
        glTexParameteri(textureTarget, GLenum(GL_TEXTURE_MAG_FILTER), GLint(GL_LINEAR))
        glTexParameteri(textureTarget, GLenum(GL_TEXTURE_WRAP_S), GLint(GL_CLAMP_TO_EDGE))
        glTexParameteri(textureTarget, GLenum(GL_TEXTURE_WRAP_T), GLint(GL_CLAMP_TO_EDGE))

        var previousFramebuffer: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &previousFramebuffer)
        var previousViewport = [GLint](repeating: 0, count: 4)
        previousViewport.withUnsafeMutableBufferPointer { pointer in
            if let baseAddress = pointer.baseAddress {
                glGetIntegerv(GLenum(GL_VIEWPORT), baseAddress)
            }
        }

        var framebuffer = GLuint(0)
        glGenFramebuffers(1, &framebuffer)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), textureTarget, textureName, 0)

        let framebufferStatus = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
        guard framebufferStatus == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
            framebufferFailureCount += 1
            Logger.shared.log("[MPVPiPBridge] OpenGL framebuffer incomplete status=\(framebufferStatus)", type: "MPV")
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), GLuint(previousFramebuffer))
            glDeleteFramebuffers(1, &framebuffer)
            EAGLContext.setCurrent(nil)
            return
        }

        glViewport(0, 0, GLsizei(width), GLsizei(height))
        var fbo = EclipseMPVOpenGLFBO(
            fbo: Int32(framebuffer),
            w: Int32(width),
            h: Int32(height),
            internal_format: Int32(GL_RGBA)
        )
        var flipY = eclipseMPVPiPOpenGLFlipY
        let renderResult = render(&fbo, &flipY)
        glFlush()
        glViewport(previousViewport[0], previousViewport[1], GLsizei(previousViewport[2]), GLsizei(previousViewport[3]))
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), GLuint(previousFramebuffer))
        glDeleteFramebuffers(1, &framebuffer)
        CVOpenGLESTextureCacheFlush(cache, 0)
        EAGLContext.setCurrent(nil)

        lastRenderResult = renderResult
        guard renderResult >= 0 else {
            renderFailureCount += 1
            Logger.shared.log("[MPVPiPBridge] OpenGL PiP render failed \(renderResult)", type: "MPV")
            return
        }
        renderSuccessCount += 1
        enqueue(buffer: buffer, playbackPosition: playbackPosition)
    }

    private func targetRenderSize(for videoSize: CGSize) -> CGSize? {
        guard videoSize.width > 0, videoSize.height > 0 else { return nil }
        return CGSize(width: max(1, floor(videoSize.width)), height: max(1, floor(videoSize.height)))
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
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!,
            kCVPixelBufferOpenGLESCompatibilityKey: kCFBooleanTrue!
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
            Logger.shared.log("[MPVPiPBridge] failed to create pixel buffer pool status=\(status)", type: "MPV")
        }
    }

    private func enqueue(buffer: CVPixelBuffer, playbackPosition: Double) {
        let needsFlush = updateFormatDescriptionIfNeeded(for: buffer)
        guard let description = formatDescription else { return }

        let mediaSeconds = playbackPosition.isFinite ? max(0, playbackPosition) : 0
        let presentationTime = CMTime(seconds: mediaSeconds, preferredTimescale: 1000)
        let frameDuration = CMTime(seconds: 1.0 / 24.0, preferredTimescale: 1000)
        var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
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
            Logger.shared.log("[MPVPiPBridge] failed to create sample buffer result=\(result)", type: "MPV")
            return
        }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                attachment,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        let enqueueOnMain = { [weak self] in
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
                    CMTimebaseSetTime(timebase, time: presentationTime)
                    CMTimebaseSetRate(timebase, rate: 1.0)
                    self.displayLayer.controlTimebase = timebase
                }
            } else if let timebase = self.displayLayer.controlTimebase {
                CMTimebaseSetTime(timebase, time: presentationTime)
                CMTimebaseSetRate(timebase, rate: 1.0)
            }

            if #available(iOS 18.0, *) {
                self.displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
            } else {
                self.displayLayer.enqueue(sampleBuffer)
            }
            self.enqueuedFrameCount += 1
            self.lastEnqueueTimestamp = CACurrentMediaTime()
            let elapsed = max(0, self.lastEnqueueTimestamp - self.performanceWindowStart)
            if elapsed >= 1.0 {
                self.lastEnqueueFramesPerSecond = Double(self.enqueuedFrameCount - self.performanceWindowEnqueuedCount) / elapsed
                self.performanceWindowStart = self.lastEnqueueTimestamp
                self.performanceWindowEnqueuedCount = self.enqueuedFrameCount
            }
            if self.enqueuedFrameCount <= 5 || self.enqueuedFrameCount % 60 == 0 {
                Logger.shared.log("[MPVPiPBridge] enqueued sample frame count=\(self.enqueuedFrameCount) pts=\(String(format: "%.2f", mediaSeconds)) layerReady=\(self.displayLayer.isReadyForMoreMediaData) status=\(self.layerStatusName(self.displayLayer.status))", type: "MPV")
            }
        }
        if Thread.isMainThread {
            enqueueOnMain()
        } else {
            DispatchQueue.main.async(execute: enqueueOnMain)
        }
    }

    private func ensureTextureCache(glContext: EAGLContext) -> CVOpenGLESTextureCache? {
        if let textureCache {
            return textureCache
        }
        var cache: CVOpenGLESTextureCache?
        let status = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nil, glContext, nil, &cache)
        if status == kCVReturnSuccess, let cache {
            textureCache = cache
            return cache
        }
        textureFailureCount += 1
        Logger.shared.log("[MPVPiPBridge] failed to create OpenGL texture cache status=\(status)", type: "MPV")
        return nil
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
            Logger.shared.log("[MPVPiPBridge] failed to create format description status=\(status)", type: "MPV")
        }
        return needsFlush
    }

    func debugSnapshot() -> String {
        let collectSnapshot = {
            let nsError = self.displayLayer.error.map { $0 as NSError }
            let errorText = nsError.map { "\($0.domain)#\($0.code)" } ?? "nil"
            return "attempts=\(self.renderAttemptCount) ok=\(self.renderSuccessCount) failures=\(self.renderFailureCount) skips=\(self.renderSkipCount) allocFailures=\(self.allocationFailureCount) textureFailures=\(self.textureFailureCount) framebufferFailures=\(self.framebufferFailureCount) lastResult=\(self.lastRenderResult) source=\(String(format: "%.0fx%.0f", self.lastRenderSourceSize.width, self.lastRenderSourceSize.height)) target=\(String(format: "%.0fx%.0f", self.lastRenderTargetSize.width, self.lastRenderTargetSize.height)) lastRender=\(String(format: "%.2f", self.lastRenderTimestamp)) lastEnqueue=\(String(format: "%.2f", self.lastEnqueueTimestamp)) enqueued=\(self.enqueuedFrameCount) ready=\(self.displayLayer.isReadyForMoreMediaData) status=\(self.layerStatusName(self.displayLayer.status)) error=\(errorText) hidden=\(self.displayLayer.isHidden) opacity=\(String(format: "%.2f", self.displayLayer.opacity)) frame=\(String(format: "%.0fx%.0f", self.displayLayer.bounds.width, self.displayLayer.bounds.height)) timebase=\(self.displayLayer.controlTimebase != nil)"
        }
        if Thread.isMainThread {
            return collectSnapshot()
        }
        var snapshot = ""
        DispatchQueue.main.sync {
            snapshot = collectSnapshot()
        }
        return snapshot
    }

    func performanceSnapshot() -> String {
        let collectSnapshot = {
            let nsError = self.displayLayer.error.map { $0 as NSError }
            let errorText = nsError.map { "\($0.domain)#\($0.code)" } ?? "nil"
            let now = CACurrentMediaTime()
            let enqueueAge = self.lastEnqueueTimestamp > 0 ? now - self.lastEnqueueTimestamp : 0
            let frameHealth: String
            if self.enqueuedFrameCount == 0 {
                frameHealth = "waiting"
            } else if enqueueAge > 1.0 {
                frameHealth = "stale"
            } else if enqueueAge > 0.25 {
                frameHealth = "late"
            } else {
                frameHealth = "ok"
            }
            let missedFrames = self.renderFailureCount + self.renderSkipCount
            return "pipFPS=\(String(format: "%.1f", self.lastEnqueueFramesPerSecond)) frameAge=\(String(format: "%.2fs", enqueueAge)) health=\(frameHealth)\nenq=\(self.enqueuedFrameCount) ok=\(self.renderSuccessCount) missed=\(missedFrames) fail=\(self.renderFailureCount) skip=\(self.renderSkipCount)\ntexFail=\(self.textureFailureCount) fboFail=\(self.framebufferFailureCount) target=\(String(format: "%.0fx%.0f", self.lastRenderTargetSize.width, self.lastRenderTargetSize.height))\nlayer=\(self.layerStatusName(self.displayLayer.status)) ready=\(self.displayLayer.isReadyForMoreMediaData) err=\(errorText)"
        }
        if Thread.isMainThread {
            return collectSnapshot()
        }
        var snapshot = ""
        DispatchQueue.main.sync {
            snapshot = collectSnapshot()
        }
        return snapshot
    }

    private func layerStatusName(_ status: AVQueuedSampleBufferRenderingStatus) -> String {
        switch status {
        case .unknown: return "unknown"
        case .rendering: return "rendering"
        case .failed: return "failed"
        @unknown default: return "unknown"
        }
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
        let codec: String
        let external: Bool
        let defaultTrack: Bool
        let forced: Bool
        let selected: Bool
    }

    private let displayLayer: AVSampleBufferDisplayLayer
    private let glContext: EAGLContext
    private let glView: MPVOpenGLView
    private let pipBridge: MPVPiPBridge
    private let eventQueue = DispatchQueue(label: "mpv.native.events", qos: .utility)
    private let stateQueue = DispatchQueue(label: "mpv.native.state", attributes: .concurrent)
    private let eventQueueGroup = DispatchGroup()
    private var foregroundDisplayLink: CADisplayLink?
    private var foregroundDisplayLinkTarget: MPVForegroundDisplayLinkTarget?
    private var pipRenderTimer: DispatchSourceTimer?

    private var mpv: OpaquePointer?
    private var renderContext: OpaquePointer?
    private var currentMode: RenderMode = .openGL
    private var openGLAPIType = Array("opengl\0".utf8CString)
    private var openGLRenderParams = [mpv_render_param](repeating: mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil), count: 4)
    private var blockForTargetTime: Int32 = 0

    private var currentPreset: PlayerPreset?
    private var currentURL: URL?
    private var currentHeaders: [String: String]?
    private var pendingInitialSeek: Double?
    private var videoSize: CGSize = .zero
    private var cachedDuration: Double = 0
    private var cachedPosition: Double = 0
    private var isPaused = true
    private var isLoading = false
    private var isPausedForCache = false
    private var isRunning = false
    private var isStopping = false
    private var isReadyToSeek = false
    private var isRenderScheduled = false
    private var forcedOpenGLRenderCount = 0
    private var forcedPiPRenderCount = 0
    private var lastForegroundRenderTime: CFTimeInterval = 0
    private var lastPiPRenderTime: CFTimeInterval = 0
    private let foregroundFrameInterval: CFTimeInterval
    private let foregroundFramesPerSecond: Int
    private let pipFrameInterval: CFTimeInterval = 1.0 / 24.0
    private var lastAppliedSubtitleStyle: SubtitleStyle = .default
    private var lastSubtitleViewportSize: CGSize = .zero
    private var loadGeneration = 0
    private var isAwaitingFileLoadedForCurrentLoad = true
    private var currentLoadStartedAt: Date?
    private var lastProgressLogBucket = -1
    private var lastDurationLogValue: Double = -1
    private var lastTrackSummary = ""
    private var lastPlaybackErrorMessage: String?
    private var lastSlowOpenGLRenderLogAt: CFTimeInterval = 0
    private var hardwareDecodeFailureWindowStart: Date?
    private var hardwareDecodeFailureCount = 0
    private var runtimeHardwareDecodeFallbackApplied = false
    private var selectedVideoTrackID: Int?
    private var pipTransitionID = 0
    private var pipRenderRequestCount = 0
    // PiP diagnostics: distinguish "MPV produced a new frame" (FRAME flag set) from
    // "we re-rendered the same/stale frame" (forced). All-forced means a black/frozen
    // PiP even when enqueue succeeds. Heartbeat ticks drive a periodic health log.
    private var pipFrameUpdateRenderCount = 0
    private var pipForcedRenderCount = 0
    private var pipHeartbeatTick = 0
    private var lastRenderingLayoutSize: CGSize = .zero

    weak var delegate: MPVNativeRendererDelegate?

    var isPausedState: Bool {
        isPaused
    }

    var currentTime: Double {
        cachedPosition
    }

    var duration: Double {
        cachedDuration
    }

    var supportsBitmapSubtitleTracks: Bool {
        true
    }

    var prefersPictureInPictureLayerActivationBeforeStart: Bool {
        true
    }

    private func logMPV(_ message: String) {
        Logger.shared.log("[MPVNativeRenderer] \(message)", type: "MPV")
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
        let nativeScale = screen.nativeScale > 0 ? screen.nativeScale : screen.scale
        let configuredFPS = Settings.shared.mpvForegroundFPS
        let targetFPS = max(1, min(screen.maximumFramesPerSecond, configuredFPS))
        self.foregroundFramesPerSecond = targetFPS
        self.foregroundFrameInterval = 1.0 / CFTimeInterval(targetFPS)

        glView.renderer = self
        glView.backgroundColor = .black
        glView.isOpaque = true
        glView.enableSetNeedsDisplay = false
        glView.drawableColorFormat = .RGBA8888
        glView.drawableDepthFormat = .format24
        glView.drawableStencilFormat = .format8
        glView.drawableMultisample = .multisampleNone
        glView.contentScaleFactor = nativeScale
        glView.layer.contentsScale = nativeScale
        glView.isUserInteractionEnabled = false

        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        displayLayer.contentsScale = nativeScale
        displayLayer.isHidden = true
        displayLayer.opacity = 0.0
    }

    deinit {
        stop()
    }

    func getRenderingView() -> UIView {
        glView
    }

    func renderingLayoutDidChange(containerSize: CGSize) {
        let updateLayout = { [weak self] in
            guard let self else { return }
            let screen = self.glView.window?.screen ?? UIScreen.main
            let scale = screen.nativeScale > 0 ? screen.nativeScale : screen.scale
            self.glView.contentScaleFactor = scale
            self.glView.layer.contentsScale = scale
            self.displayLayer.contentsScale = scale
            self.displayLayer.frame = CGRect(origin: .zero, size: containerSize)

            guard containerSize.width > 0, containerSize.height > 0 else { return }
            let changed = abs(self.lastRenderingLayoutSize.width - containerSize.width) > 0.5
                || abs(self.lastRenderingLayoutSize.height - containerSize.height) > 0.5
            guard changed else { return }
            self.lastRenderingLayoutSize = containerSize
            guard self.isRunning else { return }
            self.refreshSubtitleStyleIfViewportChanged()
            if self.currentMode == .openGL {
                EAGLContext.setCurrent(self.glContext)
                self.glView.deleteDrawable()
                EAGLContext.setCurrent(nil)
                self.glView.setNeedsDisplay()
                self.glView.display()
                self.requestRenderBurst(reason: "layout-change", count: 3, interval: 0.05)
            } else {
                self.renderPiPFrame(force: true, immediate: true)
            }
            self.logMPV("layout changed container=\(String(format: "%.0fx%.0f", containerSize.width, containerSize.height)) scale=\(String(format: "%.2f", scale)) mode=\(self.currentMode)")
        }
        if Thread.isMainThread {
            updateLayout()
        } else {
            DispatchQueue.main.async(execute: updateLayout)
        }
    }

    func start() throws {
        guard !isRunning else {
            logMPV("start skipped because renderer is already running")
            return
        }
        logMPV("start requested")
        guard let handle = mpv_create() else {
            logMPV("mpv_create failed")
            throw RendererError.mpvCreationFailed
        }
        mpv = handle

        setOption(name: "terminal", value: "no")
        setOption(name: "msg-level", value: "all=warn,cplayer=v,ffmpeg=v,demux=v,stream=v")
        setOption(name: "keep-open", value: "yes")
        setOption(name: "idle", value: "yes")
        setOption(name: "vo", value: "libmpv")
        setOption(name: "hwdec", value: "videotoolbox-copy")
        setOption(name: "vd-lavc-dr", value: "no")
        setOption(name: "vd-lavc-software-fallback", value: "yes")
        // Surround: request the source channel layout so multichannel routes (USB-C/HDMI/AirPlay)
        // get 5.1/7.1 PCM; stereo routes downmix transparently. See ensureAudioSessionActive.
        setOption(name: "audio-channels", value: Settings.shared.mpvSurroundSoundEnabled ? "auto" : "stereo")
        setOption(name: "demuxer-thread", value: "yes")
        setOption(name: "cache", value: "yes")
        setOption(name: "cache-pause-wait", value: "5")
        setOption(name: "demuxer-max-bytes", value: "80M")
        setOption(name: "demuxer-readahead-secs", value: "10")
        setOption(name: "video-sync", value: "audio")
        setOption(name: "video-timing-offset", value: "0.015")
        setOption(name: "framedrop", value: "vo")
        setOption(name: "interpolation", value: "no")
        setOption(name: "sub-auto", value: "fuzzy")
        setOption(name: "subs-fallback", value: "yes")
        setOption(name: "sub-ass-override", value: experimentalSubtitleASSOverrideValue(isMetalRenderer: false))
        setOption(name: "sub-use-margins", value: "yes")
        applySubtitleStyle(lastAppliedSubtitleStyle)

        let initStatus = mpv_initialize(handle)
        guard initStatus >= 0 else {
            logMPV("mpv_initialize failed status=\(initStatus)")
            mpv_destroy(handle)
            mpv = nil
            throw RendererError.mpvInitialization(initStatus)
        }

        isRunning = true
        currentMode = .openGL
        mpv_request_log_messages(handle, "v")
        do {
            try createOpenGLRenderContext()
            observeProperties()
            installWakeupHandler()
            ensureAudioSessionActive()
            logMPV("start completed mode=openGL hwdec=videotoolbox-copy dr=no softwareFallback=yes quality=default cachePauseWait=5s nativeScale=\(String(format: "%.2f", glView.contentScaleFactor))")
            scheduleRender()
        } catch {
            logMPV("start failed after mpv_initialize: \(error)")
            isRunning = false
            destroyRenderContext()
            mpv_destroy(handle)
            mpv = nil
            throw error
        }
    }

    func stop() {
        if isStopping { return }
        if !isRunning, mpv == nil { return }
        loadGeneration += 1
        isAwaitingFileLoadedForCurrentLoad = true
        logMPV("stop requested running=\(isRunning) ready=\(isReadyToSeek) loading=\(isLoading) cached=\(String(format: "%.2f", cachedPosition))/\(String(format: "%.2f", cachedDuration))")
        isRunning = false
        isStopping = true
        stopForegroundDisplayLink(reason: "stop")
        stopPiPRenderLoop(reason: "stop")

        destroyRenderContext()
        pipBridge.reset(removingDisplayedImage: true)
        currentMode = .openGL

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
        isPausedForCache = false
        cachedDuration = 0
        cachedPosition = 0
        currentLoadStartedAt = nil
        lastProgressLogBucket = -1
        lastDurationLogValue = -1
        lastTrackSummary = ""
        lastPlaybackErrorMessage = nil
        resetHardwareDecodeFailureTracking()
        updateVideoSize(width: 0, height: 0, allowZero: true)
        isStopping = false
        logMPV("stop completed")
    }

    func load(url: URL, with preset: PlayerPreset, headers: [String: String]? = nil) {
        currentPreset = preset
        currentURL = url
        currentHeaders = headers
        cachedPosition = 0
        cachedDuration = 0
        updateVideoSize(width: 0, height: 0, allowZero: true)
        isReadyToSeek = false
        loadGeneration += 1
        isAwaitingFileLoadedForCurrentLoad = true
        currentLoadStartedAt = Date()
        lastProgressLogBucket = -1
        lastDurationLogValue = -1
        lastTrackSummary = ""
        lastPlaybackErrorMessage = nil
        isPausedForCache = false
        resetHardwareDecodeFailureTracking()
        let generation = loadGeneration
        logMPV("load start gen=\(generation) target=\(describe(url: url)) preset=\(preset.id.rawValue) headerKeys=[\((headers ?? [:]).keys.sorted().joined(separator: ","))] pendingInitialSeek=\(pendingInitialSeek.map { String(format: "%.2f", $0) } ?? "nil")")
        setLoading(true)

        guard let handle = mpv else {
            logMPV("load aborted gen=\(generation): mpv handle is nil")
            setLoading(false)
            delegate?.renderer(self, didFailWithError: "MPV was not ready to load media")
            return
        }
        ensureAudioSessionActive()

        apply(commands: preset.commands, on: handle)
        command(handle, ["stop"])
        updateHTTPHeaders(headers)
        applySubtitleStyle(lastAppliedSubtitleStyle)

        let target = url.isFileURL ? url.path : url.absoluteString
        let loadStatus = command(handle, ["loadfile", target, "replace"])
        if loadStatus < 0 {
            logMPV("loadfile command failed gen=\(generation) status=\(loadStatus)")
            setLoading(false)
            delegate?.renderer(self, didFailWithError: "MPV rejected the media load command (\(loadStatus))")
            return
        }
        mpv_wakeup(handle)
        scheduleRender()
        scheduleLoadWatchdog(generation: generation, delay: 8)
        scheduleLoadWatchdog(generation: generation, delay: 20)
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

    func canStartSampleBufferPictureInPicture() -> Bool {
        true
    }

    func pictureInPictureDebugSnapshot() -> String {
        pipDebugSnapshot()
    }

    func performanceOverlaySnapshot() -> String {
        let size = currentVideoSize()
        let pipSummary = pipBridge.performanceSnapshot()
        return "MPV \(currentMode) \(isPaused ? "paused" : "playing")\(isLoading ? " loading" : "")\npos \(String(format: "%.1f", cachedPosition))/\(String(format: "%.1f", cachedDuration))\nfg \(foregroundFramesPerSecond)fps target PiP 24fps target\nvideo \(String(format: "%.0fx%.0f", size.width, size.height))\n\(pipSummary)"
    }

    func prepareForPictureInPictureStart() {
        guard isRunning, currentMode != .pictureInPicture else { return }
        pipTransitionID += 1
        pipRenderRequestCount = 0
        pipFrameUpdateRenderCount = 0
        pipForcedRenderCount = 0
        pipHeartbeatTick = 0
        logMPV("PiP prepare begin id=\(pipTransitionID) \(pipDebugSnapshot())")
        logMPV("switching to OpenGL sample-buffer PiP render path")
        rememberSelectedVideoTrack(reason: "enter-pip")
        stopForegroundDisplayLink(reason: "enter-pip")
        isRenderScheduled = false
        pipBridge.resetDiagnosticsForNewAttempt()
        currentMode = .pictureInPicture
        logMPV("PiP prepare entered OpenGL-backed mode id=\(pipTransitionID) \(pipDebugSnapshot())")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning, !self.isStopping, self.currentMode == .pictureInPicture else { return }
            // Keep the inline GL surface visible while PiP is being primed. If
            // AVKit refuses to start PiP, the user should see a frozen frame at
            // worst, not a black player.
            self.glView.isHidden = false
            self.displayLayer.isHidden = false
            self.displayLayer.opacity = 1.0
            self.displayLayer.zPosition = -1
        }
        refreshVideoState()
        restoreSelectedVideoTrack(reason: "enter-pip")
        refreshVideoState()
        renderPiPFrame(force: true, immediate: true)
        logMPV("PiP immediate prime complete id=\(pipTransitionID) primed=\(pipBridge.hasEnqueuedFrame()) \(pipDebugSnapshot())")
        startPiPRenderLoop(reason: "enter-pip")
        requestRenderBurst(reason: "enter-pip", count: 8, interval: 0.06)
    }

    func finishPictureInPicture() {
        guard isRunning else { return }
        guard currentMode != .openGL else {
            resumeForegroundRendering(reason: "finish-pip-already-openGL")
            return
        }
        logMPV("PiP finish begin id=\(pipTransitionID) \(pipDebugSnapshot())")
        logMPV("restoring OpenGL render path after PiP")
        stopPiPRenderLoop(reason: "finish-pip")
        isRenderScheduled = false
        pipBridge.reset(removingDisplayedImage: true)
        currentMode = .openGL
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning, !self.isStopping, self.currentMode == .openGL else { return }
            self.displayLayer.isHidden = true
            self.displayLayer.opacity = 0.0
            self.displayLayer.zPosition = -1
            self.glView.isHidden = false
        }
        restoreSelectedVideoTrack(reason: "finish-pip")
        refreshVideoState()
        resumeForegroundRendering(reason: "finish-pip")
        logMPV("PiP finish restored OpenGL id=\(pipTransitionID) \(pipDebugSnapshot())")
        scheduleForegroundRestoreChecks(reason: "finish-pip")
    }

    func primePictureInPictureFrames(reason: String) {
        guard isRunning, currentMode == .pictureInPicture else { return }
        renderPiPFrame(force: true, immediate: true)
        logMPV("PiP prime requested reason=\(reason) primed=\(pipBridge.hasEnqueuedFrame()) \(pipDebugSnapshot())")
        requestRenderBurst(reason: "pip-prime-\(reason)", count: 6, interval: 0.06)
    }

    func activatePictureInPictureLayer() {
        guard isRunning, currentMode == .pictureInPicture else { return }
        logMPV("activating sample-buffer PiP layer \(pipDebugSnapshot())")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning, !self.isStopping, self.currentMode == .pictureInPicture else { return }
            self.displayLayer.isHidden = false
            self.displayLayer.opacity = 1.0
            self.displayLayer.zPosition = 1
            self.glView.isHidden = true
            self.logMPV("sample-buffer PiP layer activated \(self.pipDebugSnapshot())")
        }
        requestRenderBurst(reason: "pip-layer-active", count: 4, interval: 0.06)
    }

    func isPictureInPicturePrimed() -> Bool {
        guard isRunning, currentMode == .pictureInPicture else { return false }
        return pipBridge.hasEnqueuedFrame()
    }

    func resumeForegroundRendering(reason: String) {
        guard isRunning else { return }
        guard currentMode == .openGL else {
            logMPV("foreground render recovery skipped reason=\(reason) mode=\(currentMode)")
            return
        }
        logMPV("foreground render recovery reason=\(reason) \(pipDebugSnapshot())")
        startForegroundDisplayLink(reason: reason)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning, !self.isStopping, self.currentMode == .openGL else { return }
            self.displayLayer.isHidden = true
            self.displayLayer.opacity = 0.0
            self.displayLayer.zPosition = -1
            self.glView.isHidden = false
            self.glView.setNeedsLayout()
            EAGLContext.setCurrent(self.glContext)
            self.glView.deleteDrawable()
            EAGLContext.setCurrent(nil)
            self.glView.setNeedsDisplay()
            self.glView.display()
        }
        if let handle = mpv {
            mpv_wakeup(handle)
        }
        requestRenderBurst(reason: reason, count: 6, interval: 0.08)
    }

    func beginForegroundUIStallRecovery(reason: String) {
        guard isRunning, !isStopping, currentMode == .openGL else { return }
        logMPV("foreground UI recovery requested reason=\(reason)")
        if let handle = mpv {
            mpv_wakeup(handle)
        }
        scheduleRender(force: true)
    }

    private func isForegroundUIRenderSuppressed(now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        _ = now
        if Thread.isMainThread, RunLoop.current.currentMode == .tracking {
            return true
        }
        return false
    }

    private func scheduleForegroundRestoreChecks(reason: String) {
        for delay in [0.25, 0.8, 1.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      self.isRunning,
                      !self.isStopping,
                      self.currentMode == .openGL else {
                    return
                }
                self.refreshVideoState()
                self.restoreSelectedVideoTrack(reason: "\(reason)-restore-check")
                self.logMPV("foreground restore check reason=\(reason) delay=\(String(format: "%.2f", delay)) \(self.pipDebugSnapshot())")
                self.requestRenderBurst(reason: "\(reason)-restore-check", count: 3, interval: 0.05)
            }
        }
    }

    private func pipDebugSnapshot() -> String {
        let size = currentVideoSize()
        let tracks = fetchTrackList()
        let videoCount = tracks.filter { $0.type == "video" }.count
        let selectedVideo = tracks.first(where: { $0.type == "video" && $0.selected })?.id ?? -1
        let subtitleCount = tracks.filter { $0.type == "sub" }.count
        let selectedSubtitle = tracks.first(where: { $0.type == "sub" && $0.selected })?.id ?? -1
        let trackPreview = tracks.prefix(6).map { track -> String in
            let selected = track.selected ? "*" : ""
            return "\(track.type)#\(track.id)\(selected):\(track.title)"
        }.joined(separator: "|")
        let vid = mpv.flatMap { getStringProperty(handle: $0, name: "vid") } ?? "nil"
        let sid = mpv.flatMap { getStringProperty(handle: $0, name: "sid") } ?? "nil"
        let subVisibility = mpv.flatMap { getStringProperty(handle: $0, name: "sub-visibility") } ?? "nil"
        let voConfigured = mpv.flatMap { getStringProperty(handle: $0, name: "vo-configured") } ?? "nil"
        let hwdec = mpv.flatMap { getStringProperty(handle: $0, name: "hwdec-current") } ?? "nil"
        return "mode=\(currentMode) running=\(isRunning) stopping=\(isStopping) context=\(renderContext != nil) paused=\(isPaused) loading=\(isLoading) ready=\(isReadyToSeek) pos=\(String(format: "%.2f", cachedPosition))/\(String(format: "%.2f", cachedDuration)) video=\(String(format: "%.0fx%.0f", size.width, size.height)) glBounds=\(String(format: "%.0fx%.0f", glView.bounds.width, glView.bounds.height)) drawable=\(glView.drawableWidth)x\(glView.drawableHeight) vid=\(vid) sid=\(sid) subVisible=\(subVisibility) vo=\(voConfigured) hwdec=\(hwdec) tracksVideo=\(videoCount) selectedVideo=\(selectedVideo) tracksSub=\(subtitleCount) selectedSub=\(selectedSubtitle) selectedVideoMemory=\(selectedVideoTrackID.map(String.init) ?? "nil") trackPreview=\(trackPreview) bridge={\(pipBridge.debugSnapshot())}"
    }

    private func createOpenGLRenderContext() throws {
        guard let handle = mpv else { return }
        logMPV("creating OpenGL render context")
        var status: Int32 = 0
        performOnMainSync {
            EAGLContext.setCurrent(glContext)
            var initParams = EclipseMPVOpenGLInitParams(get_proc_address: eclipseMPVGetOpenGLProcAddress, get_proc_address_ctx: nil)
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
            logMPV("OpenGL render context creation failed status=\(status)")
            throw RendererError.renderContextCreation(status)
        }
        installRenderUpdateCallback()
        logMPV("OpenGL render context ready pacing=display-link-throttled renderBlockForTargetTime=\(blockForTargetTime)")
    }

    private func destroyRenderContext() {
        guard let context = renderContext else { return }
        logMPV("destroying render context mode=\(currentMode)")
        pipBridge.waitForPendingRenders()
        performOnMainSync {
            EAGLContext.setCurrent(glContext)
            mpv_render_context_set_update_callback(context, nil, nil)
            mpv_render_context_free(context)
            glView.deleteDrawable()
            EAGLContext.setCurrent(nil)
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
            ("paused-for-cache", MPV_FORMAT_FLAG),
            ("sid", MPV_FORMAT_NONE),
            ("aid", MPV_FORMAT_NONE),
            ("track-list", MPV_FORMAT_NONE)
        ]

        for (name, format) in properties {
            _ = name.withCString { pointer in
                mpv_observe_property(handle, 0, pointer, format)
            }
        }
        logMPV("observing properties \(properties.map { $0.0 }.joined(separator: ","))")
    }

    private func installWakeupHandler() {
        guard let handle = mpv else { return }
        mpv_set_wakeup_callback(handle, { userdata in
            guard let userdata else { return }
            let instance = Unmanaged<MPVNativeRenderer>.fromOpaque(userdata).takeUnretainedValue()
            instance.processEvents()
        }, Unmanaged.passUnretained(self).toOpaque())
        logMPV("wakeup handler installed")
    }

    private func startForegroundDisplayLink(reason: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isRunning,
                  !self.isStopping,
                  self.currentMode == .openGL else {
                return
            }
            guard self.foregroundDisplayLink == nil else { return }
            let target = MPVForegroundDisplayLinkTarget(renderer: self)
            let link = CADisplayLink(target: target, selector: #selector(MPVForegroundDisplayLinkTarget.displayLinkDidFire(_:)))
            self.applyForegroundDisplayLinkFrameRate(link, fps: self.foregroundFramesPerSecond)
            link.add(to: .main, forMode: .default)
            self.foregroundDisplayLinkTarget = target
            self.foregroundDisplayLink = link
            self.logMPV("foreground display link started reason=\(reason) fps=\(self.foregroundFramesPerSecond)")
        }
    }

    private func applyForegroundDisplayLinkFrameRate(_ link: CADisplayLink, fps: Int) {
        let clampedFPS = max(1, fps)
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: Float(min(24, clampedFPS)),
                maximum: Float(clampedFPS),
                preferred: Float(clampedFPS)
            )
        } else {
            link.preferredFramesPerSecond = clampedFPS
        }
    }

    private func stopForegroundDisplayLink(reason: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let link = self.foregroundDisplayLink else { return }
            link.invalidate()
            self.foregroundDisplayLink = nil
            self.foregroundDisplayLinkTarget = nil
            self.isRenderScheduled = false
            self.logMPV("foreground display link stopped reason=\(reason)")
        }
    }

    private func startPiPRenderLoop(reason: String) {
        let start = { [weak self] in
            guard let self,
                  self.isRunning,
                  !self.isStopping,
                  self.currentMode == .pictureInPicture,
                  self.pipRenderTimer == nil else {
                return
            }

            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: self.pipFrameInterval, leeway: .milliseconds(8))
            timer.setEventHandler { [weak self] in
                guard let self,
                      self.isRunning,
                      !self.isStopping,
                      self.currentMode == .pictureInPicture else {
                    self?.stopPiPRenderLoop(reason: "pip-loop-ended")
                    return
                }
                // Heartbeat (~every 2s) so a stalled/black PiP shows up as a steady
                // health log instead of silence after the last successful enqueue.
                self.pipHeartbeatTick &+= 1
                if self.pipHeartbeatTick % 48 == 0 {
                    self.logMPV("PiP heartbeat paused=\(self.isPaused) frameUpdates=\(self.pipFrameUpdateRenderCount) forced=\(self.pipForcedRenderCount) \(self.pipBridge.performanceSnapshot())")
                }
                if !self.isPaused || self.forcedPiPRenderCount > 0 {
                    self.renderPiPFrame(force: true)
                }
            }
            self.pipRenderTimer = timer
            timer.resume()
            self.logMPV("PiP render loop started reason=\(reason) fps=24")
        }
        if Thread.isMainThread {
            start()
        } else {
            DispatchQueue.main.async(execute: start)
        }
    }

    private func stopPiPRenderLoop(reason: String) {
        let stop = { [weak self] in
            guard let self, let timer = self.pipRenderTimer else { return }
            timer.setEventHandler {}
            timer.cancel()
            self.pipRenderTimer = nil
            self.logMPV("PiP render loop stopped reason=\(reason)")
        }

        if Thread.isMainThread {
            stop()
        } else {
            DispatchQueue.main.sync(execute: stop)
        }
    }

    fileprivate func handleForegroundDisplayLink(_ link: CADisplayLink) {
        guard isRunning, !isStopping, currentMode == .openGL else {
            stopForegroundDisplayLink(reason: "not-openGL")
            return
        }
        guard !isForegroundUIRenderSuppressed() else { return }
        guard !isPaused || isLoading || forcedOpenGLRenderCount > 0 else { return }
        glView.display()
    }

    private func scheduleRender(force: Bool = false) {
        guard isRunning, !isStopping else { return }
        if force {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRunning, !self.isStopping else { return }
                switch self.currentMode {
                case .openGL:
                    self.forcedOpenGLRenderCount = max(self.forcedOpenGLRenderCount, 1)
                case .pictureInPicture:
                    self.forcedPiPRenderCount = max(self.forcedPiPRenderCount, 1)
                }
                self.scheduleRender()
            }
            return
        }
        switch currentMode {
        case .openGL:
            scheduleOpenGLRender()
        case .pictureInPicture:
            schedulePiPRender()
        }
    }

    private func requestRenderBurst(reason: String, count: Int, interval: CFTimeInterval) {
        guard count > 0 else { return }
        logMPV("render burst reason=\(reason) count=\(count) mode=\(currentMode)")
        for index in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + (interval * Double(index))) { [weak self] in
                guard let self, self.isRunning, !self.isStopping else { return }
                if let handle = self.mpv {
                    mpv_wakeup(handle)
                }
                self.scheduleRender(force: true)
            }
        }
    }

    private func scheduleOpenGLRender() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning, !self.isStopping, self.currentMode == .openGL else { return }
            guard !self.isForegroundUIRenderSuppressed() || self.forcedOpenGLRenderCount > 0 else { return }
            guard !self.isRenderScheduled else { return }
            self.isRenderScheduled = true
            let now = CACurrentMediaTime()
            let delay = max(0, self.foregroundFrameInterval - (now - self.lastForegroundRenderTime))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                guard self.isRunning, !self.isStopping, self.currentMode == .openGL else {
                    self.isRenderScheduled = false
                    return
                }
                guard !self.isForegroundUIRenderSuppressed() || self.forcedOpenGLRenderCount > 0 else {
                    self.isRenderScheduled = false
                    return
                }
                self.isRenderScheduled = false
                self.glView.display()
            }
        }
    }

    private func schedulePiPRender() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning, !self.isStopping, self.currentMode == .pictureInPicture else { return }
            guard !self.isRenderScheduled else { return }
            self.isRenderScheduled = true
            let now = CACurrentMediaTime()
            let delay = max(0, self.pipFrameInterval - (now - self.lastPiPRenderTime))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                guard self.isRunning, !self.isStopping, self.currentMode == .pictureInPicture else {
                    self.isRenderScheduled = false
                    return
                }
                self.isRenderScheduled = false
                self.renderPiPFrame()
            }
        }
    }

    fileprivate func drawOpenGLFrame() {
        guard isRunning, !isStopping, currentMode == .openGL, let context = renderContext else { return }
        guard glView.bounds.width > 0, glView.bounds.height > 0 else { return }
        guard !isForegroundUIRenderSuppressed() || forcedOpenGLRenderCount > 0 else { return }
        refreshSubtitleStyleIfViewportChanged()

        lastForegroundRenderTime = CACurrentMediaTime()
        EAGLContext.setCurrent(glContext)
        glView.bindDrawable()

        let updateFlags = UInt32(mpv_render_context_update(context))
        let shouldForceRender = forcedOpenGLRenderCount > 0
        if shouldForceRender {
            forcedOpenGLRenderCount -= 1
        }
        if updateFlags & MPV_RENDER_UPDATE_FRAME.rawValue != 0 || shouldForceRender {
            var framebuffer: GLint = 0
            glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &framebuffer)
            glViewport(0, 0, GLsizei(glView.drawableWidth), GLsizei(glView.drawableHeight))

            var fbo = EclipseMPVOpenGLFBO(
                fbo: Int32(framebuffer),
                w: Int32(glView.drawableWidth),
                h: Int32(glView.drawableHeight),
                internal_format: Int32(GL_RGBA)
            )
            var flipY: Int32 = 1
            _ = renderOpenGLFrame(context: context, fbo: &fbo, flipY: &flipY, reportSwap: true)
        }

        if updateFlags > 0 {
            scheduleRender()
        }
    }

    private func renderOpenGLFrame(
        context: OpaquePointer,
        fbo: inout EclipseMPVOpenGLFBO,
        flipY: inout Int32,
        reportSwap: Bool
    ) -> Int32 {
        let startedAt = CACurrentMediaTime()
        let result = withUnsafeMutablePointer(to: &fbo) { fboPointer in
            withUnsafeMutablePointer(to: &flipY) { flipPointer in
                openGLRenderParams[0] = mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPointer))
                openGLRenderParams[1] = mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPointer))
                openGLRenderParams[2] = mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: UnsafeMutableRawPointer(&blockForTargetTime))
                openGLRenderParams[3] = mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                return openGLRenderParams.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    guard let baseAddress = buffer.baseAddress else { return -1 }
                    return mpv_render_context_render(context, baseAddress)
                }
            }
        }
        if result < 0 {
            logMPV("OpenGL render failed \(result)")
        } else if reportSwap {
            mpv_render_context_report_swap(context)
        }
        let elapsed = CACurrentMediaTime() - startedAt
        let now = CACurrentMediaTime()
        if elapsed > 0.018, now - lastSlowOpenGLRenderLogAt > 2.0 {
            lastSlowOpenGLRenderLogAt = now
            logMPV("OpenGL render slow elapsedMs=\(String(format: "%.1f", elapsed * 1000)) mode=\(currentMode) nonblocking=\(blockForTargetTime == 0)")
        }
        return result
    }

    private func renderPiPFrame(force: Bool = false, immediate: Bool = false) {
        guard isRunning, !isStopping, currentMode == .pictureInPicture, let context = renderContext else {
            if currentMode == .pictureInPicture {
                logMPV("PiP render skipped running=\(isRunning) stopping=\(isStopping) context=\(renderContext != nil)")
            }
            return
        }
        lastPiPRenderTime = CACurrentMediaTime()
        EAGLContext.setCurrent(glContext)
        let updateFlags = UInt32(mpv_render_context_update(context))
        EAGLContext.setCurrent(nil)
        let shouldForceRender = force || forcedPiPRenderCount > 0
        if shouldForceRender {
            forcedPiPRenderCount = max(0, forcedPiPRenderCount - 1)
        }
        if updateFlags & MPV_RENDER_UPDATE_FRAME.rawValue != 0 || shouldForceRender {
            if updateFlags & MPV_RENDER_UPDATE_FRAME.rawValue != 0 {
                pipFrameUpdateRenderCount += 1
            } else {
                pipForcedRenderCount += 1
            }
            let renderSize = currentPiPRenderSize()
            pipRenderRequestCount += 1
            if pipRenderRequestCount <= 5 || pipRenderRequestCount % 60 == 0 {
                logMPV("PiP render frame request count=\(pipRenderRequestCount) frameUpdates=\(pipFrameUpdateRenderCount) forced=\(pipForcedRenderCount) immediate=\(immediate) force=\(force) flags=\(updateFlags) size=\(String(format: "%.0fx%.0f", renderSize.width, renderSize.height)) \(pipDebugSnapshot())")
            }
            pipBridge.renderOpenGL(context: context, glContext: glContext, videoSize: renderSize, playbackPosition: cachedPosition) { [weak self] fbo, flipY in
                guard let self else { return -1 }
                return self.renderOpenGLFrame(context: context, fbo: &fbo, flipY: &flipY, reportSwap: true)
            }
        } else if pipRenderRequestCount <= 3 {
            logMPV("PiP render no frame update flags=\(updateFlags) force=\(force) forcedCount=\(forcedPiPRenderCount)")
        }
        if updateFlags > 0 {
            scheduleRender()
        }
    }

    private func handleEvent(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_START_FILE:
            logMPV("event start-file gen=\(loadGeneration)")
            cachedPosition = 0
            cachedDuration = 0
            setLoading(true)
        case MPV_EVENT_VIDEO_RECONFIG:
            logMPV("event video-reconfig")
            refreshVideoState()
        case MPV_EVENT_FILE_LOADED:
            logMPV("event file-loaded gen=\(loadGeneration)")
            handleFileLoaded()
        case MPV_EVENT_END_FILE:
            logMPV("event end-file gen=\(loadGeneration) ready=\(isReadyToSeek) loading=\(isLoading) pos=\(String(format: "%.2f", cachedPosition)) dur=\(String(format: "%.2f", cachedDuration))")
            if !isReadyToSeek {
                let message = lastPlaybackErrorMessage ?? "MPV ended before playback became ready"
                setLoading(false)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.renderer(self, didFailWithError: message)
                }
            }
        case MPV_EVENT_PROPERTY_CHANGE:
            if let property = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee.name {
                refreshProperty(named: String(cString: property))
            }
        case MPV_EVENT_SHUTDOWN:
            logMPV("event shutdown")
        case MPV_EVENT_LOG_MESSAGE:
            if let logPointer = event.data?.assumingMemoryBound(to: mpv_event_log_message.self) {
                let component = logPointer.pointee.prefix.map { String(cString: $0) } ?? "unknown"
                let text = logPointer.pointee.text.map { String(cString: $0) } ?? ""
                let level = logPointer.pointee.level.map { String(cString: $0) } ?? "info"
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let lower = trimmed.lowercased()
                    if lower.contains("tls") {
                        lastPlaybackErrorMessage = trimmed
                    } else if lower.contains("http error")
                        || lower.contains("failed to open")
                        || lower.contains("error opening")
                        || lower.contains("403")
                        || lower.contains("404")
                        || lower.contains("502") {
                        if let existing = lastPlaybackErrorMessage, existing.lowercased().contains("tls") {
                            lastPlaybackErrorMessage = "\(existing) \(trimmed)"
                        } else {
                            lastPlaybackErrorMessage = trimmed
                        }
                    }
                    logMPV("mpv[\(component)] \(level): \(trimmed)")
                    trackHardwareDecodeFailureIfNeeded(component: component, message: trimmed, lowercasedMessage: lower)
                }
            }
        default:
            break
        }
    }

    private func trackHardwareDecodeFailureIfNeeded(component: String, message: String, lowercasedMessage lower: String) {
        guard isRunning, !isStopping, !runtimeHardwareDecodeFallbackApplied else { return }
        guard lower.contains("hardware accelerator failed to decode picture")
            || lower.contains("error while decoding frame (hardware decoding)")
            || lower.contains("vt decoder cb: output image buffer is null")
            || lower.contains("no frame decoded") else {
            return
        }

        let now = Date()
        if let start = hardwareDecodeFailureWindowStart, now.timeIntervalSince(start) <= 5.0 {
            hardwareDecodeFailureCount += 1
        } else {
            hardwareDecodeFailureWindowStart = now
            hardwareDecodeFailureCount = 1
        }

        if hardwareDecodeFailureCount == 1 || hardwareDecodeFailureCount == 6 {
            logMPV("hardware decode failure observed count=\(hardwareDecodeFailureCount) component=\(component) message=\(shortText(message, limit: 140))")
        }

        guard hardwareDecodeFailureCount >= 6 else { return }
        applyRuntimeHardwareDecodeFallback(trigger: shortText(message, limit: 140))
    }

    private func applyRuntimeHardwareDecodeFallback(trigger: String) {
        guard !runtimeHardwareDecodeFallbackApplied else { return }
        runtimeHardwareDecodeFallbackApplied = true

        let currentHWDec = mpv.flatMap { getStringProperty(handle: $0, name: "hwdec-current") } ?? "nil"
        let videoCodec = mpv.flatMap { getStringProperty(handle: $0, name: "video-codec") } ?? "nil"
        logMPV("hardware decode fallback applying count=\(hardwareDecodeFailureCount) codec=\(videoCodec) hwdec=\(currentHWDec) trigger=\(trigger)")

        setProperty(name: "vd-lavc-software-fallback", value: "yes")
        setProperty(name: "hwdec", value: "no")
        if let handle = mpv, isReadyToSeek {
            command(handle, ["seek", "0", "relative", "exact"])
        }
        requestRenderBurst(reason: "hwdecode-fallback", count: 4, interval: 0.06)
    }

    private func resetHardwareDecodeFailureTracking() {
        hardwareDecodeFailureWindowStart = nil
        hardwareDecodeFailureCount = 0
        runtimeHardwareDecodeFallbackApplied = false
    }

    private func handleFileLoaded() {
        isReadyToSeek = true
        isAwaitingFileLoadedForCurrentLoad = false
        setLoading(isPausedForCache)
        refreshVideoState()
        let elapsed = currentLoadStartedAt.map { String(format: "%.2f", Date().timeIntervalSince($0)) } ?? "nil"
        logMPV("file loaded gen=\(loadGeneration) elapsed=\(elapsed)s duration=\(String(format: "%.2f", cachedDuration)) position=\(String(format: "%.2f", cachedPosition))")
        logTrackSummaryIfChanged(reason: "file-loaded")
        startForegroundDisplayLink(reason: "file-loaded")
        if let initialSeek = pendingInitialSeek {
            logMPV("applying pending initial seek \(String(format: "%.2f", initialSeek))s")
            seek(to: initialSeek)
            pendingInitialSeek = nil
        }
        scheduleRender()
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
        let cachedVideoSize = currentVideoSize()
        logMPV("video state width=\(width) height=\(height) cached=\(String(format: "%.0fx%.0f", cachedVideoSize.width, cachedVideoSize.height)) glBounds=\(String(format: "%.0fx%.0f", glView.bounds.width, glView.bounds.height)) drawable=\(glView.drawableWidth)x\(glView.drawableHeight)")
        if width <= 0 || height <= 0 {
            restoreSelectedVideoTrack(reason: "zero-video-size-\(currentMode)")
        }
        scheduleRender()
    }

    private func currentPiPRenderSize() -> CGSize {
        let videoSize = currentVideoSize()
        if videoSize.width > 0, videoSize.height > 0 {
            return videoSize
        }

        if glView.drawableWidth > 0, glView.drawableHeight > 0 {
            let drawableSize = CGSize(width: CGFloat(glView.drawableWidth), height: CGFloat(glView.drawableHeight))
            logMPV("PiP render using GL drawable fallback size=\(String(format: "%.0fx%.0f", drawableSize.width, drawableSize.height))")
            return drawableSize
        }

        let viewSize = glView.bounds.size
        if viewSize.width > 0, viewSize.height > 0 {
            logMPV("PiP render using GL bounds fallback size=\(String(format: "%.0fx%.0f", viewSize.width, viewSize.height))")
            return viewSize
        }

        let layerSize = displayLayer.bounds.size
        if layerSize.width > 0, layerSize.height > 0 {
            let fallbackScale = UIScreen.main.nativeScale > 0 ? UIScreen.main.nativeScale : UIScreen.main.scale
            let layerScale = displayLayer.contentsScale > 1 ? displayLayer.contentsScale : fallbackScale
            let scaledLayerSize = CGSize(width: layerSize.width * layerScale, height: layerSize.height * layerScale)
            logMPV("PiP render using displayLayer fallback size=\(String(format: "%.0fx%.0f", scaledLayerSize.width, scaledLayerSize.height)) scale=\(String(format: "%.2f", layerScale))")
            return scaledLayerSize
        }

        logMPV("PiP render using default fallback size=1920x1080")
        return CGSize(width: 1920, height: 1080)
    }

    private func refreshProperty(named name: String) {
        guard let handle = mpv else { return }
        switch name {
        case "duration":
            var value = Double(0)
            if getProperty(handle: handle, name: name, format: MPV_FORMAT_DOUBLE, value: &value) >= 0 {
                cachedDuration = max(0, value)
                if cachedDuration > 0, abs(cachedDuration - lastDurationLogValue) > 5 {
                    lastDurationLogValue = cachedDuration
                    logMPV("duration updated \(String(format: "%.2f", cachedDuration))s")
                }
                publishProgress()
            }
        case "time-pos":
            var value = Double(0)
            if getProperty(handle: handle, name: name, format: MPV_FORMAT_DOUBLE, value: &value) >= 0 {
                cachedPosition = max(0, value)
                let bucket = Int(cachedPosition / 10.0)
                if bucket != lastProgressLogBucket {
                    lastProgressLogBucket = bucket
                    logMPV("progress position=\(String(format: "%.2f", cachedPosition)) duration=\(String(format: "%.2f", cachedDuration)) loading=\(isLoading) ready=\(isReadyToSeek) paused=\(isPaused)")
                }
                publishProgress()
            }
        case "dwidth", "dheight":
            refreshVideoState()
        case "pause":
            var flag: Int32 = 0
            if getProperty(handle: handle, name: name, format: MPV_FORMAT_FLAG, value: &flag) >= 0 {
                let newPaused = flag != 0
                if newPaused != isPaused {
                    isPaused = newPaused
                    logMPV("pause changed isPaused=\(newPaused)")
                    if newPaused {
                        stopForegroundDisplayLink(reason: "paused")
                    } else {
                        startForegroundDisplayLink(reason: "unpaused")
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.delegate?.renderer(self, didChangePause: newPaused)
                    }
                }
            }
        case "paused-for-cache":
            var flag: Int32 = 0
            if getProperty(handle: handle, name: name, format: MPV_FORMAT_FLAG, value: &flag) >= 0 {
                let newPausedForCache = flag != 0
                if newPausedForCache != isPausedForCache {
                    isPausedForCache = newPausedForCache
                    logMPV("cache buffering changed pausedForCache=\(newPausedForCache) \(cacheDiagnosticsSnapshot())")
                    if newPausedForCache {
                        setLoading(true)
                    } else if isReadyToSeek {
                        setLoading(false)
                    }
                }
            }
        case "sid":
            let current = getCurrentSubtitleTrackId()
            logMPV("subtitle track changed sid=\(current)")
            logTrackSummaryIfChanged(reason: "sid")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.renderer(self, subtitleTrackDidChange: current)
                self.delegate?.rendererDidChangeTracks(self)
            }
        case "aid", "track-list":
            logTrackSummaryIfChanged(reason: name)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.rendererDidChangeTracks(self)
            }
        default:
            break
        }
    }

    private func publishProgress() {
        guard !isAwaitingFileLoadedForCurrentLoad else { return }
        let position = cachedPosition
        let duration = cachedDuration
        let generation = loadGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.loadGeneration == generation,
                  !self.isAwaitingFileLoadedForCurrentLoad else { return }
            self.delegate?.renderer(self, didUpdatePosition: position, duration: duration)
        }
    }

    private func setLoading(_ loading: Bool) {
        guard isLoading != loading else { return }
        isLoading = loading
        logMPV("loading changed \(loading)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.renderer(self, didChangeLoading: loading)
        }
    }

    private func updateVideoSize(width: Int, height: Int, allowZero: Bool = false) {
        guard (width > 0 && height > 0) || allowZero else { return }
        let size = CGSize(width: max(width, 0), height: max(height, 0))
        stateQueue.sync(flags: .barrier) {
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
            eclipseApplyPreferredOutputChannels(log: { [weak self] in self?.logMPV($0) })
            EclipseAudioRouteWatcher.shared.ensureInstalled()
        } catch {
            logMPV("failed to activate AVAudioSession: \(error)")
        }
    }

    private func setOption(name: String, value: String) {
        guard let handle = mpv else { return }
        let status = value.withCString { valuePointer in
            name.withCString { namePointer in
                mpv_set_option_string(handle, namePointer, valuePointer)
            }
        }
        if status < 0 {
            logMPV("failed to set option \(name)=\(redactIfSensitive(name: name, value: value)) status=\(status)")
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
            logMPV("failed to set property \(name)=\(redactIfSensitive(name: name, value: value)) status=\(status)")
        }
    }

    private func clearProperty(name: String) {
        guard let handle = mpv else { return }
        let status = name.withCString { namePointer in
            mpv_set_property(handle, namePointer, MPV_FORMAT_NONE, nil)
        }
        if status < 0 {
            logMPV("failed to clear property \(name) status=\(status)")
        }
    }

    private func updateHTTPHeaders(_ headers: [String: String]?) {
        guard let headers, !headers.isEmpty else {
            logMPV("clearing HTTP headers")
            clearProperty(name: "http-header-fields")
            return
        }

        let headerString = headers
            .filter { !$0.key.isEmpty && !$0.value.isEmpty }
            .map { key, value in "\(key): \(value)" }
            .joined(separator: "\r\n")

        if headerString.isEmpty {
            logMPV("HTTP header update had no usable values; clearing")
            clearProperty(name: "http-header-fields")
        } else {
            logMPV("applying MPV raw HTTP headers count=\(headers.count) keys=[\(headers.keys.sorted().joined(separator: ","))]")
            setProperty(name: "http-header-fields", value: headerString)
        }
    }

    private func apply(commands: [[String]], on handle: OpaquePointer) {
        for command in commands where !command.isEmpty {
            self.command(handle, command)
        }
    }

    @discardableResult
    private func command(_ handle: OpaquePointer, _ args: [String]) -> Int32 {
        guard !args.isEmpty else { return 0 }
        logMPV("command \(sanitizedCommand(args))")
        let status = withCStringArray(args) { pointer in
            mpv_command_async(handle, 0, pointer)
        }
        if status < 0 {
            logMPV("command failed status=\(status) command=\(sanitizedCommand(args))")
        }
        return status
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

    private func scheduleLoadWatchdog(generation: Int, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.isRunning,
                  !self.isStopping,
                  self.loadGeneration == generation,
                  self.isLoading,
                  !self.isReadyToSeek else {
                return
            }

            let elapsed = self.currentLoadStartedAt.map { String(format: "%.2f", Date().timeIntervalSince($0)) } ?? "nil"
            let videoSize = self.currentVideoSize()
            let coreIdle = self.mpv.flatMap { self.getStringProperty(handle: $0, name: "core-idle") } ?? "nil"
            let idleActive = self.mpv.flatMap { self.getStringProperty(handle: $0, name: "idle-active") } ?? "nil"
            let streamOpen = self.mpv.flatMap { self.getStringProperty(handle: $0, name: "stream-open-filename") } ?? "nil"
            let path = self.mpv.flatMap { self.getStringProperty(handle: $0, name: "path") } ?? "nil"
            let pausedForCache = self.mpv.flatMap { self.getStringProperty(handle: $0, name: "paused-for-cache") } ?? "nil"
            let cacheState = self.mpv.flatMap { self.getStringProperty(handle: $0, name: "cache-buffering-state") } ?? "nil"
            self.logMPV("startup watchdog gen=\(generation) delay=\(String(format: "%.0f", delay))s elapsed=\(elapsed)s loading=\(self.isLoading) ready=\(self.isReadyToSeek) paused=\(self.isPaused) pausedForCache=\(pausedForCache) cache=\(cacheState) pos=\(String(format: "%.2f", self.cachedPosition)) dur=\(String(format: "%.2f", self.cachedDuration)) video=\(String(format: "%.0fx%.0f", videoSize.width, videoSize.height)) glBounds=\(String(format: "%.0fx%.0f", self.glView.bounds.width, self.glView.bounds.height)) coreIdle=\(coreIdle) idleActive=\(idleActive) streamOpen=\(self.shortText(streamOpen, limit: 120)) path=\(self.shortText(path, limit: 120)) url=\(self.currentURL.map { self.describe(url: $0) } ?? "nil")")
            if let handle = self.mpv {
                mpv_wakeup(handle)
            }
            self.scheduleRender()
            if delay >= 8, coreIdle == "yes", idleActive == "yes" {
                self.logMPV("startup watchdog declaring stalled load gen=\(generation); mpv stayed idle after loadfile")
                self.setLoading(false)
                self.delegate?.renderer(self, didFailWithError: "MPV stayed idle after the stream was submitted")
            }
        }
    }

    private func rememberSelectedVideoTrack(reason: String) {
        let tracks = fetchTrackList()
        if let selected = tracks.first(where: { $0.type == "video" && $0.selected })?.id {
            selectedVideoTrackID = selected
            logMPV("remembered selected video track id=\(selected) reason=\(reason)")
            return
        }

        guard selectedVideoTrackID == nil,
              let fallback = tracks.first(where: { $0.type == "video" })?.id else {
            return
        }
        selectedVideoTrackID = fallback
        logMPV("remembered fallback video track id=\(fallback) reason=\(reason)")
    }

    private func restoreSelectedVideoTrack(reason: String) {
        guard mpv != nil else { return }
        let tracks = fetchTrackList()
        let videoTrackIDs = tracks.filter { $0.type == "video" }.map(\.id)
        guard !videoTrackIDs.isEmpty else { return }

        let target = selectedVideoTrackID.flatMap { videoTrackIDs.contains($0) ? $0 : nil } ?? videoTrackIDs[0]
        if tracks.contains(where: { $0.type == "video" && $0.id == target && $0.selected }) {
            return
        }

        selectedVideoTrackID = target
        logMPV("restoring video track id=\(target) reason=\(reason)")
        setProperty(name: "vid", value: "\(target)")
    }

    private func logTrackSummaryIfChanged(reason: String) {
        let tracks = fetchTrackList()
        let videoCount = tracks.filter { $0.type == "video" }.count
        let selectedVideo = tracks.first(where: { $0.type == "video" && $0.selected })?.id
        if let selectedVideo {
            selectedVideoTrackID = selectedVideo
        }
        let audioCount = tracks.filter { $0.type == "audio" }.count
        let subtitleCount = tracks.filter { $0.type == "sub" }.count
        let selectedAudio = tracks.first(where: { $0.type == "audio" && $0.selected })?.id ?? -1
        let selectedSubtitle = tracks.first(where: { $0.type == "sub" && $0.selected })?.id ?? -1
        let preview = tracks.prefix(8).map { track -> String in
            let selected = track.selected ? "*" : ""
            let codec = track.codec.isEmpty ? "unknown" : track.codec
            let flags = [
                track.external ? "external" : nil,
                track.defaultTrack ? "default" : nil,
                track.forced ? "forced" : nil
            ]
            .compactMap { $0 }
            .joined(separator: ",")
            let flagText = flags.isEmpty ? "" : "[\(flags)]"
            return "\(track.type)#\(track.id)\(selected):\(track.title){\(codec)}\(flagText)"
        }.joined(separator: "|")
        let summary = "video=\(videoCount) selectedVideo=\(selectedVideo ?? -1) audio=\(audioCount) selectedAudio=\(selectedAudio) subs=\(subtitleCount) selectedSub=\(selectedSubtitle) preview=\(preview)"
        guard summary != lastTrackSummary else { return }
        lastTrackSummary = summary
        logMPV("tracks changed reason=\(reason) \(summary)")
        if currentMode == .pictureInPicture, selectedVideo == nil {
            restoreSelectedVideoTrack(reason: "track-list-\(reason)")
        }
    }

    private func cacheDiagnosticsSnapshot() -> String {
        guard let handle = mpv else { return "mpv=nil" }
        let buffering = getStringProperty(handle: handle, name: "cache-buffering-state") ?? "nil"
        let duration = getStringProperty(handle: handle, name: "demuxer-cache-duration") ?? "nil"
        let speed = getStringProperty(handle: handle, name: "cache-speed") ?? "nil"
        let idle = getStringProperty(handle: handle, name: "demuxer-cache-idle") ?? "nil"
        return "cachePercent=\(buffering) cacheDuration=\(duration) cacheSpeed=\(speed) demuxerIdle=\(idle)"
    }

    private func describe(url: URL) -> String {
        if url.isFileURL {
            return "file://\(url.lastPathComponent)"
        }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return shortText(url.absoluteString, limit: 180)
        }
        if components.query != nil {
            components.query = "<query>"
        }
        return shortText(components.string ?? url.absoluteString, limit: 180)
    }

    private func sanitizedCommand(_ args: [String]) -> String {
        args.enumerated().map { index, arg in
            if index == 1, args.first == "loadfile", let url = URL(string: arg) {
                return describe(url: url)
            }
            if arg.contains("\r\n") || arg.localizedCaseInsensitiveContains("cookie:") || arg.localizedCaseInsensitiveContains("authorization:") {
                return "<redacted>"
            }
            return shortText(arg, limit: 120)
        }
        .joined(separator: " ")
    }

    private func redactIfSensitive(name: String, value: String) -> String {
        if name == "http-header-fields" {
            return "<\(value.components(separatedBy: "\r\n").count) headers>"
        }
        return shortText(value, limit: 120)
    }

    private func shortText(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "..."
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
            var codec = ""
            var external = false
            var defaultTrack = false
            var forced = false
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
                case "codec":
                    if value.format == MPV_FORMAT_STRING, let cString = value.u.string {
                        codec = String(cString: cString)
                    }
                case "external":
                    if value.format == MPV_FORMAT_FLAG {
                        external = value.u.flag != 0
                    }
                case "default":
                    if value.format == MPV_FORMAT_FLAG {
                        defaultTrack = value.u.flag != 0
                    }
                case "forced":
                    if value.format == MPV_FORMAT_FLAG {
                        forced = value.u.flag != 0
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
            tracks.append(MPVTrackInfo(
                id: id,
                type: type,
                title: displayTitle(title: title, lang: lang, fallbackId: id),
                lang: lang,
                codec: codec,
                external: external,
                defaultTrack: defaultTrack,
                forced: forced,
                selected: selected
            ))
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
        logMPV("play requested")
        ensureAudioSessionActive()
        startForegroundDisplayLink(reason: "play")
        setProperty(name: "pause", value: "no")
        requestRenderBurst(reason: "play", count: 4, interval: 0.08)
    }

    func pausePlayback() {
        logMPV("pause requested")
        stopForegroundDisplayLink(reason: "pause-request")
        setProperty(name: "pause", value: "yes")
    }

    func togglePause() {
        isPaused ? play() : pausePlayback()
    }

    func seek(to seconds: Double) {
        guard let handle = mpv else { return }
        command(handle, ["seek", String(max(0, seconds)), "absolute", "exact"])
        requestRenderBurst(reason: "seek-absolute", count: 3, interval: 0.06)
    }

    func seek(by seconds: Double) {
        guard let handle = mpv else { return }
        command(handle, ["seek", String(seconds), "relative", "exact"])
        requestRenderBurst(reason: "seek-relative", count: 3, interval: 0.06)
    }

    func setSpeed(_ speed: Double) {
        let clampedSpeed = min(max(speed, 0.25), 3.0)
        logMPV("setSpeed requested=\(String(format: "%.2f", speed)) clamped=\(String(format: "%.2f", clampedSpeed))")
        setProperty(name: "speed", value: String(clampedSpeed))
        requestRenderBurst(reason: "speed-\(String(format: "%.2f", clampedSpeed))", count: 2, interval: 0.08)
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
        logMPV("setAudioTrack id=\(id)")
        setProperty(name: "aid", value: String(id))
    }

    func applyAudioFilterChain(_ chain: String) {
        logMPV("applyAudioFilterChain \(chain.isEmpty ? "(cleared)" : chain)")
        setProperty(name: "af", value: chain)
    }

    func getSubtitleTracks() -> [(Int, String)] {
        fetchTrackList()
            .filter { $0.type == "sub" }
            .map { ($0.id, $0.title) }
    }

    func getSubtitleTracksDetailed() -> [(Int, String, String, Bool)] {
        fetchTrackList()
            .filter { $0.type == "sub" }
            .map { ($0.id, $0.title, $0.codec, $0.external) }
    }

    func getCurrentSubtitleTrackId() -> Int {
        let id = getTrackIdProperty("sid")
        if id >= 0 { return id }
        return fetchTrackList().first(where: { $0.type == "sub" && $0.selected })?.id ?? -1
    }

    func setSubtitleTrack(id: Int) {
        logMPV("setSubtitleTrack id=\(id)")
        setProperty(name: "sid", value: String(id))
        setProperty(name: "sub-visibility", value: "yes")
    }

    func disableSubtitles() {
        logMPV("disableSubtitles requested")
        setProperty(name: "sid", value: "no")
        setProperty(name: "sub-visibility", value: "no")
    }

    func refreshSubtitleOverlay() {
        applySubtitleStyle(lastAppliedSubtitleStyle)
    }

    func loadExternalSubtitles(urls: [String], names: [String]? = nil, enforce: Bool = false) {
        guard let handle = mpv else { return }
        logMPV("loadExternalSubtitles count=\(urls.count) enforce=\(enforce)")
        for (index, url) in urls.enumerated() {
            guard !url.isEmpty else { continue }
            let fallbackName: String?
            if let names, index < names.count {
                fallbackName = names[index]
            } else {
                fallbackName = nil
            }
            let title = externalSubtitleTitle(urlString: url, fallbackName: fallbackName, fallbackIndex: index)
            let flag = enforce ? "select" : "auto"
            command(handle, ["sub-add", url, flag, title])
        }
    }

    private func externalSubtitleTitle(urlString: String, fallbackName: String?, fallbackIndex: Int) -> String {
        if let fallbackName, !fallbackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fallbackName
        }
        if let url = URL(string: urlString) {
            let filename = url.deletingPathExtension().lastPathComponent
            if !filename.isEmpty {
                return filename
            }
        }
        return "Subtitle \(fallbackIndex + 1)"
    }

    func applySubtitleStyle(_ style: SubtitleStyle) {
        lastAppliedSubtitleStyle = style
        logMPV("applySubtitleStyle visible=\(style.isVisible) font=\(String(format: "%.1f", style.fontSize)) stroke=\(String(format: "%.1f", style.strokeWidth)) offset=\(String(format: "%.1f", style.verticalOffset))")
        setProperty(name: "sub-visibility", value: style.isVisible ? "yes" : "no")
        setProperty(name: "sub-font-size", value: String(adjustedSubtitleFontSize(for: style)))
        setProperty(name: "sub-color", value: mpvColor(style.foregroundColor))
        setProperty(name: "sub-border-color", value: mpvColor(style.strokeColor))
        setProperty(name: "sub-border-size", value: String(format: "%.2f", max(0, min(style.strokeWidth * 1.5, 5.0))))
        setProperty(name: "sub-pos", value: mpvSubtitlePosition(for: style.verticalOffset))
        setProperty(name: "sub-shadow-offset", value: "0")
        setProperty(name: "sub-ass-override", value: experimentalSubtitleASSOverrideValue(isMetalRenderer: false))
        setProperty(name: "sub-border-style", value: style.closedCaptionBackground ? "background-box" : "outline-and-shadow")
        setProperty(name: "sub-back-color", value: style.closedCaptionBackground ? "0.0/0.0/0.0/0.75" : "0.0/0.0/0.0/0.0")
    }

    private func refreshSubtitleStyleIfViewportChanged() {
        let size = glView.bounds.size
        guard abs(size.width - lastSubtitleViewportSize.width) > 0.5 ||
              abs(size.height - lastSubtitleViewportSize.height) > 0.5 else {
            return
        }
        lastSubtitleViewportSize = size
        applySubtitleStyle(lastAppliedSubtitleStyle)
    }

    private func adjustedSubtitleFontSize(for style: SubtitleStyle) -> Int {
        let baseSize = max(10, min(style.fontSize, 72))
        let viewport = glView.bounds.size
        guard viewport.width > viewport.height, viewport.height > 0 else {
            return Int(baseSize)
        }

        let multiplier = min(2.0, max(1.0, 720.0 / viewport.height))
        return Int(max(10, min(baseSize * multiplier, 72)))
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
/// Compatibility placeholder for code shared with platforms where the iOS MPV
/// renderer is unavailable. OpenGL is intentionally not compiled into iOS.
final class MPVNativeRenderer: PlayerRenderer {
    enum RendererError: Error { case unavailable }

    weak var delegate: MPVNativeRendererDelegate?

    init(displayLayer: AVSampleBufferDisplayLayer) { }
    var prefersPictureInPictureLayerActivationBeforeStart: Bool { false }
    func getRenderingView() -> UIView { UIView() }
    func renderingLayoutDidChange(containerSize: CGSize) { }
    func start() throws { throw RendererError.unavailable }
    func stop() { }
    func load(url: URL, with preset: PlayerPreset, headers: [String: String]?) { }
    func reloadCurrentItem() { }
    func applyPreset(_ preset: PlayerPreset) { }
    func prepareInitialSeek(to seconds: Double?) { }
    func beginForegroundUIStallRecovery(reason: String) { }
    func canStartSampleBufferPictureInPicture() -> Bool { false }
    func prepareForPictureInPictureStart() { }
    func finishPictureInPicture() { }
    func primePictureInPictureFrames(reason: String) { }
    func activatePictureInPictureLayer() { }
    func isPictureInPicturePrimed() -> Bool { false }
    func resumeForegroundRendering(reason: String) { }
    func pictureInPictureDebugSnapshot() -> String { "mpv unavailable" }
    func performanceOverlaySnapshot() -> String { "MPV unavailable" }
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
    func getSubtitleTracksDetailed() -> [(Int, String, String, Bool)] { [] }
    func getCurrentSubtitleTrackId() -> Int { -1 }
    func setSubtitleTrack(id: Int) { }
    func disableSubtitles() { }
    func refreshSubtitleOverlay() { }
    func loadExternalSubtitles(urls: [String], names: [String]? = nil, enforce: Bool = false) { }
    func applySubtitleStyle(_ style: SubtitleStyle) { }
    var isPausedState: Bool { true }
    var supportsBitmapSubtitleTracks: Bool { false }
}
#endif

/// Lightweight per-stream facts surfaced by the performance overlay so heat can be *correlated* with what is
/// actually being.
struct MetalPlaybackDiagnostics {
    let renderSize: CGSize
    let isHDR: Bool
    /// "SDR" / "HDR PQ" / "HDR HLG".
    let dynamicRangeText: String
    /// True while the expensive rgba64 -> RGBA16F high-bit-depth render path is active.
    let highBitDepthActive: Bool
    /// Active subtitle track codec ("ass" / "subrip" / "hdmv_pgs_subtitle"); nil when subtitles
    /// are off or the stream is hard-subbed (no subtitle track at all).
    let subtitleCodec: String?
    /// Raw hwdec-current value from the inline renderer. An empty string means
    /// mpv did not expose the property at this instant (commonly while reconfiguring),
    /// while a literal "no" is the authoritative software-decoder state.
    let hardwareDecoder: String?
}

#if ECLIPSE_MPVKIT_MOLTENVK_INLINE_RENDERER && ECLIPSE_MPVKIT_SAMPLE_BUFFER_PIP_BRIDGE

/// Hosts the GPU renderer's inline `CAMetalLayer`, keeping it sized to the view bounds and
/// reporting layout changes so the renderer can resize its MoltenVK drawable.
final class MPVGPUInlineHostView: UIView {
    var onLayoutChange: ((CGRect) -> Void)?
    private weak var hostedLayer: CAMetalLayer?

    func host(_ metalLayer: CAMetalLayer) {
        guard hostedLayer !== metalLayer else { return }
        hostedLayer?.removeFromSuperlayer()
        hostedLayer = metalLayer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        layer.addSublayer(metalLayer)
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let hostedLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedLayer.frame = bounds
            CATransaction.commit()
        }
        onLayoutChange?(bounds)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Moving between an iPad's internal panel and an external display can keep identical
        // bounds. Still notify the bridge so its EDR/colorspace decision follows the new screen.
        onLayoutChange?(bounds)
    }
}

/// PlayerRenderer that renders inline playback on the GPU, mpv `vo=gpu-next` via MoltenVK into a `CAMetalLayer`,
/// preferring direct VideoToolbox hardware decode with its copy path available as a fallback.
final class MPVGPUPlayerBridge: PlayerRenderer {
    static var unavailableReason: String? { MPVGPUPlayerRenderer.inlineGPUUnavailableReason }
    static var isAvailable: Bool { MPVGPUPlayerRenderer.isSupported }

    weak var delegate: MPVNativeRendererDelegate?

    private let gpuRenderer: MPVGPUPlayerRenderer
    private let hostView = MPVGPUInlineHostView(frame: .zero)
    private var currentPreset: PlayerPreset?
    private var currentURL: URL?
    private var currentHeaders: [String: String]?
    private var pendingInitialSeek: Double?
    private var lastAppliedSubtitleStyle: SubtitleStyle = .default
    private var isRunning = false
    private var isPaused = true
    private var isReadyToSeek = false
    private var isLoading = false
    private var isAwaitingReadyForCurrentLoad = true
    /// MPVKit's gpu-next wrapper reports `.playing` immediately when `play()` clears mpv's pause
    /// property, before the new file has emitted FILE_LOADED / VIDEO_RECONFIG. On slower iPads a
    /// fresh 0:00 load can otherwise be treated as fully started early enough to kick off PiP
    /// warmup while the inline renderer is still opening the file, which can starve the player UI.
    private var didLogFreshIPadStartupFence = false
    private var hasDeferredFreshIPadPlaybackState = false
    /// Caller-owned token mirrored into MPVKit so a late FILE_LOADED/VIDEO_RECONFIG from a
    /// replaced item cannot release the fresh-iPad startup fence for the current load.
    private var gpuLoadGeneration: UInt64 = 0
    private var hasObservedVideoReconfigureForCurrentLoad = false
    private var isPictureInPictureActive = false
    /// Invalidates callbacks queued by a previous start/stop cycle before they can reach the host.
    private var callbackGeneration: UInt64 = 0
    private var pictureInPictureStopRequestHandler: ((String) -> Void)?
    private var positionUpdateTimer: Timer?
    private var lastPositionUpdateAt: CFTimeInterval = 0
    private let positionUpdateInterval: CFTimeInterval = 0.5
    private var lastLoggedState = ""
    /// Drives the GPU heat-quality profile: the drawable downscale (`renderScale` to `renderScaleMultiplier`) plus
    /// frame-size/HDR caps.
    private var qualityProfile: MPVMetalSampleBufferQualityProfile
    /// Fraction of native drawable resolution the inline gpu-next surface is rendered at (from the
    /// active profile's `renderScale`). Lower = less fragment-shader work and heat; CAMetalLayer
    /// upscales to the view bounds.
    private var renderScaleMultiplier: CGFloat = 1.0
    private var lastLoggedScalers = ""
    /// Last logged decode signature (hwdec-current|pixfmt) so the per-load decode-engagement log
    /// fires only when it changes. Reset on each new load.
    private var lastLoggedDecode = ""
    /// Decoded source video height (from the kit diagnostics), used by upscaling modes to choose scaler/cap behavior.
    private var lastKnownSourceHeight: Int = 0
    /// Decoded source video width, paired with `lastKnownSourceHeight` so capped upscaling modes
    /// render cap can aspect-fit the source into the view (letterboxed video occupies less than the
    /// full view). 0 until resolved; reset on each new load.
    private var lastKnownSourceWidth: Int = 0
    /// Fresh-load fence for the next-episode / in-place replace transition.
    private var hasConfirmedFreshPositionForCurrentLoad = false
    /// The kit's (stale) cachedPosition captured at the START of load(), before the new file is handed to mpv.
    private var positionAtLoadStart: Double = 0
    /// Last applied HDR decision signature (mode|gamma|primaries|passthrough) so repeated
    /// VIDEO_RECONFIG events don't redundantly reconfigure. Mirrors the MoltenVK reference path.
    private var lastHDRConfigurationSignature = ""
    /// Screen identity/capability signature, kept separate from the source HDR signature so
    /// Stage Manager layout churn is cheap while a real display migration forces re-evaluation.
    private var lastHDRDisplayEnvironmentSignature = ""
    private var lastTrackListSignature = ""
    private var lastNotifiedSubtitleTrackId: Int?
    var isPausedState: Bool { isPaused }
    var currentTime: Double { gpuRenderer.currentTime }
    var duration: Double { gpuRenderer.duration }
    var supportsBitmapSubtitleTracks: Bool { MPVRenderBackendSupport.metalBitmapSubtitlesAllowed }
    /// True so the PiP sample-buffer renderer is activated (begun, producing frames into the shared display layer)
    /// BEFORE.
    var prefersPictureInPictureLayerActivationBeforeStart: Bool { true }
    /// Human-readable name of the active quality profile ("Sharp" / "Balanced" / "Low Heat").
    /// Read by the performance overlay HUD, mirroring the sample-buffer bridge.
    var activeQualityProfileName: String { qualityProfile.name }

    init(pictureInPictureDisplayLayer: AVSampleBufferDisplayLayer, qualityProfile: MPVMetalSampleBufferQualityProfile) {
        self.qualityProfile = qualityProfile
        self.renderScaleMultiplier = max(0.1, qualityProfile.renderScale)
        gpuRenderer = MPVGPUPlayerRenderer(
            inlineLayer: MPVGPUPlayerMetalLayer(),
            pictureInPictureDisplayLayer: pictureInPictureDisplayLayer,
            options: Self.makeOptions()
        )
        Logger.shared.log("[MPVGPUPlayerBridge] init \(qualityProfile.logDescription)", type: "MPV")
        hostView.backgroundColor = .black
        hostView.isUserInteractionEnabled = false
        hostView.host(gpuRenderer.inlineLayer)
        hostView.onLayoutChange = { [weak self] bounds in
            guard let self else { return }
            self.gpuRenderer.updateInlineLayerLayout(bounds: bounds, contentsScale: self.effectiveContentsScale())
            self.refreshHDRConfigurationForCurrentDisplayIfNeeded(reason: "display-layout")
        }
    }

    /// Native drawable scale of the screen the inline layer is on (falls back to UIScreen.main).
    private func currentBaseContentsScale() -> CGFloat {
        let screen = hostView.window?.screen ?? UIScreen.main
        let scale = screen.nativeScale > 0 ? screen.nativeScale : screen.scale
        return scale > 0 ? scale : 2.0
    }

    /// Native scale x the effective renderScale - the drawable resolution gpu-next renders at.
    private func effectiveContentsScale() -> CGFloat {
        max(0.5, currentBaseContentsScale() * effectiveRenderScaleMultiplier())
    }

    /// The next standard resolution tier strictly above `height` (480/720/1080/1440/2160); returns
    /// `height` unchanged once it is already at/above the top tier.
    private func oneTierAboveHeight(_ height: Int) -> Int {
        for tier in [480, 720, 1080, 1440, 2160] where tier > height { return tier }
        return height
    }

    /// Render-scale multiplier actually used for the drawable.
    private func effectiveRenderScaleMultiplier() -> CGFloat {
        let base = renderScaleMultiplier
        let targetHeight: CGFloat
        switch Settings.shared.mpvUpscalingMode {
        case .oneLevelAlways:
            targetHeight = CGFloat(oneTierAboveHeight(lastKnownSourceHeight))
        case .upscaleTo4K:
            targetHeight = 2160
        case .off, .upscaleTo1080, .auto:
            return base
        }
        guard lastKnownSourceWidth > 0, lastKnownSourceHeight > 0 else {
            return base
        }
        let viewW = hostView.bounds.width
        let viewH = hostView.bounds.height
        guard viewW > 1, viewH > 1 else { return base }
        // Aspect-fit the source into the view to get the video's DISPLAYED height (letterboxed video
        // occupies less than the full view, so the view height alone would over-cap portrait video).
        let srcAspect = CGFloat(lastKnownSourceWidth) / CGFloat(lastKnownSourceHeight)
        let videoDisplayHeightPoints = (viewW / viewH > srcAspect) ? viewH : viewW / srcAspect
        let nativeVideoDrawableHeight = videoDisplayHeightPoints * currentBaseContentsScale()
        guard nativeVideoDrawableHeight > 1 else { return base }
        // Cap the render target; min() keeps the heat profile's downscale and never supersamples beyond the display.
        return min(base, targetHeight / nativeVideoDrawableHeight)
    }

    private static func makeOptions() -> MPVGPUPlayerRendererOptions {
        MPVGPUPlayerRendererOptions(
            maximumPiPFrameSize: CGSize(width: 1280, height: 720),
            preferredPiPFramesPerSecond: 24,
            inlineProfile: "fast",
            hardwareDecoding: "videotoolbox,videotoolbox-copy",
            // HDR/EDR starts off; applyHDRConfiguration() enables passthrough per-content and per the
            // user's HDR Output setting once the colorspace is known (matches the reference path),
            // so SDR content and non-EDR displays are never affected.
            enablesTargetColorspaceHint: false,
            pausesInlineRendererDuringPictureInPicture: true,
            pictureInPictureBackendPreference: .automatic,
            maximumInFlightPictureInPictureFrames: 3,
            pictureInPicturePreparationTimeout: 1,
            additionalMPVOptions: makeAdditionalMPVOptions()
        )
    }

    /// Parity init options the kit's gpu-next renderer doesn't set itself, mirroring the sample-buffer renderer.
    private static func makeAdditionalMPVOptions() -> [String: String] {
        [
            "audio-channels": Settings.shared.mpvSurroundSoundEnabled ? "auto" : "stereo",
            "hwdec-software-fallback": "3",
            "demuxer-thread": "yes",
            "cache": "yes",
            "cache-pause-wait": "5",
            "demuxer-max-bytes": "80M",
            "demuxer-readahead-secs": "10",
            // MoltenVK queue-emulation CPU reduction.
            "vulkan-async-compute": "no",
            "vulkan-async-transfer": "no",
            "vulkan-queue-count": "1",
            "vulkan-swap-mode": "fifo"
        ]
    }

    // MARK: View / layout

    func getRenderingView() -> UIView {
        hostView.host(gpuRenderer.inlineLayer)
        return hostView
    }

    func renderingLayoutDidChange(containerSize: CGSize) {
        let bounds = CGRect(origin: .zero, size: containerSize)
        let apply = { [weak self] in
            guard let self else { return }
            self.hostView.frame = bounds
            self.gpuRenderer.updateInlineLayerLayout(bounds: bounds, contentsScale: self.effectiveContentsScale())
            self.refreshHDRConfigurationForCurrentDisplayIfNeeded(reason: "container-layout")
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    /// Re-applies the current profile's drawable scale to the inline layer (used after a quality
    /// profile change so the new renderScale takes effect without waiting for a layout pass).
    private func reapplyInlineLayout() {
        let apply = { [weak self] in
            guard let self else { return }
            self.gpuRenderer.updateInlineLayerLayout(bounds: self.hostView.bounds, contentsScale: self.effectiveContentsScale())
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    /// Resolves the gpu-next scaler/deband options from the user's Upscaling setting, independent of the heat-quality
    /// profile (which.
    private func resolvedUpscalingScalers() -> (scale: String, cscale: String, dscale: String, deband: String) {
        let cheap = (scale: "bilinear", cscale: "bilinear", dscale: "mitchell", deband: "no")
        // mpv has a known corrupted-frame path when an EWA filter is used for cscale. It is most
        // visible under sustained gpu-next/MoltenVK upscaling as vertical smearing/stale bands.
        // Keep EWA for luma detail, but use the non-EWA Lanczos chroma workaround on iPad.
        let qualityChromaScaler = UIDevice.current.userInterfaceIdiom == .pad ? "lanczos" : "ewa_lanczossoft"
        let quality = (scale: "ewa_lanczossharp", cscale: qualityChromaScaler, dscale: "mitchell", deband: "yes")
        // A 4K cap applies to nearly every common source on iPad. Keep the lighter non-EWA Lanczos
        // scaler for this tier, but enable debanding so the mode matches its advertised behavior.
        let fourK = (scale: "lanczos", cscale: "bilinear", dscale: "mitchell", deband: "yes")
        // Thermal safety: when the heat profile has dropped to its lowest tier (Low Heat = serious/critical thermal, or
        // the user.
        if qualityProfile.name == "Low Heat" { return cheap }
        switch Settings.shared.mpvUpscalingMode {
        case .off:
            return cheap
        case .upscaleTo1080:
            // Only sub-1080p sources benefit; leave already-HD on the cheap path.
            return (lastKnownSourceHeight > 0 && lastKnownSourceHeight < 1080) ? quality : cheap
        case .upscaleTo4K:
            // Only sub-4K sources benefit; leave native 4K+ on the cheap path.
            return (lastKnownSourceHeight > 0 && lastKnownSourceHeight < 2160) ? fourK : cheap
        case .oneLevelAlways, .auto:
            // Both apply the quality scaler to every source; they differ only in render target
            // (effectiveRenderScaleMultiplier caps oneLevelAlways one tier above source), not here.
            return quality
        }
    }

    /// Caches the decoded source dimensions from the kit so the upscaling modes can gate on them.
    /// Called on video-reconfigure (dimensions resolved or changed); load() resets them to 0 first.
    private func refreshSourceVideoDimensions() {
        let d = gpuRenderer.diagnosticsSnapshot()
        let w = Int(d.videoWidth)
        let h = Int(d.videoHeight)
        if w > 0 { lastKnownSourceWidth = w }
        if h > 0 { lastKnownSourceHeight = h }
    }

    /// Applies the active Upscaling mode's gpu-next scalers/deband at runtime.
    private func applyGPUQualityScalers() {
        let s = resolvedUpscalingScalers()
        _ = gpuRenderer.command(["set", "scale", s.scale])
        _ = gpuRenderer.command(["set", "cscale", s.cscale])
        _ = gpuRenderer.command(["set", "dscale", s.dscale])
        _ = gpuRenderer.command(["set", "deband", s.deband])
        let signature = "\(s.scale)/\(s.cscale)/\(s.dscale)/deband=\(s.deband)"
        if signature != lastLoggedScalers {
            lastLoggedScalers = signature
            Logger.shared.log("[MPVGPUPlayerBridge] gpu-next upscaling=\(Settings.shared.mpvUpscalingMode.rawValue) scalers=\(signature) srcH=\(lastKnownSourceHeight) renderScale=\(String(format: "%.2f", renderScaleMultiplier))", type: "MPV")
        }
    }

    /// Live quality profile update for the GPU path (scaler tier + drawable downscale). Returns
    /// true when the render settings actually changed. Mirrors the sample-buffer bridge's
    /// `updateSampleBufferQualityProfile` so the Auto thermal system can drive both renderers.
    @discardableResult
    func updateQualityProfile(_ newProfile: MPVMetalSampleBufferQualityProfile) -> Bool {
        let changed = !qualityProfile.hasSameRenderSettings(as: newProfile)
        qualityProfile = newProfile
        renderScaleMultiplier = max(0.1, newProfile.renderScale)
        if changed {
            // Only push the four `set scale/cscale/dscale/deband` commands when the tier actually changed.
            applyGPUQualityScalers()
            reapplyInlineLayout()
            Logger.shared.log("[MPVGPUPlayerBridge] live gpu-next profile update \(newProfile.logDescription)", type: "MPV")
        }
        return changed
    }

    // MARK: Lifecycle

    func start() throws {
        guard !isRunning else { return }
        callbackGeneration &+= 1
        let callbackGeneration = callbackGeneration
        gpuRenderer.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                guard let self, self.callbackGeneration == callbackGeneration else { return }
                self.handleState(state)
            }
        }
        gpuRenderer.onError = { [weak self] message in
            DispatchQueue.main.async {
                guard let self, self.callbackGeneration == callbackGeneration else { return }
                self.delegate?.renderer(self, didFailWithError: message)
            }
        }
        gpuRenderer.onDiagnostics = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.callbackGeneration == callbackGeneration else { return }
                self.notifyTrackChangesIfNeeded(reason: "diagnostics")
            }
        }
        gpuRenderer.onPictureInPictureStopRequested = { [weak self] reason in
            guard let self,
                  self.callbackGeneration == callbackGeneration,
                  self.isRunning else { return }
            self.pictureInPictureStopRequestHandler?(reason)
        }
        // Re-evaluate HDR/colorspace whenever the decoded video parameters resolve or change
        // (file loaded / VIDEO_RECONFIG). Fired on the main thread by the kit.
        gpuRenderer.onVideoReconfigureForGeneration = { [weak self] generation in
            guard let self,
                  self.callbackGeneration == callbackGeneration,
                  generation == self.gpuLoadGeneration else { return }
            // Source dimensions are now known/updated - refresh the cached size and re-apply
            // scalers so the upscaling modes pick the right scaler for the real resolution.
            self.refreshSourceVideoDimensions()
            self.applyGPUQualityScalers()
            // The "Upscale by one level" render-target cap depends on the source height that just
            // resolved - re-lay out the drawable so its resolution reflects the new cap.
            self.reapplyInlineLayout()
            self.applyHDRConfiguration(reason: "video-reconfigure")
            // Surface whether videotoolbox HW decode actually attached vs a silent software
            // fallback for this file - the decisive signal for the steady-state CPU question.
            self.logDecodeEngagement()
            self.notifyTrackChangesIfNeeded(reason: "video-reconfigure")
            // A paused fresh item can legitimately remain at 0:00 forever. A generation-matched
            // reconfigure is current-item proof even without clock movement, so release the
            // physical-iPad startup fence without accepting stale state from the replaced item.
            self.hasObservedVideoReconfigureForCurrentLoad = true
            self.hasConfirmedFreshPositionForCurrentLoad = true
            self.completeFreshIPadStartupFenceIfNeeded(
                reason: "video-reconfigure",
                currentLoadConfirmed: true
            )
        }
        // Activate the playback audio session (category/mode + preferred multichannel output);
        // the kit renderer doesn't own this.
        ensureAudioSessionActive()
        try gpuRenderer.start()
        // mpv handle now exists - apply the profile's scalers/deband and drawable scale (the
        // init-time `set` calls were no-ops without a handle), then evaluate HDR for the layer.
        applyGPUQualityScalers()
        reapplyInlineLayout()
        isRunning = true
        refreshHDRConfigurationForCurrentDisplayIfNeeded(reason: "start")
        startPositionUpdateTimer()
    }

    func stop() {
        callbackGeneration &+= 1
        gpuLoadGeneration &+= 1
        gpuRenderer.stop()
        stopPositionUpdateTimer()
        gpuRenderer.onStateChange = nil
        gpuRenderer.onError = nil
        gpuRenderer.onDiagnostics = nil
        gpuRenderer.onPictureInPictureStopRequested = nil
        gpuRenderer.onVideoReconfigureForGeneration = nil
        isRunning = false
        isReadyToSeek = false
        isLoading = false
        isAwaitingReadyForCurrentLoad = true
        didLogFreshIPadStartupFence = false
        hasDeferredFreshIPadPlaybackState = false
        hasObservedVideoReconfigureForCurrentLoad = false
        isPictureInPictureActive = false
        setInlineVideoHidden(false)
        lastPositionUpdateAt = 0
        lastHDRConfigurationSignature = ""
        lastHDRDisplayEnvironmentSignature = ""
        lastTrackListSignature = ""
        lastNotifiedSubtitleTrackId = nil
    }

    func waitUntilStopped() async {
        await gpuRenderer.waitUntilStopped()
    }

    func load(url: URL, with preset: PlayerPreset, headers: [String: String]?) {
        gpuLoadGeneration &+= 1
        let generation = gpuLoadGeneration
        currentURL = url
        currentPreset = preset
        currentHeaders = headers
        isReadyToSeek = false
        isLoading = true
        isAwaitingReadyForCurrentLoad = true
        didLogFreshIPadStartupFence = false
        hasDeferredFreshIPadPlaybackState = false
        hasObservedVideoReconfigureForCurrentLoad = false
        // Arm the fresh-load fence: snapshot the kit's (still-stale) cached position so emits stay suppressed until the
        // kit reports a.
        hasConfirmedFreshPositionForCurrentLoad = false
        positionAtLoadStart = gpuRenderer.currentTime
        // New file: force HDR re-evaluation once its colorspace resolves, and forget the previous
        // source size so the upscaling modes re-decide on the next video-reconfigure.
        lastHDRConfigurationSignature = ""
        lastKnownSourceHeight = 0
        lastKnownSourceWidth = 0
        lastLoggedDecode = ""
        lastTrackListSignature = ""
        lastNotifiedSubtitleTrackId = nil
        applyPreset(preset)
        delegate?.renderer(self, didChangeLoading: true)
        gpuRenderer.load(url, headers: headers, generation: generation)
        gpuRenderer.play()
        applySubtitleStyle(lastAppliedSubtitleStyle)
    }

    func reloadCurrentItem() {
        guard let currentURL, let currentPreset else { return }
        load(url: currentURL, with: currentPreset, headers: currentHeaders)
    }

    func applyPreset(_ preset: PlayerPreset) {
        currentPreset = preset
        for command in preset.commands {
            _ = gpuRenderer.command(command)
        }
    }

    func prepareInitialSeek(to seconds: Double?) {
        pendingInitialSeek = seconds.map { max(0, $0) }
        if isReadyToSeek {
            applyPendingInitialSeekIfNeeded(reason: "prepare-ready")
        }
    }

    func performanceOverlaySnapshot() -> String {
        let d = gpuRenderer.diagnosticsSnapshot()
        // Preserve an unavailable/reconfigure instant instead of misreporting it as software.
        let decode: String
        if d.hardwareDecoder.isEmpty {
            decode = "reconfiguring"
        } else if d.hardwareDecoder == "no" {
            decode = "SW"
        } else {
            decode = d.hardwareDecoder
        }
        return "MPV gpu-next \(isPaused ? "paused" : "playing")\(isLoading ? " loading" : "")\npos \(String(format: "%.1f", d.currentTime))/\(String(format: "%.1f", d.duration))\nmode \(d.presentationMode.rawValue) vo=\(d.inlineVideoOutput) api=\(d.inlineGPUAPI) ctx=\(d.inlineGPUContext)\ndecode=\(decode) pixfmt=\(d.videoPixelFormat.isEmpty ? "?" : d.videoPixelFormat)"
    }

    /// Logs whether either ordered VideoToolbox path actually attached for the current file. If
    /// both paths fail, mpv can still drop to libavcodec software decode (CPU-bound and
    /// scene-dependent); this surfaces the resulting state. Read-only diagnostic;
    /// deduped so it logs once per (decoder, pixfmt) change.
    private func logDecodeEngagement() {
        let d = gpuRenderer.diagnosticsSnapshot()
        let hwdec = d.hardwareDecoder.trimmingCharacters(in: .whitespacesAndNewlines)
        let signature = "\(hwdec.isEmpty ? "unavailable" : hwdec)|\(d.videoPixelFormat)"
        guard signature != lastLoggedDecode else { return }
        lastLoggedDecode = signature
        if hwdec.isEmpty {
            Logger.shared.log("[MPVGPUPlayerBridge] decode state unavailable during video reconfigure pixfmt=\(d.videoPixelFormat) src=\(lastKnownSourceWidth)x\(lastKnownSourceHeight) (hwdec-current was not exposed at this instant; this does not prove software decoding)", type: "MPV")
        } else if hwdec == "no" {
            Logger.shared.log("[MPVGPUPlayerBridge] software decode - hwdec-current=no pixfmt=\(d.videoPixelFormat) src=\(lastKnownSourceWidth)x\(lastKnownSourceHeight) (neither VideoToolbox path remained attached; CPU-bound, scene-dependent)", type: "MPV")
        } else {
            Logger.shared.log("[MPVGPUPlayerBridge] hardware decode hwdec-current=\(hwdec) pixfmt=\(d.videoPixelFormat) src=\(lastKnownSourceWidth)x\(lastKnownSourceHeight)", type: "MPV")
        }
    }

    func beginForegroundUIStallRecovery(reason: String) { _ = reason }

    // MARK: Playback

    func play() {
        isPaused = false
        gpuRenderer.play()
        delegate?.renderer(self, didChangePause: false)
        emitPositionUpdate(force: true)
    }

    func pausePlayback() {
        isPaused = true
        gpuRenderer.pause()
        delegate?.renderer(self, didChangePause: true)
        emitPositionUpdate(force: true)
    }

    func togglePause() {
        isPaused ? play() : pausePlayback()
    }

    func seek(to seconds: Double) {
        gpuRenderer.seek(to: seconds)
        emitPositionUpdate(force: true)
    }

    func seek(by seconds: Double) {
        gpuRenderer.seek(by: seconds)
        emitPositionUpdate(force: true)
    }

    func setSpeed(_ speed: Double) {
        gpuRenderer.setSpeed(speed)
    }

    func getSpeed() -> Double {
        gpuRenderer.getSpeed()
    }

    // MARK: Tracks

    func getAudioTracksDetailed() -> [(Int, String, String)] {
        gpuRenderer.audioTracks().map { ($0.id, $0.title, $0.language) }
    }

    func getAudioTracks() -> [(Int, String)] {
        gpuRenderer.audioTracks().map { ($0.id, $0.title) }
    }

    func getCurrentAudioTrackId() -> Int {
        gpuRenderer.currentAudioTrackID()
    }

    func setAudioTrack(id: Int) {
        gpuRenderer.setAudioTrack(id: id)
        // Keep the track UI/caches in sync (parity with the sample-buffer bridge).
        delegate?.rendererDidChangeTracks(self)
    }

    func getSubtitleTracks() -> [(Int, String)] {
        gpuRenderer.subtitleTracks().map { ($0.id, $0.title) }
    }

    func getSubtitleTracksDetailed() -> [(Int, String, String, Bool)] {
        gpuRenderer.subtitleTracks().map { ($0.id, $0.title, $0.codec, false) }
    }

    func getCurrentSubtitleTrackId() -> Int {
        gpuRenderer.currentSubtitleTrackID()
    }

    func setSubtitleTrack(id: Int) {
        gpuRenderer.setSubtitleTrack(id: id)
        lastNotifiedSubtitleTrackId = id
        // Sync the subtitle button state + track menus (parity with the sample-buffer bridge).
        delegate?.renderer(self, subtitleTrackDidChange: id)
        delegate?.rendererDidChangeTracks(self)
    }

    func disableSubtitles() {
        gpuRenderer.disableSubtitles()
        lastNotifiedSubtitleTrackId = -1
        delegate?.renderer(self, subtitleTrackDidChange: -1)
    }

    func refreshSubtitleOverlay() {
        applySubtitleStyle(lastAppliedSubtitleStyle)
    }

    func loadExternalSubtitles(urls: [String], names: [String]?, enforce: Bool) {
        gpuRenderer.loadExternalSubtitles(urls: urls, names: names, selectFirst: enforce)
        delegate?.rendererDidChangeTracks(self)
    }

    func applySubtitleStyle(_ style: SubtitleStyle) {
        lastAppliedSubtitleStyle = style
        gpuRenderer.applySubtitleStyle(
            MPVMetalSampleBufferSubtitleStyle(
                foregroundColor: style.foregroundColor.cgColor,
                strokeColor: style.strokeColor.cgColor,
                strokeWidth: style.strokeWidth,
                fontSize: sampleBufferBumpedSubtitleFontSize(style.fontSize),
                isVisible: style.isVisible
            )
        )
        _ = gpuRenderer.command(["set", "sub-pos", mpvSubtitlePosition(for: style.verticalOffset, maxPosition: 100)])
        _ = gpuRenderer.command(["set", "sub-shadow-offset", "0"])
        _ = gpuRenderer.command(["set", "sub-ass-override", experimentalSubtitleASSOverrideValue(isMetalRenderer: true)])
        _ = gpuRenderer.command(["set", "sub-border-style", style.closedCaptionBackground ? "background-box" : "outline-and-shadow"])
        _ = gpuRenderer.command(["set", "sub-back-color", style.closedCaptionBackground ? "0.0/0.0/0.0/0.75" : "0.0/0.0/0.0/0.0"])
        _ = gpuRenderer.command(["set", "sub-ass-vsfilter-blur-compat", subtitlePerformanceModeActive(isMetalRenderer: true) ? "no" : "yes"])
    }

    func applyAudioFilterChain(_ chain: String) {
        Logger.shared.log("[MPVGPUPlayerBridge] applyAudioFilterChain \(chain.isEmpty ? "(cleared)" : chain)", type: "MPV")
        // Route through the kit so the chain is mirrored onto the PiP renderer (a separate mpv
        // instance) - otherwise comfort audio would be lost while in Picture in Picture.
        gpuRenderer.setAudioFilterChain(chain)
    }

    /// Snapshot for the performance overlay.
    func currentPlaybackDiagnostics() -> MetalPlaybackDiagnostics {
        let d = gpuRenderer.diagnosticsSnapshot()
        let transfer = d.videoTransferFunction.lowercased()
        let primaries = d.videoColorPrimaries.lowercased()
        let isHDR = d.videoSignalPeak > 1.0
            || transfer.contains("pq")
            || transfer.contains("2084")
            || transfer.contains("hlg")
            || primaries.contains("2020")
        let rangeText = isHDR ? (transfer.contains("hlg") ? "HDR HLG" : "HDR PQ") : "SDR"
        let pixelFormat = d.videoPixelFormat.lowercased()
        let highBitDepth = isHDR
            || pixelFormat.contains("10")
            || pixelFormat.contains("12")
            || pixelFormat.contains("16")
        let renderSize: CGSize = (d.videoWidth > 0 && d.videoHeight > 0)
            ? CGSize(width: d.videoWidth, height: d.videoHeight)
            : gpuRenderer.inlineLayer.drawableSize
        let subtitleCodec = gpuRenderer.subtitleTracks().first(where: { $0.selected })?.codec
        return MetalPlaybackDiagnostics(
            renderSize: renderSize,
            isHDR: isHDR,
            dynamicRangeText: rangeText,
            highBitDepthActive: highBitDepth,
            subtitleCodec: subtitleCodec,
            hardwareDecoder: d.hardwareDecoder
        )
    }

    // MARK: Picture in Picture
    //
    // PiP renders through the kit renderer's internal sample-buffer instance into the shared
    // AVSampleBufferDisplayLayer (the same layer the PiPController is bound to). prepare loads &
    // primes that instance; activate performs the inlinetoPiP swap; finish/resume restores inline.

    func canStartSampleBufferPictureInPicture() -> Bool {
        true
    }

    func preparePictureInPicture() async throws {
        try await gpuRenderer.preparePictureInPicture()
        Logger.shared.log(
            "[MPVGPUPlayerBridge] PiP async prepare ready \(pictureInPictureDebugSnapshot())",
            type: "MPV"
        )
    }

    func prepareForPictureInPictureStart() {
        requestLegacyPictureInPicturePreparation(reason: "prepare-pip")
    }

    func finishPictureInPicture() {
        isPictureInPictureActive = false
        setInlineVideoHidden(false)
        gpuRenderer.endPictureInPicture(restoringInlinePlayback: true)
    }

    func finishPictureInPictureAndWait(restoringInlinePlayback: Bool) async -> Bool {
        let expectedCallbackGeneration = callbackGeneration
        let expectedLoadGeneration = gpuLoadGeneration
        isPictureInPictureActive = false
        if restoringInlinePlayback {
            // gpu-next needs an available inline drawable before MPVKit can prove token-zero
            // restoration. Make it visible first, then await the native generation handshake.
            setInlineVideoHidden(false)
        }
        let restored = await gpuRenderer.endPictureInPictureAndWait(
            restoringInlinePlayback: restoringInlinePlayback
        )
        guard restored,
              isRunning,
              callbackGeneration == expectedCallbackGeneration,
              gpuLoadGeneration == expectedLoadGeneration else {
            return false
        }
        return true
    }

    /// Hides/shows the inline gpu-next CAMetalLayer while PiP is active.
    private func setInlineVideoHidden(_ hidden: Bool) {
        let apply: () -> Void = { [weak self] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.gpuRenderer.inlineLayer.isHidden = hidden
            CATransaction.commit()
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    func primePictureInPictureFrames(reason: String) {
        requestLegacyPictureInPicturePreparation(reason: reason)
    }

    private func requestLegacyPictureInPicturePreparation(reason: String) {
        // PlayerRenderer keeps these synchronous entry points for older call sites. Queue the
        // canonical bounded preparation instead of reaching into MPVKit's deprecated prime API.
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.preparePictureInPicture()
                Logger.shared.log(
                    "[MPVGPUPlayerBridge] legacy PiP request ready reason=\(reason) \(self.pictureInPictureDebugSnapshot())",
                    type: "MPV"
                )
            } catch {
                Logger.shared.log(
                    "[MPVGPUPlayerBridge] legacy PiP request failed reason=\(reason) error=\(error)",
                    type: "MPV"
                )
            }
        }
    }

    func activatePictureInPictureLayer() {
        // Guard against re-activation: the start path activates before startPictureInPicture() and
        // the watchdog may call again - beginPictureInPicture isn't re-entrant-safe (it re-seeks).
        guard !isPictureInPictureActive else { return }
        gpuRenderer.beginPictureInPicture()
        isPictureInPictureActive = true
        setInlineVideoHidden(true)
    }

    func isPictureInPicturePrimed() -> Bool {
        switch gpuRenderer.diagnosticsSnapshot().pictureInPictureState {
        case .ready, .active:
            return true
        default:
            return false
        }
    }

    func updatePictureInPictureRenderSize(_ size: CGSize) {
        gpuRenderer.updatePictureInPictureRenderSize(size)
    }

    func waitForPictureInPictureTimelineUpdate() async {
        await gpuRenderer.waitForPictureInPictureTimelineUpdate()
    }

    func setPictureInPictureStopRequestHandler(_ handler: ((String) -> Void)?) {
        pictureInPictureStopRequestHandler = handler
    }

    func resumeForegroundRendering(reason: String) {
        _ = reason
        guard isPictureInPictureActive else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.finishPictureInPictureAndWait(restoringInlinePlayback: true)
        }
    }

    // MARK: HDR / audio session

    /// Detects whether the loaded video is HDR and, honoring the user's HDR Output setting and the
    /// display's EDR capability, switches the inline gpu-next layer between HDR passthrough and SDR.
    /// Mirrors the MoltenVK reference path; safe for SDR sources and deduplicated by signature.
    func applyHDRConfiguration(reason: String) {
        guard isRunning else { return }
        let diagnostics = gpuRenderer.diagnosticsSnapshot()
        let gamma = diagnostics.videoTransferFunction.lowercased()
        let primaries = diagnostics.videoColorPrimaries.lowercased()
        let isHDRSource = diagnostics.videoSignalPeak > 1.0
            || gamma == "pq" || gamma == "hlg" || gamma == "st2084"
            || primaries == "bt.2020"

        let mode = Settings.shared.mpvHDRMode
        let wantsPassthrough: Bool
        switch mode {
        case .sdr:
            wantsPassthrough = false
        case .hdr:
            wantsPassthrough = isHDRSource
        case .auto:
            wantsPassthrough = isHDRSource && displaySupportsEDR()
        }

        let signature = "\(mode.rawValue)|\(gamma)|\(primaries)|\(wantsPassthrough)"
        guard signature != lastHDRConfigurationSignature else { return }
        lastHDRConfigurationSignature = signature

        _ = gpuRenderer.command(["set", "target-colorspace-hint", wantsPassthrough ? "yes" : "no"])
        let layer = gpuRenderer.inlineLayer
        let applyEDR = {
            if #available(iOS 16.0, *) { layer.wantsExtendedDynamicRangeContent = wantsPassthrough }
        }
        if Thread.isMainThread { applyEDR() } else { DispatchQueue.main.async(execute: applyEDR) }

        Logger.shared.log("[MPVGPUPlayerBridge] HDR config reason=\(reason) mode=\(mode.rawValue) gamma=\(gamma.isEmpty ? "nil" : gamma) primaries=\(primaries.isEmpty ? "nil" : primaries) hdrSource=\(isHDRSource) passthrough=\(wantsPassthrough)", type: "MPV")
    }

    private func refreshHDRConfigurationForCurrentDisplayIfNeeded(reason: String) {
        guard isRunning else { return }
        let screen = currentDisplayScreen()
        let supportsEDR: Bool
        if #available(iOS 16.0, *) {
            supportsEDR = screen.potentialEDRHeadroom > 1.0
        } else {
            supportsEDR = false
        }
        let signature = "\(ObjectIdentifier(screen))|\(screen.traitCollection.displayGamut.rawValue)|\(supportsEDR)"
        guard signature != lastHDRDisplayEnvironmentSignature else { return }
        lastHDRDisplayEnvironmentSignature = signature

        // A display migration can leave the source diagnostics unchanged while changing whether
        // automatic passthrough is valid. Bust only the HDR decision cache, not decoder state.
        lastHDRConfigurationSignature = ""
        applyHDRConfiguration(reason: reason)
    }

    private func currentDisplayScreen() -> UIScreen {
        hostView.window?.screen
            ?? UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
            ?? UIScreen.main
    }

    private func displaySupportsEDR() -> Bool {
        guard #available(iOS 16.0, *) else { return false }
        return currentDisplayScreen().potentialEDRHeadroom > 1.0
    }

    private func ensureAudioSessionActive() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
            eclipseApplyPreferredOutputChannels(log: { Logger.shared.log("[MPVGPUPlayerBridge] \($0)", type: "MPV") })
            EclipseAudioRouteWatcher.shared.ensureInstalled()
        } catch {
            Logger.shared.log("[MPVGPUPlayerBridge] failed to activate AVAudioSession: \(error)", type: "MPV")
        }
    }

    func pictureInPictureDebugSnapshot() -> String {
        let d = gpuRenderer.diagnosticsSnapshot()
        let layer = gpuRenderer.pictureInPictureDisplayLayer
        let frameCount = d.pictureInPictureDiagnostics?.frameCount ?? 0
        return "mode=gpu-next-inline presentation=\(d.presentationMode.rawValue) vo=\(d.inlineVideoOutput) api=\(d.inlineGPUAPI) ctx=\(d.inlineGPUContext) running=\(isRunning) paused=\(isPaused) loading=\(isLoading) ready=\(isReadyToSeek) pip=\(isPictureInPictureActive) pos=\(String(format: "%.2f", d.currentTime))/\(String(format: "%.2f", d.duration)) pipFrames=\(frameCount) sourceLayer={hidden=\(layer.isHidden) opacity=\(String(format: "%.2f", layer.opacity)) status=\(layer.status.rawValue) ready=\(layer.isReadyForMoreMediaData) timebase=\(layer.controlTimebase != nil)}"
    }

    // MARK: Position / state

    private func startPositionUpdateTimer() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.startPositionUpdateTimer() }
            return
        }
        positionUpdateTimer?.invalidate()
        let timer = Timer(timeInterval: positionUpdateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.emitPositionUpdate(force: false)
            }
        }
        positionUpdateTimer = timer
        RunLoop.main.add(timer, forMode: .default)
        emitPositionUpdate(force: true)
    }

    private func stopPositionUpdateTimer() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.stopPositionUpdateTimer() }
            return
        }
        positionUpdateTimer?.invalidate()
        positionUpdateTimer = nil
    }

    private func emitPositionUpdate(force: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.emitPositionUpdate(force: force) }
            return
        }
        guard isRunning else { return }
        if shouldFenceFreshIPadStartup {
            let freshPosition = gpuRenderer.currentTime
            if freshPosition.isFinite,
               freshPosition > 0.01,
               abs(freshPosition - positionAtLoadStart) > 0.01 {
                hasConfirmedFreshPositionForCurrentLoad = true
                completeFreshIPadStartupFenceIfNeeded(
                    reason: "fresh-position",
                    currentLoadConfirmed: true
                )
            }
        }
        guard !isAwaitingReadyForCurrentLoad else { return }
        // Apply a resume seek that was deferred until the demuxer published a real duration; a
        // seek against an unknown (0) duration is clamped and dropped, restarting at 0:00.
        if pendingInitialSeek != nil, gpuRenderer.duration > 0 {
            applyPendingInitialSeekIfNeeded(reason: "duration-known")
            return
        }
        // Fresh-load fence: the kit reuses one renderer instance and does NOT reset its cached currentTime/duration
        // across.
        if !hasConfirmedFreshPositionForCurrentLoad {
            if gpuRenderer.currentTime != positionAtLoadStart {
                hasConfirmedFreshPositionForCurrentLoad = true
            } else {
                return
            }
        }
        let now = CACurrentMediaTime()
        guard force || now - lastPositionUpdateAt >= positionUpdateInterval else { return }
        lastPositionUpdateAt = now
        delegate?.renderer(self, didUpdatePosition: gpuRenderer.currentTime, duration: gpuRenderer.duration)
    }

    private func applyPendingInitialSeekIfNeeded(reason: String) {
        guard let initialSeek = pendingInitialSeek else { return }
        if initialSeek > 0, !(gpuRenderer.duration > 0) {
            Logger.shared.log("[MPVGPUPlayerBridge] deferring pending initial seek \(String(format: "%.2f", initialSeek))s reason=\(reason) durationUnknown", type: "MPV")
            return
        }
        pendingInitialSeek = nil
        Logger.shared.log("[MPVGPUPlayerBridge] applying pending initial seek \(String(format: "%.2f", initialSeek))s reason=\(reason)", type: "MPV")
        gpuRenderer.seek(to: initialSeek)
        emitPositionUpdate(force: true)
    }

    private func markReadyIfNeeded(reason: String) {
        guard !isReadyToSeek else { return }
        isReadyToSeek = true
        isAwaitingReadyForCurrentLoad = false
        applyPendingInitialSeekIfNeeded(reason: reason)
        delegate?.renderer(self, didBecomeReadyToSeek: true)
        notifyTrackChangesIfNeeded(reason: "ready-\(reason)")
    }

    /// A nil prepared seek is Eclipse's fresh-playback (0:00) signal. Keep the workaround scoped to
    /// physical iPad behavior and the MoltenVK gpu-next bridge; iPhone, AVPlayer, and resumed
    /// playback keep their existing startup timing. The sample-buffer bridge applies its own
    /// first-frame version of the same fence below.
    private var isPhysicalIPad: Bool {
#if targetEnvironment(simulator)
        return false
#else
        return UIDevice.current.userInterfaceIdiom == .pad
#endif
    }

    private var shouldFenceFreshIPadStartup: Bool {
        isPhysicalIPad
            && currentURL != nil
            && pendingInitialSeek == nil
            && isAwaitingReadyForCurrentLoad
    }

    private func deferFreshIPadStartupIfNeeded(state: String) -> Bool {
        guard shouldFenceFreshIPadStartup else { return false }
        isLoading = true
        hasDeferredFreshIPadPlaybackState = true
        delegate?.renderer(self, didChangeLoading: true)
        if !didLogFreshIPadStartupFence {
            didLogFreshIPadStartupFence = true
            Logger.shared.log(
                "[MPVGPUPlayerBridge] deferring fresh iPad 0:00 startup state=\(state) until current-load video reconfigure or clock movement",
                type: "MPV"
            )
        }
        // FILE_LOADED invokes the kit's state callback before its reconfigure callback, but the
        // bridge intentionally hops state handling to the next main-queue turn. Remembering the
        // token-validated reconfigure closes that ordering window without trusting an old item.
        if hasObservedVideoReconfigureForCurrentLoad {
            completeFreshIPadStartupFenceIfNeeded(
                reason: "video-reconfigure-observed",
                currentLoadConfirmed: true
            )
        }
        return true
    }

    private func completeFreshIPadStartupFenceIfNeeded(
        reason: String,
        currentLoadConfirmed: Bool
    ) {
        guard isPhysicalIPad,
              currentURL != nil,
              pendingInitialSeek == nil,
              hasDeferredFreshIPadPlaybackState,
              currentLoadConfirmed,
              isAwaitingReadyForCurrentLoad else { return }
        Logger.shared.log(
            "[MPVGPUPlayerBridge] completing fresh iPad 0:00 startup fence reason=\(reason)",
            type: "MPV"
        )
        isLoading = false
        hasDeferredFreshIPadPlaybackState = false
        delegate?.renderer(self, didChangeLoading: false)
        delegate?.renderer(self, didChangePause: isPaused)
        markReadyIfNeeded(reason: reason)
    }

    private func notifyTrackChangesIfNeeded(reason: String) {
        let audioTracks = gpuRenderer.audioTracks()
        let subtitleTracks = gpuRenderer.subtitleTracks()
        let selectedAudio = audioTracks.first(where: { $0.selected })?.id ?? gpuRenderer.currentAudioTrackID()
        let selectedSubtitle = subtitleTracks.first(where: { $0.selected })?.id ?? gpuRenderer.currentSubtitleTrackID()
        let audioSignature = audioTracks
            .map { "\($0.id):\($0.title):\($0.language):\($0.selected)" }
            .joined(separator: "|")
        let subtitleSignature = subtitleTracks
            .map { "\($0.id):\($0.title):\($0.language):\($0.codec):\($0.selected)" }
            .joined(separator: "|")
        let signature = "audio=\(selectedAudio)[\(audioSignature)]|sub=\(selectedSubtitle)[\(subtitleSignature)]"

        guard signature != lastTrackListSignature else { return }
        lastTrackListSignature = signature

        guard !audioTracks.isEmpty || !subtitleTracks.isEmpty else { return }
        Logger.shared.log("[MPVGPUPlayerBridge] tracks changed reason=\(reason) audio=\(audioTracks.count) selectedAudio=\(selectedAudio) subs=\(subtitleTracks.count) selectedSub=\(selectedSubtitle)", type: "MPV")

        let previousSubtitleTrackId = lastNotifiedSubtitleTrackId
        if selectedSubtitle != previousSubtitleTrackId {
            lastNotifiedSubtitleTrackId = selectedSubtitle
            if selectedSubtitle >= 0 || previousSubtitleTrackId != nil {
                delegate?.renderer(self, subtitleTrackDidChange: selectedSubtitle)
            }
        }
        delegate?.rendererDidChangeTracks(self)
    }

    private func handleState(_ state: MPVGPUPlayerRendererState) {
        let label = "\(state)"
        if label != lastLoggedState {
            lastLoggedState = label
            Logger.shared.log("[MPVGPUPlayerBridge] state=\(label)", type: "MPV")
        }
        switch state {
        case .starting, .loading:
            isLoading = true
            delegate?.renderer(self, didChangeLoading: true)
        case .playing:
            isPaused = false
            if deferFreshIPadStartupIfNeeded(state: "playing") { return }
            isLoading = false
            delegate?.renderer(self, didChangeLoading: false)
            delegate?.renderer(self, didChangePause: false)
            markReadyIfNeeded(reason: "playing")
        case .paused:
            isPaused = true
            if deferFreshIPadStartupIfNeeded(state: "paused") {
                return
            }
            isLoading = false
            delegate?.renderer(self, didChangeLoading: false)
            delegate?.renderer(self, didChangePause: true)
            // A load can settle straight into .paused (e.g. PiP entered while paused) without
            // passing through .playing, so mark ready here too or the resume seek never lands.
            if currentURL != nil { markReadyIfNeeded(reason: "paused") }
        case .pictureInPicture:
            isLoading = false
            delegate?.renderer(self, didChangeLoading: false)
        case .ready:
            isLoading = false
            delegate?.renderer(self, didChangeLoading: false)
        case .failed(let message):
            delegate?.renderer(self, didFailWithError: message)
        case .idle, .stopping, .stopped:
            break
        }
    }
}
#endif

#if ECLIPSE_MPVKIT_MOLTENVK_INLINE_RENDERER && ECLIPSE_MPVKIT_SAMPLE_BUFFER_PIP_BRIDGE
struct MPVMetalSampleBufferQualityProfile: Equatable {
    let name: String
    let maximumFrameSize: CGSize
    let preferredPiPFramesPerSecond: Int
    /// Enables the expensive rgba64 -> RGBA16F HDR sample-buffer route.
    /// Low Heat disables it so HDR falls back to the cheaper BGRA presentation path.
    let allowsHighBitDepthHDR: Bool
    /// Fraction of the native drawable resolution the inline MoltenVK surface is rendered at.
    /// 1.0 = full native pixels; lower values reduce fragment-shader work (and therefore heat)
    /// by rendering a smaller surface that CAMetalLayer upscales to the view bounds.
    let renderScale: CGFloat
    let reason: String

    private static let fullQualityMaximumFrameSize = CGSize(width: 3840, height: 2160)

    var logDescription: String {
        let sizeText = "\(Int(maximumFrameSize.width))x\(Int(maximumFrameSize.height))"
        let scaleText = String(format: "%.2f", renderScale)
        return "profile=\(name) maxFrame=\(sizeText) renderScale=\(scaleText) pipCap=\(preferredPiPFramesPerSecond) highBitDepthHDR=\(allowsHighBitDepthHDR) reason=\(reason)"
    }

    func hasSameRenderSettings(as other: MPVMetalSampleBufferQualityProfile) -> Bool {
        maximumFrameSize == other.maximumFrameSize
            && preferredPiPFramesPerSecond == other.preferredPiPFramesPerSecond
            && allowsHighBitDepthHDR == other.allowsHighBitDepthHDR
            && abs(renderScale - other.renderScale) < 0.001
    }

    static func sharp(reason: String) -> MPVMetalSampleBufferQualityProfile {
        MPVMetalSampleBufferQualityProfile(
            name: "Sharp",
            maximumFrameSize: fullQualityMaximumFrameSize,
            preferredPiPFramesPerSecond: 30,
            allowsHighBitDepthHDR: true,
            renderScale: 1.0,
            reason: reason
        )
    }

    static func balanced(reason: String) -> MPVMetalSampleBufferQualityProfile {
        MPVMetalSampleBufferQualityProfile(
            name: "Balanced",
            maximumFrameSize: CGSize(width: 2560, height: 1440),
            preferredPiPFramesPerSecond: 30,
            allowsHighBitDepthHDR: true,
            renderScale: 0.82,
            reason: reason
        )
    }

    static func lowHeat(reason: String) -> MPVMetalSampleBufferQualityProfile {
        MPVMetalSampleBufferQualityProfile(
            name: "Low Heat",
            maximumFrameSize: CGSize(width: 1600, height: 900),
            preferredPiPFramesPerSecond: 24,
            allowsHighBitDepthHDR: false,
            renderScale: 0.62,
            reason: reason
        )
    }

}

final class MPVSampleBufferPiPBridge: PlayerRenderer {
    enum RendererError: Error {
        case sampleBufferUnavailable
    }

    static var isAvailable: Bool {
        MPVMetalSampleBufferRenderer.isSupported
    }

    weak var delegate: MPVNativeRendererDelegate?

    private let displayLayer: AVSampleBufferDisplayLayer
    private let sampleRenderer: MPVMetalSampleBufferRenderer
    private var qualityProfile: MPVMetalSampleBufferQualityProfile
    /// While the player UI/menus are on screen, the main-thread software render is throttled to
    /// this frame rate so the UI (which shares the main thread with the render) stays responsive.
    private var isInteractiveRenderThrottleActive = false
    private static let interactiveThrottleFPS = 30
    private let placeholderView = UIView(frame: .zero)
    private var currentPreset: PlayerPreset?
    private var currentURL: URL?
    private var currentHeaders: [String: String]?
    private var pendingInitialSeek: Double?
    private var lastAppliedSubtitleStyle: SubtitleStyle = .default
    private var isRunning = false
    private var isPaused = true
    private var isReadyToSeek = false
    private var isLoading = false
    private var isAwaitingReadyForCurrentLoad = true
    private var sampleBufferLoadGeneration = 0
    /// Invalidates callbacks queued by a previous start/stop cycle before they reach the host.
    private var callbackGeneration: UInt64 = 0
    private var didLogFreshIPadStartupFence = false
    private var hasDeferredFreshIPadPlaybackState = false
    private var positionUpdateTimer: Timer?
    private var lastPositionUpdateAt: CFTimeInterval = 0
    private let positionUpdateInterval: CFTimeInterval = 0.5
    private var lastLoggedSampleBufferState = ""
    private var lastLoggedDiagnosticsFrameCount = 0
    private var lastLoggedDiagnosticsFailures = 0

    var isPausedState: Bool { isPaused }
    var currentTime: Double { sampleRenderer.currentTime }
    var duration: Double { sampleRenderer.duration }
    /// Human-readable name of the quality profile currently driving the sample-buffer
    /// renderer ("Sharp" / "Balanced" / "Low Heat"). Read by the performance overlay HUD.
    var activeQualityProfileName: String { qualityProfile.name }
    var supportsBitmapSubtitleTracks: Bool {
        MPVRenderBackendSupport.metalBitmapSubtitlesAllowed
    }
    var prefersPictureInPictureLayerActivationBeforeStart: Bool { false }

    init(displayLayer: AVSampleBufferDisplayLayer, qualityProfile: MPVMetalSampleBufferQualityProfile) {
        self.displayLayer = displayLayer
        self.qualityProfile = qualityProfile
        let screen = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }
            .first ?? UIScreen.main
        let nativeScale = screen.nativeScale > 0 ? screen.nativeScale : screen.scale
        let configuration = Self.sampleBufferConfiguration(for: qualityProfile, screen: screen)
        let targetFPS = configuration.targetFPS
        let pipFramesPerSecond = configuration.pipFramesPerSecond
        let options = configuration.options
        self.sampleRenderer = MPVMetalSampleBufferRenderer(displayLayer: displayLayer, options: options)
        Logger.shared.log("[MPVSampleBufferPiPBridge] configured sample-buffer fps=\(targetFPS) pipFPS=\(pipFramesPerSecond) \(qualityProfile.logDescription)", type: "MPV")
        placeholderView.backgroundColor = .clear
        placeholderView.isUserInteractionEnabled = false
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        displayLayer.contentsScale = nativeScale
    }

    func getRenderingView() -> UIView {
        // The single MPV handle renders into displayLayer for both inline and PiP, so
        // host the layer inside the rendering view and keep it visible for inline
        // playback. (renderingLayoutDidChange keeps its frame synced to the container.)
        if displayLayer.superlayer !== placeholderView.layer {
            displayLayer.removeFromSuperlayer()
            displayLayer.frame = placeholderView.bounds
            displayLayer.zPosition = 0
            placeholderView.layer.addSublayer(displayLayer)
        }
        displayLayer.isHidden = false
        displayLayer.opacity = 1.0
        return placeholderView
    }

    func renderingLayoutDidChange(containerSize: CGSize) {
        let updateLayout = { [weak self] in
            guard let self else { return }
            let screen = self.placeholderView.window?.screen ?? UIScreen.main
            let scale = screen.nativeScale > 0 ? screen.nativeScale : screen.scale
            self.displayLayer.contentsScale = scale
            self.displayLayer.frame = CGRect(origin: .zero, size: containerSize)
            if self.isRunning {
                self.sampleRenderer.primeFrames(reason: "layout-change", count: 2)
            }
        }
        if Thread.isMainThread {
            updateLayout()
        } else {
            DispatchQueue.main.async(execute: updateLayout)
        }
    }

    func start() throws {
        guard !isRunning else { return }
        callbackGeneration &+= 1
        let callbackGeneration = callbackGeneration
        sampleRenderer.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                guard let self, self.callbackGeneration == callbackGeneration else { return }
                self.handleSampleBufferState(state)
            }
        }
        sampleRenderer.onError = { [weak self] message in
            DispatchQueue.main.async {
                guard let self, self.callbackGeneration == callbackGeneration else { return }
                self.delegate?.renderer(self, didFailWithError: message)
            }
        }
        sampleRenderer.onDiagnostics = { [weak self] diagnostics in
            guard let self else { return }
            let generation = self.sampleBufferLoadGeneration
            DispatchQueue.main.async {
                guard self.callbackGeneration == callbackGeneration,
                      self.sampleBufferLoadGeneration == generation else { return }
                self.logDiagnosticsIfNeeded(diagnostics)
                let liveDiagnostics = self.sampleRenderer.diagnosticsSnapshot()
                self.completeFreshIPadStartupFenceIfNeeded(
                    reason: "first-frame",
                    currentLoadConfirmed: liveDiagnostics.frameCount > 0
                )
            }
        }
        try sampleRenderer.start()
        isRunning = true
        startPositionUpdateTimer()
    }

    func stop() {
        callbackGeneration &+= 1
        sampleRenderer.stop()
        stopPositionUpdateTimer()
        sampleRenderer.onStateChange = nil
        sampleRenderer.onError = nil
        sampleRenderer.onDiagnostics = nil
        isRunning = false
        isReadyToSeek = false
        isLoading = false
        isAwaitingReadyForCurrentLoad = true
        sampleBufferLoadGeneration += 1
        didLogFreshIPadStartupFence = false
        hasDeferredFreshIPadPlaybackState = false
        lastPositionUpdateAt = 0
        lastLoggedSampleBufferState = ""
        lastLoggedDiagnosticsFrameCount = 0
        lastLoggedDiagnosticsFailures = 0
    }

    func waitUntilStopped() async {
        await sampleRenderer.waitUntilStopped()
    }

    func load(url: URL, with preset: PlayerPreset, headers: [String: String]?) {
        currentURL = url
        currentPreset = preset
        currentHeaders = headers
        sampleBufferLoadGeneration += 1
        applyPreset(preset)
        isReadyToSeek = false
        isLoading = true
        isAwaitingReadyForCurrentLoad = true
        didLogFreshIPadStartupFence = false
        hasDeferredFreshIPadPlaybackState = false
        delegate?.renderer(self, didChangeLoading: true)
        sampleRenderer.load(url, headers: headers)
        sampleRenderer.play()
    }

    func reloadCurrentItem() {
        guard let currentURL, let currentPreset else { return }
        load(url: currentURL, with: currentPreset, headers: currentHeaders)
    }

    func applyPreset(_ preset: PlayerPreset) {
        currentPreset = preset
        for command in preset.commands {
            _ = sampleRenderer.command(command)
        }
    }

    func prepareInitialSeek(to seconds: Double?) {
        pendingInitialSeek = seconds.map { max(0, $0) }
        if isReadyToSeek {
            applyPendingInitialSeekIfNeeded(reason: "prepare-ready")
        }
    }

    func performanceOverlaySnapshot() -> String {
        let snapshot = sampleRenderer.diagnosticsSnapshot()
        return "MPV sample-buffer-pip \(isPaused ? "paused" : "playing")\(isLoading ? " loading" : "") \(qualityProfile.name)\npos \(String(format: "%.1f", sampleRenderer.currentTime))/\(String(format: "%.1f", sampleRenderer.duration))\nframes \(snapshot.frameCount) attempts \(snapshot.renderAttemptCount) failures \(snapshot.renderFailureCount)\nlayer \(snapshot.displayLayerStatus) ready=\(snapshot.displayLayerReadyForMoreMediaData) moltenVKProbe=\(snapshot.metalCompatibilityProbeSucceeded)\nbackend \(snapshot.presentationBackend.rawValue) api=\(snapshot.renderAPI) source=\(snapshot.sourcePixelFormatDescription) pixel=\(snapshot.pixelFormatDescription) hdr=\(snapshot.hdrMetadataApplied) highBitDepth=\(snapshot.highBitDepthRenderingActive) highBitDepthFailures=\(snapshot.highBitDepthRenderingFailureCount) moltenVKFrames=\(snapshot.metalPresentationFrameCount) moltenVKFailures=\(snapshot.metalPresentationFailureCount)"
    }

#if ECLIPSE_MPVKIT_METAL_LIVE_QUALITY_RECONFIGURE
    @discardableResult
    func updateSampleBufferQualityProfile(_ newProfile: MPVMetalSampleBufferQualityProfile) -> Bool {
        guard !qualityProfile.hasSameRenderSettings(as: newProfile) else {
            qualityProfile = newProfile
            return false
        }
        let screen = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }
            .first ?? UIScreen.main
        let configuration = Self.sampleBufferConfiguration(for: newProfile, screen: screen)
        qualityProfile = newProfile
        var options = configuration.options
        // Keep the interactive throttle in effect if a thermal profile change lands while the
        // player UI is up, so the menus don't briefly jump back to the full render rate.
        if isInteractiveRenderThrottleActive {
            options.preferredFramesPerSecond = min(options.preferredFramesPerSecond, Self.interactiveThrottleFPS)
        }
        sampleRenderer.updateOptions(options)
        Logger.shared.log("[MPVSampleBufferPiPBridge] live sample-buffer profile update fps=\(options.preferredFramesPerSecond) pipFPS=\(configuration.pipFramesPerSecond) throttled=\(isInteractiveRenderThrottleActive) \(newProfile.logDescription)", type: "MPV")
        return true
    }
#endif

    func play() {
        isPaused = false
        sampleRenderer.play()
        delegate?.renderer(self, didChangePause: false)
        emitPositionUpdate(force: true)
    }

    func pausePlayback() {
        isPaused = true
        sampleRenderer.pause()
        delegate?.renderer(self, didChangePause: true)
        emitPositionUpdate(force: true)
    }

    func togglePause() {
        isPaused ? play() : pausePlayback()
    }

    func seek(to seconds: Double) {
        sampleRenderer.seek(to: seconds)
        emitPositionUpdate(force: true)
    }

    func seek(by seconds: Double) {
        sampleRenderer.seek(by: seconds)
        emitPositionUpdate(force: true)
    }

    func setSpeed(_ speed: Double) {
        sampleRenderer.setSpeed(speed)
    }

    func getSpeed() -> Double {
        sampleRenderer.getSpeed()
    }

    /// Mutes this renderer when it is embedded as a warm hybrid PiP bridge.
    /// The direct sample-buffer path does not call this because inline and PiP
    /// are the same mpv instance.
    func setAudioMuted(_ muted: Bool) {
        _ = sampleRenderer.command(["set", "mute", muted ? "yes" : "no"])
    }

    func getAudioTracksDetailed() -> [(Int, String, String)] {
        sampleRenderer.audioTracks().map { ($0.id, $0.title, $0.language) }
    }

    func getAudioTracks() -> [(Int, String)] {
        sampleRenderer.audioTracks().map { ($0.id, $0.title) }
    }

    func getCurrentAudioTrackId() -> Int {
        sampleRenderer.currentAudioTrackID()
    }

    func setAudioTrack(id: Int) {
        sampleRenderer.setAudioTrack(id: id)
        delegate?.rendererDidChangeTracks(self)
    }

    func getSubtitleTracks() -> [(Int, String)] {
        sampleRenderer.subtitleTracks().map { ($0.id, $0.title) }
    }

    func getSubtitleTracksDetailed() -> [(Int, String, String, Bool)] {
        sampleRenderer.subtitleTracks().map { ($0.id, $0.title, $0.codec, false) }
    }

    func getCurrentSubtitleTrackId() -> Int {
        sampleRenderer.currentSubtitleTrackID()
    }

    func setSubtitleTrack(id: Int) {
        sampleRenderer.setSubtitleTrack(id: id)
        delegate?.renderer(self, subtitleTrackDidChange: id)
        delegate?.rendererDidChangeTracks(self)
    }

    func disableSubtitles() {
        sampleRenderer.disableSubtitles()
        delegate?.renderer(self, subtitleTrackDidChange: -1)
    }

    func refreshSubtitleOverlay() {
        applySubtitleStyle(lastAppliedSubtitleStyle)
    }

    func loadExternalSubtitles(urls: [String], names: [String]?, enforce: Bool) {
        sampleRenderer.loadExternalSubtitles(urls: urls, names: names, selectFirst: enforce)
        delegate?.rendererDidChangeTracks(self)
    }

    func applySubtitleStyle(_ style: SubtitleStyle) {
        lastAppliedSubtitleStyle = style
        sampleRenderer.applySubtitleStyle(
            MPVMetalSampleBufferSubtitleStyle(
                foregroundColor: style.foregroundColor.cgColor,
                strokeColor: style.strokeColor.cgColor,
                strokeWidth: style.strokeWidth,
                fontSize: sampleBufferBumpedSubtitleFontSize(style.fontSize),
                isVisible: style.isVisible
            )
        )
        _ = sampleRenderer.command(["set", "sub-pos", mpvSubtitlePosition(for: style.verticalOffset, maxPosition: 100)])
        _ = sampleRenderer.command(["set", "sub-shadow-offset", "0"])
        _ = sampleRenderer.command(["set", "sub-ass-override", experimentalSubtitleASSOverrideValue(isMetalRenderer: true)])
        _ = sampleRenderer.command(["set", "sub-border-style", style.closedCaptionBackground ? "background-box" : "outline-and-shadow"])
        _ = sampleRenderer.command(["set", "sub-back-color", style.closedCaptionBackground ? "0.0/0.0/0.0/0.75" : "0.0/0.0/0.0/0.0"])
        // Subtitle performance mode: also stop libass blur from scaling with the render resolution, so any inline
        // blur/edges that.
        _ = sampleRenderer.command(["set", "sub-ass-vsfilter-blur-compat", subtitlePerformanceModeActive(isMetalRenderer: true) ? "no" : "yes"])
    }

    func applyAudioFilterChain(_ chain: String) {
        Logger.shared.log("[MPVSampleBufferPiPBridge] applyAudioFilterChain \(chain.isEmpty ? "(cleared)" : chain)", type: "MPV")
        _ = sampleRenderer.command(["set", "af", chain])
    }

    /// Snapshot of what the sample-buffer renderer is currently decoding/rendering, for the
    /// performance overlay. Derived entirely from the renderer's existing public diagnostics -
    /// no extra mpv work beyond one track-list read.
    func currentPlaybackDiagnostics() -> MetalPlaybackDiagnostics {
        let diag = sampleRenderer.diagnosticsSnapshot()
        let transfer = diag.videoTransferFunction.lowercased()
        let primaries = diag.videoColorPrimaries.lowercased()
        let isHDR = diag.videoSignalPeak > 1.0
            || transfer.contains("pq")
            || transfer.contains("2084")
            || transfer.contains("hlg")
            || primaries.contains("2020")
        let rangeText = isHDR ? (transfer.contains("hlg") ? "HDR HLG" : "HDR PQ") : "SDR"
        let subtitleCodec = sampleRenderer.subtitleTracks().first(where: { $0.selected })?.codec
        return MetalPlaybackDiagnostics(
            renderSize: diag.lastFrameSize,
            isHDR: isHDR,
            dynamicRangeText: rangeText,
            highBitDepthActive: diag.highBitDepthRenderingActive,
            subtitleCodec: subtitleCodec,
            hardwareDecoder: nil
        )
    }

    func canStartSampleBufferPictureInPicture() -> Bool {
        true
    }

    func prepareForPictureInPictureStart() {
        displayLayer.isHidden = false
        displayLayer.opacity = 1.0
        sampleRenderer.primeFrames(reason: "enter-pip", count: 8)
    }

    func finishPictureInPicture() {
        exposePictureInPictureLayerInline()
    }

    func finishPictureInPictureAndWait(restoringInlinePlayback: Bool) async -> Bool {
        let expectedCallbackGeneration = callbackGeneration
        let expectedLoadGeneration = sampleBufferLoadGeneration
        if restoringInlinePlayback {
            // The same display layer serves inline playback and AVKit. Expose it before waiting so
            // the awaited current-generation sample is actually eligible for inline presentation.
            exposePictureInPictureLayerInline()
        }
        let restored = await sampleRenderer.waitForTimelineUpdate(requiringCurrentFrame: true)
        guard restored,
              isRunning,
              callbackGeneration == expectedCallbackGeneration,
              sampleBufferLoadGeneration == expectedLoadGeneration else {
            return false
        }
        return true
    }

    private func exposePictureInPictureLayerInline() {
        displayLayer.isHidden = false
        displayLayer.opacity = 1.0
        displayLayer.zPosition = 0
    }

    func primePictureInPictureFrames(reason: String) {
        sampleRenderer.primeFrames(reason: reason, count: 6)
    }

    func activatePictureInPictureLayer() {
        displayLayer.isHidden = false
        displayLayer.opacity = 1.0
        displayLayer.zPosition = 1
        sampleRenderer.primeFrames(reason: "activate-pip", count: 4)
    }

    func isPictureInPicturePrimed() -> Bool {
        sampleRenderer.diagnosticsSnapshot().frameCount > 0
    }

    func waitForPictureInPictureTimelineUpdate() async {
        _ = await sampleRenderer.waitForTimelineUpdate(requiringCurrentFrame: true)
    }

    func resumeForegroundRendering(reason: String) {
        _ = reason
        exposePictureInPictureLayerInline()
    }

    func pictureInPictureDebugSnapshot() -> String {
        let snapshot = sampleRenderer.diagnosticsSnapshot()
        return "mode=sample-buffer-pip backend=\(snapshot.presentationBackend.rawValue) api=\(snapshot.renderAPI) source=\(snapshot.sourcePixelFormatDescription) pixel=\(snapshot.pixelFormatDescription) hdr=\(snapshot.hdrMetadataApplied) highBitDepth=\(snapshot.highBitDepthRenderingActive) highBitDepthFailures=\(snapshot.highBitDepthRenderingFailureCount) primaries=\(snapshot.videoColorPrimaries.isEmpty ? "unknown" : snapshot.videoColorPrimaries) transfer=\(snapshot.videoTransferFunction.isEmpty ? "unknown" : snapshot.videoTransferFunction) sigPeak=\(String(format: "%.2f", snapshot.videoSignalPeak)) running=\(isRunning) paused=\(isPaused) loading=\(isLoading) ready=\(isReadyToSeek) pos=\(String(format: "%.2f", sampleRenderer.currentTime))/\(String(format: "%.2f", sampleRenderer.duration)) frames=\(snapshot.frameCount) attempts=\(snapshot.renderAttemptCount) failures=\(snapshot.renderFailureCount) moltenVKFrames=\(snapshot.metalPresentationFrameCount) moltenVKFailures=\(snapshot.metalPresentationFailureCount) layer=\(snapshot.displayLayerStatus) moltenVKProbe=\(snapshot.metalCompatibilityProbeSucceeded)"
    }

    func beginForegroundUIStallRecovery(reason: String) {
        _ = reason
    }

    /// Throttle the main-thread software render to a low frame rate while the player UI/menus are visible, then restore
    /// the current.
    func setInteractiveRenderThrottle(_ throttled: Bool) {
        guard isInteractiveRenderThrottleActive != throttled else { return }
        isInteractiveRenderThrottleActive = throttled
        let screen = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }
            .first ?? UIScreen.main
        var options = Self.sampleBufferConfiguration(for: qualityProfile, screen: screen).options
        if throttled {
            options.preferredFramesPerSecond = min(options.preferredFramesPerSecond, Self.interactiveThrottleFPS)
        }
        sampleRenderer.updateOptions(options)
    }

    private static func sampleBufferConfiguration(
        for qualityProfile: MPVMetalSampleBufferQualityProfile,
        screen: UIScreen
    ) -> (options: MPVMetalSampleBufferRendererOptions, targetFPS: Int, pipFramesPerSecond: Int) {
        let configuredFPS = Settings.shared.mpvForegroundFPS
        let targetFPS = max(1, min(screen.maximumFramesPerSecond, configuredFPS))
        let pipFramesPerSecond = min(targetFPS, qualityProfile.preferredPiPFramesPerSecond)
        let options = MPVMetalSampleBufferRendererOptions(
            maximumFrameSize: qualityProfile.maximumFrameSize,
            preferredFramesPerSecond: targetFPS,
            preferredPiPFramesPerSecond: pipFramesPerSecond,
            prefersHighBitDepthRendering: qualityProfile.allowsHighBitDepthHDR
        )
        return (options, targetFPS, pipFramesPerSecond)
    }

    private func startPositionUpdateTimer() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.startPositionUpdateTimer()
            }
            return
        }
        positionUpdateTimer?.invalidate()
        let timer = Timer(timeInterval: positionUpdateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.emitPositionUpdate(force: false)
            }
        }
        positionUpdateTimer = timer
        RunLoop.main.add(timer, forMode: .default)
        emitPositionUpdate(force: true)
    }

    private func stopPositionUpdateTimer() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.stopPositionUpdateTimer()
            }
            return
        }
        positionUpdateTimer?.invalidate()
        positionUpdateTimer = nil
    }

    private func emitPositionUpdate(force: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.emitPositionUpdate(force: force)
            }
            return
        }
        guard isRunning else { return }
        if shouldFenceFreshIPadStartup {
            let freshPosition = sampleRenderer.currentTime
            completeFreshIPadStartupFenceIfNeeded(
                reason: "fresh-position",
                currentLoadConfirmed: freshPosition.isFinite && freshPosition > 0.01
            )
        }
        guard !isAwaitingReadyForCurrentLoad else { return }
        // Apply a resume seek that was deferred because the duration wasn't known yet
        // (see applyPendingInitialSeekIfNeeded). Once the demuxer reports a real
        // duration the seek lands correctly instead of being dropped against 0.
        if pendingInitialSeek != nil, sampleRenderer.duration > 0 {
            applyPendingInitialSeekIfNeeded(reason: "duration-known")
            return
        }
        let now = CACurrentMediaTime()
        guard force || now - lastPositionUpdateAt >= positionUpdateInterval else { return }
        lastPositionUpdateAt = now
        delegate?.renderer(self, didUpdatePosition: sampleRenderer.currentTime, duration: sampleRenderer.duration)
    }

    private func applyPendingInitialSeekIfNeeded(reason: String) {
        guard let initialSeek = pendingInitialSeek else { return }
        // The sample-buffer renderer reports .ready/.playing as soon as the first frame is decodable, which can be
        // *before* the demuxer.
        if initialSeek > 0, !(sampleRenderer.duration > 0) {
            Logger.shared.log("[MPVSampleBufferPiPBridge] deferring pending initial seek \(String(format: "%.2f", initialSeek))s reason=\(reason) durationUnknown", type: "MPV")
            return
        }
        pendingInitialSeek = nil
        Logger.shared.log("[MPVSampleBufferPiPBridge] applying pending initial seek \(String(format: "%.2f", initialSeek))s reason=\(reason)", type: "MPV")
        sampleRenderer.seek(to: initialSeek)
        emitPositionUpdate(force: true)
    }

    private var isPhysicalIPad: Bool {
#if targetEnvironment(simulator)
        return false
#else
        return UIDevice.current.userInterfaceIdiom == .pad
#endif
    }

    private var shouldFenceFreshIPadStartup: Bool {
        isPhysicalIPad
            && currentURL != nil
            && pendingInitialSeek == nil
            && isAwaitingReadyForCurrentLoad
    }

    private func deferFreshIPadStartupIfNeeded(state: String) -> Bool {
        guard shouldFenceFreshIPadStartup else { return false }
        isLoading = true
        hasDeferredFreshIPadPlaybackState = true
        delegate?.renderer(self, didChangeLoading: true)
        if !didLogFreshIPadStartupFence {
            didLogFreshIPadStartupFence = true
            Logger.shared.log(
                "[MPVSampleBufferPiPBridge] deferring fresh iPad 0:00 startup state=\(state) until first current-load frame or clock movement",
                type: "MPV"
            )
        }
        return true
    }

    private func completeFreshIPadStartupFenceIfNeeded(
        reason: String,
        currentLoadConfirmed: Bool
    ) {
        guard shouldFenceFreshIPadStartup,
              hasDeferredFreshIPadPlaybackState,
              currentLoadConfirmed else { return }
        Logger.shared.log(
            "[MPVSampleBufferPiPBridge] completing fresh iPad 0:00 startup fence reason=\(reason)",
            type: "MPV"
        )
        isLoading = false
        hasDeferredFreshIPadPlaybackState = false
        delegate?.renderer(self, didChangeLoading: false)
        delegate?.renderer(self, didChangePause: isPaused)
        isReadyToSeek = true
        isAwaitingReadyForCurrentLoad = false
        applyPendingInitialSeekIfNeeded(reason: reason)
        delegate?.renderer(self, didBecomeReadyToSeek: true)
    }

    private func handleSampleBufferState(_ state: MPVMetalSampleBufferRendererState) {
        logStateIfNeeded(state)
        switch state {
        case .loading, .starting:
            isLoading = true
            delegate?.renderer(self, didChangeLoading: true)
        case .playing:
            isPaused = false
            if deferFreshIPadStartupIfNeeded(state: "playing") { return }
            isLoading = false
            delegate?.renderer(self, didChangeLoading: false)
            delegate?.renderer(self, didChangePause: false)
            if !isReadyToSeek {
                isReadyToSeek = true
                isAwaitingReadyForCurrentLoad = false
                applyPendingInitialSeekIfNeeded(reason: "playing")
                delegate?.renderer(self, didBecomeReadyToSeek: true)
            }
        case .paused:
            isPaused = true
            if deferFreshIPadStartupIfNeeded(state: "paused") { return }
            isLoading = false
            delegate?.renderer(self, didChangeLoading: false)
            delegate?.renderer(self, didChangePause: true)
            // A load can settle straight into .paused (e.g. entering PiP while
            // paused) without ever passing through .playing/.ready. Without this,
            // the pending resume seek is never applied and position updates stay
            // gated, so PiP would start at 0:00.
            if currentURL != nil, !isReadyToSeek {
                isReadyToSeek = true
                isAwaitingReadyForCurrentLoad = false
                applyPendingInitialSeekIfNeeded(reason: "paused")
                delegate?.renderer(self, didBecomeReadyToSeek: true)
            }
        case .ready:
            if deferFreshIPadStartupIfNeeded(state: "ready") { return }
            isLoading = false
            delegate?.renderer(self, didChangeLoading: false)
            if currentURL != nil, !isReadyToSeek {
                isReadyToSeek = true
                isAwaitingReadyForCurrentLoad = false
                applyPendingInitialSeekIfNeeded(reason: "ready")
                delegate?.renderer(self, didBecomeReadyToSeek: true)
            }
        case .failed(let message):
            isLoading = false
            delegate?.renderer(self, didChangeLoading: false)
            delegate?.renderer(self, didFailWithError: message)
        case .idle, .stopping, .stopped:
            break
        }
    }

    private func logStateIfNeeded(_ state: MPVMetalSampleBufferRendererState) {
        let label: String
        switch state {
        case .idle: label = "idle"
        case .starting: label = "starting"
        case .loading: label = "loading"
        case .ready: label = "ready"
        case .playing: label = "playing"
        case .paused: label = "paused"
        case .stopping: label = "stopping"
        case .stopped: label = "stopped"
        case .failed(let message): label = "failed:\(message)"
        }
        guard label != lastLoggedSampleBufferState else { return }
        lastLoggedSampleBufferState = label
        Logger.shared.log("[MPVSampleBufferPiPBridge] state=\(label) pos=\(String(format: "%.2f", sampleRenderer.currentTime))/\(String(format: "%.2f", sampleRenderer.duration)) layer={\(pictureInPictureDebugSnapshot())}", type: "MPV")
    }

    private func logDiagnosticsIfNeeded(_ diagnostics: MPVMetalSampleBufferRendererDiagnostics) {
        let totalFailures = diagnostics.renderFailureCount + diagnostics.allocationFailureCount + diagnostics.enqueueFailureCount
        let shouldLogFrame = diagnostics.frameCount <= 3 && diagnostics.frameCount != lastLoggedDiagnosticsFrameCount
        let shouldLogMilestone = diagnostics.frameCount >= lastLoggedDiagnosticsFrameCount + 120
        let shouldLogFailure = totalFailures != lastLoggedDiagnosticsFailures
        guard shouldLogFrame || shouldLogMilestone || shouldLogFailure else { return }
        lastLoggedDiagnosticsFrameCount = diagnostics.frameCount
        lastLoggedDiagnosticsFailures = totalFailures
        Logger.shared.log(
            "[MPVSampleBufferPiPBridge] diagnostics backend=\(diagnostics.presentationBackend.rawValue) api=\(diagnostics.renderAPI) source=\(diagnostics.sourcePixelFormatDescription) pixel=\(diagnostics.pixelFormatDescription) hdr=\(diagnostics.hdrMetadataApplied) highBitDepth=\(diagnostics.highBitDepthRenderingActive) highBitDepthFail=\(diagnostics.highBitDepthRenderingFailureCount) primaries=\(diagnostics.videoColorPrimaries.isEmpty ? "unknown" : diagnostics.videoColorPrimaries) transfer=\(diagnostics.videoTransferFunction.isEmpty ? "unknown" : diagnostics.videoTransferFunction) sigPeak=\(String(format: "%.2f", diagnostics.videoSignalPeak)) moltenVKFrames=\(diagnostics.metalPresentationFrameCount) moltenVKFail=\(diagnostics.metalPresentationFailureCount) frames=\(diagnostics.frameCount) attempts=\(diagnostics.renderAttemptCount) renderFail=\(diagnostics.renderFailureCount) allocFail=\(diagnostics.allocationFailureCount) enqueueFail=\(diagnostics.enqueueFailureCount) lastStatus=\(diagnostics.lastRenderStatus) size=\(String(format: "%.0fx%.0f", diagnostics.lastFrameSize.width, diagnostics.lastFrameSize.height)) layer=\(diagnostics.displayLayerStatus) ready=\(diagnostics.displayLayerReadyForMoreMediaData) moltenVKProbe=\(diagnostics.metalCompatibilityProbeSucceeded)",
            type: "MPV"
        )
    }
}

#if ECLIPSE_ENABLE_OPENGL_RENDERER
final class MPVMoltenVKRenderer: PlayerRenderer, MPVNativeRendererDelegate {
    enum RendererError: Error {
        case mpvCreationFailed
        case mpvInitialization(Int32)
        case metalUnavailable
    }

    private struct MPVTrackInfo {
        let id: Int
        let type: String
        let title: String
        let lang: String
        let codec: String
        let external: Bool
        let defaultTrack: Bool
        let forced: Bool
        let selected: Bool
    }

    static var isAvailable: Bool {
        MTLCreateSystemDefaultDevice() != nil
    }

    weak var delegate: MPVNativeRendererDelegate? {
        didSet {
            fallbackRenderer?.delegate = delegate
            pipBridge.delegate = self
        }
    }

    private let displayLayer: AVSampleBufferDisplayLayer
    private var qualityProfile: MPVMetalSampleBufferQualityProfile
    private let containerView = UIView(frame: .zero)
    private let metalView = MPVMoltenVKView(frame: .zero)
    private let pipBridge: MPVSampleBufferPiPBridge
    private let eventQueue = DispatchQueue(label: "mpv.moltenvk.events", qos: .utility)
    private let stateQueue = DispatchQueue(label: "mpv.moltenvk.state", attributes: .concurrent)
    private let eventQueueGroup = DispatchGroup()

    private var fallbackRenderer: MPVNativeRenderer?
    private var mpv: OpaquePointer?
    private var currentPreset: PlayerPreset?
    private var currentURL: URL?
    private var currentHeaders: [String: String]?
    private var pendingInitialSeek: Double?
    private var pendingPiPAudioTrackId: Int?
    private var pendingPiPSubtitleTrackId: Int?
    private var selectedAudioTrackId: Int?
    private var selectedSubtitleTrackId: Int?
    private var loadedExternalSubtitleRequests: [(urls: [String], names: [String]?, enforce: Bool)] = []
    private var cachedDuration: Double = 0
    private var cachedPosition: Double = 0
    private var videoSize: CGSize = .zero
    private var isPaused = true
    private var wasPausedBeforePiP = true
    private var isLoading = false
    private var isPausedForCache = false
    private var isRunning = false
    private var isStopping = false
    private var isReadyToSeek = false
    private var isAwaitingFileLoadedForCurrentLoad = true
    private var isUsingPiPBridge = false
    private var isPreparingPiPBridge = false
    private var pipBridgeLoadGeneration: Int?
    private var lastSuppressedPiPBridgeStateLog = ""
    private var loadGeneration = 0
    private var currentLoadStartedAt: Date?
    private var lastAppliedSubtitleStyle: SubtitleStyle = .default
    private var lastSubtitleViewportSize: CGSize = .zero
    private var lastTrackSummary = ""
    private var lastProgressLogBucket = -1
    private var lastDurationLogValue: Double = -1
    private var lastPlaybackErrorMessage: String?
    private var hardwareDecodeFailureWindowStart: Date?
    private var hardwareDecodeFailureCount = 0
    private var runtimeHardwareDecodeFallbackApplied = false
    private var lastRenderingLayoutSize: CGSize = .zero
    private var lastMetalDrawableSize: CGSize = .zero
    // True when the inline MoltenVK layer is currently configured for HDR/EDR passthrough.
    private var hdrPassthroughActive = false
    private var lastHDRConfigurationSignature = ""

    var isPausedState: Bool {
        fallbackRenderer?.isPausedState ?? (isUsingPiPBridge ? pipBridge.isPausedState : isPaused)
    }

    var supportsBitmapSubtitleTracks: Bool {
        true
    }

    var prefersPictureInPictureLayerActivationBeforeStart: Bool {
        fallbackRenderer?.prefersPictureInPictureLayerActivationBeforeStart
            ?? pipBridge.prefersPictureInPictureLayerActivationBeforeStart
    }

    init(displayLayer: AVSampleBufferDisplayLayer, qualityProfile: MPVMetalSampleBufferQualityProfile) {
        self.displayLayer = displayLayer
        self.qualityProfile = qualityProfile
        self.pipBridge = MPVSampleBufferPiPBridge(displayLayer: displayLayer, qualityProfile: qualityProfile)
        self.pipBridge.delegate = self

        let screen = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }
            .first ?? UIScreen.main
        let nativeScale = screen.nativeScale > 0 ? screen.nativeScale : screen.scale

        containerView.backgroundColor = .black
        containerView.isUserInteractionEnabled = false
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.backgroundColor = .black
        metalView.isOpaque = true
        metalView.isUserInteractionEnabled = false
        metalView.metalLayer.device = MTLCreateSystemDefaultDevice()
        metalView.metalLayer.framebufferOnly = true
        metalView.metalLayer.backgroundColor = UIColor.black.cgColor
        metalView.metalLayer.contentsScale = nativeScale
        metalView.renderScale = qualityProfile.renderScale
        containerView.addSubview(metalView)
        NSLayoutConstraint.activate([
            metalView.topAnchor.constraint(equalTo: containerView.topAnchor),
            metalView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            metalView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor)
        ])

        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        displayLayer.contentsScale = nativeScale
        displayLayer.isHidden = true
        displayLayer.opacity = 0.0
    }

    deinit {
        stop()
    }

    func getRenderingView() -> UIView {
        containerView
    }

    func renderingLayoutDidChange(containerSize: CGSize) {
        if let fallbackRenderer {
            fallbackRenderer.renderingLayoutDidChange(containerSize: containerSize)
            return
        }

        let updateLayout = { [weak self] in
            guard let self else { return }
            let targetSize: CGSize
            if self.containerView.bounds.width > 0, self.containerView.bounds.height > 0 {
                targetSize = self.containerView.bounds.size
            } else {
                targetSize = containerSize
            }
            guard targetSize.width > 0, targetSize.height > 0 else { return }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.containerView.layoutIfNeeded()
            if self.metalView.frame.size != targetSize {
                self.metalView.frame = CGRect(origin: .zero, size: targetSize)
            }
            self.metalView.layoutIfNeeded()
            let drawableSize = self.metalView.synchronizeDrawableSize()
            self.displayLayer.frame = CGRect(origin: .zero, size: targetSize)
            CATransaction.commit()

            self.pipBridge.renderingLayoutDidChange(containerSize: targetSize)
            let layoutChanged = abs(self.lastRenderingLayoutSize.width - targetSize.width) > 0.5
                || abs(self.lastRenderingLayoutSize.height - targetSize.height) > 0.5
            let drawableChanged = abs(self.lastMetalDrawableSize.width - drawableSize.width) > 0.5
                || abs(self.lastMetalDrawableSize.height - drawableSize.height) > 0.5
            guard layoutChanged || drawableChanged else { return }

            self.lastRenderingLayoutSize = targetSize
            self.lastMetalDrawableSize = drawableSize
            self.refreshSubtitleStyleIfViewportChanged()
            if self.isRunning, !self.isStopping, !self.isUsingPiPBridge, let handle = self.mpv {
                mpv_wakeup(handle)
            }
            self.logMPV("layout synchronized container=\(String(format: "%.0fx%.0f", targetSize.width, targetSize.height)) moltenVKBounds=\(String(format: "%.0fx%.0f", self.metalView.bounds.width, self.metalView.bounds.height)) drawable=\(String(format: "%.0fx%.0f", drawableSize.width, drawableSize.height)) pipActive=\(self.isUsingPiPBridge)")
        }
        if Thread.isMainThread {
            updateLayout()
        } else {
            DispatchQueue.main.async(execute: updateLayout)
        }
    }

    func start() throws {
        guard fallbackRenderer == nil else {
            try fallbackRenderer?.start()
            return
        }
        do {
            try startMoltenVK()
        } catch {
            logMPV("MoltenVK start failed; falling back to OpenGL error=\(error)")
            let fallback = MPVNativeRenderer(displayLayer: displayLayer)
            fallback.delegate = delegate
            installFallbackRendererView(fallback.getRenderingView())
            fallbackRenderer = fallback
            try fallback.start()
        }
    }

    func stop() {
        if let fallbackRenderer {
            fallbackRenderer.stop()
            return
        }
        if isStopping { return }
        if !isRunning, mpv == nil { return }
        loadGeneration += 1
        isStopping = true
        isRunning = false
        pipBridge.stop()
        resetHDRConfiguration()

        let handleForShutdown = mpv
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
        isUsingPiPBridge = false
        isPreparingPiPBridge = false
        pipBridgeLoadGeneration = nil
        pendingPiPAudioTrackId = nil
        pendingPiPSubtitleTrackId = nil
        isReadyToSeek = false
        isLoading = false
        isPaused = true
        isPausedForCache = false
        cachedDuration = 0
        cachedPosition = 0
        updateVideoSize(width: 0, height: 0, allowZero: true)
        resetHardwareDecodeFailureTracking()
        isStopping = false
        logMPV("stop completed")
    }

    func load(url: URL, with preset: PlayerPreset, headers: [String: String]? = nil) {
        if let fallbackRenderer {
            fallbackRenderer.load(url: url, with: preset, headers: headers)
            return
        }
        currentURL = url
        currentPreset = preset
        currentHeaders = headers
        cachedPosition = 0
        cachedDuration = 0
        updateVideoSize(width: 0, height: 0, allowZero: true)
        isReadyToSeek = false
        isAwaitingFileLoadedForCurrentLoad = true
        isPausedForCache = false
        currentLoadStartedAt = Date()
        lastTrackSummary = ""
        lastPlaybackErrorMessage = nil
        lastProgressLogBucket = -1
        lastDurationLogValue = -1
        resetHardwareDecodeFailureTracking()
        loadGeneration += 1
        let generation = loadGeneration
        pipBridgeLoadGeneration = nil
        isPreparingPiPBridge = false
        isUsingPiPBridge = false
        pendingPiPAudioTrackId = nil
        pendingPiPSubtitleTrackId = nil
        pipBridge.stop()
        logMPV("load start gen=\(generation) target=\(describe(url: url)) preset=\(preset.id.rawValue) headerKeys=[\((headers ?? [:]).keys.sorted().joined(separator: ","))] pendingInitialSeek=\(pendingInitialSeek.map { String(format: "%.2f", $0) } ?? "nil")")
        setLoading(true)

        guard let handle = mpv else {
            setLoading(false)
            delegate?.renderer(self, didFailWithError: "MPV MoltenVK was not ready to load media")
            return
        }

        ensureAudioSessionActive()
        apply(commands: preset.commands, on: handle)
        command(handle, ["stop"])
        updateHTTPHeaders(headers)
        applySubtitleStyle(lastAppliedSubtitleStyle)
        let target = url.isFileURL ? url.path : url.absoluteString
        var loadCommand = ["loadfile", target, "replace"]
        if let initialSeek = pendingInitialSeek, initialSeek.isFinite, initialSeek > 0 {
            loadCommand.append(String(format: "start=%.3f", initialSeek))
            logMPV("load start option gen=\(generation) seek=\(String(format: "%.2f", initialSeek))s")
        }
        let loadStatus = command(handle, loadCommand)
        if loadStatus < 0 {
            setLoading(false)
            delegate?.renderer(self, didFailWithError: "MPV MoltenVK rejected the media load command (\(loadStatus))")
            return
        }
        mpv_wakeup(handle)
        scheduleLoadWatchdog(generation: generation, delay: 8)
        scheduleLoadWatchdog(generation: generation, delay: 20)
    }

    func reloadCurrentItem() {
        guard let currentURL, let currentPreset else { return }
        load(url: currentURL, with: currentPreset, headers: currentHeaders)
    }

    func applyPreset(_ preset: PlayerPreset) {
        if let fallbackRenderer {
            fallbackRenderer.applyPreset(preset)
            return
        }
        currentPreset = preset
        guard let handle = mpv else { return }
        apply(commands: preset.commands, on: handle)
        if isUsingPiPBridge {
            pipBridge.applyPreset(preset)
        }
    }

    func prepareInitialSeek(to seconds: Double?) {
        fallbackRenderer?.prepareInitialSeek(to: seconds)
        pendingInitialSeek = seconds.map { max(0, $0) }
        if isUsingPiPBridge {
            pipBridge.prepareInitialSeek(to: pendingInitialSeek)
        }
    }

    func performanceOverlaySnapshot() -> String {
        if let fallbackRenderer {
            return fallbackRenderer.performanceOverlaySnapshot()
        }
        let size = currentVideoSize()
        let mode = isUsingPiPBridge ? "moltenvk-pip" : "moltenvk"
        return "MPV \(mode) \(isPausedState ? "paused" : "playing")\(isLoading ? " loading" : "") \(qualityProfile.name)\npos \(String(format: "%.1f", cachedPosition))/\(String(format: "%.1f", cachedDuration))\nvideo \(String(format: "%.0fx%.0f", size.width, size.height))\n\(pipBridge.pictureInPictureDebugSnapshot())"
    }

    func beginForegroundUIStallRecovery(reason: String) {
        fallbackRenderer?.beginForegroundUIStallRecovery(reason: reason)
        guard fallbackRenderer == nil else { return }
        logMPV("foreground UI recovery requested reason=\(reason) renderer=moltenvk")
        if let handle = mpv {
            mpv_wakeup(handle)
        }
    }

#if ECLIPSE_MPVKIT_METAL_LIVE_QUALITY_RECONFIGURE
    @discardableResult
    func updateSampleBufferQualityProfile(_ newProfile: MPVMetalSampleBufferQualityProfile) -> Bool {
        guard fallbackRenderer == nil else { return false }
        let bridgeChanged = pipBridge.updateSampleBufferQualityProfile(newProfile)
        let previousScale = qualityProfile.renderScale
        qualityProfile = newProfile
        guard abs(previousScale - newProfile.renderScale) > 0.001 else {
            logMPV("MoltenVK quality profile updated, render scale unchanged \(newProfile.logDescription)")
            return bridgeChanged
        }
        let applyChange = { [weak self] in
            guard let self else { return }
            self.metalView.renderScale = newProfile.renderScale
            // Re-run the layout pass so the smaller drawable is published and mpv is woken to
            // recreate its swapchain at the new surface size (the MoltenVK context resizes to
            // the layer's drawableSize on the next present).
            self.renderingLayoutDidChange(containerSize: self.containerView.bounds.size)
        }
        if Thread.isMainThread {
            applyChange()
        } else {
            DispatchQueue.main.async(execute: applyChange)
        }
        logMPV("MoltenVK quality profile applied to inline renderer \(newProfile.logDescription)")
        return true
    }
#endif

    func play() {
        if let fallbackRenderer {
            fallbackRenderer.play()
            return
        }
        if isUsingPiPBridge {
            pipBridge.play()
        } else {
            ensureAudioSessionActive()
            setProperty(name: "pause", value: "no")
        }
        isPaused = false
        delegate?.renderer(self, didChangePause: false)
    }

    func pausePlayback() {
        if let fallbackRenderer {
            fallbackRenderer.pausePlayback()
            return
        }
        if isUsingPiPBridge {
            pipBridge.pausePlayback()
        } else {
            setProperty(name: "pause", value: "yes")
        }
        isPaused = true
        delegate?.renderer(self, didChangePause: true)
    }

    func togglePause() {
        isPausedState ? play() : pausePlayback()
    }

    func seek(to seconds: Double) {
        if let fallbackRenderer {
            fallbackRenderer.seek(to: seconds)
            return
        }
        if isUsingPiPBridge {
            pipBridge.seek(to: seconds)
        } else if let handle = mpv {
            command(handle, ["seek", String(max(0, seconds)), "absolute", "exact"])
        }
        cachedPosition = max(0, seconds)
        publishProgress()
    }

    func seek(by seconds: Double) {
        if let fallbackRenderer {
            fallbackRenderer.seek(by: seconds)
            return
        }
        if isUsingPiPBridge {
            pipBridge.seek(by: seconds)
        } else if let handle = mpv {
            command(handle, ["seek", String(seconds), "relative", "exact"])
        }
    }

    func setSpeed(_ speed: Double) {
        if let fallbackRenderer {
            fallbackRenderer.setSpeed(speed)
            return
        }
        let clampedSpeed = min(max(speed, 0.25), 3.0)
        if isUsingPiPBridge {
            pipBridge.setSpeed(clampedSpeed)
        } else {
            setProperty(name: "speed", value: String(clampedSpeed))
        }
    }

    func getSpeed() -> Double {
        if let fallbackRenderer { return fallbackRenderer.getSpeed() }
        if isUsingPiPBridge { return pipBridge.getSpeed() }
        guard let handle = mpv else { return 1.0 }
        var speed = Double(1.0)
        getProperty(handle: handle, name: "speed", format: MPV_FORMAT_DOUBLE, value: &speed)
        return speed
    }

    func getAudioTracksDetailed() -> [(Int, String, String)] {
        if let fallbackRenderer { return fallbackRenderer.getAudioTracksDetailed() }
        if isUsingPiPBridge { return pipBridge.getAudioTracksDetailed() }
        return fetchTrackList().filter { $0.type == "audio" }.map { ($0.id, $0.title, $0.lang) }
    }

    func getAudioTracks() -> [(Int, String)] {
        getAudioTracksDetailed().map { ($0.0, $0.1) }
    }

    func getCurrentAudioTrackId() -> Int {
        if let fallbackRenderer { return fallbackRenderer.getCurrentAudioTrackId() }
        if isUsingPiPBridge { return pipBridge.getCurrentAudioTrackId() }
        let id = getTrackIdProperty("aid")
        if id >= 0 { return id }
        return fetchTrackList().first(where: { $0.type == "audio" && $0.selected })?.id ?? -1
    }

    func setAudioTrack(id: Int) {
        if let fallbackRenderer {
            fallbackRenderer.setAudioTrack(id: id)
            return
        }
        selectedAudioTrackId = id
        if isUsingPiPBridge {
            pipBridge.setAudioTrack(id: id)
        } else {
            setProperty(name: "aid", value: String(id))
        }
    }

    func getSubtitleTracks() -> [(Int, String)] {
        getSubtitleTracksDetailed().map { ($0.0, $0.1) }
    }

    func getSubtitleTracksDetailed() -> [(Int, String, String, Bool)] {
        if let fallbackRenderer { return fallbackRenderer.getSubtitleTracksDetailed() }
        if isUsingPiPBridge { return pipBridge.getSubtitleTracksDetailed() }
        return fetchTrackList().filter { $0.type == "sub" }.map { ($0.id, $0.title, $0.codec, $0.external) }
    }

    func getCurrentSubtitleTrackId() -> Int {
        if let fallbackRenderer { return fallbackRenderer.getCurrentSubtitleTrackId() }
        if isUsingPiPBridge { return pipBridge.getCurrentSubtitleTrackId() }
        let id = getTrackIdProperty("sid")
        if id >= 0 { return id }
        return fetchTrackList().first(where: { $0.type == "sub" && $0.selected })?.id ?? -1
    }

    func setSubtitleTrack(id: Int) {
        if let fallbackRenderer {
            fallbackRenderer.setSubtitleTrack(id: id)
            return
        }
        selectedSubtitleTrackId = id
        if isUsingPiPBridge {
            pipBridge.setSubtitleTrack(id: id)
        } else {
            setProperty(name: "sid", value: String(id))
            setProperty(name: "sub-visibility", value: "yes")
        }
        delegate?.renderer(self, subtitleTrackDidChange: id)
    }

    func disableSubtitles() {
        if let fallbackRenderer {
            fallbackRenderer.disableSubtitles()
            return
        }
        selectedSubtitleTrackId = nil
        if isUsingPiPBridge {
            pipBridge.disableSubtitles()
        } else {
            setProperty(name: "sid", value: "no")
            setProperty(name: "sub-visibility", value: "no")
        }
        delegate?.renderer(self, subtitleTrackDidChange: -1)
    }

    func refreshSubtitleOverlay() {
        applySubtitleStyle(lastAppliedSubtitleStyle)
    }

    func loadExternalSubtitles(urls: [String], names: [String]? = nil, enforce: Bool = false) {
        if let fallbackRenderer {
            fallbackRenderer.loadExternalSubtitles(urls: urls, names: names, enforce: enforce)
            return
        }
        loadedExternalSubtitleRequests.append((urls: urls, names: names, enforce: enforce))
        if isUsingPiPBridge {
            pipBridge.loadExternalSubtitles(urls: urls, names: names, enforce: enforce)
        }
        guard let handle = mpv else { return }
        for (index, url) in urls.enumerated() where !url.isEmpty {
            let title = externalSubtitleTitle(urlString: url, fallbackName: names.flatMap { index < $0.count ? $0[index] : nil }, fallbackIndex: index)
            command(handle, ["sub-add", url, enforce ? "select" : "auto", title])
        }
    }

    func applySubtitleStyle(_ style: SubtitleStyle) {
        if let fallbackRenderer {
            fallbackRenderer.applySubtitleStyle(style)
            return
        }
        lastAppliedSubtitleStyle = style
        setProperty(name: "sub-visibility", value: style.isVisible ? "yes" : "no")
        setProperty(name: "sub-font-size", value: String(adjustedSubtitleFontSize(for: style)))
        setProperty(name: "sub-color", value: mpvColor(style.foregroundColor))
        setProperty(name: "sub-border-color", value: mpvColor(style.strokeColor))
        setProperty(name: "sub-border-size", value: String(format: "%.2f", max(0, min(style.strokeWidth * 1.5, 5.0))))
        setProperty(name: "sub-pos", value: mpvSubtitlePosition(for: style.verticalOffset))
        setProperty(name: "sub-shadow-offset", value: "0")
        setProperty(name: "sub-ass-override", value: experimentalSubtitleASSOverrideValue(isMetalRenderer: true))
        setProperty(name: "sub-border-style", value: style.closedCaptionBackground ? "background-box" : "outline-and-shadow")
        setProperty(name: "sub-back-color", value: style.closedCaptionBackground ? "0.0/0.0/0.0/0.75" : "0.0/0.0/0.0/0.0")
        if isUsingPiPBridge {
            pipBridge.applySubtitleStyle(style)
        }
    }

    func canStartSampleBufferPictureInPicture() -> Bool {
        fallbackRenderer?.canStartSampleBufferPictureInPicture() ?? pipBridge.canStartSampleBufferPictureInPicture()
    }

    func prepareForPictureInPictureStart() {
        if let fallbackRenderer {
            fallbackRenderer.prepareForPictureInPictureStart()
            return
        }
        guard isRunning, let currentURL, let currentPreset else {
            logMPV("PiP hybrid prepare skipped running=\(isRunning) url=\(currentURL != nil) preset=\(currentPreset != nil)")
            return
        }
        wasPausedBeforePiP = isPausedState
        pendingPiPAudioTrackId = selectedAudioTrackId ?? getCurrentAudioTrackId()
        pendingPiPSubtitleTrackId = selectedSubtitleTrackId ?? getCurrentSubtitleTrackId()
        isPreparingPiPBridge = true

        if pipBridgeLoadGeneration != loadGeneration {
            do {
                try pipBridge.start()
            } catch {
                isPreparingPiPBridge = false
                pipBridgeLoadGeneration = nil
                logMPV("PiP hybrid bridge start failed error=\(error) foreground={\(pictureInPictureDebugSnapshot())}")
                delegate?.renderer(self, didFailWithError: "MPV MoltenVK sample-buffer PiP handoff failed to start")
                return
            }

            pipBridgeLoadGeneration = loadGeneration
            pipBridge.prepareInitialSeek(to: cachedPosition)
            pipBridge.load(url: currentURL, with: currentPreset, headers: currentHeaders)
            pipBridge.setSpeed(getSpeed())
            pipBridge.applySubtitleStyle(lastAppliedSubtitleStyle)
            for request in loadedExternalSubtitleRequests {
                pipBridge.loadExternalSubtitles(urls: request.urls, names: request.names, enforce: request.enforce)
            }
            if wasPausedBeforePiP {
                pipBridge.pausePlayback()
            }
            logMPV("PiP hybrid GPU sample-buffer bridge load gen=\(loadGeneration) pos=\(String(format: "%.2f", cachedPosition)) paused=\(wasPausedBeforePiP) audio=\(pendingPiPAudioTrackId ?? -1) sub=\(pendingPiPSubtitleTrackId ?? -1) externalSubs=\(loadedExternalSubtitleRequests.count) foregroundSid=\(getCurrentSubtitleTrackId())")
        } else {
            pipBridge.prepareInitialSeek(to: cachedPosition)
            pipBridge.setSpeed(getSpeed())
            pipBridge.applySubtitleStyle(lastAppliedSubtitleStyle)
            logMPV("PiP hybrid GPU sample-buffer bridge reuse gen=\(loadGeneration) pos=\(String(format: "%.2f", cachedPosition)) primed=\(pipBridge.isPictureInPicturePrimed())")
        }

        // Keep the PiP bridge silent until it takes over at activation; otherwise
        // both the inline mpv and the bridge play this stream's audio during the
        // prepare->activate window. Skip if PiP is already active so a re-prepare
        // can't silence the running window.
        if !isUsingPiPBridge {
            pipBridge.setAudioMuted(true)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isRunning,
                  !self.isStopping,
                  self.isPreparingPiPBridge || self.isUsingPiPBridge else { return }
            self.displayLayer.isHidden = false
            self.displayLayer.opacity = 1.0
            self.displayLayer.zPosition = -1
            self.metalView.isHidden = false
        }
        pipBridge.prepareForPictureInPictureStart()
    }

    func finishPictureInPicture() {
        if let fallbackRenderer {
            fallbackRenderer.finishPictureInPicture()
            return
        }
        guard isUsingPiPBridge || isPreparingPiPBridge || pipBridgeLoadGeneration != nil else {
            resumeForegroundRendering(reason: "finish-pip-not-active")
            return
        }
        let wasActive = isUsingPiPBridge
        let reportedBridgePosition = pipBridge.currentTime
        let bridgePosition = reportedBridgePosition.isFinite && reportedBridgePosition > 0.1 ? reportedBridgePosition : cachedPosition
        let bridgeSpeed = pipBridge.getSpeed()
        let bridgeAudio = pipBridge.getCurrentAudioTrackId()
        let bridgeSubtitle = pipBridge.getCurrentSubtitleTrackId()
        let shouldResumePlayback = !pipBridge.isPausedState
        logMPV("PiP hybrid finish active=\(wasActive) pos=\(String(format: "%.2f", bridgePosition)) speed=\(String(format: "%.2f", bridgeSpeed)) audio=\(bridgeAudio) sub=\(bridgeSubtitle) resume=\(shouldResumePlayback)")
        pipBridge.stop()
        isUsingPiPBridge = false
        isPreparingPiPBridge = false
        pipBridgeLoadGeneration = nil
        pendingPiPAudioTrackId = nil
        pendingPiPSubtitleTrackId = nil
        if wasActive {
            setProperty(name: "vid", value: "auto")
            setSpeed(bridgeSpeed)
            seek(to: bridgePosition)
            if bridgeAudio >= 0 { setAudioTrack(id: bridgeAudio) }
            if bridgeSubtitle >= 0 {
                setSubtitleTrack(id: bridgeSubtitle)
            } else {
                disableSubtitles()
            }
            if shouldResumePlayback {
                play()
            } else {
                pausePlayback()
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isRunning,
                  !self.isUsingPiPBridge,
                  !self.isPreparingPiPBridge else { return }
            self.displayLayer.isHidden = true
            self.displayLayer.opacity = 0.0
            self.displayLayer.zPosition = -1
            self.metalView.isHidden = false
            self.metalView.setNeedsLayout()
        }
    }

    func primePictureInPictureFrames(reason: String) {
        if let fallbackRenderer {
            fallbackRenderer.primePictureInPictureFrames(reason: reason)
            return
        }
        if isUsingPiPBridge || isPreparingPiPBridge {
            pipBridge.primePictureInPictureFrames(reason: reason)
        }
    }

    func activatePictureInPictureLayer() {
        if let fallbackRenderer {
            fallbackRenderer.activatePictureInPictureLayer()
            return
        }
        let bridgePrimed = pipBridge.isPictureInPicturePrimed()
        guard isUsingPiPBridge || isPreparingPiPBridge || (pipBridgeLoadGeneration == loadGeneration && bridgePrimed) else {
            logMPV("PiP hybrid activate skipped preparing=\(isPreparingPiPBridge) using=\(isUsingPiPBridge) bridgeGen=\(pipBridgeLoadGeneration ?? -1) currentGen=\(loadGeneration) primed=\(bridgePrimed) bridge={\(pipBridge.pictureInPictureDebugSnapshot())}")
            return
        }
        let wasActive = isUsingPiPBridge
        isUsingPiPBridge = true
        isPreparingPiPBridge = false
        if !wasActive {
            setProperty(name: "pause", value: "yes")
            setProperty(name: "vid", value: "no")
            // Inline mpv is now paused and the bridge owns playback, so let its audio through.
            pipBridge.setAudioMuted(false)
            logMPV("PiP hybrid activated bridge foregroundPos=\(String(format: "%.2f", cachedPosition)) bridge={\(pipBridge.pictureInPictureDebugSnapshot())}")
        }
        pipBridge.activatePictureInPictureLayer()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning, self.isUsingPiPBridge else { return }
            self.metalView.isHidden = true
        }
    }

    func isPictureInPicturePrimed() -> Bool {
        fallbackRenderer?.isPictureInPicturePrimed()
            ?? ((isUsingPiPBridge || isPreparingPiPBridge || pipBridgeLoadGeneration == loadGeneration) && pipBridge.isPictureInPicturePrimed())
    }

    func resumeForegroundRendering(reason: String) {
        if let fallbackRenderer {
            fallbackRenderer.resumeForegroundRendering(reason: reason)
            return
        }
        guard isRunning else { return }
        if isUsingPiPBridge {
            finishPictureInPicture()
            return
        }
        if isPreparingPiPBridge || pipBridgeLoadGeneration != nil {
            finishPictureInPicture()
            return
        }
        setProperty(name: "vid", value: "auto")
        if !isPaused {
            setProperty(name: "pause", value: "no")
        }
        DispatchQueue.main.async { [weak self] in
            self?.displayLayer.isHidden = true
            self?.displayLayer.opacity = 0.0
            self?.displayLayer.zPosition = -1
            self?.metalView.isHidden = false
            self?.metalView.setNeedsLayout()
        }
        logMPV("foreground render restored reason=\(reason)")
    }

    func pictureInPictureDebugSnapshot() -> String {
        if let fallbackRenderer {
            return fallbackRenderer.pictureInPictureDebugSnapshot()
        }
        let size = currentVideoSize()
        let vo = mpv.flatMap { getStringProperty(handle: $0, name: "vo-configured") } ?? "nil"
        let hwdec = mpv.flatMap { getStringProperty(handle: $0, name: "hwdec-current") } ?? "nil"
        let mode = isUsingPiPBridge ? "moltenvk-pip" : (isPreparingPiPBridge ? "moltenvk-pip-warmup" : "moltenvk")
        return "mode=\(mode) running=\(isRunning) paused=\(isPausedState) loading=\(isLoading) ready=\(isReadyToSeek) pos=\(String(format: "%.2f", cachedPosition))/\(String(format: "%.2f", cachedDuration)) video=\(String(format: "%.0fx%.0f", size.width, size.height)) vo=\(vo) hwdec=\(hwdec) hdr=\(hdrPassthroughActive ? "passthrough" : "sdr") bridgeGen=\(pipBridgeLoadGeneration ?? -1) currentGen=\(loadGeneration) bridge={\(pipBridge.pictureInPictureDebugSnapshot())}"
    }

    private func startMoltenVK() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw RendererError.metalUnavailable
        }
        guard !isRunning else { return }
        guard let handle = mpv_create() else {
            throw RendererError.mpvCreationFailed
        }
        mpv = handle
        logMPV("start requested backend=moltenvk \(qualityProfile.logDescription)")
        setOption(name: "terminal", value: "no")
        setOption(name: "msg-level", value: "all=warn,cplayer=v,ffmpeg=v,demux=v,stream=v")
        setOption(name: "keep-open", value: "yes")
        setOption(name: "idle", value: "yes")
        setMetalLayerWindowIDOption()
        setOption(name: "vo", value: "gpu-next")
        setOption(name: "gpu-api", value: "vulkan")
        setOption(name: "gpu-context", value: "moltenvk")
        setOption(name: "hwdec", value: "videotoolbox")
        setOption(name: "vd-lavc-software-fallback", value: "yes")
        setOption(name: "demuxer-thread", value: "yes")
        setOption(name: "cache", value: "yes")
        setOption(name: "cache-pause-wait", value: "5")
        setOption(name: "demuxer-max-bytes", value: "80M")
        setOption(name: "demuxer-readahead-secs", value: "10")
        setOption(name: "video-sync", value: "audio")
        setOption(name: "framedrop", value: "vo")
        setOption(name: "interpolation", value: "no")
        setOption(name: "video-rotate", value: "no")
        // Surround: ask mpv for the full source channel layout so it can feed multichannel PCM to the audio device when
        // the active route.
        setOption(name: "audio-channels", value: Settings.shared.mpvSurroundSoundEnabled ? "auto" : "stereo")
        // HDR is applied per-file once the colorspace is known (applyHDRConfiguration); start
        // with passthrough off so SDR content and non-HDR displays are never affected.
        setOption(name: "target-colorspace-hint", value: "no")
        setOption(name: "sub-auto", value: "fuzzy")
        setOption(name: "subs-fallback", value: "yes")
        setOption(name: "sub-ass-override", value: experimentalSubtitleASSOverrideValue(isMetalRenderer: true))
        setOption(name: "sub-use-margins", value: "yes")
        applySubtitleStyle(lastAppliedSubtitleStyle)

        let initStatus = mpv_initialize(handle)
        guard initStatus >= 0 else {
            mpv_destroy(handle)
            mpv = nil
            throw RendererError.mpvInitialization(initStatus)
        }
        isRunning = true
        mpv_request_log_messages(handle, "v")
        observeProperties()
        installWakeupHandler()
        ensureAudioSessionActive()
        logMPV("start completed backend=moltenvk vo=gpu-next gpu-api=vulkan gpu-context=moltenvk")
    }

    private func installFallbackRendererView(_ fallbackView: UIView) {
        performOnMainSync {
            self.metalView.removeFromSuperview()
            fallbackView.translatesAutoresizingMaskIntoConstraints = false
            self.containerView.addSubview(fallbackView)
            NSLayoutConstraint.activate([
                fallbackView.topAnchor.constraint(equalTo: self.containerView.topAnchor),
                fallbackView.bottomAnchor.constraint(equalTo: self.containerView.bottomAnchor),
                fallbackView.leadingAnchor.constraint(equalTo: self.containerView.leadingAnchor),
                fallbackView.trailingAnchor.constraint(equalTo: self.containerView.trailingAnchor)
            ])
        }
    }

    private func setMetalLayerWindowIDOption() {
        guard let handle = mpv else { return }
        let pointer = Unmanaged.passUnretained(metalView.metalLayer).toOpaque()
        var wid = Int64(Int(bitPattern: pointer))
        let status = "wid".withCString { namePointer in
            mpv_set_option(handle, namePointer, MPV_FORMAT_INT64, &wid)
        }
        if status < 0 {
            logMPV("failed to set MoltenVK layer wid status=\(status)")
        }
    }

    /// Detects whether the loaded video is HDR and, honoring the user's HDR Output setting and the display's EDR
    /// capability, switches.
    private func applyHDRConfiguration(reason: String) {
        guard let handle = mpv, isRunning, !isStopping, fallbackRenderer == nil, !isUsingPiPBridge else { return }

        let gamma = (getStringProperty(handle: handle, name: "video-params/gamma") ?? "").lowercased()
        let primaries = (getStringProperty(handle: handle, name: "video-params/primaries") ?? "").lowercased()
        let isHDRSource = gamma == "pq" || gamma == "hlg" || gamma == "st2084" || primaries == "bt.2020"

        let mode = Settings.shared.mpvHDRMode
        let wantsPassthrough: Bool
        switch mode {
        case .sdr:
            wantsPassthrough = false
        case .hdr:
            wantsPassthrough = isHDRSource
        case .auto:
            wantsPassthrough = isHDRSource && displaySupportsEDR()
        }

        // Skip redundant reconfiguration on repeated reconfig events for the same state.
        let signature = "\(mode.rawValue)|\(gamma)|\(primaries)|\(wantsPassthrough)"
        guard signature != lastHDRConfigurationSignature else { return }
        lastHDRConfigurationSignature = signature

        // `target-colorspace-hint=yes` makes gpu-next signal the source colorspace to the swapchain;
        // only enable it when we actually want HDR passthrough so SDR output and non-EDR displays
        // keep mpv's default tone-mapping behavior (no regression for the common SDR case).
        setProperty(name: "target-colorspace-hint", value: wantsPassthrough ? "yes" : "no")
        hdrPassthroughActive = wantsPassthrough

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if #available(iOS 16.0, *) {
                self.metalView.metalLayer.wantsExtendedDynamicRangeContent = wantsPassthrough
            }
        }

        logMPV("HDR config reason=\(reason) mode=\(mode.rawValue) gamma=\(gamma.isEmpty ? "nil" : gamma) primaries=\(primaries.isEmpty ? "nil" : primaries) hdrSource=\(isHDRSource) passthrough=\(wantsPassthrough)")
    }

    private func resetHDRConfiguration() {
        lastHDRConfigurationSignature = ""
        hdrPassthroughActive = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if #available(iOS 16.0, *) {
                self.metalView.metalLayer.wantsExtendedDynamicRangeContent = false
            }
        }
    }

    private func displaySupportsEDR() -> Bool {
        guard #available(iOS 16.0, *) else { return false }
        let screen = metalView.window?.screen
            ?? UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.screen }
                .first
            ?? UIScreen.main
        return screen.potentialEDRHeadroom > 1.0
    }

    private func observeProperties() {
        guard let handle = mpv else { return }
        let properties: [(String, mpv_format)] = [
            ("dwidth", MPV_FORMAT_INT64),
            ("dheight", MPV_FORMAT_INT64),
            ("duration", MPV_FORMAT_DOUBLE),
            ("time-pos", MPV_FORMAT_DOUBLE),
            ("pause", MPV_FORMAT_FLAG),
            ("paused-for-cache", MPV_FORMAT_FLAG),
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
            let instance = Unmanaged<MPVMoltenVKRenderer>.fromOpaque(userdata).takeUnretainedValue()
            instance.processEvents()
        }, Unmanaged.passUnretained(self).toOpaque())
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

    private func handleEvent(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_START_FILE:
            cachedPosition = 0
            cachedDuration = 0
            setLoading(true)
        case MPV_EVENT_VIDEO_RECONFIG:
            refreshVideoState()
            applyHDRConfiguration(reason: "video-reconfig")
        case MPV_EVENT_FILE_LOADED:
            handleFileLoaded()
        case MPV_EVENT_END_FILE:
            if !isReadyToSeek {
                let message = lastPlaybackErrorMessage ?? "MPV MoltenVK ended before playback became ready"
                setLoading(false)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.renderer(self, didFailWithError: message)
                }
            }
        case MPV_EVENT_PROPERTY_CHANGE:
            if let property = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee.name {
                refreshProperty(named: String(cString: property))
            }
        case MPV_EVENT_LOG_MESSAGE:
            if let logPointer = event.data?.assumingMemoryBound(to: mpv_event_log_message.self) {
                let component = logPointer.pointee.prefix.map { String(cString: $0) } ?? "unknown"
                let text = logPointer.pointee.text.map { String(cString: $0) } ?? ""
                let level = logPointer.pointee.level.map { String(cString: $0) } ?? "info"
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let lower = trimmed.lowercased()
                    if lower.contains("tls")
                        || lower.contains("http error")
                        || lower.contains("failed to open")
                        || lower.contains("error opening")
                        || lower.contains("403")
                        || lower.contains("404")
                        || lower.contains("502") {
                        lastPlaybackErrorMessage = trimmed
                    }
                    logMPV("mpv[\(component)] \(level): \(trimmed)")
                    trackHardwareDecodeFailureIfNeeded(component: component, message: trimmed, lowercasedMessage: lower)
                }
            }
        default:
            break
        }
    }

    private func trackHardwareDecodeFailureIfNeeded(component: String, message: String, lowercasedMessage lower: String) {
        guard isRunning, !isStopping, !runtimeHardwareDecodeFallbackApplied else { return }
        guard lower.contains("hardware accelerator failed to decode picture")
            || lower.contains("error while decoding frame (hardware decoding)")
            || lower.contains("vt decoder cb: output image buffer is null")
            || lower.contains("no frame decoded") else {
            return
        }

        let now = Date()
        if let start = hardwareDecodeFailureWindowStart, now.timeIntervalSince(start) <= 5.0 {
            hardwareDecodeFailureCount += 1
        } else {
            hardwareDecodeFailureWindowStart = now
            hardwareDecodeFailureCount = 1
        }

        if hardwareDecodeFailureCount == 1 || hardwareDecodeFailureCount == 6 {
            logMPV("hardware decode failure observed count=\(hardwareDecodeFailureCount) component=\(component) message=\(shortText(message, limit: 140))")
        }

        guard hardwareDecodeFailureCount >= 6 else { return }
        applyRuntimeHardwareDecodeFallback(trigger: shortText(message, limit: 140))
    }

    private func applyRuntimeHardwareDecodeFallback(trigger: String) {
        guard !runtimeHardwareDecodeFallbackApplied else { return }
        runtimeHardwareDecodeFallbackApplied = true

        let currentHWDec = mpv.flatMap { getStringProperty(handle: $0, name: "hwdec-current") } ?? "nil"
        let videoCodec = mpv.flatMap { getStringProperty(handle: $0, name: "video-codec") } ?? "nil"
        logMPV("hardware decode fallback applying count=\(hardwareDecodeFailureCount) codec=\(videoCodec) hwdec=\(currentHWDec) trigger=\(trigger)")

        setProperty(name: "vd-lavc-software-fallback", value: "yes")
        setProperty(name: "hwdec", value: "no")
        if let handle = mpv, isReadyToSeek {
            command(handle, ["seek", "0", "relative", "exact"])
            mpv_wakeup(handle)
        }
    }

    private func resetHardwareDecodeFailureTracking() {
        hardwareDecodeFailureWindowStart = nil
        hardwareDecodeFailureCount = 0
        runtimeHardwareDecodeFallbackApplied = false
    }

    private func handleFileLoaded() {
        isReadyToSeek = true
        isAwaitingFileLoadedForCurrentLoad = false
        setLoading(isPausedForCache)
        refreshVideoState()
        applyHDRConfiguration(reason: "file-loaded")
        logTrackSummaryIfChanged(reason: "file-loaded")
        if let initialSeek = pendingInitialSeek {
            pendingInitialSeek = nil
            seek(to: initialSeek)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.renderer(self, didBecomeReadyToSeek: true)
            self.delegate?.rendererDidChangeTracks(self)
        }
    }

    private func refreshProperty(named name: String) {
        guard let handle = mpv else { return }
        switch name {
        case "duration":
            var value = Double(0)
            if getProperty(handle: handle, name: name, format: MPV_FORMAT_DOUBLE, value: &value) >= 0 {
                cachedDuration = max(0, value)
                if cachedDuration > 0, abs(cachedDuration - lastDurationLogValue) > 5 {
                    lastDurationLogValue = cachedDuration
                    logMPV("duration updated \(String(format: "%.2f", cachedDuration))s")
                }
                publishProgress()
            }
        case "time-pos":
            var value = Double(0)
            if getProperty(handle: handle, name: name, format: MPV_FORMAT_DOUBLE, value: &value) >= 0 {
                cachedPosition = max(0, value)
                let bucket = Int(cachedPosition / 10.0)
                if bucket != lastProgressLogBucket {
                    lastProgressLogBucket = bucket
                    logMPV("progress position=\(String(format: "%.2f", cachedPosition)) duration=\(String(format: "%.2f", cachedDuration)) loading=\(isLoading) ready=\(isReadyToSeek) paused=\(isPaused)")
                }
                publishProgress()
            }
        case "dwidth", "dheight":
            refreshVideoState()
        case "pause":
            var flag: Int32 = 0
            if getProperty(handle: handle, name: name, format: MPV_FORMAT_FLAG, value: &flag) >= 0 {
                let newPaused = flag != 0
                if isUsingPiPBridge {
                    isPaused = newPaused
                    logMPV("foreground pause change suppressed during PiP bridge active paused=\(newPaused)")
                    return
                }
                if newPaused != isPaused {
                    isPaused = newPaused
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.delegate?.renderer(self, didChangePause: newPaused)
                    }
                }
            }
        case "paused-for-cache":
            var flag: Int32 = 0
            if getProperty(handle: handle, name: name, format: MPV_FORMAT_FLAG, value: &flag) >= 0 {
                let newPausedForCache = flag != 0
                if newPausedForCache != isPausedForCache {
                    isPausedForCache = newPausedForCache
                    if newPausedForCache {
                        setLoading(true)
                    } else if isReadyToSeek {
                        setLoading(false)
                    }
                }
            }
        case "sid":
            let current = getCurrentSubtitleTrackId()
            selectedSubtitleTrackId = current >= 0 ? current : nil
            logTrackSummaryIfChanged(reason: "sid")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.renderer(self, subtitleTrackDidChange: current)
                self.delegate?.rendererDidChangeTracks(self)
            }
        case "aid":
            let current = getCurrentAudioTrackId()
            selectedAudioTrackId = current >= 0 ? current : nil
            fallthrough
        case "track-list":
            logTrackSummaryIfChanged(reason: name)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.rendererDidChangeTracks(self)
            }
        default:
            break
        }
    }

    private func refreshVideoState() {
        guard let handle = mpv else { return }
        var width: Int64 = 0
        var height: Int64 = 0
        getProperty(handle: handle, name: "dwidth", format: MPV_FORMAT_INT64, value: &width)
        getProperty(handle: handle, name: "dheight", format: MPV_FORMAT_INT64, value: &height)
        updateVideoSize(width: Int(width), height: Int(height))
        refreshSubtitleStyleIfViewportChanged()
    }

    private func publishProgress() {
        guard !isAwaitingFileLoadedForCurrentLoad else { return }
        let position = cachedPosition
        let duration = cachedDuration
        let generation = loadGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.loadGeneration == generation,
                  !self.isAwaitingFileLoadedForCurrentLoad else { return }
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

    private func scheduleLoadWatchdog(generation: Int, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.isRunning,
                  !self.isStopping,
                  self.loadGeneration == generation,
                  self.isLoading,
                  !self.isReadyToSeek else {
                return
            }
            let elapsed = self.currentLoadStartedAt.map { String(format: "%.2f", Date().timeIntervalSince($0)) } ?? "nil"
            let coreIdle = self.mpv.flatMap { self.getStringProperty(handle: $0, name: "core-idle") } ?? "nil"
            let idleActive = self.mpv.flatMap { self.getStringProperty(handle: $0, name: "idle-active") } ?? "nil"
            self.logMPV("startup watchdog gen=\(generation) delay=\(String(format: "%.0f", delay))s elapsed=\(elapsed)s loading=\(self.isLoading) ready=\(self.isReadyToSeek) pos=\(String(format: "%.2f", self.cachedPosition)) dur=\(String(format: "%.2f", self.cachedDuration)) coreIdle=\(coreIdle) idleActive=\(idleActive)")
            if coreIdle == "yes", idleActive == "yes" {
                self.setLoading(false)
                self.delegate?.renderer(self, didFailWithError: "MPV MoltenVK stayed idle after the stream was submitted")
            }
        }
    }

    private func updateVideoSize(width: Int, height: Int, allowZero: Bool = false) {
        guard (width > 0 && height > 0) || allowZero else { return }
        let size = CGSize(width: max(width, 0), height: max(height, 0))
        stateQueue.sync(flags: .barrier) {
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
            eclipseApplyPreferredOutputChannels(log: { [weak self] in self?.logMPV($0) })
            EclipseAudioRouteWatcher.shared.ensureInstalled()
        } catch {
            logMPV("failed to activate AVAudioSession: \(error)")
        }
    }

    private func setOption(name: String, value: String) {
        guard let handle = mpv else { return }
        let status = value.withCString { valuePointer in
            name.withCString { namePointer in
                mpv_set_option_string(handle, namePointer, valuePointer)
            }
        }
        if status < 0 {
            logMPV("failed to set option \(name)=\(redactIfSensitive(name: name, value: value)) status=\(status)")
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
            logMPV("failed to set property \(name)=\(redactIfSensitive(name: name, value: value)) status=\(status)")
        }
    }

    private func clearProperty(name: String) {
        guard let handle = mpv else { return }
        let status = name.withCString { namePointer in
            mpv_set_property(handle, namePointer, MPV_FORMAT_NONE, nil)
        }
        if status < 0 {
            logMPV("failed to clear property \(name) status=\(status)")
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

    @discardableResult
    private func command(_ handle: OpaquePointer, _ args: [String]) -> Int32 {
        guard !args.isEmpty else { return 0 }
        let status = withCStringArray(args) { pointer in
            mpv_command_async(handle, 0, pointer)
        }
        if status < 0 {
            logMPV("command failed status=\(status) command=\(sanitizedCommand(args))")
        }
        return status
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
        for index in 0..<Int(list.pointee.num) {
            let item = list.pointee.values[index]
            guard item.format == MPV_FORMAT_NODE_MAP, let map = item.u.list else { continue }
            var id = -1
            var type = ""
            var title = ""
            var lang = ""
            var codec = ""
            var external = false
            var defaultTrack = false
            var forced = false
            var selected = false
            for entryIndex in 0..<Int(map.pointee.num) {
                guard let keyPointer = map.pointee.keys[entryIndex] else { continue }
                let key = String(cString: keyPointer)
                let value = map.pointee.values[entryIndex]
                switch key {
                case "id" where value.format == MPV_FORMAT_INT64:
                    id = Int(value.u.int64)
                case "type" where value.format == MPV_FORMAT_STRING:
                    type = value.u.string.map { String(cString: $0) } ?? ""
                case "title" where value.format == MPV_FORMAT_STRING:
                    title = value.u.string.map { String(cString: $0) } ?? ""
                case "lang" where value.format == MPV_FORMAT_STRING:
                    lang = value.u.string.map { String(cString: $0) } ?? ""
                case "codec" where value.format == MPV_FORMAT_STRING:
                    codec = value.u.string.map { String(cString: $0) } ?? ""
                case "external" where value.format == MPV_FORMAT_FLAG:
                    external = value.u.flag != 0
                case "default" where value.format == MPV_FORMAT_FLAG:
                    defaultTrack = value.u.flag != 0
                case "forced" where value.format == MPV_FORMAT_FLAG:
                    forced = value.u.flag != 0
                case "selected" where value.format == MPV_FORMAT_FLAG:
                    selected = value.u.flag != 0
                default:
                    break
                }
            }
            guard id >= 0, !type.isEmpty else { continue }
            tracks.append(MPVTrackInfo(
                id: id,
                type: type,
                title: displayTitle(title: title, lang: lang, fallbackId: id),
                lang: lang,
                codec: codec,
                external: external,
                defaultTrack: defaultTrack,
                forced: forced,
                selected: selected
            ))
        }
        return tracks
    }

    private func getTrackIdProperty(_ name: String) -> Int {
        guard let handle = mpv else { return -1 }
        if let value = getStringProperty(handle: handle, name: name) {
            let lower = value.lowercased()
            if lower == "no" || lower == "auto" { return -1 }
            if let intValue = Int(value) { return intValue }
        }
        var id: Int64 = -1
        let status = getProperty(handle: handle, name: name, format: MPV_FORMAT_INT64, value: &id)
        return status >= 0 ? Int(id) : -1
    }

    private func logTrackSummaryIfChanged(reason: String) {
        let tracks = fetchTrackList()
        let videoCount = tracks.filter { $0.type == "video" }.count
        let audioCount = tracks.filter { $0.type == "audio" }.count
        let subtitleCount = tracks.filter { $0.type == "sub" }.count
        let selectedAudio = tracks.first(where: { $0.type == "audio" && $0.selected })?.id ?? -1
        let selectedSubtitle = tracks.first(where: { $0.type == "sub" && $0.selected })?.id ?? -1
        let preview = tracks.prefix(8).map { track -> String in
            let selected = track.selected ? "*" : ""
            let flags = [
                track.external ? "external" : nil,
                track.defaultTrack ? "default" : nil,
                track.forced ? "forced" : nil
            ].compactMap { $0 }.joined(separator: ",")
            let flagText = flags.isEmpty ? "" : "[\(flags)]"
            return "\(track.type)#\(track.id)\(selected):\(track.title){\(track.codec.isEmpty ? "unknown" : track.codec)}\(flagText)"
        }.joined(separator: "|")
        let summary = "video=\(videoCount) audio=\(audioCount) selectedAudio=\(selectedAudio) subs=\(subtitleCount) selectedSub=\(selectedSubtitle) preview=\(preview)"
        guard summary != lastTrackSummary else { return }
        lastTrackSummary = summary
        logMPV("tracks changed reason=\(reason) \(summary)")
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

    private func externalSubtitleTitle(urlString: String, fallbackName: String?, fallbackIndex: Int) -> String {
        if let fallbackName, !fallbackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fallbackName
        }
        if let url = URL(string: urlString) {
            let filename = url.deletingPathExtension().lastPathComponent
            if !filename.isEmpty { return filename }
        }
        return "Subtitle \(fallbackIndex + 1)"
    }

    private func refreshSubtitleStyleIfViewportChanged() {
        let size = containerView.bounds.size
        guard abs(size.width - lastSubtitleViewportSize.width) > 0.5 ||
              abs(size.height - lastSubtitleViewportSize.height) > 0.5 else {
            return
        }
        lastSubtitleViewportSize = size
        applySubtitleStyle(lastAppliedSubtitleStyle)
    }

    private func adjustedSubtitleFontSize(for style: SubtitleStyle) -> Int {
        let baseSize = max(10, min(style.fontSize, 72))
        let viewport = containerView.bounds.size
        guard viewport.width > viewport.height, viewport.height > 0 else {
            return Int(baseSize)
        }
        let multiplier = min(2.0, max(1.0, 720.0 / viewport.height))
        return Int(max(10, min(baseSize * multiplier, 72)))
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

    private func describe(url: URL) -> String {
        if url.isFileURL { return "file://\(url.lastPathComponent)" }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return shortText(url.absoluteString, limit: 180)
        }
        if components.query != nil {
            components.query = "<query>"
        }
        return shortText(components.string ?? url.absoluteString, limit: 180)
    }

    private func sanitizedCommand(_ args: [String]) -> String {
        args.enumerated().map { index, arg in
            if index == 1, args.first == "loadfile", let url = URL(string: arg) {
                return describe(url: url)
            }
            if arg.contains("\r\n") || arg.localizedCaseInsensitiveContains("cookie:") || arg.localizedCaseInsensitiveContains("authorization:") {
                return "<redacted>"
            }
            return shortText(arg, limit: 120)
        }.joined(separator: " ")
    }

    private func redactIfSensitive(name: String, value: String) -> String {
        if name == "http-header-fields" {
            return "<\(value.components(separatedBy: "\r\n").count) headers>"
        }
        return shortText(value, limit: 120)
    }

    private func shortText(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "..."
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

    private func logMPV(_ message: String) {
        Logger.shared.log("[MPVMoltenVKRenderer] \(message)", type: "MPV")
    }

    func renderer(_ renderer: PlayerRenderer, didUpdatePosition position: Double, duration: Double) {
        guard renderer === pipBridge else { return }
        guard isUsingPiPBridge else {
            logSuppressedPiPBridgeEvent("position", detail: "pos=\(String(format: "%.2f", position))/\(String(format: "%.2f", duration))")
            return
        }
        cachedPosition = max(0, position)
        cachedDuration = max(0, duration)
        delegate?.renderer(self, didUpdatePosition: cachedPosition, duration: cachedDuration)
    }

    func renderer(_ renderer: PlayerRenderer, didChangePause isPaused: Bool) {
        guard renderer === pipBridge else { return }
        guard isUsingPiPBridge else {
            logSuppressedPiPBridgeEvent("pause", detail: "paused=\(isPaused)")
            return
        }
        self.isPaused = isPaused
        delegate?.renderer(self, didChangePause: isPaused)
    }

    func renderer(_ renderer: PlayerRenderer, didChangeLoading isLoading: Bool) {
        guard renderer === pipBridge else { return }
        guard isUsingPiPBridge else {
            logSuppressedPiPBridgeEvent("loading", detail: "loading=\(isLoading)")
            return
        }
        self.isLoading = isLoading
        delegate?.renderer(self, didChangeLoading: isLoading)
    }

    func renderer(_ renderer: PlayerRenderer, didBecomeReadyToSeek: Bool) {
        guard renderer === pipBridge else { return }
        if let pendingPiPAudioTrackId, pendingPiPAudioTrackId >= 0 {
            pipBridge.setAudioTrack(id: pendingPiPAudioTrackId)
        }
        if let pendingPiPSubtitleTrackId {
            if pendingPiPSubtitleTrackId >= 0 {
                pipBridge.setSubtitleTrack(id: pendingPiPSubtitleTrackId)
            } else {
                pipBridge.disableSubtitles()
            }
        }
        if isPreparingPiPBridge || isUsingPiPBridge {
            pipBridge.primePictureInPictureFrames(reason: "bridge-ready")
        }
        logMPV("PiP hybrid GPU sample-buffer bridge ready audio=\(pendingPiPAudioTrackId ?? -1) sub=\(pendingPiPSubtitleTrackId ?? -1) snapshot={\(pipBridge.pictureInPictureDebugSnapshot())}")
        guard isUsingPiPBridge else { return }
        delegate?.renderer(self, didBecomeReadyToSeek: didBecomeReadyToSeek)
    }

    func renderer(_ renderer: PlayerRenderer, didFailWithError message: String) {
        guard renderer === pipBridge else { return }
        guard isUsingPiPBridge else {
            if pipBridge.isPictureInPicturePrimed() {
                logMPV("PiP hybrid bridge warmup error ignored after frames message=\(message) bridge={\(pipBridge.pictureInPictureDebugSnapshot())}")
                return
            }
            logMPV("PiP hybrid bridge error during warmup suppressed message=\(message) foreground={\(pictureInPictureDebugSnapshot())}")
            isPreparingPiPBridge = false
            pipBridgeLoadGeneration = nil
            return
        }
        delegate?.renderer(self, didFailWithError: message)
    }

    func rendererDidChangeTracks(_ renderer: PlayerRenderer) {
        guard renderer === pipBridge else { return }
        guard isUsingPiPBridge else {
            logSuppressedPiPBridgeEvent("tracks", detail: pipBridge.pictureInPictureDebugSnapshot())
            return
        }
        delegate?.rendererDidChangeTracks(self)
    }

    func renderer(_ renderer: PlayerRenderer, subtitleTrackDidChange trackId: Int) {
        guard renderer === pipBridge else { return }
        guard isUsingPiPBridge else {
            logSuppressedPiPBridgeEvent("subtitle", detail: "track=\(trackId)")
            return
        }
        selectedSubtitleTrackId = trackId >= 0 ? trackId : nil
        delegate?.renderer(self, subtitleTrackDidChange: trackId)
    }

    private func logSuppressedPiPBridgeEvent(_ event: String, detail: String) {
        let signature = event == "position" ? event : "\(event)|\(detail)"
        guard signature != lastSuppressedPiPBridgeStateLog else { return }
        lastSuppressedPiPBridgeStateLog = signature
        logMPV("PiP hybrid bridge warmup event suppressed event=\(event) detail={\(detail)}")
    }
}
#endif
#endif

#else

final class MPVNativeRenderer: PlayerRenderer {
    enum RendererError: Error {
        case unavailable
    }

    weak var delegate: MPVNativeRendererDelegate?

    init(displayLayer: AVSampleBufferDisplayLayer) { }
    var prefersPictureInPictureLayerActivationBeforeStart: Bool { false }
    func getRenderingView() -> UIView { UIView() }
    func renderingLayoutDidChange(containerSize: CGSize) { }
    func start() throws { throw RendererError.unavailable }
    func stop() { }
    func load(url: URL, with preset: PlayerPreset, headers: [String: String]?) { }
    func reloadCurrentItem() { }
    func applyPreset(_ preset: PlayerPreset) { }
    func prepareInitialSeek(to seconds: Double?) { }
    func beginForegroundUIStallRecovery(reason: String) { }
    func canStartSampleBufferPictureInPicture() -> Bool { false }
    func prepareForPictureInPictureStart() { }
    func finishPictureInPicture() { }
    func primePictureInPictureFrames(reason: String) { }
    func activatePictureInPictureLayer() { }
    func isPictureInPicturePrimed() -> Bool { false }
    func resumeForegroundRendering(reason: String) { }
    func pictureInPictureDebugSnapshot() -> String { "mpv unavailable" }
    func performanceOverlaySnapshot() -> String { "MPV unavailable" }
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
    func getSubtitleTracksDetailed() -> [(Int, String, String, Bool)] { [] }
    func getCurrentSubtitleTrackId() -> Int { -1 }
    func setSubtitleTrack(id: Int) { }
    func disableSubtitles() { }
    func refreshSubtitleOverlay() { }
    func loadExternalSubtitles(urls: [String], names: [String]? = nil, enforce: Bool = false) { }
    func applySubtitleStyle(_ style: SubtitleStyle) { }
    var isPausedState: Bool { true }
    var supportsBitmapSubtitleTracks: Bool { false }
}

#endif
