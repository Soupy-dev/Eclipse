#if os(iOS) && canImport(GoogleCast)
import Foundation
@preconcurrency import GoogleCast
import SwiftUI
import UIKit

enum CastEligibilityResult {
    case eligible(CastMediaDescriptor)
    case eligibleWithWarnings(CastMediaDescriptor, [String])
    case blocked(String)

    var descriptor: CastMediaDescriptor? {
        switch self {
        case .eligible(let descriptor), .eligibleWithWarnings(let descriptor, _):
            return descriptor
        case .blocked:
            return nil
        }
    }
}

struct CastSubtitleTrack {
    let identifier: Int
    let url: URL
    let contentType: String
    let name: String
    let languageCode: String?
}

struct CastMediaDescriptor {
    let url: URL
    let contentType: String
    let title: String
    let subtitle: String?
    let artworkURL: URL?
    let startPosition: Double
    let shouldAutoplay: Bool
    let subtitleTracks: [CastSubtitleTrack]
    let activeTrackIDs: [NSNumber]
    let identity: [String: Any]
}

private struct CastProgressIdentity: Codable {
    enum Kind: String, Codable { case movie, episode }

    let kind: Kind
    let id: Int
    let title: String?
    let posterURL: String?
    let season: Int?
    let episode: Int?
    let isAnime: Bool
    let playbackContext: EpisodePlaybackContext?

    init?(request: PlaybackRequest) {
        playbackContext = request.episodePlaybackContext
        switch request.mediaInfo {
        case .movie(let id, let title, let posterURL, let isAnime):
            kind = .movie
            self.id = id
            self.title = title
            self.posterURL = posterURL
            season = nil
            episode = nil
            self.isAnime = isAnime
        case .episode(let id, let season, let episode, let title, let posterURL, let isAnime):
            kind = .episode
            self.id = id
            self.title = title
            self.posterURL = posterURL
            self.season = season
            self.episode = episode
            self.isAnime = isAnime
        case .none:
            return nil
        }
    }

    var mediaInfo: MediaInfo? {
        switch kind {
        case .movie:
            return .movie(id: id, title: title ?? "Movie", posterURL: posterURL, isAnime: isAnime)
        case .episode:
            guard let season, let episode else { return nil }
            return .episode(
                showId: id,
                seasonNumber: season,
                episodeNumber: episode,
                showTitle: title,
                showPosterURL: posterURL,
                isAnime: isAnime
            )
        }
    }
}

#endif

/// One persistence path for local-renderer and Cast progress. ProgressManager
/// remains authoritative for completion/removal rules, while Trakt receives the
/// same normalized position and episode identity.
@MainActor
enum PlaybackProgressPersistence {
    static func persist(
        mediaInfo: MediaInfo,
        position: Double,
        duration: Double,
        playbackContext: EpisodePlaybackContext?,
        traktAction: TraktScrobbleAction? = nil
    ) {
        guard position.isFinite,
              duration.isFinite,
              duration >= 5,
              position >= 0,
              position <= duration + 2 else { return }
        let safePosition = min(position, duration)

        switch mediaInfo {
        case .movie(let id, let title, let posterURL, _):
            ProgressManager.shared.updateMovieProgress(
                movieId: id,
                title: title,
                currentTime: safePosition,
                totalDuration: duration,
                posterURL: posterURL
            )
        case .episode(let showID, let season, let episode, let showTitle, let posterURL, let isAnime):
            ProgressManager.shared.updateEpisodeProgress(
                showId: showID,
                seasonNumber: season,
                episodeNumber: episode,
                currentTime: safePosition,
                totalDuration: duration,
                showTitle: showTitle,
                showPosterURL: posterURL,
                playbackContext: playbackContext,
                isAnime: isAnime || playbackContext?.hasAnimeMediaId == true
            )
        }

        if let traktAction, safePosition > 0.5 {
            TrackerManager.shared.scrobbleTraktPlayback(
                traktAction,
                for: mediaInfo,
                progress: min(max(safePosition / duration, 0), 1),
                playbackContext: playbackContext
            )
        }
    }
}

#if os(iOS) && canImport(GoogleCast)

@MainActor
protocol GoogleCastPlayerHandoff: AnyObject {
    var castCurrentPosition: Double { get }
    var castCurrentDuration: Double { get }
    var castIsPaused: Bool { get }
    var castPlaybackRate: Double { get }
    var castIsVisible: Bool { get }

    func castWillBeginHandoff()
    func castDidBecomeActive(deviceName: String?)
    func castDidFailOrCancel(message: String, resumeLocal: Bool, position: Double?)
    func castDidUpdate(position: Double, duration: Double, isPaused: Bool, playbackRate: Double)
    func castDidEndUnexpectedly(position: Double, shouldResume: Bool)
    func castRequiresConfirmation(title: String, message: String, continueTitle: String, completion: @escaping (Bool) -> Void)
}

enum GoogleCastBootstrap {
    @MainActor
    static func configure() {
        guard !GCKCastContext.isSharedInstanceInitialized() else {
            GoogleCastCoordinator.shared.start()
            return
        }
        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        let enabledAtLaunch = GoogleCastSettings.isEnabled()
        // GCKCastContext is a process-wide singleton. Keep it initialized so a
        // GCKUICastButton can be constructed safely, but make a saved-off
        // preference inert before the SDK has a chance to start discovery.
        options.disableDiscoveryAutostart = !enabledAtLaunch
        options.startDiscoveryAfterFirstTapOnCastButton = enabledAtLaunch
        options.suspendSessionsWhenBackgrounded = false
        options.physicalVolumeButtonsWillControlDeviceVolume = false
        GCKCastContext.setSharedInstanceWith(options)
        GCKCastContext.sharedInstance().useDefaultExpandedMediaControls = true
        GoogleCastCoordinator.shared.start()
        Logger.shared.log(
            "GoogleCast: context initialized with Default Media Receiver enabled=\(enabledAtLaunch)",
            type: "Player"
        )
    }
}

enum GoogleCastReplacementResult {
    /// The receiver has accepted the replacement. The Player must commit its
    /// matching metadata before ordinary remote-progress updates resume.
    case loaded(UUID)
    case failed(String)
    case restoredLocally(String)
}

@MainActor
final class GoogleCastCoordinator: NSObject, ObservableObject {
    private enum LoadPurpose: Equatable {
        case handoff
        case replacement
    }

    /// A `GCKRequest` acknowledgement only confirms that the sender command
    /// completed. Keep the immutable request/descriptor that created it until
    /// the receiver also reports this exact media as non-idle.
    private final class PendingCastLoad {
        let token: UUID
        let purpose: LoadPurpose
        let playbackRequest: PlaybackRequest
        let descriptor: CastMediaDescriptor
        let replacementTransactionID: UUID?
        var requestDidComplete = false
        var receivedExpectedMediaStatus = false

        init(
            token: UUID,
            purpose: LoadPurpose,
            playbackRequest: PlaybackRequest,
            descriptor: CastMediaDescriptor,
            replacementTransactionID: UUID?
        ) {
            self.token = token
            self.purpose = purpose
            self.playbackRequest = playbackRequest
            self.descriptor = descriptor
            self.replacementTransactionID = replacementTransactionID
        }
    }

    /// `GCKRequest.cancel()` only stops sender-side tracking. A receiver can
    /// still process the old LOAD, so remember it long enough to stop a late
    /// orphaned handoff rather than leaving local and remote playback active.
    private struct TombstonedCastLoad {
        let descriptor: CastMediaDescriptor
        let expiresAt: Date
    }

    static let shared = GoogleCastCoordinator()
    private static let progressIdentityDefaultsKey = "GoogleCast.progressIdentity.v1"

    @Published private(set) var isSessionConnected = false
    @Published private(set) var isRemoteMediaActive = false
    @Published private(set) var isPlayerVisible = false

    weak var player: (any GoogleCastPlayerHandoff)?
    /// The Player whose local renderer was paused/stopped for the active
    /// remote handoff. It is intentionally separate from the currently visible
    /// observer so a later prepare call cannot restore the wrong Player.
    private weak var handoffOwner: (any GoogleCastPlayerHandoff)?
    private weak var preparationOwner: (any GoogleCastPlayerHandoff)?

    private var activeRequest: PlaybackRequest?
    /// The request that has actually reached the receiver. During a source
    /// replacement this intentionally stays on the old request until LOAD
    /// succeeds, preventing progress from being attributed to an unplayed item.
    private var remoteRequest: PlaybackRequest?
    private var eligibility: CastEligibilityResult?
    private var eligibilityGeneration = UUID()
    private var confirmationGeneration: UUID?
    private var attachedSession: GCKCastSession?
    private var remoteClient: GCKRemoteMediaClient?
    private var pendingLoadRequest: GCKRequest?
    private var pendingLoad: PendingCastLoad?
    private var tombstonedLoad: TombstonedCastLoad?
    private var pendingLoadSnapshot: (position: Double, wasPaused: Bool)?
    private var loadPurpose: LoadPurpose = .handoff
    private var replacementCompletion: ((GoogleCastReplacementResult) -> Void)?
    private var replacementTransactionID: UUID?
    private var replacementLoadIssued = false
    private var replacementCommitPending = false
    /// Retains the replacement recovery semantics through a cancellation that
    /// immediately clears the public transaction (for example, turning Cast
    /// off while B is loading) until `detach` can restore the original A.
    private var replacementRecoveryPending = false
    private var loadTimeoutWorkItem: DispatchWorkItem?
    private var loadGeneration = UUID()
    private var progressTimer: Timer?
    private var lastRemotePosition: Double = 0
    private var lastRemoteDuration: Double = 0
    private var lastRemoteWasPaused: Bool?
    private var loadSnapshot: (position: Double, wasPaused: Bool)?
    private var didPauseForPendingLoad = false
    private var didStopLocalForActiveLoad = false
    private var sessionWasSuspended = false
    private var lastDetachedProgressSaveAt: TimeInterval = 0
    private var progressIdentity: CastProgressIdentity?
    private var remoteMediaIdentifier: String?
    private var remoteContentURL: URL?
    private var started = false
    private var featureEnabled = GoogleCastSettings.isEnabled()

    private override init() {
        if let data = UserDefaults.standard.data(forKey: Self.progressIdentityDefaultsKey) {
            progressIdentity = try? JSONDecoder().decode(CastProgressIdentity.self, from: data)
        }
        super.init()
    }

    func start() {
        guard GCKCastContext.isSharedInstanceInitialized() else {
            log("start deferred because Cast context is not initialized")
            return
        }
        if !started {
            started = true
            let context = GCKCastContext.sharedInstance()
            context.sessionManager.add(self)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(castPreferencesDidChange),
                name: UserDefaults.didChangeNotification,
                object: UserDefaults.standard
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(castAppDidBecomeActive),
                name: UIApplication.didBecomeActiveNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(castMediaStateAccountWillChange),
                name: .mediaStateWillChangeCurrentUser,
                object: nil
            )
        }
        refreshEnabledState(force: true)
    }

    /// Local controls must not race a receiver LOAD after the Player has
    /// deliberately paused its renderer for a handoff.
    var isHandoffLoadPending: Bool {
        featureEnabled && didPauseForPendingLoad && !isRemoteMediaActive
    }

    /// Ignore delayed MPV callbacks while Cast owns (or is taking ownership
    /// of) playback. Those callbacks otherwise overwrite receiver progress,
    /// pause state, startup-failure handling, or restored media selection.
    var shouldIgnoreLocalRendererCallbacks: Bool {
        featureEnabled && (isHandoffLoadPending || (isRemoteMediaActive && handoffOwner != nil))
    }

    var isReplacementInProgress: Bool {
        replacementTransactionID != nil
    }

    func isAwaitingRemoteReplacementCommit(_ transactionID: UUID) -> Bool {
        replacementTransactionID == transactionID && replacementCommitPending && isRemoteMediaActive
    }

    func prepare(request: PlaybackRequest, player: any GoogleCastPlayerHandoff) {
        guard featureEnabled else { return }
        // A Player appearing while another Player already owns the receiver is
        // a passive observer, not permission to replace that remote stream.
        guard !isRemoteMediaActive,
              pendingLoad == nil,
              confirmationGeneration == nil,
              replacementTransactionID == nil,
              !didPauseForPendingLoad else {
            log("ignored passive prepare while a Cast handoff is active")
            return
        }
        self.player = player
        preparationOwner = player
        isPlayerVisible = true
        beginPreparation(request: request, purpose: .handoff, owner: player)
    }

    /// A replacement must be transactional: the old request stays authoritative
    /// until the receiver confirms the new one. This avoids corrupting visible
    /// metadata and saved progress when a new provider URL fails on the TV.
    func replaceRemoteMedia(
        with request: PlaybackRequest,
        player: any GoogleCastPlayerHandoff,
        completion: @escaping (GoogleCastReplacementResult) -> Void
    ) {
        guard featureEnabled,
              isSessionConnected,
              isRemoteMediaActive,
              remoteClient != nil else {
            completion(.failed("Google Cast is no longer connected. The current video was left unchanged."))
            return
        }
        guard pendingLoadRequest == nil,
              pendingLoad == nil,
              confirmationGeneration == nil,
              replacementTransactionID == nil else {
            completion(.failed("Google Cast is still loading the previous request. Please wait a moment and try again."))
            return
        }
        self.player = player
        preparationOwner = player
        isPlayerVisible = true
        // Capture the currently confirmed receiver position before suppressing
        // updates for the replacement transaction.
        publishRemoteProgress()
        let transactionID = UUID()
        replacementTransactionID = transactionID
        replacementLoadIssued = false
        replacementCommitPending = false
        replacementRecoveryPending = false
        replacementCompletion = completion
        beginPreparation(
            request: request,
            purpose: .replacement,
            owner: player,
            replacementTransactionID: transactionID
        )
    }

    private func beginPreparation(
        request: PlaybackRequest,
        purpose: LoadPurpose,
        owner: any GoogleCastPlayerHandoff,
        replacementTransactionID: UUID? = nil
    ) {
        activeRequest = request
        loadPurpose = purpose
        preparationOwner = owner
        let generation = UUID()
        eligibilityGeneration = generation
        confirmationGeneration = nil
        eligibility = nil

        Task { [weak self] in
            guard let self else { return }
            let result = await CastEligibilityEvaluator.evaluate(request: request)
            guard self.featureEnabled,
                  self.eligibilityGeneration == generation,
                  self.preparationOwner === owner,
                  self.player === owner,
                  owner.castIsVisible,
                  purpose != .replacement || self.replacementTransactionID == replacementTransactionID else { return }
            self.eligibility = result
            switch result {
            case .blocked(let reason):
                self.log("eligibility blocked reason=\(reason)")
            case .eligible:
                self.log("eligibility accepted")
            case .eligibleWithWarnings(_, let warnings):
                self.log("eligibility accepted warnings=\(warnings.count)")
            }
            if self.isSessionConnected {
                self.loadPreparedMediaIfPossible()
            }
        }
    }

    func update(request: PlaybackRequest) {
        guard featureEnabled else { return }
        guard !isRemoteMediaActive,
              pendingLoad == nil,
              confirmationGeneration == nil,
              replacementTransactionID == nil,
              !didPauseForPendingLoad else {
            log("deferred request update while Cast owns playback")
            return
        }
        guard let player else {
            activeRequest = request
            return
        }
        prepare(request: request, player: player)
    }

    func confirmRemoteReplacementCommitted(_ transactionID: UUID) {
        guard replacementTransactionID == transactionID, replacementCommitPending else { return }
        replacementCommitPending = false
        replacementLoadIssued = false
        replacementTransactionID = nil
        replacementRecoveryPending = false
        publishRemoteProgress()
    }

    func abandonRemoteReplacementCommit(_ transactionID: UUID) {
        guard replacementTransactionID == transactionID else { return }
        replacementCommitPending = false
        replacementLoadIssued = false
        replacementTransactionID = nil
        replacementRecoveryPending = false
        replacementCompletion = nil
        publishRemoteProgress()
    }

    func playerVisibilityChanged(_ visible: Bool, player: any GoogleCastPlayerHandoff) {
        guard self.player === player else { return }
        isPlayerVisible = visible
    }

    func playerClosed(_ player: any GoogleCastPlayerHandoff) {
        let ownsObserver = self.player === player
        let ownsPreparation = preparationOwner === player
        let ownsHandoff = handoffOwner === player
        guard ownsObserver || ownsPreparation || ownsHandoff else { return }
        if ownsObserver {
            isPlayerVisible = false
            self.player = nil
        }
        if ownsPreparation {
            let pendingReceiverLoad = pendingLoadRequest != nil
            cancelCurrentPreparation(reason: "The player was closed before Google Cast finished loading.")
            if pendingReceiverLoad,
               GCKCastContext.isSharedInstanceInitialized(),
               isSessionConnected {
                _ = GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
            }
        }
        // A deliberately closed Player should leave a continued Cast session in
        // mini-controller mode, not be restarted if the receiver later drops.
        if ownsHandoff {
            handoffOwner = nil
        }
        if replacementCommitPending {
            replacementCommitPending = false
            replacementLoadIssued = false
            replacementTransactionID = nil
            replacementRecoveryPending = false
            replacementCompletion = nil
        }
        if !isSessionConnected {
            activeRequest = nil
            eligibility = nil
        }
    }

    func stopForAccountBoundary(_ player: any GoogleCastPlayerHandoff) {
        guard self.player === player || preparationOwner === player || handoffOwner === player else { return }
        cancelCurrentPreparation(reason: "The Eclipse account changed.")
        isPlayerVisible = false
        self.player = nil
        handoffOwner = nil
        clearProgressIdentity()
        guard GCKCastContext.isSharedInstanceInitialized(), isSessionConnected else {
            activeRequest = nil
            remoteRequest = nil
            eligibility = nil
            return
        }
        _ = GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
        detach(error: nil)
        log("session ended at account boundary")
    }

    var shouldShowMiniController: Bool {
        featureEnabled && isSessionConnected && isRemoteMediaActive && !isPlayerVisible
    }

    var remoteIsPaused: Bool? {
        guard featureEnabled,
              isRemoteMediaActive,
              let status = remoteClient?.mediaStatus,
              status.playerState != .idle,
              isCurrentRemoteMedia(status) else { return nil }
        return status.playerState == .paused
    }

    var remotePlaybackRate: Double? {
        guard featureEnabled,
              isRemoteMediaActive,
              let status = remoteClient?.mediaStatus,
              status.playerState != .idle,
              isCurrentRemoteMedia(status) else { return nil }
        return Double(status.playbackRate)
    }

    @discardableResult
    func playIfRemote() -> Bool {
        guard ownsCurrentRemoteMedia(), let remoteClient else { return false }
        guard remoteCommandIsSupported(kGCKMediaCommandPause) else { return true }
        remoteClient.play()
        return true
    }

    @discardableResult
    func pauseIfRemote() -> Bool {
        guard ownsCurrentRemoteMedia(), let remoteClient else { return false }
        guard remoteCommandIsSupported(kGCKMediaCommandPause) else { return true }
        remoteClient.pause()
        return true
    }

    @discardableResult
    func togglePauseIfRemote() -> Bool {
        guard ownsCurrentRemoteMedia() else { return false }
        guard remoteCommandIsSupported(kGCKMediaCommandPause) else { return true }
        if remoteIsPaused == true {
            remoteClient?.play()
        } else {
            remoteClient?.pause()
        }
        return true
    }

    @discardableResult
    func seekIfRemote(to position: Double) -> Bool {
        guard ownsCurrentRemoteMedia(), let remoteClient, position.isFinite else { return false }
        guard remoteCommandIsSupported(kGCKMediaCommandSeek) else { return true }
        let options = GCKMediaSeekOptions()
        options.interval = max(0, position)
        options.relative = false
        options.resumeState = .unchanged
        remoteClient.seek(with: options)
        return true
    }

    @discardableResult
    func seekIfRemote(by offset: Double) -> Bool {
        guard ownsCurrentRemoteMedia(), let remoteClient, offset.isFinite else { return false }
        guard remoteCommandIsSupported(kGCKMediaCommandSeek) else { return true }
        let options = GCKMediaSeekOptions()
        options.interval = offset
        options.relative = true
        options.resumeState = .unchanged
        remoteClient.seek(with: options)
        return true
    }

    @discardableResult
    func setPlaybackRateIfRemote(_ rate: Double) -> Bool {
        guard ownsCurrentRemoteMedia(), let remoteClient, rate.isFinite else { return false }
        guard remoteCommandIsSupported(kGCKMediaCommandSetPlaybackRate) else { return true }
        remoteClient.setPlaybackRate(Float(clampedPlaybackRate(rate)))
        return true
    }

    func presentCastDialog() {
        guard featureEnabled, GCKCastContext.isSharedInstanceInitialized() else { return }
        GCKCastContext.sharedInstance().presentCastDialog()
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: GoogleCastSettings.enabledKey)
        refreshEnabledState(force: true)
    }

    func refreshEnabledState(force: Bool = false) {
        let enabled = GoogleCastSettings.isEnabled()
        let didChange = featureEnabled != enabled
        featureEnabled = enabled
        guard started, GCKCastContext.isSharedInstanceInitialized(), didChange || force else { return }

        let context = GCKCastContext.sharedInstance()
        if enabled {
            context.discoveryManager.startDiscovery()
            if let session = context.sessionManager.currentCastSession, remoteClient == nil {
                attach(to: session)
                if activeRequest != nil, !isRemoteMediaActive {
                    loadPreparedMediaIfPossible()
                }
            }
            log("feature enabled; discovery started")
        } else {
            cancelCurrentPreparation(reason: "Google Cast was turned off.")
            context.discoveryManager.stopDiscovery()
            if context.sessionManager.currentCastSession != nil {
                _ = context.sessionManager.endSessionAndStopCasting(true)
            }
            // Do not wait for a network callback to restore a locally visible
            // player. A delayed didEnd notification is harmless because detach
            // is idempotent.
            detach(error: nil)
            activeRequest = nil
            remoteRequest = nil
            eligibility = nil
            clearProgressIdentity()
            log("feature disabled; discovery stopped and session ended")
        }
    }

    @objc private func castPreferencesDidChange() {
        refreshEnabledState()
    }

    @objc private func castAppDidBecomeActive() {
        // The SDK normally restarts discovery on foreground. Reassert the
        // user's disabled preference before it can surface devices or a prompt.
        refreshEnabledState(force: true)
    }

    @objc private func castMediaStateAccountWillChange() {
        // An open player receives the same synchronous notification and owns
        // its local renderer shutdown. This path protects detached/mini-player
        // Cast sessions, which otherwise have no PlayerViewController left to
        // clear their old-account progress identity.
        guard player == nil else { return }
        cancelCurrentPreparation(reason: "The Eclipse account changed.")
        guard GCKCastContext.isSharedInstanceInitialized(), isSessionConnected else {
            activeRequest = nil
            remoteRequest = nil
            clearProgressIdentity()
            return
        }
        _ = GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
        detach(error: nil)
        activeRequest = nil
        remoteRequest = nil
        clearProgressIdentity()
        log("session ended at account boundary without retaining remote progress")
    }

    private func remoteCommandIsSupported(_ command: Int) -> Bool {
        guard let status = remoteClient?.mediaStatus else { return true }
        guard status.isMediaCommandSupported(command) else {
            log("receiver does not support command=\(command)")
            return false
        }
        return true
    }

    private func clampedPlaybackRate(_ rate: Double) -> Double {
        min(max(rate, 0.5), 2.0)
    }

    private func attach(to session: GCKCastSession) {
        guard featureEnabled else {
            _ = GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
            return
        }
        let isNewSession: Bool
        if let attachedSession {
            isNewSession = attachedSession !== session
        } else {
            isNewSession = true
        }
        if isNewSession {
            remoteClient?.remove(self)
            remoteClient = session.remoteMediaClient
            remoteClient?.add(self)
        }
        attachedSession = session
        isSessionConnected = true
        sessionWasSuspended = false
        if let mediaStatus = session.remoteMediaClient?.mediaStatus {
            // Resuming a session does not prove its receiver media belongs to
            // Eclipse. Never adopt another sender's title/progress merely
            // because this app happened to reconnect to the same device.
            isRemoteMediaActive = mediaStatus.playerState != .idle && isCurrentRemoteMedia(mediaStatus)
        } else {
            isRemoteMediaActive = false
        }
        startProgressTimer()
        log("session connected device=\(session.device.friendlyName ?? "unknown")")
    }

    private func detach(error: Error?) {
        guard remoteClient != nil || isSessionConnected || isRemoteMediaActive || pendingLoad != nil || didPauseForPendingLoad || didStopLocalForActiveLoad else {
            return
        }
        let pending = pendingLoad
        let replacementWasInFlight = replacementTransactionID != nil
            || replacementLoadIssued
            || replacementCommitPending
            || replacementRecoveryPending
            || pending?.purpose == .replacement
            || loadPurpose == .replacement
        // Preserve the last confirmed A position during a B replacement. A
        // status from B may arrive before PlayerViewController commits B's
        // identity, so it must never be saved under A.
        if !replacementWasInFlight {
            publishRemoteProgress()
        }
        let wasSuspended = sessionWasSuspended
        let snapshot = pendingLoadSnapshot ?? loadSnapshot
        let pendingWasPaused = snapshot?.wasPaused ?? true
        let remoteWasPaused = replacementWasInFlight
            ? pendingWasPaused
            : (remoteIsPaused ?? lastRemoteWasPaused ?? pendingWasPaused)
        let shouldRestoreLocal = didPauseForPendingLoad || didStopLocalForActiveLoad || error != nil || wasSuspended
        let position: Double
        if replacementWasInFlight, let snapshot {
            position = max(0, snapshot.position)
        } else {
            position = lastRemotePosition > 0.1 ? lastRemotePosition : (snapshot?.position ?? 0)
        }
        let restoreOwner = handoffOwner
        remoteClient?.remove(self)
        remoteClient = nil
        attachedSession = nil
        tombstonePendingLoadIfNeeded()
        pendingLoadRequest = nil
        pendingLoad = nil
        cancelLoadTimeout()
        isSessionConnected = false
        isRemoteMediaActive = false
        stopProgressTimer()
        sessionWasSuspended = false
        didPauseForPendingLoad = false
        didStopLocalForActiveLoad = false
        loadSnapshot = nil
        pendingLoadSnapshot = nil
        loadPurpose = .handoff
        preparationOwner = nil
        handoffOwner = nil
        remoteRequest = nil
        remoteMediaIdentifier = nil
        remoteContentURL = nil
        clearProgressIdentity()
        if replacementWasInFlight {
            resetReplacementTransaction()
            replacementRecoveryPending = false
        }
        var didRestoreLocal = false
        if shouldRestoreLocal, let restoreOwner, restoreOwner.castIsVisible {
            restoreOwner.castDidEndUnexpectedly(position: position, shouldResume: !remoteWasPaused)
            didRestoreLocal = true
        }
        if replacementWasInFlight {
            if didRestoreLocal {
                finishReplacement(.restoredLocally(
                    "Google Cast disconnected before the new source could be loaded. Eclipse restored the current video locally."
                ))
            } else {
                finishReplacement(.failed("Google Cast disconnected before the new source could be loaded."))
            }
        }
        if !isPlayerVisible || !featureEnabled {
            activeRequest = nil
            eligibility = nil
        }
        log("session ended error=\(error != nil) suspended=\(wasSuspended)")
    }

    private func loadPreparedMediaIfPossible() {
        guard featureEnabled,
              isSessionConnected,
              pendingLoadRequest == nil,
              pendingLoad == nil else { return }
        guard let owner = preparationOwner,
              player === owner,
              owner.castIsVisible else {
            log("discarded prepared Cast load because its Player is no longer active")
            return
        }
        guard let eligibility else {
            log("waiting for direct-stream eligibility")
            return
        }
        switch eligibility {
        case .blocked(let reason):
            failPreparedLoad(reason)
        case .eligible(let descriptor):
            load(descriptor)
        case .eligibleWithWarnings(let descriptor, let warnings):
            guard confirmationGeneration == nil else { return }
            let generation = eligibilityGeneration
            let purpose = loadPurpose
            let transactionID = replacementTransactionID
            confirmationGeneration = generation
            owner.castRequiresConfirmation(
                title: "Cast Compatibility",
                message: warnings.joined(separator: "\n\n"),
                continueTitle: "Cast Without Subtitles"
            ) { [weak self] shouldContinue in
                guard let self else { return }
                guard self.featureEnabled,
                      self.eligibilityGeneration == generation,
                      self.confirmationGeneration == generation,
                      self.preparationOwner === owner,
                      self.player === owner,
                      owner.castIsVisible,
                      purpose != .replacement || self.replacementTransactionID == transactionID else { return }
                self.confirmationGeneration = nil
                if shouldContinue {
                    self.load(descriptor)
                } else {
                    self.log("load cancelled after compatibility warning")
                    self.failPreparedLoad("Casting was cancelled. Local playback is unchanged.")
                }
            }
        }
    }

    private func load(_ descriptor: CastMediaDescriptor) {
        guard featureEnabled,
              pendingLoadRequest == nil,
              pendingLoad == nil,
              let remoteClient,
              let playbackRequest = activeRequest,
              let owner = preparationOwner,
              player === owner,
              owner.castIsVisible else { return }
        let purpose = loadPurpose
        let transactionID = purpose == .replacement ? replacementTransactionID : nil
        guard purpose != .replacement || transactionID != nil else {
            failPreparedLoad("The Cast source change was superseded before it reached the TV.")
            return
        }
        let snapshotPosition: Double
        let wasPaused: Bool
        let playbackRate: Double
        if purpose == .replacement {
            // The local renderer is deliberately stopped while a receiver owns
            // playback, so it cannot describe the state that a source switch
            // should preserve. Carry the receiver's current position, pause
            // state, and rate into its replacement LOAD instead.
            let receiverPosition = remoteClient.approximateStreamPosition()
            snapshotPosition = receiverPosition.isFinite && receiverPosition >= 0
                ? receiverPosition
                : max(0, lastRemotePosition)
            wasPaused = remoteIsPaused ?? lastRemoteWasPaused ?? !descriptor.shouldAutoplay
            playbackRate = remotePlaybackRate ?? owner.castPlaybackRate
        } else {
            let currentPosition = owner.castCurrentPosition
            snapshotPosition = currentPosition.isFinite && currentPosition > 0.1
                ? currentPosition
                : descriptor.startPosition
            wasPaused = owner.castIsPaused
            playbackRate = owner.castPlaybackRate
        }
        pendingLoadSnapshot = (snapshotPosition, wasPaused)
        if purpose == .handoff {
            // Set the latch before pausing the renderer: its delegate can fire
            // synchronously and must not treat this intentional pause as a
            // local playback change.
            handoffOwner = owner
            didPauseForPendingLoad = true
            didStopLocalForActiveLoad = false
            owner.castWillBeginHandoff()
        } else {
            replacementLoadIssued = true
        }

        let metadata = GCKMediaMetadata(metadataType: .generic)
        metadata.setString(descriptor.title, forKey: kGCKMetadataKeyTitle)
        if let subtitle = descriptor.subtitle, !subtitle.isEmpty {
            metadata.setString(subtitle, forKey: kGCKMetadataKeySubtitle)
        }
        if let artworkURL = descriptor.artworkURL,
           let scheme = artworkURL.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            metadata.addImage(GCKImage(url: artworkURL, width: 1280, height: 720))
        }

        let tracks = descriptor.subtitleTracks.compactMap { track in
            GCKMediaTrack(
                identifier: track.identifier,
                contentIdentifier: track.url.absoluteString,
                contentType: track.contentType,
                type: .text,
                textSubtype: .subtitles,
                name: track.name,
                languageCode: track.languageCode,
                customData: nil
            )
        }
        let mediaBuilder = GCKMediaInformationBuilder(contentURL: descriptor.url)
        mediaBuilder.contentID = descriptor.url.absoluteString
        mediaBuilder.contentType = descriptor.contentType
        mediaBuilder.streamType = .buffered
        mediaBuilder.metadata = metadata
        mediaBuilder.mediaTracks = tracks
        mediaBuilder.customData = descriptor.identity

        let loadBuilder = GCKMediaLoadRequestDataBuilder()
        loadBuilder.mediaInformation = mediaBuilder.build()
        loadBuilder.autoplay = NSNumber(value: !wasPaused)
        loadBuilder.startTime = max(0, snapshotPosition)
        loadBuilder.playbackRate = Float(clampedPlaybackRate(playbackRate))
        loadBuilder.activeTrackIDs = descriptor.activeTrackIDs
        let pending = PendingCastLoad(
            token: UUID(),
            purpose: purpose,
            playbackRequest: playbackRequest,
            descriptor: descriptor,
            replacementTransactionID: transactionID
        )
        // Install the pending state before sending the command. Some receiver
        // transports can publish a media-status update immediately, and that
        // update must be associated with this exact LOAD rather than treated
        // as an unexpected takeover of the prior source.
        pendingLoad = pending
        let request = remoteClient.loadMedia(with: loadBuilder.build())
        pendingLoadRequest = request
        request.delegate = self
        scheduleLoadTimeout(for: request, token: pending.token)
        log("load requested type=\(descriptor.contentType) position=\(Int(snapshotPosition)) tracks=\(tracks.count) purpose=\(purpose)")
    }

    private func completePendingLoadIfReady() {
        guard let pending = pendingLoad,
              pending.requestDidComplete,
              pending.receivedExpectedMediaStatus,
              let status = remoteClient?.mediaStatus,
              status.playerState != .idle,
              mediaStatus(status, matches: pending.descriptor) else { return }
        handleLoadSuccess(pending)
    }

    private func handleLoadSuccess(_ pending: PendingCastLoad) {
        guard pendingLoad === pending else { return }
        guard pending.purpose != .replacement
                || replacementTransactionID == pending.replacementTransactionID else {
            tombstone(descriptor: pending.descriptor)
            pendingLoadRequest?.delegate = nil
            pendingLoadRequest?.cancel()
            pendingLoadRequest = nil
            pendingLoad = nil
            return
        }
        cancelLoadTimeout()
        pendingLoadRequest?.delegate = nil
        pendingLoadRequest = nil
        pendingLoad = nil
        isRemoteMediaActive = true
        if pending.purpose == .handoff {
            didStopLocalForActiveLoad = true
        }
        didPauseForPendingLoad = false
        if let pendingLoadSnapshot {
            loadSnapshot = pendingLoadSnapshot
        }
        self.pendingLoadSnapshot = nil
        activeRequest = pending.playbackRequest
        remoteRequest = pending.playbackRequest
        remoteMediaIdentifier = mediaIdentifier(in: pending.descriptor)
        remoteContentURL = pending.descriptor.url
        setProgressIdentity(for: pending.playbackRequest)
        eligibility = nil
        preparationOwner = nil
        if pending.purpose == .handoff {
            handoffOwner?.castDidBecomeActive(
                deviceName: GCKCastContext.sharedInstance().sessionManager.currentCastSession?.device.friendlyName
            )
        } else if let transactionID = pending.replacementTransactionID {
            replacementLoadIssued = true
            replacementCommitPending = true
            finishReplacement(.loaded(transactionID))
        }
        loadPurpose = .handoff
        startProgressTimer()
        log("load completed purpose=\(pending.purpose)")
    }

    private func handleLoadFailure(_ message: String, expectedToken: UUID? = nil) {
        guard let pending = pendingLoad else {
            if loadPurpose == .replacement || replacementTransactionID != nil {
                failPreparedLoad(message)
            }
            return
        }
        guard expectedToken == nil || pending.token == expectedToken else { return }
        let purpose = pending.purpose
        let failedLoadSnapshot = pendingLoadSnapshot ?? loadSnapshot
        let status = remoteClient?.mediaStatus
        let oldRemoteIsStillPlaying = purpose == .replacement
            && status?.playerState != .idle
            && status.map { isCurrentRemoteMedia($0) } == true
        let failedLoadMayHaveReachedReceiver = status?.playerState != .idle
            && status.map { mediaStatus($0, matches: pending.descriptor) } == true

        cancelLoadTimeout()
        tombstone(descriptor: pending.descriptor)
        pendingLoadRequest?.delegate = nil
        pendingLoadRequest?.cancel()
        pendingLoadRequest = nil
        pendingLoad = nil
        pendingLoadSnapshot = nil
        eligibility = nil
        preparationOwner = nil

        if purpose == .replacement {
            activeRequest = remoteRequest
            if oldRemoteIsStillPlaying {
                // The old receiver stream is still authoritative, so preserve
                // it exactly as it was and let the user choose another source.
                isRemoteMediaActive = true
                replacementLoadIssued = false
                replacementCommitPending = false
                replacementTransactionID = nil
                replacementRecoveryPending = false
                finishReplacement(.failed(message))
            } else {
                // The receiver lost A or may have loaded B despite reporting a
                // failure. End the receiver session before restoring local A.
                let shouldEndReceiver = failedLoadMayHaveReachedReceiver || status?.playerState != .idle
                let position = failedLoadSnapshot?.position ?? max(0, lastRemotePosition)
                let wasPaused = failedLoadSnapshot?.wasPaused ?? lastRemoteWasPaused ?? false
                let restoreOwner = handoffOwner
                isRemoteMediaActive = false
                didPauseForPendingLoad = false
                didStopLocalForActiveLoad = false
                loadSnapshot = nil
                handoffOwner = nil
                remoteRequest = nil
                remoteMediaIdentifier = nil
                remoteContentURL = nil
                clearProgressIdentity()
                resetReplacementTransaction()
                replacementRecoveryPending = false
                // Clear ownership before ending the SDK session. Its didEnd
                // callback can be synchronous on some receiver failures.
                if shouldEndReceiver { endSessionAndStopCasting() }
                if let restoreOwner, restoreOwner.castIsVisible {
                    restoreOwner.castDidEndUnexpectedly(position: position, shouldResume: !wasPaused)
                    finishReplacement(.restoredLocally(
                        "The TV could not load the new source. Eclipse restored the current video locally."
                    ))
                } else {
                    finishReplacement(.failed(message))
                }
            }
        } else {
            let shouldEndReceiver = failedLoadMayHaveReachedReceiver
            let restoreOwner = handoffOwner ?? player
            let shouldResumeLocal = didPauseForPendingLoad
            isRemoteMediaActive = false
            didPauseForPendingLoad = false
            didStopLocalForActiveLoad = false
            loadSnapshot = nil
            handoffOwner = nil
            remoteRequest = nil
            remoteMediaIdentifier = nil
            remoteContentURL = nil
            clearProgressIdentity()
            if shouldEndReceiver { endSessionAndStopCasting() }
            if let restoreOwner, restoreOwner.castIsVisible {
                restoreOwner.castDidFailOrCancel(
                    message: message,
                    resumeLocal: shouldResumeLocal,
                    position: shouldResumeLocal ? failedLoadSnapshot?.position : nil
                )
            }
        }
        loadPurpose = .handoff
        log("load failed purpose=\(purpose)")
    }

    private func failPreparedLoad(_ message: String) {
        let purpose = loadPurpose
        let owner = preparationOwner ?? player
        confirmationGeneration = nil
        eligibility = nil
        preparationOwner = nil
        if purpose == .replacement || replacementTransactionID != nil {
            activeRequest = remoteRequest
            resetReplacementTransaction()
            replacementRecoveryPending = false
            finishReplacement(.failed(message))
        } else if let owner, owner.castIsVisible {
            owner.castDidFailOrCancel(message: message, resumeLocal: false, position: nil)
        }
        loadPurpose = .handoff
    }

    private func finishReplacement(_ result: GoogleCastReplacementResult) {
        guard let completion = replacementCompletion else { return }
        replacementCompletion = nil
        completion(result)
    }

    private func resetReplacementTransaction() {
        replacementTransactionID = nil
        replacementLoadIssued = false
        replacementCommitPending = false
    }

    private func cancelCurrentPreparation(reason: String) {
        let pendingPurpose = pendingLoad?.purpose
        let purpose = pendingPurpose ?? loadPurpose
        let wasReplacement = purpose == .replacement || replacementTransactionID != nil
        // An eligibility probe or compatibility alert has not changed the
        // receiver, so cancelling it must leave continued A playback as an
        // ordinary remote session. Preserve recovery state only once B's LOAD
        // was actually issued; the SDK may still apply that cancelled request.
        let replacementMayHaveReachedReceiver = pendingPurpose == .replacement || replacementLoadIssued
        eligibilityGeneration = UUID()
        confirmationGeneration = nil
        eligibility = nil
        preparationOwner = nil
        tombstonePendingLoadIfNeeded()
        pendingLoadRequest = nil
        pendingLoad = nil
        cancelLoadTimeout()
        if wasReplacement {
            activeRequest = remoteRequest
            replacementRecoveryPending = replacementMayHaveReachedReceiver
            resetReplacementTransaction()
            finishReplacement(.failed(reason))
        }
        loadPurpose = .handoff
    }

    private func scheduleLoadTimeout(for request: GCKRequest, token: UUID) {
        cancelLoadTimeout()
        let generation = UUID()
        loadGeneration = generation
        let workItem = DispatchWorkItem { [weak self, weak request] in
            Task { @MainActor in
                guard let self,
                      self.loadGeneration == generation,
                      let request,
                      request === self.pendingLoadRequest,
                      self.pendingLoad?.token == token else { return }
                let purpose = self.pendingLoad?.purpose
                request.delegate = nil
                request.cancel()
                self.handleLoadFailure(
                    "The Cast device did not respond while loading this stream. Eclipse kept local playback available.",
                    expectedToken: token
                )
                // For an initial handoff there is no confirmed remote stream to
                // preserve, so ending the session closes a late cancelled LOAD.
                if purpose == .handoff {
                    self.endSessionAndStopCasting()
                }
            }
        }
        loadTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: workItem)
    }

    private func cancelLoadTimeout() {
        loadTimeoutWorkItem?.cancel()
        loadTimeoutWorkItem = nil
        loadGeneration = UUID()
    }

    private func mediaIdentifier(in descriptor: CastMediaDescriptor) -> String? {
        descriptor.identity["eclipseCastMediaID"] as? String
    }

    private func mediaIdentifier(in status: GCKMediaStatus) -> String? {
        (status.mediaInformation?.customData as? [String: Any])?["eclipseCastMediaID"] as? String
    }

    private func mediaStatus(_ status: GCKMediaStatus, matches descriptor: CastMediaDescriptor) -> Bool {
        if let expectedIdentifier = mediaIdentifier(in: descriptor),
           let actualIdentifier = mediaIdentifier(in: status) {
            return actualIdentifier == expectedIdentifier
        }
        guard let mediaInformation = status.mediaInformation else { return false }
        return mediaInformation.contentURL == descriptor.url
            || mediaInformation.contentID == descriptor.url.absoluteString
    }

    private func isCurrentRemoteMedia(_ status: GCKMediaStatus) -> Bool {
        guard remoteRequest != nil else { return false }
        if let expectedIdentifier = remoteMediaIdentifier,
           let actualIdentifier = mediaIdentifier(in: status) {
            return actualIdentifier == expectedIdentifier
        }
        guard let expectedURL = remoteContentURL,
              let mediaInformation = status.mediaInformation else { return false }
        return mediaInformation.contentURL == expectedURL
            || mediaInformation.contentID == expectedURL.absoluteString
    }

    private func ownsCurrentRemoteMedia() -> Bool {
        guard featureEnabled,
              isRemoteMediaActive,
              let status = remoteClient?.mediaStatus,
              status.playerState != .idle else { return false }
        return isCurrentRemoteMedia(status)
    }

    private func setProgressIdentity(for request: PlaybackRequest) {
        guard let identity = CastProgressIdentity(request: request) else {
            clearProgressIdentity()
            return
        }
        progressIdentity = identity
        if let data = try? JSONEncoder().encode(identity) {
            UserDefaults.standard.set(data, forKey: Self.progressIdentityDefaultsKey)
        }
    }

    private func tombstone(descriptor: CastMediaDescriptor) {
        tombstonedLoad = TombstonedCastLoad(
            descriptor: descriptor,
            expiresAt: Date().addingTimeInterval(30)
        )
    }

    private func tombstonePendingLoadIfNeeded() {
        guard let pending = pendingLoad else { return }
        tombstone(descriptor: pending.descriptor)
        pendingLoadRequest?.delegate = nil
        pendingLoadRequest?.cancel()
    }

    private func consumeTombstonedLoadIfNeeded(_ status: GCKMediaStatus?) -> Bool {
        guard let tombstonedLoad else { return false }
        guard tombstonedLoad.expiresAt > Date() else {
            self.tombstonedLoad = nil
            return false
        }
        guard let status,
              status.playerState != .idle,
              mediaStatus(status, matches: tombstonedLoad.descriptor) else { return false }
        self.tombstonedLoad = nil
        log("stopped a late cancelled receiver LOAD")
        endSessionAndStopCasting()
        return true
    }

    private func endSessionAndStopCasting() {
        guard GCKCastContext.isSharedInstanceInitialized(),
              GCKCastContext.sharedInstance().sessionManager.currentCastSession != nil else { return }
        _ = GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
    }

    private func startProgressTimer() {
        guard featureEnabled, progressTimer == nil else { return }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publishRemoteProgress() }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func publishRemoteProgress() {
        guard featureEnabled,
              isRemoteMediaActive,
              let remoteClient,
              let status = remoteClient.mediaStatus,
              status.playerState != .idle,
              isCurrentRemoteMedia(status) else { return }
        // Evaluation may take a moment, during which A remains authoritative.
        // Suppress only after the receiver has actually received B's LOAD and
        // until PlayerViewController commits B's matching title/metadata.
        guard !replacementLoadIssued, !replacementCommitPending else { return }
        let position = remoteClient.approximateStreamPosition()
        let duration = status.mediaInformation?.streamDuration ?? 0
        if position.isFinite { lastRemotePosition = max(0, position) }
        if duration.isFinite { lastRemoteDuration = max(0, duration) }
        lastRemoteWasPaused = status.playerState == .paused
        player?.castDidUpdate(
            position: lastRemotePosition,
            duration: lastRemoteDuration,
            isPaused: status.playerState == .paused,
            playbackRate: Double(status.playbackRate)
        )
        if player == nil {
            persistDetachedProgressIfNeeded(isPaused: status.playerState == .paused)
        }
    }

    private func persistDetachedProgressIfNeeded(isPaused: Bool) {
        guard lastRemoteDuration >= 5,
              lastRemotePosition >= 0,
              let mediaInfo = remoteRequest?.mediaInfo else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastDetachedProgressSaveAt >= 10 else { return }
        lastDetachedProgressSaveAt = now
        PlaybackProgressPersistence.persist(
            mediaInfo: mediaInfo,
            position: lastRemotePosition,
            duration: lastRemoteDuration,
            playbackContext: remoteRequest?.episodePlaybackContext,
            traktAction: isPaused ? nil : .start
        )
    }

    private func handleRemoteMediaOwnershipLoss() {
        guard isRemoteMediaActive else { return }
        let restoreOwner = handoffOwner
        let position = lastRemotePosition > 0.1 ? lastRemotePosition : (loadSnapshot?.position ?? 0)
        let replacementWasInFlight = replacementTransactionID != nil || replacementCommitPending || replacementRecoveryPending
        isRemoteMediaActive = false
        didPauseForPendingLoad = false
        didStopLocalForActiveLoad = false
        loadSnapshot = nil
        pendingLoadSnapshot = nil
        remoteRequest = nil
        remoteMediaIdentifier = nil
        remoteContentURL = nil
        handoffOwner = nil
        clearProgressIdentity()
        if replacementWasInFlight {
            resetReplacementTransaction()
            replacementRecoveryPending = false
            if let restoreOwner, restoreOwner.castIsVisible {
                restoreOwner.castDidEndUnexpectedly(position: position, shouldResume: false)
                finishReplacement(.restoredLocally(
                    "The Cast receiver changed media before Eclipse could finish the source change. Eclipse restored the current video locally."
                ))
            } else {
                finishReplacement(.failed("The Cast receiver changed media before Eclipse could finish the source change."))
            }
        } else if let restoreOwner, restoreOwner.castIsVisible {
            // Another sender took control. Restore our source paused so audio
            // cannot compete with the receiver's new media.
            restoreOwner.castDidEndUnexpectedly(position: position, shouldResume: false)
        }
        log("receiver media no longer matches Eclipse's active handoff")
    }

    private func handleRemoteIdle(_ status: GCKMediaStatus) {
        let idleReason = status.idleReason
        guard idleReason != .none else { return }
        let restoreOwner = handoffOwner
        let replacementWasInFlight = replacementTransactionID != nil || replacementCommitPending || replacementRecoveryPending
        let snapshot = loadSnapshot
        let shouldResume = idleReason != .finished && !(lastRemoteWasPaused ?? false)
        let position: Double
        if replacementWasInFlight, let snapshot {
            position = max(0, snapshot.position)
        } else {
            position = lastRemotePosition > 0.1 ? lastRemotePosition : (snapshot?.position ?? 0)
        }
        isRemoteMediaActive = false
        didPauseForPendingLoad = false
        didStopLocalForActiveLoad = false
        loadSnapshot = nil
        pendingLoadSnapshot = nil
        remoteRequest = nil
        remoteMediaIdentifier = nil
        remoteContentURL = nil
        handoffOwner = nil
        clearProgressIdentity()
        if replacementWasInFlight {
            resetReplacementTransaction()
            replacementRecoveryPending = false
            if let restoreOwner, restoreOwner.castIsVisible {
                restoreOwner.castDidEndUnexpectedly(position: position, shouldResume: !snapshotWasPaused(snapshot))
                finishReplacement(.restoredLocally(
                    "The TV stopped while Eclipse was changing the Cast source. Eclipse restored the current video locally."
                ))
            } else {
                finishReplacement(.failed("The TV stopped while Eclipse was changing the Cast source."))
            }
        } else if let restoreOwner, restoreOwner.castIsVisible {
            if idleReason == .error {
                restoreOwner.castDidFailOrCancel(
                    message: "The TV could not play this stream. Its codec, container, or CORS policy may not be supported.",
                    resumeLocal: shouldResume,
                    position: position
                )
            } else {
                restoreOwner.castDidEndUnexpectedly(position: position, shouldResume: shouldResume)
            }
        }
        log("remote playback entered idle state reason=\(idleReason.rawValue)")
    }

    private func snapshotWasPaused(_ snapshot: (position: Double, wasPaused: Bool)?) -> Bool {
        snapshot?.wasPaused ?? (lastRemoteWasPaused ?? true)
    }

    private func log(_ message: String) {
        Logger.shared.log("GoogleCast: \(message)", type: "Player")
    }

    private func clearProgressIdentity() {
        progressIdentity = nil
        UserDefaults.standard.removeObject(forKey: Self.progressIdentityDefaultsKey)
    }
}

extension GoogleCastCoordinator: @preconcurrency GCKSessionManagerListener {
    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKSession) {
        guard featureEnabled else {
            _ = sessionManager.endSessionAndStopCasting(true)
            return
        }
        guard let castSession = session as? GCKCastSession else { return }
        attach(to: castSession)
        loadPreparedMediaIfPossible()
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didResumeSession session: GCKSession) {
        guard featureEnabled else {
            _ = sessionManager.endSessionAndStopCasting(true)
            return
        }
        guard let castSession = session as? GCKCastSession else { return }
        attach(to: castSession)
        if !isRemoteMediaActive {
            loadPreparedMediaIfPossible()
        }
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didSuspend session: GCKSession, with reason: GCKConnectionSuspendReason) {
        guard let castSession = session as? GCKCastSession,
              let attachedSession,
              attachedSession === castSession else { return }
        sessionWasSuspended = true
        log("session suspended reason=\(reason.rawValue)")
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKSession, withError error: Error?) {
        guard let castSession = session as? GCKCastSession,
              let attachedSession,
              attachedSession === castSession else { return }
        detach(error: error)
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKSession, withError error: Error) {
        guard featureEnabled else { return }
        if let attachedSession,
           let castSession = session as? GCKCastSession,
           attachedSession !== castSession {
            return
        }
        let message = "Eclipse could not connect to that Cast device. Local playback is unchanged."
        if pendingLoad != nil {
            handleLoadFailure(message)
        } else {
            failPreparedLoad(message)
        }
    }
}

extension GoogleCastCoordinator: @preconcurrency GCKRemoteMediaClientListener {
    func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        guard client === remoteClient else { return }
        if consumeTombstonedLoadIfNeeded(mediaStatus) { return }
        if let pending = pendingLoad {
            guard let status = mediaStatus else { return }
            if status.playerState != .idle,
               self.mediaStatus(status, matches: pending.descriptor) {
                pending.receivedExpectedMediaStatus = true
                completePendingLoadIfReady()
            } else if status.playerState == .idle,
                      status.idleReason == .error {
                // A receiver can surface a media error before the request
                // delegate reports it. Other idle states may belong to A while
                // B is replacing it, so leave those to the timeout.
                handleLoadFailure(
                    "The TV could not load this direct stream. Eclipse will keep local playback available.",
                    expectedToken: pending.token
                )
            }
            return
        }
        guard let mediaStatus else {
            if isRemoteMediaActive { handleRemoteMediaOwnershipLoss() }
            return
        }
        if mediaStatus.playerState == .idle {
            if isRemoteMediaActive || didStopLocalForActiveLoad || didPauseForPendingLoad {
                handleRemoteIdle(mediaStatus)
            }
            return
        }
        guard isCurrentRemoteMedia(mediaStatus) else {
            handleRemoteMediaOwnershipLoss()
            return
        }
        isRemoteMediaActive = true
        publishRemoteProgress()
    }
}

extension GoogleCastCoordinator: @preconcurrency GCKRequestDelegate {
    func requestDidComplete(_ request: GCKRequest) {
        guard request === pendingLoadRequest, let pending = pendingLoad else { return }
        pending.requestDidComplete = true
        completePendingLoadIfReady()
    }

    func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        guard request === pendingLoadRequest, let pending = pendingLoad else { return }
        handleLoadFailure(
            "The TV could not load this direct stream. Eclipse will keep it playing locally.",
            expectedToken: pending.token
        )
    }

    func request(_ request: GCKRequest, didAbortWith abortReason: GCKRequestAbortReason) {
        guard request === pendingLoadRequest, let pending = pendingLoad else { return }
        handleLoadFailure(
            "Casting was cancelled. Eclipse will keep the stream playing locally.",
            expectedToken: pending.token
        )
    }
}

enum CastEligibilityEvaluator {
    private static let supportedByExtension: [String: String] = [
        "mp4": "video/mp4",
        "m4v": "video/mp4",
        "webm": "video/webm",
        "ts": "video/mp2t",
        "m2ts": "video/mp2t",
        "m3u8": "application/x-mpegURL",
        "mpd": "application/dash+xml"
    ]
    private static let unsupportedExtensions: Set<String> = ["mkv", "avi", "flv", "wmv", "movpkg"]

    static func evaluate(request: PlaybackRequest) async -> CastEligibilityResult {
        guard let scheme = request.url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .blocked("Google Cast can only open a direct HTTP or HTTPS stream. Downloads, local files, torrents, and magnets remain available in MoltenVK.")
        }
        if request.url.host?.lowercased() == "localhost" || request.url.host == "127.0.0.1" || request.url.host == "::1" {
            return .blocked("This stream is served only to the iPhone or iPad. The TV cannot reach Eclipse's local playback proxy.")
        }
        let ext = request.url.pathExtension.lowercased()
        if unsupportedExtensions.contains(ext) {
            return .blocked("The TV receiver does not support the .\(ext) container directly. Continue using MoltenVK for this stream.")
        }

        var contentType = supportedByExtension[ext]
        if !request.headers.isEmpty || contentType == nil {
            guard let probe = await probeDirectURL(request.url) else {
                return .blocked("This source only works with Eclipse's local request headers or could not be reached without them, so the TV cannot open it directly.")
            }
            guard (200..<400).contains(probe.statusCode) else {
                return .blocked("The direct stream returned HTTP \(probe.statusCode) without Eclipse's playback headers, so it cannot be sent to the TV.")
            }
            let probedType = normalizedContentType(probe.mimeType)
            if probedType == "text/html" || probedType == "application/json" {
                return .blocked("The direct URL returned a web or authentication response instead of media. Continue using MoltenVK.")
            }
            contentType = castContentType(probedType) ?? contentType
        }
        guard let resolvedContentType = contentType else {
            return .blocked("Eclipse could not identify this as MP4, WebM, MPEG-TS, HLS, or DASH media for the Cast receiver.")
        }

        let tracks = subtitleTracks(for: request)
        let selectedTrack = selectedSubtitleTrack(in: tracks, request: request)
        var warnings: [String] = []
        if request.mediaSelectionIntent.subtitlesEnabled,
           !request.subtitles.isEmpty,
           selectedTrack == nil {
            warnings.append("The selected subtitles are local, protected, or use a format such as SRT/ASS that the Default Media Receiver cannot fetch. The video can be cast without those subtitles.")
        }

        let descriptor = CastMediaDescriptor(
            url: request.url,
            contentType: resolvedContentType,
            title: request.title.isEmpty ? "Eclipse" : request.title,
            subtitle: request.subtitle,
            artworkURL: request.artworkURL,
            startPosition: request.resumePosition ?? 0,
            shouldAutoplay: true,
            subtitleTracks: tracks,
            activeTrackIDs: selectedTrack.map { [NSNumber(value: $0.identifier)] } ?? [],
            identity: identity(for: request)
        )
        return warnings.isEmpty ? .eligible(descriptor) : .eligibleWithWarnings(descriptor, warnings)
    }

    private static func probeDirectURL(_ url: URL) async -> HTTPURLResponse? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let (_, response) = try? await session.data(for: head),
           let http = response as? HTTPURLResponse,
           (200..<400).contains(http.statusCode) {
            return http
        }
        // CDNs commonly reject or authenticate HEAD independently from media
        // GETs. A tiny range request is the closest useful receiver probe for
        // every non-success/inconclusive HEAD response, not just 405/501.
        var range = URLRequest(url: url)
        range.httpMethod = "GET"
        range.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        range.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        guard let (_, response) = try? await session.data(for: range) else { return nil }
        return response as? HTTPURLResponse
    }

    private static func normalizedContentType(_ value: String?) -> String? {
        value?.split(separator: ";", maxSplits: 1).first.map(String.init)?.lowercased()
    }

    private static func castContentType(_ value: String?) -> String? {
        guard let value else { return nil }
        if value == "video/mp4" || value == "application/mp4" { return "video/mp4" }
        if value == "video/webm" { return "video/webm" }
        if value == "video/mp2t" || value == "video/mpeg" { return "video/mp2t" }
        if value.contains("mpegurl") || value.contains("vnd.apple.mpegurl") { return "application/x-mpegURL" }
        if value == "application/dash+xml" { return value }
        return nil
    }

    private static func subtitleTracks(for request: PlaybackRequest) -> [CastSubtitleTrack] {
        request.subtitles.enumerated().compactMap { index, rawURL in
            guard let url = URL(string: rawURL),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  request.subtitleHeadersByURL?[rawURL]?.isEmpty != false else { return nil }
            let ext = url.pathExtension.lowercased()
            let contentType: String
            switch ext {
            case "vtt": contentType = "text/vtt"
            case "ttml", "dfxp", "xml": contentType = "application/ttml+xml"
            default: return nil
            }
            let name = request.subtitleNames?[safe: index] ?? "Subtitle \(index + 1)"
            return CastSubtitleTrack(
                identifier: index + 1,
                url: url,
                contentType: contentType,
                name: name,
                languageCode: languageCode(from: name)
            )
        }
    }

    private static func selectedSubtitleTrack(in tracks: [CastSubtitleTrack], request: PlaybackRequest) -> CastSubtitleTrack? {
        guard request.mediaSelectionIntent.subtitlesEnabled else { return nil }
        guard let preferred = comparableLanguageCode(request.mediaSelectionIntent.preferredSubtitleLanguage) else {
            return tracks.first
        }
        return tracks.first { track in
            comparableLanguageCode(track.languageCode) == preferred
        } ?? tracks.first
    }

    private static func languageCode(from name: String) -> String? {
        let normalized = name
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let tokens = Set(
            normalized.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
        let knownLanguages: [(code: String, aliases: Set<String>)] = [
            ("en", ["en", "eng", "english"]),
            ("ja", ["ja", "jpn", "japanese"]),
            ("zh", ["zh", "zho", "chi", "chinese", "mandarin", "cantonese"]),
            ("ko", ["ko", "kor", "korean"]),
            ("es", ["es", "spa", "spanish"]),
            ("fr", ["fr", "fra", "fre", "french"]),
            ("de", ["de", "deu", "ger", "german"]),
            ("it", ["it", "ita", "italian"]),
            ("pt", ["pt", "por", "portuguese"]),
            ("ar", ["ar", "ara", "arabic"]),
            ("ru", ["ru", "rus", "russian"])
        ]
        return knownLanguages.first(where: { !$0.aliases.isDisjoint(with: tokens) })?.code
    }

    private static func comparableLanguageCode(_ rawValue: String?) -> String? {
        guard let normalized = PlaybackMediaSelectionIntent.normalizedLanguage(rawValue) else { return nil }
        let base = normalized.split(separator: "-").first.map(String.init) ?? normalized
        let aliases = [
            "eng": "en", "jpn": "ja", "zho": "zh", "chi": "zh", "kor": "ko",
            "spa": "es", "fra": "fr", "fre": "fr", "deu": "de", "ger": "de",
            "ita": "it", "por": "pt", "ara": "ar", "rus": "ru"
        ]
        return aliases[base] ?? base
    }

    private static func identity(for request: PlaybackRequest) -> [String: Any] {
        // This per-LOAD nonce is more reliable than a URL alone: providers can
        // reuse a manifest URL across episodes, and a cancelled GCK request can
        // still reach the receiver after a newer selection is underway.
        var value: [String: Any] = [
            "source": "Eclipse",
            "title": request.title,
            "eclipseCastMediaID": UUID().uuidString
        ]
        switch request.mediaInfo {
        case .movie(let id, _, _, _):
            value["mediaType"] = "movie"
            value["tmdbID"] = id
        case .episode(let showID, let season, let episode, _, _, _):
            value["mediaType"] = "episode"
            value["tmdbID"] = showID
            value["season"] = season
            value["episode"] = episode
        case .none:
            break
        }
        if let imdbID = request.imdbID { value["imdbID"] = imdbID }
        return value
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct GoogleCastMiniControllerBar: View {
    @ObservedObject private var cast = GoogleCastCoordinator.shared

    var body: some View {
        Group {
            if cast.shouldShowMiniController {
                GoogleCastMiniControllerRepresentable()
                    .frame(height: 64)
                    .background(Color.black.opacity(0.94))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: cast.shouldShowMiniController)
    }
}

private struct GoogleCastMiniControllerRepresentable: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> GCKUIMiniMediaControlsViewController {
        GCKCastContext.sharedInstance().createMiniMediaControlsViewController()
    }

    func updateUIViewController(_ uiViewController: GCKUIMiniMediaControlsViewController, context: Context) {}
}
#endif
