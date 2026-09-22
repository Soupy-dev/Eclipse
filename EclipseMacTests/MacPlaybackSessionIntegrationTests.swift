import AppKit
import AVFoundation
import Combine
import Darwin
import MPVKitSampleBufferGPL
import XCTest
@testable import EclipseMac

@MainActor
final class MacPlaybackSessionIntegrationTests: XCTestCase {
    func testMPVSessionPublishesRealClockAndStopsExactlyOnce() async throws {
        try await exercise(engine: .mpv)
    }

    func testAVPlayerSessionPublishesRealClockAndStopsExactlyOnce() async throws {
        try await exercise(engine: .avPlayer)
    }

    func testIntelDrawableCapPreservesRepeatedOddSizedGeometry() throws {
        guard PlatformCapabilities.current.intelMacCompatibility.isEnabled else {
            throw XCTSkip("Intel-only synchronous drawable cap.")
        }
        let layer = MPVGPUPlayerMetalLayer()
        let bounds = CGRect(x: 0, y: 0, width: 6_401, height: 3_601)
        layer.frame = bounds
        layer.contentsScale = 2
        let initialScale = layer.contentsScale
        let initialDrawable = layer.drawableSize
        XCTAssertLessThanOrEqual(initialDrawable.width * initialDrawable.height,
            CGFloat(MacIntelPlaybackPolicy.maximumDrawablePixelCount))
        for _ in 0..<100 {
            layer.frame = bounds
            layer.bounds = bounds
            layer.contentsScale = layer.contentsScale
            XCTAssertEqual(layer.contentsScale, initialScale)
            XCTAssertEqual(layer.drawableSize, initialDrawable)
        }
    }

    func testMPVRendererPresentsFreshVideoAfterResizeAndExternalSubtitleSelection() async throws {
        try await withDirectRenderer { renderer, window, directory in
            let validation = await renderer.validateForegroundVideoAfterSystemResume(
                timeout: 2,
                allowsSoftwareDecoding: PlatformCapabilities.current.intelMacCompatibility.isEnabled
            )
            guard case .healthy = validation else {
                XCTFail("The renderer must prove a fresh inline video frame, received \(validation).")
                throw URLError(.cannotDecodeContentData)
            }
            if PlatformCapabilities.current.intelMacCompatibility.isEnabled {
                let concurrentValidation = Task {
                    await renderer.validateForegroundVideoAfterSystemResume(timeout: 2, allowsSoftwareDecoding: true)
                }
                await Task.yield()
                do {
                    try await renderer.preparePictureInPicture()
                    XCTFail("Intel PiP preparation must be rejected while inline validation is active.")
                } catch let error as MPVGPUPlayerRendererError {
                    guard case .pictureInPictureUnavailable = error else { throw error }
                }
                let preservedValidation = await concurrentValidation.value
                guard case .healthy = preservedValidation else {
                    XCTFail("Intel PiP rejection must preserve inline frame validation: \(preservedValidation).")
                    throw URLError(.cannotDecodeContentData)
                }
                XCTAssertEqual(renderer.pictureInPictureState, .idle)
                XCTAssertNil(renderer.selectedPictureInPictureBackend)
                XCTAssertEqual(renderer.diagnosticsSnapshot().activeMPVInstanceCount, 1)
            }
            let appliedBefore = renderer.diagnosticsSnapshot().inlineResizeApplicationCount
            renderer.updateInlineLayerLayout(bounds: CGRect(x: 0, y: 0, width: 6_400, height: 3_600), contentsScale: 2)
            if PlatformCapabilities.current.intelMacCompatibility.isEnabled {
                let immediateSize = renderer.inlineLayer.drawableSize
                XCTAssertLessThanOrEqual(immediateSize.width * immediateSize.height,
                    CGFloat(MacIntelPlaybackPolicy.maximumDrawablePixelCount),
                    "Intel must cap drawables before the native renderer can allocate a swapchain.")
            }
            try await waitForRenderer("A large drawable must be bounded without distorting its aspect ratio.",
                renderer: renderer, window: window) {
                renderer.diagnosticsSnapshot().inlineResizeApplicationCount > appliedBefore
            }
            let size = renderer.inlineLayer.drawableSize
            let maximumPixels = renderer.diagnosticsSnapshot().maximumInlineDrawablePixelCount
            XCTAssertGreaterThan(size.width, 1)
            XCTAssertGreaterThan(size.height, 1)
            XCTAssertLessThanOrEqual(size.width * size.height, CGFloat(maximumPixels))
            XCTAssertEqual(size.width / size.height, 16.0 / 9.0, accuracy: 0.002)
            if PlatformCapabilities.current.intelMacCompatibility.isEnabled {
                XCTAssertEqual(maximumPixels, MacIntelPlaybackPolicy.maximumDrawablePixelCount)
                XCTAssertFalse(renderer.inlineLayer.wantsExtendedDynamicRangeContent)
            }
            renderer.updateInlineLayerLayout(bounds: CGRect(x: 0, y: 0, width: 640, height: 360), contentsScale: 1)
            let subtitle = directory.appendingPathComponent("fixture.srt")
            try "1\n00:00:00,000 --> 00:00:11,900\nEclipse Intel subtitle fixture\n".write(
                to: subtitle, atomically: true, encoding: .utf8
            )
            renderer.loadExternalSubtitles(urls: [subtitle.absoluteString], names: ["Fixture"], selectFirst: true)
            try await waitForRenderer("The external subtitle must load and become the selected track.",
                renderer: renderer, window: window) {
                renderer.currentSubtitleTrackID() >= 0 && renderer.subtitleTracks().count == 1
            }
            let selected = renderer.currentSubtitleTrackID()
            XCTAssertEqual(renderer.currentExternalSubtitleURL(), subtitle.absoluteString)
            renderer.disableSubtitles()
            try await waitForRenderer("Disabling subtitles must preserve the loaded track.",
                renderer: renderer, window: window) {
                renderer.currentSubtitleTrackID() < 0 && renderer.subtitleTracks().count == 1
            }
            renderer.setSubtitleTrack(id: selected)
            try await waitForRenderer("A previously loaded external subtitle must be selectable again.",
                renderer: renderer, window: window) {
                renderer.currentSubtitleTrackID() == selected
            }
            XCTAssertGreaterThanOrEqual(renderer.command(["seek", "2", "absolute+exact"]), 0)
            try await waitForRenderer("Seeking with external subtitles must resume actual video presentation.",
                renderer: renderer, window: window) { renderer.currentTime > 2.2 }
            let afterSeek = await renderer.validateForegroundVideoAfterSystemResume(
                timeout: 2,
                allowsSoftwareDecoding: PlatformCapabilities.current.intelMacCompatibility.isEnabled
            )
            guard case .healthy = afterSeek else {
                XCTFail("Video must present a fresh frame after resize and subtitle selection: \(afterSeek).")
                throw URLError(.cannotDecodeContentData)
            }
        }
    }

    func testAppleSiliconNativePictureInPictureBridgeReturnsToFreshInlineVideo() async throws {
        guard !PlatformCapabilities.current.intelMacCompatibility.isEnabled else {
            throw XCTSkip("Apple Silicon PiP regression coverage.")
        }
        try await withDirectRenderer { renderer, window, _ in
            XCTAssertTrue(MPVGPUPlayerRenderer.supportsPictureInPicture)
            try await renderer.preparePictureInPicture()
            let prepared = renderer.diagnosticsSnapshot()
            XCTAssertGreaterThan(prepared.pictureInPictureEnqueuedFrameCount, 0)
            XCTAssertNotNil(prepared.selectedPictureInPictureBackend)
            XCTAssertNotEqual(prepared.selectedPictureInPictureBackend, .compatibilityDualSession)
            renderer.beginPictureInPicture()
            try await waitForRenderer("The native PiP bridge must keep presenting frames after activation.",
                renderer: renderer, window: window) {
                if case .active = renderer.pictureInPictureState {
                    return renderer.diagnosticsSnapshot().pictureInPictureEnqueuedFrameCount
                        > prepared.pictureInPictureEnqueuedFrameCount
                }
                return false
            }
            let restored = await renderer.endPictureInPictureAndWait(restoringInlinePlayback: true)
            XCTAssertTrue(restored, "Native PiP restoration must prove inline presentation.")
            XCTAssertEqual(renderer.pictureInPictureState, .idle)
            let validation = await renderer.validateForegroundVideoAfterSystemResume(timeout: 2)
            guard case .healthy = validation else {
                XCTFail("Apple Silicon must present fresh inline video after the PiP bridge returns: \(validation).")
                throw URLError(.cannotDecodeContentData)
            }
        }
    }

    func testIntelMPVRejectsPictureInPictureBeforeChangingRendererState() async throws {
        guard PlatformCapabilities.current.intelMacCompatibility.isEnabled else {
            throw XCTSkip("Intel-only PiP restriction.")
        }
        let renderer = MPVGPUPlayerRenderer()
        let before = renderer.diagnosticsSnapshot()
        var changes = 0
        renderer.onStateChange = { _ in changes += 1 }
        renderer.onPictureInPictureStateChange = { _ in changes += 1 }
        XCTAssertFalse(MPVGPUPlayerRenderer.supportsPictureInPicture)
        do {
            try await renderer.preparePictureInPicture()
            XCTFail("Intel MPV must reject PiP preparation before starting or allocating a backend.")
        } catch let error as MPVGPUPlayerRendererError {
            guard case .pictureInPictureUnavailable = error else {
                XCTFail("Expected an Intel capability rejection, received \(error).")
                throw error
            }
        }
        XCTAssertEqual(renderer.diagnosticsSnapshot(), before)
        XCTAssertEqual(changes, 0)
        renderer.beginPictureInPicture()
        XCTAssertEqual(renderer.diagnosticsSnapshot(), before)
        XCTAssertEqual(changes, 0)
        renderer.stop()
        await renderer.waitUntilStopped()
    }

    func testIntelSoftwareDecodingRequiresFreshFrameAndExplicitValidationOptIn() async throws {
        guard PlatformCapabilities.current.intelMacCompatibility.isEnabled else {
            throw XCTSkip("Intel-only software fallback validation.")
        }
        try await withDirectRenderer(hardwareDecoding: "no") { renderer, window, _ in
            try await waitForRenderer("The fixture must run with an explicitly selected software decoder.",
                renderer: renderer, window: window) { renderer.refreshCurrentHardwareDecoder() == "no" }
            let defaultValidation = await renderer.validateForegroundVideoAfterSystemResume(timeout: 2)
            XCTAssertEqual(defaultValidation, .decoderUnavailable(current: "no"))
            let softwareValidation = await renderer.validateForegroundVideoAfterSystemResume(
                timeout: 2, allowsSoftwareDecoding: true
            )
            XCTAssertEqual(softwareValidation, .healthy(decoder: "no"))
            renderer.pause()
            try await waitForRenderer("Software playback must honor pause before foreground validation.",
                renderer: renderer, window: window) { renderer.diagnosticsSnapshot().isPaused }
            let pausedValidation = await renderer.validateForegroundVideoAfterSystemResume(
                timeout: 2, allowsSoftwareDecoding: true
            )
            XCTAssertEqual(pausedValidation, .playbackDeferred(decoder: "no"))
            renderer.play()
            let resumedValidation = await renderer.validateForegroundVideoAfterSystemResume(
                timeout: 2, allowsSoftwareDecoding: true
            )
            XCTAssertEqual(resumedValidation, .healthy(decoder: "no"))
        }
    }

    private func withDirectRenderer(
        hardwareDecoding: String? = nil,
        body: (MPVGPUPlayerRenderer, NSWindow, URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EclipseMacRendererTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("fixture.mov")
        try await Task.detached(priority: .utility) { try Self.makeVideo(at: fixture) }.value
        let compatibility = PlatformCapabilities.current.intelMacCompatibility
        let decoding = hardwareDecoding ?? (compatibility.isEnabled
            ? MacIntelPlaybackPolicy.hardwareDecoding : "videotoolbox,videotoolbox-copy")
        let extraOptions = MacIntelPlaybackPolicy.options([
            "ao": PlaybackAudioOutputPolicy.driverList, "hwdec-software-fallback": "no",
            "keep-open": "yes", "pause": "no", "demuxer-thread": "yes",
            "vulkan-async-compute": "no", "vulkan-async-transfer": "no",
            "vulkan-queue-count": "1", "vulkan-swap-mode": "fifo"
        ], compatibility: compatibility)
        let options = MPVGPUPlayerRendererOptions(
            hardwareDecoding: decoding,
            enablesTargetColorspaceHint: false,
            pictureInPicturePreparationTimeout: 3,
            maximumInlineDrawablePixelCount: compatibility.isEnabled ? MacIntelPlaybackPolicy.maximumDrawablePixelCount : 0,
            additionalMPVOptions: extraOptions
        )
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = MacPlaybackSurfaceView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        view.showMPV()
        let renderer = MPVGPUPlayerRenderer(view: view.gpuView, options: options)
        view.installPictureInPictureLayer(renderer.pictureInPictureDisplayLayer)
        window.contentView = view
        window.orderFront(nil)
        defer {
            renderer.stop()
            window.contentView = nil
            window.close()
        }
        do {
            try renderer.start()
            if compatibility.isEnabled {
                let enforced = MacIntelPlaybackPolicy.options(["hwdec": decoding], compatibility: compatibility)
                for (name, value) in enforced.sorted(by: { $0.key < $1.key }) {
                    let status = renderer.command(["set", name, value])
                    XCTAssertGreaterThanOrEqual(status, 0, "The actual MPV runtime rejected Intel option \(name).")
                    guard status >= 0 else { throw URLError(.cannotDecodeContentData) }
                }
            }
            renderer.updateInlineLayerLayout(bounds: view.bounds, contentsScale: 1)
            renderer.load(fixture, generation: 1)
            renderer.play()
            try await waitForRenderer("The renderer must load the fixture and advance its clock.",
                renderer: renderer, window: window) {
                renderer.currentTime > 0.3 && renderer.duration > 11.5 && renderer.currentVideoTrackID() >= 0
            }
            try await body(renderer, window, directory)
        } catch {
            try? await stopDirectRenderer(renderer, window: window)
            throw error
        }
        try await stopDirectRenderer(renderer, window: window)
    }

    private func stopDirectRenderer(_ renderer: MPVGPUPlayerRenderer, window: NSWindow) async throws {
        renderer.stop()
        var stopped = false
        let shutdown = Task { await renderer.waitUntilStopped(); stopped = true }
        defer { shutdown.cancel() }
        try await waitForRenderer("The direct renderer must release its resources within the shutdown deadline.",
            renderer: renderer, window: window) { stopped }
        XCTAssertEqual(renderer.diagnosticsSnapshot().state, .stopped)
    }

    private func waitForRenderer(_ message: String, renderer: MPVGPUPlayerRenderer, window: NSWindow,
                                 condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition(), Date() < deadline {
            if case .failed(let failure) = renderer.diagnosticsSnapshot().state {
                XCTFail("\(message) Renderer error: \(failure)")
                throw URLError(.cannotDecodeContentData)
            }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard condition() else {
            XCTFail("\(message) Diagnostics: \(renderer.diagnosticsSnapshot())")
            throw URLError(.timedOut)
        }
    }

    private func exercise(engine: PlaybackEngine) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EclipseMacSessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.mov")
        try await Task.detached(priority: .utility) { try Self.makeVideo(at: url) }.value
        let asset = AVURLAsset(url: url)
        let fixtureDuration = try await asset.load(.duration).seconds
        XCTAssertEqual(fixtureDuration, 12, accuracy: 0.1)
        let suite = "EclipseMacSessionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resume = MacLocalPlaybackResumeStore(directory: directory.appendingPathComponent("Resume"))
        let owner = ProfileManager.shared.activeProfileID
        let authority = try XCTUnwrap(ProgressManager.shared.profileMutationAuthority(requiredOwner: owner))
        let request = PlaybackRequest(url: url,
            preset: PlayerPreset(id: .sdrRec709, title: "Fixture", summary: "", stream: nil, commands: []),
            mediaSelectionIntent: .init(preferredAudioLanguage: nil, preferredSubtitleLanguage: nil, subtitlesEnabled: false),
            title: "Native session fixture")
        let session = MacPlaybackSession(request: request, engine: engine, owner: owner, authority: authority,
            defaults: defaults, localResumeStore: resume)
        var publicationCount = 0
        let observation = session.objectWillChange.sink { publicationCount += 1 }
        defer { observation.cancel() }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        session.surface.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        window.contentView = session.surface
        window.orderFront(nil)
        var closeCount = 0
        session.onClose = { closeCount += 1 }
        defer {
            session.stop()
            window.contentView = nil
            window.close()
        }
        session.start()
        do {
            try await wait("\(engine) must publish readiness, duration, and a progressing clock.", session: session) {
                session.isReady && session.isPlaying && session.duration > 11.5 && session.position > 0.5
            }
            XCTAssertNil(session.request.mediaInfo)
            XCTAssertNil(session.errorMessage)
            XCTAssertEqual(session.engine, engine)
            XCTAssertEqual(session.duration, fixtureDuration, accuracy: 0.2)
            XCTAssertGreaterThan(session.position, 0.5)
            XCTAssertGreaterThan(publicationCount, 0)
            session.setPlaying(false, broadcast: false)
            try await Task.sleep(nanoseconds: 350_000_000)
            let pausedPosition = session.position
            try await Task.sleep(nanoseconds: 450_000_000)
            XCTAssertFalse(session.isPlaying)
            XCTAssertEqual(session.position, pausedPosition, accuracy: 0.15)
            session.seek(to: 5, broadcast: false)
            try await wait("\(engine) must publish a paused seek through the real renderer.", session: session) {
                abs(session.position - 5) < 0.35 && !session.isPlaying
            }
            let alternate: PlaybackEngine = engine == .mpv ? .avPlayer : .mpv
            for handoffEngine in [alternate, engine] {
                session.retryWithAlternateEngine()
                try await wait("An explicit engine handoff must preserve paused position and intent.", session: session) {
                    session.engine == handoffEngine && session.isReady && !session.isPlaying
                        && abs(session.position - 5) < 0.35
                }
                let handoffPosition = session.position
                try await Task.sleep(nanoseconds: 450_000_000)
                XCTAssertFalse(session.isPlaying)
                XCTAssertEqual(session.position, handoffPosition, accuracy: 0.15)
            }
            if PlatformCapabilities.current.intelMacCompatibility.isEnabled, session.engine == .mpv {
                let beforeWake = session.position
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
                await Task.yield()
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
                try await Task.sleep(nanoseconds: 500_000_000)
                XCTAssertFalse(session.isPlaying)
                XCTAssertEqual(session.position, beforeWake, accuracy: 0.15)
                XCTAssertNil(session.errorMessage)
            }
            session.setPlaying(true, broadcast: false)
            try await wait("\(engine) must resume the same clock after a seek.", session: session) {
                session.isPlaying && session.position > 5.5
            }
            if PlatformCapabilities.current.intelMacCompatibility.isEnabled, session.engine == .mpv {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                XCTAssertTrue(session.isPlaying)
                XCTAssertNil(session.errorMessage)
                XCTAssertGreaterThan(session.position, 5.5)
            }
            session.stop()
            session.stop()
            var shutdownCompleted = false
            let shutdown = Task { await session.waitUntilStopped(); shutdownCompleted = true }
            defer { shutdown.cancel() }
            try await wait("\(engine) must retire its renderer within the shutdown deadline.", session: session,
                failsOnPlaybackError: false) { shutdownCompleted }
            XCTAssertFalse(session.isCurrentOwner)
            XCTAssertEqual(closeCount, 1)
            let stoppedPosition = session.position
            session.start()
            session.setPlaying(true, broadcast: false)
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertEqual(session.position, stoppedPosition, accuracy: 0.01)
            XCTAssertEqual(closeCount, 1)
            XCTAssertGreaterThan(resume.currentTime(for: url, owner: owner), 5)
            XCTAssertTrue(resume.flushForMacTermination())
        } catch {
            session.stop()
            throw error
        }
    }

    private func wait(_ message: String, session: MacPlaybackSession, failsOnPlaybackError: Bool = true,
                      condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition(), Date() < deadline {
            if failsOnPlaybackError, let error = session.errorMessage {
                XCTFail("\(message) Player error: \(error)")
                throw URLError(.cannotDecodeContentData)
            }
            session.surface.window?.contentView?.layoutSubtreeIfNeeded()
            session.surface.window?.displayIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard condition() else {
            XCTFail("\(message) ready=\(session.isReady) playing=\(session.isPlaying) position=\(session.position) duration=\(session.duration)")
            throw URLError(.timedOut)
        }
    }

    nonisolated private static func makeVideo(at url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        defer { if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() } }
        let width = 640
        let height = 360
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 30]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        guard writer.canAdd(input) else { throw URLError(.cannotCreateFile) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? URLError(.cannotCreateFile) }
        writer.startSession(atSourceTime: .zero)
        let deadline = Date().addingTimeInterval(20)
        for frame in 0..<360 {
            while !input.isReadyForMoreMediaData && writer.status == .writing && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.002)
            }
            guard Date() < deadline, input.isReadyForMoreMediaData else { throw writer.error ?? URLError(.timedOut) }
            var optionalBuffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                nil, &optionalBuffer) == kCVReturnSuccess, let buffer = optionalBuffer,
                CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw URLError(.cannotCreateFile) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else {
                CVPixelBufferUnlockBaseAddress(buffer, [])
                throw URLError(.cannotCreateFile)
            }
            var color = 0xFF003366 | UInt32((frame * 2) % 255) << 16
            memset_pattern4(base, &color, CVPixelBufferGetBytesPerRow(buffer) * height)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw writer.error ?? URLError(.cannotWriteToFile)
            }
        }
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        guard finished.wait(timeout: .now() + 20) == .success, writer.status == .completed else {
            throw writer.error ?? URLError(.cannotWriteToFile)
        }
    }
}
