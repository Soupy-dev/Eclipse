import Combine
import CryptoKit
import Foundation
import GroupActivities
#if os(iOS)
import UIKit
#endif

struct WatchTogetherMediaDescriptor: Codable, Equatable, Sendable {
    let tmdbID: Int
    let mediaType: String
    let seasonNumber: Int?
    let episodeNumber: Int?
    let playbackContext: EpisodePlaybackContext?
    let isAnime: Bool
    let title: String?

    init(
        tmdbID: Int,
        mediaType: String,
        seasonNumber: Int?,
        episodeNumber: Int?,
        playbackContext: EpisodePlaybackContext? = nil,
        isAnime: Bool = false,
        title: String? = nil
    ) {
        self.tmdbID = tmdbID
        self.mediaType = mediaType.lowercased()
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.playbackContext = playbackContext
        self.isAnime = isAnime
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = normalizedTitle?.isEmpty == false ? String(normalizedTitle!.prefix(120)) : nil
    }

    private enum CodingKeys: String, CodingKey {
        case tmdbID
        case mediaType
        case seasonNumber
        case episodeNumber
        case playbackContext
        case isAnime
        case title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tmdbID = try container.decode(Int.self, forKey: .tmdbID)
        mediaType = try container.decode(String.self, forKey: .mediaType).lowercased()
        seasonNumber = try container.decodeIfPresent(Int.self, forKey: .seasonNumber)
        episodeNumber = try container.decodeIfPresent(Int.self, forKey: .episodeNumber)
        playbackContext = try container.decodeIfPresent(EpisodePlaybackContext.self, forKey: .playbackContext)
        isAnime = try container.decodeIfPresent(Bool.self, forKey: .isAnime) ?? false
        title = try container.decodeIfPresent(String.self, forKey: .title)
    }

    var stableKey: String? {
        guard tmdbID > 0 else { return nil }
        switch mediaType {
        case "movie":
            return "movie:\(tmdbID)"
        case "tv":
            if isAnime || playbackContext?.hasAnimeMediaId == true {
                guard let context = playbackContext, context.hasAnimeMediaId else { return nil }
                let animeID = context.anilistMediaId.map(String.init)
                    ?? context.kitsuMediaId.map { "kitsu:\($0)" }
                    ?? "missing"
                return "anime-episode:\(tmdbID):\(animeID):\(context.localSeasonNumber):\(context.localEpisodeNumber)"
            }
            guard let seasonNumber, let episodeNumber, seasonNumber > 0, episodeNumber > 0 else {
                return nil
            }
            return "episode:\(tmdbID):\(seasonNumber):\(episodeNumber)"
        default:
            return nil
        }
    }

    var localSeasonNumber: Int? {
        playbackContext?.localSeasonNumber ?? seasonNumber
    }

    var localEpisodeNumber: Int? {
        playbackContext?.localEpisodeNumber ?? episodeNumber
    }

    var animeContextFailureReason: String? {
        guard isAnime, mediaType == "tv" else { return nil }
        guard let playbackContext else {
            return "This anime episode has no anime playback context. Watch Together stopped instead of guessing an episode. Reopen it from the anime episode list and try again."
        }
        guard playbackContext.hasAnimeMediaId else {
            return "This anime episode has no AniList or Kitsu identity. Watch Together stopped instead of falling back to TMDB. Enable full anime detail metadata, reopen the episode, and try again."
        }
        if playbackContext.isSpecial, playbackContext.anilistMediaId == nil {
            return "This anime special has no AniList identity, so the other device cannot resolve it exactly. Reopen it after full anime metadata loads and try again."
        }
        return nil
    }
}

struct WatchTogetherSharedState: Codable, Equatable, Sendable {
    let mediaIdentifier: String
    let media: WatchTogetherMediaDescriptor
    let mediaRevision: UInt64
    let stateRevision: UInt64
    let position: Double
    let duration: Double?
    let normalizedProgress: Double?
    let isPlaying: Bool
    let playbackRate: Double
    /// True while the destination renderer is still resolving. This travels with snapshots so
    /// a successor authority can release the paused transition if the original authority leaves.
    let awaitsReadiness: Bool?
    let sentAt: TimeInterval
    let authorityInstanceID: UUID

    func projectedPosition(at timestamp: TimeInterval = Date().timeIntervalSince1970) -> Double {
        guard isPlaying else { return position }
        let elapsed = timestamp - sentAt
        guard (0...5).contains(elapsed) else { return position }
        let projected = position + elapsed * playbackRate
        if let duration, duration.isFinite, duration > 0 {
            return min(max(0, projected), duration)
        }
        return max(0, projected)
    }
}

struct WatchTogetherJoinRequest: Identifiable, Equatable {
    let id: String
    let media: WatchTogetherMediaDescriptor
    let title: String
    let targetSceneSessionIdentifier: String?

    init(
        id: String,
        media: WatchTogetherMediaDescriptor,
        title: String,
        targetSceneSessionIdentifier: String? = nil
    ) {
        self.id = id
        self.media = media
        self.title = title
        self.targetSceneSessionIdentifier = targetSceneSessionIdentifier
    }

    func targetingScene(sessionIdentifier: String) -> WatchTogetherJoinRequest {
        WatchTogetherJoinRequest(
            id: id,
            media: media,
            title: title,
            targetSceneSessionIdentifier: sessionIdentifier
        )
    }

    var searchResult: TMDBSearchResult {
        let baseTitle = media.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = baseTitle?.isEmpty == false ? baseTitle! : title
        return TMDBSearchResult(
            id: media.tmdbID,
            mediaType: media.mediaType,
            title: media.mediaType == "movie" ? resolvedTitle : nil,
            name: media.mediaType == "movie" ? nil : resolvedTitle,
            overview: nil,
            posterPath: nil,
            backdropPath: nil,
            releaseDate: nil,
            firstAirDate: nil,
            voteAverage: nil,
            popularity: 0,
            adult: false,
            genreIds: nil
        )
    }
}

extension Notification.Name {
    static let watchTogetherJoinRequested = Notification.Name("watchTogetherJoinRequested")
    static let watchTogetherSessionCleared = Notification.Name("watchTogetherSessionCleared")
}

struct EclipseWatchTogetherActivity: GroupActivity, Codable, Sendable {
    let mediaIdentifier: String
    let title: String
    let media: WatchTogetherMediaDescriptor?
    let originatorInstanceID: UUID?
    let initialState: WatchTogetherSharedState?

    init(
        mediaIdentifier: String,
        title: String,
        media: WatchTogetherMediaDescriptor? = nil,
        originatorInstanceID: UUID? = nil,
        initialState: WatchTogetherSharedState? = nil
    ) {
        self.mediaIdentifier = mediaIdentifier
        self.title = title
        self.media = media
        self.originatorInstanceID = originatorInstanceID
        self.initialState = initialState
    }

    var metadata: GroupActivityMetadata {
        get async {
            var metadata = GroupActivityMetadata()
            metadata.type = .watchTogether
            metadata.title = title
            metadata.subtitle = "Watch together in Eclipse"
            return metadata
        }
    }
}

enum WatchTogetherConnectionState: Equatable {
    case ready
    case activating
    case active(participantCount: Int, mediaMatches: Bool, sharedTitle: String)
}

enum WatchTogetherActivationResult: Equatable {
    case started
    case needsGroupSession
    case cancelled
    case unavailable(String)
}

enum WatchTogetherNextEpisodeResult: Equatable {
    case notActive
    case sent
    case rejected
}

@MainActor
protocol WatchTogetherPlaybackDelegate: AnyObject {
    var watchTogetherMediaDescriptor: WatchTogetherMediaDescriptor? { get }
    var watchTogetherPosition: Double { get }
    var watchTogetherDuration: Double { get }
    var watchTogetherIsPlaying: Bool { get }
    var watchTogetherPlaybackRate: Double { get }
    var watchTogetherIsReady: Bool { get }
    func watchTogetherAdopt(media: WatchTogetherMediaDescriptor)
    func watchTogetherApply(state: WatchTogetherSharedState, shouldSeek: Bool)
    func watchTogetherPrepareForMediaTransition(to media: WatchTogetherMediaDescriptor)
    func watchTogetherConnectionDidChange(_ state: WatchTogetherConnectionState)
    func watchTogetherShowNotice(_ message: String)
}

@MainActor
final class WatchTogetherCoordinator {
    static let shared = WatchTogetherCoordinator()

    private enum MessageReason: String, Codable, Sendable {
        case hello
        case requestState
        case play
        case pause
        case seek
        case playbackRate
        case snapshot
        case nextEpisode
    }

    private struct PlaybackMessage: Codable, Sendable {
        let id: UUID
        let senderInstanceID: UUID
        let sequence: UInt64
        let mediaIdentifier: String
        let reason: MessageReason
        let position: Double?
        let isPlaying: Bool?
        let playbackRate: Double?
        let sentAt: TimeInterval?
        let controlClock: UInt64?
        let controlAuthorityID: UUID?
        let targetMedia: WatchTogetherMediaDescriptor?
        let state: WatchTogetherSharedState?
    }

    private struct OutboundMessage {
        let message: PlaybackMessage
        let participants: Participants
    }

    private weak var playbackDelegate: (any WatchTogetherPlaybackDelegate)?
    private var attachedMediaIdentifier: String?
    private var attachedMedia: WatchTogetherMediaDescriptor?
    private var attachedTitle = ""

    private var currentSharedState: WatchTogetherSharedState?
    private var pendingJoinRequest: WatchTogetherJoinRequest?
    private var pendingTransitionKey: String?
    private var pendingAuthorityTransitionRevision: UInt64?
    private var didReceiveAuthoritativeStateMessage = false
    private var logicalStateRevision: UInt64 = 0
    private var stateAuthorityInstanceID: UUID?
    private var stateAuthorityParticipantID: UUID?
    private var participantIDByInstanceID: [UUID: UUID] = [:]

    private var session: GroupSession<EclipseWatchTogetherActivity>?
    private var messenger: GroupSessionMessenger?
    private var sessionObservationTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var activationTimeoutTask: Task<Void, Never>?
    private var initialJoinFallbackTask: Task<Void, Never>?
    private var joinDeliveryTask: Task<Void, Never>?
    private var authorityMappingGraceTask: Task<Void, Never>?
    private var authorityMappingGraceExpired = false
    private var outboundSendTask: Task<Void, Never>?
    private var outboundMessages: [OutboundMessage] = []
    private var outboundSendGeneration: UInt64 = 0
    private var stateCancellable: AnyCancellable?
    private var participantsCancellable: AnyCancellable?

    private let senderInstanceID = UUID()
    private var nextSequence: UInt64 = 0
    private var lastSequenceBySender: [String: UInt64] = [:]
    private var recentlyReceivedMessageIDs: [UUID] = []
    private var recentlyReceivedMessageIDSet: Set<UUID> = []
    private var startedObserving = false
    private let groupStateObserver = GroupStateObserver()

    private init() {}

    func start() {
        guard WatchTogetherSettings.isEnabled(), !startedObserving else { return }
        startedObserving = true
        sessionObservationTask = Task { [weak self] in
            for await session in EclipseWatchTogetherActivity.sessions() {
                guard !Task.isCancelled else { return }
                self?.configure(session)
            }
        }
    }

    static func mediaIdentifier(forStableKey stableKey: String) -> String {
        let digest = SHA256.hash(data: Data(stableKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func mediaIdentifier(for media: WatchTogetherMediaDescriptor) -> String? {
        media.stableKey.map(mediaIdentifier(forStableKey:))
    }

    func attach(
        _ delegate: any WatchTogetherPlaybackDelegate,
        mediaIdentifier: String?,
        title: String
    ) {
        guard WatchTogetherSettings.isEnabled() else {
            detach(delegate)
            delegate.watchTogetherConnectionDidChange(.ready)
            return
        }

        start()
        playbackDelegate = delegate
        attachedMediaIdentifier = mediaIdentifier
        attachedMedia = delegate.watchTogetherMediaDescriptor
        attachedTitle = sanitizedTitle(title)

        if let session,
           session.activity.originatorInstanceID == senderInstanceID,
           isLocalStateAuthority,
           (!didReceiveAuthoritativeStateMessage || session.state != .joined),
           let state = canonicalStateFromLiveDelegate(baseline: currentSharedState) {
            acceptLocalState(state)
            didReceiveAuthoritativeStateMessage = true
            pendingAuthorityTransitionRevision = delegate.watchTogetherIsReady
                ? nil
                : state.mediaRevision
        }

        if let state = currentSharedState,
           (didReceiveAuthoritativeStateMessage || isLocalStateAuthority),
           state.mediaIdentifier == mediaIdentifier {
            delegate.watchTogetherAdopt(media: state.media)
            attachedMedia = state.media
            pendingTransitionKey = nil
            joinDeliveryTask?.cancel()
            joinDeliveryTask = nil
            if pendingJoinRequest?.media == state.media {
                pendingJoinRequest = nil
            }
            applySharedState(state, to: delegate, forceSeek: false)
        }

        if let session, session.state == .joined {
            if isLocalStateAuthority {
                sendState(reason: .snapshot)
            } else {
                requestCurrentState()
            }
            if let state = currentSharedState,
               (didReceiveAuthoritativeStateMessage || isLocalStateAuthority),
               state.mediaIdentifier != mediaIdentifier {
                routeToSharedMedia(state)
            }
        }
        notifyConnectionState()
    }

    func detach(_ delegate: any WatchTogetherPlaybackDelegate) {
        guard playbackDelegate === delegate else { return }
        playbackDelegate = nil
        attachedMediaIdentifier = nil
        attachedMedia = nil
        attachedTitle = ""
    }

    func beginActivity() async -> WatchTogetherActivationResult {
        guard WatchTogetherSettings.isEnabled() else {
            return .unavailable("Watch Together is disabled in Settings.")
        }
        guard let activity = makeActivity() else {
            return .unavailable("Watch Together needs a movie or episode identity before it can start.")
        }
        if let failure = activity.media?.animeContextFailureReason {
            return .unavailable(failure)
        }

        guard groupStateObserver.isEligibleForGroupSession else {
            return .needsGroupSession
        }
        playbackDelegate?.watchTogetherConnectionDidChange(.activating)

        switch await activity.prepareForActivation() {
        case .activationPreferred:
            do {
                let activatedLocally = try await activity.activate()
                if activatedLocally {
                    scheduleActivationTimeout()
                    return .started
                }
                notifyConnectionState()
                return .cancelled
            } catch {
                notifyConnectionState()
                return .unavailable("SharePlay could not start: \(error.localizedDescription)")
            }
        case .activationDisabled:
            notifyConnectionState()
            return .cancelled
        case .cancelled:
            notifyConnectionState()
            return .cancelled
        @unknown default:
            notifyConnectionState()
            return .unavailable("SharePlay is unavailable on this device.")
        }
    }

    func activityForSharing() -> EclipseWatchTogetherActivity? {
        guard WatchTogetherSettings.isEnabled() else { return nil }
        return makeActivity()
    }

    func takePendingJoinRequest(forSceneSessionIdentifier sceneSessionIdentifier: String?) -> WatchTogetherJoinRequest? {
        guard let request = pendingJoinRequest else { return nil }

        if let targetSceneSessionIdentifier = request.targetSceneSessionIdentifier {
            guard targetSceneSessionIdentifier == sceneSessionIdentifier else { return nil }
            return request
        }

        if let sceneSessionIdentifier {
#if os(iOS)
            if let preferredSceneSessionIdentifier = preferredJoinPresentationSceneSessionIdentifier(),
               preferredSceneSessionIdentifier != sceneSessionIdentifier {
                return nil
            }
#endif
            let targetedRequest = request.targetingScene(sessionIdentifier: sceneSessionIdentifier)
            pendingJoinRequest = targetedRequest
            return targetedRequest
        }

#if os(iOS)
        // Multiple iPad WindowGroup roots may still be attaching their scene probes. Wait for one
        // to provide an identity so only that root can atomically claim the presentation. iPhone
        // remains compatible with the original single-window delivery if no scene exists yet.
        guard UIDevice.current.userInterfaceIdiom != .pad else { return nil }
#endif
        return request
    }

    func isCurrentSharedMedia(_ media: WatchTogetherMediaDescriptor) -> Bool {
        guard didReceiveAuthoritativeStateMessage,
              let session,
              session.state == .joined,
              let currentSharedState,
              let identifier = Self.mediaIdentifier(for: media) else {
            return false
        }
        return currentSharedState.mediaIdentifier == identifier
    }

    func leaveSession() {
        session?.leave()
        clearSession(leaveCurrent: false)
    }

    func endSessionForEveryone() {
        session?.end()
        clearSession(leaveCurrent: false)
    }

    func sendCurrentState(
        reason: String = "manual",
        from sender: any WatchTogetherPlaybackDelegate
    ) {
        guard playbackDelegate === sender else { return }
        if isLocalStateAuthority {
            sendState(reason: .snapshot)
            Logger.shared.log("WatchTogether: sent playback snapshot reason=\(reason)", type: "Player")
        } else {
            requestCurrentState()
            Logger.shared.log("WatchTogether: requested authoritative snapshot reason=\(reason)", type: "Player")
        }
    }

    /// Returns true when the newly-ready authority renderer should begin playback locally.
    /// Media transitions are announced paused, then released only after the destination
    /// renderer is actually ready so no participant's timeline advances during resolution.
    func playbackDidBecomeReady(_ sender: any WatchTogetherPlaybackDelegate) -> Bool {
        guard playbackDelegate === sender,
              sender.watchTogetherIsReady,
              isLocalStateAuthority,
              let pendingRevision = pendingAuthorityTransitionRevision,
              let current = currentSharedState,
              current.mediaRevision == pendingRevision,
              attachedMediaIdentifier == current.mediaIdentifier,
              let session,
              session.state == .joined else {
            return false
        }

        pendingAuthorityTransitionRevision = nil
        sendState(
            reason: .play,
            forcedPosition: sender.watchTogetherPosition,
            forcedPlayingState: true,
            forcedAwaitsReadiness: false,
            advancesRevision: true
        )
        Logger.shared.log(
            "WatchTogether: destination renderer ready; released media revision=\(pendingRevision)",
            type: "Player"
        )
        return true
    }

    func sendUserPlay(from sender: any WatchTogetherPlaybackDelegate) {
        guard playbackDelegate === sender,
              sender.watchTogetherIsReady,
              isAttachedToCurrentActivity else { return }
        pendingAuthorityTransitionRevision = nil
        sendState(
            reason: .play,
            forcedPlayingState: true,
            forcedAwaitsReadiness: false,
            advancesRevision: true
        )
    }

    func sendUserPause(from sender: any WatchTogetherPlaybackDelegate) {
        guard playbackDelegate === sender,
              sender.watchTogetherIsReady,
              isAttachedToCurrentActivity else { return }
        pendingAuthorityTransitionRevision = nil
        sendState(
            reason: .pause,
            forcedPlayingState: false,
            forcedAwaitsReadiness: false,
            advancesRevision: true
        )
    }

    func sendUserSeek(to position: Double, from sender: any WatchTogetherPlaybackDelegate) {
        guard playbackDelegate === sender,
              sender.watchTogetherIsReady,
              isAttachedToCurrentActivity,
              position.isFinite,
              position >= 0 else { return }
        pendingAuthorityTransitionRevision = nil
        sendState(
            reason: .seek,
            forcedPosition: position,
            forcedAwaitsReadiness: false,
            advancesRevision: true
        )
    }

    func sendUserPlaybackRate(_ playbackRate: Double, from sender: any WatchTogetherPlaybackDelegate) {
        guard playbackDelegate === sender,
              sender.watchTogetherIsReady,
              isAttachedToCurrentActivity,
              playbackRate.isFinite,
              (0.25...3.0).contains(playbackRate) else { return }
        pendingAuthorityTransitionRevision = nil
        sendState(
            reason: .playbackRate,
            forcedPlaybackRate: playbackRate,
            forcedAwaitsReadiness: false,
            advancesRevision: true
        )
    }

    func sendNextEpisode(
        seasonNumber: Int,
        episodeNumber: Int,
        title: String? = nil,
        playbackContext: EpisodePlaybackContext? = nil,
        from sender: any WatchTogetherPlaybackDelegate
    ) -> WatchTogetherNextEpisodeResult {
        guard playbackDelegate === sender,
              sender.watchTogetherIsReady,
              isAttachedToCurrentActivity,
              let currentMedia = currentSharedState?.media ?? sender.watchTogetherMediaDescriptor,
              currentMedia.mediaType == "tv",
              seasonNumber > 0,
              episodeNumber > 0,
              let session,
              session.state == .joined else {
            return .notActive
        }

        let targetMedia = WatchTogetherMediaDescriptor(
            tmdbID: currentMedia.tmdbID,
            mediaType: "tv",
            seasonNumber: playbackContext?.resolvedTMDBSeasonNumber ?? seasonNumber,
            episodeNumber: playbackContext?.resolvedTMDBEpisodeNumber ?? episodeNumber,
            playbackContext: playbackContext,
            isAnime: currentMedia.isAnime || playbackContext?.hasAnimeMediaId == true,
            title: title ?? currentMedia.title
        )
        if let failure = targetMedia.animeContextFailureReason {
            sender.watchTogetherShowNotice(failure)
            return .rejected
        }
        guard let targetIdentifier = Self.mediaIdentifier(for: targetMedia) else {
            sender.watchTogetherShowNotice("Watch Together could not create an exact identity for the next episode.")
            return .rejected
        }

        let previousState = currentSharedState
        let nextMediaRevision = max(1, (previousState?.mediaRevision ?? 0) &+ 1)
        let nextStateRevision = allocateStateRevision()
        let playbackRate = validatedPlaybackRate(sender.watchTogetherPlaybackRate) ?? 1.0
        let state = WatchTogetherSharedState(
            mediaIdentifier: targetIdentifier,
            media: targetMedia,
            mediaRevision: nextMediaRevision,
            stateRevision: nextStateRevision,
            position: 0,
            duration: nil,
            normalizedProgress: 0,
            isPlaying: false,
            playbackRate: playbackRate,
            awaitsReadiness: true,
            sentAt: Date().timeIntervalSince1970,
            authorityInstanceID: senderInstanceID
        )
        pendingAuthorityTransitionRevision = nextMediaRevision
        acceptLocalState(state)
        send(
            message(
                reason: .nextEpisode,
                state: state,
                legacyMediaIdentifier: previousState?.mediaIdentifier
            )
        )
        Logger.shared.log(
            "WatchTogether: broadcast authoritative media transition revision=\(nextMediaRevision) local=S\(targetMedia.localSeasonNumber ?? seasonNumber)E\(targetMedia.localEpisodeNumber ?? episodeNumber)",
            type: "Player"
        )
        return .sent
    }

    private var isAttachedToCurrentActivity: Bool {
        guard didReceiveAuthoritativeStateMessage || isLocalStateAuthority,
              let session,
              session.state == .joined,
              let attachedMediaIdentifier,
              let currentSharedState else {
            return false
        }
        return currentSharedState.mediaIdentifier == attachedMediaIdentifier
    }

    private var isLocalStateAuthority: Bool {
        stateAuthorityInstanceID == senderInstanceID
    }

    private func makeActivity() -> EclipseWatchTogetherActivity? {
        guard let delegate = playbackDelegate,
              let media = delegate.watchTogetherMediaDescriptor,
              media.animeContextFailureReason == nil,
              let mediaIdentifier = Self.mediaIdentifier(for: media) else {
            return nil
        }
        let title = attachedTitle.isEmpty ? (media.title ?? "Eclipse video") : attachedTitle
        let duration = validDuration(delegate.watchTogetherDuration)
        let position = clampedPosition(delegate.watchTogetherPosition, duration: duration)
        let initialState = WatchTogetherSharedState(
            mediaIdentifier: mediaIdentifier,
            media: media,
            mediaRevision: 1,
            stateRevision: 1,
            position: position,
            duration: duration,
            normalizedProgress: normalizedProgress(position: position, duration: duration),
            isPlaying: delegate.watchTogetherIsReady && delegate.watchTogetherIsPlaying,
            playbackRate: validatedPlaybackRate(delegate.watchTogetherPlaybackRate) ?? 1.0,
            awaitsReadiness: delegate.watchTogetherIsReady ? false : true,
            sentAt: Date().timeIntervalSince1970,
            authorityInstanceID: senderInstanceID
        )
        currentSharedState = initialState
        logicalStateRevision = max(logicalStateRevision, initialState.stateRevision)
        stateAuthorityInstanceID = senderInstanceID
        return EclipseWatchTogetherActivity(
            mediaIdentifier: mediaIdentifier,
            title: title,
            media: media,
            originatorInstanceID: senderInstanceID,
            initialState: initialState
        )
    }

    private func canonicalStateFromLiveDelegate(
        baseline: WatchTogetherSharedState?
    ) -> WatchTogetherSharedState? {
        guard let delegate = playbackDelegate,
              let media = delegate.watchTogetherMediaDescriptor,
              media.animeContextFailureReason == nil,
              let mediaIdentifier = Self.mediaIdentifier(for: media) else {
            return nil
        }

        let mediaRevision: UInt64
        if let baseline {
            mediaRevision = baseline.mediaIdentifier == mediaIdentifier
                ? baseline.mediaRevision
                : incrementedRevision(baseline.mediaRevision)
        } else {
            mediaRevision = 1
        }
        let stateRevision = incrementedRevision(baseline?.stateRevision ?? 0)
        let duration = validDuration(delegate.watchTogetherDuration)
        let position = clampedPosition(delegate.watchTogetherPosition, duration: duration)
        return WatchTogetherSharedState(
            mediaIdentifier: mediaIdentifier,
            media: media,
            mediaRevision: mediaRevision,
            stateRevision: stateRevision,
            position: position,
            duration: duration,
            normalizedProgress: normalizedProgress(position: position, duration: duration),
            isPlaying: delegate.watchTogetherIsReady && delegate.watchTogetherIsPlaying,
            playbackRate: validatedPlaybackRate(delegate.watchTogetherPlaybackRate) ?? 1.0,
            awaitsReadiness: delegate.watchTogetherIsReady ? false : true,
            sentAt: Date().timeIntervalSince1970,
            authorityInstanceID: senderInstanceID
        )
    }

    private func configure(_ newSession: GroupSession<EclipseWatchTogetherActivity>) {
        guard WatchTogetherSettings.isEnabled() else {
            newSession.leave()
            return
        }

        activationTimeoutTask?.cancel()
        activationTimeoutTask = nil
        if let session, session.id != newSession.id {
            session.leave()
        }
        clearSession(leaveCurrent: false)

        session = newSession
        let activitySeedState = validatedState(newSession.activity.initialState)
            ?? bootstrapState(for: newSession.activity)
        let isOriginator = newSession.activity.originatorInstanceID == senderInstanceID
        let liveOriginatorState = isOriginator
            ? canonicalStateFromLiveDelegate(baseline: activitySeedState)
            : nil
        // Keep the immutable activity state only as a revision baseline if the originator's
        // replacement player has not attached yet. It remains provisional until that live
        // delegate rebuilds the canonical state in attach(_:mediaIdentifier:title:).
        let seedState = isOriginator
            ? (liveOriginatorState ?? activitySeedState)
            : activitySeedState
        currentSharedState = seedState
        logicalStateRevision = seedState?.stateRevision ?? 0
        stateAuthorityInstanceID = isOriginator
            ? senderInstanceID
            : seedState?.authorityInstanceID ?? newSession.activity.originatorInstanceID
        didReceiveAuthoritativeStateMessage = isOriginator && liveOriginatorState != nil
        if isOriginator,
           let liveOriginatorState,
           playbackDelegate?.watchTogetherIsReady != true,
           liveOriginatorState.awaitsReadiness == true {
            pendingAuthorityTransitionRevision = liveOriginatorState.mediaRevision
        }

        let messenger = GroupSessionMessenger(session: newSession)
        self.messenger = messenger

        stateCancellable = newSession.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak newSession] state in
                guard let self, let newSession, self.session?.id == newSession.id else { return }
                switch state {
                case .waiting:
                    self.notifyConnectionState()
                case .joined:
                    self.sendHello()
                    if self.isLocalStateAuthority {
                        if let delegate = self.playbackDelegate,
                           self.playbackDidBecomeReady(delegate),
                           let releasedState = self.currentSharedState {
                            self.applySharedState(releasedState, to: delegate, forceSeek: false)
                        } else {
                            self.sendState(reason: .snapshot)
                        }
                    } else {
                        self.requestCurrentState()
                    }
                    self.notifyConnectionState()
                case .invalidated(let error):
                    Logger.shared.log("WatchTogether: session invalidated: \(error.localizedDescription)", type: "Player")
                    self.clearSession(leaveCurrent: false)
                @unknown default:
                    self.clearSession(leaveCurrent: false)
                }
            }

        participantsCancellable = newSession.$activeParticipants
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak newSession] _ in
                guard let self, let newSession, self.session?.id == newSession.id else { return }
                self.reconcileStateAuthority(in: newSession)
                self.sendHello()
                self.requestCurrentState()
                self.notifyConnectionState()
            }

        messageTask = Task { [weak self, weak newSession, weak messenger] in
            guard let messenger else { return }
            for await (message, context) in messenger.messages(of: PlaybackMessage.self) {
                guard !Task.isCancelled, let self, let newSession, self.session?.id == newSession.id else { return }
                self.receive(message, context: context, session: newSession)
            }
        }

        snapshotTask = Task { [weak self, weak newSession] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }
                guard let self, let newSession, self.session?.id == newSession.id else { return }
                if self.isLocalStateAuthority {
                    self.sendState(reason: .snapshot)
                }
            }
        }

        newSession.join()
        if stateAuthorityInstanceID == senderInstanceID {
            stateAuthorityParticipantID = newSession.localParticipant.id
            participantIDByInstanceID[senderInstanceID] = newSession.localParticipant.id
        }
        scheduleAuthorityMappingGrace(for: newSession)

        if !isOriginator {
            scheduleInitialJoinFallback(for: newSession)
        }

        Logger.shared.log("WatchTogether: joined secure SharePlay session", type: "Player")
        notifyConnectionState()

        Task { [weak self, weak newSession] in
            for delay in [250_000_000, 900_000_000, 2_000_000_000] as [UInt64] {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard let self, let newSession, self.session?.id == newSession.id else { return }
                self.sendHello()
                self.requestCurrentState()
            }
        }
    }

    private func bootstrapState(for activity: EclipseWatchTogetherActivity) -> WatchTogetherSharedState? {
        guard let media = activity.media,
              media.animeContextFailureReason == nil,
              let mediaIdentifier = Self.mediaIdentifier(for: media),
              mediaIdentifier == activity.mediaIdentifier,
              let originatorInstanceID = activity.originatorInstanceID else {
            return nil
        }
        return WatchTogetherSharedState(
            mediaIdentifier: mediaIdentifier,
            media: media,
            mediaRevision: 1,
            stateRevision: 1,
            position: 0,
            duration: nil,
            normalizedProgress: 0,
            isPlaying: false,
            playbackRate: 1,
            awaitsReadiness: nil,
            sentAt: Date().timeIntervalSince1970,
            authorityInstanceID: originatorInstanceID
        )
    }

    private func sendHello() {
        guard let session, session.state == .joined else { return }
        send(
            PlaybackMessage(
                id: UUID(),
                senderInstanceID: senderInstanceID,
                sequence: allocateSequence(),
                mediaIdentifier: currentSharedState?.mediaIdentifier ?? session.activity.mediaIdentifier,
                reason: .hello,
                position: nil,
                isPlaying: nil,
                playbackRate: nil,
                sentAt: nil,
                controlClock: nil,
                controlAuthorityID: nil,
                targetMedia: nil,
                state: nil
            )
        )
    }

    private func requestCurrentState() {
        guard let session, session.state == .joined else { return }
        send(
            PlaybackMessage(
                id: UUID(),
                senderInstanceID: senderInstanceID,
                sequence: allocateSequence(),
                mediaIdentifier: session.activity.mediaIdentifier,
                reason: .requestState,
                position: nil,
                isPlaying: nil,
                playbackRate: nil,
                sentAt: nil,
                controlClock: nil,
                controlAuthorityID: nil,
                targetMedia: nil,
                state: nil
            )
        )
    }

    private func sendState(
        reason: MessageReason,
        forcedPosition: Double? = nil,
        forcedPlayingState: Bool? = nil,
        forcedPlaybackRate: Double? = nil,
        forcedAwaitsReadiness: Bool? = nil,
        advancesRevision: Bool = false,
        to participants: Participants = .all
    ) {
        guard let current = currentSharedState,
              let session,
              session.state == .joined else {
            return
        }

        let delegateMatches = attachedMediaIdentifier == current.mediaIdentifier
            && playbackDelegate?.watchTogetherIsReady == true
        guard didReceiveAuthoritativeStateMessage || delegateMatches else {
            // Never publish an immutable activity payload as live state while the originator's
            // replacement renderer is still attaching.
            return
        }
        let delegate = delegateMatches ? playbackDelegate : nil
        let duration = validDuration(delegate?.watchTogetherDuration) ?? current.duration
        let rawPosition = forcedPosition ?? delegate?.watchTogetherPosition ?? current.projectedPosition()
        let position = clampedPosition(rawPosition, duration: duration)
        let awaitsReadiness = forcedAwaitsReadiness ?? current.awaitsReadiness
        let playingState = awaitsReadiness == true
            ? false
            : forcedPlayingState ?? delegate?.watchTogetherIsPlaying ?? current.isPlaying
        let playbackRate = validatedPlaybackRate(forcedPlaybackRate ?? delegate?.watchTogetherPlaybackRate)
            ?? current.playbackRate

        let revision: UInt64
        let authorityID: UUID
        if advancesRevision {
            revision = allocateStateRevision()
            authorityID = senderInstanceID
        } else {
            guard isLocalStateAuthority else { return }
            revision = current.stateRevision
            authorityID = senderInstanceID
        }

        let state = WatchTogetherSharedState(
            mediaIdentifier: current.mediaIdentifier,
            media: current.media,
            mediaRevision: current.mediaRevision,
            stateRevision: revision,
            position: position,
            duration: duration,
            normalizedProgress: normalizedProgress(position: position, duration: duration),
            isPlaying: playingState,
            playbackRate: playbackRate,
            awaitsReadiness: awaitsReadiness,
            sentAt: Date().timeIntervalSince1970,
            authorityInstanceID: authorityID
        )
        acceptLocalState(state)
        send(message(reason: reason, state: state), to: participants)
    }

    private func message(
        reason: MessageReason,
        state: WatchTogetherSharedState,
        legacyMediaIdentifier: String? = nil
    ) -> PlaybackMessage {
        PlaybackMessage(
            id: UUID(),
            senderInstanceID: senderInstanceID,
            sequence: allocateSequence(),
            mediaIdentifier: legacyMediaIdentifier ?? state.mediaIdentifier,
            reason: reason,
            position: state.position,
            isPlaying: state.isPlaying,
            playbackRate: state.playbackRate,
            sentAt: state.sentAt,
            controlClock: state.stateRevision,
            controlAuthorityID: state.authorityInstanceID,
            targetMedia: state.media,
            state: state
        )
    }

    private func send(_ message: PlaybackMessage, to participants: Participants = .all) {
        guard messenger != nil else { return }
        outboundMessages.append(OutboundMessage(message: message, participants: participants))
        drainOutboundMessagesIfNeeded()
    }

    private func drainOutboundMessagesIfNeeded() {
        guard outboundSendTask == nil else { return }
        let generation = outboundSendGeneration
        outboundSendTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled,
                  generation == self.outboundSendGeneration,
                  !self.outboundMessages.isEmpty {
                let outbound = self.outboundMessages.removeFirst()
                guard let messenger = self.messenger else { continue }
                do {
                    try await messenger.send(outbound.message, to: outbound.participants)
                } catch {
                    Logger.shared.log("WatchTogether: message send failed: \(error.localizedDescription)", type: "Player")
                }
            }
            guard generation == self.outboundSendGeneration else { return }
            self.outboundSendTask = nil
            if !self.outboundMessages.isEmpty {
                self.drainOutboundMessagesIfNeeded()
            }
        }
    }

    private func receive(
        _ message: PlaybackMessage,
        context: GroupSessionMessenger.MessageContext,
        session: GroupSession<EclipseWatchTogetherActivity>
    ) {
        guard session.activeParticipants.contains(context.source),
              context.source != session.localParticipant,
              rememberMessageID(message.id) else {
            return
        }

        let senderKey = "\(context.source.id.uuidString):\(message.senderInstanceID.uuidString)"
        let lastSequence = lastSequenceBySender[senderKey] ?? 0
        guard message.sequence > lastSequence else { return }
        lastSequenceBySender[senderKey] = message.sequence
        participantIDByInstanceID[message.senderInstanceID] = context.source.id

        if message.reason == .hello {
            if message.senderInstanceID == stateAuthorityInstanceID {
                stateAuthorityParticipantID = context.source.id
                authorityMappingGraceTask?.cancel()
                authorityMappingGraceTask = nil
            }
            reconcileStateAuthority(in: session)
            return
        }

        if message.reason == .requestState {
            guard isLocalStateResponder(to: context.source, in: session) else { return }
            sendState(reason: .snapshot, to: .only(context.source))
            return
        }

        guard let incoming = resolvedState(from: message, in: session),
              incoming.authorityInstanceID == message.senderInstanceID,
              shouldAccept(incoming) else {
            return
        }

        logicalStateRevision = max(logicalStateRevision, incoming.stateRevision)
        currentSharedState = incoming
        didReceiveAuthoritativeStateMessage = true
        stateAuthorityInstanceID = incoming.authorityInstanceID
        stateAuthorityParticipantID = context.source.id
        authorityMappingGraceTask?.cancel()
        authorityMappingGraceTask = nil
        if incoming.awaitsReadiness == true {
            pendingAuthorityTransitionRevision = incoming.mediaRevision
        } else if incoming.authorityInstanceID != senderInstanceID {
            pendingAuthorityTransitionRevision = nil
        }
        handleAcceptedState(incoming, reason: message.reason)
    }

    private func resolvedState(
        from message: PlaybackMessage,
        in session: GroupSession<EclipseWatchTogetherActivity>
    ) -> WatchTogetherSharedState? {
        if let state = validatedState(message.state) {
            return state
        }

        let media: WatchTogetherMediaDescriptor
        let mediaRevision: UInt64
        if message.reason == .nextEpisode, let targetMedia = message.targetMedia {
            media = targetMedia
            mediaRevision = max(1, (currentSharedState?.mediaRevision ?? 0) &+ 1)
        } else if let current = currentSharedState,
                  current.mediaIdentifier == message.mediaIdentifier {
            media = current.media
            mediaRevision = current.mediaRevision
        } else if message.mediaIdentifier == session.activity.mediaIdentifier,
                  let activityMedia = session.activity.media {
            media = activityMedia
            mediaRevision = 1
        } else {
            return nil
        }

        let legacyPosition: Double?
        if let position = message.position {
            legacyPosition = position
        } else {
            legacyPosition = message.reason == .nextEpisode ? 0 : nil
        }
        let legacyPlayingState: Bool?
        if let isPlaying = message.isPlaying {
            legacyPlayingState = isPlaying
        } else {
            legacyPlayingState = message.reason == .nextEpisode ? true : nil
        }
        guard media.animeContextFailureReason == nil,
              let identifier = Self.mediaIdentifier(for: media),
              message.reason == .nextEpisode || identifier == message.mediaIdentifier,
              let rawPosition = legacyPosition,
              rawPosition.isFinite,
              rawPosition >= 0,
              let isPlaying = legacyPlayingState else {
            return nil
        }
        let position = min(rawPosition, 7 * 24 * 60 * 60)
        let rate = validatedPlaybackRate(message.playbackRate) ?? 1.0
        let revision = message.controlClock ?? max(1, logicalStateRevision &+ 1)
        return WatchTogetherSharedState(
            mediaIdentifier: identifier,
            media: media,
            mediaRevision: mediaRevision,
            stateRevision: revision,
            position: position,
            duration: nil,
            normalizedProgress: nil,
            isPlaying: isPlaying,
            playbackRate: rate,
            awaitsReadiness: message.reason == .nextEpisode && !isPlaying ? true : nil,
            sentAt: message.sentAt ?? Date().timeIntervalSince1970,
            authorityInstanceID: message.senderInstanceID
        )
    }

    private func validatedState(_ state: WatchTogetherSharedState?) -> WatchTogetherSharedState? {
        guard let state,
              state.mediaRevision > 0,
              state.stateRevision > 0,
              state.position.isFinite,
              state.position >= 0,
              state.position <= 7 * 24 * 60 * 60,
              state.sentAt.isFinite,
              validatedPlaybackRate(state.playbackRate) != nil,
              Self.mediaIdentifier(for: state.media) == state.mediaIdentifier,
              state.media.animeContextFailureReason == nil else {
            return nil
        }
        if let duration = state.duration,
           (!duration.isFinite || duration <= 0 || duration > 7 * 24 * 60 * 60) {
            return nil
        }
        if let progress = state.normalizedProgress,
           (!progress.isFinite || !(0...1).contains(progress)) {
            return nil
        }
        if state.awaitsReadiness == true, state.isPlaying {
            return nil
        }
        return state
    }

    private func shouldAccept(_ incoming: WatchTogetherSharedState) -> Bool {
        // The first live message always supersedes the immutable activity bootstrap. Comparing
        // equal revisions or wall-clock timestamps here can otherwise reject the authority when
        // devices have clock skew or the originator changed episodes while the session formed.
        guard didReceiveAuthoritativeStateMessage else { return true }
        guard let current = currentSharedState else { return true }
        if incoming.mediaRevision != current.mediaRevision {
            return incoming.mediaRevision > current.mediaRevision
        }
        if incoming.stateRevision != current.stateRevision {
            return incoming.stateRevision > current.stateRevision
        }
        if incoming.authorityInstanceID == current.authorityInstanceID {
            return incoming.mediaIdentifier == current.mediaIdentifier
                && incoming.sentAt > current.sentAt
        }
        return incoming.authorityInstanceID.uuidString > current.authorityInstanceID.uuidString
    }

    private func handleAcceptedState(_ state: WatchTogetherSharedState, reason: MessageReason) {
        initialJoinFallbackTask?.cancel()
        initialJoinFallbackTask = nil

        guard let delegate = playbackDelegate,
              attachedMediaIdentifier == state.mediaIdentifier else {
            routeToSharedMedia(state)
            return
        }

        delegate.watchTogetherAdopt(media: state.media)
        attachedMedia = state.media
        pendingTransitionKey = nil
        joinDeliveryTask?.cancel()
        joinDeliveryTask = nil
        if pendingJoinRequest?.media == state.media {
            pendingJoinRequest = nil
        }
        let forceSeek = reason == .seek || reason == .nextEpisode
        applySharedState(state, to: delegate, forceSeek: forceSeek)
        notifyConnectionState()
    }

    private func applySharedState(
        _ state: WatchTogetherSharedState,
        to delegate: any WatchTogetherPlaybackDelegate,
        forceSeek: Bool
    ) {
        let projectedPosition = state.projectedPosition()
        let synchronizedPosition: Double
        let localDuration = validDuration(delegate.watchTogetherDuration)
        if let localDuration,
           let sharedDuration = validDuration(state.duration) {
            let projectedProgress = min(max(0, projectedPosition / sharedDuration), 1)
            synchronizedPosition = projectedProgress * localDuration
        } else if let localDuration,
                  let progress = state.normalizedProgress,
                  progress.isFinite,
                  (0...1).contains(progress) {
            synchronizedPosition = progress * localDuration
        } else {
            synchronizedPosition = projectedPosition
        }
        let drift = abs(delegate.watchTogetherPosition - synchronizedPosition)
        let shouldSeek = forceSeek || drift >= 0.35
        delegate.watchTogetherApply(state: state, shouldSeek: shouldSeek)
    }

    private func routeToSharedMedia(_ state: WatchTogetherSharedState) {
        guard didReceiveAuthoritativeStateMessage || isLocalStateAuthority,
              let transitionKey = joinKey(for: state) else {
            requestCurrentState()
            return
        }
        guard pendingTransitionKey != transitionKey else {
            if joinDeliveryTask == nil {
                scheduleJoinDelivery(for: state, transitionKey: transitionKey, initialDelayNanoseconds: 0)
            }
            return
        }

        joinDeliveryTask?.cancel()
        joinDeliveryTask = nil
        pendingJoinRequest = nil
        pendingTransitionKey = transitionKey
        let needsPlayerClose: Bool
        if let delegate = playbackDelegate,
           attachedMediaIdentifier != state.mediaIdentifier {
            delegate.watchTogetherPrepareForMediaTransition(to: state.media)
            needsPlayerClose = true
        } else {
            needsPlayerClose = false
        }
        scheduleJoinDelivery(
            for: state,
            transitionKey: transitionKey,
            initialDelayNanoseconds: needsPlayerClose ? 550_000_000 : 0
        )
        notifyConnectionState()
    }

    private func joinKey(for state: WatchTogetherSharedState) -> String? {
        guard let session else { return nil }
        return "\(String(describing: session.id)):\(state.mediaRevision):\(state.mediaIdentifier)"
    }

    private func scheduleJoinDelivery(
        for state: WatchTogetherSharedState,
        transitionKey: String,
        initialDelayNanoseconds: UInt64
    ) {
        joinDeliveryTask?.cancel()
        joinDeliveryTask = Task { [weak self] in
            if initialDelayNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: initialDelayNanoseconds)
                } catch {
                    return
                }
            }

            while !Task.isCancelled {
                guard let self,
                      self.pendingTransitionKey == transitionKey,
                      let current = self.currentSharedState,
                      current.mediaRevision == state.mediaRevision,
                      current.mediaIdentifier == state.mediaIdentifier,
                      self.attachedMediaIdentifier != current.mediaIdentifier else {
                    return
                }
                self.deliverJoinRequest(for: current, joinKey: transitionKey)
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func deliverJoinRequest(for state: WatchTogetherSharedState, joinKey: String) {
        let title = sanitizedTitle(state.media.title ?? session?.activity.title ?? "Eclipse video")
        let existingTargetSceneIdentifier: String?
        if let existingRequest = pendingJoinRequest,
           existingRequest.id == joinKey,
           let target = existingRequest.targetSceneSessionIdentifier,
           joinPresentationSceneExists(sessionIdentifier: target) {
            existingTargetSceneIdentifier = target
        } else {
            existingTargetSceneIdentifier = preferredJoinPresentationSceneSessionIdentifier()
        }
        let request = WatchTogetherJoinRequest(
            id: joinKey,
            media: state.media,
            title: title,
            targetSceneSessionIdentifier: existingTargetSceneIdentifier
        )
        pendingJoinRequest = request
        NotificationCenter.default.post(name: .watchTogetherJoinRequested, object: request)
        Logger.shared.log(
            "WatchTogether: requested exact media handoff revision=\(state.mediaRevision) tmdbId=\(state.media.tmdbID) localSeason=\(state.media.localSeasonNumber.map(String.init) ?? "none") localEpisode=\(state.media.localEpisodeNumber.map(String.init) ?? "none")",
            type: "Player"
        )
    }

    private func preferredJoinPresentationSceneSessionIdentifier() -> String? {
#if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState != .unattached }
        return scenes.sorted { lhs, rhs in
            let lhsRank = joinPresentationRank(for: lhs)
            let rhsRank = joinPresentationRank(for: rhs)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.session.persistentIdentifier < rhs.session.persistentIdentifier
        }.first?.session.persistentIdentifier
#else
        return nil
#endif
    }

    private func joinPresentationSceneExists(sessionIdentifier: String) -> Bool {
#if os(iOS)
        UIApplication.shared.connectedScenes.contains { scene in
            guard let windowScene = scene as? UIWindowScene else { return false }
            return windowScene.activationState != .unattached
                && windowScene.session.persistentIdentifier == sessionIdentifier
        }
#else
        return false
#endif
    }

#if os(iOS)
    private func joinPresentationRank(for scene: UIWindowScene) -> Int {
        let hasKeyWindow = scene.windows.contains(where: \.isKeyWindow)
        switch (scene.activationState, hasKeyWindow) {
        case (.foregroundActive, true): return 0
        case (.foregroundActive, false): return 1
        case (.foregroundInactive, true): return 2
        case (.foregroundInactive, false): return 3
        case (.background, _): return 4
        case (.unattached, _): return 5
        @unknown default: return 6
        }
    }
#endif

    private func scheduleInitialJoinFallback(for session: GroupSession<EclipseWatchTogetherActivity>) {
        initialJoinFallbackTask?.cancel()
        initialJoinFallbackTask = Task { [weak self, weak session] in
            for delay in [1_200_000_000, 2_000_000_000, 3_000_000_000] as [UInt64] {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard let self, let session, self.session?.id == session.id else { return }
                guard !self.didReceiveAuthoritativeStateMessage else { return }
                self.sendHello()
                self.requestCurrentState()
                Logger.shared.log(
                    "WatchTogether: waiting for authoritative shared state; provisional activity media was not opened",
                    type: "Player"
                )
            }
        }
    }

    private func isLocalStateResponder(
        to requester: Participant,
        in session: GroupSession<EclipseWatchTogetherActivity>
    ) -> Bool {
        guard didReceiveAuthoritativeStateMessage else {
            // An activity payload is only a hint for finding the current authority.
            // It must never be echoed back as if it were live playback state.
            return false
        }
        if isLocalStateAuthority {
            return true
        }
        if let authorityID = stateAuthorityInstanceID,
           participantIDByInstanceID[authorityID] == nil,
           !authorityMappingGraceExpired {
            // Wait for the authority's hello mapping instead of letting an arbitrary participant
            // answer with a stale bootstrap state while the host is still joining.
            return false
        }
        if let authorityParticipantID = stateAuthorityParticipantID {
            return authorityParticipantID == session.localParticipant.id
        }
        let existingParticipants = session.activeParticipants.filter { $0 != requester }
        return existingParticipants.min(by: participantSort) == session.localParticipant
    }

    private func scheduleAuthorityMappingGrace(
        for session: GroupSession<EclipseWatchTogetherActivity>
    ) {
        authorityMappingGraceTask?.cancel()
        authorityMappingGraceTask = nil
        authorityMappingGraceExpired = false

        if let authorityID = stateAuthorityInstanceID,
           participantIDByInstanceID[authorityID] != nil {
            return
        }

        authorityMappingGraceTask = Task { [weak self, weak session] in
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            } catch {
                return
            }
            guard let self, let session, self.session?.id == session.id else { return }
            if let authorityID = self.stateAuthorityInstanceID,
               self.participantIDByInstanceID[authorityID] != nil {
                self.authorityMappingGraceTask = nil
                return
            }
            self.authorityMappingGraceExpired = true
            self.authorityMappingGraceTask = nil
            self.reconcileStateAuthority(in: session)
            self.requestCurrentState()
        }
    }

    private func reconcileStateAuthority(in session: GroupSession<EclipseWatchTogetherActivity>) {
        if let authorityID = stateAuthorityInstanceID {
            if let participantID = participantIDByInstanceID[authorityID] {
                if session.activeParticipants.contains(where: { $0.id == participantID }) {
                    stateAuthorityParticipantID = participantID
                    return
                }
            } else if !authorityMappingGraceExpired {
                // The originator instance and SharePlay participant use different UUID spaces.
                // Do not elect a replacement until hello maps the current authority.
                return
            }
        }

        guard let fallback = session.activeParticipants.min(by: participantSort) else { return }
        if fallback == session.localParticipant {
            guard let current = currentSharedState else { return }
            let delegateMatches = attachedMediaIdentifier == current.mediaIdentifier
                && playbackDelegate?.watchTogetherIsReady == true
            guard didReceiveAuthoritativeStateMessage || delegateMatches else {
                // Never promote the immutable activity bootstrap to authoritative playback.
                // With no live matching renderer, keep requesting a real state instead.
                stateAuthorityParticipantID = nil
                requestCurrentState()
                return
            }
            stateAuthorityParticipantID = fallback.id
            participantIDByInstanceID[senderInstanceID] = fallback.id
            stateAuthorityInstanceID = senderInstanceID
            let position = delegateMatches
                ? playbackDelegate?.watchTogetherPosition ?? current.projectedPosition()
                : current.projectedPosition()
            let duration = delegateMatches
                ? validDuration(playbackDelegate?.watchTogetherDuration) ?? current.duration
                : current.duration
            let state = WatchTogetherSharedState(
                mediaIdentifier: current.mediaIdentifier,
                media: current.media,
                mediaRevision: current.mediaRevision,
                stateRevision: allocateStateRevision(),
                position: clampedPosition(position, duration: duration),
                duration: duration,
                normalizedProgress: normalizedProgress(position: position, duration: duration),
                isPlaying: delegateMatches ? playbackDelegate?.watchTogetherIsPlaying ?? current.isPlaying : current.isPlaying,
                playbackRate: delegateMatches
                    ? validatedPlaybackRate(playbackDelegate?.watchTogetherPlaybackRate) ?? current.playbackRate
                    : current.playbackRate,
                awaitsReadiness: current.awaitsReadiness,
                sentAt: Date().timeIntervalSince1970,
                authorityInstanceID: senderInstanceID
            )
            acceptLocalState(state)
            didReceiveAuthoritativeStateMessage = true
            if state.awaitsReadiness == true {
                pendingAuthorityTransitionRevision = state.mediaRevision
            }
            send(message(reason: .snapshot, state: state))
            if let delegate = playbackDelegate,
               playbackDidBecomeReady(delegate),
               let releasedState = currentSharedState {
                applySharedState(releasedState, to: delegate, forceSeek: false)
            }
        } else if let remoteInstance = participantIDByInstanceID.first(where: { $0.value == fallback.id })?.key {
            stateAuthorityParticipantID = fallback.id
            stateAuthorityInstanceID = remoteInstance
        } else {
            stateAuthorityParticipantID = fallback.id
        }
    }

    private func participantSort(_ lhs: Participant, _ rhs: Participant) -> Bool {
        lhs.id.uuidString < rhs.id.uuidString
    }

    private func acceptLocalState(_ state: WatchTogetherSharedState) {
        currentSharedState = state
        logicalStateRevision = max(logicalStateRevision, state.stateRevision)
        stateAuthorityInstanceID = senderInstanceID
        if let session {
            stateAuthorityParticipantID = session.localParticipant.id
            participantIDByInstanceID[senderInstanceID] = session.localParticipant.id
        }
    }

    private func allocateSequence() -> UInt64 {
        nextSequence &+= 1
        if nextSequence == 0 { nextSequence = 1 }
        return nextSequence
    }

    private func allocateStateRevision() -> UInt64 {
        logicalStateRevision &+= 1
        if logicalStateRevision == 0 { logicalStateRevision = 1 }
        return logicalStateRevision
    }

    private func incrementedRevision(_ revision: UInt64) -> UInt64 {
        guard revision < UInt64.max else { return revision }
        return max(1, revision + 1)
    }

    private func validDuration(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0, value <= 7 * 24 * 60 * 60 else { return nil }
        return value
    }

    private func clampedPosition(_ value: Double, duration: Double?) -> Double {
        guard value.isFinite else { return 0 }
        let upperBound = duration ?? 7 * 24 * 60 * 60
        return min(max(0, value), upperBound)
    }

    private func normalizedProgress(position: Double, duration: Double?) -> Double? {
        guard let duration, duration > 0 else { return nil }
        return min(max(0, position / duration), 1)
    }

    private func validatedPlaybackRate(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0.25...3.0).contains(value) else { return nil }
        return value
    }

    private func rememberMessageID(_ id: UUID) -> Bool {
        guard recentlyReceivedMessageIDSet.insert(id).inserted else { return false }
        recentlyReceivedMessageIDs.append(id)
        if recentlyReceivedMessageIDs.count > 256 {
            let stale = recentlyReceivedMessageIDs.removeFirst()
            recentlyReceivedMessageIDSet.remove(stale)
        }
        return true
    }

    private func notifyConnectionState() {
        guard let delegate = playbackDelegate else { return }
        guard let session, session.state == .joined else {
            delegate.watchTogetherConnectionDidChange(.ready)
            return
        }
        delegate.watchTogetherConnectionDidChange(
            .active(
                participantCount: session.activeParticipants.count,
                mediaMatches: isAttachedToCurrentActivity,
                sharedTitle: currentSharedState?.media.title ?? session.activity.title
            )
        )
    }

    private func clearSession(
        leaveCurrent: Bool = true,
        preservePendingPresentation: Bool = false
    ) {
        let shouldNotifyPresentationCleared = session != nil
            || pendingJoinRequest != nil
            || pendingTransitionKey != nil
        if leaveCurrent {
            session?.leave()
        }
        stateCancellable?.cancel()
        participantsCancellable?.cancel()
        messageTask?.cancel()
        snapshotTask?.cancel()
        activationTimeoutTask?.cancel()
        initialJoinFallbackTask?.cancel()
        joinDeliveryTask?.cancel()
        authorityMappingGraceTask?.cancel()
        outboundSendGeneration &+= 1
        outboundSendTask?.cancel()
        stateCancellable = nil
        participantsCancellable = nil
        messageTask = nil
        snapshotTask = nil
        activationTimeoutTask = nil
        initialJoinFallbackTask = nil
        joinDeliveryTask = nil
        authorityMappingGraceTask = nil
        authorityMappingGraceExpired = false
        outboundSendTask = nil
        outboundMessages.removeAll()
        session = nil
        messenger = nil
        currentSharedState = nil
        pendingTransitionKey = nil
        pendingAuthorityTransitionRevision = nil
        didReceiveAuthoritativeStateMessage = false
        logicalStateRevision = 0
        stateAuthorityInstanceID = nil
        stateAuthorityParticipantID = nil
        participantIDByInstanceID.removeAll()
        lastSequenceBySender.removeAll()
        recentlyReceivedMessageIDs.removeAll()
        recentlyReceivedMessageIDSet.removeAll()
        if !preservePendingPresentation {
            pendingJoinRequest = nil
            if shouldNotifyPresentationCleared {
                NotificationCenter.default.post(name: .watchTogetherSessionCleared, object: nil)
            }
        }
        notifyConnectionState()
    }

    private func scheduleActivationTimeout() {
        activationTimeoutTask?.cancel()
        activationTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                return
            }
            guard let self, self.session == nil else { return }
            self.notifyConnectionState()
            self.playbackDelegate?.watchTogetherShowNotice("SharePlay did not create a local session. Try Watch Together again.")
        }
    }

    private func sanitizedTitle(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "Eclipse video" }
        return String(normalized.prefix(120))
    }
}
