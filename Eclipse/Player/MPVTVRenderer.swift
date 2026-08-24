#if os(tvOS)
import AVFoundation
import AVKit
import CoreMedia
import MediaPlayer
import QuartzCore
import UIKit
import MPVKitSampleBufferGPL

@MainActor
final class MPVTVRenderer {
    enum State: Equatable {
        case idle
        case loading
        case ready
        case playing
        case paused
        case pictureInPicture
        case stopping
        case stopped
        case failed(String)
    }

    static var isAvailable: Bool { MPVGPUPlayerRenderer.isSupported }

    let view = MPVTVMetalHostView(frame: .zero)

    var onStateChange: ((State) -> Void)?
    var onPositionChange: ((_ position: Double, _ duration: Double) -> Void)?
    var onFirstFrame: (() -> Void)?
    var onStartupFailure: ((String) -> Void)?
    var onPlaybackFailure: ((String) -> Void)?
    var onPictureInPictureStopRequested: ((String) -> Void)?
    var onVideoFormatChange: ((MPVGPUPlayerRendererDiagnostics) -> Void)?
    var onTracksChange: (() -> Void)?

    private let renderer: MPVGPUPlayerRenderer
    private let audioSession = MPVTVAudioSession()
    private var request: PlaybackRequest?
    private var pendingResumePosition: Double?
    private var positionTimer: Timer?
    private var startupTimeout: DispatchWorkItem?
    private var externalSubtitleDownloads: [TVBoundedSubtitleDownload] = []
    private var externalSubtitleTemporaryFiles: [URL] = []
    private var externalSubtitleLoadGeneration = UUID()
    private(set) var state: State = .idle
    private(set) var hasRenderedFirstFrame = false
    private(set) var isPaused = true
    private var didReportFatalFailure = false
    private var lastTrackSignature = ""
    private var lastVideoConfigurationSignature = ""
    private var lastKnownOutputDrawableSize: CGSize = .zero
    private var lifecycleGeneration: UInt64 = 0
    private var lastLoggedPictureInPictureDiagnosticsSignature = ""
    private var lastLoggedPictureInPicturePressureTotal = 0
    private var lastLoggedAudioRecoveryCount = 0

    var currentTime: Double { renderer.currentTime }
    var duration: Double { renderer.duration }
    var pictureInPictureDisplayLayer: AVSampleBufferDisplayLayer {
        renderer.pictureInPictureDisplayLayer
    }

    private static func shaderCacheDirectory() -> String? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = caches.appendingPathComponent("mpv-shader-cache", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return directory.path
    }

    init() {
        let prefersSurround = ProfileSettingsStore.active.object(forKey: "mpvSurroundSoundEnabled") as? Bool ?? true
        let defaultSubtitleLanguage = ProfileSettingsStore.active.string(forKey: "defaultSubtitleLanguage") ?? "eng"
        var additionalOptions = [
            "audio-channels": prefersSurround ? "auto" : "stereo",
            "slang": defaultSubtitleLanguage,
            "cache": "yes",
            "cache-pause-wait": "5",
            "demuxer-thread": "yes",
            "demuxer-max-bytes": "80M",
            "demuxer-readahead-secs": "10",
            "hwdec-software-fallback": "no",
            "vd-lavc-software-fallback": "no",
            "vulkan-async-compute": "no",
            "vulkan-async-transfer": "no",
            "vulkan-queue-count": "1",
            "vulkan-swap-mode": "fifo"
        ]
        if let shaderCacheDir = Self.shaderCacheDirectory() {
            additionalOptions["gpu-shader-cache"] = "yes"
            additionalOptions["gpu-shader-cache-dir"] = shaderCacheDir
        }
        let options = MPVGPUPlayerRendererOptions(
            maximumPiPFrameSize: CGSize(width: 1920, height: 1080),
            preferredPiPFramesPerSecond: 30,
            inlineProfile: "fast",
            hardwareDecoding: "videotoolbox",
            enablesTargetColorspaceHint: true,
            pausesInlineRendererDuringPictureInPicture: true,
            pictureInPictureBackendPreference: .automatic,
            maximumInFlightPictureInPictureFrames: 3,
            pictureInPicturePreparationTimeout: 1,
            additionalMPVOptions: additionalOptions
        )
        renderer = MPVGPUPlayerRenderer(
            inlineLayer: MPVGPUPlayerMetalLayer(),
            pictureInPictureDisplayLayer: AVSampleBufferDisplayLayer(),
            options: options
        )
        view.host(renderer.inlineLayer)
        view.onLayoutChange = { [weak self] bounds, scale in
            self?.lastKnownOutputDrawableSize = CGSize(
                width: bounds.width * scale,
                height: bounds.height * scale
            )
            self?.renderer.updateInlineLayerLayout(bounds: bounds, contentsScale: scale)
        }
    }

    func start(_ request: PlaybackRequest) throws {
        if state == .stopping {

            Logger.shared.log(
                "[MPVTVRenderer] start rejected reason=teardown-in-progress renderer={\(pictureInPictureDebugSnapshot())}",
                type: "MPV"
            )
            throw MPVGPUPlayerRendererError.teardownInProgress
        }
        guard state == .idle || state == .stopped else { return }
        guard Self.isAvailable else {
            throw MPVMetalSampleBufferRendererError.metalUnavailable
        }

        self.request = request
        lifecycleGeneration &+= 1
        configureCallbacks(generation: lifecycleGeneration)
        pendingResumePosition = resolvedResumePosition(for: request)
        hasRenderedFirstFrame = false
        didReportFatalFailure = false
        lastLoggedPictureInPictureDiagnosticsSignature = ""
        lastLoggedPictureInPicturePressureTotal = 0
        lastLoggedAudioRecoveryCount = 0
        Logger.shared.log(
            "[MPVTVRenderer] start begin lifecycleGeneration=\(lifecycleGeneration)",
            type: "MPV"
        )
        audioSession.activate()
        updateState(.loading)

        do {
            try renderer.start()
            if let preferredAudioLanguage = request.mediaSelectionIntent.preferredAudioLanguage {
                _ = renderer.command(["set", "alang", preferredAudioLanguage])
            }
            renderer.load(request.url, headers: request.headers)
            applySubtitleDefaults()
            loadExternalSubtitles(for: request)
            renderer.setSpeed(resolvedDefaultSpeed())
            renderer.play()
            startPositionUpdates()
            scheduleStartupTimeout()
            Logger.shared.log(
                "[MPVTVRenderer] start completed lifecycleGeneration=\(lifecycleGeneration) renderer={\(pictureInPictureDebugSnapshot())}",
                type: "MPV"
            )
        } catch {
            Logger.shared.log(
                "[MPVTVRenderer] start failed error=\(error) renderer={\(pictureInPictureDebugSnapshot())}",
                type: "MPV"
            )
            fail(error.localizedDescription, beforeFirstFrame: true)
            throw error
        }
    }

    func stop() {
        guard state != .stopped, state != .stopping else { return }
        Logger.shared.log(
            "[MPVTVRenderer] stop requested lifecycleGeneration=\(lifecycleGeneration) renderer={\(pictureInPictureDebugSnapshot())}",
            type: "MPV"
        )
        lifecycleGeneration &+= 1
        startupTimeout?.cancel()
        startupTimeout = nil
        positionTimer?.invalidate()
        positionTimer = nil
        cancelExternalSubtitleLoading()
        updateState(.stopping)
        renderer.stop()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.renderer.waitUntilStopped()
            self.audioSession.deactivate()
            self.updateState(.stopped)
            Logger.shared.log(
                "[MPVTVRenderer] stop drained lifecycleGeneration=\(self.lifecycleGeneration)",
                type: "MPV"
            )
        }
    }

    func waitUntilStopped() async {
        await renderer.waitUntilStopped()
    }

    func play() {
        isPaused = false
        renderer.play()
        updateState(.playing)
    }

    func pause() {
        isPaused = true
        renderer.pause()
        updateState(.paused)
    }

    func togglePlayback() {
        isPaused ? play() : pause()
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        renderer.seek(to: max(0, min(seconds, duration > 0 ? duration : seconds)))
        emitPosition()
    }

    func seek(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func setSpeed(_ speed: Double) {
        renderer.setSpeed(max(0.25, min(speed, 3)))
    }

    func audioTracks() -> [MPVMetalSampleBufferTrack] { renderer.audioTracks() }
    func subtitleTracks() -> [MPVMetalSampleBufferTrack] { renderer.subtitleTracks() }
    func setAudioTrack(_ id: Int) { renderer.setAudioTrack(id: id); onTracksChange?() }
    func setSubtitleTrack(_ id: Int) { renderer.setSubtitleTrack(id: id); onTracksChange?() }
    func disableSubtitles() { renderer.disableSubtitles(); onTracksChange?() }

    private func loadExternalSubtitles(for request: PlaybackRequest) {
        cancelExternalSubtitleLoading()
        guard !request.subtitles.isEmpty else { return }

        let generation = UUID()
        externalSubtitleLoadGeneration = generation
        var resolvedURLs = Array<String?>(repeating: nil, count: request.subtitles.count)
        let group = DispatchGroup()

        for (index, rawValue) in request.subtitles.enumerated() {
            guard let url = URL(string: rawValue) else { continue }
            let rawHeaders = request.subtitleHeadersByURL?[rawValue]
                ?? request.subtitleHeadersByURL?[url.absoluteString]
                ?? [:]
            let headers = AVPlayerResourceLoader.sanitizedHTTPHeaders(rawHeaders)

            guard !headers.isEmpty,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                resolvedURLs[index] = rawValue
                continue
            }

            group.enter()
            let download = TVBoundedSubtitleDownload(url: url, headers: headers)
            externalSubtitleDownloads.append(download)
            download.start { [weak self, weak download] result in
                defer { group.leave() }
                guard let self,
                      self.externalSubtitleLoadGeneration == generation,
                      self.state != .stopped else { return }
                if let download {
                    self.externalSubtitleDownloads.removeAll { $0 === download }
                }
                guard case .success(let data) = result else { return }

                let rawExtension = url.pathExtension.lowercased()
                let safeExtension = rawExtension.range(
                    of: #"^[a-z0-9]{1,8}$"#,
                    options: .regularExpression
                ) != nil ? rawExtension : "sub"
                let fileURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("eclipse-subtitle-\(UUID().uuidString)")
                    .appendingPathExtension(safeExtension)
                do {
                    try data.write(to: fileURL, options: .atomic)
                    self.externalSubtitleTemporaryFiles.append(fileURL)
                    resolvedURLs[index] = fileURL.absoluteString
                } catch {
                    Logger.shared.log(
                        "[TVPlayback] protected subtitle staging failed category=local-write",
                        type: "Player"
                    )
                }
            }
        }

        let applyResolvedTracks = { [weak self] in
            guard let self,
                  self.externalSubtitleLoadGeneration == generation,
                  self.state != .stopped else { return }
            let indexedTracks = resolvedURLs.enumerated().compactMap { index, url -> (String, String?)? in
                guard let url else { return nil }
                let name = request.subtitleNames.flatMap { names in
                    names.indices.contains(index) ? names[index] : nil
                }
                return (url, name)
            }
            guard !indexedTracks.isEmpty else { return }
            let hasSuppliedNames = indexedTracks.contains { $0.1 != nil }
            self.renderer.loadExternalSubtitles(
                urls: indexedTracks.map(\.0),
                names: hasSuppliedNames
                    ? indexedTracks.map { $0.1 ?? "Subtitle" }
                    : nil,
                selectFirst: request.mediaSelectionIntent.subtitlesEnabled
            )
        }

        if externalSubtitleDownloads.isEmpty {
            applyResolvedTracks()
        } else {
            group.notify(queue: .main, execute: applyResolvedTracks)
        }
    }

    private func cancelExternalSubtitleLoading() {
        externalSubtitleLoadGeneration = UUID()
        let downloads = externalSubtitleDownloads
        externalSubtitleDownloads.removeAll()
        downloads.forEach { $0.cancel(reportCancellation: true) }
        externalSubtitleTemporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        externalSubtitleTemporaryFiles.removeAll()
    }

    var canStartPictureInPicture: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
            && (ProfileSettingsStore.active.object(forKey: "mpvPictureInPictureEnabled") as? Bool ?? true)
    }

    func preparePictureInPicture() async throws {
        guard canStartPictureInPicture else {
            Logger.shared.log(
                "[MPVTVRenderer] PiP prepare blocked reason=unavailable renderer={\(pictureInPictureDebugSnapshot())}",
                type: "MPV"
            )
            throw MPVGPUPlayerRendererError.pictureInPictureUnavailable("tvOS PiP is unavailable")
        }
        Logger.shared.log(
            "[MPVTVRenderer] PiP prepare begin renderer={\(pictureInPictureDebugSnapshot())}",
            type: "MPV"
        )
        do {
            try await renderer.preparePictureInPicture()
        } catch {
            Logger.shared.log(
                "[MPVTVRenderer] PiP prepare failed error=\(error) renderer={\(pictureInPictureDebugSnapshot())}",
                type: "MPV"
            )
            throw error
        }
        let diagnostics = renderer.diagnosticsSnapshot()
        logPictureInPictureDiagnosticsIfNeeded(diagnostics, reason: "prepare-ready")
        Logger.shared.log(
            "[MPVTVRenderer] PiP prepare ready renderer={\(pictureInPictureDebugSnapshot())}",
            type: "MPV"
        )
    }

    func beginPictureInPicture() {
        renderer.beginPictureInPicture()
        updateState(.pictureInPicture)
        Logger.shared.log(
            "[MPVTVRenderer] PiP activate renderer={\(pictureInPictureDebugSnapshot())}",
            type: "MPV"
        )
    }

    func endPictureInPicture(restoringInlinePlayback: Bool = true) {
        Task { @MainActor in
            _ = await self.endPictureInPictureAndWait(
                restoringInlinePlayback: restoringInlinePlayback
            )
        }
    }

    @discardableResult
    func endPictureInPictureAndWait(
        restoringInlinePlayback: Bool = true
    ) async -> Bool {
        let generation = lifecycleGeneration
        guard state != .stopping, state != .stopped else {
            Logger.shared.log(
                "[MPVTVRenderer] PiP restore blocked state=\(stateDescription(state)) renderer={\(pictureInPictureDebugSnapshot())}",
                type: "MPV"
            )
            return false
        }

        Logger.shared.log(
            "[MPVTVRenderer] PiP restore begin inline=\(restoringInlinePlayback) lifecycleGeneration=\(generation) renderer={\(pictureInPictureDebugSnapshot())}",
            type: "MPV"
        )

        let restored = await renderer.endPictureInPictureAndWait(
            restoringInlinePlayback: restoringInlinePlayback
        )
        let lifecycleIsCurrent = generation == lifecycleGeneration
        let stateAllowsRestore = state != .stopping && state != .stopped
        let accepted = restored && lifecycleIsCurrent && stateAllowsRestore
        if accepted {
            updateState(isPaused ? .paused : .playing)
        }
        Logger.shared.log(
            "[MPVTVRenderer] PiP restore end nativeRestored=\(restored) accepted=\(accepted) lifecycleCurrent=\(lifecycleIsCurrent) stateAllowsRestore=\(stateAllowsRestore) renderer={\(pictureInPictureDebugSnapshot())}",
            type: "MPV"
        )
        return accepted
    }

    func updatePictureInPictureRenderSize(_ size: CGSize) {
        renderer.updatePictureInPictureRenderSize(size)
    }

    func waitForPictureInPictureTimelineUpdate() async {
        await renderer.waitForPictureInPictureTimelineUpdate()
    }

    func diagnosticsSnapshot() -> MPVGPUPlayerRendererDiagnostics {
        renderer.diagnosticsSnapshot()
    }

    func pictureInPictureDebugSnapshot() -> String {
        pictureInPictureDiagnosticsSummary(renderer.diagnosticsSnapshot())
    }

    private func configureCallbacks(generation: UInt64) {
        renderer.onStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self, self.lifecycleGeneration == generation else { return }
                self.handle(state)
            }
        }
        renderer.onError = { [weak self] message in
            Task { @MainActor in
                guard let self, self.lifecycleGeneration == generation else { return }
                self.handleRendererError(message)
            }
        }
        renderer.onDiagnostics = { [weak self] diagnostics in
            Task { @MainActor in
                guard let self, self.lifecycleGeneration == generation else { return }
                self.handleDiagnostics(diagnostics)
            }
        }
        renderer.onPictureInPictureStopRequested = { [weak self] reason in
            Task { @MainActor in
                guard let self,
                      self.lifecycleGeneration == generation,
                      self.state != .stopping,
                      self.state != .stopped else { return }
                Logger.shared.log(
                    "[MPVTVRenderer] MPVKit requested PiP stop reason=\(reason) renderer={\(self.pictureInPictureDebugSnapshot())}",
                    type: "MPV"
                )
                self.onPictureInPictureStopRequested?(reason)
            }
        }
        renderer.onVideoReconfigure = { [weak self] in
            Task { @MainActor in
                guard let self, self.lifecycleGeneration == generation else { return }
                self.onVideoFormatChange?(self.renderer.diagnosticsSnapshot())
            }
        }
    }

    private func handle(_ rendererState: MPVGPUPlayerRendererState) {
        switch rendererState {
        case .idle:
            updateState(.idle)
        case .starting, .loading:
            updateState(.loading)
        case .ready:
            applyPendingResumeIfNeeded()
            updateState(.ready)
        case .playing:
            isPaused = false
            applyPendingResumeIfNeeded()
            updateState(.playing)
        case .paused:
            isPaused = true
            applyPendingResumeIfNeeded()
            updateState(.paused)
        case .pictureInPicture:
            updateState(.pictureInPicture)
        case .stopping:
            updateState(.stopping)
        case .stopped:
            updateState(.stopped)
        case .failed(let message):
            fail(message, beforeFirstFrame: !hasRenderedFirstFrame)
        }
    }

    private func handleDiagnostics(_ diagnostics: MPVGPUPlayerRendererDiagnostics) {
        logPictureInPictureDiagnosticsIfNeeded(diagnostics, reason: "callback")
        if !hasRenderedFirstFrame,
           diagnostics.videoWidth > 0,
           diagnostics.videoHeight > 0,
           diagnostics.state == .playing || diagnostics.state == .paused {
            hasRenderedFirstFrame = true
            startupTimeout?.cancel()
            startupTimeout = nil
            onFirstFrame?()
        }
        emitPosition()
        applyVideoConfiguration(diagnostics)
        onVideoFormatChange?(diagnostics)

        let audio = renderer.audioTracks().map { "\($0.id):\($0.selected)" }.joined(separator: ",")
        let subtitles = renderer.subtitleTracks().map { "\($0.id):\($0.selected)" }.joined(separator: ",")
        let signature = "\(audio)|\(subtitles)"
        if signature != lastTrackSignature {
            lastTrackSignature = signature
            onTracksChange?()
        }
    }

    private func handleRendererError(_ message: String) {
        let lower = message.lowercased()
        let fatalMarkers = [
            "playback ended with error", "mpv_initialize failed", "loadfile failed",
            "failed to open", "unrecognized file format", "fatal"
        ]
        let isFatal = fatalMarkers.contains(where: lower.contains)
        Logger.shared.log(
            "[MPVTVRenderer] renderer error fatal=\(isFatal) message=\(message) renderer={\(pictureInPictureDebugSnapshot())}",
            type: "MPV"
        )
        guard isFatal else { return }
        fail(message, beforeFirstFrame: !hasRenderedFirstFrame)
    }

    private func fail(_ message: String, beforeFirstFrame: Bool) {
        guard !didReportFatalFailure else { return }
        didReportFatalFailure = true
        startupTimeout?.cancel()
        startupTimeout = nil
        Logger.shared.log(
            "[MPVTVRenderer] fatal failure beforeFirstFrame=\(beforeFirstFrame) message=\(message) renderer={\(pictureInPictureDebugSnapshot())}",
            type: "MPV"
        )
        updateState(.failed(message))
        if beforeFirstFrame {
            onStartupFailure?(message)
        } else {
            onPlaybackFailure?(message)
        }
    }

    private func applyPendingResumeIfNeeded() {
        guard let pendingResumePosition, duration > 0 else { return }
        self.pendingResumePosition = nil
        renderer.seek(to: min(pendingResumePosition, max(0, duration - 1)))
    }

    private func applySubtitleDefaults() {
        let fontSize = ProfileSettingsStore.active.double(forKey: "subtitles_fontSize")
        let strokeWidth = ProfileSettingsStore.active.object(forKey: "subtitles_strokeWidth") as? Double ?? 1
        let foregroundColor = archivedColor(forKey: "subtitles_foregroundColor", fallback: .white)
        let strokeColor = archivedColor(forKey: "subtitles_strokeColor", fallback: .black)
        renderer.applySubtitleStyle(MPVMetalSampleBufferSubtitleStyle(
            foregroundColor: foregroundColor.cgColor,
            strokeColor: strokeColor.cgColor,
            strokeWidth: CGFloat(max(0, min(strokeWidth, 4))),
            fontSize: CGFloat(fontSize > 0 ? fontSize : 38),
            isVisible: ProfileSettingsStore.active.bool(forKey: "enableSubtitlesByDefault")
        ))
        let offset = ProfileSettingsStore.active.object(forKey: "playerSubtitleOverlayBottomConstant") == nil
            ? -6
            : ProfileSettingsStore.active.double(forKey: "playerSubtitleOverlayBottomConstant")
        let position = max(0, min(100, 100 + (offset + 6)))
        let captionBackground = ProfileSettingsStore.active.bool(forKey: "subtitles_closedCaptionBackground")
        _ = renderer.command(["set", "sub-pos", String(format: "%.0f", position)])
        _ = renderer.command(["set", "sub-border-style", captionBackground ? "background-box" : "outline-and-shadow"])
        _ = renderer.command(["set", "sub-back-color", captionBackground ? "0.0/0.0/0.0/0.75" : "0.0/0.0/0.0/0.0"])
    }

    private func archivedColor(forKey key: String, fallback: UIColor) -> UIColor {
        guard let data = ProfileSettingsStore.active.data(forKey: key),
              let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data) else {
            return fallback
        }
        return color
    }

    private var contentIsAnimation: Bool {
        guard let request else { return false }
        return request.isAnime
            || request.isAnimation
            || request.episodePlaybackContext?.hasAnimeMediaId == true
    }

    private func outputScale(_ diagnostics: MPVGPUPlayerRendererDiagnostics) -> Double? {
        let size = lastKnownOutputDrawableSize
        guard size.width > 1, size.height > 1 else { return nil }
        guard diagnostics.videoWidth > 0, diagnostics.videoHeight > 0 else { return nil }
        return min(
            Double(size.width) / Double(diagnostics.videoWidth),
            Double(size.height) / Double(diagnostics.videoHeight)
        )
    }

    private func resolvedNeuralUpscaler(_ diagnostics: MPVGPUPlayerRendererDiagnostics) -> MPVNeuralUpscaler {
        MPVScalerPolicy.tvNeuralUpscaler(
            selected: Settings.shared.mpvNeuralUpscalerTV,
            isAnimation: contentIsAnimation,
            supportsConvolutional: MPVUserShaderLibrary.supportsConvolutionalUpscalers,
            sourceHeight: Int(diagnostics.videoHeight),
            outputScale: outputScale(diagnostics)
        )
    }

    private func applyVideoConfiguration(_ diagnostics: MPVGPUPlayerRendererDiagnostics) {

        let transfer = diagnostics.videoTransferFunction.lowercased()
        let primaries = diagnostics.videoColorPrimaries.lowercased()
        let sourceIsHDR = diagnostics.videoSignalPeak > 1
            || transfer.contains("pq") || transfer.contains("2084") || transfer.contains("hlg")
            || primaries.contains("2020")

        let requestsHDR = sourceIsHDR
        let neural = resolvedNeuralUpscaler(diagnostics)
        let neuralPath = MPVUserShaderLibrary.shaderPath(for: neural)
        let memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        let s = MPVScalerPolicy.tvScalers(
            neuralActive: neuralPath != nil,
            qualityChroma: MPVScalerPolicy.tvSupportsQualityChroma(memoryGB: memoryGB)
        )
        let qualityScaling = s.qualityScaling ? "yes" : "no"
        let signature = "\(neural.rawValue)|\(s.scale)|\(s.cscale)|\(s.deband)|\(qualityScaling)|\(neuralPath ?? "none")|\(requestsHDR)"
        guard signature != lastVideoConfigurationSignature else { return }
        lastVideoConfigurationSignature = signature

        _ = renderer.command(["set", "scale", s.scale])
        _ = renderer.command(["set", "cscale", s.cscale])
        _ = renderer.command(["set", "dscale", s.dscale])
        _ = renderer.command(["set", "deband", s.deband])
        _ = renderer.command(["set", "sigmoid-upscaling", qualityScaling])
        _ = renderer.command(["set", "correct-downscaling", qualityScaling])
        _ = renderer.command(["set", "linear-downscaling", qualityScaling])
        if let neuralPath {
            _ = renderer.command(["change-list", "glsl-shaders", "set", neuralPath])
        } else {
            _ = renderer.command(["change-list", "glsl-shaders", "clr", ""])
        }
        _ = renderer.command(["set", "target-colorspace-hint", requestsHDR ? "yes" : "no"])
        Logger.shared.log(
            "[MPVTVRenderer] video config neural=\(neural.rawValue) selected=\(Settings.shared.mpvNeuralUpscalerTV.rawValue) animation=\(contentIsAnimation) shader=\(neuralPath.map { ($0 as NSString).lastPathComponent } ?? "none") scale=\(s.scale) cscale=\(s.cscale) deband=\(s.deband) srcH=\(Int(diagnostics.videoHeight)) hdr=\(requestsHDR)",
            type: "MPV"
        )
    }

    private func resolvedDefaultSpeed() -> Double {
        PlaybackSpeedPolicy.normalized(
            ProfileSettingsStore.active.double(forKey: "defaultPlaybackSpeed")
        )
    }

    private func resolvedResumePosition(for request: PlaybackRequest) -> Double? {
        if let explicit = request.resumePosition { return explicit }
        guard let mediaInfo = request.mediaInfo else { return nil }
        let progress: Double
        let position: Double
        switch mediaInfo {
        case .movie(let id, let title, _, _):
            progress = ProgressManager.shared.getMovieProgress(movieId: id, title: title)
            position = ProgressManager.shared.getMovieCurrentTime(movieId: id, title: title)
        case .episode(let showID, let season, let episode, _, _, _):
            progress = ProgressManager.shared.getEpisodeProgress(
                showId: showID,
                seasonNumber: season,
                episodeNumber: episode
            )
            position = ProgressManager.shared.getEpisodeCurrentTime(
                showId: showID,
                seasonNumber: season,
                episodeNumber: episode
            )
        }
        return progress < 0.95 && position > 0 ? position : nil
    }

    private func startPositionUpdates() {
        positionTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.emitPosition() }
        }
        positionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func emitPosition() {
        onPositionChange?(currentTime, duration)
    }

    private func scheduleStartupTimeout() {
        startupTimeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, !self.hasRenderedFirstFrame else { return }
                self.fail("MPV did not produce a video frame before the startup timeout.", beforeFirstFrame: true)
            }
        }
        startupTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: item)
    }

    private func updateState(_ newState: State) {
        guard state != newState else { return }
        state = newState
        Logger.shared.log(
            "[MPVTVRenderer] state=\(stateDescription(newState)) renderer={\(pictureInPictureDebugSnapshot())}",
            type: "MPV"
        )
        onStateChange?(newState)
    }

    private func logPictureInPictureDiagnosticsIfNeeded(
        _ diagnostics: MPVGPUPlayerRendererDiagnostics,
        reason: String
    ) {
        let selectedBackend = diagnostics.selectedPictureInPictureBackend?.rawValue ?? "unselected"
        let fallbackReason = sanitizedPictureInPictureDiagnosticText(
            diagnostics.pictureInPictureFallbackReason
        )
        let transitionSignature = [
            pictureInPictureStateDescription(diagnostics.pictureInPictureState),
            diagnostics.pictureInPictureBackendPreference.rawValue,
            selectedBackend,
            fallbackReason,
            String(diagnostics.activeMPVInstanceCount)
        ].joined(separator: "|")
        let pressureTotal = diagnostics.backpressureDropCount
            + diagnostics.poolExhaustionDropCount
            + diagnostics.staleGenerationDropCount
        let transitionChanged = transitionSignature != lastLoggedPictureInPictureDiagnosticsSignature
        let pressureDelta = pressureTotal - lastLoggedPictureInPicturePressureTotal
        let pressureMilestone = pressureTotal != lastLoggedPictureInPicturePressureTotal
            && (pressureTotal <= 3 || pressureDelta >= 60 || pressureDelta < 0)
        let audioRecoveryChanged = diagnostics.audioRecoveryCount != lastLoggedAudioRecoveryCount
        guard transitionChanged || pressureMilestone || audioRecoveryChanged else { return }

        lastLoggedPictureInPictureDiagnosticsSignature = transitionSignature
        lastLoggedPictureInPicturePressureTotal = pressureTotal
        lastLoggedAudioRecoveryCount = diagnostics.audioRecoveryCount
        Logger.shared.log(
            "[MPVTVRenderer] PiP diagnostics reason=\(reason) \(pictureInPictureDiagnosticsSummary(diagnostics))",
            type: "MPV"
        )
    }

    private func pictureInPictureDiagnosticsSummary(
        _ diagnostics: MPVGPUPlayerRendererDiagnostics
    ) -> String {
        let backend = diagnostics.selectedPictureInPictureBackend?.rawValue ?? "unselected"
        let fallback = sanitizedPictureInPictureDiagnosticText(
            diagnostics.pictureInPictureFallbackReason
        )
        let frameCount = diagnostics.pictureInPictureEnqueuedFrameCount
        return "state=\(pictureInPictureStateDescription(diagnostics.pictureInPictureState)) preference=\(diagnostics.pictureInPictureBackendPreference.rawValue) selected=\(backend) fallback=\(fallback) instances=\(diagnostics.activeMPVInstanceCount) generation=\(diagnostics.pictureInPicturePreparationGeneration) prepareMs=\(String(format: "%.1f", diagnostics.pictureInPicturePreparationLatency * 1_000)) frames=\(frameCount) schedulerCoalesced=\(diagnostics.schedulerCoalescedRequestCount) backpressureDrops=\(diagnostics.backpressureDropCount) poolDrops=\(diagnostics.poolExhaustionDropCount) staleDrops=\(diagnostics.staleGenerationDropCount) inFlight=\(diagnostics.inFlightGPUFrameCount) gpuMs=\(String(format: "%.2f", diagnostics.lastGPULatencyMilliseconds)) epoch=\(diagnostics.timelineEpoch) rate=\(String(format: "%.2f", diagnostics.timelineRate)) pipResize=\(diagnostics.pictureInPictureResizeRequestCount)/\(diagnostics.pictureInPictureResizeApplicationCount)/\(diagnostics.pictureInPictureResizeCoalescedCount) inlineResize=\(diagnostics.inlineResizeRequestCount)/\(diagnostics.inlineResizeApplicationCount)/\(diagnostics.inlineResizeCoalescedCount) audioRecoveries=\(diagnostics.audioRecoveryCount)"
    }

    private func pictureInPictureStateDescription(_ state: MPVPictureInPictureState) -> String {
        switch state {
        case .idle:
            return "idle"
        case .preparing(let generation):
            return "preparing(\(generation))"
        case .ready(let generation):
            return "ready(\(generation))"
        case .active(let generation):
            return "active(\(generation))"
        case .restoring(let generation):
            return "restoring(\(generation))"
        case .failed(let generation, let reason):
            return "failed(\(generation),\(sanitizedPictureInPictureDiagnosticText(reason)))"
        }
    }

    private func sanitizedPictureInPictureDiagnosticText(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "none" }
        return text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private func stateDescription(_ state: State) -> String {
        switch state {
        case .idle: return "idle"
        case .loading: return "loading"
        case .ready: return "ready"
        case .playing: return "playing"
        case .paused: return "paused"
        case .pictureInPicture: return "picture-in-picture"
        case .stopping: return "stopping"
        case .stopped: return "stopped"
        case .failed(let message):
            return "failed(\(sanitizedPictureInPictureDiagnosticText(message)))"
        }
    }
}

@MainActor
final class MPVTVMetalHostView: UIView {
    var onLayoutChange: ((_ bounds: CGRect, _ nativeScale: CGFloat) -> Void)?
    private weak var hostedLayer: CAMetalLayer?

    func host(_ layer: CAMetalLayer) {
        guard hostedLayer !== layer else { return }
        hostedLayer?.removeFromSuperlayer()
        hostedLayer = layer
        self.layer.addSublayer(layer)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostedLayer?.frame = bounds
        CATransaction.commit()
        onLayoutChange?(bounds, scale > 0 ? scale : 1)
    }
}

@MainActor
private final class MPVTVAudioSession {
    private var routeToken: NSObjectProtocol?
    private var isActive = false

    func activate() {
        guard !isActive else { reapplyPreferredChannels(); return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
            isActive = true
            reapplyPreferredChannels()
            routeToken = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.reapplyPreferredChannels() }
            }
        } catch {
            Logger.shared.log("[MPVTVRenderer] audio session activation failed: \(error)", type: "MPV")
        }
    }

    func deactivate() {
        if let routeToken {
            NotificationCenter.default.removeObserver(routeToken)
            self.routeToken = nil
        }
        guard isActive else { return }
        isActive = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Logger.shared.log("[MPVTVRenderer] audio session deactivation failed: \(error)", type: "MPV")
        }
    }

    private func reapplyPreferredChannels() {
        let session = AVAudioSession.sharedInstance()
        let surroundEnabled = ProfileSettingsStore.active.object(forKey: "mpvSurroundSoundEnabled") as? Bool ?? true
        let maximum = max(1, session.maximumOutputNumberOfChannels)
        let desired = surroundEnabled && session.supportsMultichannelContent ? maximum : min(2, maximum)
        guard desired != session.preferredOutputNumberOfChannels else { return }
        do {
            try session.setPreferredOutputNumberOfChannels(desired)
        } catch {
            Logger.shared.log("[MPVTVRenderer] preferred output channels \(desired) failed: \(error)", type: "MPV")
        }
    }
}
#endif
