import AppKit
import AVKit
import Combine
import MPVKitSampleBufferGPL
import SwiftUI

private enum MacAudioComfortMode: String {
    case original
    case comfort
    case dialogue
    case night

    static func resolve(_ rawValue: String?) -> MacAudioComfortMode {
        MacAudioComfortMode(rawValue: rawValue ?? "") ?? .original
    }

    /// Mirrors Eclipse's canonical iOS MPV filters. MPVKit's macOS build uses
    /// the same libavfilter-backed `af` property, so these do real processing
    /// rather than changing the system output volume.
    var filterChain: String {
        switch self {
        case .original:
            return ""
        case .comfort:
            return "lavfi=[acompressor=ratio=3:threshold=0.1:attack=20:release=250:makeup=2,dynaudnorm=f=200:g=11:p=0.9:m=10:r=0.5,alimiter=limit=0.9]"
        case .dialogue:
            return "lavfi=[highpass=f=90,acompressor=ratio=4:threshold=0.063:attack=10:release=200:makeup=2,equalizer=f=2500:width_type=q:width=1.4:gain=3.5,dynaudnorm=f=200:g=11:p=0.9:m=10,alimiter=limit=0.9]"
        case .night:
            return "lavfi=[acompressor=ratio=4:threshold=0.05:attack=15:release=250:makeup=2.5,equalizer=f=3000:width_type=q:width=1.5:gain=2,equalizer=f=110:width_type=q:width=1.0:gain=-4,dynaudnorm=f=150:g=9:p=0.9:m=12,alimiter=limit=0.85]"
        }
    }
}

@MainActor
private struct MacMPVPlaybackPreferences {
    private enum ResolvedQuality {
        case sharp
        case balanced
        case lowHeat

        var inlineProfile: String {
            switch self {
            case .sharp: "high-quality"
            case .balanced, .lowHeat: "fast"
            }
        }

        /// Zero asks MPVKit to use its macOS platform maximum (currently a 5K drawable).
        var maximumInlineDrawablePixelCount: Int {
            switch self {
            case .sharp: 0
            case .balanced: 2_560 * 1_440
            case .lowHeat: 1_600 * 900
            }
        }

        var maximumPiPFrameSize: CGSize {
            switch self {
            case .sharp: CGSize(width: 1_920, height: 1_080)
            case .balanced: CGSize(width: 1_280, height: 720)
            case .lowHeat: CGSize(width: 960, height: 540)
            }
        }

        var preferredPiPFramesPerSecond: Int {
            switch self {
            case .sharp, .balanced: 30
            case .lowHeat: 24
            }
        }

        var forcesCheapScaling: Bool { self == .lowHeat }
    }

    struct VideoConfiguration {
        let scale: String
        let chromaScale: String
        let downscale: String
        let deband: String
        let maximumInlineDrawablePixelCount: Int

        var signature: String {
            "\(scale)|\(chromaScale)|\(downscale)|\(deband)|\(maximumInlineDrawablePixelCount)"
        }
    }

    let defaultPlaybackSpeed: Double
    let subtitlesEnabled: Bool
    let subtitleLanguage: String
    let audioLanguage: String
    let subtitleFontSize: Double
    let subtitleStrokeWidth: Double
    let subtitleVerticalOffset: Double
    let subtitleBackgroundEnabled: Bool
    let ignoresEmbeddedSubtitleStyles: Bool
    let audioFilterChain: String
    let streamCacheEnabled: Bool
    let streamCacheLimitMB: Int
    let hdrMode: String
    let upscalingMode: String
    private let quality: ResolvedQuality

    static func current() -> MacMPVPlaybackPreferences {
        let defaults = UserDefaults.standard
        let savedSpeed = defaults.double(forKey: "defaultPlaybackSpeed")
        let speed = min(100, max(0.01, savedSpeed > 0 ? savedSpeed : 1))
        let qualityRaw = defaults.string(forKey: "mpvMetalQualityProfile") ?? "auto"
        let quality: ResolvedQuality
        switch qualityRaw {
        case "sharp":
            quality = .sharp
        case "balanced":
            quality = .balanced
        case "lowHeat":
            quality = .lowHeat
        default:
            // Auto follows the Mac's thermal state when a player session starts. This keeps the
            // setting meaningful without changing render surfaces in the middle of a frame.
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: quality = .sharp
            case .fair: quality = .balanced
            case .serious, .critical: quality = .lowHeat
            @unknown default: quality = .balanced
            }
        }

        let savedFontSize = defaults.double(forKey: "subtitles_fontSize")
        let savedStrokeWidth = defaults.object(forKey: "subtitles_strokeWidth") as? Double ?? 1
        let savedVerticalOffset = defaults.object(forKey: "playerSubtitleOverlayBottomConstant") as? Double ?? -6
        let streamCacheEnabled = (defaults.object(forKey: "macMPVStreamCacheEnabled") as? Bool) ?? true
        let savedStreamCacheLimit = defaults.integer(forKey: "macMPVStreamCacheLimitMB")
        let streamCacheLimitMB = min(512, max(32, savedStreamCacheLimit > 0 ? savedStreamCacheLimit : 128))

        return MacMPVPlaybackPreferences(
            defaultPlaybackSpeed: speed,
            subtitlesEnabled: defaults.bool(forKey: "enableSubtitlesByDefault"),
            subtitleLanguage: normalizedLanguage(defaults.string(forKey: "defaultSubtitleLanguage"), fallback: "eng"),
            audioLanguage: normalizedLanguage(defaults.string(forKey: "preferredAutoAudioLanguage"), fallback: "eng"),
            subtitleFontSize: min(72, max(12, savedFontSize > 0 ? savedFontSize : 30)),
            subtitleStrokeWidth: min(4, max(0, savedStrokeWidth)),
            subtitleVerticalOffset: min(24, max(-24, savedVerticalOffset)),
            subtitleBackgroundEnabled: defaults.bool(forKey: "subtitles_closedCaptionBackground"),
            ignoresEmbeddedSubtitleStyles: defaults.bool(forKey: "experimentalMPVIgnoreSpecialSubtitleStyles"),
            audioFilterChain: MacAudioComfortMode.resolve(defaults.string(forKey: "audioComfortMode")).filterChain,
            streamCacheEnabled: streamCacheEnabled,
            streamCacheLimitMB: streamCacheLimitMB,
            hdrMode: normalizedChoice(defaults.string(forKey: "mpvHDRMode"), allowed: ["auto", "hdr", "sdr"], fallback: "auto"),
            upscalingMode: normalizedChoice(
                defaults.string(forKey: "mpvUpscalingMode"),
                allowed: ["off", "upscaleTo1080", "upscaleTo4K", "oneLevelAlways", "auto"],
                fallback: "off"
            ),
            quality: quality
        )
    }

    func rendererOptions(for screen: NSScreen?) -> MPVGPUPlayerRendererOptions {
        let initialVideoConfiguration = videoConfiguration(videoWidth: 0, videoHeight: 0)
        return MPVGPUPlayerRendererOptions(
            maximumPiPFrameSize: quality.maximumPiPFrameSize,
            preferredPiPFramesPerSecond: quality.preferredPiPFramesPerSecond,
            inlineProfile: quality.inlineProfile,
            hardwareDecoding: "videotoolbox",
            enablesTargetColorspaceHint: targetColorspaceHintEnabled(for: screen),
            pausesInlineRendererDuringPictureInPicture: true,
            pictureInPictureBackendPreference: .automatic,
            maximumInFlightPictureInPictureFrames: 3,
            pictureInPicturePreparationTimeout: 1,
            maximumInlineDrawablePixelCount: quality.maximumInlineDrawablePixelCount,
            additionalMPVOptions: [
                "keep-open": "yes",
                "save-position-on-quit": "no",
                "osc": "no",
                "input-default-bindings": "no",
                "sub-auto": "fuzzy",
                "speed": mpvNumber(defaultPlaybackSpeed),
                "sid": subtitlesEnabled ? "auto" : "no",
                "slang": subtitleLanguage,
                "alang": audioLanguage,
                "sub-font-size": mpvNumber(subtitleFontSize),
                "sub-border-size": mpvNumber(min(5, subtitleStrokeWidth * 1.5)),
                "sub-pos": mpvNumber(subtitlePosition),
                "sub-ass-override": ignoresEmbeddedSubtitleStyles ? "force" : "no",
                "sub-ass-use-video-data": "all",
                "sub-border-style": subtitleBackgroundEnabled ? "background-box" : "outline-and-shadow",
                "sub-back-color": subtitleBackgroundEnabled ? "0.0/0.0/0.0/0.75" : "0.0/0.0/0.0/0.0",
                "af": audioFilterChain,
                "cache": streamCacheEnabled ? "yes" : "no",
                "cache-pause": streamCacheEnabled ? "yes" : "no",
                "cache-pause-wait": "3",
                "demuxer-max-bytes": "\(streamCacheLimitMB)M",
                "demuxer-max-back-bytes": "\(max(16, streamCacheLimitMB / 4))M",
                "scale": initialVideoConfiguration.scale,
                "cscale": initialVideoConfiguration.chromaScale,
                "dscale": initialVideoConfiguration.downscale,
                "deband": initialVideoConfiguration.deband
            ]
        )
    }

    func targetColorspaceHintEnabled(for screen: NSScreen?) -> Bool {
        switch hdrMode {
        case "hdr":
            return true
        case "sdr":
            return false
        default:
            let potentialEDRHeadroom = (screen ?? NSScreen.main)?
                .maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
            return potentialEDRHeadroom > 1
        }
    }

    func videoConfiguration(videoWidth: Int, videoHeight: Int) -> VideoConfiguration {
        let cheap = (scale: "bilinear", chroma: "bilinear", downscale: "mitchell", deband: "no")
        let qualityScaling = (scale: "ewa_lanczossharp", chroma: "lanczos", downscale: "mitchell", deband: "yes")
        let fourKScaling = (scale: "lanczos", chroma: "bilinear", downscale: "mitchell", deband: "yes")

        let scaler: (scale: String, chroma: String, downscale: String, deband: String)
        if quality.forcesCheapScaling {
            scaler = cheap
        } else {
            switch upscalingMode {
            case "upscaleTo1080":
                scaler = videoHeight > 0 && videoHeight < 1_080 ? qualityScaling : cheap
            case "upscaleTo4K":
                scaler = videoHeight > 0 && videoHeight < 2_160 ? fourKScaling : cheap
            case "oneLevelAlways", "auto":
                scaler = qualityScaling
            default:
                scaler = cheap
            }
        }

        let upscalingPixelLimit: Int
        switch upscalingMode {
        case "upscaleTo1080" where videoHeight > 0 && videoHeight < 1_080:
            upscalingPixelLimit = 1_920 * 1_080
        case "upscaleTo4K" where videoHeight > 0 && videoHeight < 2_160:
            upscalingPixelLimit = 3_840 * 2_160
        case "oneLevelAlways" where videoWidth > 0 && videoHeight > 0:
            let targetHeight: Int
            switch videoHeight {
            case ..<720: targetHeight = 720
            case ..<1_080: targetHeight = 1_080
            case ..<1_440: targetHeight = 1_440
            case ..<2_160: targetHeight = 2_160
            default: targetHeight = 2_880
            }
            let aspectRatio = Double(videoWidth) / Double(videoHeight)
            upscalingPixelLimit = max(2, Int((Double(targetHeight) * aspectRatio).rounded())) * targetHeight
        default:
            upscalingPixelLimit = 0
        }

        return VideoConfiguration(
            scale: scaler.scale,
            chromaScale: scaler.chroma,
            downscale: scaler.downscale,
            deband: scaler.deband,
            maximumInlineDrawablePixelCount: combinedPixelLimit(
                quality.maximumInlineDrawablePixelCount,
                upscalingPixelLimit
            )
        )
    }

    private static func normalizedLanguage(_ value: String?, fallback: String) -> String {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return normalized.isEmpty ? fallback : normalized
    }

    private static func normalizedChoice(_ value: String?, allowed: Set<String>, fallback: String) -> String {
        guard let value, allowed.contains(value) else { return fallback }
        return value
    }

    private func combinedPixelLimit(_ lhs: Int, _ rhs: Int) -> Int {
        if lhs <= 0 { return rhs }
        if rhs <= 0 { return lhs }
        return min(lhs, rhs)
    }

    private func mpvNumber(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    var subtitlePosition: Double {
        // mpv's `sub-pos` range is 0...150: 100 is its original position,
        // lower values move subtitles up, and higher values move them down.
        // Eclipse's saved -6 default therefore remains exactly at mpv's 100.
        min(150, max(0, 100 + (subtitleVerticalOffset + 6)))
    }
}

@MainActor
final class MacPlaybackController: ObservableObject {
    static let shared = MacPlaybackController()

    private struct PendingPlaybackRequest {
        let url: URL
        let headers: [String: String]
        let generation: UInt64
    }

    private struct PendingResume {
        let generation: UInt64
        let time: Double
    }

    @Published private(set) var title = "Nothing Playing"
    @Published private(set) var sourceURL: URL?
    @Published private(set) var isPaused = true
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var pendingWindowPresentation = false
    @Published private(set) var playbackSpeed = 1.0

    private(set) var renderer: MPVGPUPlayerRenderer?
    private weak var hostView: NSView?
    private var pendingRequest: PendingPlaybackRequest?
    private var progressTimer: Timer?
    private var playbackIdentity: MacPlaybackIdentity?
    private var pendingResume: PendingResume?
    private var playbackGeneration: UInt64 = 0
    private var activeLoadGeneration: UInt64?
    private var lastRecordedPosition: Double = -100
    private var activePreferences: MacMPVPlaybackPreferences?
    private var rendererOptions: MPVGPUPlayerRendererOptions?
    private var lastVideoConfigurationSignature = ""
    private var lastVolumeAdjustment: (delta: Double, time: TimeInterval)?

    var hasMedia: Bool { sourceURL != nil }
    var progress: Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }
    var seekInterval: Double { max(5, UserDefaults.standard.double(forKey: "macPlayerSeekSeconds") == 0 ? 10 : UserDefaults.standard.double(forKey: "macPlayerSeekSeconds")) }

    private init() {}

    func requestPlayback(url: URL, title: String, headers: [String: String] = [:], identity: MacPlaybackIdentity? = nil) {
        playbackGeneration &+= 1
        let generation = playbackGeneration
        pendingRequest = PendingPlaybackRequest(
            url: url,
            headers: headers,
            generation: generation
        )
        playbackIdentity = identity
        pendingResume = identity
            .flatMap { MacMediaStateStore.shared.value(for: $0)?.currentTime }
            .map { PendingResume(generation: generation, time: $0) }
        lastRecordedPosition = -100
        self.title = title
        sourceURL = url
        errorMessage = nil
        isLoading = true
        pendingWindowPresentation = true
        startPendingRequestIfPossible()
    }

    func attach(to view: NSView) {
        hostView = view
        if renderer == nil {
            let preferences = MacMPVPlaybackPreferences.current()
            let options = preferences.rendererOptions(for: view.window?.screen)
            activePreferences = preferences
            rendererOptions = options
            playbackSpeed = preferences.defaultPlaybackSpeed
            let renderer = MPVGPUPlayerRenderer(view: view, options: options)
            renderer.onStateChange = { [weak self] state in
                Task { @MainActor in self?.consume(state: state) }
            }
            renderer.onError = { [weak self] message in
                Task { @MainActor in
                    self?.errorMessage = message
                    self?.isLoading = false
                }
            }
            renderer.onPictureInPictureStopRequested = { [weak self] _ in
                Task { @MainActor in self?.renderer?.endPictureInPicture() }
            }
            do {
                try renderer.start()
                self.renderer = renderer
                installProgressTimer()
            } catch {
                errorMessage = "MPVKit could not start: \(error.localizedDescription)"
                isLoading = false
            }
        }
        updateLayout(for: view)
        startPendingRequestIfPossible()
    }

    func detach(from view: NSView) {
        guard hostView === view else { return }
        hostView = nil
    }

    func updateLayout(for view: NSView) {
        updateAutomaticHDRPreference(for: view)
        renderer?.updateInlineLayerLayout(
            bounds: view.bounds,
            contentsScale: view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        )
    }

    func togglePlayback() {
        guard let renderer, hasMedia else { return }
        if isPaused { renderer.play() } else { renderer.pause() }
    }

    func seek(by seconds: Double) {
        renderer?.seek(by: seconds)
    }

    func seek(to fraction: Double) {
        guard duration > 0 else { return }
        renderer?.seek(to: min(1, max(0, fraction)) * duration)
    }

    func seek(toTime seconds: Double) {
        guard duration > 0 else { return }
        renderer?.seek(to: min(duration, max(0, seconds)))
    }

    func toggleMute() {
        _ = renderer?.command(["cycle", "mute"])
    }

    func adjustVolume(by delta: Double) {
        // AppKit can deliver the same physical media-key event through more than one
        // responder during a window focus change. Keep one MPV mutation per event while
        // retaining normal held-key repeat cadence.
        let now = ProcessInfo.processInfo.systemUptime
        if let previous = lastVolumeAdjustment,
           previous.delta == delta,
           now - previous.time < 0.01 {
            return
        }
        lastVolumeAdjustment = (delta, now)
        _ = renderer?.command(["add", "volume", String(delta)])
    }

    func cycleSubtitles() { _ = renderer?.command(["cycle", "sub"]) }
    func cycleAudioTrack() { _ = renderer?.command(["cycle", "audio"]) }
    func cycleSpeed() {
        let choices = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
        let next = choices.first(where: { $0 > playbackSpeed + 0.01 }) ?? choices[0]
        playbackSpeed = next
        _ = renderer?.command(["set", "speed", String(next)])
    }

    func togglePictureInPicture() {
        guard UserDefaults.standard.object(forKey: "mpvPictureInPictureEnabled") as? Bool ?? true else {
            errorMessage = "Picture in Picture is disabled in Settings."
            return
        }
        guard let renderer, hasMedia else { return }
        Task {
            do {
                try await renderer.preparePictureInPicture()
                renderer.beginPictureInPicture()
            } catch {
                errorMessage = "Picture in Picture is unavailable: \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        recordProgress(force: true)
        playbackGeneration &+= 1
        pendingRequest = nil
        pendingResume = nil
        activeLoadGeneration = nil
        renderer?.stop()
        renderer = nil
        sourceURL = nil
        position = 0
        duration = 0
        isPaused = true
        isLoading = false
        progressTimer?.invalidate()
        progressTimer = nil
        playbackIdentity = nil
        activePreferences = nil
        rendererOptions = nil
        lastVideoConfigurationSignature = ""
    }

    private func startPendingRequestIfPossible() {
        guard let renderer, let request = pendingRequest else { return }
        pendingRequest = nil
        activeLoadGeneration = request.generation
        applyMediaDefaults(to: renderer)
        renderer.load(request.url, headers: request.headers, generation: request.generation)
    }

    private func consume(state: MPVGPUPlayerRendererState) {
        switch state {
        case .idle, .stopped:
            isPaused = true
            isLoading = false
        case .starting, .loading:
            isLoading = true
        case .ready:
            isPaused = true
            // `.ready` only means the MPV engine has started. A submitted file remains
            // loading until MPVKit reports its playing/paused state and a real duration.
            if !hasMedia { isLoading = false }
            applyVideoPreferencesIfNeeded(force: true)
        case .playing:
            isPaused = false
            isLoading = false
        case .paused:
            isPaused = true
            isLoading = false
        case .pictureInPicture:
            isPaused = false
            isLoading = false
        case .stopping:
            isLoading = false
        case .failed(let message):
            errorMessage = message
            isLoading = false
            isPaused = true
        }
    }

    private func installProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let renderer = self.renderer else { return }
                self.position = renderer.currentTime
                self.duration = renderer.duration
                self.applyPendingResumeIfReady(using: renderer)
                self.applyVideoPreferencesIfNeeded()
                if abs(self.position - self.lastRecordedPosition) >= 5 {
                    self.recordProgress(force: false)
                }
            }
        }
    }

    private func recordProgress(force: Bool) {
        guard let playbackIdentity, duration > 0, position >= 0 else { return }
        lastRecordedPosition = position
        MacMediaStateStore.shared.record(
            identity: playbackIdentity,
            currentTime: position,
            duration: duration,
            forceCloud: force
        )
    }

    private func applyPendingResumeIfReady(using renderer: MPVGPUPlayerRenderer) {
        guard let generation = activeLoadGeneration,
              let pendingResume,
              pendingResume.generation == generation else { return }

        let loadedDuration = renderer.duration
        guard loadedDuration.isFinite, loadedDuration > 0 else { return }

        // Main-actor serialization plus both generation checks ensure an older load can
        // neither seek nor consume the resume point belonging to a replacement request.
        guard activeLoadGeneration == generation,
              self.pendingResume?.generation == generation else { return }
        self.pendingResume = nil

        guard pendingResume.time > 5,
              pendingResume.time < max(0, loadedDuration - 20) else { return }
        renderer.seek(to: min(pendingResume.time, max(0, loadedDuration - 1)))
    }

    private func applyMediaDefaults(to renderer: MPVGPUPlayerRenderer) {
        guard let preferences = activePreferences else { return }
        playbackSpeed = preferences.defaultPlaybackSpeed
        _ = renderer.command(["set", "speed", String(format: "%.3f", preferences.defaultPlaybackSpeed)])
        _ = renderer.command(["set", "slang", preferences.subtitleLanguage])
        _ = renderer.command(["set", "alang", preferences.audioLanguage])
        _ = renderer.command(["set", "sid", preferences.subtitlesEnabled ? "auto" : "no"])
        _ = renderer.command(["set", "sub-font-size", String(format: "%.1f", preferences.subtitleFontSize)])
        _ = renderer.command(["set", "sub-border-size", String(format: "%.2f", min(5, preferences.subtitleStrokeWidth * 1.5))])
        _ = renderer.command(["set", "sub-pos", String(format: "%.0f", preferences.subtitlePosition)])
        _ = renderer.command(["set", "sub-ass-override", preferences.ignoresEmbeddedSubtitleStyles ? "force" : "no"])
        _ = renderer.command(["set", "sub-ass-use-video-data", "all"])
        _ = renderer.command(["set", "sub-border-style", preferences.subtitleBackgroundEnabled ? "background-box" : "outline-and-shadow"])
        _ = renderer.command(["set", "sub-back-color", preferences.subtitleBackgroundEnabled ? "0.0/0.0/0.0/0.75" : "0.0/0.0/0.0/0.0"])
        _ = renderer.command(["set", "af", preferences.audioFilterChain])
        _ = renderer.command(["set", "cache", preferences.streamCacheEnabled ? "yes" : "no"])
        _ = renderer.command(["set", "demuxer-max-bytes", "\(preferences.streamCacheLimitMB)M"])
        _ = renderer.command(["set", "demuxer-max-back-bytes", "\(max(16, preferences.streamCacheLimitMB / 4))M"])
        lastVideoConfigurationSignature = ""
    }

    private func applyVideoPreferencesIfNeeded(force: Bool = false) {
        guard let renderer, let preferences = activePreferences else { return }
        let diagnostics = renderer.diagnosticsSnapshot()
        let configuration = preferences.videoConfiguration(
            videoWidth: diagnostics.videoWidth,
            videoHeight: diagnostics.videoHeight
        )
        guard force || configuration.signature != lastVideoConfigurationSignature else { return }
        lastVideoConfigurationSignature = configuration.signature

        _ = renderer.command(["set", "scale", configuration.scale])
        _ = renderer.command(["set", "cscale", configuration.chromaScale])
        _ = renderer.command(["set", "dscale", configuration.downscale])
        _ = renderer.command(["set", "deband", configuration.deband])

        if var options = rendererOptions,
           options.maximumInlineDrawablePixelCount != configuration.maximumInlineDrawablePixelCount {
            options.maximumInlineDrawablePixelCount = configuration.maximumInlineDrawablePixelCount
            rendererOptions = options
            renderer.updateOptions(options)
            if let hostView { updateLayout(for: hostView) }
        }
    }

    private func updateAutomaticHDRPreference(for view: NSView) {
        guard let renderer,
              let preferences = activePreferences,
              preferences.hdrMode == "auto",
              var options = rendererOptions else { return }
        let shouldEnable = preferences.targetColorspaceHintEnabled(for: view.window?.screen)
        guard options.enablesTargetColorspaceHint != shouldEnable else { return }
        options.enablesTargetColorspaceHint = shouldEnable
        rendererOptions = options
        renderer.updateOptions(options)
    }
}

private struct MacPlayerSkinAppearance {
    let primary: Color
    let secondary: Color

    static func resolve(_ rawValue: String) -> MacPlayerSkinAppearance {
        switch rawValue {
        case "blackAndGold":
            return MacPlayerSkinAppearance(
                primary: Color(red: 0.98, green: 0.79, blue: 0.30),
                secondary: Color(red: 0.38, green: 0.25, blue: 0.04)
            )
        case "prismatic":
            return MacPlayerSkinAppearance(
                primary: Color(red: 0.51, green: 0.91, blue: 1.00),
                secondary: Color(red: 0.77, green: 0.35, blue: 0.96)
            )
        case "cyberpunk", "cypberpunk":
            return MacPlayerSkinAppearance(
                primary: Color(red: 0.09, green: 0.95, blue: 0.98),
                secondary: Color(red: 1.00, green: 0.14, blue: 0.65)
            )
        default:
            return MacPlayerSkinAppearance(primary: .white, secondary: .purple)
        }
    }
}

struct MacPlayerView: View {
    @EnvironmentObject private var playback: MacPlaybackController
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubPosition: Double?
    @AppStorage("mpvPictureInPictureEnabled") private var pictureInPictureEnabled = true
    @AppStorage("mpvPlayerSkin") private var playerSkin = "default"
    @AppStorage("mpvPlayerSkinTintControlsOnly") private var tintControlsOnly = false
    @AppStorage("experimentalMPVShowRemainingTime") private var showRemainingTime = true
    @AppStorage("experimentalMPVPreciseProgress") private var preciseProgress = true

    var body: some View {
        ZStack {
            Color.black
            MacMPVSurface()
                .environmentObject(playback)

            if !playback.hasMedia {
                ContentUnavailableView("Nothing Playing", systemImage: "play.rectangle", description: Text("Open media from Eclipse or press ⌘O."))
            }

            if playback.isLoading {
                ProgressView().controlSize(.large)
            }

            if controlsVisible, playback.hasMedia {
                VStack {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(playback.title).font(.headline).lineLimit(1).foregroundStyle(skin.primary)
                            if let error = playback.errorMessage {
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                        }
                        Spacer()
                    }
                    .padding(20)
                    .background(.linearGradient(colors: topGradientColors, startPoint: .top, endPoint: .bottom))
                    Spacer()
                    controls
                }
                .transition(.opacity)
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .onHover { inside in
            if inside { revealControls() }
        }
        .onTapGesture { revealControls() }
        .onDisappear { playback.stop() }
        .background(MacPlayerKeyMonitor(playback: playback))
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Slider(
                value: scrubBinding,
                in: 0...max(playback.duration, 1),
                step: preciseProgress ? 0.1 : 1,
                onEditingChanged: scrubDidChange
            )
            .tint(skin.primary)
            HStack(spacing: 18) {
                Button { playback.seek(by: -playback.seekInterval) } label: { Image(systemName: "gobackward") }
                Button { playback.togglePlayback() } label: {
                    Image(systemName: playback.isPaused ? "play.fill" : "pause.fill")
                        .font(.title2)
                        .frame(width: 28)
                }
                Button { playback.seek(by: playback.seekInterval) } label: { Image(systemName: "goforward") }
                Text(time(playback.position))
                    .monospacedDigit().font(.caption).foregroundStyle(skin.primary)
                Text(showRemainingTime ? "−\(time(max(0, playback.duration - playback.position)))" : "/ \(time(playback.duration))")
                    .monospacedDigit().font(.caption).foregroundStyle(.secondary)
                    .help(showRemainingTime ? "Time Remaining" : "Duration")
                Spacer()
                Button { playback.cycleAudioTrack() } label: { Image(systemName: "waveform") }.help("Next Audio Track (A)")
                Button { playback.cycleSubtitles() } label: { Image(systemName: "captions.bubble") }.help("Next Subtitle Track (S)")
                Button { playback.cycleSpeed() } label: { Text(String(format: "%gx", playback.playbackSpeed)).monospacedDigit() }.help("Playback Speed")
                Button { playback.toggleMute() } label: { Image(systemName: "speaker.wave.2.fill") }
                if pictureInPictureEnabled {
                    Button { playback.togglePictureInPicture() } label: { Image(systemName: "pip.enter") }
                        .help("Picture in Picture (P)")
                }
                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help("Full Screen (F)")
                Button {
                    playback.stop()
                    dismissWindow(id: MacWindowID.player)
                } label: { Image(systemName: "xmark.circle.fill") }
                    .help("Close Player")
            }
            .buttonStyle(.plain)
            .foregroundStyle(skin.primary)
        }
        .padding(20)
        .background(.linearGradient(colors: controlGradientColors, startPoint: .top, endPoint: .bottom))
        .shadow(color: playerSkin == "default" ? .clear : skin.secondary.opacity(0.2), radius: 18, y: 8)
    }

    private var skin: MacPlayerSkinAppearance {
        MacPlayerSkinAppearance.resolve(playerSkin)
    }

    private var topGradientColors: [Color] {
        guard playerSkin != "default", !tintControlsOnly else { return [.black.opacity(0.78), .clear] }
        return [.black.opacity(0.84), skin.secondary.opacity(0.18), .clear]
    }

    private var controlGradientColors: [Color] {
        guard playerSkin != "default", !tintControlsOnly else { return [.clear, .black.opacity(0.9)] }
        return [.clear, skin.secondary.opacity(0.13), .black.opacity(0.94)]
    }

    private var scrubBinding: Binding<Double> {
        Binding(
            get: { min(max(0, scrubPosition ?? playback.position), max(playback.duration, 1)) },
            set: { scrubPosition = $0 }
        )
    }

    private func scrubDidChange(_ isEditing: Bool) {
        if isEditing {
            if scrubPosition == nil { scrubPosition = playback.position }
        } else {
            let target = scrubPosition
            scrubPosition = nil
            if let target { playback.seek(toTime: target) }
            revealControls()
        }
    }

    private func revealControls() {
        withAnimation(.easeOut(duration: 0.16)) { controlsVisible = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, !playback.isPaused else { return }
            await MainActor.run { withAnimation { controlsVisible = false } }
        }
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct MacMPVSurface: NSViewRepresentable {
    @EnvironmentObject private var playback: MacPlaybackController

    func makeNSView(context: Context) -> MacMPVHostView {
        let view = MacMPVHostView()
        view.onLayout = { [weak playback] host in playback?.updateLayout(for: host) }
        playback.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: MacMPVHostView, context: Context) {
        playback.updateLayout(for: nsView)
    }

    static func dismantleNSView(_ nsView: MacMPVHostView, coordinator: ()) {
        MacPlaybackController.shared.detach(from: nsView)
    }
}

private final class MacMPVHostView: NSView {
    var onLayout: ((MacMPVHostView) -> Void)?
    override func layout() {
        super.layout()
        onLayout?(self)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onLayout?(self)
    }
}

private struct MacPlayerKeyMonitor: NSViewRepresentable {
    let playback: MacPlaybackController
    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.playback = playback
        return view
    }
    func updateNSView(_ nsView: KeyView, context: Context) { nsView.playback = playback }

    final class KeyView: NSView {
        weak var playback: MacPlaybackController?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
        override func keyDown(with event: NSEvent) {
            guard let playback else { return super.keyDown(with: event) }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case " ": playback.togglePlayback()
            case "m": playback.toggleMute()
            case "p": playback.togglePictureInPicture()
            case "a": playback.cycleAudioTrack()
            case "s": playback.cycleSubtitles()
            case "f": window?.toggleFullScreen(nil)
            default:
                switch event.keyCode {
                case 123: playback.seek(by: -keyboardSeekInterval(for: event, playback: playback))
                case 124: playback.seek(by: keyboardSeekInterval(for: event, playback: playback))
                case 125: playback.adjustVolume(by: -5)
                case 126: playback.adjustVolume(by: 5)
                default: super.keyDown(with: event)
                }
            }
        }

        private func keyboardSeekInterval(for event: NSEvent, playback: MacPlaybackController) -> Double {
            if event.modifierFlags.contains(.shift) { return 60 }
            let preciseEnabled = (UserDefaults.standard.object(forKey: "experimentalMPVPreciseProgress") as? Bool) ?? true
            if preciseEnabled, event.modifierFlags.contains(.option) { return 1 }
            return playback.seekInterval
        }
    }
}
