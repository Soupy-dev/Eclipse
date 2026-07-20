import AVFoundation
import AVKit
import MediaPlayer
import UIKit

/// One construction and presentation seam for MPV and AVPlayer. Existing launch sites can move to
/// this coordinator incrementally; the request remains identical if Automatic falls back before
/// MPV's first frame.
@MainActor
final class PlaybackCoordinator {
    static let shared = PlaybackCoordinator()

    private var activeHandoffs: [ObjectIdentifier: UUID] = [:]
    // Retain the host while its player is alive. SwiftUI can otherwise release a transient
    // presentation controller before an in-player Services/episode selection finishes resolving.
    // The weak key removes the entry (and releases the host) as soon as the player is dismissed.
    private let presentationHosts = NSMapTable<UIViewController, UIViewController>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )

    private init() {}

    func makeViewController(
        for request: PlaybackRequest,
        engine: PlaybackEngine = .selected
    ) -> UIViewController {
#if os(tvOS)
        return TVPlaybackViewController(request: request, requestedEngine: engine)
#else
        let deviceFamily = PlaybackDeviceFamily.current
        let plan = PlaybackLaunchPlan.make(
            selection: engine,
            deviceFamily: deviceFamily
        )
        if deviceFamily == .pad,
           plan.primary == .avPlayer,
           plan.preStartFallback == .mpv,
           Self.isKnownAVPlayerIncompatibleContainer(request.url) {
            Logger.shared.log(
                "PlaybackCoordinator: iPad Automatic bypassing AVPlayer for .\(request.url.pathExtension.lowercased()) and starting Molten directly",
                type: "Player"
            )
            return makeIOSMPVPlayer(for: request)
        }
        switch plan.primary {
        case .avPlayer:
            return makeIOSAVPlayer(for: request, preStartFallback: plan.preStartFallback)
        case .mpv:
            return makeIOSMPVPlayer(for: request, preStartFallback: plan.preStartFallback)
        case .automatic:
            preconditionFailure("Automatic must resolve to a concrete playback engine")
        }
#endif
    }

    func present(
        _ request: PlaybackRequest,
        from presenter: UIViewController,
        engine: PlaybackEngine = .selected,
        animated: Bool = true
    ) {
        let controller = makeViewController(for: request, engine: engine)
        controller.modalPresentationStyle = .fullScreen
        presentationHosts.setObject(presenter, forKey: controller)
        presenter.present(controller, animated: animated) {
#if !os(tvOS)
            (controller as? NormalPlayer)?.playAtDefaultSpeed()
#endif
        }
    }

#if !os(tvOS)
    private func makeIOSMPVPlayer(
        for request: PlaybackRequest,
        preStartFallback: PlaybackEngine? = nil,
        isEngineFallback: Bool = false
    ) -> UIViewController {
        let controller = PlayerViewController(
            url: request.url,
            preset: request.preset,
            headers: request.headers,
            subtitles: request.subtitles.isEmpty ? nil : request.subtitles,
            subtitleNames: request.subtitleNames,
            subtitleHeadersByURL: request.subtitleHeadersByURL,
            mediaSelectionIntent: request.mediaSelectionIntent,
            mediaInfo: request.mediaInfo,
            imdbId: request.imdbID
        )
        controller.isAnimeHint = request.isAnime
        controller.isAnimationContentHint = request.isAnimation
        controller.playerTitleOverride = request.title
        controller.servicesSelectionContext = PlayerServicesSelectionContext(request: request)
        controller.originalTMDBSeasonNumber = request.originalTMDBSeasonNumber
        controller.originalTMDBEpisodeNumber = request.originalTMDBEpisodeNumber
        controller.episodePlaybackContext = request.episodePlaybackContext
        controller.playbackLaunchContext = request.launchContext ?? Self.syntheticLaunchContext(for: request)
        controller.onRequestNextEpisode = request.onRequestNextEpisode
        controller.onRequestResolvedNextEpisode = request.onRequestResolvedNextEpisode
        controller.localNextEpisodeFallback = request.localNextEpisodeFallback
        controller.onPlaybackStartupFailure = request.onPlaybackStartupFailure
#if os(iOS) && canImport(GoogleCast)
        controller.activePlaybackRequest = request
#endif
        controller.isCoordinatorEngineFallback = isEngineFallback
        controller.forceHeaderProxyForStartup = isEngineFallback
        if preStartFallback == .avPlayer {
            controller.onAutomaticPlaybackFallback = { [weak controller] report in
                guard let controller else {
                    request.onPlaybackStartupFailure?(report)
                    return
                }
                self.replace(
                    controller,
                    after: report,
                    with: .avPlayer,
                    request: request
                )
            }
        }
        controller.modalPresentationStyle = .fullScreen
        return controller
    }

    private func makeIOSAVPlayer(
        for request: PlaybackRequest,
        preStartFallback: PlaybackEngine? = nil,
        isEngineFallback: Bool = false
    ) -> UIViewController {
        let controller = NormalPlayer()
        controller.configure(with: request)
        controller.isCoordinatorEngineFallback = isEngineFallback
        if preStartFallback == .mpv {
            armMoltenFallback(for: controller, request: request)
        }
        controller.modalPresentationStyle = .fullScreen
        return controller
    }

    /// Rebinds AVPlayer's one-shot fallback to the exact request currently loaded in the
    /// controller. In-place source and episode changes must call this; retaining the closure made
    /// during initial presentation would reopen the original URL or episode in Molten.
    func armMoltenFallback(for controller: NormalPlayer, request: PlaybackRequest) {
        controller.automaticallyFallsBackToMolten = true
        controller.onAutomaticPlaybackFallback = { [weak controller] report in
            guard let controller else {
                request.onPlaybackStartupFailure?(report)
                return
            }
            self.replace(
                controller,
                after: report,
                with: .mpv,
                request: request
            )
        }
    }

    func shouldHandOffAVPlayerDirectly(for request: PlaybackRequest) -> Bool {
        Self.isKnownAVPlayerIncompatibleContainer(request.url)
    }

    /// Uses the normal coordinator handoff without first installing a container AVFoundation is
    /// known not to support. The request is passed through unchanged, including headers, subtitle
    /// metadata, episode identity, and playback context.
    func handOffAVPlayerToMolten(
        _ controller: NormalPlayer,
        request: PlaybackRequest,
        reason: String
    ) {
        controller.beginPlaybackEngineHandoff()
        let report = PlaybackFailureReport(
            context: request.launchContext ?? Self.syntheticLaunchContext(for: request),
            message: reason,
            isSourceFailure: false
        )
        replace(
            controller,
            after: report,
            with: .mpv,
            request: request
        )
    }

    private func replace(
        _ controller: UIViewController,
        after report: PlaybackFailureReport,
        with fallbackEngine: PlaybackEngine,
        request: PlaybackRequest,
        presentationRetryCount: Int = 0,
        handoffID suppliedHandoffID: UUID? = nil,
        handoffWasEverVisible: Bool = false
    ) {
        let controllerID = ObjectIdentifier(controller)
        let wasEverVisible = handoffWasEverVisible || Self.hasBeenVisible(controller)
        let handoffID: UUID
        if let suppliedHandoffID {
            guard activeHandoffs[controllerID] == suppliedHandoffID else { return }
            handoffID = suppliedHandoffID
        } else {
            handoffID = UUID()
            activeHandoffs[controllerID] = handoffID
        }

        guard !controller.isBeingDismissed else {
            activeHandoffs.removeValue(forKey: controllerID)
            return
        }

        if controller.isBeingPresented {
            if let transitionCoordinator = controller.transitionCoordinator {
                let registered = transitionCoordinator.animate(alongsideTransition: nil) { _ in
                    // UIKit can still report `isBeingPresented` during the transition-completion
                    // callback itself. Cross one run-loop boundary before evaluating final state.
                    DispatchQueue.main.async {
                        self.replace(
                            controller,
                            after: report,
                            with: fallbackEngine,
                            request: request,
                            presentationRetryCount: presentationRetryCount + 1,
                            handoffID: handoffID,
                            handoffWasEverVisible: wasEverVisible
                        )
                    }
                }
                if registered { return }
            }
            guard presentationRetryCount < 40 else {
                failHandoff(
                    controller,
                    controllerID: controllerID,
                    handoffID: handoffID,
                    report: report,
                    request: request,
                    wasEverVisible: wasEverVisible
                )
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.replace(
                    controller,
                    after: report,
                    with: fallbackEngine,
                    request: request,
                    presentationRetryCount: presentationRetryCount + 1,
                    handoffID: handoffID,
                    handoffWasEverVisible: wasEverVisible
                )
            }
            return
        }

        // A runtime failure can be reported while a source picker or failure alert is still
        // attached to the player. Dismissing the player at that moment only dismisses its child,
        // so drain the child first and retry the same, generation-guarded handoff.
        if let child = controller.presentedViewController {
            if !child.isBeingDismissed {
                child.dismiss(animated: false)
            }
            guard presentationRetryCount < 120 else {
                failHandoff(
                    controller,
                    controllerID: controllerID,
                    handoffID: handoffID,
                    report: report,
                    request: request,
                    wasEverVisible: wasEverVisible
                )
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.replace(
                    controller,
                    after: report,
                    with: fallbackEngine,
                    request: request,
                    presentationRetryCount: presentationRetryCount + 1,
                    handoffID: handoffID,
                    handoffWasEverVisible: wasEverVisible
                )
            }
            return
        }

        guard let presenter = controller.presentingViewController else {
            if presentationRetryCount < 40 {
                // An item's initial KVO failure can arrive while UIKit is still connecting the
                // full-screen presentation relationship. Give that relationship one run-loop
                // turn before deciding there is no safe presenter.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.replace(
                        controller,
                        after: report,
                        with: fallbackEngine,
                        request: request,
                        presentationRetryCount: presentationRetryCount + 1,
                        handoffID: handoffID,
                        handoffWasEverVisible: wasEverVisible
                    )
                }
                return
            }
            if let presentationHost = presentationHosts.object(forKey: controller),
               !presentationHost.isBeingDismissed,
               presentationHost.viewIfLoaded?.window != nil,
               presentationHost.presentedViewController == nil,
               let replacement = makeReplacementController(
                    for: fallbackEngine,
                    request: request
               ) {
                activeHandoffs.removeValue(forKey: controllerID)
                presentationHosts.removeObject(forKey: controller)
                replacement.modalPresentationStyle = .fullScreen
                presentationHosts.setObject(presentationHost, forKey: replacement)
                Logger.shared.log(
                    "PlaybackCoordinator: primary player never attached; presenting the same request with \(fallbackEngine.displayName)",
                    type: "Player"
                )
                presentationHost.present(replacement, animated: false) {
                    (replacement as? NormalPlayer)?.playAtDefaultSpeed()
                }
                return
            }
            failHandoff(
                controller,
                controllerID: controllerID,
                handoffID: handoffID,
                report: report,
                request: request,
                wasEverVisible: wasEverVisible
            )
            return
        }
        guard !presenter.isBeingDismissed,
              presenter.viewIfLoaded?.window != nil,
              presenter.presentedViewController === controller else {
            failHandoff(
                controller,
                controllerID: controllerID,
                handoffID: handoffID,
                report: report,
                request: request,
                wasEverVisible: wasEverVisible
            )
            return
        }
        guard let replacement = makeReplacementController(
            for: fallbackEngine,
            request: request
        ) else {
            activeHandoffs.removeValue(forKey: controllerID)
            request.onPlaybackStartupFailure?(report)
            return
        }
        replacement.modalPresentationStyle = .fullScreen
        presentationHosts.setObject(presenter, forKey: replacement)
        Logger.shared.log(
            "PlaybackCoordinator: \(type(of: controller)) failed before playback; retrying the same request with \(fallbackEngine.displayName)",
            type: "Player"
        )
        controller.dismiss(animated: false) {
            guard self.activeHandoffs[controllerID] == handoffID else { return }
            self.activeHandoffs.removeValue(forKey: controllerID)
            self.presentationHosts.removeObject(forKey: controller)
            guard !presenter.isBeingDismissed,
                  presenter.viewIfLoaded?.window != nil,
                  presenter.presentedViewController == nil else {
                // A newer presentation owns this presenter now. Do not let a stale fallback cover
                // it, and do not feed its failure into the newer playback request.
                return
            }
            presenter.present(replacement, animated: false) {
                (replacement as? NormalPlayer)?.playAtDefaultSpeed()
            }
        }
    }

    private func makeReplacementController(
        for fallbackEngine: PlaybackEngine,
        request: PlaybackRequest
    ) -> UIViewController? {
        switch fallbackEngine {
        case .mpv:
            return makeIOSMPVPlayer(for: request, isEngineFallback: true)
        case .avPlayer:
            return makeIOSAVPlayer(for: request, isEngineFallback: true)
        case .automatic:
            return nil
        }
    }

    private func failHandoff(
        _ controller: UIViewController,
        controllerID: ObjectIdentifier,
        handoffID: UUID,
        report: PlaybackFailureReport,
        request: PlaybackRequest,
        wasEverVisible: Bool
    ) {
        guard activeHandoffs[controllerID] == handoffID else { return }
        activeHandoffs.removeValue(forKey: controllerID)
        presentationHosts.removeObject(forKey: controller)
        guard !controller.isBeingDismissed else { return }
        guard controller.viewIfLoaded?.window != nil else {
            // A completed user/system dismissal is no longer `isBeingDismissed`. Only return
            // control to source selection when this controller genuinely never reached a window;
            // otherwise a deliberate Close could reopen playback behind the user's back.
            if !wasEverVisible, !Self.hasBeenVisible(controller) {
                request.onPlaybackStartupFailure?(report)
            }
            return
        }
        if let player = controller as? PlayerViewController {
            player.playbackEngineHandoffDidFail(report)
        } else if let player = controller as? NormalPlayer {
            player.playbackEngineHandoffDidFail(report)
        } else {
            request.onPlaybackStartupFailure?(report)
        }
    }

    private static func hasBeenVisible(_ controller: UIViewController) -> Bool {
        if controller.viewIfLoaded?.window != nil { return true }
        if let player = controller as? PlayerViewController {
            return player.playbackHandoffHasAppeared
        }
        if let player = controller as? NormalPlayer {
            return player.playbackHandoffHasAppeared
        }
        return false
    }

    private static func syntheticLaunchContext(for request: PlaybackRequest) -> PlaybackLaunchContext {
        PlaybackLaunchContext(
            sourceId: request.url.isFileURL ? "local-playback" : "direct-playback",
            sourceName: request.url.isFileURL ? "Downloaded Media" : "Direct Stream",
            sourceKind: .service,
            autoMode: false,
            streamURL: request.url.absoluteString,
            headers: request.headers,
            subtitles: request.subtitles,
            subtitleNames: request.subtitleNames,
            subtitleHeadersByURL: request.subtitleHeadersByURL,
            retryCount: 0
        )
    }

    /// AVFoundation does not support these container families. Avoid briefly showing Apple's
    /// terminal error UI when iPad Automatic can choose Molten deterministically before launch.
    /// Unknown extensions still try AVPlayer and retain the normal one-shot fallback.
    private static func isKnownAVPlayerIncompatibleContainer(_ url: URL) -> Bool {
        ["avi", "flv", "mkv", "mpd", "webm", "wmv"].contains(url.pathExtension.lowercased())
    }
#endif
}

#if os(tvOS)
/// Container controller used so AVPlayer is composed as Apple's unmodified
/// `AVPlayerViewController`, while MPV remains a dedicated remote-native controller.
@MainActor
final class TVPlaybackViewController: UIViewController {
    private let request: PlaybackRequest
    private let requestedEngine: PlaybackEngine
    private var activeChild: UIViewController?
    private var mpvController: TVMPVPlayerViewController?
    private var avPlayerController: AVPlayerViewController?
    private var avPlayerResourceLoader: AVPlayerResourceLoader?
    private var avExternalSubtitleController: TVAVPlayerExternalSubtitleController?
    private var avMediaSelectionTask: Task<Void, Never>?
    private var avPlayerStatusObservation: NSKeyValueObservation?
    private var avPlayerTimeControlObservation: NSKeyValueObservation?
    private var avPlayerTimeObserver: Any?
    private var avPlayerEndToken: NSObjectProtocol?
    private var hasAttemptedAutomaticFallback = false
    private var hasBegunPlaybackLease = false
    private var hasEndedPlaybackLease = false
    private var hasFinalizedPlayback = false
    private var playbackDidStart = false
    private var currentPosition: Double = 0
    private var currentDuration: Double = 0
    private var lastProgressPersistAt: CFTimeInterval = 0
    private var lastScrobbleAt: CFTimeInterval = 0
    private var nextEpisodeState: TVNextEpisodeState = .watching
    private var nextEpisodeResolutionTask: Task<Void, Never>?
    private var naturalEndResolutionTimeoutTask: Task<Void, Never>?
    private var nextEpisodeResolution: NextEpisodeResolution?
    private var didReachNaturalPlaybackEnd = false
    private var wasPlayingBeforeNextEpisodePrompt = false
    private var isTransitioningToNextEpisode = false
    private var hasPreparedAVPlayerItem = false
    private var skipSegmentFetchTask: Task<Void, Never>?
    private var didRequestSkipSegments = false
    private var skipSegments: [SkipSegment] = []
    private var activeSkipSegment: SkipSegment?
    private var autoSkippedSegmentKeys = Set<String>()

    private let skipSegmentButton = UIButton(type: .system)
    private let nextEpisodeOverlay = UIView()
    private let nextEpisodeCard = UIView()
    private let nextEpisodeTitleLabel = UILabel()
    private let nextEpisodeMessageLabel = UILabel()
    private let playNextEpisodeButton = UIButton(type: .system)
    private let keepWatchingButton = UIButton(type: .system)
    private lazy var nextEpisodeBackGesture: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(handleNextEpisodeBack))
        gesture.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        gesture.isEnabled = false
        return gesture
    }()

    init(request: PlaybackRequest, requestedEngine: PlaybackEngine) {
        self.request = request
        self.requestedEngine = requestedEngine
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSkipSegmentButton()
        configureNextEpisodeOverlay()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCurrentUserBoundary),
            name: .mediaStateWillChangeCurrentUser,
            object: nil
        )
        resolveNextEpisodeIfNeeded()
        switch requestedEngine {
        case .avPlayer:
            startAVPlayer(reason: "selected", selectionIntent: request.mediaSelectionIntent)
        case .mpv:
            startMPV(allowsAutomaticFallback: false)
        case .automatic:
            startMPV(allowsAutomaticFallback: true)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(
            self,
            name: .mediaStateWillChangeCurrentUser,
            object: nil
        )
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if !nextEpisodeOverlay.isHidden {
            return [playNextEpisodeButton]
        }
        if let activeChild {
            return [activeChild]
        }
        return super.preferredFocusEnvironments
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || navigationController?.isBeingDismissed == true || view.window == nil else { return }
        finalizePlaybackIfNeeded()
    }

    private func startMPV(allowsAutomaticFallback: Bool) {
        guard MPVTVRenderer.isAvailable else {
            if allowsAutomaticFallback {
                fallbackToAVPlayer(reason: "The MPV Metal renderer is unavailable.")
            } else {
                showTerminalError("The MPV Metal renderer is unavailable on this Apple TV.")
            }
            return
        }

        let controller = TVMPVPlayerViewController(request: request)
        controller.onFirstFrame = { [weak self] in
            guard let self else { return }
            self.playbackDidStart = true
            self.beginPlaybackLeaseIfNeeded()
        }
        controller.onProgress = { [weak self] position, duration, isPlaying in
            self?.handlePlaybackProgress(position: position, duration: duration, isPlaying: isPlaying)
        }
        controller.onStartupFailure = { [weak self] message in
            guard let self else { return }
            let decision = PlaybackFallbackPolicy.decision(
                requestedEngine: self.requestedEngine,
                playbackDidStart: self.playbackDidStart,
                hasAttemptedAutomaticFallback: self.hasAttemptedAutomaticFallback
            )
            if allowsAutomaticFallback, decision == .retryAutomaticallyWithAVPlayer {
                self.fallbackToAVPlayer(reason: message)
            } else if decision == .offerManualAVPlayerRetry {
                self.showMPVFailure(message)
            } else {
                self.showTerminalError(message)
            }
        }
        controller.onRetryWithAVPlayer = { [weak self] message in
            self?.fallbackToAVPlayer(reason: message)
        }
        controller.onDismiss = { [weak self] in self?.dismissPlayback() }
        mpvController = controller
        install(controller, animated: false)
        controller.startPlayback()
    }

    private func fallbackToAVPlayer(reason: String) {
        guard requestedEngine == .automatic || mpvController != nil else { return }
        if requestedEngine == .automatic {
            guard !hasAttemptedAutomaticFallback else {
                showTerminalError(reason)
                return
            }
            hasAttemptedAutomaticFallback = true
        }
        let selectionIntent = mpvController?.avPlayerFallbackSelectionIntent()
            ?? request.mediaSelectionIntent
        mpvController?.stopPlayback()
        mpvController = nil
        Logger.shared.log("[TVPlayback] retrying with AVPlayer reason=\(reason)", type: "Player")
        startAVPlayer(reason: reason, selectionIntent: selectionIntent)
    }

    private func startAVPlayer(
        reason: String,
        selectionIntent: PlaybackMediaSelectionIntent
    ) {
        avPlayerStatusObservation?.invalidate()
        avPlayerStatusObservation = nil
        avPlayerTimeControlObservation?.invalidate()
        avPlayerTimeControlObservation = nil
        removeAVPlayerTimeObserver()
        avMediaSelectionTask?.cancel()
        avMediaSelectionTask = nil
        avExternalSubtitleController?.invalidate()
        avExternalSubtitleController = nil
        hasPreparedAVPlayerItem = false
        if let avPlayerEndToken {
            NotificationCenter.default.removeObserver(avPlayerEndToken)
            self.avPlayerEndToken = nil
        }
        avPlayerResourceLoader?.invalidate()
        let backedItem = AVPlayerResourceLoader.makeItem(url: request.url, headers: request.headers)
        avPlayerResourceLoader = backedItem.loader
        let item = backedItem.item
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        player.defaultRate = resolvedAVPlayerRate()

        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        let pictureInPictureEnabled = UserDefaults.standard.object(
            forKey: "mpvPictureInPictureEnabled"
        ) as? Bool ?? true
        controller.allowsPictureInPicturePlayback = pictureInPictureEnabled
            && AVPictureInPictureController.isPictureInPictureSupported()
        controller.appliesPreferredDisplayCriteriaAutomatically = true
        let seekInterval = UserDefaults.standard.double(forKey: "playerDoubleTapSeekSeconds")
        let normalizedSeekInterval = seekInterval > 0 ? min(max(seekInterval, 5), 60) : 10
        let remoteCommands = MPRemoteCommandCenter.shared()
        remoteCommands.skipForwardCommand.preferredIntervals = [NSNumber(value: normalizedSeekInterval)]
        remoteCommands.skipBackwardCommand.preferredIntervals = [NSNumber(value: normalizedSeekInterval)]
        let externalSubtitles = TVAVPlayerExternalSubtitleController(
            request: request,
            selectionIntent: selectionIntent,
            playerViewController: controller
        )
        externalSubtitles.onSelectionChanged = { [weak item] hasExternalSelection in
            guard let item else { return }
            Task { @MainActor in
                await AVPlayerMediaSelectionAdapter.applySubtitleIntent(
                    selectionIntent,
                    to: item,
                    externalSubtitleSelected: hasExternalSelection
                )
            }
        }
        avExternalSubtitleController = externalSubtitles
        avPlayerController = controller

        avPlayerStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor in
                guard let self, let item else { return }
                switch item.status {
                case .readyToPlay:
                    guard !self.hasPreparedAVPlayerItem else { return }
                    self.hasPreparedAVPlayerItem = true
                    self.avMediaSelectionTask?.cancel()
                    self.avMediaSelectionTask = Task { @MainActor [weak self, weak item] in
                        guard let self, let item else { return }
                        await AVPlayerMediaSelectionAdapter.apply(
                            selectionIntent,
                            to: item,
                            externalSubtitleSelected: externalSubtitles.hasInitialSelection
                        )
                        guard !Task.isCancelled,
                              self.avPlayerController?.player?.currentItem === item else { return }
                        let playbackRate = self.resolvedAVPlayerRate()
                        player.defaultRate = playbackRate
                        let resume = self.currentPosition > 0
                            ? self.currentPosition
                            : self.resolvedResumePosition()
                        if let resume {
                            player.seek(to: CMTime(seconds: resume, preferredTimescale: 600)) { _ in
                                player.playImmediately(atRate: playbackRate)
                            }
                        } else {
                            player.playImmediately(atRate: playbackRate)
                        }
                    }
                case .failed:
                    self.showTerminalError(item.error?.localizedDescription ?? "AVPlayer could not play this stream.")
                default:
                    break
                }
            }
        }
        avPlayerTimeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                if player.timeControlStatus == .playing {
                    self.playbackDidStart = true
                    self.beginPlaybackLeaseIfNeeded()
                }
            }
        }
        avPlayerTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak item] time in
            Task { @MainActor in
                guard let self, let item else { return }
                let duration = item.duration.seconds
                guard time.seconds.isFinite, duration.isFinite, duration > 0 else { return }
                if time.seconds > 0.1 {
                    self.playbackDidStart = true
                    self.beginPlaybackLeaseIfNeeded()
                }
                self.handlePlaybackProgress(
                    position: time.seconds,
                    duration: duration,
                    isPlaying: player.timeControlStatus == .playing
                )
                self.avExternalSubtitleController?.update(time: time.seconds)
            }
        }
        avPlayerEndToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.handlePlaybackProgress(
                    position: self.currentDuration,
                    duration: self.currentDuration,
                    isPlaying: false
                )
                self.handleNaturalPlaybackEnd()
            }
        }

        Logger.shared.log("[TVPlayback] starting AVPlayer reason=\(reason)", type: "Player")
        install(controller, animated: activeChild != nil)
    }

    private func install(_ controller: UIViewController, animated: Bool) {
        let previous = activeChild
        previous?.willMove(toParent: nil)

        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        controller.didMove(toParent: self)
        activeChild = controller
        view.bringSubviewToFront(skipSegmentButton)
        view.bringSubviewToFront(nextEpisodeOverlay)

        let removePrevious = {
            previous?.view.removeFromSuperview()
            previous?.removeFromParent()
        }
        guard animated, let previous else { removePrevious(); return }
        controller.view.alpha = 0
        UIView.animate(withDuration: 0.25, animations: {
            controller.view.alpha = 1
            previous.view.alpha = 0
        }, completion: { _ in removePrevious() })
    }

    private func configureNextEpisodeOverlay() {
        nextEpisodeOverlay.translatesAutoresizingMaskIntoConstraints = false
        nextEpisodeOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.58)
        nextEpisodeOverlay.isHidden = true
        nextEpisodeOverlay.accessibilityViewIsModal = false
        view.addSubview(nextEpisodeOverlay)
        view.addGestureRecognizer(nextEpisodeBackGesture)

        nextEpisodeCard.translatesAutoresizingMaskIntoConstraints = false
        nextEpisodeCard.backgroundColor = UIColor(white: 0.10, alpha: 0.97)
        nextEpisodeCard.layer.cornerRadius = 34
        nextEpisodeCard.layer.cornerCurve = .continuous
        nextEpisodeOverlay.addSubview(nextEpisodeCard)

        nextEpisodeTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        nextEpisodeTitleLabel.text = "Next Episode"
        nextEpisodeTitleLabel.textColor = .white
        nextEpisodeTitleLabel.font = .systemFont(ofSize: 46, weight: .bold)
        nextEpisodeTitleLabel.textAlignment = .center
        nextEpisodeTitleLabel.accessibilityTraits = .header

        nextEpisodeMessageLabel.translatesAutoresizingMaskIntoConstraints = false
        nextEpisodeMessageLabel.textColor = UIColor.white.withAlphaComponent(0.78)
        nextEpisodeMessageLabel.font = .systemFont(ofSize: 27, weight: .regular)
        nextEpisodeMessageLabel.textAlignment = .center
        nextEpisodeMessageLabel.numberOfLines = 2

        var playConfiguration = UIButton.Configuration.borderedProminent()
        playConfiguration.title = "Play Next Episode"
        playConfiguration.image = UIImage(systemName: "forward.end.fill")
        playConfiguration.imagePadding = 14
        playConfiguration.cornerStyle = .large
        playNextEpisodeButton.configuration = playConfiguration
        playNextEpisodeButton.translatesAutoresizingMaskIntoConstraints = false
        playNextEpisodeButton.accessibilityHint = "Closes this player, then opens the next episode."
        playNextEpisodeButton.addAction(UIAction { [weak self] _ in
            self?.applyNextEpisodeEvent(.playNext)
        }, for: .primaryActionTriggered)

        var keepConfiguration = UIButton.Configuration.bordered()
        keepConfiguration.title = "Keep Watching"
        keepConfiguration.cornerStyle = .large
        keepWatchingButton.configuration = keepConfiguration
        keepWatchingButton.translatesAutoresizingMaskIntoConstraints = false
        keepWatchingButton.accessibilityHint = "Returns to the current episode without opening the next one."
        keepWatchingButton.addAction(UIAction { [weak self] _ in
            self?.applyNextEpisodeEvent(.keepWatching)
        }, for: .primaryActionTriggered)

        let buttonStack = UIStackView(arrangedSubviews: [playNextEpisodeButton, keepWatchingButton])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.axis = .horizontal
        buttonStack.alignment = .fill
        buttonStack.distribution = .fillEqually
        buttonStack.spacing = 34

        let contentStack = UIStackView(arrangedSubviews: [
            nextEpisodeTitleLabel,
            nextEpisodeMessageLabel,
            buttonStack
        ])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = 24
        contentStack.setCustomSpacing(40, after: nextEpisodeMessageLabel)
        nextEpisodeCard.addSubview(contentStack)

        NSLayoutConstraint.activate([
            nextEpisodeOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            nextEpisodeOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            nextEpisodeOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            nextEpisodeOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            nextEpisodeCard.centerXAnchor.constraint(equalTo: nextEpisodeOverlay.centerXAnchor),
            nextEpisodeCard.centerYAnchor.constraint(equalTo: nextEpisodeOverlay.centerYAnchor),
            nextEpisodeCard.widthAnchor.constraint(equalTo: nextEpisodeOverlay.safeAreaLayoutGuide.widthAnchor, multiplier: 0.64),
            contentStack.leadingAnchor.constraint(equalTo: nextEpisodeCard.leadingAnchor, constant: 58),
            contentStack.trailingAnchor.constraint(equalTo: nextEpisodeCard.trailingAnchor, constant: -58),
            contentStack.topAnchor.constraint(equalTo: nextEpisodeCard.topAnchor, constant: 48),
            contentStack.bottomAnchor.constraint(equalTo: nextEpisodeCard.bottomAnchor, constant: -48),
            buttonStack.heightAnchor.constraint(equalToConstant: 88)
        ])
    }

    private func configureSkipSegmentButton() {
        var configuration = UIButton.Configuration.borderedProminent()
        configuration.title = "Skip Segment"
        configuration.image = UIImage(systemName: "forward.fill")
        configuration.imagePadding = 12
        configuration.cornerStyle = .large
        skipSegmentButton.configuration = configuration
        skipSegmentButton.translatesAutoresizingMaskIntoConstraints = false
        skipSegmentButton.isHidden = true
        skipSegmentButton.accessibilityIdentifier = "TVPlayer.SkipSegment"
        skipSegmentButton.accessibilityHint = "Seeks to the end of this segment."
        skipSegmentButton.addAction(UIAction { [weak self] _ in
            self?.skipActiveSegment()
        }, for: .primaryActionTriggered)
        view.addSubview(skipSegmentButton)

        NSLayoutConstraint.activate([
            skipSegmentButton.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -72
            ),
            skipSegmentButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -150
            ),
            skipSegmentButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 78),
            skipSegmentButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 230)
        ])
    }

    private func showMPVFailure(_ message: String) {
        let alert = UIAlertController(title: "MPV Playback Failed", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Retry with AVPlayer", style: .default) { [weak self] _ in
            self?.fallbackToAVPlayer(reason: message)
        })
        alert.addAction(UIAlertAction(title: "Close", style: .cancel) { [weak self] _ in
            self?.dismissPlayback()
        })
        present(alert, animated: true)
    }

    private func showTerminalError(_ message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Playback Failed", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Close", style: .cancel) { [weak self] _ in
            self?.dismissPlayback()
        })
        present(alert, animated: true)
    }

    private func dismissPlayback() {
        mpvController?.stopPlayback()
        avPlayerController?.player?.pause()
        finalizePlaybackIfNeeded()
        dismiss(animated: true)
    }

    @objc private func handleCurrentUserBoundary() {
        // CKSyncEngine posts this synchronously before replacing the outgoing user's managers.
        // Stopping first freezes the last position; `finalizePlaybackIfNeeded` is idempotent, so
        // the ensuing dismissal cannot double-write progress or scrobble-close the session twice.
        guard !hasFinalizedPlayback else { return }
        mpvController?.stopPlayback()
        avPlayerController?.player?.pause()
        finalizePlaybackIfNeeded()
        dismiss(animated: false)
    }

    private func beginPlaybackLeaseIfNeeded() {
        guard !hasBegunPlaybackLease else { return }
        hasBegunPlaybackLease = true
        MediaStatePlaybackLease.begin()
    }

    private func finishPlaybackLeaseIfNeeded() {
        guard hasBegunPlaybackLease, !hasEndedPlaybackLease else { return }
        hasEndedPlaybackLease = true
        MediaStatePlaybackLease.end()
    }

    private func removeAVPlayerTimeObserver() {
        guard let token = avPlayerTimeObserver else { return }
        avPlayerController?.player?.removeTimeObserver(token)
        avPlayerTimeObserver = nil
    }

    private func resolvedResumePosition() -> Double? {
        if let explicit = request.resumePosition { return explicit }
        guard let mediaInfo = request.mediaInfo else { return nil }
        let progress: Double
        let position: Double
        switch mediaInfo {
        case .movie(let id, let title, _, _):
            progress = ProgressManager.shared.getMovieProgress(movieId: id, title: title)
            position = ProgressManager.shared.getMovieCurrentTime(movieId: id, title: title)
        case .episode(let showID, let season, let episode, _, _, _):
            progress = ProgressManager.shared.getEpisodeProgress(showId: showID, seasonNumber: season, episodeNumber: episode)
            position = ProgressManager.shared.getEpisodeCurrentTime(showId: showID, seasonNumber: season, episodeNumber: episode)
        }
        return progress < 0.95 && position > 0 ? position : nil
    }

    private func handlePlaybackProgress(position: Double, duration: Double, isPlaying: Bool) {
        guard position.isFinite, duration.isFinite, duration >= 5, position >= 0 else { return }
        currentPosition = min(position, duration)
        currentDuration = duration
        startSkipSegmentFetchIfNeeded(duration: duration)
        updateSkipSegmentState(isPlaying: isPlaying)

        let now = CACurrentMediaTime()
        if now - lastProgressPersistAt >= 1 || currentPosition >= duration - 0.5 {
            lastProgressPersistAt = now
            persistCurrentProgress()
        }
        if isPlaying, playbackDidStart, now - lastScrobbleAt >= 15 {
            lastScrobbleAt = now
            scrobbleCurrentProgress()
        }
        if currentPosition >= duration - 0.5 {
            handleNaturalPlaybackEnd()
        } else {
            offerNextEpisodeAtThresholdIfNeeded()
        }
    }

    private func startSkipSegmentFetchIfNeeded(duration: Double) {
        guard !didRequestSkipSegments,
              duration.isFinite,
              duration >= 5,
              let mediaInfo = request.mediaInfo else { return }

        let defaults = UserDefaults.standard
        let introDBEnabled = defaults.object(forKey: "introDBEnabled") as? Bool ?? true
        let introDBAppEnabled = defaults.object(forKey: "introDBAppEnabled") as? Bool ?? true
        guard introDBEnabled || (introDBAppEnabled && request.imdbID != nil) else {
            didRequestSkipSegments = true
            return
        }

        let tmdbID: Int
        let storedSeason: Int?
        let storedEpisode: Int?
        switch mediaInfo {
        case .movie(let id, _, _, _):
            tmdbID = id
            storedSeason = nil
            storedEpisode = nil
        case .episode(let showID, let season, let episode, _, _, _):
            tmdbID = showID
            storedSeason = season
            storedEpisode = episode
        }

        let tmdbSeason = request.originalTMDBSeasonNumber
            ?? request.episodePlaybackContext?.resolvedTMDBSeasonNumber
            ?? storedSeason
        let tmdbEpisode = request.originalTMDBEpisodeNumber
            ?? request.episodePlaybackContext?.resolvedTMDBEpisodeNumber
            ?? storedEpisode
        let imdbSeason = request.episodePlaybackContext?.isSpecial == true
            ? tmdbSeason
            : storedSeason
        let imdbEpisode = request.episodePlaybackContext?.isSpecial == true
            ? tmdbEpisode
            : storedEpisode

        didRequestSkipSegments = true
        skipSegmentFetchTask = Task { [weak self] in
            guard let self else { return }
            var fetched: [SkipSegment] = []

            if introDBEnabled {
                do {
                    fetched = try await IntroDBService.shared.fetchSkipTimes(
                        tmdbId: tmdbID,
                        seasonNumber: tmdbSeason,
                        episodeNumber: tmdbEpisode,
                        episodeDuration: duration
                    )
                } catch {
                    Logger.shared.log(
                        "[TVPlayback] TheIntroDB skip lookup failed category=network-or-decoding",
                        type: "Player"
                    )
                }
            }

            if fetched.isEmpty,
               introDBAppEnabled,
               let imdbID = request.imdbID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !imdbID.isEmpty {
                do {
                    fetched = try await IntroDBAppService.shared.fetchSkipTimes(
                        imdbId: imdbID,
                        seasonNumber: imdbSeason,
                        episodeNumber: imdbEpisode,
                        episodeDuration: duration
                    )
                } catch {
                    Logger.shared.log(
                        "[TVPlayback] IntroDB skip lookup failed category=network-or-decoding",
                        type: "Player"
                    )
                }
            }

            guard !Task.isCancelled, !hasFinalizedPlayback else { return }
            skipSegments = TVSkipSegmentPolicy.normalized(fetched, duration: duration)
            updateSkipSegmentState(isPlaying: activePlaybackIsPlaying)
        }
    }

    private var activePlaybackIsPlaying: Bool {
        if let mpvController {
            return mpvController.isPlaybackActive
        }
        guard let player = avPlayerController?.player else { return false }
        return player.timeControlStatus == .playing || player.rate > 0
    }

    private func updateSkipSegmentState(isPlaying: Bool) {
        guard let segment = TVSkipSegmentPolicy.activeSegment(
            in: skipSegments,
            position: currentPosition
        ) else {
            activeSkipSegment = nil
            setSkipSegmentButtonVisible(false)
            return
        }

        activeSkipSegment = segment
        let autoSkipEnabled = UserDefaults.standard.bool(forKey: "aniSkipAutoSkip")
        if isPlaying,
           autoSkipEnabled,
           autoSkippedSegmentKeys.insert(segment.uniqueKey).inserted {
            setSkipSegmentButtonVisible(false)
            seekActivePlayback(to: segment.endTime + 0.25)
            return
        }

        skipSegmentButton.configuration?.title = segment.type.displayLabel
        skipSegmentButton.accessibilityLabel = segment.type.displayLabel
        setSkipSegmentButtonVisible(nextEpisodeOverlay.isHidden)
    }

    private func skipActiveSegment() {
        guard let segment = activeSkipSegment else { return }
        autoSkippedSegmentKeys.insert(segment.uniqueKey)
        setSkipSegmentButtonVisible(false)
        seekActivePlayback(to: segment.endTime + 0.25)
        let skippedName = segment.type.displayLabel.replacingOccurrences(of: "Skip ", with: "")
        UIAccessibility.post(
            notification: .announcement,
            argument: "\(skippedName) skipped"
        )
    }

    private func seekActivePlayback(to position: Double) {
        let boundedPosition = currentDuration > 0
            ? min(max(0, position), currentDuration)
            : max(0, position)
        if let mpvController {
            mpvController.seekToPlaybackPosition(boundedPosition)
        } else {
            avPlayerController?.player?.seek(
                to: CMTime(seconds: boundedPosition, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
    }

    private func setSkipSegmentButtonVisible(_ visible: Bool) {
        let wasFocused = skipSegmentButton.isFocused
        skipSegmentButton.isHidden = !visible
        guard wasFocused, !visible else { return }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func persistCurrentProgress() {
        guard let mediaInfo = request.mediaInfo,
              currentDuration >= 5,
              currentPosition >= 0 else { return }
        switch mediaInfo {
        case .movie(let id, let title, let posterURL, _):
            ProgressManager.shared.updateMovieProgress(
                movieId: id,
                title: title,
                currentTime: currentPosition,
                totalDuration: currentDuration,
                posterURL: posterURL
            )
        case .episode(let showID, let season, let episode, let title, let posterURL, let isAnime):
            ProgressManager.shared.updateEpisodeProgress(
                showId: showID,
                seasonNumber: season,
                episodeNumber: episode,
                currentTime: currentPosition,
                totalDuration: currentDuration,
                showTitle: title,
                showPosterURL: posterURL,
                playbackContext: request.episodePlaybackContext?.forEpisodeNumber(episode),
                isAnime: isAnime || request.episodePlaybackContext?.hasAnimeMediaId == true
            )
        }
    }

    private func scrobbleCurrentProgress() {
        guard let mediaInfo = request.mediaInfo, currentDuration > 0 else { return }
        let progress = min(max(currentPosition / currentDuration, 0), 1)
        let context: EpisodePlaybackContext?
        if case .episode(_, _, let episode, _, _, _) = mediaInfo {
            context = request.episodePlaybackContext?.forEpisodeNumber(episode)
        } else {
            context = nil
        }
        TrackerManager.shared.scrobbleTraktPlayback(
            .start,
            for: mediaInfo,
            progress: progress,
            playbackContext: context
        )
    }

    private var nextEpisodeTarget: ResolvedNextEpisodeTarget? {
        let enabled = UserDefaults.standard.object(forKey: "showNextEpisodeButton") as? Bool ?? true
        guard enabled, case .available(let target) = nextEpisodeResolution else { return nil }
        return target
    }

    private func resolveNextEpisodeIfNeeded() {
        let enabled = UserDefaults.standard.object(forKey: "showNextEpisodeButton") as? Bool ?? true
        guard enabled, NextEpisodeSeed(request: request) != nil else {
            nextEpisodeResolution = .noAvailableEpisode
            return
        }

        nextEpisodeResolutionTask?.cancel()
        let request = request
        nextEpisodeResolutionTask = Task { [weak self] in
            let resolution = await NextEpisodeResolver().resolve(for: request)
            guard !Task.isCancelled, let self, !self.hasFinalizedPlayback else { return }
            self.nextEpisodeResolution = resolution
            self.nextEpisodeResolutionTask = nil
            self.handleCompletedNextEpisodeResolution()
        }
    }

    private func handleCompletedNextEpisodeResolution() {
        guard !hasFinalizedPlayback else { return }
        if didReachNaturalPlaybackEnd {
            naturalEndResolutionTimeoutTask?.cancel()
            naturalEndResolutionTimeoutTask = nil
            if nextEpisodeTarget != nil {
                applyNextEpisodeEvent(.naturalEnd)
            } else {
                dismissPlayback()
            }
            return
        }
        offerNextEpisodeAtThresholdIfNeeded()
    }

    private func offerNextEpisodeAtThresholdIfNeeded() {
        guard nextEpisodeTarget != nil, currentDuration > 0 else { return }
        let savedThreshold = UserDefaults.standard.double(forKey: "nextEpisodeThreshold")
        let threshold = savedThreshold > 0 ? min(max(savedThreshold, 0.5), 0.99) : 0.90
        guard currentPosition / currentDuration >= threshold else { return }
        applyNextEpisodeEvent(.thresholdReached)
    }

    private func handleNaturalPlaybackEnd() {
        guard !didReachNaturalPlaybackEnd else { return }
        didReachNaturalPlaybackEnd = true

        if nextEpisodeTarget != nil {
            applyNextEpisodeEvent(.naturalEnd)
            return
        }
        if nextEpisodeResolution != nil {
            dismissPlayback()
            return
        }

        // Resolution begins at player creation and normally finishes long before playback ends.
        // If metadata is still in flight, wait briefly rather than flashing a false prompt or
        // leaving a completed player stranded indefinitely on a network failure.
        naturalEndResolutionTimeoutTask?.cancel()
        naturalEndResolutionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, !self.hasFinalizedPlayback else { return }
            self.dismissPlayback()
        }
    }

    private func applyNextEpisodeEvent(_ event: TVNextEpisodeEvent) {
        let transition = TVNextEpisodePolicy.transition(
            from: nextEpisodeState,
            event: event,
            hasNextEpisode: nextEpisodeTarget != nil
        )
        nextEpisodeState = transition.state

        switch transition.action {
        case .none:
            break
        case .showPrompt(let atNaturalEnd):
            showNextEpisodePrompt(atNaturalEnd: atNaturalEnd)
        case .hidePrompt(let resumePlayback):
            hideNextEpisodePrompt(resumePlayback: resumePlayback)
        case .playNext:
            transitionToNextEpisode()
        }
    }

    private func showNextEpisodePrompt(atNaturalEnd: Bool) {
        wasPlayingBeforeNextEpisodePrompt = pauseActivePlaybackForPrompt()
        setSkipSegmentButtonVisible(false)
        let destination = nextEpisodeTarget.map {
            $0.isAnime
                ? "Episode \($0.episode.episodeNumber)"
                : "Season \($0.episode.seasonNumber), Episode \($0.episode.episodeNumber)"
        } ?? "the next episode"
        nextEpisodeMessageLabel.text = atNaturalEnd
            ? "Playback has ended. Play \(destination) or stay here."
            : "\(destination) is ready. Choose Play Next Episode or keep watching this one."
        nextEpisodeOverlay.isHidden = false
        nextEpisodeOverlay.accessibilityViewIsModal = true
        nextEpisodeBackGesture.isEnabled = true
        view.bringSubviewToFront(nextEpisodeOverlay)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        UIAccessibility.post(notification: .screenChanged, argument: playNextEpisodeButton)
    }

    private func hideNextEpisodePrompt(resumePlayback: Bool) {
        nextEpisodeOverlay.isHidden = true
        nextEpisodeOverlay.accessibilityViewIsModal = false
        nextEpisodeBackGesture.isEnabled = false
        if resumePlayback, wasPlayingBeforeNextEpisodePrompt {
            resumeActivePlaybackAfterPrompt()
        }
        wasPlayingBeforeNextEpisodePrompt = false
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func pauseActivePlaybackForPrompt() -> Bool {
        if let mpvController {
            return mpvController.pauseForNextEpisodePrompt()
        }
        guard let player = avPlayerController?.player else { return false }
        let wasPlaying = player.timeControlStatus == .playing || player.rate > 0
        player.pause()
        return wasPlaying
    }

    private func resumeActivePlaybackAfterPrompt() {
        if let mpvController {
            mpvController.resumeAfterNextEpisodePrompt()
        } else if let player = avPlayerController?.player {
            let playbackRate = resolvedAVPlayerRate()
            player.defaultRate = playbackRate
            player.playImmediately(atRate: playbackRate)
        }
    }

    private func resolvedAVPlayerRate() -> Float {
        Float(PlaybackSpeedPolicy.normalized(
            UserDefaults.standard.double(forKey: "defaultPlaybackSpeed")
        ))
    }

    @objc private func handleNextEpisodeBack() {
        applyNextEpisodeEvent(.back)
    }

    private func transitionToNextEpisode() {
        guard !isTransitioningToNextEpisode, let target = nextEpisodeTarget else { return }
        isTransitioningToNextEpisode = true
        nextEpisodeOverlay.isHidden = true
        nextEpisodeBackGesture.isEnabled = false
        mpvController?.stopPlayback()
        avPlayerController?.player?.pause()
        finalizePlaybackIfNeeded()

        let launchNext = { TVNextEpisodeRoutingCenter.shared.route(target) }
        guard presentingViewController != nil else {
            launchNext()
            return
        }
        dismiss(animated: true, completion: launchNext)
    }

    private func finalizePlaybackIfNeeded() {
        guard !hasFinalizedPlayback else { return }
        hasFinalizedPlayback = true
        // `viewDidDisappear` can be reached through a parent/system dismissal rather than the
        // player's explicit Close action. Always stop the active engine here so an MPV timer,
        // remote-command target, audio session, or AVPlayer cannot survive offscreen.
        mpvController?.stopPlayback()
        avPlayerController?.player?.pause()
        nextEpisodeResolutionTask?.cancel()
        nextEpisodeResolutionTask = nil
        naturalEndResolutionTimeoutTask?.cancel()
        naturalEndResolutionTimeoutTask = nil
        skipSegmentFetchTask?.cancel()
        skipSegmentFetchTask = nil
        avPlayerStatusObservation?.invalidate()
        avPlayerStatusObservation = nil
        avPlayerTimeControlObservation?.invalidate()
        avPlayerTimeControlObservation = nil
        removeAVPlayerTimeObserver()
        if let avPlayerEndToken {
            NotificationCenter.default.removeObserver(avPlayerEndToken)
            self.avPlayerEndToken = nil
        }
        avPlayerResourceLoader?.invalidate()
        avPlayerResourceLoader = nil
        avMediaSelectionTask?.cancel()
        avMediaSelectionTask = nil
        avExternalSubtitleController?.invalidate()
        avExternalSubtitleController = nil
        if playbackDidStart {
            persistCurrentProgress()
        }
        if let mediaInfo = request.mediaInfo {
            ProgressManager.shared.syncTraktProgressOnPlaybackClose(
                for: mediaInfo,
                playbackContext: request.episodePlaybackContext,
                played: playbackDidStart
            )
        }
        ProgressManager.shared.flushPendingSave()

        var userInfo: [String: Any] = [:]
        if let mediaInfo = request.mediaInfo {
            switch mediaInfo {
            case .movie(let id, _, _, _):
                userInfo["tmdbId"] = id
                userInfo["isMovie"] = true
            case .episode(let showID, _, _, _, _, _):
                userInfo["tmdbId"] = showID
                userInfo["isMovie"] = false
            }
        }
        NotificationCenter.default.post(name: .playerDidClose, object: self, userInfo: userInfo)
        finishPlaybackLeaseIfNeeded()
    }
}
#endif

/// Applies only the media-selection intent that AVFoundation exposes publicly. AVFoundation can
/// select embedded audio/legible options by language, but its old tvOS external-subtitle option
/// API is unavailable to Swift and deprecated as unsupported. External SRT/WebVTT files are
/// therefore represented by the public transport-bar menu and content-overlay adapter below.
@MainActor
enum AVPlayerMediaSelectionAdapter {
    static func apply(
        _ intent: PlaybackMediaSelectionIntent,
        to item: AVPlayerItem,
        externalSubtitleSelected: Bool,
        isStillCurrent: () -> Bool = { true }
    ) async {
        await applyAudioIntent(intent, to: item, isStillCurrent: isStillCurrent)
        guard !Task.isCancelled, isStillCurrent() else { return }
        await applySubtitleIntent(
            intent,
            to: item,
            externalSubtitleSelected: externalSubtitleSelected,
            isStillCurrent: isStillCurrent
        )
    }

    static func applySubtitleIntent(
        _ intent: PlaybackMediaSelectionIntent,
        to item: AVPlayerItem,
        externalSubtitleSelected: Bool,
        isStillCurrent: () -> Bool = { true }
    ) async {
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else {
            return
        }
        guard !Task.isCancelled, isStillCurrent() else { return }
        guard intent.subtitlesEnabled, !externalSubtitleSelected else {
            if group.allowsEmptySelection {
                item.select(nil, in: group)
            }
            return
        }

        if let option = preferredOption(
            in: group,
            preferredLanguage: intent.preferredSubtitleLanguage
        ) {
            item.select(option, in: group)
        } else {
            item.selectMediaOptionAutomatically(in: group)
        }
    }

    private static func applyAudioIntent(
        _ intent: PlaybackMediaSelectionIntent,
        to item: AVPlayerItem,
        isStillCurrent: () -> Bool
    ) async {
        guard let preferredLanguage = intent.preferredAudioLanguage,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
              !Task.isCancelled,
              isStillCurrent(),
              let option = preferredOption(in: group, preferredLanguage: preferredLanguage) else {
            return
        }
        item.select(option, in: group)
    }

    private static func preferredOption(
        in group: AVMediaSelectionGroup,
        preferredLanguage: String?
    ) -> AVMediaSelectionOption? {
        let descriptors = group.options.map {
            PlaybackLanguageSelectionPolicy.Option(
                languageTag: $0.extendedLanguageTag ?? $0.locale?.identifier,
                displayName: $0.displayName
            )
        }
        guard let index = PlaybackLanguageSelectionPolicy.preferredIndex(
            in: descriptors,
            preferredLanguage: preferredLanguage
        ) else { return nil }
        return group.options[index]
    }
}

struct TVExternalSubtitleCue: Equatable {
    let start: Double
    let end: Double
    let text: String
}

/// Bounded parser for the text subtitle formats providers commonly return. Bitmap formats such as
/// PGS cannot be represented by AVPlayer's public overlay APIs and remain MPV-only.
enum TVExternalSubtitleParser {
    private static let maximumCueCount = 20_000
    private static let maximumCueTextLength = 4_000

    static func parse(_ data: Data) -> [TVExternalSubtitleCue] {
        guard let source = decodeText(data) else { return [] }
        let normalized = source
            .replacingOccurrences(of: "\u{feff}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalized.range(of: "[Events]", options: .caseInsensitive) != nil {
            return parseASS(normalized)
        }
        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [TVExternalSubtitleCue] = []
        cues.reserveCapacity(min(blocks.count, maximumCueCount))

        for block in blocks where cues.count < maximumCueCount {
            let lines = block
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }
            let timingParts = lines[timingIndex].components(separatedBy: "-->")
            guard timingParts.count >= 2,
                  let start = parseTimestamp(timingParts[0]),
                  let end = parseTimestamp(
                    timingParts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                        .split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
                  ),
                  start.isFinite,
                  end.isFinite,
                  end > start else {
                continue
            }
            let rawText = lines.dropFirst(timingIndex + 1).joined(separator: "\n")
            let text = sanitizedCueText(rawText)
            guard !text.isEmpty else { continue }
            cues.append(TVExternalSubtitleCue(start: max(0, start), end: end, text: text))
        }
        return cues.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
    }

    private static func parseASS(_ source: String) -> [TVExternalSubtitleCue] {
        var inEvents = false
        var format = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var cues: [TVExternalSubtitleCue] = []
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            guard cues.count < maximumCueCount else { break }
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") {
                inEvents = line.caseInsensitiveCompare("[Events]") == .orderedSame
                continue
            }
            guard inEvents else { continue }
            if line.lowercased().hasPrefix("format:") {
                format = line.dropFirst("format:".count)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                continue
            }
            guard line.lowercased().hasPrefix("dialogue:"),
                  let startIndex = format.firstIndex(of: "start"),
                  let endIndex = format.firstIndex(of: "end"),
                  let textIndex = format.firstIndex(of: "text"),
                  format.count >= 3 else { continue }
            let payload = line.dropFirst("dialogue:".count)
            let fields = payload.split(
                separator: ",",
                maxSplits: max(0, format.count - 1),
                omittingEmptySubsequences: false
            ).map(String.init)
            guard fields.indices.contains(startIndex),
                  fields.indices.contains(endIndex),
                  fields.indices.contains(textIndex),
                  let start = parseTimestamp(fields[startIndex]),
                  let end = parseTimestamp(fields[endIndex]),
                  start.isFinite,
                  end.isFinite,
                  end > start else { continue }
            let assText = fields[textIndex]
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
            let withoutOverrides: String
            if let expression = try? NSRegularExpression(pattern: "\\{[^}]{0,1024}\\}") {
                withoutOverrides = expression.stringByReplacingMatches(
                    in: assText,
                    range: NSRange(assText.startIndex..<assText.endIndex, in: assText),
                    withTemplate: ""
                )
            } else {
                withoutOverrides = assText
            }
            let text = sanitizedCueText(withoutOverrides)
            guard !text.isEmpty else { continue }
            cues.append(TVExternalSubtitleCue(start: max(0, start), end: end, text: text))
        }
        return cues.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
    }

    private static func decodeText(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let utf16 = String(data: data, encoding: .utf16) { return utf16 }
        return String(data: data, encoding: .isoLatin1)
    }

    private static func parseTimestamp(_ rawValue: String) -> Double? {
        let cleaned = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        let components = cleaned.split(separator: ":").map(String.init)
        guard components.count == 2 || components.count == 3,
              let seconds = Double(components.last ?? "") else { return nil }
        let minutesIndex = components.count - 2
        guard let minutes = Double(components[minutesIndex]) else { return nil }
        let hours: Double
        if components.count == 3 {
            guard let parsedHours = Double(components[0]) else { return nil }
            hours = parsedHours
        } else {
            hours = 0
        }
        return hours * 3_600 + minutes * 60 + seconds
    }

    private static func sanitizedCueText(_ rawValue: String) -> String {
        let range = NSRange(rawValue.startIndex..<rawValue.endIndex, in: rawValue)
        let withoutTags: String
        if let expression = try? NSRegularExpression(pattern: "<[^>]{1,256}>") {
            withoutTags = expression.stringByReplacingMatches(
                in: rawValue,
                range: range,
                withTemplate: ""
            )
        } else {
            withoutTags = rawValue
        }
        let decoded = withoutTags
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(decoded.prefix(maximumCueTextLength))
    }
}

#if os(tvOS)
@MainActor
private final class TVAVPlayerExternalSubtitleController {
    private struct Candidate {
        let url: URL
        let title: String
        let languageTag: String?
        let headers: [String: String]
    }

    var onSelectionChanged: ((Bool) -> Void)?
    private(set) var hasInitialSelection = false

    private weak var playerViewController: AVPlayerViewController?
    private let candidates: [Candidate]
    private let label = UILabel()
    private var selectedIndex: Int?
    private var cues: [TVExternalSubtitleCue] = []
    private var download: TVBoundedSubtitleDownload?

    init(
        request: PlaybackRequest,
        selectionIntent: PlaybackMediaSelectionIntent,
        playerViewController: AVPlayerViewController
    ) {
        self.playerViewController = playerViewController
        candidates = Self.makeCandidates(from: request)
        configureOverlay(in: playerViewController)

        if selectionIntent.subtitlesEnabled, !candidates.isEmpty {
            let descriptors = candidates.map {
                PlaybackLanguageSelectionPolicy.Option(
                    languageTag: $0.languageTag,
                    displayName: $0.title
                )
            }
            selectedIndex = PlaybackLanguageSelectionPolicy.preferredIndex(
                in: descriptors,
                preferredLanguage: selectionIntent.preferredSubtitleLanguage
            ) ?? 0
            hasInitialSelection = true
        }
        rebuildMenu()
        if let selectedIndex {
            loadCandidate(at: selectedIndex, notify: false)
        }
    }

    func update(time: Double) {
        guard selectedIndex != nil, !cues.isEmpty, time.isFinite else {
            label.isHidden = true
            return
        }
        var lower = 0
        var upper = cues.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if cues[middle].start <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let index = lower - 1
        guard index >= 0, cues[index].end > time else {
            label.isHidden = true
            return
        }
        label.attributedText = Self.styledCueText(cues[index].text)
        label.isHidden = false
    }

    func invalidate() {
        download?.cancel()
        download = nil
        cues = []
        label.removeFromSuperview()
        if let playerViewController {
            playerViewController.transportBarCustomMenuItems = []
        }
    }

    private func configureOverlay(in controller: AVPlayerViewController) {
        controller.loadViewIfNeeded()
        guard let overlay = controller.contentOverlayView else { return }
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 4
        label.textAlignment = .center
        label.textColor = Self.subtitleColor(forKey: "subtitles_foregroundColor", fallback: .white)
        label.backgroundColor = UserDefaults.standard.bool(forKey: "subtitles_closedCaptionBackground")
            ? UIColor.black.withAlphaComponent(0.72)
            : .clear
        label.layer.cornerRadius = 12
        label.layer.masksToBounds = true
        let savedFontSize = UserDefaults.standard.double(forKey: "subtitles_fontSize")
        label.font = .systemFont(
            ofSize: CGFloat(savedFontSize > 0 ? min(max(savedFontSize, 24), 72) : 44),
            weight: .semibold
        )
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.72
        label.isHidden = true
        label.accessibilityTraits = .staticText
        overlay.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.safeAreaLayoutGuide.leadingAnchor, constant: 100),
            label.trailingAnchor.constraint(lessThanOrEqualTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -100),
            label.bottomAnchor.constraint(
                equalTo: overlay.safeAreaLayoutGuide.bottomAnchor,
                constant: Self.subtitleBottomConstant
            ),
            label.widthAnchor.constraint(lessThanOrEqualTo: overlay.safeAreaLayoutGuide.widthAnchor, multiplier: 0.82)
        ])
    }

    private func rebuildMenu() {
        guard let playerViewController, !candidates.isEmpty else { return }
        let off = UIAction(
            title: "Off",
            image: UIImage(systemName: "captions.bubble")
        ) { [weak self] _ in
            self?.disableExternalSubtitles()
        }
        off.state = selectedIndex == nil ? .on : .off

        let actions = candidates.enumerated().map { index, candidate in
            let action = UIAction(title: candidate.title) { [weak self] _ in
                self?.loadCandidate(at: index, notify: true)
            }
            action.state = selectedIndex == index ? .on : .off
            return action
        }
        let menu = UIMenu(
            title: "External Subtitles",
            image: UIImage(systemName: "captions.bubble.fill"),
            children: [off] + actions
        )
        playerViewController.transportBarCustomMenuItems = [menu]
    }

    private func disableExternalSubtitles() {
        download?.cancel()
        download = nil
        selectedIndex = nil
        cues = []
        label.isHidden = true
        rebuildMenu()
        onSelectionChanged?(false)
    }

    private func loadCandidate(at index: Int, notify: Bool) {
        guard candidates.indices.contains(index) else { return }
        download?.cancel()
        cues = []
        label.isHidden = true
        selectedIndex = index
        rebuildMenu()
        if notify { onSelectionChanged?(true) }

        let candidate = candidates[index]
        let download = TVBoundedSubtitleDownload(
            url: candidate.url,
            headers: candidate.headers
        )
        self.download = download
        download.start { [weak self, weak download] result in
            guard let self, self.download === download, self.selectedIndex == index else { return }
            self.download = nil
            switch result {
            case .success(let data):
                let parsed = TVExternalSubtitleParser.parse(data)
                guard !parsed.isEmpty else {
                    self.disableExternalSubtitles()
                    return
                }
                self.cues = parsed
            case .failure:
                // No provider URL or credential-bearing error is logged. Falling back to the
                // embedded legible selection is safer than leaving a failed option checked.
                self.disableExternalSubtitles()
            }
        }
    }

    private static func makeCandidates(from request: PlaybackRequest) -> [Candidate] {
        request.subtitles.enumerated().compactMap { index, rawValue in
            guard let url = URL(string: rawValue),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                return nil
            }
            let suppliedName: String?
            if let names = request.subtitleNames, names.indices.contains(index) {
                suppliedName = names[index].trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                suppliedName = nil
            }
            let title = suppliedName.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }
                ?? "Subtitle \(index + 1)"
            let rawHeaders = request.subtitleHeadersByURL?[rawValue]
                ?? request.subtitleHeadersByURL?[url.absoluteString]
                ?? [:]
            return Candidate(
                url: url,
                title: title,
                languageTag: inferredLanguageTag(from: title),
                headers: AVPlayerResourceLoader.sanitizedHTTPHeaders(rawHeaders)
            )
        }
    }

    private static func inferredLanguageTag(from title: String) -> String? {
        let tokens = title
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { (2...3).contains($0.count) }
        let locale = Locale(identifier: "en")
        return tokens.first { locale.localizedString(forLanguageCode: $0) != nil }
    }

    private static func styledCueText(_ text: String) -> NSAttributedString {
        let defaults = UserDefaults.standard
        let savedFontSize = defaults.double(forKey: "subtitles_fontSize")
        let fontSize = CGFloat(savedFontSize > 0 ? min(max(savedFontSize, 24), 72) : 44)
        let strokeWidth = defaults.object(forKey: "subtitles_strokeWidth") as? Double ?? 1
        let usesCaptionBackground = defaults.bool(forKey: "subtitles_closedCaptionBackground")
        return NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: subtitleColor(forKey: "subtitles_foregroundColor", fallback: .white),
                .strokeColor: subtitleColor(forKey: "subtitles_strokeColor", fallback: .black),
                .strokeWidth: usesCaptionBackground ? 0 : -max(0, min(strokeWidth, 4))
            ]
        )
    }

    private static func subtitleColor(forKey key: String, fallback: UIColor) -> UIColor {
        guard let data = UserDefaults.standard.data(forKey: key),
              let color = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: UIColor.self,
                from: data
              ) else {
            return fallback
        }
        return color
    }

    private static var subtitleBottomConstant: CGFloat {
        let defaults = UserDefaults.standard
        let offset = defaults.object(forKey: "playerSubtitleOverlayBottomConstant") == nil
            ? -6
            : defaults.double(forKey: "playerSubtitleOverlayBottomConstant")
        return min(-54, max(-210, -92 - CGFloat(offset + 6) * 2.5))
    }
}
#endif

final class TVBoundedSubtitleDownload: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private static let maximumBytes = 4 * 1_024 * 1_024

    private let originURL: URL
    private let headers: [String: String]
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var body = Data()
    private var completion: ((Result<Data, Error>) -> Void)?
    private var redirectCount = 0

    init(url: URL, headers: [String: String]) {
        originURL = url
        self.headers = headers
    }

    func start(completion: @escaping (Result<Data, Error>) -> Void) {
        guard session == nil else { return }
        self.completion = completion
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue.main
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        let request = makeRequest(url: originURL)
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func cancel(reportCancellation: Bool = false) {
        let completion = self.completion
        self.completion = nil
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        if reportCancellation {
            completion?(.failure(URLError(.cancelled)))
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode),
              response.expectedContentLength <= 0
                || response.expectedContentLength <= Int64(Self.maximumBytes) else {
            completionHandler(.cancel)
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard body.count + data.count <= Self.maximumBytes else {
            task?.cancel()
            finish(.failure(URLError(.dataLengthExceedsMaximum)))
            return
        }
        body.append(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              redirectCount < 10 else {
            completionHandler(nil)
            finish(.failure(URLError(.httpTooManyRedirects)))
            return
        }
        redirectCount += 1
        completionHandler(makeRequest(url: url))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        } else {
            finish(.success(body))
        }
    }

    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        AVPlayerResourceLoader.httpHeaders(
            headers,
            for: url,
            credentialOriginURL: originURL
        ).forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    private func finish(_ result: Result<Data, Error>) {
        guard let completion else { return }
        self.completion = nil
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil
        completion(result)
    }
}
