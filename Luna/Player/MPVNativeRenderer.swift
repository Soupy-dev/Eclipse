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
import QuartzCore

protocol PlayerRenderer: AnyObject {
    var isPausedState: Bool { get }

    func start() throws
    func stop()
    func load(url: URL, with preset: PlayerPreset, headers: [String: String]?)
    func reloadCurrentItem()
    func applyPreset(_ preset: PlayerPreset)
    func prepareInitialSeek(to seconds: Double?)
    func performanceOverlaySnapshot() -> String

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
    func loadExternalSubtitles(urls: [String], names: [String]?, enforce: Bool)
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
private let lunaGLBGRA = GLenum(0x80E1)
private let lunaMPVPiPOpenGLFlipY: Int32 = 0

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

private final class MPVOpenGLView: UIView {
    weak var renderer: MPVNativeRenderer?
    private let context: EAGLContext
    private let drawableLock = NSLock()
    private var drawableNeedsRebuild = true
    private var framebuffer = GLuint(0)
    private var colorRenderbuffer = GLuint(0)
    private(set) var drawableWidth = 0
    private(set) var drawableHeight = 0

    override class var layerClass: AnyClass {
        CAEAGLLayer.self
    }

    private var eaglLayer: CAEAGLLayer {
        layer as! CAEAGLLayer
    }

    init(frame: CGRect, context: EAGLContext) {
        self.context = context
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .black
        isUserInteractionEnabled = false
        contentScaleFactor = UIScreen.main.scale
        eaglLayer.isOpaque = true
        eaglLayer.contentsScale = contentScaleFactor
        eaglLayer.drawableProperties = [
            kEAGLDrawablePropertyRetainedBacking: false,
            kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8
        ]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        markDrawableNeedsRebuild()
        renderer?.openGLViewDidLayout()
    }

    func markDrawableNeedsRebuild() {
        drawableLock.lock()
        drawableNeedsRebuild = true
        drawableLock.unlock()
    }

    private func consumeDrawableNeedsRebuild() -> Bool {
        drawableLock.lock()
        let needsRebuild = drawableNeedsRebuild
        drawableNeedsRebuild = false
        drawableLock.unlock()
        return needsRebuild
    }

    func prepareDrawable() -> Bool {
        EAGLContext.setCurrent(context)
        let needsRebuild = consumeDrawableNeedsRebuild()
        if framebuffer == 0 || colorRenderbuffer == 0 || needsRebuild {
            deleteDrawable()

            glGenFramebuffers(1, &framebuffer)
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)

            glGenRenderbuffers(1, &colorRenderbuffer)
            glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorRenderbuffer)
            guard context.renderbufferStorage(Int(GL_RENDERBUFFER), from: eaglLayer) else {
                deleteDrawable()
                return false
            }

            glFramebufferRenderbuffer(
                GLenum(GL_FRAMEBUFFER),
                GLenum(GL_COLOR_ATTACHMENT0),
                GLenum(GL_RENDERBUFFER),
                colorRenderbuffer
            )

            var width = GLint(0)
            var height = GLint(0)
            glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_WIDTH), &width)
            glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_HEIGHT), &height)
            drawableWidth = Int(width)
            drawableHeight = Int(height)

            let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
            guard status == GLenum(GL_FRAMEBUFFER_COMPLETE), drawableWidth > 0, drawableHeight > 0 else {
                deleteDrawable()
                return false
            }
        } else {
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
            glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorRenderbuffer)
        }
        return drawableWidth > 0 && drawableHeight > 0
    }

    func currentFramebuffer() -> GLuint {
        framebuffer
    }

    func presentDrawable() {
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorRenderbuffer)
        context.presentRenderbuffer(Int(GL_RENDERBUFFER))
    }

    func deleteDrawable() {
        EAGLContext.setCurrent(context)
        if framebuffer != 0 {
            var fbo = framebuffer
            glDeleteFramebuffers(1, &fbo)
            framebuffer = 0
        }
        if colorRenderbuffer != 0 {
            var renderbuffer = colorRenderbuffer
            glDeleteRenderbuffers(1, &renderbuffer)
            colorRenderbuffer = 0
        }
        drawableWidth = 0
        drawableHeight = 0
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
        render: @escaping (inout LunaMPVOpenGLFBO, inout Int32) -> Int32
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
            Logger.shared.log("[MPVPiPBridge] OpenGL render target size=\(width)x\(height) source=\(String(format: "%.0fx%.0f", videoSize.width, videoSize.height)) flipY=\(lunaMPVPiPOpenGLFlipY)", type: "MPV")
        } else if renderAttemptCount <= 3 || renderAttemptCount % 60 == 0 {
            Logger.shared.log("[MPVPiPBridge] OpenGL render attempt count=\(renderAttemptCount) target=\(width)x\(height) source=\(String(format: "%.0fx%.0f", videoSize.width, videoSize.height)) flipY=\(lunaMPVPiPOpenGLFlipY)", type: "MPV")
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
            lunaGLBGRA,
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
        var fbo = LunaMPVOpenGLFBO(
            fbo: Int32(framebuffer),
            w: Int32(width),
            h: Int32(height),
            internal_format: Int32(GL_RGBA)
        )
        var flipY = lunaMPVPiPOpenGLFlipY
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
    private let renderQueue = DispatchQueue(label: "mpv.native.foreground-render", qos: .userInteractive)
    private let renderQueueKey = DispatchSpecificKey<Bool>()
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
    private var forcedOpenGLRenderCount = 0
    private var forcedPiPRenderCount = 0
    private var lastForegroundRenderTime: CFTimeInterval = 0
    private var lastPiPRenderTime: CFTimeInterval = 0
    private let foregroundFrameInterval: CFTimeInterval
    private let foregroundFramesPerSecond: Int
    private let pipFrameInterval: CFTimeInterval = 1.0 / 24.0
    private var lastAppliedSubtitleStyle: SubtitleStyle = .default
    private var loadGeneration = 0
    private var currentLoadStartedAt: Date?
    private var lastProgressLogBucket = -1
    private var lastDurationLogValue: Double = -1
    private var lastTrackSummary = ""
    private var lastPlaybackDiagnosticsBucket = -1
    private var lastPlaybackErrorMessage: String?
    private var selectedVideoTrackID: Int?
    private var pipTransitionID = 0
    private var pipRenderRequestCount = 0

    weak var delegate: MPVNativeRendererDelegate?

    var isPausedState: Bool {
        isPaused
    }

    var supportsBitmapSubtitleTracks: Bool {
        true
    }

    private func logMPV(_ message: String) {
        Logger.shared.log("[MPVNativeRenderer] \(message)", type: "MPV")
    }

    private func logMPVCrashProbe(_ message: String) {
        Logger.shared.log("[MPVNativeRenderer] \(message)", type: "MPVCrashProbe")
    }

    private func performOnRenderQueueSync(_ block: () -> Void) {
        if DispatchQueue.getSpecific(key: renderQueueKey) == true {
            block()
        } else {
            renderQueue.sync(execute: block)
        }
    }

    private func performOnRenderQueueAsync(_ block: @escaping () -> Void) {
        renderQueue.async(execute: block)
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
        let configuredFPS = Settings.shared.mpvForegroundFPS
        let targetFPS = max(1, min(screen.maximumFramesPerSecond, configuredFPS))
        self.foregroundFramesPerSecond = targetFPS
        self.foregroundFrameInterval = 1.0 / CFTimeInterval(targetFPS)
        self.renderQueue.setSpecific(key: renderQueueKey, value: true)

        glView.renderer = self

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

    fileprivate func openGLViewDidLayout() {
        guard isRunning, !isStopping, currentMode == .openGL else { return }
        scheduleRender(force: true)
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
        logMPVCrashProbe("diagnostics marker version=mpv-ios-opengl-36f621b-behavior backend=openGL")

        setOption(name: "terminal", value: "no")
        setOption(name: "msg-level", value: "all=warn,cplayer=v,ffmpeg=v,demux=v,stream=v")
        setOption(name: "keep-open", value: "yes")
        setOption(name: "idle", value: "yes")
        setOption(name: "vo", value: "libmpv")
        setOption(name: "profile", value: "fast")
        setOption(name: "hwdec", value: "videotoolbox-copy")
        setOption(name: "vd-lavc-dr", value: "no")
        setOption(name: "vd-lavc-software-fallback", value: "no")
        setOption(name: "demuxer-thread", value: "yes")
        setOption(name: "cache", value: "yes")
        setOption(name: "demuxer-max-bytes", value: "80M")
        setOption(name: "demuxer-readahead-secs", value: "10")
        setOption(name: "video-sync", value: "audio")
        setOption(name: "framedrop", value: "vo")
        setOption(name: "interpolation", value: "no")
        setOption(name: "sub-auto", value: "fuzzy")
        setOption(name: "subs-fallback", value: "yes")
        setOption(name: "sub-ass-override", value: "yes")
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
            logMPV("start completed mode=openGL hwdec=videotoolbox-copy dr=no softwareFallback=no")
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
        cachedDuration = 0
        cachedPosition = 0
        currentLoadStartedAt = nil
        lastProgressLogBucket = -1
        lastDurationLogValue = -1
        lastTrackSummary = ""
        lastPlaybackErrorMessage = nil
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
        currentLoadStartedAt = Date()
        lastProgressLogBucket = -1
        lastDurationLogValue = -1
        lastTrackSummary = ""
        lastPlaybackErrorMessage = nil
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
        logMPVCrashProbe("configured iOS MPV video path target=\(describe(url: url)) hwdec=videotoolbox-copy softwareFallback=no backend=openGL")
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
        logMPV("PiP prepare begin id=\(pipTransitionID) \(pipDebugSnapshot())")
        logMPV("switching to OpenGL sample-buffer PiP render path")
        rememberSelectedVideoTrack(reason: "enter-pip")
        stopForegroundDisplayLink(reason: "enter-pip")
        isRenderScheduled = false
        pipBridge.resetDiagnosticsForNewAttempt()
        currentMode = .pictureInPicture
        logMPV("PiP prepare entered OpenGL-backed mode id=\(pipTransitionID) \(pipDebugSnapshot())")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
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
            guard let self else { return }
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
            self.glView.markDrawableNeedsRebuild()
        }
        if let handle = mpv {
            mpv_wakeup(handle)
        }
        requestRenderBurst(reason: reason, count: 6, interval: 0.08)
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
        performOnRenderQueueSync {
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
            logMPV("OpenGL render context creation failed status=\(status)")
            throw RendererError.renderContextCreation(status)
        }
        installRenderUpdateCallback()
        logMPV("OpenGL render context ready")
    }

    private func destroyRenderContext() {
        guard let context = renderContext else { return }
        logMPV("destroying render context mode=\(currentMode)")
        pipBridge.waitForPendingRenders()
        performOnRenderQueueSync {
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
            if #available(iOS 15.0, *) {
                link.preferredFrameRateRange = CAFrameRateRange(
                    minimum: Float(min(24, self.foregroundFramesPerSecond)),
                    maximum: Float(self.foregroundFramesPerSecond),
                    preferred: Float(self.foregroundFramesPerSecond)
                )
            } else {
                link.preferredFramesPerSecond = self.foregroundFramesPerSecond
            }
            link.add(to: .main, forMode: .common)
            self.foregroundDisplayLinkTarget = target
            self.foregroundDisplayLink = link
            self.logMPV("foreground display link started reason=\(reason) fps=\(self.foregroundFramesPerSecond) renderQueue=enabled")
        }
    }

    private func stopForegroundDisplayLink(reason: String) {
        let stopDisplayLink = { [weak self] in
            guard let self, let link = self.foregroundDisplayLink else { return }
            link.invalidate()
            self.foregroundDisplayLink = nil
            self.foregroundDisplayLinkTarget = nil
            self.logMPV("foreground display link stopped reason=\(reason)")
        }
        if Thread.isMainThread {
            stopDisplayLink()
        } else {
            DispatchQueue.main.sync(execute: stopDisplayLink)
        }
        performOnRenderQueueSync {
            isRenderScheduled = false
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
        guard !isPaused || isLoading || forcedOpenGLRenderCount > 0 else { return }
        enqueueForegroundRender(reason: "display-link")
    }

    private func enqueueForegroundRender(reason: String) {
        performOnRenderQueueAsync { [weak self] in
            guard let self, self.isRunning, !self.isStopping, self.currentMode == .openGL else { return }
            guard !self.isRenderScheduled else { return }
            self.isRenderScheduled = true
            self.drawOpenGLFrame()
            self.isRenderScheduled = false
        }
    }

    private func scheduleRender(force: Bool = false) {
        guard isRunning, !isStopping else { return }
        if force {
            let applyForce = { [weak self] in
                guard let self, self.isRunning, !self.isStopping else { return }
                switch self.currentMode {
                case .openGL:
                    self.forcedOpenGLRenderCount = max(self.forcedOpenGLRenderCount, 1)
                case .pictureInPicture:
                    self.forcedPiPRenderCount = max(self.forcedPiPRenderCount, 1)
                }
                self.scheduleRender()
            }
            if currentMode == .openGL {
                performOnRenderQueueAsync {
                    applyForce()
                }
            } else {
                DispatchQueue.main.async {
                    applyForce()
                }
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
        performOnRenderQueueAsync { [weak self] in
            guard let self, self.isRunning, !self.isStopping, self.currentMode == .openGL else { return }
            if self.foregroundDisplayLink != nil, self.forcedOpenGLRenderCount == 0 {
                return
            }
            guard !self.isRenderScheduled else { return }
            self.isRenderScheduled = true
            let now = CACurrentMediaTime()
            let delay = max(0, self.foregroundFrameInterval - (now - self.lastForegroundRenderTime))
            self.renderQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                guard self.isRunning, !self.isStopping, self.currentMode == .openGL else {
                    self.isRenderScheduled = false
                    return
                }
                self.isRenderScheduled = false
                self.drawOpenGLFrame()
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
        guard glView.prepareDrawable() else {
            EAGLContext.setCurrent(nil)
            return
        }
        defer { EAGLContext.setCurrent(nil) }

        lastForegroundRenderTime = CACurrentMediaTime()
        EAGLContext.setCurrent(glContext)

        let updateFlags = UInt32(mpv_render_context_update(context))
        let shouldForceRender = forcedOpenGLRenderCount > 0
        if shouldForceRender {
            forcedOpenGLRenderCount -= 1
        }
        if updateFlags & MPV_RENDER_UPDATE_FRAME.rawValue != 0 || shouldForceRender {
            glViewport(0, 0, GLsizei(glView.drawableWidth), GLsizei(glView.drawableHeight))

            var fbo = LunaMPVOpenGLFBO(
                fbo: Int32(glView.currentFramebuffer()),
                w: Int32(glView.drawableWidth),
                h: Int32(glView.drawableHeight),
                internal_format: Int32(GL_RGBA)
            )
            var flipY: Int32 = 1
            let result = renderOpenGLFrame(context: context, fbo: &fbo, flipY: &flipY, reportSwap: false)
            if result >= 0 {
                glView.presentDrawable()
                mpv_render_context_report_swap(context)
            }
        }

        if updateFlags > 0 {
            scheduleRender()
        }
    }

    private func renderOpenGLFrame(
        context: OpaquePointer,
        fbo: inout LunaMPVOpenGLFBO,
        flipY: inout Int32,
        reportSwap: Bool
    ) -> Int32 {
        let result = withUnsafeMutablePointer(to: &fbo) { fboPointer in
            withUnsafeMutablePointer(to: &flipY) { flipPointer in
                openGLRenderParams[0] = mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPointer))
                openGLRenderParams[1] = mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPointer))
                openGLRenderParams[2] = mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
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
            let renderSize = currentPiPRenderSize()
            pipRenderRequestCount += 1
            if pipRenderRequestCount <= 5 || pipRenderRequestCount % 60 == 0 {
                logMPV("PiP render frame request count=\(pipRenderRequestCount) immediate=\(immediate) force=\(force) flags=\(updateFlags) size=\(String(format: "%.0fx%.0f", renderSize.width, renderSize.height)) \(pipDebugSnapshot())")
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
                }
            }
        default:
            break
        }
    }

    private func handleFileLoaded() {
        isReadyToSeek = true
        setLoading(false)
        refreshVideoState()
        let elapsed = currentLoadStartedAt.map { String(format: "%.2f", Date().timeIntervalSince($0)) } ?? "nil"
        logMPV("file loaded gen=\(loadGeneration) elapsed=\(elapsed)s duration=\(String(format: "%.2f", cachedDuration)) position=\(String(format: "%.2f", cachedPosition))")
        logTrackSummaryIfChanged(reason: "file-loaded")
        logPlaybackDiagnostics(reason: "file-loaded")
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

        let viewSize = glView.bounds.size
        if viewSize.width > 0, viewSize.height > 0 {
            logMPV("PiP render using GL bounds fallback size=\(String(format: "%.0fx%.0f", viewSize.width, viewSize.height))")
            return viewSize
        }

        let layerSize = displayLayer.bounds.size
        if layerSize.width > 0, layerSize.height > 0 {
            logMPV("PiP render using displayLayer fallback size=\(String(format: "%.0fx%.0f", layerSize.width, layerSize.height))")
            return layerSize
        }

        logMPV("PiP render using default fallback size=640x360")
        return CGSize(width: 640, height: 360)
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
                    if shouldLogPlaybackDiagnostics(for: bucket) {
                        logPlaybackDiagnostics(reason: "progress-\(bucket * 10)s")
                    }
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

    private func shouldLogPlaybackDiagnostics(for progressBucket: Int) -> Bool {
        guard progressBucket != lastPlaybackDiagnosticsBucket else { return false }
        if progressBucket <= 6 { return true }
        return progressBucket % 3 == 0
    }

    private func logPlaybackDiagnostics(reason: String) {
        lastPlaybackDiagnosticsBucket = Int(cachedPosition / 10.0)
        let size = currentVideoSize()
        logMPVCrashProbe("diagnostics checkpoint reason=\(reason) gen=\(loadGeneration) mode=\(currentMode) backend=openGL pos=\(String(format: "%.2f", cachedPosition))/\(String(format: "%.2f", cachedDuration)) loading=\(isLoading) ready=\(isReadyToSeek) paused=\(isPaused) running=\(isRunning) stopping=\(isStopping) video=\(String(format: "%.0fx%.0f", size.width, size.height)) lastTracks={\(shortText(lastTrackSummary, limit: 260))}")
        guard let handle = mpv else {
            logMPVCrashProbe("diagnostics values reason=\(reason) skipped: mpv handle nil")
            return
        }
        let videoCodec = getStringProperty(handle: handle, name: "video-codec") ?? "nil"
        let audioCodec = getStringProperty(handle: handle, name: "audio-codec") ?? "nil"
        let hwdec = getStringProperty(handle: handle, name: "hwdec-current") ?? "nil"
        let videoFormat = getStringProperty(handle: handle, name: "video-format") ?? "nil"
        let pixelFormat = getStringProperty(handle: handle, name: "video-params/pixelformat")
            ?? getStringProperty(handle: handle, name: "video-params/format")
            ?? "nil"
        let hwPixelFormat = getStringProperty(handle: handle, name: "video-params/hw-pixelformat") ?? "nil"
        let videoFilter = getStringProperty(handle: handle, name: "vf") ?? "nil"
        let hwdecImageFormat = getStringProperty(handle: handle, name: "hwdec-image-format") ?? "nil"
        let fps = getStringProperty(handle: handle, name: "estimated-vf-fps")
            ?? getStringProperty(handle: handle, name: "container-fps")
            ?? "nil"
        let voDrops = getStringProperty(handle: handle, name: "vo-drop-frame-count") ?? "nil"
        let decoderDrops = getStringProperty(handle: handle, name: "decoder-frame-drop-count") ?? "nil"
        logMPVCrashProbe("diagnostics values reason=\(reason) backend=openGL codecV=\(videoCodec) codecA=\(audioCodec) hwdec=\(hwdec) hwdecImage=\(hwdecImageFormat) videoFormat=\(videoFormat) pixelFormat=\(pixelFormat) hwPixelFormat=\(hwPixelFormat) vf=\(videoFilter) fps=\(fps) voDrops=\(voDrops) decoderDrops=\(decoderDrops)")
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
        logMPV("setAudioTrack id=\(id)")
        setProperty(name: "aid", value: String(id))
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
        logMPV("applySubtitleStyle visible=\(style.isVisible) font=\(String(format: "%.1f", style.fontSize)) stroke=\(String(format: "%.1f", style.strokeWidth))")
        setProperty(name: "sub-visibility", value: style.isVisible ? "yes" : "no")
        setProperty(name: "sub-font-size", value: String(Int(max(10, min(style.fontSize, 72)))))
        setProperty(name: "sub-color", value: mpvColor(style.foregroundColor))
        setProperty(name: "sub-border-color", value: mpvColor(style.strokeColor))
        setProperty(name: "sub-border-size", value: String(format: "%.2f", max(0, min(style.strokeWidth * 1.5, 5.0))))
        setProperty(name: "sub-shadow-offset", value: "0")
        setProperty(name: "sub-ass-override", value: "yes")
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
    func canStartSampleBufferPictureInPicture() -> Bool { false }
    func prepareForPictureInPictureStart() { }
    func finishPictureInPicture() { }
    func primePictureInPictureFrames(reason: String) { }
    func activatePictureInPictureLayer() { }
    func isPictureInPicturePrimed() -> Bool { false }
    func resumeForegroundRendering(reason: String) { }
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
