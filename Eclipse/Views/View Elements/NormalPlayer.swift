import AVKit

class NormalPlayer: AVPlayerViewController, AVPlayerViewControllerDelegate {
    private var originalRate: Float = 1.0
    private var timeObserverToken: Any?
    private var startupTimeObserverToken: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var startupWorkItem: DispatchWorkItem?
    private var playbackDidStart = false
    private var playbackFailureHandled = false
    private var slowProbeCount = 0
    private var hasBegunMediaStatePlaybackLease = false
    private var hasEndedMediaStatePlaybackLease = false
    private var hasFinalizedPlaybackSession = false
    var mediaInfo: MediaInfo?
    var episodePlaybackContext: EpisodePlaybackContext?
    var playbackLaunchContext: PlaybackLaunchContext?
    var onPlaybackStartupFailure: ((PlaybackFailureReport) -> Void)?
    
#if os(iOS)
    private var holdGesture: UILongPressGestureRecognizer?
    private var preferredAudioSelectionTask: Task<Void, Never>?
    private var isPictureInPictureActiveOrStarting = false
    private var hasViewDisappeared = false
    private var isRestoringFromPictureInPicture = false
#endif
    
    override func viewDidLoad() {
        super.viewDidLoad()
        beginMediaStatePlaybackLeaseIfNeeded()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaStateAccountBoundary),
            name: .mediaStateWillChangeCurrentUser,
            object: nil
        )
        
#if os(iOS)
        setupHoldGesture()
        setupPictureInPictureHandling()
#endif
        if let info = mediaInfo {
            setupProgressTracking(for: info)
        }
        setupPlaybackStartupMonitoring()
        setupAudioSession()
#if os(iOS)
        schedulePreferredAudioSelection()
#endif
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
#if os(iOS)
        hasViewDisappeared = true
        if isPictureInPictureActiveOrStarting {
            // AVPlayerViewController dismisses its full-screen UI while PiP
            // keeps playing. The playback lease and progress observer must
            // remain active until PiP actually stops.
            return
        }
#endif
        finalizePlaybackSessionIfNeeded()
        tearDownPlaybackObservers()
    }

    private func tearDownPlaybackObservers() {
#if os(iOS)
        preferredAudioSelectionTask?.cancel()
        preferredAudioSelectionTask = nil
#endif
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let token = startupTimeObserverToken {
            player?.removeTimeObserver(token)
            startupTimeObserverToken = nil
        }
        startupWorkItem?.cancel()
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
#endif
        player = nil
        dismiss(animated: false)
    }
    
    deinit {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
        }
        if let token = startupTimeObserverToken {
            player?.removeTimeObserver(token)
        }
#if os(iOS)
        preferredAudioSelectionTask?.cancel()
#endif
        startupWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
        finishMediaStatePlaybackLeaseIfNeeded()
    }
    
#if os(iOS)
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hasViewDisappeared = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasViewDisappeared = false
        isRestoringFromPictureInPicture = false
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if UserDefaults.standard.bool(forKey: "alwaysLandscape") {
            return .landscape
        } else {
            return .all
        }
    }
    
    private func setupHoldGesture() {
        holdGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleHoldGesture(_:)))
        holdGesture?.minimumPressDuration = 0.5
        if let holdGesture = holdGesture {
            view.addGestureRecognizer(holdGesture)
        }
    }
    
    private func setupPictureInPictureHandling() {
        delegate = self
        
        if AVPictureInPictureController.isPictureInPictureSupported() {
            self.allowsPictureInPicturePlayback = true
        }
    }

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isPictureInPictureActiveOrStarting = true
    }

    func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isPictureInPictureActiveOrStarting = true
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isPictureInPictureActiveOrStarting = false
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
    }
    
    func playerViewController(_ playerViewController: AVPlayerViewController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        isRestoringFromPictureInPicture = true
        let windowScene = UIApplication.shared.connectedScenes
            .filter { $0.activationState == .foregroundActive }
            .compactMap { $0 as? UIWindowScene }
            .first
        
        let window = windowScene?.windows.first(where: { $0.isKeyWindow })
        
        if let topVC = window?.rootViewController?.topmostViewController() {
            if topVC != self {
                topVC.present(self, animated: true) {
                    completionHandler(true)
                }
            } else {
                completionHandler(true)
            }
        } else {
            isRestoringFromPictureInPicture = false
            completionHandler(false)
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
        guard let player = player else { return }
        originalRate = player.rate
        let holdSpeed = UserDefaults.standard.float(forKey: "holdSpeedPlayer")
        player.rate = holdSpeed > 0 ? holdSpeed : 2.0
    }
    
    private func endHoldSpeed() {
        player?.rate = originalRate
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
        guard let context = playbackLaunchContext,
              let player = player,
              let url = URL(string: context.streamURL),
              !url.isFileURL else {
            return
        }

        itemStatusObservation = player.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                switch item.status {
                case .readyToPlay:
                    self?.markPlaybackStarted()
                case .failed:
                    self?.handlePlaybackStartupFailure(item.error?.localizedDescription ?? "AVPlayer could not load this stream", isSourceFailure: true)
                default:
                    break
                }
            }
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            if player.timeControlStatus == .playing {
                DispatchQueue.main.async {
                    self?.markPlaybackStarted()
                    self?.sendTraktScrobble(.start, reason: "avplayer-playing")
                }
            } else if player.timeControlStatus == .paused {
                DispatchQueue.main.async {
                    self?.sendTraktScrobble(.pause, reason: "avplayer-paused")
                }
            }
        }

        startupTimeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC)),
            queue: .main
        ) { [weak self] time in
            if time.seconds.isFinite, time.seconds > 0.1 {
                self?.markPlaybackStarted()
            }
        }

        schedulePlaybackStartupCheck(url: url, headers: context.headers, delay: 35)
    }

    private func schedulePlaybackStartupCheck(url: URL, headers: [String: String], delay: TimeInterval) {
        startupWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.playbackDidStart, !self.playbackFailureHandled else { return }
            self.runPlaybackStartupProbe(url: url, headers: headers)
        }
        startupWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func markPlaybackStarted() {
        guard !playbackDidStart else { return }
        playbackDidStart = true
        startupWorkItem?.cancel()
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
        Task { [weak self] in
            let result = await SourceHealthMonitor.shared.probeStream(url: url, headers: headers)
            await MainActor.run {
                guard let self, !self.playbackDidStart, !self.playbackFailureHandled else { return }
                switch result {
                case .reachable:
                    self.slowProbeCount += 1
                    self.schedulePlaybackStartupCheck(url: url, headers: headers, delay: 20)
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
        guard !playbackDidStart, !playbackFailureHandled, let context = playbackLaunchContext else { return }
        playbackFailureHandled = true
        startupWorkItem?.cancel()

        SourceHealthStore.shared.recordPlaybackFailure(
            sourceId: context.sourceId,
            sourceName: context.sourceName,
            reason: message,
            isSourceFailure: isSourceFailure
        )

        let report = PlaybackFailureReport(context: context, message: message, isSourceFailure: isSourceFailure)
        if context.autoMode {
            dismiss(animated: true) { [weak self] in
                self?.player?.pause()
                self?.onPlaybackStartupFailure?(report)
            }
        } else {
            let alert = UIAlertController(
                title: "Playback Failed",
                message: "\(context.sourceName) could not start playback. \(message)",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
                self?.retryPlaybackAfterFailure()
            })
            alert.addAction(UIAlertAction(title: "Close", style: .cancel) { [weak self] _ in
                self?.dismiss(animated: true)
            })
            present(alert, animated: true)
        }
    }

    private func retryPlaybackAfterFailure() {
        guard let context = playbackLaunchContext, let url = URL(string: context.streamURL) else {
            player?.seek(to: .zero)
            playAtDefaultSpeed()
            return
        }

        itemStatusObservation = nil
        timeControlObservation = nil
        if let token = startupTimeObserverToken {
            player?.removeTimeObserver(token)
            startupTimeObserverToken = nil
        }
        startupWorkItem?.cancel()

        playbackFailureHandled = false
        playbackDidStart = false
        slowProbeCount = 0

        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": context.headers])
        let item = AVPlayerItem(asset: asset)
        if player == nil {
            player = AVPlayer(playerItem: item)
        } else {
            player?.replaceCurrentItem(with: item)
        }
#if os(iOS)
        schedulePreferredAudioSelection()
#endif
        setupPlaybackStartupMonitoring()
        playAtDefaultSpeed()
    }
    
    func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
#if os(iOS)
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: .mixWithOthers)
            try audioSession.setActive(true)
            try audioSession.overrideOutputAudioPort(.speaker)
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
        seekToLastPosition(for: mediaInfo)
    }
    
    private func seekToLastPosition(for mediaInfo: MediaInfo) {
        let lastPlayedTime: Double
        
        switch mediaInfo {
        case .movie(let id, let title, _, _):
            lastPlayedTime = ProgressManager.shared.getMovieCurrentTime(movieId: id, title: title)
            
        case .episode(let showId, let seasonNumber, let episodeNumber, _, _, _):
            lastPlayedTime = ProgressManager.shared.getEpisodeCurrentTime(showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber)
        }
        
        if lastPlayedTime != 0 {
            let progress = getProgressPercentage(for: mediaInfo)
            if progress < 0.95 {
                let seekTime = CMTime(seconds: lastPlayedTime, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
                player?.seek(to: seekTime)
                Logger.shared.log("Resumed playback from \(Int(lastPlayedTime))s", type: "Progress")
            }
        }
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
    func schedulePreferredAudioSelection() {
        preferredAudioSelectionTask?.cancel()
        preferredAudioSelectionTask = nil

        guard let item = player?.currentItem else { return }
        let isAnime: Bool
        switch mediaInfo {
        case .movie(_, _, _, let value), .episode(_, _, _, _, _, let value):
            isAnime = value
        case nil:
            isAnime = false
        }
        guard let preferredLanguage = PlaybackMediaSelectionIntent
            .currentDefaults(isAnime: isAnime)
            .preferredAudioLanguage else {
            return
        }

        preferredAudioSelectionTask = Task { @MainActor [weak self, weak item] in
            guard let self, let item else { return }
            do {
                guard let group = try await item.asset.loadMediaSelectionGroup(for: .audible),
                      !Task.isCancelled,
                      self.player?.currentItem === item else {
                    return
                }
                let options = group.options.map {
                    PlaybackLanguageSelectionPolicy.Option(
                        languageTag: $0.extendedLanguageTag ?? $0.locale?.identifier,
                        displayName: $0.displayName
                    )
                }
                guard let index = PlaybackLanguageSelectionPolicy.preferredIndex(
                    in: options,
                    preferredLanguage: preferredLanguage
                ), group.options.indices.contains(index) else {
                    Logger.shared.log(
                        "NormalPlayer: no embedded audio match for preferred language=\(preferredLanguage) anime=\(isAnime)",
                        type: "Player"
                    )
                    return
                }
                let option = group.options[index]
                item.select(option, in: group)
                Logger.shared.log(
                    "NormalPlayer: auto-selected audio=\(option.displayName) preferredLanguage=\(preferredLanguage) anime=\(isAnime)",
                    type: "Player"
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                Logger.shared.log(
                    "NormalPlayer: preferred audio selection failed: \(error.localizedDescription)",
                    type: "Player"
                )
            }
        }
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
        
        return self
    }
}
