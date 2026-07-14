#if os(tvOS)
import AVFoundation
import AVKit
import CoreMedia
import MediaPlayer
import QuartzCore
import UIKit
import MPVKitSampleBufferGPL

/// Small tvOS-only adapter over MPVKit's gpu-next/MoltenVK renderer. The existing iOS
/// `MPVNativeRenderer` stays isolated so remote-control behavior does not become another branch in
/// its touch-oriented controller.
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
    private var lifecycleGeneration: UInt64 = 0

    var currentTime: Double { renderer.currentTime }
    var duration: Double { renderer.duration }
    var pictureInPictureDisplayLayer: AVSampleBufferDisplayLayer {
        renderer.pictureInPictureDisplayLayer
    }

    init() {
        let prefersSurround = UserDefaults.standard.object(forKey: "mpvSurroundSoundEnabled") as? Bool ?? true
        let defaultSubtitleLanguage = UserDefaults.standard.string(forKey: "defaultSubtitleLanguage") ?? "eng"
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
            additionalMPVOptions: [
                "audio-channels": prefersSurround ? "auto" : "stereo",
                "slang": defaultSubtitleLanguage,
                "cache": "yes",
                "cache-pause-wait": "5",
                "demuxer-thread": "yes",
                "demuxer-max-bytes": "80M",
                "demuxer-readahead-secs": "10",
                "vd-lavc-software-fallback": "yes",
                "vulkan-async-compute": "no",
                "vulkan-async-transfer": "no",
                "vulkan-queue-count": "1",
                "vulkan-swap-mode": "fifo"
            ]
        )
        renderer = MPVGPUPlayerRenderer(
            inlineLayer: MPVGPUPlayerMetalLayer(),
            pictureInPictureDisplayLayer: AVSampleBufferDisplayLayer(),
            options: options
        )
        view.host(renderer.inlineLayer)
        view.onLayoutChange = { [weak self] bounds, scale in
            self?.renderer.updateInlineLayerLayout(bounds: bounds, contentsScale: scale)
        }
    }

    func start(_ request: PlaybackRequest) throws {
        if state == .stopping {
            // MPVKit teardown is deliberately asynchronous. Never make a caller believe a new
            // request started while the previous handle and GPU work are still draining.
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
        } catch {
            fail(error.localizedDescription, beforeFirstFrame: true)
            throw error
        }
    }

    func stop() {
        guard state != .stopped, state != .stopping else { return }
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

            // MPV can load ordinary remote and local subtitles directly, including large bitmap
            // formats such as PGS. Only credential-bearing tracks need a bounded local bridge,
            // because MPV's subtitle API does not accept per-track request headers.
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
            && (UserDefaults.standard.object(forKey: "mpvPictureInPictureEnabled") as? Bool ?? true)
    }

    func preparePictureInPicture() async throws {
        guard canStartPictureInPicture else {
            throw MPVGPUPlayerRendererError.pictureInPictureUnavailable("tvOS PiP is unavailable")
        }
        try await renderer.preparePictureInPicture()
    }

    func beginPictureInPicture() {
        renderer.beginPictureInPicture()
        updateState(.pictureInPicture)
    }

    func endPictureInPicture(restoringInlinePlayback: Bool = true) {
        Task { @MainActor in
            _ = await self.endPictureInPictureAndWait(
                restoringInlinePlayback: restoringInlinePlayback
            )
        }
    }

    /// Completes only after MPVKit has restored a current-generation inline frame. A stop or a
    /// replacement lifecycle invalidates the result even if the native restore finishes later.
    @discardableResult
    func endPictureInPictureAndWait(
        restoringInlinePlayback: Bool = true
    ) async -> Bool {
        let generation = lifecycleGeneration
        guard state != .stopping, state != .stopped else { return false }

        let restored = await renderer.endPictureInPictureAndWait(
            restoringInlinePlayback: restoringInlinePlayback
        )
        guard restored,
              generation == lifecycleGeneration,
              state != .stopping,
              state != .stopped else {
            return false
        }
        updateState(isPaused ? .paused : .playing)
        return true
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
        guard fatalMarkers.contains(where: lower.contains) else { return }
        fail(message, beforeFirstFrame: !hasRenderedFirstFrame)
    }

    private func fail(_ message: String, beforeFirstFrame: Bool) {
        guard !didReportFatalFailure else { return }
        didReportFatalFailure = true
        startupTimeout?.cancel()
        startupTimeout = nil
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
        let fontSize = UserDefaults.standard.double(forKey: "subtitles_fontSize")
        let strokeWidth = UserDefaults.standard.object(forKey: "subtitles_strokeWidth") as? Double ?? 1
        let foregroundColor = archivedColor(forKey: "subtitles_foregroundColor", fallback: .white)
        let strokeColor = archivedColor(forKey: "subtitles_strokeColor", fallback: .black)
        renderer.applySubtitleStyle(MPVMetalSampleBufferSubtitleStyle(
            foregroundColor: foregroundColor.cgColor,
            strokeColor: strokeColor.cgColor,
            strokeWidth: CGFloat(max(0, min(strokeWidth, 4))),
            fontSize: CGFloat(fontSize > 0 ? fontSize : 38),
            isVisible: UserDefaults.standard.bool(forKey: "enableSubtitlesByDefault")
        ))
        let offset = UserDefaults.standard.object(forKey: "playerSubtitleOverlayBottomConstant") == nil
            ? -6
            : UserDefaults.standard.double(forKey: "playerSubtitleOverlayBottomConstant")
        let position = max(0, min(100, 100 + (offset + 6)))
        let captionBackground = UserDefaults.standard.bool(forKey: "subtitles_closedCaptionBackground")
        _ = renderer.command(["set", "sub-pos", String(format: "%.0f", position)])
        _ = renderer.command(["set", "sub-border-style", captionBackground ? "background-box" : "outline-and-shadow"])
        _ = renderer.command(["set", "sub-back-color", captionBackground ? "0.0/0.0/0.0/0.75" : "0.0/0.0/0.0/0.0"])
    }

    private func archivedColor(forKey key: String, fallback: UIColor) -> UIColor {
        guard let data = UserDefaults.standard.data(forKey: key),
              let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data) else {
            return fallback
        }
        return color
    }

    private func applyVideoConfiguration(_ diagnostics: MPVGPUPlayerRendererDiagnostics) {
        // Upscaling is deliberately disabled on Apple TV until sustained 4K hardware validation.
        // A shared iOS preference must not silently activate an unvalidated TV renderer path.
        let transfer = diagnostics.videoTransferFunction.lowercased()
        let primaries = diagnostics.videoColorPrimaries.lowercased()
        let sourceIsHDR = diagnostics.videoSignalPeak > 1
            || transfer.contains("pq") || transfer.contains("2084") || transfer.contains("hlg")
            || primaries.contains("2020")
        // Apple TV always follows source metadata and the system Match Content
        // policy. iOS-only HDR overrides must never silently affect TV output.
        let requestsHDR = sourceIsHDR
        let signature = "off|false|\(requestsHDR)"
        guard signature != lastVideoConfigurationSignature else { return }
        lastVideoConfigurationSignature = signature

        _ = renderer.command(["set", "scale", "bilinear"])
        _ = renderer.command(["set", "cscale", "bilinear"])
        _ = renderer.command(["set", "dscale", "mitchell"])
        _ = renderer.command(["set", "deband", "no"])
        _ = renderer.command(["set", "target-colorspace-hint", requestsHDR ? "yes" : "no"])
    }

    private func resolvedDefaultSpeed() -> Double {
        PlaybackSpeedPolicy.normalized(
            UserDefaults.standard.double(forKey: "defaultPlaybackSpeed")
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
        onStateChange?(newState)
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
        let surroundEnabled = UserDefaults.standard.object(forKey: "mpvSurroundSoundEnabled") as? Bool ?? true
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
