#if os(macOS)
import AppKit
import AVFoundation
import AVKit
import Combine
import MediaPlayer
import MPVKitSampleBufferGPL

@MainActor
final class MacPlaybackSession: NSObject, ObservableObject {
    let id = UUID()
    let request: PlaybackRequest
    let owner: UUID
    let authority: ProgressManager.ProfileMutationAuthority
    let surface = MacPlaybackSurfaceView()
    @Published private(set) var engine: PlaybackEngine
    @Published private(set) var isPlaying = false
    @Published private(set) var isReady = false
    @Published private(set) var isBuffering = true
    @Published private(set) var isPictureInPicture = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var audioTracks: [MacPlaybackTrack] = []
    @Published private(set) var subtitleTracks: [MacPlaybackTrack] = []
    @Published private(set) var selectedAudioID = -1
    @Published private(set) var selectedSubtitleID = -1
    @Published private(set) var subtitleText = ""
    @Published private(set) var nextEpisode: ResolvedNextEpisodeTarget?
    @Published private(set) var onlineSubtitles: [MacOnlineSubtitle] = []
    @Published private(set) var searchingOnlineSubtitles = false
    private var onlineSubtitleTask: Task<Void, Never>?
    private var onlineSubtitleGeneration: UInt64 = 0
    private var automaticSubtitleTask: Task<Void, Never>?
    private var userSelectedSubtitle = false
    @Published private(set) var activeSkipSegment: SkipSegment?
    @Published private(set) var skip85SecondsAvailable = false
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var speed: Double = 1
    @Published var volume: Double = 1
    @Published var performanceText = ""
    var onClose: (() -> Void)?
    var onRestoreMainWindow: (() -> Void)?
    private var renderer: MPVGPUPlayerRenderer?
    private let intelCompatibility = PlatformCapabilities.current.intelMacCompatibility
    private var intelRecoveryTask: Task<Void, Never>?
    private var intelRecoveryIdentity: UUID?
    private var intelWakeValidationPending = false
    private var intelWakeValidationAttempts = 0
    private var intelWakeNextValidationAt: TimeInterval = 0
    private(set) var player: AVPlayer?
    private var resourceLoader: AVPlayerResourceLoader?
    private var proxyURL: URL?
    private var proxyLease: PlaybackProxySessionOwnership.Lease?
    private var pictureInPictureController: AVPictureInPictureController?
    private var statusObservation: NSKeyValueObservation?
    private var playbackEndObserver: NSObjectProtocol?
    private var autoplayCompletionGate = MacAutoplayCompletionGate()
    private var autoplayTask: Task<Void, Never>?
    private var subtitleTimingControlsPresented = false
    private var playbackTimer: Timer?
    private var skipTask: Task<Void, Never>?
    private var skipSegments: [SkipSegment] = []
    private var skippedSegments = Set<String>()
    private var didRequestSkipSegments = false
    private var alternateResumePosition: Double?
    private var lastQualitySignature = ""
    private var lastInlineBounds = CGRect.zero
    private var lastInlineScale: CGFloat = 0
    private var downloadLeases: [DownloadStorageLease] = []
    private var engineStopTasks: [Task<Void, Never>] = []
    private var shutdownTask: Task<Void, Never>?
    @Published private(set) var isRefreshingSource = false
    @Published private(set) var requestedSourceEpisode: PlayerEpisodeBrowserItem?
    @Published private(set) var showsNextEpisodeButton = false
    private var sourceRefreshTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var playbackDesired = true
    private var playbackActivity: NSObjectProtocol?
    private var systemIsSleeping = false
    @Published private(set) var pendingMPVSubtitle: URL?
    private var nextEpisodeStagingTask: Task<Void, Never>?
    private var stagedNextEpisode: PlaybackRequest?
    private struct NextEpisodeStagingAuthority {
        let loadGeneration: UInt64
        let scope: ProviderPlaybackScopeAuthority
        let watchTogetherIdentity: WatchTogetherPlaybackHandoffIdentity
    }
    private var stagedNextEpisodeAuthority: NextEpisodeStagingAuthority?
    private var stagedNextEpisodeLease: PlaybackProxySessionOwnership.Lease?
    private var didStageNextEpisode = false
    private var nextEpisodeTask: Task<Void, Never>?
    private var subtitleTask: Task<Void, Never>?
    private var pictureInPictureTask: Task<Void, Never>?
    private var pictureInPictureRestoreTask: Task<Void, Never>?
    private var lastStateDiagnosticAt = Date.distantPast
    private var nextSubtitleID = -100
    private var externalSubtitles: [Int: [TVExternalSubtitleCue]] = [:]
    private var externalSubtitleNames: [Int: String] = [:]
    private var subtitleDownloads: [TVBoundedSubtitleDownload] = []
    private var subtitleSelectionGeneration: UInt64 = 0
    private var avAudioOptions: [AVMediaSelectionOption] = []
    private var avSubtitleOptions: [AVMediaSelectionOption] = []
    private var mediaInfo: MediaInfo?
    private var playbackContext: EpisodePlaybackContext?
    private var loadGeneration: UInt64 = 0
    private var subtitleGeneration: UInt64 = 0
    private var stopped = false
    private var started = false
    private var hasLease = false
    private var hasAppliedInitialSeek = false
    private var hasAppliedTrackDefaults = false
    private var hasStartedPlayback = false
    private var observedPlaybackMovement: Double = 0
    private var hasAttemptedFallback = false
    private(set) var isRestoringPictureInPicture = false
    private var pictureInPictureRestoreAuthority: MacPlaybackRestorationAuthority?
    private var lastPersistedAt = Date.distantPast
    private var lastScrobbledAt = Date.distantPast
    private var securityScopedURLs: [URL] = []
    private var remoteCommandTokens: [(MPRemoteCommand, Any)] = []
    private var observers: [NSObjectProtocol] = []
    private let requestedEngine: PlaybackEngine
    private let defaults: UserDefaults
    private let localResumeStore: MacLocalPlaybackResumeStore
    private var mediaSelectionIntent: PlaybackMediaSelectionIntent
    private var addedSubtitles: [(url: String, name: String)] = []
    private var externalSubtitleURLs: [Int: String] = [:]
    private var preferredExternalSubtitleURL: String?

    init(request: PlaybackRequest, engine: PlaybackEngine, owner: UUID,
         authority: ProgressManager.ProfileMutationAuthority,
         defaults: UserDefaults? = nil, localResumeStore: MacLocalPlaybackResumeStore = .shared) {
        let prepared: PlaybackRequest
        let preparationError: String?
        do {
            prepared = try PlaybackExternalAudioTransport.prepare(request)
            preparationError = nil
        } catch {
            prepared = request
            preparationError = error.localizedDescription
        }
        let request = prepared
        self.request = request
        self.mediaSelectionIntent = request.mediaSelectionIntent
        self.owner = owner
        self.authority = authority
        self.defaults = defaults ?? ProfileSettingsStore.active
        self.localResumeStore = localResumeStore
        self.requestedEngine = PlaybackExternalAudioTransport.requiresMPV(request.url) ? .mpv
            : TypedPluginPlaybackEnginePolicy.effectiveEngine(
                requested: engine, sourceKind: request.launchContext?.sourceKind)
        self.engine = PlaybackLaunchPlan.make(selection: requestedEngine, deviceFamily: .mac).primary
        mediaInfo = request.mediaInfo
        playbackContext = request.episodePlaybackContext
        super.init()
        errorMessage = preparationError
        if PlaybackExternalAudioTransport.requiresMPV(request.url) {
            notice = PlaybackExternalAudioTransport.mpvReason
        }
        speed = bounded(self.defaults.object(forKey: "defaultPlaybackSpeed") as? Double ?? 1, range: 0.25...3)
        proxyLease = request.launchContext?.ephemeralProxyOwnership?.acquireLease()
        surface.onGeometryChange = { [weak self] in self?.updateDisplay() }
    }

    var isCurrentOwner: Bool {
        !stopped && ProgressManager.shared.profileMutationAuthorityIsCurrent(authority)
    }

    var supportsPictureInPicture: Bool {
        PlatformCapabilities.current.supportsPictureInPicture
            && (engine != .mpv || intelCompatibility.supportsMPVPictureInPicture)
    }

    func start() {
        guard !started, isCurrentOwner else { return }
        started = true
        if let errorMessage {
            if let context = request.launchContext {
                request.onPlaybackStartupFailure?(.init(context: context, message: errorMessage, isSourceFailure: true))
            }
            return
        }
        if request.url.isFileURL {
            if let item = DownloadManager.shared.completedDownloads.first(where: {
                DownloadManager.shared.localFileURL(for: $0)?.standardizedFileURL == request.url.standardizedFileURL
            }) {
                do {
                    downloadLeases.append(try DownloadManager.shared.acquirePlaybackLease(for: item))
                    if let subtitle = try? DownloadManager.shared.acquireSubtitleLease(for: item) {
                        downloadLeases.append(subtitle)
                    }
                } catch {
                    errorMessage = "The downloaded file is no longer available."
                    return
                }
            }
            if request.url.startAccessingSecurityScopedResource() { securityScopedURLs.append(request.url) }
        }
        MediaStatePlaybackLease.begin()
        hasLease = true
        startEngine()
        installRemoteCommands()
        WatchTogetherCoordinator.shared.attach(self,
            mediaIdentifier: watchTogetherMediaDescriptor.flatMap(WatchTogetherCoordinator.mediaIdentifier(for:)),
            title: request.title)
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        playbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.autoplayTask?.cancel() }
            })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.autoplayTask?.cancel()
                    self?.intelRecoveryTask?.cancel()
                    self?.systemIsSleeping = true
                    self?.updatePlaybackActivity()
                }
            })
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeScreenProfileNotification,
                     NSApplication.didChangeScreenParametersNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateDisplay() }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.systemIsSleeping = false
                    self.recoverAfterWake()
                    self.updatePlaybackActivity()
                }
            })
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification,
            object: defaults, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.applyRuntimeSettings() }
            })

    }

    private func startEngine() {
        guard isCurrentOwner else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        isReady = false
        isBuffering = true
        hasAppliedInitialSeek = false
        hasAppliedTrackDefaults = false
        errorMessage = nil
        externalSubtitles.removeAll()
        externalSubtitleNames.removeAll()
        externalSubtitleURLs.removeAll()
        selectedAudioID = -1
        selectedSubtitleID = -1
        nextSubtitleID = -100
        if engine == .mpv {
            if intelCompatibility.isEnabled, !MPVGPUPlayerRenderer.isSupported {
                failLocalRenderer(MPVGPUPlayerRenderer.inlineGPUUnavailableReason ?? "Metal is unavailable on this Mac.")
                return
            }
            surface.showMPV()
            var options = MPVGPUPlayerRendererOptions(
                hardwareDecoding: "videotoolbox,videotoolbox-copy",
                enablesTargetColorspaceHint: false,
                pictureInPicturePreparationTimeout: 3,
                maximumInlineDrawablePixelCount: 0,
                additionalMPVOptions: ["ao": PlaybackAudioOutputPolicy.driverList,
                    "hwdec-software-fallback": "no", "keep-open": "yes", "pause": playbackDesired ? "no" : "yes",
                    "demuxer-thread": "yes", "cache": "yes", "cache-pause-wait": "5",
                    "demuxer-max-bytes": "80M", "demuxer-readahead-secs": "10",
                    "vulkan-async-compute": "no", "vulkan-async-transfer": "no",
                    "vulkan-queue-count": "1", "vulkan-swap-mode": "fifo"]
                    .merging(MPVDolbyPlaybackSettings(defaults: defaults).options) { _, value in value })
            if intelCompatibility.isEnabled {
                options.hardwareDecoding = MacIntelPlaybackPolicy.hardwareDecoding
                options.maximumInlineDrawablePixelCount = MacIntelPlaybackPolicy.maximumDrawablePixelCount
                options.additionalMPVOptions = MacIntelPlaybackPolicy.options(options.additionalMPVOptions,
                    compatibility: intelCompatibility)
            }
            let renderer = MPVGPUPlayerRenderer(view: surface.gpuView, options: options)
            self.renderer = renderer
            surface.installPictureInPictureLayer(renderer.pictureInPictureDisplayLayer)
            renderer.onStateChange = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.loadGeneration == generation, self.isCurrentOwner else { return }
                    Logger.shared.log("MacPlayback event=renderer-state state=\(state) generation=\(generation)", type: "PlaybackTrace")
                    self.isBuffering = state == .loading || state == .starting
                    switch state {
                    case .ready, .playing, .paused, .pictureInPicture:
                        self.becameReady()
                    case .failed(let message): self.failed(message)
                    default: break
                    }
                }
            }
            renderer.onError = { [weak self] message in
                Task { @MainActor in
                    guard let self, self.loadGeneration == generation else { return }
                    self.failed(message)
                }
            }
            renderer.onPlaybackEndForGeneration = { [weak self] endedGeneration in
                Task { @MainActor in
                    self?.playbackDidEnd(generation: endedGeneration)
                }
            }
            renderer.onInlineHitchDiagnostic = { message in
                Logger.shared.log("MacPlayback: \(message)", type: "PlaybackTrace")
            }
            renderer.onPictureInPictureStopRequested = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isCurrentOwner, self.loadGeneration == generation else { return }
                    self.pictureInPictureController?.stopPictureInPicture()
                }
            }
            do {
                try renderer.start()
                renderer.setVideoFilterChain(MPVDolbyPlaybackSettings(defaults: defaults).videoFilterChain)
                request.preset.commands.forEach { _ = renderer.command($0) }
                if intelCompatibility.isEnabled {
                    let enforced = MacIntelPlaybackPolicy.options(["hwdec": MacIntelPlaybackPolicy.hardwareDecoding],
                        compatibility: intelCompatibility)
                    guard enforced.sorted(by: { $0.key < $1.key }).allSatisfy({
                        renderer.command(["set", $0.key, $0.value]) >= 0
                    }) else {
                        failLocalRenderer("The Intel playback configuration could not be applied.")
                        return
                    }
                }
                let transportURL: URL
                let transportHeaders: [String: String]
                if request.launchContext?.sourceKind != .skyStream,
                   ExperimentalMPVPreloadManager.shared.shouldUsePlaybackProxy(for: request.url),
                   let proxy = MPVHeaderProxy.shared.makeProxyURL(for: request.url, headers: request.headers,
                       logType: "MPV", traceID: request.launchContext?.traceID,
                       allowsSharedCloudflareBypass: !request.usesMangayomiSource,
                       onConfirmedCloudflareChallenge: { [weak self] url, rejectedCookie, interactive, _ in
                           Task { @MainActor in
                               guard let self, self.loadGeneration == generation, self.isCurrentOwner else { return }
                               self.refreshSource(challengeURL: url, rejectedCookie: rejectedCookie, interactive: interactive)
                           }
                       }) {
                    proxyURL = proxy
                    transportURL = proxy
                    transportHeaders = [:]
                } else {
                    transportURL = request.url
                    transportHeaders = request.headers
                }
                renderer.load(transportURL, headers: transportHeaders, generation: generation)
                if !playbackDesired { renderer.pause() }
                renderer.setSpeed(speed)
                applyRuntimeSettings()
            } catch {
                if intelCompatibility.isEnabled {
                    failLocalRenderer(error.localizedDescription)
                } else {
                    failed(error.localizedDescription)
                }
            }
        } else {
            let deliveredURL: URL
            if !request.url.isFileURL, !request.headers.isEmpty {
                guard let url = MPVHeaderProxy.shared.makeProxyURL(for: request.url,
                    headers: request.headers, traceID: request.launchContext?.traceID,
                    allowsSharedCloudflareBypass: !request.usesMangayomiSource,
                    onConfirmedCloudflareChallenge: { [weak self] url, rejectedCookie, interactive, _ in
                        Task { @MainActor in
                            guard let self, self.loadGeneration == generation, self.isCurrentOwner else { return }
                            self.refreshSource(challengeURL: url, rejectedCookie: rejectedCookie, interactive: interactive)
                        }
                    }) else {
                    failed("The stream transport could not start.")
                    return
                }
                proxyURL = url
                deliveredURL = url
            } else {
                deliveredURL = request.url
            }
            let backed = AVPlayerResourceLoader.makeItem(url: deliveredURL, headers: [:])
            resourceLoader = backed.loader
            let player = AVPlayer(playerItem: backed.item)
            self.player = player
            playbackEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: backed.item, queue: .main
            ) { [weak self, weak player] _ in
                Task { @MainActor in
                    guard let self, let player, self.player === player else { return }
                    self.playbackDidEnd(generation: generation)
                }
            }
            player.volume = Float(volume)
            surface.showAVPlayer(player)
            statusObservation = backed.item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, self.loadGeneration == generation, self.isCurrentOwner else { return }
                    if item.status == .readyToPlay { self.becameReady() }
                    if item.status == .failed { self.failed(item.error?.localizedDescription ?? "Playback could not start.") }
                }
            }
        }
        updateDisplay()
        scheduleStartupCheck()
    }

    private func becameReady() {
        guard isCurrentOwner else { return }
        isReady = true
        isBuffering = false
        if !hasAppliedInitialSeek {
            hasAppliedInitialSeek = true
            let resume = alternateResumePosition ?? request.resumePosition ?? savedPosition()
            alternateResumePosition = nil
            if resume > 0 { seek(to: resume, broadcast: false) }
            setPlaying(playbackDesired, broadcast: false)
        }
        if !hasAppliedTrackDefaults {
            hasAppliedTrackDefaults = true
            refreshTracks(applyDefaults: true)
            if renderer != nil {
                renderer?.loadExternalSubtitles(urls: attachedSubtitleInputs.map(\.url), names: attachedSubtitleInputs.map(\.name),
                    selectFirst: mediaSelectionIntent.subtitlesEnabled,
                    headersByURL: request.subtitleHeadersByURL)
            } else {
                loadAVExternalSubtitles()
            }
            scheduleAutomaticSubtitleFallback()
        }
        _ = WatchTogetherCoordinator.shared.playbackDidBecomeReady(self)
    }

    func togglePlayback() { setPlaying(!isPlaying) }

    func setPlaying(_ playing: Bool, broadcast: Bool = true) {
        guard isCurrentOwner else { return }
        if playing {
            renderer?.play()
            player?.playImmediately(atRate: Float(speed))
        } else {
            autoplayTask?.cancel()
            renderer?.pause()
            player?.pause()
        }
        isPlaying = playing
        playbackDesired = playing
        if playing, intelWakeValidationPending, let renderer { recoverIntelPlaybackAfterWake(renderer) }
        updatePlaybackActivity()
        if playing, !hasStartedPlayback, startupTask == nil { scheduleStartupCheck() }
        if broadcast {
            if playing { WatchTogetherCoordinator.shared.sendUserPlay(from: self) }
            else { WatchTogetherCoordinator.shared.sendUserPause(from: self) }
            persistProgress(action: playing ? .start : .pause)
        }
        updateNowPlaying()
    }

    func seek(to seconds: Double, broadcast: Bool = true) {
        guard isCurrentOwner, seconds.isFinite else { return }
        autoplayTask?.cancel()
        let value = max(0, duration > 0 ? min(seconds, duration) : seconds)
        renderer?.seek(to: value)
        player?.seek(to: CMTime(seconds: value, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        position = value
        if broadcast { WatchTogetherCoordinator.shared.sendUserSeek(to: value, from: self) }
    }

    var seekStep: Double {
        bounded(Settings.shared.playerDoubleTapSeekSeconds, range: 5...60)
    }

    func seek(by seconds: Double) { seek(to: position + seconds) }

    func setSpeed(_ value: Double, broadcast: Bool = true) {
        guard isCurrentOwner else { return }
        speed = bounded(value, range: 0.25...3)
        renderer?.setSpeed(speed)
        if isPlaying { player?.rate = Float(speed) }
        if broadcast { WatchTogetherCoordinator.shared.sendUserPlaybackRate(speed, from: self) }
    }

    func setVolume(_ value: Double) {
        guard isCurrentOwner else { return }
        volume = bounded(value, range: 0...1)
        player?.volume = Float(volume)
        _ = renderer?.command(["set", "volume", String(volume * 100)])
    }

    func selectAudio(_ id: Int) {
        guard isCurrentOwner else { return }
        if let renderer { renderer.setAudioTrack(id: id) }
        else if avAudioOptions.indices.contains(id), let item = player?.currentItem,
                let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) {
            item.select(avAudioOptions[id], in: group)
        }
        selectedAudioID = id
        updateMediaSelectionIntent()
    }

    var subtitleDelaySeconds: Double {
        PlayerSubtitleTiming.sanitized(defaults.double(forKey: "playerSubtitleDelaySeconds"))
    }

    func adjustSubtitleDelay(by adjustment: Double?) {
        guard isCurrentOwner, engine == .mpv, renderer != nil else { return }
        defaults.set(adjustment.map { PlayerSubtitleTiming.sanitized(subtitleDelaySeconds + $0) } ?? 0,
                     forKey: "playerSubtitleDelaySeconds")
        applySubtitleAppearance()
        objectWillChange.send()
    }

    func selectSubtitle(_ id: Int, userInitiated: Bool = true) {
        guard isCurrentOwner else { return }
        if userInitiated { userSelectedSubtitle = true }
        subtitleSelectionGeneration &+= 1
        if let renderer { renderer.setSubtitleTrack(id: id) }
        else if let item = player?.currentItem,
                let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
            item.select(avSubtitleOptions.indices.contains(id) ? avSubtitleOptions[id] : nil, in: group)
        }
        selectedSubtitleID = id
        subtitleText = ""
        updateMediaSelectionIntent(subtitleChanged: true)
    }

    private func updateMediaSelectionIntent(subtitleChanged: Bool = false) {
        let audioLanguage = renderer?.audioTracks().first(where: { $0.id == selectedAudioID })?.language
            ?? (avAudioOptions.indices.contains(selectedAudioID) ? avAudioOptions[selectedAudioID].extendedLanguageTag : nil)
        let subtitleLanguage = renderer?.subtitleTracks().first(where: { $0.id == selectedSubtitleID })?.language
            ?? (avSubtitleOptions.indices.contains(selectedSubtitleID) ? avSubtitleOptions[selectedSubtitleID].extendedLanguageTag : nil)
        mediaSelectionIntent = mediaSelectionIntent.overridingRendererSelection(audioLanguage: audioLanguage,
            subtitleLanguage: subtitleLanguage,
            hasSelectedSubtitle: subtitleChanged ? selectedSubtitleID != -1 : (selectedSubtitleID != -1 ? true : nil))
        let externalURL = renderer?.currentExternalSubtitleURL() ?? externalSubtitleURLs[selectedSubtitleID]
        if subtitleChanged || externalURL != nil { preferredExternalSubtitleURL = externalURL }
    }

    private var attachedSubtitleInputs: [(url: String, name: String)] {
        var inputs = request.subtitles.enumerated().map { index, url in
            (url: url, name: request.subtitleNames.flatMap { $0.indices.contains(index) ? $0[index] : nil }
                ?? URL(string: url)?.deletingPathExtension().lastPathComponent ?? "Subtitle")
        } + addedSubtitles
        if let preferredExternalSubtitleURL,
           let index = inputs.firstIndex(where: { $0.url == preferredExternalSubtitleURL }) {
            let selected = inputs.remove(at: index)
            inputs.insert(selected, at: 0)
        } else if let index = PlaybackLanguageSelectionPolicy.preferredIndex(in: inputs.map {
            .init(languageTag: nil, displayName: $0.name)
        }, preferredLanguage: mediaSelectionIntent.preferredSubtitleLanguage) {
            let preferred = inputs.remove(at: index)
            inputs.insert(preferred, at: 0)
        }
        return inputs
    }

    func addSubtitle(_ url: URL) {
        guard isCurrentOwner else { return }
        userSelectedSubtitle = true
        guard MacPlaybackFileTypes.subtitleExtensions.contains(url.pathExtension.lowercased()), addedSubtitles.count < 40 else { return }
        if url.isFileURL, url.startAccessingSecurityScopedResource() { securityScopedURLs.append(url) }
        let name = url.deletingPathExtension().lastPathComponent
        addedSubtitles.append((url.absoluteString, name))
        preferredExternalSubtitleURL = url.absoluteString
        mediaSelectionIntent = mediaSelectionIntent.overridingRendererSelection(audioLanguage: nil, subtitleLanguage: nil, hasSelectedSubtitle: true)
        if engine == .avPlayer, !MacPlaybackFileTypes.avOverlaySubtitleExtensions.contains(url.pathExtension.lowercased()) {
            pendingMPVSubtitle = url
            notice = "This subtitle format requires MPV."
            return
        }
        if let renderer {
            renderer.loadExternalSubtitles(urls: [url.absoluteString], names: [url.deletingPathExtension().lastPathComponent])
        } else {
            loadAVExternalSubtitles(urls: [url.absoluteString], names: [url.deletingPathExtension().lastPathComponent], forceSelection: true)
        }
    }

    private func scheduleAutomaticSubtitleFallback() {
        automaticSubtitleTask?.cancel()
        let generation = loadGeneration
        automaticSubtitleTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            guard let self, self.isCurrentOwner, self.loadGeneration == generation else { return }
            await self.subtitleTask?.value
            guard !Task.isCancelled, self.isCurrentOwner, self.loadGeneration == generation,
                  self.canApplyAutomaticSubtitleFallback else { return }
            self.searchOnlineSubtitles(automaticallySelect: true)
        }
    }

    private var canApplyAutomaticSubtitleFallback: Bool {
        guard !userSelectedSubtitle, mediaSelectionIntent.subtitlesEnabled,
              Settings.shared.playerOpenSubtitlesAutoFallbackEnabled,
              mediaSelectionIntent.preferredSubtitleLanguage != nil else { return false }
        let local: [PlaybackLanguageSelectionPolicy.Option]
        if let renderer {
            local = renderer.subtitleTracks().map { .init(languageTag: $0.language, displayName: $0.title) }
        } else {
            local = avSubtitleOptions.map { .init(languageTag: $0.extendedLanguageTag, displayName: $0.displayName) }
                + externalSubtitleNames.values.map { .init(languageTag: nil, displayName: $0) }
        }
        return PlaybackLanguageSelectionPolicy.preferredIndex(in: local,
            preferredLanguage: mediaSelectionIntent.preferredSubtitleLanguage) == nil
    }

    func searchOnlineSubtitles(automaticallySelect: Bool = false) {
        guard isCurrentOwner else { return }
        onlineSubtitleTask?.cancel()
        onlineSubtitleGeneration &+= 1
        let generation = onlineSubtitleGeneration
        let sourceGeneration = ServiceStoreScope.generation
        let playbackGeneration = loadGeneration
        searchingOnlineSubtitles = true
        onlineSubtitleTask = Task { [weak self] in
            guard let self else { return }
            let results = await MacOnlineSubtitleResolver.resolve(request: self.request,
                includesOpenSubtitles: Settings.shared.playerOpenSubtitlesEnabled,
                isStillCurrent: { self.isCurrentOwner && !Task.isCancelled && self.loadGeneration == playbackGeneration && ServiceStoreScope.isCurrent(sourceGeneration) })
            guard self.isCurrentOwner, !Task.isCancelled, self.onlineSubtitleGeneration == generation,
                  self.loadGeneration == playbackGeneration, ServiceStoreScope.isCurrent(sourceGeneration) else { return }
            self.searchingOnlineSubtitles = false
            self.onlineSubtitles = results
            if automaticallySelect, self.canApplyAutomaticSubtitleFallback,
               let index = PlaybackLanguageSelectionPolicy.preferredIndex(in: results.map {
                   .init(languageTag: $0.language, displayName: $0.title)
               }, preferredLanguage: self.mediaSelectionIntent.preferredSubtitleLanguage) {
                self.selectOnlineSubtitle(results[index], userInitiated: false)
            }
            self.prefetchOnlineSubtitles(menuIsOpen: !automaticallySelect)
            if results.isEmpty, !automaticallySelect { self.notice = "No online subtitles were found." }
        }
    }

    private func prefetchOnlineSubtitles(menuIsOpen: Bool) {
        guard let renderer else { return }
        let options = onlineSubtitles.map { subtitle in
            PlaybackSubtitlePrefetchPolicy.Candidate(url: subtitle.url,
                source: subtitle.sourceID == nil ? .openSubtitles : .addon,
                matchesPreferredLanguage: PlaybackLanguageSelectionPolicy.preferredIndex(in: [
                    .init(languageTag: subtitle.language, displayName: subtitle.title)
                ], preferredLanguage: mediaSelectionIntent.preferredSubtitleLanguage) != nil)
        }
        var enabled = Set<PlaybackSubtitlePrefetchPolicy.Source>()
        if !StremioAddonManager.shared.activeSubtitleAddons.isEmpty { enabled.insert(.addon) }
        if Settings.shared.playerOpenSubtitlesEnabled { enabled.insert(.openSubtitles) }
        let process = ProcessInfo.processInfo
        let urls = PlaybackSubtitlePrefetchPolicy.urls(candidates: options, enabledSources: enabled,
            subtitlesEnabled: mediaSelectionIntent.subtitlesEnabled,
            automaticFallbackEnabled: Settings.shared.playerOpenSubtitlesAutoFallbackEnabled,
            warmupEnabled: defaults.bool(forKey: ExperimentalFeatureState.mpvPreloadEnabledKey),
            menuIsOpen: menuIsOpen,
            resourceConstrained: process.isLowPowerModeEnabled || process.thermalState == .serious || process.thermalState == .critical)
        renderer.prefetchExternalSubtitles(urls: urls, headersByURL: [:], allowsCellularAccess: false)
    }

    func selectOnlineSubtitle(_ subtitle: MacOnlineSubtitle, userInitiated: Bool = true) {
        guard isCurrentOwner else { return }
        if userInitiated { userSelectedSubtitle = true }
        if let sourceID = subtitle.sourceID,
           !StremioAddonComponentSettings.allowsSubtitles(sourceID: sourceID) { return }
        guard addedSubtitles.count < 40 else { return }
        addedSubtitles.append((subtitle.url, subtitle.title))
        preferredExternalSubtitleURL = subtitle.url
        mediaSelectionIntent = mediaSelectionIntent.overridingRendererSelection(audioLanguage: nil, subtitleLanguage: nil, hasSelectedSubtitle: true)
        subtitleSelectionGeneration &+= 1
        if let renderer {
            renderer.loadExternalSubtitles(urls: [subtitle.url], names: [subtitle.title], selectFirst: true, headersByURL: [:])
        } else {
            loadAVExternalSubtitles(urls: [subtitle.url], names: [subtitle.title], forceSelection: true)
        }
    }

    var episodeBrowserSeed: PlayerEpisodeBrowserSeed? {
        guard let seed = NextEpisodeSeed(request: request) else { return nil }
        return PlayerEpisodeBrowserSeed(showId: seed.showID, showTitle: seed.showTitle,
            showPosterURL: seed.showPosterURL, currentSeasonNumber: seed.currentSeasonNumber,
            currentEpisodeNumber: seed.currentEpisodeNumber, isAnime: seed.isAnime,
            imdbId: seed.imdbID, currentPlaybackContext: seed.playbackContext, mediaYear: seed.mediaYear)
    }

    func selectEpisode(_ item: PlayerEpisodeBrowserItem) -> Bool {
        guard isCurrentOwner, !item.isCurrent else { return true }
        let identity = WatchTogetherCoordinator.shared.playbackHandoffIdentity
        if identity.sessionID != nil, item.isAnime, item.playbackContext?.hasAnimeMediaId != true {
            notice = "Watch Together needs this episode’s exact anime identity. Open it from the show page so everyone can move together."
            return true
        }
        if defaults.bool(forKey: "preferDownloadedMedia") || request.url.isFileURL,
           let download = item.downloadItem,
           let file = DownloadManager.shared.localFileURL(for: download) {
            let resolved = PlayerResolvedPlaybackRequest(url: file, preset: request.preset,
                headers: [:], subtitles: DownloadManager.shared.localSubtitleURL(for: download).map { [$0.absoluteString] },
                subtitleNames: nil, mediaInfo: nil, imdbId: item.imdbId, isAnimeHint: item.isAnime,
                isAnimationContentHint: request.isAnimation,
                originalTMDBSeasonNumber: item.originalTMDBSeasonNumber,
                originalTMDBEpisodeNumber: item.originalTMDBEpisodeNumber,
                episodePlaybackContext: item.playbackContext, launchContext: nil, mediaYear: item.mediaYear)
            replacePlayback(with: resolved, episode: item, watchTogetherIdentity: identity)
            return true
        }
        return false
    }

    func selectionRequest(for episode: PlayerEpisodeBrowserItem?) -> PlaybackRequest {
        guard let episode else { return request }
        return PlaybackRequest(url: request.url, preset: request.preset,
            mediaInfo: .episode(showId: episode.showId, seasonNumber: episode.episode.seasonNumber,
                episodeNumber: episode.episode.episodeNumber, showTitle: episode.showTitle,
                showPosterURL: episode.showPosterURL, isAnime: episode.isAnime),
            mediaYear: episode.mediaYear, imdbID: episode.imdbId, episodePlaybackContext: episode.playbackContext,
            title: episode.mediaTitle, artworkURL: episode.posterURL.flatMap(URL.init(string:)),
            isAnime: episode.isAnime, isAnimation: request.isAnimation,
            originalTMDBSeasonNumber: episode.originalTMDBSeasonNumber,
            originalTMDBEpisodeNumber: episode.originalTMDBEpisodeNumber,
            servicesOriginalTitle: episode.originalTitle, servicesOriginalAudioLanguage: episode.originalAudioLanguage,
            onRequestNextEpisode: request.onRequestNextEpisode, onRequestResolvedNextEpisode: request.onRequestResolvedNextEpisode)
    }

    func replacePlayback(with resolved: PlayerResolvedPlaybackRequest, episode: PlayerEpisodeBrowserItem?,
                         watchTogetherIdentity: WatchTogetherPlaybackHandoffIdentity? = nil) {
        guard isCurrentOwner, watchTogetherIdentity == nil
                || watchTogetherIdentity == WatchTogetherCoordinator.shared.playbackHandoffIdentity else {
            resolved.launchContext?.ephemeralProxyOwnership?.invalidate()
            return
        }
        if let episode, !commitWatchTogetherEpisode(episode.episode, title: episode.mediaTitle,
            context: episode.playbackContext, expected: watchTogetherIdentity) {
            resolved.launchContext?.ephemeralProxyOwnership?.invalidate()
            return
        }
        let base = selectionRequest(for: episode)
        let next = PlaybackRequest(url: resolved.url, preset: resolved.preset, headers: resolved.headers ?? [:],
            subtitles: resolved.subtitles ?? [], subtitleNames: resolved.subtitleNames,
            subtitleHeadersByURL: resolved.subtitleHeadersByURL, externalAudioTracks: resolved.externalAudioTracks,
            mediaSelectionIntent: mediaSelectionIntent,
            mediaInfo: resolved.mediaInfo ?? base.mediaInfo, kidsPolicyDetails: base.kidsPolicyDetails,
            mediaYear: resolved.mediaYear ?? base.mediaYear, imdbID: resolved.imdbId ?? base.imdbID,
            episodePlaybackContext: resolved.episodePlaybackContext ?? base.episodePlaybackContext,
            launchContext: resolved.launchContext, resumePosition: episode == nil ? position : nil,
            title: base.title, subtitle: base.subtitle, artworkURL: base.artworkURL,
            isAnime: resolved.isAnimeHint || base.isAnime,
            isAnimation: resolved.isAnimationContentHint ?? base.isAnimation,
            originalTMDBSeasonNumber: resolved.originalTMDBSeasonNumber ?? base.originalTMDBSeasonNumber,
            originalTMDBEpisodeNumber: resolved.originalTMDBEpisodeNumber ?? base.originalTMDBEpisodeNumber,
            servicesOriginalTitle: base.servicesOriginalTitle, servicesOriginalAudioLanguage: base.servicesOriginalAudioLanguage,
            onRequestNextEpisode: base.onRequestNextEpisode, onRequestResolvedNextEpisode: base.onRequestResolvedNextEpisode,
            onPlaybackStartupFailure: request.onPlaybackStartupFailure)
        MacPlaybackCoordinator.shared.present(next)
    }

    private func commitWatchTogetherEpisode(_ episode: TMDBEpisode, title: String,
                                           context: EpisodePlaybackContext?,
                                           expected: WatchTogetherPlaybackHandoffIdentity?) -> Bool {
        let current = WatchTogetherCoordinator.shared.playbackHandoffIdentity
        guard expected == nil || expected == current else { return false }
        let result = WatchTogetherCoordinator.shared.sendNextEpisode(seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber, title: title, playbackContext: context, from: self)
        if result == .notActive, current.sessionID != nil {
            notice = "Watch Together changed before the next episode was ready. Sync the session and try again."
            return false
        }
        return result != .rejected
    }

    func playNextEpisode() {
        autoplayTask?.cancel()
        guard isCurrentOwner, let nextEpisode else { return }
        let identity = WatchTogetherCoordinator.shared.playbackHandoffIdentity
        if requiresRememberedSourceSelection(nextEpisode)
            || (stagedNextEpisode != nil && !stagedNextEpisodeAuthorityIsCurrent) {
            nextEpisodeStagingTask?.cancel()
            nextEpisodeStagingTask = nil
            stagedNextEpisode?.launchContext?.ephemeralProxyOwnership?.invalidate()
            stagedNextEpisode = nil
            stagedNextEpisodeAuthority = nil
            stagedNextEpisodeLease?.release()
            stagedNextEpisodeLease = nil
        }
        if let stagedNextEpisode {
            guard commitWatchTogetherEpisode(nextEpisode.episode, title: nextEpisode.mediaTitle,
                context: nextEpisode.playbackContext, expected: identity) else { return }
            MacPlaybackCoordinator.shared.present(stagedNextEpisode.replacingMediaSelectionIntent(mediaSelectionIntent))
        } else if let seed = episodeBrowserSeed {
            Task { [weak self] in
                let model = PlayerEpisodeBrowserViewModel(seed: seed)
                let item = await model.itemAfterCurrent(skippingKnownFillers: NextEpisodeFillerSettings.isEnabled())
                guard let self, self.isCurrentOwner, !Task.isCancelled, let item,
                      identity == WatchTogetherCoordinator.shared.playbackHandoffIdentity else { return }
                if !self.selectEpisode(item) { self.requestedSourceEpisode = item }
            }
        }
    }

    func cancelPendingAutoplay() {
        autoplayTask?.cancel()
    }

    func setSubtitleTimingControlsPresented(_ presented: Bool) {
        subtitleTimingControlsPresented = presented && engine == .mpv && isCurrentOwner
        if presented { cancelPendingAutoplay() }
    }

    private var canAutoplayInline: Bool {
        guard isCurrentOwner, AutoplayNextEpisodeSettings.isEnabled(defaults: defaults),
              !subtitleTimingControlsPresented,
              playbackDesired, hasStartedPlayback, isReady, errorMessage == nil,
              !isRefreshingSource, !isPictureInPicture, !isRestoringPictureInPicture,
              pictureInPictureTask == nil, !systemIsSleeping,
              !MacLaunchProfileAccess.isTerminating, !MacLaunchProfileAccess.requiresUnlock,
              NSApplication.shared.isActive, let window = surface.window,
              window.isVisible, !window.isMiniaturized, window.attachedSheet == nil,
              WatchTogetherCoordinator.shared.playbackHandoffIdentity.sessionID == nil else { return false }
        return true
    }

    private func playbackDidEnd(generation: UInt64) {
        guard generation == loadGeneration, isCurrentOwner else { return }
        if let renderer {
            let snapshot = renderer.diagnosticsSnapshot()
            if snapshot.currentTime.isFinite { position = max(0, snapshot.currentTime) }
            if snapshot.duration.isFinite { duration = max(0, snapshot.duration) }
        } else if let player {
            let time = player.currentTime().seconds
            let total = player.currentItem?.duration.seconds ?? 0
            if time.isFinite { position = max(0, time) }
            if total.isFinite { duration = max(0, total) }
        }
        guard let seed = episodeBrowserSeed,
              autoplayCompletionGate.claim(completedGeneration: generation, currentGeneration: loadGeneration,
                  position: position, duration: duration, isEligible: canAutoplayInline) else { return }
        let windowGeneration = MacLaunchProfileAccess.windowGeneration
        let serviceGeneration = ServiceStoreScope.generation
        let identity = WatchTogetherCoordinator.shared.playbackHandoffIdentity
        let skipsFillers = NextEpisodeFillerSettings.isEnabled()
        persistProgress(action: .stop)
        autoplayTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.loadGeneration == generation { self.autoplayTask = nil } }
            @MainActor func isCurrent() -> Bool {
                !Task.isCancelled && self.canAutoplayInline && self.loadGeneration == generation
                    && windowGeneration == MacLaunchProfileAccess.windowGeneration
                    && ServiceStoreScope.isCurrent(serviceGeneration)
                    && identity == WatchTogetherCoordinator.shared.playbackHandoffIdentity
            }
            let model = PlayerEpisodeBrowserViewModel(seed: seed)
            let item = await model.itemAfterCurrent(skippingKnownFillers: skipsFillers)
            guard isCurrent(), let item else { return }
            if self.selectEpisode(item) { return }
            let target = ResolvedNextEpisodeTarget(showID: item.showId, episode: item.episode,
                playbackContext: item.playbackContext, mediaTitle: item.mediaTitle,
                seasonTitleOverride: item.seasonTitleOverride, originalTitle: item.originalTitle,
                posterURL: item.posterURL, imdbID: item.imdbId, isAnime: item.isAnime,
                isAnimation: self.request.isAnimation, mediaYear: item.mediaYear)
            let resolver = MacProviderPlaybackResolver(
                request: self.request.replacingMediaSelectionIntent(self.mediaSelectionIntent),
                owner: self.owner, authority: self.authority)
            let resolved = await resolver.resolveNext(target)
            guard isCurrent() else {
                resolved?.launchContext?.ephemeralProxyOwnership?.invalidate()
                return
            }
            if let resolved, !self.requiresRememberedSourceSelection(target) {
                MacPlaybackCoordinator.shared.present(resolved.replacingMediaSelectionIntent(self.mediaSelectionIntent))
            } else {
                resolved?.launchContext?.ephemeralProxyOwnership?.invalidate()
                self.notice = "Choose a source to continue with the next episode."
                self.requestedSourceEpisode = item
            }
        }
    }

    private func requiresRememberedSourceSelection(_ target: ResolvedNextEpisodeTarget) -> Bool {
        WatchTogetherCoordinator.shared.playbackHandoffIdentity.sessionID == nil
            && RememberedPlaybackSettings.requiresSourceSelection(
                tmdbID: target.showID, season: target.episode.seasonNumber,
                animeID: target.playbackContext?.anilistMediaId, defaults: defaults)
    }

    private var stagedNextEpisodeAuthorityIsCurrent: Bool {
        guard let authority = stagedNextEpisodeAuthority else { return false }
        return isCurrentOwner && authority.loadGeneration == loadGeneration
            && authority.scope.isCurrent
            && authority.watchTogetherIdentity == WatchTogetherCoordinator.shared.playbackHandoffIdentity
    }

    private func updateNextEpisode() {
        guard duration > 0, let seed = episodeBrowserSeed else { return }
        let savedThreshold = defaults.double(forKey: "nextEpisodeThreshold")
        let threshold = savedThreshold > 0 ? savedThreshold : 0.9
        let progress = position / duration
        showsNextEpisodeButton = (defaults.object(forKey: "showNextEpisodeButton") as? Bool ?? true)
            && progress >= threshold && nextEpisode != nil
        guard progress >= max(0.5, threshold - 0.05) else { return }
        if nextEpisode == nil, nextEpisodeTask == nil {
            nextEpisodeTask = Task { [weak self] in
                let model = PlayerEpisodeBrowserViewModel(seed: seed)
                let next = await model.itemAfterCurrent(skippingKnownFillers: NextEpisodeFillerSettings.isEnabled())
                guard let self, self.isCurrentOwner, !Task.isCancelled, let next else { return }
                self.nextEpisode = .init(showID: next.showId, episode: next.episode, playbackContext: next.playbackContext,
                    mediaTitle: next.mediaTitle, seasonTitleOverride: next.seasonTitleOverride,
                    originalTitle: next.originalTitle, posterURL: next.posterURL, imdbID: next.imdbId,
                    isAnime: next.isAnime, isAnimation: self.request.isAnimation, mediaYear: next.mediaYear)
            }
        }
        guard engine == .mpv, !didStageNextEpisode, let nextEpisode,
              !requiresRememberedSourceSelection(nextEpisode),
              defaults.bool(forKey: ExperimentalFeatureState.mpvSmoothTransitionEnabledKey),
              ExperimentalFeatureState.canUseExperimentalMPVPlayback else { return }
        didStageNextEpisode = true
        let generation = loadGeneration
        let stagingAuthority = NextEpisodeStagingAuthority(
            loadGeneration: generation, scope: .capture(),
            watchTogetherIdentity: WatchTogetherCoordinator.shared.playbackHandoffIdentity)
        nextEpisodeStagingTask = Task { [weak self] in
            guard let self else { return }
            let resolver = MacProviderPlaybackResolver(request: self.request.replacingMediaSelectionIntent(self.mediaSelectionIntent), owner: self.owner, authority: self.authority)
            let staged = await resolver.resolveNext(nextEpisode)
            guard self.isCurrentOwner, !Task.isCancelled, self.loadGeneration == generation,
                  stagingAuthority.scope.isCurrent,
                  stagingAuthority.watchTogetherIdentity == WatchTogetherCoordinator.shared.playbackHandoffIdentity,
                  !self.requiresRememberedSourceSelection(nextEpisode) else {
                staged?.launchContext?.ephemeralProxyOwnership?.invalidate()
                return
            }
            self.stagedNextEpisodeLease = staged?.launchContext?.ephemeralProxyOwnership?.acquireLease()
            self.stagedNextEpisode = staged
            self.stagedNextEpisodeAuthority = staged == nil ? nil : stagingAuthority
            if let staged {
                ExperimentalMPVPreloadManager.shared.prewarm(url: staged.url, headers: staged.headers,
                    label: "next-S\(nextEpisode.episode.seasonNumber)E\(nextEpisode.episode.episodeNumber)",
                    allowsSharedCloudflareBypass: !staged.usesMangayomiSource)
            }
        }
    }

    func refreshSource(challengeURL: URL? = nil, rejectedCookie: String? = nil, interactive: Bool = false) {
        guard isCurrentOwner, !isRefreshingSource, let context = request.launchContext,
              context.retryCount < 2 else { return }
        isRefreshingSource = true
        let generation = loadGeneration
        setPlaying(false, broadcast: false)
        sourceRefreshTask = Task { [weak self] in
            guard let self else { return }
            let resolver = MacProviderPlaybackResolver(request: self.request.replacingMediaSelectionIntent(self.mediaSelectionIntent), owner: self.owner, authority: self.authority)
            var resolved = await resolver.refresh()
            if interactive, LegacyServiceChallengePolicy.permitsRecovery(for: context), let challengeURL,
               resolved == nil || resolved?.url == self.request.url {
                let solved = await CloudflareBypassManager.shared.refreshSessionAfterChallenge(for: challengeURL,
                    rejectedCookieHeader: rejectedCookie)
                if solved { resolved = await resolver.refresh() ?? resolved }
            }
            guard self.isCurrentOwner, !Task.isCancelled, self.loadGeneration == generation else {
                resolved?.launchContext?.ephemeralProxyOwnership?.invalidate()
                return
            }
            self.isRefreshingSource = false
            guard let resolved, let launch = resolved.launchContext else {
                self.notice = "This source could not refresh its stream. Choose another source to continue."
                return
            }
            let resumed = resolved.replacingResolvedTransport(url: resolved.url, headers: resolved.headers,
                subtitles: resolved.subtitles, subtitleNames: resolved.subtitleNames,
                subtitleHeadersByURL: resolved.subtitleHeadersByURL, launchContext: launch, resumePosition: self.position)
            MacPlaybackCoordinator.shared.present(resumed.replacingMediaSelectionIntent(self.mediaSelectionIntent), engine: self.requestedEngine)
        }
    }

    func retryWithAlternateEngine() {
        guard isCurrentOwner, request.launchContext?.sourceKind != .skyStream else { return }
        guard !PlaybackExternalAudioTransport.requiresMPV(request.url) else {
            notice = PlaybackExternalAudioTransport.mpvReason
            return
        }
        alternateResumePosition = position
        pendingMPVSubtitle = nil
        notice = nil
        updateMediaSelectionIntent()
        persistProgress()
        teardownEngine()
        engine = engine == .mpv ? .avPlayer : .mpv
        startEngine()
    }

    private func scheduleStartupCheck() {
        guard !hasStartedPlayback, startupTask == nil else { return }
        let generation = loadGeneration
        startupTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.loadGeneration == generation { self.startupTask = nil } }
            for attempt in 0..<3 {
                do { try await Task.sleep(nanoseconds: attempt == 0 ? 15_000_000_000 : 20_000_000_000) } catch { return }
                guard self.isCurrentOwner, self.loadGeneration == generation, !self.hasStartedPlayback,
                      self.playbackDesired else { return }
                if self.requestedEngine == .automatic, self.engine == .avPlayer {
                    self.failed("AVPlayer did not begin playback within 15 seconds.", isSourceFailure: false)
                    return
                }
                if self.request.url.isFileURL || self.request.launchContext?.sourceKind == .skyStream {
                    if attempt == 2 { self.failed("The player could not begin playback.", isSourceFailure: false) }
                    continue
                }
                let outcome = await SourceHealthMonitor.shared.probeStream(url: self.request.url, headers: self.request.headers)
                guard self.isCurrentOwner, self.loadGeneration == generation, !Task.isCancelled,
                      !self.hasStartedPlayback, self.playbackDesired else { return }
                switch outcome {
                case .reachable, .slowOrIndeterminate:
                    if attempt == 2 { self.failed("The stream did not begin playback.", isSourceFailure: false) }
                case .networkUnavailable:
                    self.failed("No internet connection is available.", isSourceFailure: false)
                    return
                case .sourceFailed(let reason):
                    self.failed(reason, isSourceFailure: true)
                    return
                }
            }
        }
    }

    func failed(_ message: String, isSourceFailure explicitSourceFailure: Bool? = nil) {
        guard isCurrentOwner, errorMessage == nil else { return }
        if intelCompatibility.isEnabled, engine == .mpv, MacIntelPlaybackPolicy.isLocalRendererFailure(message) {
            failLocalRenderer(message)
            return
        }
        let sourceFailure = explicitSourceFailure ?? (!PlaybackEngineRetryPolicy.shouldTryAlternateEngine(message: message)
            && !message.lowercased().contains("internet") && !message.lowercased().contains("network connection"))
        if requestedEngine == .automatic, engine == .avPlayer, !hasStartedPlayback, !sourceFailure,
           !hasAttemptedFallback, PlaybackEngineRetryPolicy.shouldTryAlternateEngine(message: message) {
            hasAttemptedFallback = true
            teardownEngine()
            engine = .mpv
            startEngine()
            return
        }
        if let context = request.launchContext, !hasStartedPlayback {
            SourceHealthStore.shared.recordPlaybackFailure(sourceId: context.sourceId, sourceName: context.sourceName,
                reason: message, isSourceFailure: sourceFailure)
        }
        errorMessage = message
        setPlaying(false, broadcast: false)
        if let context = request.launchContext, !hasStartedPlayback {
            request.onPlaybackStartupFailure?(PlaybackFailureReport(context: context,
                message: message, isSourceFailure: sourceFailure))
        }
    }

    private func failLocalRenderer(_ message: String) {
        guard isCurrentOwner, errorMessage == nil else { return }
        errorMessage = message
        isPlaying = false
        isReady = false
        isBuffering = false
        teardownEngine()
        updatePlaybackActivity()
    }

    private func tick() {
        guard isCurrentOwner else { stop(); return }
        let previousPosition = position
        if let renderer {
            let snapshot = renderer.diagnosticsSnapshot()
            if Date().timeIntervalSince(lastStateDiagnosticAt) >= 5 {
                lastStateDiagnosticAt = Date()
                Logger.shared.log("MacPlayback event=tick state=\(snapshot.state) ready=\(isReady) paused=\(snapshot.isPaused) position=\(snapshot.currentTime) duration=\(snapshot.duration) video=\(snapshot.videoWidth)x\(snapshot.videoHeight) generation=\(loadGeneration)", type: "PlaybackTrace")
            }
            if snapshot.videoWidth > 0, snapshot.videoHeight > 0 {
                surface.videoPresentationSize = CGSize(width: snapshot.videoWidth, height: snapshot.videoHeight)
            }
            position = snapshot.currentTime.isFinite ? max(0, snapshot.currentTime) : position
            duration = snapshot.duration.isFinite ? max(0, snapshot.duration) : duration
            isPlaying = !snapshot.isPaused && isReady
            isBuffering = snapshot.state == .loading || snapshot.state == .starting
            performanceText = "\(snapshot.videoCodec) · \(snapshot.videoWidth)×\(snapshot.videoHeight) · \(snapshot.hardwareDecoder)\n\(String(format: "%.1f", snapshot.estimatedFramesPerSecond)) fps · \(snapshot.droppedVideoFrameCount) dropped"
        } else if let player {
            let time = player.currentTime().seconds
            let total = player.currentItem?.duration.seconds ?? 0
            if time.isFinite { position = max(0, time) }
            if total.isFinite { duration = max(0, total) }
            isPlaying = player.rate != 0
            isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            if let cues = externalSubtitles[selectedSubtitleID] {
                subtitleText = cues.first(where: { $0.start <= position && position < $0.end })?.text ?? ""
            }
        }
        updatePlaybackActivity()
        let movement = position - previousPosition
        if isReady, isPlaying, movement > 0, movement < 2 { observedPlaybackMovement += movement }
        if isReady, observedPlaybackMovement > 0.25, !hasStartedPlayback {
            hasStartedPlayback = true
            startupTask?.cancel()
            startupTask = nil
            if let context = request.launchContext {
                SourceHealthStore.shared.recordPlaybackSuccess(sourceId: context.sourceId, sourceName: context.sourceName)
            }
        }
        updateSkipSegments()
        updateNextEpisode()
        applyVideoQuality()
        if intelWakeValidationPending, let renderer { recoverIntelPlaybackAfterWake(renderer) }
        if Date().timeIntervalSince(lastPersistedAt) >= 5 {
            persistProgress()
            refreshTracks()
            updateNowPlaying()
        }
        if isPlaying, Date().timeIntervalSince(lastScrobbledAt) >= 30 {
            persistProgress(action: .start)
            lastScrobbledAt = Date()
        }
    }

    private func persistProgress(action: TraktScrobbleAction? = nil) {
        guard ProgressManager.shared.profileMutationAuthorityIsCurrent(authority),
              hasStartedPlayback, duration.isFinite, duration >= 5,
              position.isFinite, position >= 0, position <= duration + 2 else { return }
        lastPersistedAt = Date()
        let value = min(position, duration)
        switch mediaInfo {
        case .movie(let id, let title, let poster, _):
            ProgressManager.shared.updateMovieProgress(movieId: id, title: title, currentTime: value,
                totalDuration: duration, posterURL: poster, owner: owner)
        case .episode(let id, let season, let episode, let title, let poster, let isAnime):
            ProgressManager.shared.updateEpisodeProgress(showId: id, seasonNumber: season, episodeNumber: episode,
                currentTime: value, totalDuration: duration, showTitle: title, showPosterURL: poster,
                playbackContext: playbackContext, isAnime: isAnime, owner: owner)
        case nil:
            if request.url.isFileURL {
                localResumeStore.update(url: request.url, owner: owner, position: value, duration: duration)
            }
        }
        if let mediaInfo, let action {
            TrackerManager.shared.scrobbleTraktPlayback(action, for: mediaInfo, progress: value / duration,
                playbackContext: playbackContext, requiredOwner: owner, progressAuthority: authority)
        }
    }

    private func savedPosition() -> Double {
        switch mediaInfo {
        case .movie(let id, let title, _, _): return ProgressManager.shared.getMovieCurrentTime(movieId: id, title: title)
        case .episode(let id, let season, let episode, _, _, _):
            return ProgressManager.shared.getEpisodeCurrentTime(showId: id, seasonNumber: season, episodeNumber: episode)
        case nil: return request.url.isFileURL ? localResumeStore.currentTime(for: request.url, owner: owner) : 0
        }
    }

    func stop() {
        guard !stopped else { return }
        persistProgress(action: .stop)
        if let mediaInfo {
            ProgressManager.shared.syncTraktProgressOnPlaybackClose(for: mediaInfo,
                playbackContext: playbackContext, played: hasStartedPlayback, owner: owner, progressAuthority: authority)
        }
        ProgressManager.shared.flushPendingSave()
        stopped = true
        updatePlaybackActivity()
        autoplayTask?.cancel()
        nextEpisodeTask?.cancel()
        nextEpisodeStagingTask?.cancel()
        stagedNextEpisode = nil
        stagedNextEpisodeAuthority = nil
        stagedNextEpisodeLease?.release()
        stagedNextEpisodeLease = nil
        sourceRefreshTask?.cancel()
        skipTask?.cancel()
        onlineSubtitleGeneration &+= 1
        onlineSubtitleTask?.cancel()
        automaticSubtitleTask?.cancel()
        subtitleTask?.cancel()
        searchingOnlineSubtitles = false
        subtitleDownloads.forEach { $0.cancel(reportCancellation: true) }
        subtitleDownloads.removeAll()
        pictureInPictureTask?.cancel()
        playbackTimer?.invalidate()
        playbackTimer = nil
        retirePictureInPictureController()
        WatchTogetherCoordinator.shared.detach(self)
        teardownEngine()
        remoteCommandTokens.forEach { $0.0.removeTarget($0.1) }
        remoteCommandTokens.removeAll()
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        observers.removeAll()
        let scopedURLs = securityScopedURLs
        securityScopedURLs.removeAll()
        let retainedDownloads = downloadLeases
        downloadLeases.removeAll()
        let retainedProxy = proxyLease
        proxyLease = nil
        let stopTasks = engineStopTasks + [startupTask, subtitleTask, sourceRefreshTask, nextEpisodeStagingTask,
            nextEpisodeTask, autoplayTask, skipTask, onlineSubtitleTask, automaticSubtitleTask, pictureInPictureTask,
            pictureInPictureRestoreTask].compactMap { $0 }
        engineStopTasks.removeAll()
        let releasesPlaybackLease = hasLease
        hasLease = false
        shutdownTask = Task { @MainActor in
            for task in stopTasks { await task.value }
            scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
            retainedDownloads.forEach { $0.close() }
            retainedProxy?.release()
            if releasesPlaybackLease { MediaStatePlaybackLease.end() }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        onClose?()
    }

    func waitUntilStopped() async {
        await shutdownTask?.value
    }

    private func retirePictureInPictureController() {
        pictureInPictureTask?.cancel()
        pictureInPictureRestoreTask?.cancel()
        pictureInPictureController?.delegate = nil
        pictureInPictureController?.stopPictureInPicture()
        pictureInPictureController?.contentSource = nil
        pictureInPictureController = nil
        surface.setPictureInPictureOwnsLayerGeometry(false)
        isPictureInPicture = false
        isRestoringPictureInPicture = false
        pictureInPictureRestoreAuthority = nil
    }

    private func teardownEngine() {
        if let intelRecoveryTask {
            intelRecoveryTask.cancel()
            engineStopTasks.append(intelRecoveryTask)
        }
        intelRecoveryTask = nil
        intelRecoveryIdentity = nil
        intelWakeValidationPending = false
        intelWakeValidationAttempts = 0
        intelWakeNextValidationAt = 0
        retirePictureInPictureController()
        loadGeneration &+= 1
        if let autoplayTask {
            autoplayTask.cancel()
            engineStopTasks.append(autoplayTask)
        }
        autoplayTask = nil
        if let playbackEndObserver { NotificationCenter.default.removeObserver(playbackEndObserver) }
        playbackEndObserver = nil
        if let startupTask {
            startupTask.cancel()
            engineStopTasks.append(startupTask)
        }
        startupTask = nil
        for task in [subtitleTask, automaticSubtitleTask, onlineSubtitleTask].compactMap({ $0 }) {
            task.cancel()
            engineStopTasks.append(task)
        }
        searchingOnlineSubtitles = false
        lastInlineScale = 0
        subtitleDownloads.forEach { $0.cancel(reportCancellation: true) }
        subtitleDownloads.removeAll()
        statusObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        surface.playerLayer.player = nil
        resourceLoader?.invalidate()
        resourceLoader = nil
        renderer?.onPlaybackEndForGeneration = nil
        renderer?.onStateChange = nil
        renderer?.onError = nil
        renderer?.onInlineHitchDiagnostic = nil
        if intelCompatibility.isEnabled { renderer?.onHardwareDecoderRecoveryObservation = nil }
        if let renderer {
            renderer.onPictureInPictureStopRequested = nil
            renderer.stop()
            engineStopTasks.append(Task { await renderer.waitUntilStopped() })
        }
        renderer = nil
        lastQualitySignature = ""
        if let proxyURL { MPVHeaderProxy.shared.invalidateSession(for: proxyURL) }
        proxyURL = nil
    }

    private func bounded(_ value: Double, range: ClosedRange<Double>) -> Double {
        value.isFinite ? max(range.lowerBound, min(range.upperBound, value)) : range.lowerBound
    }

    private func refreshTracks(applyDefaults: Bool = false) {
        if let renderer {
            let audio = renderer.audioTracks()
            let subtitles = renderer.subtitleTracks()
            audioTracks = audio.map { MacPlaybackTrack(id: $0.id, title: PlaybackAudioTrackLabel.title(
                id: $0.id, title: $0.title, language: $0.language, codec: $0.codec,
                channelLayout: $0.audioChannelLayout, channelCount: $0.audioChannelCount)) }
            subtitleTracks = subtitles.map { MacPlaybackTrack(id: $0.id,
                title: $0.title.isEmpty ? ($0.language.isEmpty ? "Subtitle \($0.id)" : $0.language) : $0.title) }
            if applyDefaults {
                let intent = mediaSelectionIntent
                if let index = PlaybackLanguageSelectionPolicy.preferredIndex(in: audio.map {
                    .init(languageTag: $0.language, displayName: $0.title)
                }, preferredLanguage: intent.preferredAudioLanguage) { renderer.setAudioTrack(id: audio[index].id) }
                if intent.subtitlesEnabled {
                    if let index = PlaybackLanguageSelectionPolicy.preferredIndex(in: subtitles.map {
                        .init(languageTag: $0.language, displayName: $0.title)
                    }, preferredLanguage: intent.preferredSubtitleLanguage) { renderer.setSubtitleTrack(id: subtitles[index].id) }
                } else { renderer.disableSubtitles() }
            }
            selectedAudioID = renderer.currentAudioTrackID()
            selectedSubtitleID = renderer.currentSubtitleTrackID()
        } else if let item = player?.currentItem {
            let audioGroup = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible)
            let subtitleGroup = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible)
            avAudioOptions = audioGroup?.options ?? []
            avSubtitleOptions = subtitleGroup?.options ?? []
            audioTracks = avAudioOptions.enumerated().map { .init(id: $0.offset, title: $0.element.displayName) }
            subtitleTracks = avSubtitleOptions.enumerated().map { .init(id: $0.offset, title: $0.element.displayName) }
                + externalSubtitleNames.sorted(by: { $0.key > $1.key }).map { .init(id: $0.key, title: $0.value) }
            if applyDefaults {
                let generation = loadGeneration
                Task { [weak self, weak item] in
                    guard let self, let item else { return }
                    await AVPlayerMediaSelectionAdapter.apply(self.mediaSelectionIntent, to: item,
                        externalSubtitleSelected: false, currentExternalSubtitleSelection: { [weak self] in
                            (self?.selectedSubtitleID ?? -1) < -1
                        }, isStillCurrent: { [weak self] in
                            self?.isCurrentOwner == true && self?.loadGeneration == generation
                        })
                    guard self.isCurrentOwner, self.loadGeneration == generation else { return }
                    self.refreshTracks()
                }
            }
            if let group = audioGroup, let option = item.currentMediaSelection.selectedMediaOption(in: group) {
                selectedAudioID = avAudioOptions.firstIndex(of: option) ?? -1
            }
            if selectedSubtitleID >= -1, let group = subtitleGroup {
                selectedSubtitleID = item.currentMediaSelection.selectedMediaOption(in: group)
                    .flatMap { avSubtitleOptions.firstIndex(of: $0) } ?? -1
            }
        }
    }

    private func loadAVExternalSubtitles(urls: [String]? = nil, names: [String]? = nil, forceSelection: Bool = false) {
        let urls = urls ?? attachedSubtitleInputs.map(\.url)
        let names: [String]? = names ?? attachedSubtitleInputs.map(\.name)
        let generation = loadGeneration
        let selectionGeneration = subtitleSelectionGeneration
        let previous = subtitleTask
        subtitleTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            var firstAdded: Int?
            var addedIDs: [Int] = []
            for (index, rawURL) in urls.prefix(40).enumerated() {
                guard !Task.isCancelled, self.isCurrentOwner, self.loadGeneration == generation,
                      let url = URL(string: rawURL),
                      ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { continue }
                do {
                    let data: Data
                    if url.isFileURL {
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size > 0, size <= 4 * 1_024 * 1_024 else { continue }
                        data = try await Task.detached(priority: .utility) { try Data(contentsOf: url) }.value
                    } else {
                        let fetch = TVBoundedSubtitleDownload(url: url,
                            headers: self.request.subtitleHeadersByURL?[rawURL] ?? [:])
                        self.subtitleDownloads.append(fetch)
                        data = try await withCheckedThrowingContinuation { continuation in
                            fetch.start { continuation.resume(with: $0) }
                        }
                        self.subtitleDownloads.removeAll { $0 === fetch }
                    }
                    let cues = await Task.detached(priority: .utility) { TVExternalSubtitleParser.parse(data) }.value
                    guard !Task.isCancelled, self.isCurrentOwner, self.loadGeneration == generation,
                          !cues.isEmpty else { continue }
                    let id = self.nextSubtitleID
                    self.nextSubtitleID -= 1
                    self.externalSubtitles[id] = cues
                    self.externalSubtitleURLs[id] = rawURL
                    self.externalSubtitleNames[id] = names.flatMap { $0.indices.contains(index) ? $0[index] : nil }
                        ?? url.deletingPathExtension().lastPathComponent
                    if firstAdded == nil { firstAdded = id }
                    addedIDs.append(id)
                    self.refreshTracks()
                } catch {
                    if !Task.isCancelled { self.notice = "A subtitle could not be loaded." }
                }
            }
            if let firstAdded, self.isCurrentOwner, self.loadGeneration == generation,
               self.subtitleSelectionGeneration == selectionGeneration,
               (forceSelection || self.mediaSelectionIntent.subtitlesEnabled) {
                let preferred = forceSelection ? nil : PlaybackLanguageSelectionPolicy.preferredIndex(in: addedIDs.map {
                    .init(languageTag: nil, displayName: self.externalSubtitleNames[$0] ?? "")
                }, preferredLanguage: self.mediaSelectionIntent.preferredSubtitleLanguage)
                self.selectSubtitle(preferred.map { addedIDs[$0] } ?? firstAdded, userInitiated: forceSelection)
            }
        }
    }

    private func applySubtitleAppearance() {
        let style = PlayerSubtitleAppearance(defaults: defaults)
        renderer?.applySubtitleStyle(MPVMetalSampleBufferSubtitleStyle(
            foregroundColor: style.foregroundColor.cgColor, strokeColor: style.strokeColor.cgColor,
            strokeWidth: style.strokeWidth, fontSize: style.fontSize, isVisible: true,
            position: PlayerSubtitleAppearance.mpvPosition(for: style.verticalOffset),
            verticalMargin: PlayerSubtitleAppearance.mpvMargin(for: style.verticalOffset),
            assOverride: style.overridesASSStyles ? "force" : "no", captionBackground: style.captionBackground,
            delaySeconds: subtitleDelaySeconds))
        player?.currentItem?.textStyleRules = style.avTextStyleRules
    }

    private func updateDisplay() {
        let screen = surface.window?.screen ?? NSScreen.main
        if renderer == nil {
            surface.playerLayer.contentsScale = surface.window?.backingScaleFactor ?? screen?.backingScaleFactor ?? 1
        }
        applyVideoQuality()
    }

    func applyRuntimeSettings() {
        guard isCurrentOwner else { return }
        applySubtitleAppearance()
        MPRemoteCommandCenter.shared().skipForwardCommand.preferredIntervals = [NSNumber(value: seekStep)]
        MPRemoteCommandCenter.shared().skipBackwardCommand.preferredIntervals = [NSNumber(value: seekStep)]
        if let renderer {
            let mode = AudioComfortMode(rawValue: defaults.string(forKey: "audioComfortMode") ?? "") ?? .defaultMode
            let category = AudioComfortContentCategory.resolved(isAnime: request.isAnime, isAnimation: request.isAnimation)
            let scope = defaults.stringArray(forKey: "audioComfortScopeCategories").map {
                Set($0.compactMap(AudioComfortContentCategory.init(rawValue:)))
            } ?? AudioComfortContentCategory.defaultScope
            renderer.setAudioFilterChain(scope.contains(category) ? mode.mpvAudioFilterChain : "")
            _ = renderer.command(["set", "audio-channels", (defaults.object(forKey: "mpvSurroundSoundEnabled") as? Bool ?? true) ? "auto" : "stereo"])
        }
        lastQualitySignature = ""
        applyVideoQuality()
    }

    private func applyVideoQuality() {
        guard isCurrentOwner, let renderer else { return }
        if intelCompatibility.isEnabled {
            applyIntelVideoQuality(renderer)
            return
        }
        let snapshot = renderer.diagnosticsSnapshot()
        let mode = MPVUpscalingMode(rawValue: defaults.string(forKey: "mpvUpscalingMode") ?? "") ?? .defaultMode
        let selected = MPVNeuralUpscaler(rawValue: defaults.string(forKey: "mpvNeuralUpscaler") ?? "") ?? .defaultUpscaler
        let hdrMode = MPVHDRMode(rawValue: defaults.string(forKey: "mpvHDRMode") ?? "") ?? .defaultMode
        let thermal = ProcessInfo.processInfo.thermalState
        let requestedProfile = MPVMetalQualityProfile(rawValue: defaults.string(forKey: "mpvMetalQualityProfile") ?? "") ?? .defaultProfile
        let profile = MacPlaybackVideoQualityPolicy.effectiveProfile(requestedProfile, thermal: thermal)
        let lowHeat = profile == .lowHeat
        let reduced = requestedProfile == .auto && profile != .sharp
        let height = Int(snapshot.videoHeight)
        let width = Int(snapshot.videoWidth)
        let scale = MacPlaybackVideoQualityPolicy.contentsScale(profile: profile, mode: mode,
            source: CGSize(width: width, height: height), bounds: surface.gpuView.bounds.size,
            backingScale: surface.window?.backingScaleFactor ?? 1)
        if lastInlineBounds != surface.gpuView.bounds || abs(lastInlineScale - scale) > 0.001 {
            lastInlineBounds = surface.gpuView.bounds
            lastInlineScale = scale
            renderer.updateInlineLayerLayout(bounds: surface.gpuView.bounds, contentsScale: scale)
        }
        let outputScale: Double? = width > 0 && height > 0 ? min(
            Double(surface.bounds.width * scale) / Double(width),
            Double(surface.bounds.height * scale) / Double(height)) : nil
        let neural = MPVScalerPolicy.inlineNeuralUpscaler(selected: selected, mode: mode,
            isAnimation: request.isAnimation || request.isAnime,
            supportsConvolutional: MPVUserShaderLibrary.supportsConvolutionalUpscalers,
            isLowHeat: lowHeat, isThermallyReduced: reduced, sourceHeight: height, outputScale: outputScale)
        let scalers = MPVScalerPolicy.inlineScalers(mode: mode, neuralActive: neural != .off,
            isPad: false, isLowHeat: lowHeat, sourceHeight: height)
        let shader = MPVUserShaderLibrary.shaderPath(for: neural)
        let transfer = snapshot.videoTransferFunction.lowercased()
        let primaries = snapshot.videoColorPrimaries.lowercased()
        let hdrSource = snapshot.videoSignalPeak > 1 || transfer == "st2084" || transfer == "pq" || transfer == "smpte2084" || transfer == "hlg" || transfer == "arib-std-b67" || primaries == "bt.2020"
        let edr = (surface.window?.screen ?? NSScreen.main)?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
        let hdr = hdrSource && !lowHeat && hdrMode != .sdr && (hdrMode == .hdr || edr > 1)
        let signature = "\(scalers)|\(shader ?? "")|\(hdr)"
        guard signature != lastQualitySignature else { return }
        var statuses: [Int32] = []
        for pair in [("scale", scalers.scale), ("cscale", scalers.cscale), ("dscale", scalers.dscale), ("deband", scalers.deband)] {
            statuses.append(renderer.command(["set", pair.0, pair.1]))
        }
        for property in ["sigmoid-upscaling", "correct-downscaling", "linear-downscaling"] {
            statuses.append(renderer.command(["set", property, scalers.qualityScaling ? "yes" : "no"]))
        }
        statuses.append(renderer.command(["change-list", "glsl-shaders", shader == nil ? "clr" : "set", shader ?? ""]))
        statuses.append(renderer.command(["set", "target-colorspace-hint", hdr ? "yes" : "no"]))
        renderer.inlineLayer.wantsExtendedDynamicRangeContent = hdr
        if statuses.allSatisfy({ $0 >= 0 }) { lastQualitySignature = signature }
    }

    private func applyIntelVideoQuality(_ renderer: MPVGPUPlayerRenderer) {
        let scale = surface.window?.backingScaleFactor ?? 1
        if lastInlineBounds != surface.gpuView.bounds || lastInlineScale != scale {
            lastInlineBounds = surface.gpuView.bounds
            lastInlineScale = scale
            renderer.updateInlineLayerLayout(bounds: surface.gpuView.bounds, contentsScale: scale)
        }
        renderer.inlineLayer.wantsExtendedDynamicRangeContent = false
        switch renderer.diagnosticsSnapshot().state {
        case .idle, .starting, .stopping, .stopped, .failed: return
        case .loading, .ready, .playing, .paused, .pictureInPicture: break
        }
        guard lastQualitySignature != "intel-sdr" else { return }
        let options = MacIntelPlaybackPolicy.videoOptions.merging(MacIntelPlaybackPolicy.audioOptions) { _, value in value }
        let applied = options.sorted(by: { $0.key < $1.key }).map {
            renderer.command(["set", $0.key, $0.value])
        }
        guard applied.allSatisfy({ $0 >= 0 }) else {
            failLocalRenderer("The Intel playback configuration could not be applied.")
            return
        }
        lastQualitySignature = "intel-sdr"
    }

    private func updateSkipSegments() {
        if !didRequestSkipSegments, duration > 5 {
            didRequestSkipSegments = true
            skipTask = Task { [weak self] in
                guard let self else { return }
                let segments = await MacSkipMetadataResolver.resolve(request: self.request, duration: self.duration,
                    defaults: self.defaults, isStillCurrent: { self.isCurrentOwner && !Task.isCancelled })
                guard self.isCurrentOwner, !Task.isCancelled else { return }
                self.skipSegments = segments
            }
        }
        activeSkipSegment = skipSegments.first { $0.startTime <= position && position < $0.endTime }
        skip85SecondsAvailable = defaults.bool(forKey: "skip85sEnabled") &&
            (defaults.bool(forKey: "skip85sAlwaysVisible") || (skipSegments.isEmpty && position < 300))
        if isPlaying, defaults.bool(forKey: "aniSkipAutoSkip"), let activeSkipSegment,
           !skippedSegments.contains(activeSkipSegment.uniqueKey), WatchTogetherCoordinator.shared.sessionRole(for: self) != .follower {
            skipCurrentSegment()
        }
    }

    func skipCurrentSegment() {
        guard let activeSkipSegment else { return }
        skippedSegments.insert(activeSkipSegment.uniqueKey)
        seek(to: activeSkipSegment.endTime)
    }

    private func updatePlaybackActivity() {
        let shouldPreventIdleSleep = isCurrentOwner && isReady && isPlaying && playbackDesired && !systemIsSleeping
        if shouldPreventIdleSleep, playbackActivity == nil {
            playbackActivity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                reason: "Playing video in Eclipse")
        } else if !shouldPreventIdleSleep, let playbackActivity {
            ProcessInfo.processInfo.endActivity(playbackActivity)
            self.playbackActivity = nil
        }
    }

    private func recoverAfterWake() {
        if intelCompatibility.isEnabled {
            guard isCurrentOwner, !systemIsSleeping, let renderer else { return }
            intelWakeValidationPending = true
            intelWakeValidationAttempts = 0
            intelWakeNextValidationAt = 0
            recoverIntelPlaybackAfterWake(renderer)
            return
        }
        guard isCurrentOwner, playbackDesired, !systemIsSleeping, let renderer else { return }
        let generation = loadGeneration
        Task { [weak self, weak renderer] in
            guard let self, let renderer else { return }
            let result = await renderer.validateForegroundVideoAfterSystemResume()
            guard self.isCurrentOwner, self.loadGeneration == generation, !self.isPictureInPicture else { return }
            switch result {
            case .decoderUnavailable, .inlinePresentationTimedOut:
                _ = await renderer.recreateHardwareDecoderAfterSystemResume()
            default: break
            }
            self.updateDisplay()
        }
    }

    private func recoverIntelPlaybackAfterWake(_ renderer: MPVGPUPlayerRenderer) {
        guard intelCompatibility.isEnabled, intelWakeValidationPending, intelRecoveryTask == nil,
              isCurrentOwner, playbackDesired, isReady, !isBuffering, !systemIsSleeping,
              ProcessInfo.processInfo.systemUptime >= intelWakeNextValidationAt,
              let window = surface.window, window.isVisible, !window.isMiniaturized,
              surface.gpuView.bounds.width > 1, surface.gpuView.bounds.height > 1 else { return }
        let snapshot = renderer.diagnosticsSnapshot()
        guard snapshot.videoWidth > 0, snapshot.videoHeight > 0 else {
            intelWakeValidationPending = false
            return
        }
        guard intelWakeValidationAttempts < 4 else {
            failLocalRenderer("Video could not be validated after sleep. Retry playback to continue.")
            return
        }
        intelWakeValidationAttempts += 1
        let generation = loadGeneration
        let identity = UUID()
        intelRecoveryIdentity = identity
        intelRecoveryTask = Task { @MainActor [weak self, weak renderer] in
            guard let self, let renderer else { return }
            var recoveryEpoch: UInt64?
            let watchdog = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
                guard let self, self.isCurrentOwner, self.loadGeneration == generation,
                      self.intelRecoveryIdentity == identity, self.renderer === renderer else { return }
                self.failLocalRenderer("Video recovery timed out after sleep. Retry playback to continue.")
            }
            defer {
                watchdog.cancel()
                if let recoveryEpoch { _ = renderer.finishHardwareDecoderRecoveryAttempt(epoch: recoveryEpoch) }
                if self.intelRecoveryIdentity == identity {
                    renderer.onHardwareDecoderRecoveryObservation = nil
                    self.intelRecoveryTask = nil
                    self.intelRecoveryIdentity = nil
                    self.intelWakeNextValidationAt = ProcessInfo.processInfo.systemUptime + 0.5
                }
            }
            @MainActor func isCurrent() -> Bool {
                !Task.isCancelled && self.isCurrentOwner && self.loadGeneration == generation
                    && self.intelRecoveryIdentity == identity && !self.systemIsSleeping
                    && self.renderer === renderer
            }
            @MainActor func canPresent() -> Bool {
                self.playbackDesired && !self.isBuffering && self.surface.window?.isVisible == true
                    && self.surface.window?.isMiniaturized == false
                    && self.surface.gpuView.bounds.width > 1 && self.surface.gpuView.bounds.height > 1
            }
            let result = await renderer.validateForegroundVideoAfterSystemResume(allowsSoftwareDecoding: true)
            guard isCurrent() else { return }
            guard canPresent() else { self.intelWakeValidationAttempts -= 1; return }
            switch result {
            case .healthy:
                self.intelWakeValidationPending = false
            case .playbackDeferred:
                self.intelWakeValidationAttempts -= 1
            case .decoderUnavailable, .inlinePresentationTimedOut:
                guard renderer.refreshCurrentHardwareDecoder() != "no" else {
                    self.failLocalRenderer("Video did not resume after sleep. Retry playback to continue.")
                    return
                }
                var observedEpoch: UInt64?
                renderer.onHardwareDecoderRecoveryObservation = { observedGeneration, epoch, _ in
                    if observedGeneration == generation { observedEpoch = epoch }
                }
                let recovery = await renderer.recreateHardwareDecoderAfterSystemResume(strategy: .copyOnly)
                switch recovery {
                case .accepted(let epoch):
                    recoveryEpoch = epoch
                    for _ in 0..<20 {
                        guard isCurrent() else { return }
                        guard canPresent() else { self.intelWakeValidationAttempts -= 1; return }
                        if observedEpoch == epoch { break }
                        do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                    }
                    _ = renderer.finishHardwareDecoderRecoveryAttempt(epoch: epoch)
                    recoveryEpoch = nil
                    guard isCurrent() else { return }
                    let validation = await renderer.validateForegroundVideoAfterSystemResume(allowsSoftwareDecoding: true)
                    guard isCurrent() else { return }
                    guard canPresent() else { self.intelWakeValidationAttempts -= 1; return }
                    switch validation {
                    case .healthy:
                        self.intelWakeValidationPending = false
                    case .playbackDeferred:
                        self.intelWakeValidationAttempts -= 1
                    case .decoderUnavailable, .inlinePresentationTimedOut:
                        self.failLocalRenderer("Video did not resume after sleep. Retry playback to continue.")
                    default: break
                    }
                case .commandFailed, .unavailable:
                    guard isCurrent() else { return }
                    self.failLocalRenderer("Video recovery failed after sleep. Retry playback to continue.")
                case .transitionBusy, .cancelled:
                    break
                }
            default: break
            }
            if isCurrent() { self.updateDisplay() }
        }
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        func install(_ command: MPRemoteCommand, action: @escaping @MainActor (MacPlaybackSession) -> Void) {
            command.isEnabled = true
            let token = command.addTarget { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isCurrentOwner else { return }
                    action(self)
                }
                return .success
            }
            remoteCommandTokens.append((command, token))
        }
        install(center.playCommand) { $0.setPlaying(true) }
        install(center.pauseCommand) { $0.setPlaying(false) }
        install(center.togglePlayPauseCommand) { $0.togglePlayback() }
        install(center.skipForwardCommand) { $0.seek(by: $0.seekStep) }
        install(center.skipBackwardCommand) { $0.seek(by: -$0.seekStep) }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: seekStep)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: seekStep)]
        let token = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
        remoteCommandTokens.append((center.changePlaybackPositionCommand, token))
    }

    private func updateNowPlaying() {
        guard !stopped else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: request.title.isEmpty ? request.url.deletingPathExtension().lastPathComponent : request.title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0
        ]
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    func togglePictureInPicture() {
        guard supportsPictureInPicture else { return }
        guard isCurrentOwner else { return }
        autoplayTask?.cancel()
        if isPictureInPicture {
            guard beginPictureInPictureRestoration() else { stop(); return }
            pictureInPictureController?.stopPictureInPicture()
            return
        }
        guard defaults.object(forKey: "mpvPictureInPictureEnabled") as? Bool ?? true,
              pictureInPictureTask == nil, !isRestoringPictureInPicture,
              AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let generation = loadGeneration
        pictureInPictureTask = Task { [weak self] in
            guard let self else { return }
            defer { self.pictureInPictureTask = nil }
            do {
                if let renderer = self.renderer {
                    try await renderer.preparePictureInPicture()
                    guard !Task.isCancelled, self.isCurrentOwner, self.loadGeneration == generation else { return }
                    _ = renderer.prepareForPictureInPictureStart()
                }
                let controller: AVPictureInPictureController
                if let existing = self.pictureInPictureController {
                    controller = existing
                } else {
                    let source: AVPictureInPictureController.ContentSource
                    if let renderer = self.renderer {
                        source = .init(sampleBufferDisplayLayer: renderer.pictureInPictureDisplayLayer, playbackDelegate: self)
                    } else {
                        source = .init(playerLayer: self.surface.playerLayer)
                    }
                    controller = AVPictureInPictureController(contentSource: source)
                    controller.delegate = self
                    self.pictureInPictureController = controller
                }
                let deadline = Date().addingTimeInterval(2)
                while !controller.isPictureInPicturePossible, Date() < deadline {
                    try await Task.sleep(nanoseconds: 50_000_000)
                    guard self.isCurrentOwner, self.loadGeneration == generation else { return }
                }
                guard self.isCurrentOwner, self.loadGeneration == generation,
                      controller.isPictureInPicturePossible else {
                    self.notice = "Picture in Picture is not ready yet."
                    return
                }
                self.isRestoringPictureInPicture = false
                self.pictureInPictureRestoreAuthority = nil
                self.logPictureInPicture("start-request")
                self.surface.setPictureInPictureOwnsLayerGeometry(true)
                controller.startPictureInPicture()
            } catch {
                if !Task.isCancelled { self.notice = "Picture in Picture could not start." }
            }
        }
    }

    private func logPictureInPicture(_ event: String) {
        guard let renderer else { return }
        let snapshot = renderer.diagnosticsSnapshot()
        let layer = renderer.pictureInPictureDisplayLayer
        Logger.shared.log("MacPiP event=\(event) backend=\(String(describing: snapshot.selectedPictureInPictureBackend)) enqueued=\(snapshot.pictureInPictureEnqueuedFrameCount) layerStatus=\(layer.status.rawValue) layerBounds=\(layer.bounds) layerOpacity=\(layer.opacity) sourceBounds=\(surface.bounds) state=\(snapshot.state) position=\(snapshot.currentTime) duration=\(snapshot.duration) ready=\(isReady)", type: "PlaybackTrace")
    }

    private func beginPictureInPictureRestoration() -> Bool {
        let restoration = pictureInPictureRestoreAuthority ?? MacPlaybackRestorationAuthority(
            playbackGeneration: loadGeneration, windowGeneration: MacLaunchProfileAccess.windowGeneration)
        guard restorationIsCurrent(restoration) else { return false }
        if pictureInPictureRestoreAuthority == nil {
            pictureInPictureRestoreAuthority = restoration
            isRestoringPictureInPicture = true
            onRestoreMainWindow?()
        }
        return restorationIsCurrent(restoration)
    }

    private func restorationIsCurrent(_ restoration: MacPlaybackRestorationAuthority) -> Bool {
        restoration.isCurrent(playbackGeneration: loadGeneration,
            windowGeneration: MacLaunchProfileAccess.windowGeneration, ownerIsCurrent: isCurrentOwner,
            applicationIsTerminating: MacLaunchProfileAccess.isTerminating,
            requiresUnlock: MacLaunchProfileAccess.requiresUnlock)
    }

}

extension MacPlaybackSession: AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard MacPlaybackLifecyclePolicy.acceptsPictureInPictureCallback(
            controllerIsCurrent: self.pictureInPictureController === pictureInPictureController,
            ownerIsCurrent: isCurrentOwner) else { pictureInPictureController.stopPictureInPicture(); return }
        isPictureInPicture = true
        renderer?.beginPictureInPicture()
        logPictureInPicture("started")
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error) {
        guard isCurrentOwner, self.pictureInPictureController === pictureInPictureController else { return }
        renderer?.endPictureInPicture()
        surface.setPictureInPictureOwnsLayerGeometry(false)
        isPictureInPicture = false
        notice = "Picture in Picture could not start."
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard MacPlaybackLifecyclePolicy.acceptsPictureInPictureCallback(
            controllerIsCurrent: self.pictureInPictureController === pictureInPictureController,
            ownerIsCurrent: isCurrentOwner) else { completionHandler(false); return }
        completionHandler(beginPictureInPictureRestoration())
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard isCurrentOwner, self.pictureInPictureController === pictureInPictureController else { return }
        isPictureInPicture = false
        guard isRestoringPictureInPicture, let restoration = pictureInPictureRestoreAuthority,
              restorationIsCurrent(restoration) else { stop(); return }
        let generation = loadGeneration
        pictureInPictureRestoreTask = Task { [weak self] in
            guard let self, self.isCurrentOwner, self.loadGeneration == generation else { return }
            guard self.restorationIsCurrent(restoration) else { self.stop(); return }
            if let renderer = self.renderer { _ = await renderer.endPictureInPictureAndWait(restoringInlinePlayback: true) }
            guard !Task.isCancelled, self.isCurrentOwner, self.loadGeneration == generation else { return }
            guard self.restorationIsCurrent(restoration) else { self.stop(); return }
            self.surface.setPictureInPictureOwnsLayerGeometry(false)
            self.isRestoringPictureInPicture = false
            self.pictureInPictureRestoreAuthority = nil
            self.pictureInPictureRestoreTask = nil
            self.updateDisplay()
        }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        guard self.pictureInPictureController === pictureInPictureController else { return }
        setPlaying(playing)
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: CMTime(seconds: max(duration, 1), preferredTimescale: 600))
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { !isPlaying }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        guard isCurrentOwner, self.pictureInPictureController === pictureInPictureController else { return }
        renderer?.updatePictureInPictureRenderSize(CGSize(width: Int(newRenderSize.width), height: Int(newRenderSize.height)))
        logPictureInPicture("render-size-\(newRenderSize.width)x\(newRenderSize.height)")
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime, completion: @escaping () -> Void) {
        if self.pictureInPictureController === pictureInPictureController { seek(by: skipInterval.seconds) }
        completion()
    }
}

extension MacPlaybackSession: WatchTogetherPlaybackDelegate {
    var watchTogetherMediaDescriptor: WatchTogetherMediaDescriptor? {
        switch mediaInfo {
        case .movie(let id, let title, _, let isAnime):
            return .init(tmdbID: id, mediaType: "movie", seasonNumber: nil, episodeNumber: nil,
                isAnime: isAnime, title: title)
        case .episode(let id, let season, let episode, let title, _, let isAnime):
            return .init(tmdbID: id, mediaType: "tv",
                seasonNumber: playbackContext?.resolvedTMDBSeasonNumber ?? request.originalTMDBSeasonNumber ?? season,
                episodeNumber: playbackContext?.resolvedTMDBEpisodeNumber ?? request.originalTMDBEpisodeNumber ?? episode,
                playbackContext: playbackContext, isAnime: isAnime, title: title)
        case nil: return nil
        }
    }
    var watchTogetherPosition: Double { position }
    var watchTogetherDuration: Double { duration }
    var watchTogetherIsPlaying: Bool { isPlaying }
    var watchTogetherPlaybackRate: Double { speed }
    var watchTogetherIsReady: Bool { isReady && isCurrentOwner }
    var watchTogetherIsStalled: Bool { !isReady || isBuffering }

    func watchTogetherAdopt(media: WatchTogetherMediaDescriptor) {
        guard watchTogetherMediaDescriptor?.isSameLogicalMedia(as: media) == true else { return }
        if playbackContext?.hasAnimeMediaId != true { playbackContext = media.playbackContext ?? playbackContext }
    }

    func watchTogetherApply(state: WatchTogetherSharedState, shouldSeek: Bool) {
        guard isCurrentOwner else { return }
        if shouldSeek { seek(to: state.projectedPosition(), broadcast: false) }
        setSpeed(state.playbackRate, broadcast: false)
        setPlaying(state.isPlaying && state.awaitsReadiness != true, broadcast: false)
    }

    func watchTogetherPrepareForMediaTransition(to media: WatchTogetherMediaDescriptor) {
        persistProgress()
        stop()
    }

    func watchTogetherConnectionDidChange(_ state: WatchTogetherConnectionState) {
        if case .active(let count, let matches, _) = state, matches {
            notice = "Watch Together connected · \(count) participants"
        }
    }

    func watchTogetherShowNotice(_ message: String) { notice = message }
}

struct MacPlaybackTrack: Identifiable, Equatable {
    let id: Int
    let title: String
}
#endif
