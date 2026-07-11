import Combine
import CryptoKit
import Foundation
import GroupActivities

struct EclipseWatchTogetherActivity: GroupActivity, Codable, Sendable {
    let mediaIdentifier: String
    let title: String

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

@MainActor
protocol WatchTogetherPlaybackDelegate: AnyObject {
    var watchTogetherPosition: Double { get }
    var watchTogetherIsPlaying: Bool { get }
    func watchTogetherApply(position: Double?, isPlaying: Bool)
    func watchTogetherConnectionDidChange(_ state: WatchTogetherConnectionState)
    func watchTogetherShowNotice(_ message: String)
}

@MainActor
final class WatchTogetherCoordinator {
    static let shared = WatchTogetherCoordinator()

    private enum MessageReason: String, Codable, Sendable {
        case requestState
        case play
        case pause
        case seek
        case snapshot
    }

    private struct PlaybackMessage: Codable, Sendable {
        let id: UUID
        let senderInstanceID: UUID
        let sequence: UInt64
        let mediaIdentifier: String
        let reason: MessageReason
        let position: Double?
        let isPlaying: Bool?
    }

    private weak var playbackDelegate: (any WatchTogetherPlaybackDelegate)?
    private var attachedMediaIdentifier: String?
    private var attachedTitle = ""

    private var session: GroupSession<EclipseWatchTogetherActivity>?
    private var messenger: GroupSessionMessenger?
    private var sessionObservationTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var activationTimeoutTask: Task<Void, Never>?
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
        guard WatchTogetherSettings.isEnabled() else { return }
        guard !startedObserving else { return }
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
        attachedTitle = sanitizedTitle(title)
        notifyConnectionState()

        if let session, session.state == .joined {
            if session.activity.mediaIdentifier == mediaIdentifier {
                requestCurrentState()
            } else {
                delegate.watchTogetherShowNotice("A Watch Together session is active for \(session.activity.title). Open that title to synchronize.")
            }
        }
    }

    func detach(_ delegate: any WatchTogetherPlaybackDelegate) {
        guard playbackDelegate === delegate else { return }
        playbackDelegate = nil
        attachedMediaIdentifier = nil
        attachedTitle = ""
    }

    func beginActivity() async -> WatchTogetherActivationResult {
        guard WatchTogetherSettings.isEnabled() else {
            return .unavailable("Watch Together is disabled in Settings.")
        }
        guard let mediaIdentifier = attachedMediaIdentifier else {
            return .unavailable("Watch Together needs a movie or episode identity before it can start.")
        }

        let title = attachedTitle.isEmpty ? "Eclipse video" : attachedTitle
        let activity = EclipseWatchTogetherActivity(mediaIdentifier: mediaIdentifier, title: title)

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
        guard let mediaIdentifier = attachedMediaIdentifier else { return nil }
        let title = attachedTitle.isEmpty ? "Eclipse video" : attachedTitle
        return EclipseWatchTogetherActivity(mediaIdentifier: mediaIdentifier, title: title)
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
        guard playbackDelegate === sender, isAttachedToCurrentActivity else { return }
        sendState(reason: .snapshot)
        Logger.shared.log("WatchTogether: sent playback snapshot reason=\(reason)", type: "Player")
    }

    func sendUserPlay(from sender: any WatchTogetherPlaybackDelegate) {
        guard playbackDelegate === sender, isAttachedToCurrentActivity else { return }
        sendState(reason: .play, forcedPlayingState: true)
    }

    func sendUserPause(from sender: any WatchTogetherPlaybackDelegate) {
        guard playbackDelegate === sender, isAttachedToCurrentActivity else { return }
        sendState(reason: .pause, forcedPlayingState: false)
    }

    func sendUserSeek(to position: Double, from sender: any WatchTogetherPlaybackDelegate) {
        guard playbackDelegate === sender,
              isAttachedToCurrentActivity,
              position.isFinite,
              position >= 0 else { return }
        sendState(reason: .seek, forcedPosition: position)
    }

    private var isAttachedToCurrentActivity: Bool {
        guard let session,
              session.state == .joined,
              let attachedMediaIdentifier else {
            return false
        }
        return session.activity.mediaIdentifier == attachedMediaIdentifier
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
        let messenger = GroupSessionMessenger(session: newSession)
        self.messenger = messenger

        stateCancellable = newSession.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak newSession] state in
                guard let self, let newSession, self.session?.id == newSession.id else { return }
                switch state {
                case .waiting, .joined:
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
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    return
                }
                guard let self, let newSession, self.session?.id == newSession.id else { return }
                if self.isLocalAuthority(in: newSession), self.isAttachedToCurrentActivity {
                    self.sendState(reason: .snapshot)
                }
            }
        }

        newSession.join()
        Logger.shared.log("WatchTogether: joined secure SharePlay session", type: "Player")
        notifyConnectionState()

        Task { [weak self, weak newSession] in
            do {
                try await Task.sleep(nanoseconds: 450_000_000)
            } catch {
                return
            }
            guard let self, let newSession, self.session?.id == newSession.id else { return }
            self.requestCurrentState()
        }
    }

    private func requestCurrentState() {
        guard isAttachedToCurrentActivity else { return }
        send(
            PlaybackMessage(
                id: UUID(),
                senderInstanceID: senderInstanceID,
                sequence: allocateSequence(),
                mediaIdentifier: session?.activity.mediaIdentifier ?? "",
                reason: .requestState,
                position: nil,
                isPlaying: nil
            )
        )
    }

    private func sendState(
        reason: MessageReason,
        forcedPosition: Double? = nil,
        forcedPlayingState: Bool? = nil,
        to participants: Participants = .all
    ) {
        guard let mediaIdentifier = attachedMediaIdentifier,
              let delegate = playbackDelegate,
              isAttachedToCurrentActivity else {
            return
        }

        let position = forcedPosition ?? delegate.watchTogetherPosition
        guard position.isFinite, position >= 0 else { return }
        let message = PlaybackMessage(
            id: UUID(),
            senderInstanceID: senderInstanceID,
            sequence: allocateSequence(),
            mediaIdentifier: mediaIdentifier,
            reason: reason,
            position: position,
            isPlaying: forcedPlayingState ?? delegate.watchTogetherIsPlaying
        )
        send(message, to: participants)
    }

    private func send(_ message: PlaybackMessage, to participants: Participants = .all) {
        guard let messenger else { return }
        Task {
            do {
                try await messenger.send(message, to: participants)
            } catch {
                Logger.shared.log("WatchTogether: message send failed: \(error.localizedDescription)", type: "Player")
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
              message.mediaIdentifier == session.activity.mediaIdentifier,
              rememberMessageID(message.id) else {
            return
        }

        let senderKey = "\(context.source.id.uuidString):\(message.senderInstanceID.uuidString)"
        let lastSequence = lastSequenceBySender[senderKey] ?? 0
        guard message.sequence > lastSequence else { return }
        lastSequenceBySender[senderKey] = message.sequence

        if message.reason == .requestState {
            guard isLocalStateResponder(to: context.source, in: session),
                  isAttachedToCurrentActivity else { return }
            sendState(reason: .snapshot, to: .only(context.source))
            return
        }

        guard let attachedMediaIdentifier,
              attachedMediaIdentifier == message.mediaIdentifier,
              let delegate = playbackDelegate,
              let isPlaying = message.isPlaying else {
            return
        }

        let requestedPosition: Double?
        if let position = message.position,
           position.isFinite,
           position >= 0,
           position <= 7 * 24 * 60 * 60 {
            let drift = abs(delegate.watchTogetherPosition - position)
            let threshold = message.reason == .snapshot ? 1.5 : 0.55
            requestedPosition = drift >= threshold || message.reason == .seek ? position : nil
        } else {
            requestedPosition = nil
        }

        delegate.watchTogetherApply(position: requestedPosition, isPlaying: isPlaying)
    }

    private func isLocalAuthority(in session: GroupSession<EclipseWatchTogetherActivity>) -> Bool {
        let authority = session.activeParticipants.min {
            $0.id.uuidString < $1.id.uuidString
        }
        return authority == session.localParticipant
    }

    private func isLocalStateResponder(
        to requester: Participant,
        in session: GroupSession<EclipseWatchTogetherActivity>
    ) -> Bool {
        let existingParticipants = session.activeParticipants.filter { $0 != requester }
        let responder = existingParticipants.min {
            $0.id.uuidString < $1.id.uuidString
        }
        return responder == session.localParticipant
    }

    private func allocateSequence() -> UInt64 {
        nextSequence &+= 1
        if nextSequence == 0 { nextSequence = 1 }
        return nextSequence
    }

    private func rememberMessageID(_ id: UUID) -> Bool {
        guard recentlyReceivedMessageIDSet.insert(id).inserted else { return false }
        recentlyReceivedMessageIDs.append(id)
        if recentlyReceivedMessageIDs.count > 128 {
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
                mediaMatches: session.activity.mediaIdentifier == attachedMediaIdentifier,
                sharedTitle: session.activity.title
            )
        )
    }

    private func clearSession(leaveCurrent: Bool = true) {
        if leaveCurrent {
            session?.leave()
        }
        stateCancellable?.cancel()
        participantsCancellable?.cancel()
        messageTask?.cancel()
        snapshotTask?.cancel()
        activationTimeoutTask?.cancel()
        stateCancellable = nil
        participantsCancellable = nil
        messageTask = nil
        snapshotTask = nil
        activationTimeoutTask = nil
        session = nil
        messenger = nil
        lastSequenceBySender.removeAll()
        recentlyReceivedMessageIDs.removeAll()
        recentlyReceivedMessageIDSet.removeAll()
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
