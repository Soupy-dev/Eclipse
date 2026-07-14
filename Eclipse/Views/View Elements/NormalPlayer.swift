import AVKit
import SwiftUI

#if os(iOS)
/// One visual language for Eclipse-owned AVPlayer controls. Keeping it local to this file
/// prevents AVPlayer chrome changes from leaking into the MPV/Molten renderer.
private enum IOSAVPlayerControlStyle {
    static func configuration(
        imageName: String,
        title: String? = nil,
        pointSize: CGFloat = 18,
        contentInsets: NSDirectionalEdgeInsets = NSDirectionalEdgeInsets(
            top: 8,
            leading: 8,
            bottom: 8,
            trailing: 8
        ),
        imagePadding: CGFloat = 0
    ) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: imageName)
        configuration.title = title
        configuration.imagePadding = imagePadding
        configuration.baseForegroundColor = .white
        configuration.baseBackgroundColor = UIColor.black.withAlphaComponent(0.46)
        configuration.cornerStyle = .capsule
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: pointSize,
            weight: .semibold
        )
        configuration.contentInsets = contentInsets
        return configuration
    }

    static func applyShadow(to button: UIButton) {
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.42
        button.layer.shadowRadius = 5
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
    }
}
#endif

/// Eclipse's AVKit player. AVPlayerViewController explicitly does not support subclassing, so the
/// system controller is embedded unchanged while Eclipse owns lifecycle, progress, subtitles, and
/// next-episode behavior in this container.
final class NormalPlayer: UIViewController, AVPlayerViewControllerDelegate, AVPictureInPictureControllerDelegate, UIGestureRecognizerDelegate {
    private let systemPlayerViewController = AVPlayerViewController()
#if os(iOS)
    private let playerSurfaceView = IOSAVPlayerSurfaceView()
    private var pictureInPictureController: AVPictureInPictureController?
    private var pictureInPicturePossibleObservation: NSKeyValueObservation?
#endif
    private var resourceLoader: AVPlayerResourceLoader?
#if !os(tvOS)
    private var headerProxyURL: URL?
#endif
    private var configuredRequest: PlaybackRequest?
    private var mediaSelectionIntent = PlaybackMediaSelectionIntent.currentDefaults(isAnime: false)
    private var embeddedSubtitlesAllowed = false
    private var isApplyingMediaSelection = false
    private var pendingResumePosition: Double?
    private var originalRate: Float = 1.0
    private var isHoldSpeedActive = false
    private var timeObserverToken: Any?
    private var startupTimeObserverToken: Any?
    private var interfaceTimeObserverToken: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var playerStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var startupWorkItem: DispatchWorkItem?
    private var startupProbeTask: Task<Void, Never>?
    private var postStartStallWorkItem: DispatchWorkItem?
    private var failedToEndObserver: NSObjectProtocol?
    private var playbackStalledObserver: NSObjectProtocol?
    private var mediaSelectionObserver: NSObjectProtocol?
    private var playbackDidStart = false
    private var playbackFailureHandled = false
    private var slowProbeCount = 0
    private var playbackLoadGeneration = 0
    private var startupLastObservedTime: Double?
    private var startupProgressAdvanceCount = 0
    private var hasBegunMediaStatePlaybackLease = false
    private var hasEndedMediaStatePlaybackLease = false
    private var hasFinalizedPlaybackSession = false
    private var isHandingOffPlaybackEngine = false
    private var pendingPlaybackFailureAlert: UIAlertController?
    private weak var playerInterfaceWindowScene: UIWindowScene?
    private let playerInterfaceCoverageIdentifier = UUID().uuidString
    var isCoordinatorEngineFallback = false
    var automaticallyFallsBackToMolten = false
    private(set) var playbackHandoffHasAppeared = false
    var mediaInfo: MediaInfo?
    var episodePlaybackContext: EpisodePlaybackContext?
    var playbackLaunchContext: PlaybackLaunchContext?
    var onPlaybackStartupFailure: ((PlaybackFailureReport) -> Void)?
    var onAutomaticPlaybackFallback: ((PlaybackFailureReport) -> Void)?
    var onRequestNextEpisode: ((_ seasonNumber: Int, _ episodeNumber: Int) -> Void)?

    var player: AVPlayer? {
        get {
#if os(iOS)
            playerSurfaceView.player
#else
            systemPlayerViewController.player
#endif
        }
        set {
#if os(iOS)
            playerSurfaceView.player = newValue
#else
            systemPlayerViewController.player = newValue
#endif
        }
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

#if os(iOS)
    private var holdGesture: UILongPressGestureRecognizer?
    private var doubleTapGesture: UITapGestureRecognizer?
    private var mediaControlsTapGesture: UITapGestureRecognizer?
    private var mediaControlsTouchDownGesture: UILongPressGestureRecognizer?
    private var mediaControlsWereVisibleAtTouchDown = false
    private var mediaSelectionTask: Task<Void, Never>?
    private var mediaSelectionOperationGeneration = 0
    private var mediaControlsController: IOSAVPlayerMediaControlsController?
    private var episodeBrowserHostingController: UIHostingController<AnyView>?
    private var isReplacingCurrentPlayback = false
    private var playbackReplacementGeneration = 0
    private var activeSourceSelectionID: UUID?
    private var committedSourceSelectionID: UUID?
    private weak var committedSourceSelectionItem: AVPlayerItem?
    private var nextEpisodeResolutionTask: Task<Void, Never>?
    private var nextEpisodeTarget: ResolvedNextEpisodeTarget?
    private var localNextEpisodeFallback: (seasonNumber: Int, episodeNumber: Int)?
    private var nextEpisodeResolutionStarted = false
    private var didRequestNextEpisode = false
    private var nextEpisodeVisibilityGeneration = 0
    private var currentPosition: Double = 0
    private var currentDuration: Double = 0
    private lazy var nextEpisodeButton = makeNextEpisodeButton()
    private var isPictureInPictureActiveOrStarting = false
    private var hasViewDisappeared = false
    private var isRestoringFromPictureInPicture = false
    private var pictureInPictureSessionRetainer: NormalPlayer?
    private weak var originatingWindowScene: UIWindowScene?
#endif

    func configure(with request: PlaybackRequest) {
        configuredRequest = request
        mediaInfo = request.mediaInfo
        episodePlaybackContext = request.episodePlaybackContext
        playbackLaunchContext = request.launchContext
        onPlaybackStartupFailure = request.onPlaybackStartupFailure
        onRequestNextEpisode = request.onRequestNextEpisode
        mediaSelectionIntent = request.mediaSelectionIntent
        embeddedSubtitlesAllowed = request.mediaSelectionIntent.subtitlesEnabled
        pendingResumePosition = request.resumePosition
        installPlayerItem(url: request.url, headers: request.headers)
    }

    func configureRemotePlayback(url: URL, headers: [String: String]) {
        installPlayerItem(url: url, headers: headers)
    }

    func beginPlaybackEngineHandoff() {
        guard !hasFinalizedPlaybackSession else { return }
        isHandingOffPlaybackEngine = true
        playbackFailureHandled = true
        onAutomaticPlaybackFallback = nil
        player?.pause()
    }

    private func installPlayerItem(url: URL, headers: [String: String]) {
        invalidatePlaybackTransport()
#if !os(tvOS)
        if !headers.isEmpty,
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           let proxyURL = MPVHeaderProxy.shared.makeProxyURL(
                for: url,
                headers: headers,
                logType: "AVPlayer",
                traceID: playbackLaunchContext?.traceID
           ) {
            headerProxyURL = proxyURL
            let item = AVPlayerItem(asset: AVURLAsset(url: proxyURL))
            if let player {
                player.replaceCurrentItem(with: item)
            } else {
                player = AVPlayer(playerItem: item)
            }
            Logger.shared.log(
                "NormalPlayer: using loopback header proxy for \(url.host ?? "remote stream")",
                type: "Player"
            )
            return
        }
#endif
        let backedItem = AVPlayerResourceLoader.makeItem(url: url, headers: headers)
        resourceLoader = backedItem.loader
        if let player {
            player.replaceCurrentItem(with: backedItem.item)
        } else {
            player = AVPlayer(playerItem: backedItem.item)
        }
    }

    private func invalidatePlaybackTransport() {
        resourceLoader?.invalidate()
        resourceLoader = nil
#if !os(tvOS)
        if let headerProxyURL {
            MPVHeaderProxy.shared.invalidateSession(for: headerProxyURL)
            self.headerProxyURL = nil
        }
#endif
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
#if os(iOS)
        playerSurfaceView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playerSurfaceView)
        NSLayoutConstraint.activate([
            playerSurfaceView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerSurfaceView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerSurfaceView.topAnchor.constraint(equalTo: view.topAnchor),
            playerSurfaceView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
#else
        addChild(systemPlayerViewController)
        systemPlayerViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(systemPlayerViewController.view)
        NSLayoutConstraint.activate([
            systemPlayerViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            systemPlayerViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            systemPlayerViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            systemPlayerViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        systemPlayerViewController.didMove(toParent: self)
#endif
        beginMediaStatePlaybackLeaseIfNeeded()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaStateAccountBoundary),
            name: .mediaStateWillChangeCurrentUser,
            object: nil
        )

#if os(iOS)
        if configuredRequest == nil {
            let isAnime: Bool
            switch mediaInfo {
            case .movie(_, _, _, let value), .episode(_, _, _, _, _, let value):
                isAnime = value || episodePlaybackContext?.hasAnimeMediaId == true
            case nil:
                isAnime = episodePlaybackContext?.hasAnimeMediaId == true
            }
            mediaSelectionIntent = .currentDefaults(isAnime: isAnime)
            embeddedSubtitlesAllowed = mediaSelectionIntent.subtitlesEnabled
        }
        setupHoldGesture()
        setupDoubleTapGesture()
        setupPictureInPictureHandling()
        setupMediaControls()
        setupMediaControlsVisibilityGesture()
        setupNextEpisodeButton()
        applyPlaybackLockState(capturingOrientationIfNeeded: false)
#endif
        if let info = mediaInfo {
            setupProgressTracking(for: info)
        }
        setupPlaybackStartupMonitoring()
        setupItemNotifications()
        setupInterfaceTimeObserver()
        setupAudioSession()
#if os(iOS)
        scheduleMediaSelection()
#endif
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        postPlayerInterfaceCoverage(covered: false)
#if os(iOS)
        if let scene = view.window?.windowScene ?? playerInterfaceWindowScene {
            AppDelegate.setOrientationLock(.all, for: scene)
        }
        hasViewDisappeared = true
        if isPictureInPictureActiveOrStarting {
            // AVPlayerViewController dismisses its full-screen UI while PiP
            // keeps playing. The playback lease and progress observer must
            // remain active until PiP actually stops.
            return
        }
#endif
        if isHandingOffPlaybackEngine {
            player?.pause()
            tearDownPlaybackObservers()
            finishMediaStatePlaybackLeaseIfNeeded()
            return
        }
        finalizePlaybackSessionIfNeeded()
        tearDownPlaybackObservers()
    }

    private func postPlayerInterfaceCoverage(covered: Bool) {
        let sceneSessionIdentifier = (viewIfLoaded?.window?.windowScene ?? playerInterfaceWindowScene)?
            .session.persistentIdentifier
        NotificationCenter.default.post(
            name: .playerInterfaceCoverageDidChange,
            object: self,
            userInfo: PlayerInterfaceCoverageNotification.userInfo(
                covered: covered,
                playerIdentifier: playerInterfaceCoverageIdentifier,
                sceneSessionIdentifier: sceneSessionIdentifier
            )
        )
    }

    private func tearDownPlaybackObservers() {
#if os(iOS)
        pictureInPicturePossibleObservation?.invalidate()
        pictureInPicturePossibleObservation = nil
        pictureInPictureController?.delegate = nil
        pictureInPictureController = nil
#endif
        tearDownPlaybackItemObservers()
    }

    /// Releases only state tied to the current AVPlayerItem. The player, player layer, PiP
    /// controller, gestures, lock/orientation state, scene coverage, and playback lease survive an
    /// in-place source or episode transition.
    private func tearDownPlaybackItemObservers() {
#if os(iOS)
        mediaSelectionTask?.cancel()
        mediaSelectionTask = nil
        mediaSelectionOperationGeneration &+= 1
        nextEpisodeResolutionTask?.cancel()
        nextEpisodeResolutionTask = nil
        mediaControlsController?.invalidate()
        mediaControlsController = nil
        isApplyingMediaSelection = false
#endif
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let token = startupTimeObserverToken {
            player?.removeTimeObserver(token)
            startupTimeObserverToken = nil
        }
        if let token = interfaceTimeObserverToken {
            player?.removeTimeObserver(token)
            interfaceTimeObserverToken = nil
        }
        if let failedToEndObserver {
            NotificationCenter.default.removeObserver(failedToEndObserver)
            self.failedToEndObserver = nil
        }
        if let playbackStalledObserver {
            NotificationCenter.default.removeObserver(playbackStalledObserver)
            self.playbackStalledObserver = nil
        }
        if let mediaSelectionObserver {
            NotificationCenter.default.removeObserver(mediaSelectionObserver)
            self.mediaSelectionObserver = nil
        }
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        playerStatusObservation?.invalidate()
        playerStatusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        startupWorkItem?.cancel()
        startupWorkItem = nil
        startupProbeTask?.cancel()
        startupProbeTask = nil
        postStartStallWorkItem?.cancel()
        postStartStallWorkItem = nil
        invalidatePlaybackTransport()
    }

    private func postPlayerDidCloseNotification() {
        var userInfo: [String: Any] = [:]
        if let mediaInfo {
            ProgressManager.shared.syncTraktProgressOnPlaybackClose(
                for: mediaInfo,
                playbackContext: episodePlaybackContext,
                played: playbackDidStart
            )
            switch mediaInfo {
            case .movie(let id, _, _, _):
                userInfo["tmdbId"] = id
                userInfo["isMovie"] = true
            case .episode(let showId, _, _, _, _, _):
                userInfo["tmdbId"] = showId
                userInfo["isMovie"] = false
            }
        }
        NotificationCenter.default.post(name: .playerDidClose, object: self, userInfo: userInfo)
    }

    private func beginMediaStatePlaybackLeaseIfNeeded() {
        guard mediaInfo != nil, !hasBegunMediaStatePlaybackLease else { return }
        hasBegunMediaStatePlaybackLease = true
        MediaStatePlaybackLease.begin()
    }

    private func finishMediaStatePlaybackLeaseIfNeeded() {
        guard hasBegunMediaStatePlaybackLease, !hasEndedMediaStatePlaybackLease else { return }
        hasEndedMediaStatePlaybackLease = true
        MediaStatePlaybackLease.end()
    }

    private func persistCurrentProgressForAccountBoundary() {
        guard let mediaInfo,
              let item = player?.currentItem else { return }
        let currentTime = player?.currentTime().seconds ?? .nan
        let duration = item.duration.seconds
        guard currentTime.isFinite,
              duration.isFinite,
              currentTime >= 0,
              duration >= 5,
              currentTime <= duration else { return }

        switch mediaInfo {
        case .movie(let id, let title, let posterURL, _):
            ProgressManager.shared.updateMovieProgress(
                movieId: id,
                title: title,
                currentTime: currentTime,
                totalDuration: duration,
                posterURL: posterURL
            )
        case .episode(let showId, let seasonNumber, let episodeNumber, let showTitle, let showPosterURL, let isAnime):
            ProgressManager.shared.updateEpisodeProgress(
                showId: showId,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber,
                currentTime: currentTime,
                totalDuration: duration,
                showTitle: showTitle,
                showPosterURL: showPosterURL,
                playbackContext: episodePlaybackContext?.forEpisodeNumber(episodeNumber),
                isAnime: isAnime || episodePlaybackContext?.hasAnimeMediaId == true
            )
        }
    }

    private func finalizePlaybackSessionIfNeeded(persistLatestPosition: Bool = false) {
        guard !hasFinalizedPlaybackSession else { return }
        hasFinalizedPlaybackSession = true
        playbackLoadGeneration &+= 1
        onAutomaticPlaybackFallback = nil
        startupWorkItem?.cancel()
        startupProbeTask?.cancel()
        postStartStallWorkItem?.cancel()
        player?.pause()
        if persistLatestPosition {
            persistCurrentProgressForAccountBoundary()
        }
        ProgressManager.shared.flushPendingSave()
        postPlayerDidCloseNotification()
        finishMediaStatePlaybackLeaseIfNeeded()
    }

    @objc private func handleMediaStateAccountBoundary() {
        // Notification delivery is synchronous. Finish every outgoing-account
        // write before the sync manager neutralizes or installs another user.
        guard hasBegunMediaStatePlaybackLease, !hasEndedMediaStatePlaybackLease else { return }
        finalizePlaybackSessionIfNeeded(persistLatestPosition: true)
        tearDownPlaybackObservers()
#if os(iOS)
        isPictureInPictureActiveOrStarting = false
        isRestoringFromPictureInPicture = false
        pictureInPictureSessionRetainer = nil
#endif
        player = nil
        dismiss(animated: false)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        // `configure(with:)` creates the transport before UIKit presents this controller. If a
        // coordinator handoff is cancelled before `viewDidDisappear`, there is no lifecycle
        // callback available to release that unpresented proxy session.
        invalidatePlaybackTransport()
        finishMediaStatePlaybackLeaseIfNeeded()
    }
    
#if os(iOS)
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hasViewDisappeared = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        playbackHandoffHasAppeared = true
        hasViewDisappeared = false
        isRestoringFromPictureInPicture = false
        originatingWindowScene = view.window?.windowScene ?? originatingWindowScene
        playerInterfaceWindowScene = view.window?.windowScene ?? playerInterfaceWindowScene
        presentationController?.delegate = self
        applyPlaybackLockState(capturingOrientationIfNeeded: true)
        postPlayerInterfaceCoverage(covered: true)
        if let pendingPlaybackFailureAlert {
            self.pendingPlaybackFailureAlert = nil
            presentPlaybackFailureAlert(pendingPlaybackFailureAlert)
        }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if let lockedMask = PlayerPlaybackLockSettings.lockedOrientationMask() {
            return lockedMask
        }
        if UserDefaults.standard.bool(forKey: "alwaysLandscape") {
            return .landscape
        } else {
            return .all
        }
    }

    override var shouldAutorotate: Bool {
        !PlayerPlaybackLockSettings.isLocked()
    }
    
    private func setupHoldGesture() {
        holdGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleHoldGesture(_:)))
        holdGesture?.minimumPressDuration = 0.5
        holdGesture?.cancelsTouchesInView = false
        holdGesture?.delegate = self
        if let holdGesture = holdGesture {
            view.addGestureRecognizer(holdGesture)
        }
    }

    private func setupDoubleTapGesture() {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        gesture.numberOfTapsRequired = 2
        gesture.cancelsTouchesInView = false
        gesture.delegate = self
        view.addGestureRecognizer(gesture)
        doubleTapGesture = gesture
    }

    private func setupMediaControlsVisibilityGesture() {
        // A single-tap recognizer must normally wait for double-tap seek to fail. Reveal hidden
        // controls on touch-down instead, then let the completed tap decide whether an already
        // visible overlay should hide. UIControls are excluded by the gesture delegate below.
        let touchDownGesture = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleMediaControlsTouchDown(_:))
        )
        touchDownGesture.minimumPressDuration = 0
        touchDownGesture.allowableMovement = 18
        touchDownGesture.cancelsTouchesInView = false
        touchDownGesture.delegate = self
        view.addGestureRecognizer(touchDownGesture)
        mediaControlsTouchDownGesture = touchDownGesture

        let gesture = UITapGestureRecognizer(
            target: self,
            action: #selector(handleMediaControlsVisibilityTap(_:))
        )
        gesture.cancelsTouchesInView = false
        gesture.delegate = self
        if let doubleTapGesture {
            gesture.require(toFail: doubleTapGesture)
        }
        view.addGestureRecognizer(gesture)
        mediaControlsTapGesture = gesture
    }

    @objc private func handleMediaControlsTouchDown(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began,
              let mediaControlsController else { return }
        mediaControlsWereVisibleAtTouchDown = mediaControlsController.controlsAreVisible
        if !mediaControlsWereVisibleAtTouchDown {
            mediaControlsController.showTemporarily()
        }
    }

    @objc private func handleMediaControlsVisibilityTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        mediaControlsController?.finishSurfaceTap(
            startedWithControlsVisible: mediaControlsWereVisibleAtTouchDown
        )
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended,
              !UIAccessibility.isVoiceOverRunning,
              UserDefaults.standard.object(forKey: "playerDoubleTapSeekEnabled") == nil
                || UserDefaults.standard.bool(forKey: "playerDoubleTapSeekEnabled"),
              let player else { return }
        let location = gesture.location(in: view)
        let width = max(view.bounds.width, 1)
        let direction: Double
        if location.x <= width * 0.4 {
            direction = -1
        } else if location.x >= width * 0.6 {
            direction = 1
        } else {
            return
        }
        let saved = UserDefaults.standard.double(forKey: "playerDoubleTapSeekSeconds")
        let interval = min(max(saved > 0 ? saved : 10, 5), 60)
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        let duration = player.currentItem?.duration.seconds ?? .nan
        let unclamped = current + direction * interval
        let target = duration.isFinite && duration > 0
            ? min(max(unclamped, 0), duration)
            : max(unclamped, 0)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600)
        )
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var touchedView: UIView? = touch.view
        while let candidate = touchedView {
            if candidate is UIControl { return false }
            touchedView = candidate.superview
        }
        return true
    }
    
    private func setupPictureInPictureHandling() {
        let defaults = UserDefaults.standard
        let pictureInPictureEnabled = defaults.object(forKey: "mpvPictureInPictureEnabled") as? Bool ?? true
        let automaticPictureInPictureEnabled = defaults.bool(forKey: "mpvAppExitPictureInPictureEnabled")
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              pictureInPictureEnabled else { return }
        guard let controller = AVPictureInPictureController(
            playerLayer: playerSurfaceView.playerLayer
        ) else { return }
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = automaticPictureInPictureEnabled
        pictureInPictureController = controller
        pictureInPicturePossibleObservation = controller.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] controller, _ in
            DispatchQueue.main.async { [weak self] in
                self?.mediaControlsController?.setPictureInPictureAvailable(
                    controller.isPictureInPicturePossible
                )
            }
        }
    }

    func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isPictureInPictureActiveOrStarting = true
        pictureInPictureSessionRetainer = self
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isPictureInPictureActiveOrStarting = true
        if UIApplication.shared.applicationState == .active,
           presentingViewController != nil {
            dismiss(animated: true)
        }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isPictureInPictureActiveOrStarting = false
        pictureInPictureSessionRetainer = nil
        mediaControlsController?.showTemporarily()
        if hasViewDisappeared {
            finalizePlaybackSessionIfNeeded()
            tearDownPlaybackObservers()
        }
    }

    func pictureInPictureControllerWillStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        // Keep the playback lease until PiP has fully stopped.
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isPictureInPictureActiveOrStarting = false
        if hasViewDisappeared, !isRestoringFromPictureInPicture {
            finalizePlaybackSessionIfNeeded()
            tearDownPlaybackObservers()
        }
        isRestoringFromPictureInPicture = false
        pictureInPictureSessionRetainer = nil
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        isRestoringFromPictureInPicture = true
        restoreUserInterfaceAfterPictureInPicture(
            completionHandler: completionHandler,
            remainingRunLoopRetries: 1
        )
    }

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isPictureInPictureActiveOrStarting = true
        pictureInPictureSessionRetainer = self
    }

    func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isPictureInPictureActiveOrStarting = true
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isPictureInPictureActiveOrStarting = false
        pictureInPictureSessionRetainer = nil
        if hasViewDisappeared {
            finalizePlaybackSessionIfNeeded()
            tearDownPlaybackObservers()
        }
    }

    func playerViewControllerWillStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        // Keep the lease until AVKit has fully stopped producing playback
        // callbacks; `didStop` is the account-safe release point.
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isPictureInPictureActiveOrStarting = false
        if hasViewDisappeared, !isRestoringFromPictureInPicture {
            finalizePlaybackSessionIfNeeded()
            tearDownPlaybackObservers()
        }
        isRestoringFromPictureInPicture = false
        pictureInPictureSessionRetainer = nil
    }
    
    func playerViewController(_ playerViewController: AVPlayerViewController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        isRestoringFromPictureInPicture = true
        restoreUserInterfaceAfterPictureInPicture(
            completionHandler: completionHandler,
            remainingRunLoopRetries: 1
        )
    }

    private func restoreUserInterfaceAfterPictureInPicture(
        completionHandler: @escaping (Bool) -> Void,
        remainingRunLoopRetries: Int
    ) {
        let activeScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        let candidateScenes: [UIWindowScene]
        if let originatingWindowScene,
           originatingWindowScene.activationState != .unattached {
            // A PiP session belongs to the scene that launched it. Falling through to another
            // active Stage Manager scene would reopen playback in the wrong iPad window.
            candidateScenes = [originatingWindowScene]
        } else {
            // If the original scene was destroyed, use the normal active-scene recovery path.
            candidateScenes = activeScenes
        }

        let topVC = candidateScenes.lazy.compactMap { scene -> UIViewController? in
            let window = scene.windows.first(where: { $0.isKeyWindow && $0.rootViewController != nil })
                ?? scene.windows.first(where: {
                    !$0.isHidden
                        && $0.alpha > 0
                        && $0.windowLevel == .normal
                        && $0.rootViewController != nil
                })
                ?? (scene.activationState == .foregroundActive
                    ? scene.windows.first(where: { $0.rootViewController != nil })
                    : nil)
            return window?.rootViewController?.topmostViewController()
        }.first

        if let topVC {
            if topVC != self {
                topVC.present(self, animated: true) {
                    self.hasViewDisappeared = false
                    self.isRestoringFromPictureInPicture = false
                    completionHandler(true)
                }
            } else {
                hasViewDisappeared = false
                isRestoringFromPictureInPicture = false
                completionHandler(true)
            }
            return
        }

        guard remainingRunLoopRetries > 0 else {
            isRestoringFromPictureInPicture = false
            completionHandler(false)
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                completionHandler(false)
                return
            }
            self.restoreUserInterfaceAfterPictureInPicture(
                completionHandler: completionHandler,
                remainingRunLoopRetries: remainingRunLoopRetries - 1
            )
        }
    }
    
    @objc private func handleHoldGesture(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            beginHoldSpeed()
        case .ended, .cancelled:
            endHoldSpeed()
        default:
            break
        }
    }
#endif
    
    private func beginHoldSpeed() {
        guard let player,
              player.timeControlStatus == .playing,
              player.rate > 0 else { return }
        originalRate = player.rate
        isHoldSpeedActive = true
        let holdSpeed = UserDefaults.standard.float(forKey: "holdSpeedPlayer")
        player.rate = holdSpeed > 0 ? holdSpeed : 2.0
    }
    
    private func endHoldSpeed() {
        guard isHoldSpeedActive else { return }
        isHoldSpeedActive = false
        guard let player else { return }
        if #available(iOS 16.0, tvOS 16.0, *) {
            player.defaultRate = originalRate
        }
        if player.timeControlStatus != .paused {
            // A buffer transition can set `rate` to zero while the hold is active. Restoring the
            // requested rate here prevents playback from resuming later at the temporary speed.
            player.rate = originalRate
        }
    }

    func playAtDefaultSpeed() {
        let savedSpeed = UserDefaults.standard.double(forKey: "defaultPlaybackSpeed")
        let speed = Float(savedSpeed > 0 ? min(max(savedSpeed, 0.25), 3.0) : 1.0)
        if abs(speed - 1.0) < 0.01 {
            player?.play()
        } else {
            player?.playImmediately(atRate: speed)
        }
    }

    private func setupPlaybackStartupMonitoring() {
        guard let player else { return }

        playbackLoadGeneration &+= 1
        let generation = playbackLoadGeneration
        startupLastObservedTime = nil
        startupProgressAdvanceCount = 0
        startupProbeTask?.cancel()
        startupProbeTask = nil
        postStartStallWorkItem?.cancel()
        postStartStallWorkItem = nil

        itemStatusObservation?.invalidate()
        playerStatusObservation?.invalidate()
        timeControlObservation?.invalidate()

        itemStatusObservation = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.playbackLoadGeneration == generation,
                      !self.hasFinalizedPlaybackSession,
                      !self.isHandingOffPlaybackEngine,
                      self.player?.currentItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    self.handleItemReady()
                case .failed:
                    self.handlePlaybackStartupFailure(item.error?.localizedDescription ?? "AVPlayer could not load this stream", isSourceFailure: true)
                default:
                    break
                }
            }
        }

        // AVPlayer itself can fail while its current item remains ready or unknown. Observing only
        // AVPlayerItem leaves Apple's terminal error screen visible forever on some containers.
        playerStatusObservation = player.observe(\.status, options: [.initial, .new]) { [weak self] player, _ in
            DispatchQueue.main.async { [weak self, weak player] in
                guard let self,
                      let player,
                      self.playbackLoadGeneration == generation,
                      !self.hasFinalizedPlaybackSession,
                      !self.isHandingOffPlaybackEngine,
                      self.player === player,
                      player.status == .failed else { return }
                self.handlePlaybackStartupFailure(
                    player.error?.localizedDescription ?? "AVPlayer could not open this stream",
                    isSourceFailure: true
                )
            }
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            if player.timeControlStatus == .playing {
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.playbackLoadGeneration == generation,
                          !self.hasFinalizedPlaybackSession,
                          !self.isHandingOffPlaybackEngine else { return }
                    self.postStartStallWorkItem?.cancel()
                    self.postStartStallWorkItem = nil
                    if self.playbackDidStart {
                        self.sendTraktScrobble(.start, reason: "avplayer-playing")
                    }
                }
            } else if player.timeControlStatus == .paused {
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.playbackLoadGeneration == generation,
                          !self.hasFinalizedPlaybackSession,
                          !self.isHandingOffPlaybackEngine else { return }
                    self.postStartStallWorkItem?.cancel()
                    self.postStartStallWorkItem = nil
                    self.sendTraktScrobble(.pause, reason: "avplayer-paused")
                }
            } else if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.playbackLoadGeneration == generation,
                          !self.hasFinalizedPlaybackSession,
                          !self.isHandingOffPlaybackEngine else { return }
                    self.schedulePostStartStallRecoveryIfNeeded()
                }
            }
        }

        startupTimeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC)),
            queue: .main
        ) { [weak self, weak player] time in
            guard let self,
                  self.playbackLoadGeneration == generation,
                  !self.hasFinalizedPlaybackSession,
                  !self.isHandingOffPlaybackEngine else { return }
            let seconds = time.seconds
            guard seconds.isFinite,
                  seconds >= 0,
                  player?.timeControlStatus == .playing else { return }
            if let previous = self.startupLastObservedTime {
                if seconds > previous + 0.05 {
                    self.startupProgressAdvanceCount += 1
                } else if seconds + 0.5 < previous {
                    self.startupProgressAdvanceCount = 0
                }
            }
            self.startupLastObservedTime = seconds
            if self.startupProgressAdvanceCount >= 2 {
                let hadStarted = self.playbackDidStart
                self.markPlaybackStarted()
                if !hadStarted, self.playbackDidStart {
                    self.sendTraktScrobble(.start, reason: "avplayer-progressing")
                }
            }
        }

        if let context = effectiveFailureContext(),
           let url = URL(string: context.streamURL) {
            // iPad Automatic must also recover from a corrupt or mislabeled downloaded file
            // whose AVPlayer state never becomes `.failed`. Explicit AVPlayer keeps the legacy
            // network-only health probe; probing a local file as if it were HTTP is meaningless.
            if automaticallyFallsBackToMolten || !url.isFileURL {
                schedulePlaybackStartupCheck(
                    url: url,
                    headers: context.headers,
                    delay: automaticallyFallsBackToMolten ? 15 : 35
                )
            }
        }
    }

    private func handleItemReady() {
        applyInitialResumePositionIfNeeded()
#if os(iOS)
        mediaControlsController?.refreshMediaOptions()
        scheduleMediaSelection()
#endif
    }

    private func schedulePlaybackStartupCheck(url: URL, headers: [String: String], delay: TimeInterval) {
        startupWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.committedSourceSelectionID == nil,
                  !self.playbackDidStart,
                  !self.playbackFailureHandled else { return }
            if self.automaticallyFallsBackToMolten,
               self.onAutomaticPlaybackFallback != nil {
                self.handlePlaybackStartupFailure(
                    "AVPlayer did not begin playback within 15 seconds.",
                    isSourceFailure: false
                )
                return
            }
            self.runPlaybackStartupProbe(url: url, headers: headers)
        }
        startupWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func markPlaybackStarted() {
        guard !playbackDidStart,
              !hasFinalizedPlaybackSession,
              !isHandingOffPlaybackEngine else { return }
        playbackDidStart = true
        startupWorkItem?.cancel()
        startupProbeTask?.cancel()
        startupProbeTask = nil
        if let context = playbackLaunchContext {
            SourceHealthStore.shared.recordPlaybackSuccess(sourceId: context.sourceId, sourceName: context.sourceName)
        }
    }

    private func currentTraktProgressFraction() -> Double? {
        guard let player,
              let currentItem = player.currentItem else { return nil }
        let currentTime = player.currentTime().seconds
        let duration = currentItem.duration.seconds
        guard playbackDidStart,
              currentTime.isFinite,
              duration.isFinite,
              duration >= 5,
              currentTime > 0.5,
              currentTime <= duration + 2 else {
            return nil
        }
        return min(max(currentTime / duration, 0), 1)
    }

    private func playbackContextForTraktScrobble(_ info: MediaInfo) -> EpisodePlaybackContext? {
        guard case .episode(_, _, let episodeNumber, _, _, _) = info else {
            return nil
        }
        return episodePlaybackContext?.forEpisodeNumber(episodeNumber)
    }

    private func sendTraktScrobble(_ action: TraktScrobbleAction, reason: String, force: Bool = false) {
        guard let info = mediaInfo,
              let progress = currentTraktProgressFraction() else { return }
        Logger.shared.log("NormalPlayer: Trakt scrobble \(action.rawValue) queued reason=\(reason) progress=\(Int((progress * 100).rounded()))%", type: "Tracker")
        TrackerManager.shared.scrobbleTraktPlayback(
            action,
            for: info,
            progress: progress,
            playbackContext: playbackContextForTraktScrobble(info),
            force: force
        )
    }

    private func runPlaybackStartupProbe(url: URL, headers: [String: String]) {
        let generation = playbackLoadGeneration
        startupProbeTask?.cancel()
        startupProbeTask = Task { [weak self] in
            let result = await SourceHealthMonitor.shared.probeStream(url: url, headers: headers)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.playbackLoadGeneration == generation,
                      self.committedSourceSelectionID == nil,
                      !self.playbackDidStart,
                      !self.playbackFailureHandled else { return }
                self.startupProbeTask = nil
                switch result {
                case .reachable:
                    self.slowProbeCount += 1
                    if self.slowProbeCount >= 3 {
                        self.handlePlaybackStartupFailure(
                            "The stream is reachable, but AVPlayer remained idle.",
                            isSourceFailure: false
                        )
                    } else {
                        self.schedulePlaybackStartupCheck(url: url, headers: headers, delay: 20)
                    }
                case .slowOrIndeterminate(let reason):
                    self.slowProbeCount += 1
                    if self.slowProbeCount >= 3 {
                        self.handlePlaybackStartupFailure("Playback is taking too long: \(reason)", isSourceFailure: false)
                    } else {
                        self.schedulePlaybackStartupCheck(url: url, headers: headers, delay: 20)
                    }
                case .networkUnavailable:
                    self.handlePlaybackStartupFailure("No internet connection is available.", isSourceFailure: false)
                case .sourceFailed(let reason):
                    self.handlePlaybackStartupFailure(reason, isSourceFailure: true)
                }
            }
        }
    }

    private func handlePlaybackStartupFailure(_ message: String, isSourceFailure: Bool) {
        guard !playbackDidStart,
              !playbackFailureHandled,
              committedSourceSelectionID == nil,
              !hasFinalizedPlaybackSession,
              !isHandingOffPlaybackEngine,
              let context = effectiveFailureContext() else { return }
        playbackFailureHandled = true
        startupWorkItem?.cancel()

        let report = PlaybackFailureReport(context: context, message: message, isSourceFailure: isSourceFailure)
        if let onAutomaticPlaybackFallback,
           (automaticallyFallsBackToMolten
                || PlaybackEngineRetryPolicy.shouldTryAlternateEngine(message: message)) {
            Logger.shared.log(
                "NormalPlayer: AVPlayer startup failed; handing the same request to Molten reason=\(message)",
                type: "Player"
            )
            self.onAutomaticPlaybackFallback = nil
            isHandingOffPlaybackEngine = true
            onAutomaticPlaybackFallback(report)
            return
        }

        if playbackLaunchContext != nil {
            SourceHealthStore.shared.recordPlaybackFailure(
                sourceId: context.sourceId,
                sourceName: context.sourceName,
                reason: message,
                isSourceFailure: isSourceFailure
            )
        }

        if context.autoMode, isCoordinatorEngineFallback {
            showCoordinatorFallbackFailureAlert(report)
        } else if context.autoMode, onPlaybackStartupFailure != nil {
            dismissAndReportPlaybackFailure(report)
        } else {
            showManualPlaybackFailureAlert(report)
        }
    }

    private func showCoordinatorFallbackFailureAlert(_ report: PlaybackFailureReport) {
        let alert = UIAlertController(
            title: "Playback Failed in Both Players",
            message: "AVPlayer could not start this stream after Molten failed. \(report.message)",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Retry AVPlayer", style: .default) { [weak self] _ in
            self?.retryPlaybackAfterFailure()
        })
        if onPlaybackStartupFailure != nil {
            alert.addAction(UIAlertAction(title: "Try Another Source", style: .default) { [weak self] _ in
                self?.dismissAndReportPlaybackFailure(report)
            })
        }
        alert.addAction(UIAlertAction(title: "Close", style: .cancel) { [weak self] _ in
            self?.closeAVPlayer()
        })
        presentPlaybackFailureAlert(alert)
    }

    private func showManualPlaybackFailureAlert(_ report: PlaybackFailureReport) {
        let alert = UIAlertController(
            title: "Playback Failed",
            message: "\(report.context.sourceName) could not start playback. \(report.message)",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
            self?.retryPlaybackAfterFailure()
        })
        alert.addAction(UIAlertAction(title: "Close", style: .cancel) { [weak self] _ in
            self?.closeAVPlayer()
        })
        presentPlaybackFailureAlert(alert)
    }

    private func presentPlaybackFailureAlert(_ alert: UIAlertController) {
        guard !hasFinalizedPlaybackSession,
              !isBeingDismissed else { return }
        guard viewIfLoaded?.window != nil else {
            // AVPlayer can report a failed item while this container is still in viewDidLoad.
            // Defer the alert until viewDidAppear so a fast failure cannot strand a blank player.
            pendingPlaybackFailureAlert = alert
            return
        }
        if isBeingPresented, let transitionCoordinator {
            transitionCoordinator.animate(alongsideTransition: nil) { [weak self] _ in
                self?.presentPlaybackFailureAlert(alert)
            }
            return
        }
        if let presentedViewController {
            presentedViewController.dismiss(animated: true) { [weak self] in
                self?.presentPlaybackFailureAlert(alert)
            }
            return
        }
        present(alert, animated: true)
    }

    private func dismissAndReportPlaybackFailure(_ report: PlaybackFailureReport) {
        let callback = onPlaybackStartupFailure
        player?.pause()
        if presentingViewController != nil {
            dismiss(animated: true) {
                callback?(report)
            }
        } else {
            callback?(report)
        }
    }

    /// Restores a primary player that asked the coordinator to hand off but could not safely be
    /// replaced (for example, another modal won the presenter while the handoff was connecting).
    func playbackEngineHandoffDidFail(_ report: PlaybackFailureReport) {
        guard !isBeingDismissed, viewIfLoaded?.window != nil else { return }
        isHandingOffPlaybackEngine = false
        onAutomaticPlaybackFallback = nil
        playbackFailureHandled = true
        if report.context.autoMode, onPlaybackStartupFailure != nil {
            dismissAndReportPlaybackFailure(report)
        } else {
            showManualPlaybackFailureAlert(report)
        }
    }

    private func effectiveFailureContext() -> PlaybackLaunchContext? {
        if let playbackLaunchContext { return playbackLaunchContext }
        guard let request = configuredRequest else { return nil }
        return PlaybackLaunchContext(
            sourceId: request.url.isFileURL ? "local-playback" : "direct-playback",
            sourceName: request.url.isFileURL ? "Downloaded Media" : "AVPlayer",
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

    private func retryPlaybackAfterFailure() {
        guard let context = effectiveFailureContext(), let url = URL(string: context.streamURL) else {
            player?.seek(to: .zero)
            playAtDefaultSpeed()
            return
        }

        let retryResumePosition = currentPosition > 0
            ? currentPosition
            : configuredRequest?.resumePosition
        playbackLoadGeneration &+= 1
        tearDownPlaybackItemObservers()

        playbackFailureHandled = false
        playbackDidStart = false
        slowProbeCount = 0
        pendingPlaybackFailureAlert = nil
        pendingResumePosition = retryResumePosition
#if os(iOS)
        nextEpisodeResolutionStarted = false
        nextEpisodeTarget = nil
        localNextEpisodeFallback = nil
        didRequestNextEpisode = false
        nextEpisodeVisibilityGeneration &+= 1
        nextEpisodeButton.layer.removeAllAnimations()
        nextEpisodeButton.isEnabled = true
        nextEpisodeButton.alpha = 0
        nextEpisodeButton.isHidden = true
#endif

        if player?.status == .failed {
            player = nil
        }
        installPlayerItem(url: url, headers: context.headers)
#if os(iOS)
        setupMediaControls()
#endif
        if let mediaInfo {
            setupProgressTracking(for: mediaInfo)
        }
        setupPlaybackStartupMonitoring()
        setupItemNotifications()
        setupInterfaceTimeObserver()
#if os(iOS)
        scheduleMediaSelection()
#endif
        playAtDefaultSpeed()
    }

    private func setupItemNotifications() {
        if let failedToEndObserver {
            NotificationCenter.default.removeObserver(failedToEndObserver)
        }
        if let mediaSelectionObserver {
            NotificationCenter.default.removeObserver(mediaSelectionObserver)
        }
        if let playbackStalledObserver {
            NotificationCenter.default.removeObserver(playbackStalledObserver)
        }
        guard let item = player?.currentItem else { return }
        let generation = playbackLoadGeneration
        failedToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  self.playbackLoadGeneration == generation,
                  !self.hasFinalizedPlaybackSession,
                  !self.isHandingOffPlaybackEngine,
                  self.player?.currentItem === item else { return }
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            self.handleRuntimePlaybackFailure(
                error?.localizedDescription ?? "AVPlayer stopped before the video ended."
            )
        }
        playbackStalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self,
                  self.playbackLoadGeneration == generation,
                  !self.hasFinalizedPlaybackSession,
                  !self.isHandingOffPlaybackEngine,
                  self.player?.currentItem === item else { return }
            self.schedulePostStartStallRecoveryIfNeeded()
        }
        mediaSelectionObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.mediaSelectionDidChangeNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            guard let self, let item,
                  self.playbackLoadGeneration == generation,
                  self.player?.currentItem === item,
                  !self.isApplyingMediaSelection else { return }
#if os(iOS)
            Task { @MainActor [weak self, weak item] in
                guard let self, let item,
                      self.playbackLoadGeneration == generation,
                      self.player?.currentItem === item else { return }
                self.mediaControlsController?.refreshSelectionState()
                guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                      !Task.isCancelled,
                      self.playbackLoadGeneration == generation,
                      self.player?.currentItem === item,
                      !self.isApplyingMediaSelection,
                      let selected = item.currentMediaSelection.selectedMediaOption(in: group) else { return }
                self.embeddedSubtitlesAllowed = true
                self.mediaSelectionIntent = self.mediaSelectionIntent.overridingRendererSelection(
                    audioLanguage: nil,
                    subtitleLanguage: selected.extendedLanguageTag,
                    hasSelectedSubtitle: true
                )
                self.mediaControlsController?.disableForNativeSelection()
            }
#endif
        }
    }

    private func setupInterfaceTimeObserver() {
        if let interfaceTimeObserverToken {
            player?.removeTimeObserver(interfaceTimeObserverToken)
            self.interfaceTimeObserverToken = nil
        }
        guard let player, let item = player.currentItem else { return }
        let generation = playbackLoadGeneration
        interfaceTimeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak player] time in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player,
                      self.playbackLoadGeneration == generation,
                      !self.hasFinalizedPlaybackSession,
                      !self.isHandingOffPlaybackEngine,
                      self.player === player,
                      player.currentItem === item else { return }
                let position = time.seconds
                let duration = player.currentItem?.duration.seconds ?? .nan
                self.currentPosition = position.isFinite ? max(0, position) : 0
                self.currentDuration = duration.isFinite && duration > 0 ? duration : 0
#if os(iOS)
                self.mediaControlsController?.update(time: self.currentPosition)
                self.updateNextEpisodeState(position: self.currentPosition, duration: self.currentDuration)
#endif
            }
        }
    }

    private func handleRuntimePlaybackFailure(_ message: String) {
        guard committedSourceSelectionID == nil else { return }
        guard playbackDidStart else {
            handlePlaybackStartupFailure(message, isSourceFailure: true)
            return
        }
        let alert = UIAlertController(
            title: "Playback Stopped",
            message: message,
            preferredStyle: .alert
        )
        if let context = effectiveFailureContext(),
           let onAutomaticPlaybackFallback {
            let report = PlaybackFailureReport(context: context, message: message, isSourceFailure: false)
            alert.addAction(UIAlertAction(title: "Try Other Player", style: .default) { [weak self] _ in
                self?.persistCurrentProgressForAccountBoundary()
                ProgressManager.shared.flushPendingSave()
                self?.onAutomaticPlaybackFallback = nil
                self?.isHandingOffPlaybackEngine = true
                onAutomaticPlaybackFallback(report)
            })
        }
        alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
            self?.retryPlaybackAfterFailure()
        })
        alert.addAction(UIAlertAction(title: "Close", style: .cancel) { [weak self] _ in
            self?.closeAVPlayer()
        })
        if presentedViewController == nil {
            present(alert, animated: true)
        }
    }

    private func schedulePostStartStallRecoveryIfNeeded() {
        guard playbackDidStart,
              committedSourceSelectionID == nil,
              postStartStallWorkItem == nil,
              player?.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.postStartStallWorkItem = nil
            guard self.playbackDidStart,
                  self.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate,
                  self.viewIfLoaded?.window != nil else { return }
            self.handleRuntimePlaybackFailure(
                "Playback has remained stalled for 30 seconds."
            )
        }
        postStartStallWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: workItem)
    }

    func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
#if os(iOS)
            try audioSession.setCategory(.playback, mode: .moviePlayback)
            try audioSession.setActive(true)
#elseif os(tvOS)
            try audioSession.setCategory(.playback, mode: .moviePlayback)
            try audioSession.setActive(true)
#endif
        } catch {
            Logger.shared.log("Failed to set up AVAudioSession: \(error)")
        }
    }

    // MARK: - Progress Tracking

    func setupProgressTracking(for mediaInfo: MediaInfo) {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
        }
        guard let player = player else {
            Logger.shared.log("No player available for progress tracking", type: "Warning")
            return
        }

        timeObserverToken = ProgressManager.shared.addPeriodicTimeObserver(
            to: player,
            for: mediaInfo,
            playbackContext: episodePlaybackContext
        )
    }

    private func applyInitialResumePositionIfNeeded() {
        let resumePosition: Double?
        if let pendingResumePosition,
           pendingResumePosition.isFinite,
           pendingResumePosition > 0 {
            resumePosition = pendingResumePosition
        } else if let mediaInfo,
                  getProgressPercentage(for: mediaInfo) < 0.95 {
            switch mediaInfo {
            case .movie(let id, let title, _, _):
                resumePosition = ProgressManager.shared.getMovieCurrentTime(movieId: id, title: title)
            case .episode(let showId, let seasonNumber, let episodeNumber, _, _, _):
                resumePosition = ProgressManager.shared.getEpisodeCurrentTime(
                    showId: showId,
                    seasonNumber: seasonNumber,
                    episodeNumber: episodeNumber
                )
            }
        } else {
            resumePosition = nil
        }
        pendingResumePosition = nil
        guard let resumePosition,
              resumePosition.isFinite,
              resumePosition > 0 else { return }
        let duration = player?.currentItem?.duration.seconds ?? .nan
        guard !duration.isFinite || resumePosition < duration else { return }
        player?.seek(to: CMTime(seconds: resumePosition, preferredTimescale: 600))
        Logger.shared.log("Resumed AVPlayer playback from \(Int(resumePosition))s", type: "Progress")
    }
    
    private func getProgressPercentage(for mediaInfo: MediaInfo) -> Double {
        switch mediaInfo {
        case .movie(let id, let title, _, _):
            return ProgressManager.shared.getMovieProgress(movieId: id, title: title)
            
        case .episode(let showId, let seasonNumber, let episodeNumber, _, _, _):
            return ProgressManager.shared.getEpisodeProgress(showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber)
        }
    }
}

#if os(iOS)
private extension NormalPlayer {
    func scheduleMediaSelection() {
        mediaSelectionTask?.cancel()
        mediaSelectionTask = nil
        mediaSelectionOperationGeneration &+= 1
        let operationGeneration = mediaSelectionOperationGeneration
        let loadGeneration = playbackLoadGeneration
        guard let item = player?.currentItem else { return }
        let intent = PlaybackMediaSelectionIntent(
            preferredAudioLanguage: mediaSelectionIntent.preferredAudioLanguage,
            preferredSubtitleLanguage: mediaSelectionIntent.preferredSubtitleLanguage,
            subtitlesEnabled: embeddedSubtitlesAllowed
        )
        let externalSelected = mediaControlsController?.hasSelectedSubtitle == true
        mediaSelectionTask = Task { @MainActor [weak self, weak item] in
            guard let self, let item,
                  self.mediaSelectionOperationGeneration == operationGeneration,
                  self.playbackLoadGeneration == loadGeneration,
                  self.player?.currentItem === item else { return }
            self.isApplyingMediaSelection = true
            await AVPlayerMediaSelectionAdapter.apply(
                intent,
                to: item,
                externalSubtitleSelected: externalSelected,
                isStillCurrent: { [weak self, weak item] in
                    guard let self, let item else { return false }
                    return self.mediaSelectionOperationGeneration == operationGeneration
                        && self.playbackLoadGeneration == loadGeneration
                        && self.player?.currentItem === item
                }
            )
            guard !Task.isCancelled,
                  self.mediaSelectionOperationGeneration == operationGeneration,
                  self.playbackLoadGeneration == loadGeneration,
                  self.player?.currentItem === item else { return }
            self.isApplyingMediaSelection = false
            self.mediaSelectionTask = nil
            self.mediaControlsController?.refreshSelectionState()
        }
    }

    func scheduleSubtitleSelection() {
        mediaSelectionTask?.cancel()
        mediaSelectionTask = nil
        mediaSelectionOperationGeneration &+= 1
        let operationGeneration = mediaSelectionOperationGeneration
        let loadGeneration = playbackLoadGeneration
        guard let item = player?.currentItem else { return }
        let intent = PlaybackMediaSelectionIntent(
            preferredAudioLanguage: mediaSelectionIntent.preferredAudioLanguage,
            preferredSubtitleLanguage: mediaSelectionIntent.preferredSubtitleLanguage,
            subtitlesEnabled: embeddedSubtitlesAllowed
        )
        let externalSelected = mediaControlsController?.hasSelectedSubtitle == true
        mediaSelectionTask = Task { @MainActor [weak self, weak item] in
            guard let self, let item,
                  self.mediaSelectionOperationGeneration == operationGeneration,
                  self.playbackLoadGeneration == loadGeneration,
                  self.player?.currentItem === item else { return }
            self.isApplyingMediaSelection = true
            await AVPlayerMediaSelectionAdapter.applySubtitleIntent(
                intent,
                to: item,
                externalSubtitleSelected: externalSelected,
                isStillCurrent: { [weak self, weak item] in
                    guard let self, let item else { return false }
                    return self.mediaSelectionOperationGeneration == operationGeneration
                        && self.playbackLoadGeneration == loadGeneration
                        && self.player?.currentItem === item
                }
            )
            guard !Task.isCancelled,
                  self.mediaSelectionOperationGeneration == operationGeneration,
                  self.playbackLoadGeneration == loadGeneration,
                  self.player?.currentItem === item else { return }
            self.isApplyingMediaSelection = false
            self.mediaSelectionTask = nil
            self.mediaControlsController?.refreshSelectionState()
        }
    }

    func setupMediaControls() {
        mediaControlsController?.invalidate()
        mediaControlsController = nil
        guard let player else { return }
        let subtitleURLs = configuredRequest?.subtitles ?? playbackLaunchContext?.subtitles ?? []
        let controller = IOSAVPlayerMediaControlsController(
            subtitleURLs: subtitleURLs,
            subtitleNames: configuredRequest?.subtitleNames ?? playbackLaunchContext?.subtitleNames,
            subtitleHeadersByURL: configuredRequest?.subtitleHeadersByURL
                ?? playbackLaunchContext?.subtitleHeadersByURL,
            selectionIntent: mediaSelectionIntent,
            player: player,
            overlayView: view,
            title: avPlayerDisplayTitle()
        )
        controller.onClose = { [weak self] in
            self?.closeAVPlayer()
        }
        controller.onPlaybackLockToggle = { [weak self] in
            self?.togglePlaybackLock()
        }
        controller.onPictureInPicture = { [weak self] in
            guard let self,
                  let pictureInPictureController,
                  pictureInPictureController.isPictureInPicturePossible else { return }
            pictureInPictureController.startPictureInPicture()
        }
        controller.onServices = { [weak self] in
            self?.presentServicesSheet()
        }
        controller.onEpisodeBrowser = { [weak self] in
            self?.toggleEpisodeBrowser()
        }
        controller.onSelectionChanged = { [weak self, weak controller] externalSelected, allowEmbeddedFallback in
            guard let self else { return }
            self.embeddedSubtitlesAllowed = allowEmbeddedFallback
                ? self.mediaSelectionIntent.subtitlesEnabled
                : false
            if externalSelected {
                self.mediaSelectionIntent = self.mediaSelectionIntent.overridingRendererSelection(
                    audioLanguage: nil,
                    subtitleLanguage: controller?.selectedExternalSubtitleLanguage,
                    hasSelectedSubtitle: true
                )
            } else if !allowEmbeddedFallback {
                self.mediaSelectionIntent = self.mediaSelectionIntent.overridingRendererSelection(
                    audioLanguage: nil,
                    subtitleLanguage: nil,
                    hasSelectedSubtitle: false
                )
            }
            self.scheduleSubtitleSelection()
        }
        controller.onEmbeddedSubtitleSelectionChanged = { [weak self] languageTag in
            guard let self else { return }
            self.embeddedSubtitlesAllowed = true
            self.mediaSelectionIntent = self.mediaSelectionIntent.overridingRendererSelection(
                audioLanguage: nil,
                subtitleLanguage: languageTag,
                hasSelectedSubtitle: true
            )
        }
        controller.onAudioSelectionChanged = { [weak self] languageTag in
            guard let self else { return }
            self.mediaSelectionIntent = self.mediaSelectionIntent.overridingRendererSelection(
                audioLanguage: languageTag,
                subtitleLanguage: nil,
                hasSelectedSubtitle: nil
            )
        }
        mediaControlsController = controller
        controller.setServicesAvailable(
            PlayerServicesButtonSettings.isEnabled()
                && configuredRequest.flatMap(PlayerServicesSelectionContext.init(request:)) != nil
        )
        controller.setEpisodeBrowserAvailable(
            episodeBrowserButtonEnabled && makeEpisodeBrowserSeed() != nil
        )
        controller.setPictureInPictureAvailable(
            pictureInPictureController?.isPictureInPicturePossible == true
        )
        controller.setPlaybackLocked(PlayerPlaybackLockSettings.isLocked())
        controller.showTemporarily()
        if controller.hasSelectedSubtitle {
            embeddedSubtitlesAllowed = false
        }
    }

    func avPlayerDisplayTitle() -> String {
        if let title = configuredRequest?.title.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        switch mediaInfo {
        case .movie(_, let title, _, _):
            return title
        case .episode(_, let seasonNumber, let episodeNumber, let showTitle, _, _):
            let episode = "S\(seasonNumber) · E\(episodeNumber)"
            guard let showTitle = showTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !showTitle.isEmpty else { return episode }
            return "\(showTitle)  ·  \(episode)"
        case nil:
            return "Now Playing"
        }
    }

    func closeAVPlayer() {
        guard !PlayerPlaybackLockSettings.isLocked() else {
            mediaControlsController?.showTemporarily()
            return
        }
        finalizePlaybackSessionIfNeeded(persistLatestPosition: true)
        tearDownPlaybackObservers()
        player = nil
        dismiss(animated: true)
    }

    func togglePlaybackLock() {
        let shouldLock = !PlayerPlaybackLockSettings.isLocked()
        let orientation = PlayerPlaybackLockSettings.capturedInterfaceOrientation(
            scene: view.window?.windowScene,
            viewBounds: view.bounds
        )
        PlayerPlaybackLockSettings.setLocked(
            shouldLock,
            interfaceOrientation: orientation
        )
        applyPlaybackLockState(capturingOrientationIfNeeded: true)
        mediaControlsController?.showTemporarily()
    }

    func applyPlaybackLockState(capturingOrientationIfNeeded: Bool) {
        if capturingOrientationIfNeeded,
           PlayerPlaybackLockSettings.isLocked(),
           PlayerPlaybackLockSettings.lockedOrientationMask() == nil {
            PlayerPlaybackLockSettings.setLocked(
                true,
                interfaceOrientation: view.window?.windowScene?.interfaceOrientation
            )
        }

        let locked = PlayerPlaybackLockSettings.isLocked()
        isModalInPresentation = locked
        mediaControlsController?.setPlaybackLocked(locked)
        if let scene = view.window?.windowScene ?? playerInterfaceWindowScene {
            AppDelegate.setOrientationLock(
                locked ? (PlayerPlaybackLockSettings.lockedOrientationMask() ?? supportedInterfaceOrientations) : .all,
                for: scene
            )
        }
        if #available(iOS 16.0, *) {
            setNeedsUpdateOfSupportedInterfaceOrientations()
        } else {
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    func makeNextEpisodeButton() -> UIButton {
        let button = UIButton(type: .system)
        button.configuration = IOSAVPlayerControlStyle.configuration(
            imageName: "forward.end.fill",
            title: "Next Episode",
            imagePadding: 8
        )
        IOSAVPlayerControlStyle.applyShadow(to: button)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.alpha = 0
        button.isHidden = true
        button.accessibilityIdentifier = "AVPlayer.NextEpisode"
        button.addAction(UIAction { [weak self] _ in
            self?.requestResolvedNextEpisode()
        }, for: .primaryActionTriggered)
        return button
    }

    func setupNextEpisodeButton() {
        view.addSubview(nextEpisodeButton)
        NSLayoutConstraint.activate([
            nextEpisodeButton.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -24
            ),
            nextEpisodeButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -116
            ),
            nextEpisodeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    func updateNextEpisodeState(position: Double, duration: Double) {
        guard playbackDidStart,
              duration.isFinite,
              duration >= 5,
              position.isFinite,
              case .episode = mediaInfo else {
            hideNextEpisodeButton()
            return
        }
        let enabled = UserDefaults.standard.object(forKey: "showNextEpisodeButton") == nil
            || UserDefaults.standard.bool(forKey: "showNextEpisodeButton")
        guard enabled else {
            hideNextEpisodeButton()
            return
        }
        let savedThreshold = UserDefaults.standard.double(forKey: "nextEpisodeThreshold")
        let threshold = min(max(savedThreshold > 0 ? savedThreshold : 0.90, 0.50), 0.99)
        let progress = min(max(position / duration, 0), 1)
        let resolutionLead = max(0.25, threshold - (duration < 900 ? 0.30 : 0.18))
        if progress >= resolutionLead {
            resolveNextEpisodeIfNeeded()
        }
        if progress >= threshold,
           nextEpisodeTarget != nil || localNextEpisodeFallback != nil {
            showNextEpisodeButton()
        } else {
            hideNextEpisodeButton()
        }
    }

    func resolveNextEpisodeIfNeeded() {
        guard !nextEpisodeResolutionStarted,
              let request = nextEpisodeResolutionRequest() else { return }
        nextEpisodeResolutionStarted = true
        let generation = playbackLoadGeneration
        nextEpisodeResolutionTask = Task { [weak self] in
            let resolution = await NextEpisodeResolver().resolve(for: request)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.playbackLoadGeneration == generation,
                      !self.hasFinalizedPlaybackSession,
                      !self.isHandingOffPlaybackEngine,
                      self.configuredRequest?.url == request.url else { return }
                self.nextEpisodeTarget = nil
                self.localNextEpisodeFallback = nil
                switch resolution {
                case .available(let target):
                    let usesLocalOnlyNextEpisode = request.url.isFileURL
                        && request.onRequestResolvedNextEpisode == nil
                    if usesLocalOnlyNextEpisode {
                        // A local-only callback must never turn a verified E2 prompt into the next
                        // arbitrary downloaded record (for example E10). Only expose the verified
                        // target when that exact file is available.
                        if let localTarget = request.localNextEpisodeFallback,
                           target.episode.seasonNumber == localTarget.seasonNumber,
                           target.episode.episodeNumber == localTarget.episodeNumber {
                            self.nextEpisodeTarget = target
                        }
                    } else {
                        self.nextEpisodeTarget = target
                    }
                case .unavailable:
                    if request.url.isFileURL,
                       request.onRequestNextEpisode != nil,
                       let localTarget = request.localNextEpisodeFallback {
                        self.localNextEpisodeFallback = (
                            localTarget.seasonNumber,
                            localTarget.episodeNumber
                        )
                    }
                case .noAvailableEpisode:
                    break
                }
                self.nextEpisodeResolutionTask = nil
                self.updateNextEpisodeState(
                    position: self.currentPosition,
                    duration: self.currentDuration
                )
            }
        }
    }

    func nextEpisodeResolutionRequest() -> PlaybackRequest? {
        if let configuredRequest { return configuredRequest }
        guard let mediaInfo,
              let url = playbackLaunchContext.flatMap({ URL(string: $0.streamURL) })
                ?? (player?.currentItem?.asset as? AVURLAsset)?.url else { return nil }
        let title: String
        let isAnime: Bool
        switch mediaInfo {
        case .movie:
            return nil
        case .episode(_, _, _, let showTitle, _, let mediaIsAnime):
            title = showTitle ?? ""
            isAnime = mediaIsAnime || episodePlaybackContext?.hasAnimeMediaId == true
        }
        return PlaybackRequest(
            url: url,
            headers: playbackLaunchContext?.headers ?? [:],
            subtitles: playbackLaunchContext?.subtitles ?? [],
            subtitleNames: playbackLaunchContext?.subtitleNames,
            subtitleHeadersByURL: playbackLaunchContext?.subtitleHeadersByURL,
            mediaSelectionIntent: mediaSelectionIntent,
            mediaInfo: mediaInfo,
            episodePlaybackContext: episodePlaybackContext,
            launchContext: playbackLaunchContext,
            title: title,
            isAnime: isAnime,
            originalTMDBSeasonNumber: episodePlaybackContext?.resolvedTMDBSeasonNumber,
            originalTMDBEpisodeNumber: episodePlaybackContext?.resolvedTMDBEpisodeNumber,
            onRequestNextEpisode: onRequestNextEpisode,
            onRequestResolvedNextEpisode: configuredRequest?.onRequestResolvedNextEpisode,
            onPlaybackStartupFailure: onPlaybackStartupFailure
        )
    }

    func showNextEpisodeButton() {
        guard nextEpisodeTarget != nil || localNextEpisodeFallback != nil else { return }
        nextEpisodeVisibilityGeneration &+= 1
        nextEpisodeButton.layer.removeAllAnimations()
        if let target = nextEpisodeTarget {
            nextEpisodeButton.configuration?.title = target.episode.name.isEmpty
                ? "Next Episode"
                : "Next: \(String(target.episode.name.prefix(42)))"
            nextEpisodeButton.accessibilityLabel = "Play next episode, season \(target.episode.seasonNumber), episode \(target.episode.episodeNumber)"
        } else if let localNextEpisodeFallback {
            nextEpisodeButton.configuration?.title = "Next Downloaded Episode"
            nextEpisodeButton.accessibilityLabel = "Play downloaded season \(localNextEpisodeFallback.seasonNumber), episode \(localNextEpisodeFallback.episodeNumber)"
        }
        if !nextEpisodeButton.isHidden, nextEpisodeButton.alpha >= 0.99 { return }
        nextEpisodeButton.isHidden = false
        UIView.animate(withDuration: 0.2) {
            self.nextEpisodeButton.alpha = 1
        }
    }

    func hideNextEpisodeButton() {
        guard !nextEpisodeButton.isHidden || nextEpisodeButton.alpha > 0 else { return }
        nextEpisodeVisibilityGeneration &+= 1
        let generation = nextEpisodeVisibilityGeneration
        nextEpisodeButton.layer.removeAllAnimations()
        UIView.animate(withDuration: 0.15, animations: {
            self.nextEpisodeButton.alpha = 0
        }) { [weak self] _ in
            guard let self, self.nextEpisodeVisibilityGeneration == generation else { return }
            self.nextEpisodeButton.isHidden = true
        }
    }

    func requestResolvedNextEpisode() {
        guard !didRequestNextEpisode,
              !isPictureInPictureActiveOrStarting,
              nextEpisodeTarget != nil || localNextEpisodeFallback != nil else { return }
        didRequestNextEpisode = true
        nextEpisodeButton.isEnabled = false
        if let target = nextEpisodeTarget {
            let prefersLocal = UserDefaults.standard.bool(forKey: "preferDownloadedMedia")
                || configuredRequest?.url.isFileURL == true
            if prefersLocal,
               let resolved = downloadedNextEpisodeRequest(for: target) {
                replacePlaybackFromNextEpisode(with: resolved, target: target)
                return
            }
            presentNextEpisodeSourceSheet(for: target)
            return
        }

        if let coordinate = localNextEpisodeFallback,
           let replacement = downloadedNextEpisodePlaybackRequest(for: coordinate) {
            replaceCurrentPlayback(with: replacement, reason: "next-episode-downloaded")
            return
        }

        didRequestNextEpisode = false
        nextEpisodeButton.isEnabled = true
        mediaControlsController?.showTemporarily()
        Logger.shared.log(
            "NormalPlayer: exact next-episode destination was no longer available",
            type: "Player"
        )
    }

    private func presentNextEpisodeSourceSheet(for target: ResolvedNextEpisodeTarget) {
        guard presentedViewController == nil,
              !hasFinalizedPlaybackSession,
              !hasEndedMediaStatePlaybackLease,
              !isHandingOffPlaybackEngine,
              !isPictureInPictureActiveOrStarting else {
            didRequestNextEpisode = false
            nextEpisodeButton.isEnabled = true
            return
        }

        let selectionID = UUID()
        beginSourceSelection(selectionID)
        let sheet = ModulesSearchResultsSheet(
            mediaTitle: target.mediaTitle,
            seasonTitleOverride: target.seasonTitleOverride,
            originalTitle: target.originalTitle,
            isMovie: false,
            isAnimeContent: target.isAnime,
            selectedEpisode: target.episode,
            tmdbId: target.showID,
            animeSeasonTitle: target.seasonTitleOverride ?? target.mediaTitle,
            posterPath: target.posterURL,
            originalAudioLanguage: configuredRequest?.servicesOriginalAudioLanguage,
            imdbId: target.imdbID ?? configuredRequest?.imdbID,
            originalTMDBSeasonNumber: target.originalTMDBSeasonNumber,
            originalTMDBEpisodeNumber: target.originalTMDBEpisodeNumber,
            specialTitleOnlySearch: target.playbackContext?.titleOnlySearch ?? false,
            episodePlaybackContext: target.playbackContext,
            autoModeOnly: UserDefaults.standard.bool(forKey: "servicesAutoModeEnabled"),
            onResolvedPlaybackRequest: { [weak self] resolved in
                guard let self, self.activeSourceSelectionID == selectionID else { return }
                self.activeSourceSelectionID = nil
                Logger.shared.log("NormalPlayer: received next-episode replacement request", type: "Player")
                self.replacePlaybackFromNextEpisode(with: resolved, target: target)
            },
            onPlaybackSelectionCommitted: { [weak self] in
                self?.fenceOutgoingPlayback(for: selectionID)
            },
            isAnimationGenre16: target.isAnimation
        )
        let host = UIHostingController(rootView: sheet.onDisappear { [weak self] in
            self?.scheduleSourceSelectionCancellation(
                selectionID,
                restoresNextEpisodeControl: true
            )
        })
        present(host, animated: true)
    }

    private func scheduleSourceSelectionCancellation(
        _ selectionID: UUID,
        restoresNextEpisodeControl: Bool
    ) {
        // ModulesSearchResultsSheet dismisses before delivering a resolved request (currently on a
        // short delay). Give that committed callback priority; only invalidate the token when no
        // callback claimed it after the dismissal settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.activeSourceSelectionID == selectionID else { return }
            self.activeSourceSelectionID = nil
            self.restoreOutgoingPlaybackFenceIfNeeded(for: selectionID)
            if restoresNextEpisodeControl {
                self.didRequestNextEpisode = false
                self.nextEpisodeButton.isEnabled = true
            }
        }
    }

    private func downloadedNextEpisodeRequest(
        for target: ResolvedNextEpisodeTarget
    ) -> PlayerResolvedPlaybackRequest? {
        guard let download = DownloadManager.shared.completedEpisodeDownloadItem(
            tmdbId: target.showID,
            seasonNumber: target.episode.seasonNumber,
            episodeNumber: target.episode.episodeNumber,
            playbackContext: target.playbackContext
        ),
        let fileURL = DownloadManager.shared.localFileURL(for: download) else { return nil }

        return PlayerResolvedPlaybackRequest(
            url: fileURL,
            preset: PlayerPreset.presets.first
                ?? PlayerPreset(id: .sdrRec709, title: "Default", summary: "", stream: nil, commands: []),
            headers: [:],
            subtitles: DownloadManager.shared.localSubtitleURL(for: download).map { [$0.absoluteString] },
            subtitleNames: nil,
            mediaInfo: download.mediaInfo,
            imdbId: target.imdbID ?? configuredRequest?.imdbID,
            isAnimeHint: download.isAnime || target.isAnime,
            isAnimationContentHint: target.isAnimation,
            originalTMDBSeasonNumber: target.originalTMDBSeasonNumber,
            originalTMDBEpisodeNumber: target.originalTMDBEpisodeNumber,
            episodePlaybackContext: download.episodePlaybackContext ?? target.playbackContext,
            launchContext: nil
        )
    }

    private func downloadedNextEpisodePlaybackRequest(
        for coordinate: (seasonNumber: Int, episodeNumber: Int)
    ) -> PlaybackRequest? {
        guard let existing = configuredRequest,
              case .episode(let showID, _, _, _, _, _) = mediaInfo,
              let download = DownloadManager.shared.completedEpisodeDownloadItem(
                tmdbId: showID,
                seasonNumber: coordinate.seasonNumber,
                episodeNumber: coordinate.episodeNumber,
                playbackContext: nil
              ),
              let fileURL = DownloadManager.shared.localFileURL(for: download) else { return nil }

        let context = download.episodePlaybackContext
        let followingDownload = nextCompletedDownloadedEpisode(after: download)
        return PlaybackRequest(
            url: fileURL,
            preset: PlayerPreset.presets.first,
            headers: [:],
            subtitles: DownloadManager.shared.localSubtitleURL(for: download).map { [$0.absoluteString] } ?? [],
            mediaSelectionIntent: mediaSelectionIntent,
            mediaInfo: download.mediaInfo,
            imdbID: existing.imdbID,
            episodePlaybackContext: context,
            resumePosition: nil,
            title: download.playerTitleBase,
            subtitle: download.episodeName,
            artworkURL: download.posterURL.flatMap(URL.init(string:)),
            isAnime: download.isAnime || context?.hasAnimeMediaId == true,
            isAnimation: existing.isAnimation,
            originalTMDBSeasonNumber: context?.resolvedTMDBSeasonNumber ?? coordinate.seasonNumber,
            originalTMDBEpisodeNumber: context?.resolvedTMDBEpisodeNumber ?? coordinate.episodeNumber,
            servicesOriginalTitle: existing.servicesOriginalTitle,
            servicesOriginalAudioLanguage: existing.servicesOriginalAudioLanguage,
            onRequestNextEpisode: existing.onRequestNextEpisode,
            onRequestResolvedNextEpisode: existing.onRequestResolvedNextEpisode,
            onPlaybackStartupFailure: nil,
            localNextEpisodeFallback: PlaybackEpisodeCoordinate(
                seasonNumber: followingDownload?.seasonNumber,
                episodeNumber: followingDownload?.episodeNumber
            )
        )
    }

    private func nextCompletedDownloadedEpisode(after current: DownloadItem) -> DownloadItem? {
        let manager = DownloadManager.shared
        let episodes = manager.completedDownloads
            .filter {
                !$0.isMovie
                    && $0.tmdbId == current.tmdbId
                    && $0.seasonNumber != nil
                    && $0.episodeNumber != nil
                    && manager.localFileURL(for: $0) != nil
            }
            .sorted {
                if $0.seasonNumber == $1.seasonNumber {
                    return ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0)
                }
                return ($0.seasonNumber ?? 0) < ($1.seasonNumber ?? 0)
            }
        guard let currentIndex = episodes.firstIndex(where: { $0.id == current.id }) else { return nil }
        let nextIndex = episodes.index(after: currentIndex)
        return nextIndex < episodes.endIndex ? episodes[nextIndex] : nil
    }

}

#endif

#if os(iOS)
extension NormalPlayer: UIAdaptivePresentationControllerDelegate {
    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        !PlayerPlaybackLockSettings.isLocked()
    }

    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        mediaControlsController?.showTemporarily()
    }

    private func presentServicesSheet() {
        guard PlayerServicesButtonSettings.isEnabled(),
              let request = configuredRequest,
              let context = PlayerServicesSelectionContext(request: request),
              presentedViewController == nil,
              !isPictureInPictureActiveOrStarting else {
            mediaControlsController?.showTemporarily()
            return
        }

        let selectionID = UUID()
        beginSourceSelection(selectionID)
        let sheet = ModulesSearchResultsSheet(
            mediaTitle: context.mediaTitle,
            seasonTitleOverride: context.seasonTitleOverride,
            originalTitle: context.originalTitle,
            isMovie: context.isMovie,
            isAnimeContent: context.isAnime,
            selectedEpisode: context.selectedEpisode,
            tmdbId: context.tmdbID,
            animeSeasonTitle: context.animeSeasonTitle,
            posterPath: context.posterPath,
            originalAudioLanguage: context.originalAudioLanguage,
            imdbId: context.imdbID,
            originalTMDBSeasonNumber: context.originalTMDBSeasonNumber,
            originalTMDBEpisodeNumber: context.originalTMDBEpisodeNumber,
            specialTitleOnlySearch: context.specialTitleOnlySearch,
            episodePlaybackContext: context.episodePlaybackContext,
            autoModeOnly: false,
            ignoresAutoMode: true,
            onResolvedPlaybackRequest: { [weak self] resolved in
                guard let self, self.activeSourceSelectionID == selectionID else { return }
                self.activeSourceSelectionID = nil
                Logger.shared.log("NormalPlayer: received Services replacement request", type: "Player")
                self.replacePlaybackFromServices(with: resolved, context: context)
            },
            onPlaybackSelectionCommitted: { [weak self] in
                self?.fenceOutgoingPlayback(for: selectionID)
            },
            isAnimationGenre16: context.isAnimation
        )
        let host = UIHostingController(rootView: sheet.onDisappear { [weak self] in
            self?.scheduleSourceSelectionCancellation(
                selectionID,
                restoresNextEpisodeControl: false
            )
        })
        present(host, animated: true)
    }

    private var episodeBrowserButtonEnabled: Bool {
        if UserDefaults.standard.object(forKey: "showEpisodeBrowserButton") == nil {
            let legacy = UserDefaults.standard.object(forKey: "showVLCEpisodeBrowserButton") == nil
                ? true
                : UserDefaults.standard.bool(forKey: "showVLCEpisodeBrowserButton")
            UserDefaults.standard.set(legacy, forKey: "showEpisodeBrowserButton")
        }
        return UserDefaults.standard.bool(forKey: "showEpisodeBrowserButton")
    }

    private func makeEpisodeBrowserSeed() -> PlayerEpisodeBrowserSeed? {
        guard case .episode(
            let showID,
            let seasonNumber,
            let episodeNumber,
            let showTitle,
            let showPosterURL,
            let mediaIsAnime
        ) = mediaInfo else { return nil }
        let requestTitle = configuredRequest?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = showTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = [resolvedTitle, requestTitle]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty }) ?? "Show"
        return PlayerEpisodeBrowserSeed(
            showId: showID,
            showTitle: title,
            showPosterURL: showPosterURL ?? configuredRequest?.artworkURL?.absoluteString,
            currentSeasonNumber: seasonNumber,
            currentEpisodeNumber: episodeNumber,
            isAnime: mediaIsAnime
                || configuredRequest?.isAnime == true
                || episodePlaybackContext?.hasAnimeMediaId == true,
            imdbId: configuredRequest?.imdbID,
            currentPlaybackContext: episodePlaybackContext
        )
    }

    private func toggleEpisodeBrowser() {
        guard episodeBrowserButtonEnabled,
              !isPictureInPictureActiveOrStarting,
              presentedViewController == nil,
              let seed = makeEpisodeBrowserSeed() else {
            mediaControlsController?.showTemporarily()
            return
        }
        if episodeBrowserHostingController != nil {
            dismissEpisodeBrowser(animated: true)
            return
        }
        mediaControlsController?.hideImmediately()
        let drawer = PlayerEpisodeBrowserDrawer(
            seed: seed,
            onClose: { [weak self] in self?.dismissEpisodeBrowser(animated: true) },
            onEpisodeSelected: { [weak self] item in self?.handleEpisodeBrowserSelection(item) }
        )
        let host = UIHostingController(rootView: AnyView(drawer))
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        host.didMove(toParent: self)
        episodeBrowserHostingController = host
        view.bringSubviewToFront(host.view)
    }

    private func dismissEpisodeBrowser(animated: Bool) {
        guard let host = episodeBrowserHostingController else { return }
        episodeBrowserHostingController = nil
        let remove = {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
        guard animated else {
            remove()
            return
        }
        UIView.animate(withDuration: 0.2, animations: {
            host.view.alpha = 0
        }) { _ in remove() }
    }

    private func handleEpisodeBrowserSelection(_ item: PlayerEpisodeBrowserItem) {
        guard !item.isCurrent, presentedViewController == nil else { return }
        dismissEpisodeBrowser(animated: false)
        if UserDefaults.standard.bool(forKey: "preferDownloadedMedia"),
           let resolved = downloadedEpisodeBrowserRequest(for: item) {
            replacePlaybackFromEpisodeBrowser(with: resolved, item: item)
            return
        }

        let selectionID = UUID()
        beginSourceSelection(selectionID)
        let sheet = ModulesSearchResultsSheet(
            mediaTitle: item.mediaTitle,
            seasonTitleOverride: item.seasonTitleOverride,
            originalTitle: item.originalTitle,
            isMovie: false,
            isAnimeContent: item.isAnime,
            selectedEpisode: item.episode,
            tmdbId: item.showId,
            animeSeasonTitle: item.animeSeasonTitle,
            posterPath: item.posterURL ?? item.showPosterURL,
            originalAudioLanguage: item.originalAudioLanguage,
            imdbId: item.imdbId,
            originalTMDBSeasonNumber: item.originalTMDBSeasonNumber,
            originalTMDBEpisodeNumber: item.originalTMDBEpisodeNumber,
            specialTitleOnlySearch: item.playbackContext?.titleOnlySearch ?? false,
            episodePlaybackContext: item.playbackContext,
            autoModeOnly: UserDefaults.standard.bool(forKey: "servicesAutoModeEnabled"),
            onResolvedPlaybackRequest: { [weak self] resolved in
                guard let self, self.activeSourceSelectionID == selectionID else { return }
                self.activeSourceSelectionID = nil
                Logger.shared.log("NormalPlayer: received episode-browser replacement request", type: "Player")
                self.replacePlaybackFromEpisodeBrowser(with: resolved, item: item)
            },
            onPlaybackSelectionCommitted: { [weak self] in
                self?.fenceOutgoingPlayback(for: selectionID)
            },
            isAnimationGenre16: configuredRequest?.isAnimation ?? false
        )
        let host = UIHostingController(rootView: sheet.onDisappear { [weak self] in
            self?.scheduleSourceSelectionCancellation(
                selectionID,
                restoresNextEpisodeControl: false
            )
        })
        present(host, animated: true)
    }

    private func downloadedEpisodeBrowserRequest(
        for item: PlayerEpisodeBrowserItem
    ) -> PlayerResolvedPlaybackRequest? {
        guard let downloadItem = item.downloadItem,
              let fileURL = DownloadManager.shared.localFileURL(for: downloadItem) else { return nil }
        return PlayerResolvedPlaybackRequest(
            url: fileURL,
            preset: PlayerPreset.presets.first
                ?? PlayerPreset(id: .sdrRec709, title: "Default", summary: "", stream: nil, commands: []),
            headers: [:],
            subtitles: DownloadManager.shared.localSubtitleURL(for: downloadItem).map { [$0.absoluteString] },
            subtitleNames: nil,
            mediaInfo: downloadItem.mediaInfo,
            imdbId: item.imdbId,
            isAnimeHint: downloadItem.isAnime,
            isAnimationContentHint: configuredRequest?.isAnimation,
            originalTMDBSeasonNumber: item.originalTMDBSeasonNumber,
            originalTMDBEpisodeNumber: item.originalTMDBEpisodeNumber,
            episodePlaybackContext: downloadItem.episodePlaybackContext ?? item.playbackContext,
            launchContext: nil
        )
    }

    private func replacePlaybackFromEpisodeBrowser(
        with resolved: PlayerResolvedPlaybackRequest,
        item: PlayerEpisodeBrowserItem
    ) {
        guard let existing = configuredRequest else { return }
        let followingDownload = resolved.url.isFileURL
            ? item.downloadItem.flatMap(nextCompletedDownloadedEpisode(after:))
            : nil
        let replacement = PlaybackRequest(
            url: resolved.url,
            preset: resolved.preset,
            headers: resolved.headers ?? [:],
            subtitles: resolved.subtitles ?? [],
            subtitleNames: resolved.subtitleNames,
            subtitleHeadersByURL: resolved.subtitleHeadersByURL,
            mediaSelectionIntent: mediaSelectionIntent,
            mediaInfo: resolved.mediaInfo ?? .episode(
                showId: item.showId,
                seasonNumber: item.episode.seasonNumber,
                episodeNumber: item.episode.episodeNumber,
                showTitle: item.showTitle,
                showPosterURL: item.showPosterURL,
                isAnime: item.isAnime
            ),
            imdbID: resolved.imdbId ?? item.imdbId,
            episodePlaybackContext: resolved.episodePlaybackContext ?? item.playbackContext,
            launchContext: resolved.launchContext,
            resumePosition: nil,
            title: item.showTitle,
            subtitle: item.displayTitle,
            artworkURL: item.imageURL.flatMap(URL.init(string:)),
            isAnime: resolved.isAnimeHint
                || item.isAnime
                || existing.isAnime
                || (resolved.episodePlaybackContext ?? item.playbackContext)?.hasAnimeMediaId == true,
            isAnimation: resolved.isAnimationContentHint ?? existing.isAnimation,
            originalTMDBSeasonNumber: resolved.originalTMDBSeasonNumber
                ?? (resolved.episodePlaybackContext ?? item.playbackContext)?.resolvedTMDBSeasonNumber
                ?? item.originalTMDBSeasonNumber,
            originalTMDBEpisodeNumber: resolved.originalTMDBEpisodeNumber
                ?? (resolved.episodePlaybackContext ?? item.playbackContext)?.resolvedTMDBEpisodeNumber
                ?? item.originalTMDBEpisodeNumber,
            servicesOriginalTitle: item.originalTitle,
            servicesOriginalAudioLanguage: item.originalAudioLanguage,
            onRequestNextEpisode: existing.onRequestNextEpisode,
            onRequestResolvedNextEpisode: existing.onRequestResolvedNextEpisode,
            onPlaybackStartupFailure: nil,
            localNextEpisodeFallback: PlaybackEpisodeCoordinate(
                seasonNumber: followingDownload?.seasonNumber,
                episodeNumber: followingDownload?.episodeNumber
            )
        )
        replaceCurrentPlayback(with: replacement, reason: "episode-browser")
    }

    private func replacePlaybackFromNextEpisode(
        with resolved: PlayerResolvedPlaybackRequest,
        target: ResolvedNextEpisodeTarget
    ) {
        guard let existing = configuredRequest else { return }
        let existingShowTitle: String? = {
            guard case .episode(_, _, _, let title, _, _) = existing.mediaInfo else { return nil }
            return title
        }()
        let showTitle = existingShowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedContext = resolved.episodePlaybackContext ?? target.playbackContext
        let currentDownload: DownloadItem? = resolved.url.isFileURL
            ? DownloadManager.shared.completedEpisodeDownloadItem(
                tmdbId: target.showID,
                seasonNumber: target.episode.seasonNumber,
                episodeNumber: target.episode.episodeNumber,
                playbackContext: resolvedContext
              )
            : nil
        let followingDownload = currentDownload.flatMap(nextCompletedDownloadedEpisode(after:))
        let replacement = PlaybackRequest(
            url: resolved.url,
            preset: resolved.preset,
            headers: resolved.headers ?? [:],
            subtitles: resolved.subtitles ?? [],
            subtitleNames: resolved.subtitleNames,
            subtitleHeadersByURL: resolved.subtitleHeadersByURL,
            mediaSelectionIntent: mediaSelectionIntent,
            mediaInfo: resolved.mediaInfo ?? .episode(
                showId: target.showID,
                seasonNumber: target.episode.seasonNumber,
                episodeNumber: target.episode.episodeNumber,
                showTitle: showTitle?.isEmpty == false ? showTitle : target.mediaTitle,
                showPosterURL: target.posterURL,
                isAnime: target.isAnime
            ),
            imdbID: resolved.imdbId ?? target.imdbID ?? existing.imdbID,
            episodePlaybackContext: resolvedContext,
            launchContext: resolved.launchContext,
            resumePosition: nil,
            title: target.mediaTitle,
            subtitle: target.episode.name,
            artworkURL: (target.episode.fullStillURL ?? target.posterURL).flatMap(URL.init(string:)),
            isAnime: resolved.isAnimeHint
                || target.isAnime
                || existing.isAnime
                || resolvedContext?.hasAnimeMediaId == true,
            isAnimation: resolved.isAnimationContentHint ?? target.isAnimation,
            originalTMDBSeasonNumber: resolved.originalTMDBSeasonNumber
                ?? resolvedContext?.resolvedTMDBSeasonNumber
                ?? target.originalTMDBSeasonNumber,
            originalTMDBEpisodeNumber: resolved.originalTMDBEpisodeNumber
                ?? resolvedContext?.resolvedTMDBEpisodeNumber
                ?? target.originalTMDBEpisodeNumber,
            servicesOriginalTitle: target.originalTitle ?? existing.servicesOriginalTitle,
            servicesOriginalAudioLanguage: existing.servicesOriginalAudioLanguage,
            onRequestNextEpisode: existing.onRequestNextEpisode,
            onRequestResolvedNextEpisode: existing.onRequestResolvedNextEpisode,
            // The launch-site recovery callback owns the prior episode/source sheet. If both
            // players reject this new episode, keep failure UI in this player instead of allowing
            // a stale callback to reopen the previous episode behind it.
            onPlaybackStartupFailure: nil,
            localNextEpisodeFallback: PlaybackEpisodeCoordinate(
                seasonNumber: followingDownload?.seasonNumber,
                episodeNumber: followingDownload?.episodeNumber
            )
        )
        replaceCurrentPlayback(with: replacement, reason: "next-episode")
    }

    private func replacePlaybackFromServices(
        with resolved: PlayerResolvedPlaybackRequest,
        context: PlayerServicesSelectionContext
    ) {
        guard let existing = configuredRequest else { return }

        let replacement = PlaybackRequest(
            url: resolved.url,
            preset: resolved.preset,
            headers: resolved.headers ?? [:],
            subtitles: resolved.subtitles ?? [],
            subtitleNames: resolved.subtitleNames,
            subtitleHeadersByURL: resolved.subtitleHeadersByURL,
            mediaSelectionIntent: mediaSelectionIntent,
            mediaInfo: resolved.mediaInfo ?? existing.mediaInfo,
            imdbID: resolved.imdbId ?? existing.imdbID,
            episodePlaybackContext: resolved.episodePlaybackContext ?? existing.episodePlaybackContext,
            launchContext: resolved.launchContext,
            resumePosition: currentPlaybackPositionForReplacement() ?? existing.resumePosition,
            title: context.mediaTitle,
            subtitle: existing.subtitle,
            artworkURL: existing.artworkURL,
            isAnime: resolved.isAnimeHint
                || existing.isAnime
                || existing.episodePlaybackContext?.hasAnimeMediaId == true,
            isAnimation: resolved.isAnimationContentHint ?? existing.isAnimation,
            originalTMDBSeasonNumber: resolved.originalTMDBSeasonNumber
                ?? (resolved.episodePlaybackContext ?? existing.episodePlaybackContext)?.resolvedTMDBSeasonNumber
                ?? existing.originalTMDBSeasonNumber,
            originalTMDBEpisodeNumber: resolved.originalTMDBEpisodeNumber
                ?? (resolved.episodePlaybackContext ?? existing.episodePlaybackContext)?.resolvedTMDBEpisodeNumber
                ?? existing.originalTMDBEpisodeNumber,
            servicesOriginalTitle: existing.servicesOriginalTitle,
            servicesOriginalAudioLanguage: existing.servicesOriginalAudioLanguage,
            onRequestNextEpisode: existing.onRequestNextEpisode,
            onRequestResolvedNextEpisode: existing.onRequestResolvedNextEpisode,
            onPlaybackStartupFailure: existing.onPlaybackStartupFailure,
            localNextEpisodeFallback: existing.localNextEpisodeFallback
        )

        replaceCurrentPlayback(with: replacement, reason: "services")
    }

    private func currentPlaybackPositionForReplacement() -> Double? {
        let position = player?.currentTime().seconds ?? .nan
        guard position.isFinite, position > 0 else { return nil }
        return position
    }

    private func hasSameMediaIdentity(_ lhs: MediaInfo?, _ rhs: MediaInfo?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case let (.movie(leftID, _, _, _), .movie(rightID, _, _, _)):
            return leftID == rightID
        case let (
            .episode(leftShowID, leftSeason, leftEpisode, _, _, _),
            .episode(rightShowID, rightSeason, rightEpisode, _, _, _)
        ):
            return leftShowID == rightShowID
                && leftSeason == rightSeason
                && leftEpisode == rightEpisode
        default:
            return false
        }
    }

    /// Services and episode pickers resolve while their SwiftUI host is dismissing. Drain only
    /// that child presentation, then replace the AVPlayerItem in this controller. Keeping the
    /// controller alive preserves PiP, gestures, orientation lock, scene ownership, and the single
    /// media-state playback lease.
    private func replaceCurrentPlayback(with replacement: PlaybackRequest, reason: String) {
        guard !isReplacingCurrentPlayback,
              !hasFinalizedPlaybackSession,
              !hasEndedMediaStatePlaybackLease,
              !isHandingOffPlaybackEngine,
              !isPictureInPictureActiveOrStarting,
              viewIfLoaded?.window != nil else {
            restoreOutgoingPlaybackFenceIfNeeded()
            Logger.shared.log(
                "NormalPlayer: ignored stale or unavailable replacement reason=\(reason)",
                type: "Player"
            )
            return
        }

        playbackReplacementGeneration &+= 1
        let generation = playbackReplacementGeneration
        let selectionController = presentedViewController
        activeSourceSelectionID = nil
        isReplacingCurrentPlayback = true
        Logger.shared.log(
            "NormalPlayer: beginning in-place playback replacement reason=\(reason)",
            type: "Player"
        )
        finishInPlaceReplacement(
            replacement,
            reason: reason,
            generation: generation,
            selectionController: selectionController,
            retryCount: 0
        )
    }

    private func finishInPlaceReplacement(
        _ replacement: PlaybackRequest,
        reason: String,
        generation: Int,
        selectionController: UIViewController?,
        retryCount: Int
    ) {
        guard isReplacingCurrentPlayback,
              playbackReplacementGeneration == generation,
              !hasFinalizedPlaybackSession,
              !hasEndedMediaStatePlaybackLease,
              !isHandingOffPlaybackEngine,
              !isPictureInPictureActiveOrStarting,
              viewIfLoaded?.window != nil else {
            cancelInPlaceReplacement(reason: "lifecycle changed while waiting reason=\(reason)")
            return
        }

        if let presented = presentedViewController {
            guard selectionController === presented else {
                cancelInPlaceReplacement(reason: "another controller replaced the source picker reason=\(reason)")
                return
            }
            if !presented.isBeingDismissed {
                presented.dismiss(animated: false)
            }
            guard retryCount < 120 else {
                cancelInPlaceReplacement(reason: "source picker dismissal timed out reason=\(reason)")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.finishInPlaceReplacement(
                    replacement,
                    reason: reason,
                    generation: generation,
                    selectionController: selectionController,
                    retryCount: retryCount + 1
                )
            }
            return
        }

        applyInPlacePlaybackReplacement(replacement, reason: reason, generation: generation)
    }

    private func cancelInPlaceReplacement(reason: String) {
        guard isReplacingCurrentPlayback else { return }
        isReplacingCurrentPlayback = false
        restoreOutgoingPlaybackFenceIfNeeded()
        didRequestNextEpisode = false
        nextEpisodeButton.isEnabled = true
        mediaControlsController?.showTemporarily()
        Logger.shared.log("NormalPlayer: cancelled in-place replacement \(reason)", type: "Player")
    }

    private func applyInPlacePlaybackReplacement(
        _ replacement: PlaybackRequest,
        reason: String,
        generation: Int
    ) {
        guard playbackReplacementGeneration == generation,
              isReplacingCurrentPlayback,
              !hasFinalizedPlaybackSession,
              !hasEndedMediaStatePlaybackLease,
              !isHandingOffPlaybackEngine,
              !isPictureInPictureActiveOrStarting,
              viewIfLoaded?.window != nil else {
            cancelInPlaceReplacement(reason: "commit became stale reason=\(reason)")
            return
        }

        let outgoingMediaInfo = mediaInfo
        let outgoingPlaybackContext = episodePlaybackContext
        let outgoingPlaybackDidStart = playbackDidStart
        let changesMedia = !hasSameMediaIdentity(outgoingMediaInfo, replacement.mediaInfo)
        let preferredEngine = PlaybackEngine.selected

        endHoldSpeed()
        player?.pause()
        persistCurrentProgressForAccountBoundary()
        ProgressManager.shared.flushPendingSave()
        if changesMedia, let outgoingMediaInfo {
            ProgressManager.shared.syncTraktProgressOnPlaybackClose(
                for: outgoingMediaInfo,
                playbackContext: outgoingPlaybackContext,
                played: outgoingPlaybackDidStart
            )
        }

        if preferredEngine == .mpv
            || PlaybackCoordinator.shared.shouldHandOffAVPlayerDirectly(for: replacement) {
            isReplacingCurrentPlayback = false
            clearOutgoingPlaybackFence()
            let handoffReason = preferredEngine == .mpv
                ? "The saved playback engine preference is MPV."
                : "AVPlayer does not support this stream container."
            Logger.shared.log(
                "NormalPlayer: handing selected stream to Molten preference=\(preferredEngine.rawValue) extension=.\(replacement.url.pathExtension.lowercased()) reason=\(reason)",
                type: "Player"
            )
            PlaybackCoordinator.shared.handOffAVPlayerToMolten(
                self,
                request: replacement,
                reason: handoffReason
            )
            return
        }

        // Invalidate queued callbacks before removing observers or changing metadata. The progress
        // observer is removed before install so the new item's timestamps cannot be written against
        // the outgoing episode.
        clearOutgoingPlaybackFence()
        playbackLoadGeneration &+= 1
        tearDownPlaybackItemObservers()
        dismissEpisodeBrowser(animated: false)

        playbackDidStart = false
        playbackFailureHandled = false
        slowProbeCount = 0
        startupLastObservedTime = nil
        startupProgressAdvanceCount = 0
        currentPosition = 0
        currentDuration = 0
        pendingPlaybackFailureAlert = nil
        isHandingOffPlaybackEngine = false
        isCoordinatorEngineFallback = false
        automaticallyFallsBackToMolten = false
        onAutomaticPlaybackFallback = nil
        nextEpisodeTarget = nil
        localNextEpisodeFallback = nil
        nextEpisodeResolutionStarted = false
        didRequestNextEpisode = false
        nextEpisodeVisibilityGeneration &+= 1
        nextEpisodeButton.layer.removeAllAnimations()
        nextEpisodeButton.isEnabled = true
        nextEpisodeButton.alpha = 0
        nextEpisodeButton.isHidden = true

        // AVPlayer.status is terminal after some decoder failures. A fresh AVPlayer is safe here:
        // the persistent AVPlayerLayer and PiP content source remain unchanged.
        if player?.status == .failed {
            player = nil
        }
        configure(with: replacement)
        beginMediaStatePlaybackLeaseIfNeeded()
        if preferredEngine == .automatic {
            PlaybackCoordinator.shared.armMoltenFallback(for: self, request: replacement)
        }

        setupMediaControls()
        if let mediaInfo {
            setupProgressTracking(for: mediaInfo)
        }
        setupPlaybackStartupMonitoring()
        setupItemNotifications()
        setupInterfaceTimeObserver()
        scheduleMediaSelection()
        applyPlaybackLockState(capturingOrientationIfNeeded: false)
        view.bringSubviewToFront(nextEpisodeButton)

        isReplacingCurrentPlayback = false
        Logger.shared.log(
            "NormalPlayer: completed in-place playback replacement reason=\(reason) preference=\(preferredEngine.rawValue) moltenFallback=\(preferredEngine == .automatic)",
            type: "Player"
        )
        playAtDefaultSpeed()
    }

    /// A resolved source is delivered after the sheet dismisses. Invalidate callbacks belonging
    /// to the outgoing item as soon as the user commits the source so its startup timeout or
    /// failure cannot hand the old request to Molten during that gap. The item itself keeps
    /// playing until the replacement request arrives.
    private func fenceOutgoingPlayback(for selectionID: UUID) {
        guard activeSourceSelectionID == selectionID,
              !hasFinalizedPlaybackSession,
              !hasEndedMediaStatePlaybackLease,
              !isHandingOffPlaybackEngine,
              let item = player?.currentItem else { return }
        if committedSourceSelectionID == selectionID { return }

        committedSourceSelectionID = selectionID
        committedSourceSelectionItem = item
        playbackLoadGeneration &+= 1
        if let startupTimeObserverToken {
            player?.removeTimeObserver(startupTimeObserverToken)
            self.startupTimeObserverToken = nil
        }
        startupWorkItem?.cancel()
        startupWorkItem = nil
        startupProbeTask?.cancel()
        startupProbeTask = nil
        postStartStallWorkItem?.cancel()
        postStartStallWorkItem = nil
        mediaSelectionTask?.cancel()
        mediaSelectionTask = nil
        mediaSelectionOperationGeneration &+= 1
        isApplyingMediaSelection = false
        Logger.shared.log(
            "NormalPlayer: fenced outgoing AV item for committed source selection",
            type: "Player"
        )
    }

    private func beginSourceSelection(_ selectionID: UUID) {
        // A new explicit picker wins over an older delayed callback. If the older choice had
        // already fenced the current item, re-arm that unchanged item until this new picker also
        // commits; cancelling the latest picker must not silently leave failure handling disabled.
        restoreOutgoingPlaybackFenceIfNeeded()
        activeSourceSelectionID = selectionID
    }

    private func clearOutgoingPlaybackFence() {
        committedSourceSelectionID = nil
        committedSourceSelectionItem = nil
    }

    /// If a committed sheet never delivers its resolved request, resume monitoring the unchanged
    /// item instead of leaving it alive without failure handling. A plain sheet cancellation never
    /// creates a fence and therefore does not disturb current playback at all.
    private func restoreOutgoingPlaybackFenceIfNeeded(for selectionID: UUID? = nil) {
        guard let committedID = committedSourceSelectionID,
              selectionID == nil || selectionID == committedID else { return }
        let item = committedSourceSelectionItem
        clearOutgoingPlaybackFence()
        guard !hasFinalizedPlaybackSession,
              !hasEndedMediaStatePlaybackLease,
              !isHandingOffPlaybackEngine,
              viewIfLoaded?.window != nil,
              let item,
              player?.currentItem === item else { return }

        setupPlaybackStartupMonitoring()
        setupItemNotifications()
        setupInterfaceTimeObserver()
        scheduleMediaSelection()
        Logger.shared.log(
            "NormalPlayer: restored outgoing AV item after source selection cancellation",
            type: "Player"
        )
    }
}
#endif

#if os(iOS)
private final class IOSAVPlayerSurfaceView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }
}

private final class IOSAVPlayerGradientView: UIView {
    enum Edge {
        case top
        case bottom
    }

    private let edge: Edge
    private var gradientLayer: CAGradientLayer { layer as! CAGradientLayer }

    override class var layerClass: AnyClass { CAGradientLayer.self }

    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        switch edge {
        case .top:
            gradientLayer.colors = [
                UIColor.black.withAlphaComponent(0.72).cgColor,
                UIColor.black.withAlphaComponent(0.32).cgColor,
                UIColor.clear.cgColor
            ]
        case .bottom:
            gradientLayer.colors = [
                UIColor.clear.cgColor,
                UIColor.black.withAlphaComponent(0.34).cgColor,
                UIColor.black.withAlphaComponent(0.76).cgColor
            ]
        }
    }

    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
private final class IOSAVPlayerMediaControlsController {
    private struct Candidate {
        let url: URL
        let title: String
        let languageTag: String?
        let headers: [String: String]
    }

    var onSelectionChanged: ((_ externalSelected: Bool, _ allowEmbeddedFallback: Bool) -> Void)?
    var onEmbeddedSubtitleSelectionChanged: ((_ languageTag: String?) -> Void)?
    var onAudioSelectionChanged: ((_ languageTag: String?) -> Void)?
    var onClose: (() -> Void)?
    var onPlaybackLockToggle: (() -> Void)?
    var onPictureInPicture: (() -> Void)?
    var onServices: (() -> Void)?
    var onEpisodeBrowser: (() -> Void)?
    var hasSelectedSubtitle: Bool { selectedIndex != nil }
    var selectedExternalSubtitleLanguage: String? {
        guard let selectedIndex, candidates.indices.contains(selectedIndex) else { return nil }
        return candidates[selectedIndex].languageTag
    }

    private weak var player: AVPlayer?
    private let candidates: [Candidate]
    private let label = UILabel()
    private let topGradient = IOSAVPlayerGradientView(edge: .top)
    private let bottomGradient = IOSAVPlayerGradientView(edge: .bottom)
    private let topRail = UIVisualEffectView(effect: nil)
    private let controlRail = UIVisualEffectView(effect: nil)
    private let transportContainer = UIView()
    private let closeButton = UIButton(type: .system)
    private let playbackLockButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let subtitleButton = UIButton(type: .system)
    private let audioButton = UIButton(type: .system)
    private let pictureInPictureButton = UIButton(type: .system)
    private let servicesButton = UIButton(type: .system)
    private let episodeBrowserButton = UIButton(type: .system)
    private let rewindButton = UIButton(type: .system)
    private let playPauseButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let timelineSlider = UISlider()
    private let currentTimeLabel = UILabel()
    private let durationLabel = UILabel()
    private var subtitleBottomConstraint: NSLayoutConstraint?
    private var isScrubbing = false
    private var wasPlayingBeforeScrub = false
    private var selectedIndex: Int?
    private var cues: [TVExternalSubtitleCue] = []
    private var download: TVBoundedSubtitleDownload?
    private var localLoadTask: Task<Void, Never>?
    private var localLoadGeneration = UUID()
    private var mediaOptionsTask: Task<Void, Never>?
    private var mediaOptionsLoadGeneration = 0
    private var visibilityWorkItem: DispatchWorkItem?
    private var embeddedSubtitleGroup: AVMediaSelectionGroup?
    private var audioGroup: AVMediaSelectionGroup?
    private var isLoadingMediaOptions = true

    init(
        subtitleURLs: [String],
        subtitleNames: [String]?,
        subtitleHeadersByURL: [String: [String: String]]?,
        selectionIntent: PlaybackMediaSelectionIntent,
        player: AVPlayer,
        overlayView: UIView,
        title: String
    ) {
        self.player = player
        candidates = Self.makeCandidates(
            subtitleURLs: subtitleURLs,
            subtitleNames: subtitleNames,
            subtitleHeadersByURL: subtitleHeadersByURL
        )
        configureOverlay(in: overlayView, title: title)
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
        }
        rebuildMenus()
        refreshMediaOptions()
        if let selectedIndex {
            loadCandidate(at: selectedIndex, notify: false)
        }
    }

    func update(time: Double) {
        updateTransport(time: time)
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

    func disableForNativeSelection() {
        clearExternalSelection()
        rebuildMenus()
    }

    func refreshMediaOptions() {
        mediaOptionsTask?.cancel()
        mediaOptionsLoadGeneration &+= 1
        let generation = mediaOptionsLoadGeneration
        embeddedSubtitleGroup = nil
        audioGroup = nil
        isLoadingMediaOptions = true
        rebuildMenus()
        guard let item = player?.currentItem else {
            isLoadingMediaOptions = false
            rebuildMenus()
            return
        }

        mediaOptionsTask = Task { @MainActor [weak self, weak item] in
            guard let self, let item else { return }
            let subtitleGroup = try? await item.asset.loadMediaSelectionGroup(for: .legible)
            guard !Task.isCancelled,
                  self.mediaOptionsLoadGeneration == generation,
                  self.player?.currentItem === item else { return }
            let audioGroup = try? await item.asset.loadMediaSelectionGroup(for: .audible)
            guard !Task.isCancelled,
                  self.mediaOptionsLoadGeneration == generation,
                  self.player?.currentItem === item else { return }
            self.embeddedSubtitleGroup = subtitleGroup
            self.audioGroup = audioGroup
            self.isLoadingMediaOptions = false
            self.mediaOptionsTask = nil

            // A forced-caption group cannot be disabled. Drop a custom external overlay if one
            // was optimistically selected before the HLS media-selection group became available,
            // otherwise both subtitle systems would render at once.
            if subtitleGroup?.allowsEmptySelection == false, self.selectedIndex != nil {
                self.clearExternalSelection()
                self.onSelectionChanged?(false, true)
            }
            self.rebuildMenus()
        }
    }

    func refreshSelectionState() {
        rebuildMenus()
    }

    func invalidate() {
        cancelLoads()
        visibilityWorkItem?.cancel()
        visibilityWorkItem = nil
        mediaOptionsTask?.cancel()
        mediaOptionsTask = nil
        mediaOptionsLoadGeneration &+= 1
        selectedIndex = nil
        cues = []
        embeddedSubtitleGroup = nil
        audioGroup = nil
        label.removeFromSuperview()
        topGradient.removeFromSuperview()
        bottomGradient.removeFromSuperview()
        topRail.removeFromSuperview()
        transportContainer.removeFromSuperview()
        controlRail.removeFromSuperview()
    }

    var controlsAreVisible: Bool {
        !topRail.isHidden && topRail.alpha > 0.01
    }

    func finishSurfaceTap(startedWithControlsVisible: Bool) {
        if startedWithControlsVisible {
            hideControls()
        } else {
            // Touch-down already revealed the overlay. Refresh the normal auto-hide deadline
            // without making the user wait for double-tap disambiguation to see any feedback.
            showTemporarily()
        }
    }

    func showTemporarily() {
        visibilityWorkItem?.cancel()
        topGradient.isHidden = false
        bottomGradient.isHidden = false
        topRail.isHidden = false
        transportContainer.isHidden = false
        controlRail.isHidden = false
        subtitleBottomConstraint?.constant = min(Self.subtitleBottomConstant, -122)
        UIView.animate(
            withDuration: 0.2,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.topGradient.alpha = 1
            self.bottomGradient.alpha = 1
            self.topRail.alpha = 1
            self.transportContainer.alpha = 1
            self.controlRail.alpha = 1
            self.label.superview?.layoutIfNeeded()
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.hideControls()
        }
        visibilityWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: workItem)
    }

    private func hideControls() {
        visibilityWorkItem?.cancel()
        visibilityWorkItem = nil
        UIView.animate(
            withDuration: 0.2,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.topGradient.alpha = 0
            self.bottomGradient.alpha = 0
            self.topRail.alpha = 0
            self.transportContainer.alpha = 0
            self.controlRail.alpha = 0
        } completion: { [weak self] _ in
            guard let self, self.controlRail.alpha == 0 else { return }
            self.topGradient.isHidden = true
            self.bottomGradient.isHidden = true
            self.topRail.isHidden = true
            self.transportContainer.isHidden = true
            self.controlRail.isHidden = true
            self.subtitleBottomConstraint?.constant = Self.subtitleBottomConstant
        }
    }

    func setPictureInPictureAvailable(_ available: Bool) {
        pictureInPictureButton.isEnabled = available
        pictureInPictureButton.alpha = available ? 1 : 0.42
    }

    func setServicesAvailable(_ available: Bool) {
        servicesButton.isHidden = !available
        servicesButton.isEnabled = available
    }

    func setEpisodeBrowserAvailable(_ available: Bool) {
        episodeBrowserButton.isHidden = !available
        episodeBrowserButton.isEnabled = available
    }

    func hideImmediately() {
        visibilityWorkItem?.cancel()
        visibilityWorkItem = nil
        topGradient.isHidden = true
        bottomGradient.isHidden = true
        topRail.isHidden = true
        transportContainer.isHidden = true
        controlRail.isHidden = true
    }

    func setPlaybackLocked(_ locked: Bool) {
        let isAvailable = PlayerPlaybackLockSettings.isEnabled()
        playbackLockButton.isHidden = !isAvailable
        playbackLockButton.isEnabled = isAvailable
        playbackLockButton.setImage(
            UIImage(systemName: locked ? "lock.fill" : "lock.open"),
            for: .normal
        )
        playbackLockButton.accessibilityLabel = locked ? "Unlock player" : "Lock player"
        playbackLockButton.accessibilityHint = locked
            ? "Allows orientation changes and closing the video"
            : "Locks the current orientation and prevents closing the video"
        playbackLockButton.accessibilityValue = locked ? "Locked" : "Unlocked"
        closeButton.isEnabled = !locked
        closeButton.alpha = locked ? 0.35 : 1.0
        closeButton.accessibilityHint = locked ? "Unlock the player before closing" : nil
    }

    private func configureOverlay(in overlay: UIView, title: String) {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 4
        label.textAlignment = .center
        label.backgroundColor = UserDefaults.standard.bool(forKey: "subtitles_closedCaptionBackground")
            ? UIColor.black.withAlphaComponent(0.72)
            : .clear
        label.layer.cornerRadius = 8
        label.layer.masksToBounds = true
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.72
        label.isHidden = true
        label.accessibilityTraits = .staticText
        overlay.addSubview(label)

        configureChromeButton(
            closeButton,
            imageName: "xmark",
            accessibilityLabel: "Close player"
        ) { [weak self] in
            self?.onClose?()
        }

        configureChromeButton(
            playbackLockButton,
            imageName: "lock.open",
            accessibilityLabel: "Lock player"
        ) { [weak self] in
            self?.onPlaybackLockToggle?()
        }
        setPlaybackLocked(PlayerPlaybackLockSettings.isLocked())

        configureMenuButton(
            subtitleButton,
            imageName: "captions.bubble",
            accessibilityLabel: "Subtitles",
            accessibilityIdentifier: "AVPlayer.Subtitles"
        )
        configureMenuButton(
            audioButton,
            imageName: "speaker.wave.2.fill",
            accessibilityLabel: "Audio tracks",
            accessibilityIdentifier: "AVPlayer.Audio"
        )
        configureChromeButton(
            servicesButton,
            imageName: "rectangle.stack.fill",
            accessibilityLabel: "Choose another source"
        ) { [weak self] in
            self?.showTemporarily()
            self?.onServices?()
        }
        servicesButton.accessibilityHint = "Opens Services for the current media"
        servicesButton.accessibilityIdentifier = "AVPlayer.Services"

        configureChromeButton(
            episodeBrowserButton,
            imageName: "list.bullet.rectangle",
            accessibilityLabel: "Browse episodes"
        ) { [weak self] in
            self?.onEpisodeBrowser?()
        }
        episodeBrowserButton.accessibilityHint = "Opens the episode browser for this show"
        episodeBrowserButton.accessibilityIdentifier = "AVPlayer.EpisodeBrowser"
        setEpisodeBrowserAvailable(false)

        configureChromeButton(
            pictureInPictureButton,
            imageName: "pip.enter",
            accessibilityLabel: "Picture in Picture"
        ) { [weak self] in
            self?.showTemporarily()
            self?.onPictureInPicture?()
        }
        setPictureInPictureAvailable(false)

        configureChromeButton(
            rewindButton,
            imageName: "gobackward.10",
            accessibilityLabel: "Back 10 seconds",
            pointSize: 28
        ) { [weak self] in
            self?.seek(by: -10)
        }
        configureChromeButton(
            playPauseButton,
            imageName: "play.fill",
            accessibilityLabel: "Play",
            pointSize: 34
        ) { [weak self] in
            self?.togglePlayback()
        }
        configureChromeButton(
            forwardButton,
            imageName: "goforward.10",
            accessibilityLabel: "Forward 10 seconds",
            pointSize: 28
        ) { [weak self] in
            self?.seek(by: 10)
        }

        titleLabel.text = title.isEmpty ? "Now Playing" : title
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.accessibilityTraits = .header
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        [currentTimeLabel, durationLabel].forEach { timeLabel in
            timeLabel.textColor = UIColor.white.withAlphaComponent(0.82)
            timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            timeLabel.textAlignment = .center
            timeLabel.text = "00:00"
        }
        timelineSlider.minimumValue = 0
        timelineSlider.maximumValue = 1
        timelineSlider.minimumTrackTintColor = .white
        timelineSlider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.28)
        timelineSlider.setThumbImage(
            UIImage(systemName: "circle.fill")?.withConfiguration(
                UIImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            ),
            for: .normal
        )
        timelineSlider.accessibilityLabel = "Playback position"
        timelineSlider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.isScrubbing = true
            self.wasPlayingBeforeScrub = self.player?.timeControlStatus == .playing
            self.player?.pause()
            self.showTemporarily()
        }, for: .touchDown)
        timelineSlider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.currentTimeLabel.text = Self.formatTime(Double(self.timelineSlider.value))
            self.showTemporarily()
        }, for: .valueChanged)
        timelineSlider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.finishScrubbing(at: Double(self.timelineSlider.value))
        }, for: [.touchUpInside, .touchUpOutside, .touchCancel])

        [topGradient, bottomGradient].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.alpha = 0
            $0.isHidden = true
            overlay.insertSubview($0, belowSubview: label)
        }

        topRail.translatesAutoresizingMaskIntoConstraints = false
        topRail.alpha = 0
        topRail.isHidden = true
        topRail.accessibilityIdentifier = "AVPlayer.TopControls"
        overlay.addSubview(topRail)

        let topStack = UIStackView(arrangedSubviews: [
            closeButton,
            playbackLockButton,
            pictureInPictureButton,
            titleLabel
        ])
        topStack.translatesAutoresizingMaskIntoConstraints = false
        topStack.axis = .horizontal
        topStack.alignment = .center
        topStack.spacing = 8
        topStack.setCustomSpacing(14, after: pictureInPictureButton)
        topRail.contentView.addSubview(topStack)

        transportContainer.translatesAutoresizingMaskIntoConstraints = false
        transportContainer.alpha = 0
        transportContainer.isHidden = true
        transportContainer.accessibilityIdentifier = "AVPlayer.TransportControls"
        overlay.addSubview(transportContainer)

        let transportStack = UIStackView(arrangedSubviews: [rewindButton, playPauseButton, forwardButton])
        transportStack.translatesAutoresizingMaskIntoConstraints = false
        transportStack.axis = .horizontal
        transportStack.alignment = .center
        transportStack.spacing = 30
        transportContainer.addSubview(transportStack)

        controlRail.translatesAutoresizingMaskIntoConstraints = false
        controlRail.alpha = 0
        controlRail.isHidden = true
        controlRail.accessibilityIdentifier = "AVPlayer.MediaControls"
        overlay.addSubview(controlRail)

        let timelineStack = UIStackView(arrangedSubviews: [currentTimeLabel, timelineSlider, durationLabel])
        timelineStack.axis = .horizontal
        timelineStack.alignment = .center
        timelineStack.spacing = 10
        timelineStack.translatesAutoresizingMaskIntoConstraints = false
        controlRail.contentView.addSubview(timelineStack)

        let trackStack = UIStackView(arrangedSubviews: [servicesButton, episodeBrowserButton, audioButton, subtitleButton])
        trackStack.translatesAutoresizingMaskIntoConstraints = false
        trackStack.axis = .horizontal
        trackStack.alignment = .center
        trackStack.spacing = 8
        controlRail.contentView.addSubview(trackStack)

        let bottomWidth = controlRail.widthAnchor.constraint(
            equalTo: overlay.safeAreaLayoutGuide.widthAnchor,
            constant: -48
        )
        let subtitleBottom = label.bottomAnchor.constraint(
            equalTo: overlay.safeAreaLayoutGuide.bottomAnchor,
            constant: Self.subtitleBottomConstant
        )
        subtitleBottomConstraint = subtitleBottom

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            label.leadingAnchor.constraint(
                greaterThanOrEqualTo: overlay.safeAreaLayoutGuide.leadingAnchor,
                constant: 24
            ),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: overlay.safeAreaLayoutGuide.trailingAnchor,
                constant: -24
            ),
            subtitleBottom,
            label.widthAnchor.constraint(
                lessThanOrEqualTo: overlay.safeAreaLayoutGuide.widthAnchor,
                multiplier: 0.82
            ),
            topGradient.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            topGradient.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            topGradient.topAnchor.constraint(equalTo: overlay.topAnchor),
            topGradient.heightAnchor.constraint(equalToConstant: 150),
            bottomGradient.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            bottomGradient.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            bottomGradient.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
            bottomGradient.heightAnchor.constraint(equalToConstant: 170),
            topRail.leadingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.leadingAnchor, constant: 18),
            topRail.trailingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -18),
            topRail.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 8),
            topRail.heightAnchor.constraint(equalToConstant: 46),
            topStack.leadingAnchor.constraint(equalTo: topRail.contentView.leadingAnchor),
            topStack.trailingAnchor.constraint(equalTo: topRail.contentView.trailingAnchor),
            topStack.topAnchor.constraint(equalTo: topRail.contentView.topAnchor),
            topStack.bottomAnchor.constraint(equalTo: topRail.contentView.bottomAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            playbackLockButton.widthAnchor.constraint(equalToConstant: 44),
            playbackLockButton.heightAnchor.constraint(equalToConstant: 44),
            pictureInPictureButton.widthAnchor.constraint(equalToConstant: 44),
            pictureInPictureButton.heightAnchor.constraint(equalToConstant: 44),
            transportContainer.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            transportContainer.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: -4),
            transportContainer.heightAnchor.constraint(equalToConstant: 76),
            transportStack.leadingAnchor.constraint(equalTo: transportContainer.leadingAnchor),
            transportStack.trailingAnchor.constraint(equalTo: transportContainer.trailingAnchor),
            transportStack.topAnchor.constraint(equalTo: transportContainer.topAnchor),
            transportStack.bottomAnchor.constraint(equalTo: transportContainer.bottomAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 72),
            playPauseButton.heightAnchor.constraint(equalToConstant: 72),
            rewindButton.widthAnchor.constraint(equalToConstant: 58),
            rewindButton.heightAnchor.constraint(equalToConstant: 58),
            forwardButton.widthAnchor.constraint(equalToConstant: 58),
            forwardButton.heightAnchor.constraint(equalToConstant: 58),
            controlRail.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            controlRail.bottomAnchor.constraint(
                equalTo: overlay.safeAreaLayoutGuide.bottomAnchor,
                constant: -12
            ),
            controlRail.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            controlRail.trailingAnchor.constraint(lessThanOrEqualTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            bottomWidth,
            controlRail.heightAnchor.constraint(equalToConstant: 94),
            trackStack.trailingAnchor.constraint(equalTo: controlRail.contentView.trailingAnchor),
            trackStack.topAnchor.constraint(equalTo: controlRail.contentView.topAnchor),
            trackStack.heightAnchor.constraint(equalToConstant: 44),
            audioButton.widthAnchor.constraint(equalToConstant: 44),
            audioButton.heightAnchor.constraint(equalToConstant: 44),
            servicesButton.widthAnchor.constraint(equalToConstant: 44),
            servicesButton.heightAnchor.constraint(equalToConstant: 44),
            episodeBrowserButton.widthAnchor.constraint(equalToConstant: 44),
            episodeBrowserButton.heightAnchor.constraint(equalToConstant: 44),
            subtitleButton.widthAnchor.constraint(equalToConstant: 44),
            subtitleButton.heightAnchor.constraint(equalToConstant: 44),
            timelineStack.leadingAnchor.constraint(equalTo: controlRail.contentView.leadingAnchor),
            timelineStack.trailingAnchor.constraint(equalTo: controlRail.contentView.trailingAnchor),
            timelineStack.topAnchor.constraint(equalTo: trackStack.bottomAnchor, constant: 4),
            timelineStack.bottomAnchor.constraint(equalTo: controlRail.contentView.bottomAnchor),
            currentTimeLabel.widthAnchor.constraint(equalToConstant: 52),
            durationLabel.widthAnchor.constraint(equalToConstant: 52)
        ])
    }

    private func configureChromeButton(
        _ button: UIButton,
        imageName: String,
        accessibilityLabel: String,
        pointSize: CGFloat = 18,
        action: @escaping () -> Void
    ) {
        button.configuration = IOSAVPlayerControlStyle.configuration(
            imageName: imageName,
            pointSize: pointSize
        )
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = accessibilityLabel
        IOSAVPlayerControlStyle.applyShadow(to: button)
        button.addAction(UIAction { [weak self] _ in
            self?.showTemporarily()
            action()
        }, for: .primaryActionTriggered)
    }

    private func updateTransport(time: Double) {
        let duration = player?.currentItem?.duration.seconds ?? .nan
        let validDuration = duration.isFinite && duration > 0 ? duration : 0
        if !isScrubbing {
            timelineSlider.maximumValue = Float(max(validDuration, 1))
            timelineSlider.value = Float(min(max(time.isFinite ? time : 0, 0), max(validDuration, 1)))
            currentTimeLabel.text = Self.formatTime(time)
        }
        durationLabel.text = validDuration > 0 ? Self.formatTime(validDuration) : "--:--"
        timelineSlider.isEnabled = validDuration > 0

        let isPlaying = player?.timeControlStatus != .paused
        var configuration = playPauseButton.configuration ?? .plain()
        configuration.image = UIImage(systemName: isPlaying ? "pause.fill" : "play.fill")
        playPauseButton.configuration = configuration
        playPauseButton.accessibilityLabel = isPlaying ? "Pause" : "Play"
    }

    private func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus == .paused {
            let savedSpeed = UserDefaults.standard.double(forKey: "defaultPlaybackSpeed")
            let speed = Float(savedSpeed > 0 ? min(max(savedSpeed, 0.25), 3.0) : 1.0)
            // This is a direct user command, so do not add AVPlayer's optional buffer-wait
            // latency before honoring it. Startup playback keeps its existing conservative path.
            player.playImmediately(atRate: speed)
        } else {
            player.pause()
        }
        updateTransport(time: player.currentTime().seconds)
    }

    private func seek(by offset: Double) {
        guard let player else { return }
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        let duration = player.currentItem?.duration.seconds ?? .nan
        let target = duration.isFinite && duration > 0
            ? min(max(current + offset, 0), duration)
            : max(current + offset, 0)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600)
        )
        updateTransport(time: target)
    }

    private func finishScrubbing(at position: Double) {
        guard isScrubbing, let player else { return }
        isScrubbing = false
        player.seek(
            to: CMTime(seconds: position, preferredTimescale: 600),
            toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600)
        ) { [weak self, weak player] _ in
            DispatchQueue.main.async {
                guard let self, let player else { return }
                if self.wasPlayingBeforeScrub {
                    player.play()
                }
                self.wasPlayingBeforeScrub = false
                self.showTemporarily()
            }
        }
    }

    private static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%02d:%02d", minutes, remainder)
    }

    private func configureMenuButton(
        _ button: UIButton,
        imageName: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String
    ) {
        button.configuration = IOSAVPlayerControlStyle.configuration(
            imageName: imageName,
            pointSize: 17,
            contentInsets: NSDirectionalEdgeInsets(
                top: 10,
                leading: 10,
                bottom: 10,
                trailing: 10
            )
        )
        button.translatesAutoresizingMaskIntoConstraints = false
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = accessibilityLabel
        button.accessibilityIdentifier = accessibilityIdentifier
        button.accessibilityTraits.insert(.button)
        button.isPointerInteractionEnabled = true
        IOSAVPlayerControlStyle.applyShadow(to: button)
        button.addAction(UIAction { [weak self] _ in
            self?.showTemporarily()
        }, for: .menuActionTriggered)
    }

    private func rebuildMenus() {
        rebuildSubtitleMenu()
        rebuildAudioMenu()
        updateButtonAppearance()
    }

    private func rebuildSubtitleMenu() {
        let selectedEmbedded = selectedEmbeddedSubtitleOption()
        let forcedSubtitles = embeddedSubtitleGroup?.allowsEmptySelection == false
        var children: [UIMenuElement] = []

        let off = UIAction(
            title: forcedSubtitles ? "Off (Required by Stream)" : "Off",
            image: UIImage(systemName: "captions.bubble"),
            attributes: forcedSubtitles ? .disabled : [],
            state: selectedIndex == nil && selectedEmbedded == nil ? .on : .off
        ) { [weak self] _ in
            self?.disableFromMenu()
        }
        children.append(off)

        if let group = embeddedSubtitleGroup, !group.options.isEmpty {
            let embedded = group.options.map { option in
                UIAction(
                    title: option.displayName,
                    image: UIImage(systemName: "text.bubble"),
                    state: selectedEmbedded == option ? .on : .off
                ) { [weak self, weak option] _ in
                    guard let self, let option else { return }
                    self.selectEmbeddedSubtitle(option, in: group)
                }
            }
            children.append(UIMenu(
                title: "In Stream",
                image: UIImage(systemName: "play.rectangle"),
                options: .displayInline,
                children: embedded
            ))
        }

        if !candidates.isEmpty {
            let external = candidates.enumerated().map { index, candidate in
                UIAction(
                    title: candidate.title,
                    image: UIImage(systemName: "captions.bubble"),
                    attributes: forcedSubtitles ? .disabled : [],
                    state: selectedIndex == index ? .on : .off
                ) { [weak self] _ in
                    self?.loadCandidate(at: index, notify: true)
                }
            }
            children.append(UIMenu(
                title: forcedSubtitles ? "External (Unavailable with Required Captions)" : "External",
                image: UIImage(systemName: "link"),
                options: .displayInline,
                children: external
            ))
        }

        if embeddedSubtitleGroup?.options.isEmpty != false, candidates.isEmpty {
            let title = isLoadingMediaOptions ? "Loading subtitle tracks…" : "No subtitles available"
            children.append(UIAction(title: title, attributes: .disabled) { _ in })
        }
        subtitleButton.menu = UIMenu(
            title: "Subtitles",
            image: UIImage(systemName: "captions.bubble"),
            children: children
        )
    }

    private func rebuildAudioMenu() {
        guard let group = audioGroup, !group.options.isEmpty else {
            let title = isLoadingMediaOptions ? "Loading audio tracks…" : "No alternate audio tracks available"
            audioButton.menu = UIMenu(
                title: "Audio",
                image: UIImage(systemName: "speaker.wave.2"),
                children: [UIAction(title: title, attributes: .disabled) { _ in }]
            )
            return
        }

        let selected = player?.currentItem?
            .currentMediaSelection.selectedMediaOption(in: group)
        let tracks = group.options.map { option in
            UIAction(
                title: option.displayName,
                image: UIImage(systemName: "waveform"),
                state: selected == option ? .on : .off
            ) { [weak self, weak option] _ in
                guard let self, let option else { return }
                self.selectAudio(option, in: group)
            }
        }
        audioButton.menu = UIMenu(
            title: "Audio",
            image: UIImage(systemName: "speaker.wave.2"),
            children: tracks
        )
    }

    private func updateButtonAppearance() {
        var subtitleConfiguration = subtitleButton.configuration ?? .plain()
        let subtitlesSelected = selectedIndex != nil || selectedEmbeddedSubtitleOption() != nil
        subtitleConfiguration.image = UIImage(
            systemName: subtitlesSelected ? "captions.bubble.fill" : "captions.bubble"
        )
        subtitleConfiguration.baseForegroundColor = subtitlesSelected ? .systemBlue : .white
        subtitleButton.configuration = subtitleConfiguration
        subtitleButton.accessibilityValue = subtitlesSelected ? "On" : "Off"

        var audioConfiguration = audioButton.configuration ?? .plain()
        audioConfiguration.image = UIImage(systemName: "speaker.wave.2.fill")
        audioConfiguration.baseForegroundColor = .white
        audioButton.configuration = audioConfiguration
        if let group = audioGroup,
           let selected = player?.currentItem?
            .currentMediaSelection.selectedMediaOption(in: group) {
            audioButton.accessibilityValue = selected.displayName
        } else {
            audioButton.accessibilityValue = "Default"
        }
    }

    private func selectedEmbeddedSubtitleOption() -> AVMediaSelectionOption? {
        guard selectedIndex == nil,
              let group = embeddedSubtitleGroup else { return nil }
        return player?.currentItem?
            .currentMediaSelection.selectedMediaOption(in: group)
    }

    private func selectEmbeddedSubtitle(_ option: AVMediaSelectionOption, in group: AVMediaSelectionGroup) {
        guard let item = player?.currentItem,
              embeddedSubtitleGroup === group,
              group.options.contains(option) else { return }
        clearExternalSelection()
        item.select(option, in: group)
        onEmbeddedSubtitleSelectionChanged?(option.extendedLanguageTag)
        rebuildMenus()
    }

    private func selectAudio(_ option: AVMediaSelectionOption, in group: AVMediaSelectionGroup) {
        guard let item = player?.currentItem,
              audioGroup === group,
              group.options.contains(option) else { return }
        item.select(option, in: group)
        onAudioSelectionChanged?(option.extendedLanguageTag)
        rebuildMenus()
    }

    private func disableFromMenu() {
        guard embeddedSubtitleGroup?.allowsEmptySelection != false else { return }
        clearExternalSelection()
        onSelectionChanged?(false, false)
        rebuildMenus()
    }

    private func failSelectedCandidate() {
        clearExternalSelection()
        onSelectionChanged?(false, true)
        rebuildMenus()
    }

    private func loadCandidate(at index: Int, notify: Bool) {
        guard candidates.indices.contains(index) else { return }
        cancelLoads()
        cues = []
        label.isHidden = true
        selectedIndex = index
        rebuildMenus()
        if notify { onSelectionChanged?(true, false) }

        let candidate = candidates[index]
        if candidate.url.isFileURL {
            let generation = localLoadGeneration
            localLoadTask = Task { [weak self, url = candidate.url] in
                let data = await Task.detached(priority: .utility) { () -> Data? in
                    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                          let fileSize = values.fileSize,
                          fileSize >= 0,
                          fileSize <= 4 * 1_024 * 1_024 else { return nil }
                    return try? Data(contentsOf: url, options: .mappedIfSafe)
                }.value
                guard let self,
                      !Task.isCancelled,
                      self.localLoadGeneration == generation,
                      self.selectedIndex == index else { return }
                self.localLoadTask = nil
                if let data {
                    self.accept(data: data)
                } else {
                    self.failSelectedCandidate()
                }
            }
            return
        }

        let download = TVBoundedSubtitleDownload(url: candidate.url, headers: candidate.headers)
        self.download = download
        download.start { [weak self, weak download] result in
            guard let self,
                  self.download === download,
                  self.selectedIndex == index else { return }
            self.download = nil
            switch result {
            case .success(let data):
                self.accept(data: data)
            case .failure:
                self.failSelectedCandidate()
            }
        }
    }

    private func accept(data: Data) {
        let parsed = TVExternalSubtitleParser.parse(data)
        guard !parsed.isEmpty else {
            failSelectedCandidate()
            return
        }
        cues = parsed
    }

    private func cancelLoads() {
        download?.cancel()
        download = nil
        localLoadTask?.cancel()
        localLoadTask = nil
        localLoadGeneration = UUID()
    }

    private func clearExternalSelection() {
        cancelLoads()
        selectedIndex = nil
        cues = []
        label.isHidden = true
    }

    private static func makeCandidates(
        subtitleURLs: [String],
        subtitleNames: [String]?,
        subtitleHeadersByURL: [String: [String: String]]?
    ) -> [Candidate] {
        var seen = Set<String>()
        var result: [Candidate] = []
        for (index, rawValue) in subtitleURLs.enumerated() where result.count < 100 {
            guard let url = URL(string: rawValue),
                  url.isFileURL || ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  seen.insert(url.absoluteString).inserted else { continue }
            let suppliedName = subtitleNames.flatMap { names in
                names.indices.contains(index) ? names[index].trimmingCharacters(in: .whitespacesAndNewlines) : nil
            }
            let title = suppliedName.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }
                ?? "Subtitle \(result.count + 1)"
            let headers = subtitleHeadersByURL?[rawValue]
                ?? subtitleHeadersByURL?[url.absoluteString]
                ?? [:]
            result.append(Candidate(
                url: url,
                title: title,
                languageTag: inferredLanguageTag(from: title),
                headers: AVPlayerResourceLoader.sanitizedHTTPHeaders(headers)
            ))
        }
        return result
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
        let defaultSize: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 30 : 22
        let fontSize = CGFloat(savedFontSize > 0 ? min(max(savedFontSize, 16), 52) : Double(defaultSize))
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
              let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data) else {
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

extension UIViewController {
    func topmostViewController() -> UIViewController {
        if let presented = self.presentedViewController {
            return presented.topmostViewController()
        }

        if let navigation = self as? UINavigationController {
            return navigation.visibleViewController?.topmostViewController() ?? navigation
        }

        if let tabBar = self as? UITabBarController {
            return tabBar.selectedViewController?.topmostViewController() ?? tabBar
        }

        if let splitView = self as? UISplitViewController {
            return splitView.viewControllers.last?.topmostViewController() ?? splitView
        }

        return self
    }
}

@MainActor
extension UIApplication {
    /// Resolve a presenter inside one known WindowGroup scene. When the lightweight scene probe
    /// has not attached yet, only fall back if there is exactly one foreground scene; multiple
    /// iPad scenes can each report a key window, so flattening them is not deterministic.
    func eclipseTopmostViewController(forSceneSessionIdentifier identifier: String?) -> UIViewController? {
        let foregroundScenes = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        let scene: UIWindowScene?
        if let identifier {
            scene = foregroundScenes.first {
                $0.session.persistentIdentifier == identifier
            }
        } else {
            scene = foregroundScenes.count == 1 ? foregroundScenes.first : nil
        }
        guard let scene else { return nil }
        let window = scene.windows.first(where: {
            $0.isKeyWindow && $0.rootViewController != nil
        }) ?? scene.windows.first(where: {
            !$0.isHidden
                && $0.alpha > 0
                && $0.windowLevel == .normal
                && $0.rootViewController != nil
        })
        return window?.rootViewController?.topmostViewController()
    }

    /// Resolve presentation from the application's actual key window before falling back to an
    /// active scene. `connectedScenes.first` is unordered and can target the wrong Stage Manager
    /// window when Eclipse has more than one scene.
    func eclipseTopmostViewController() -> UIViewController? {
        let windowScenes = connectedScenes.compactMap { $0 as? UIWindowScene }
        let keyWindow = windowScenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        let fallbackWindow = windowScenes
            .first(where: { $0.activationState == .foregroundActive })?
            .windows
            .first
            ?? windowScenes.first?.windows.first
        return (keyWindow ?? fallbackWindow)?.rootViewController?.topmostViewController()
    }
}
