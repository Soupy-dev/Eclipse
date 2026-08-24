import Foundation

@available(iOS 17.0, tvOS 17.0, *)
protocol MediaStateSyncTransport: AnyObject, Sendable {
    var providerDisplayName: String { get }

    var isEnabled: Bool { get }

    var accountContinuityToken: String? { get }
    func fetchRemoteEnvelopes(accountContinuityToken: String?) async throws -> MediaStateRemoteFetch

    func pushEnvelopes(
        _ merged: [String: MediaStateEnvelope],
        expecting revision: MediaStateRemoteRevision?,
        accountContinuityToken: String?
    ) async throws

    func synchronize(reason: String) async

    func recordSuccessfulSynchronization() async
    func recordFailedSynchronization(_ message: String) async
}

struct MediaStateRemoteRevision: Sendable, Equatable {

    var fileID: String?

    var token: String?

    var observedFiles: [MediaStateRemoteFileVersion] = []

    /// False means the fetch returned usable salvage but at least one remote
    /// candidate/record was missing, unreadable, or repaired. Such a fetch may
    /// be applied locally, but must never authorize a destructive replacement.
    var isComplete: Bool = true
}

struct MediaStateRemoteFileVersion: Sendable, Equatable {
    var fileID: String
    var token: String?
}

struct MediaStateRemoteFetch: Sendable {
    var records: [String: MediaStateEnvelope]

    var revision: MediaStateRemoteRevision?

    var isComplete: Bool = true
}

struct MediaStateRemoteRevisionConflict: Error {}

private struct MediaStateSyncPassInvalidated: Error {}

private enum MediaStateTransportPassOutcome {
    case completed
    case skipped
    case retry
    case failed(String)
}

private enum MediaStateTransportMergeAttempt {
    case merged(MediaStateEnvelopeReconciler.Result)
    case playbackDeferred
    case invalidated
    case refused
}

@available(iOS 17.0, tvOS 17.0, *)
extension MediaStateSyncTransport {

    var accountContinuityToken: String? { nil }

    func recordSuccessfulSynchronization() async {}

    func recordFailedSynchronization(_ message: String) async {}

    func synchronize(reason: String) async {

        let maximumAttempts = 3
        for attempt in 0..<maximumAttempts {
            switch await reconcileOnce(reason: reason) {
            case .completed:
                guard !Task.isCancelled else { return }
                await recordSuccessfulSynchronization()
                return
            case .skipped:
                return
            case .retry:
                guard attempt + 1 < maximumAttempts else { continue }
                let delay = MediaStateSyncRequestBackoffPolicy
                    .revisionConflictDelay(attempt: attempt)
                try? await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
                guard !Task.isCancelled else { return }
                continue
            case .failed(let message):
                guard !Task.isCancelled else { return }
                await recordFailedSynchronization(message)
                return
            }
        }
        guard !Task.isCancelled else { return }
        let message = "The remote copy changed repeatedly while Eclipse was syncing."
        Logger.shared.log(
            "MediaStateSync: \(providerDisplayName) abandoned (\(reason)); the remote copy moved under every write",
            type: "iCloud"
        )
        await recordFailedSynchronization(message)
    }

    private func reconcileOnce(reason: String) async -> MediaStateTransportPassOutcome {

        let startingPlaybackLease = MediaStatePlaybackLease.snapshot
        guard isEnabled,
              !MediaStateAccountBoundaryRecoveryGate.isBlockingSync,
              MediaStatePlaybackLeaseLifecyclePolicy.automaticSynchronizationAuthorityIsCurrent(
                starting: startingPlaybackLease,
                current: startingPlaybackLease
              ),
              !Task.isCancelled else { return .skipped }

        let startingAccount = accountContinuityToken
        do {
            let fetched = try await fetchRemoteEnvelopes(accountContinuityToken: startingAccount)
            guard !Task.isCancelled,
                  !MediaStateAccountBoundaryRecoveryGate.isBlockingSync,
                  isEnabled,
                  accountContinuityToken == startingAccount,
                  MediaStatePlaybackLeaseLifecyclePolicy.automaticSynchronizationAuthorityIsCurrent(
                    starting: startingPlaybackLease,
                    current: MediaStatePlaybackLease.snapshot
                  ) else {
                return .skipped
            }

            let mergeAttempt = await MainActor.run { () -> MediaStateTransportMergeAttempt in

                guard !MediaStateAccountBoundaryRecoveryGate.isBlockingSync,
                      !Task.isCancelled,
                      isEnabled,
                      accountContinuityToken == startingAccount else { return .invalidated }
                guard MediaStatePlaybackLeaseLifecyclePolicy.automaticSynchronizationAuthorityIsCurrent(
                    starting: startingPlaybackLease,
                    current: MediaStatePlaybackLease.snapshot
                ) else { return .playbackDeferred }
                guard let outcome = MediaStateSyncManager.shared.applyRemoteTransportMerge(
                    from: fetched.records
                ) else { return .refused }
                return .merged(outcome)
            }

            let outcome: MediaStateEnvelopeReconciler.Result
            switch mergeAttempt {
            case .merged(let merged):
                outcome = merged
            case .playbackDeferred:
                Logger.shared.log(
                    "MediaStateSync: \(providerDisplayName) deferred (\(reason)); playback began before the merge",
                    type: "iCloud"
                )
                return .skipped
            case .invalidated:
                Logger.shared.log(
                    "MediaStateSync: \(providerDisplayName) deferred (\(reason)); the account or recovery state changed during the fetch",
                    type: "iCloud"
                )
                return .skipped
            case .refused:
                Logger.shared.log(
                    "MediaStateSync: \(providerDisplayName) deferred (\(reason)); the archive refused the merge",
                    type: "iCloud"
                )
                return .failed("Eclipse could not safely apply the downloaded media state.")
            }
            guard MediaStatePlaybackLeaseLifecyclePolicy.automaticSynchronizationAuthorityIsCurrent(
                starting: startingPlaybackLease,
                current: MediaStatePlaybackLease.snapshot
            ) else { return .skipped }

            if outcome.remoteNeedsPush {
                guard fetched.isComplete,
                      fetched.revision?.isComplete != false else {
                    Logger.shared.log(
                        "MediaStateSync: \(providerDisplayName) kept usable remote salvage but blocked upload because the fetched authority was incomplete",
                        type: "Error"
                    )
                    return .failed(
                        "Eclipse recovered usable remote media state, but did not overwrite an incomplete remote copy."
                    )
                }
                guard !Task.isCancelled,
                      !MediaStateAccountBoundaryRecoveryGate.isBlockingSync,
                      isEnabled,
                      accountContinuityToken == startingAccount,
                      MediaStatePlaybackLeaseLifecyclePolicy.automaticSynchronizationAuthorityIsCurrent(
                        starting: startingPlaybackLease,
                        current: MediaStatePlaybackLease.snapshot
                      ) else {
                    Logger.shared.log(
                        "MediaStateSync: \(providerDisplayName) push abandoned (\(reason)); playback, the account, or recovery state changed mid-pass",
                        type: "iCloud"
                    )
                    return .skipped
                }
                do {
                    try await pushEnvelopes(
                        outcome.merged,
                        expecting: fetched.revision,
                        accountContinuityToken: startingAccount
                    )
                    guard !Task.isCancelled,
                          !MediaStateAccountBoundaryRecoveryGate.isBlockingSync,
                          isEnabled,
                          accountContinuityToken == startingAccount,
                          MediaStatePlaybackLeaseLifecyclePolicy.automaticSynchronizationAuthorityIsCurrent(
                            starting: startingPlaybackLease,
                            current: MediaStatePlaybackLease.snapshot
                          ) else {
                        return .skipped
                    }
                } catch is MediaStateRemoteRevisionConflict {
                    guard MediaStatePlaybackLeaseLifecyclePolicy.automaticSynchronizationAuthorityIsCurrent(
                        starting: startingPlaybackLease,
                        current: MediaStatePlaybackLease.snapshot
                    ) else { return .skipped }
                    Logger.shared.log(
                        "MediaStateSync: \(providerDisplayName) re-reading (\(reason)); another device wrote the bundle first",
                        type: "iCloud"
                    )
                    return .retry
                }
            }
            guard !Task.isCancelled,
                  !MediaStateAccountBoundaryRecoveryGate.isBlockingSync,
                  isEnabled,
                  accountContinuityToken == startingAccount,
                  MediaStatePlaybackLeaseLifecyclePolicy.automaticSynchronizationAuthorityIsCurrent(
                    starting: startingPlaybackLease,
                    current: MediaStatePlaybackLease.snapshot
                  ) else {
                return .skipped
            }
            Logger.shared.log(
                "MediaStateSync: \(providerDisplayName) reconciled (\(reason)) applied=\(outcome.namesChangedLocally.count) pushed=\(outcome.namesOwedToRemote.count)",
                type: "iCloud"
            )
            return .completed
        } catch is MediaStateSyncPassInvalidated {
            Logger.shared.log(
                "MediaStateSync: \(providerDisplayName) deferred (\(reason)); the account or recovery state changed",
                type: "iCloud"
            )
            return .skipped
        } catch is MediaStateRemoteRevisionConflict {
            guard MediaStatePlaybackLeaseLifecyclePolicy.automaticSynchronizationAuthorityIsCurrent(
                starting: startingPlaybackLease,
                current: MediaStatePlaybackLease.snapshot
            ) else { return .skipped }
            Logger.shared.log(
                "MediaStateSync: \(providerDisplayName) re-reading (\(reason)); the fetched candidate set changed",
                type: "iCloud"
            )
            return .retry
        } catch is CancellationError {
            return .skipped
        } catch {
            guard !Task.isCancelled,
                  MediaStatePlaybackLeaseLifecyclePolicy.automaticSynchronizationAuthorityIsCurrent(
                    starting: startingPlaybackLease,
                    current: MediaStatePlaybackLease.snapshot
                  ) else { return .skipped }
            Logger.shared.log(
                "MediaStateSync: \(providerDisplayName) transport failed (\(reason)): \(error.localizedDescription)",
                type: "Error"
            )
            return .failed(error.localizedDescription)
        }
    }
}

struct MediaStateEnvelopeBundle: Codable, Sendable {
    var schemaVersion: Int
    var records: [String: MediaStateEnvelope]

    init(records: [String: MediaStateEnvelope]) {
        self.schemaVersion = MediaStateEnvelope.schemaVersion
        self.records = records
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

enum MediaStateEnvelopeReconciler {

    struct Result: Equatable, Sendable {
        var merged: [String: MediaStateEnvelope]

        var namesOwedToRemote: [String]

        var namesChangedLocally: [String]

        var localDidChange: Bool { !namesChangedLocally.isEmpty }
        var remoteNeedsPush: Bool { !namesOwedToRemote.isEmpty }
    }

    static func reconcile(
        local: [String: MediaStateEnvelope],
        remote: [String: MediaStateEnvelope]
    ) -> Result {
        var merged = local
        var namesChangedLocally: [String] = []

        for (recordName, remoteEnvelope) in remote {
            guard let localEnvelope = merged[recordName] else {
                merged[recordName] = remoteEnvelope
                namesChangedLocally.append(recordName)
                continue
            }
            var resolved = localEnvelope.merged(with: remoteEnvelope)

            resolved.systemFields = localEnvelope.systemFields
            if resolved != localEnvelope, !isEquivalentOnTheWire(resolved, localEnvelope) {
                merged[recordName] = resolved
                namesChangedLocally.append(recordName)
            }
        }

        var namesOwedToRemote: [String] = []
        for (recordName, mergedEnvelope) in merged {
            guard let remoteEnvelope = remote[recordName] else {
                namesOwedToRemote.append(recordName)
                continue
            }
            if !isEquivalentOnTheWire(mergedEnvelope, remoteEnvelope) {
                namesOwedToRemote.append(recordName)
            }
        }

        return Result(
            merged: merged,
            namesOwedToRemote: namesOwedToRemote.sorted(),
            namesChangedLocally: namesChangedLocally.sorted()
        )
    }

    private static func isEquivalentOnTheWire(
        _ lhs: MediaStateEnvelope,
        _ rhs: MediaStateEnvelope
    ) -> Bool {
        normalizedForWireComparison(lhs) == normalizedForWireComparison(rhs)
    }

    private static func normalizedForWireComparison(
        _ envelope: MediaStateEnvelope
    ) -> MediaStateEnvelope {
        var normalized = envelope
        normalized.systemFields = nil
        normalized.modifiedAt = wirePrecisionDate(envelope.modifiedAt)
        normalized.deletedAt = envelope.deletedAt.map(wirePrecisionDate)
        normalized.resetAt = envelope.resetAt.map(wirePrecisionDate)
        return normalized
    }

    private static func wirePrecisionDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }

    static func strippedForRemote(
        _ records: [String: MediaStateEnvelope]
    ) -> [String: MediaStateEnvelope] {
        records.mapValues { envelope in
            var stripped = envelope
            stripped.systemFields = nil
            return stripped
        }
    }
}

@available(iOS 17.0, tvOS 17.0, *)
final class MediaStateCloudKitTransport: MediaStateSyncTransport {
    static let shared = MediaStateCloudKitTransport()

    private init() {}

    nonisolated var providerDisplayName: String { "iCloud" }

    nonisolated var isEnabled: Bool {
        MediaStateSyncBootstrap.isCloudKitSyncEnabled
    }

    func synchronize(reason: String) async {
        await MainActor.run {
            MediaStateSyncManager.shared.syncNow()
        }
    }

    func fetchRemoteEnvelopes(accountContinuityToken: String?) async throws -> MediaStateRemoteFetch {
        await MainActor.run {

            MediaStateRemoteFetch(
                records: MediaStateSyncManager.shared.envelopesForRemoteTransport(),
                revision: nil
            )
        }
    }

    func pushEnvelopes(
        _ merged: [String: MediaStateEnvelope],
        expecting revision: MediaStateRemoteRevision?,
        accountContinuityToken: String?
    ) async throws {

        _ = await MainActor.run {
            MediaStateSyncManager.shared.applyRemoteTransportMerge(from: merged)
        }
    }
}

#if os(iOS)

enum MediaStateRemoteTransportCooldownPolicy {
    static func isReady(retryNotBefore: Date?, now: Date) -> Bool {
        guard let retryNotBefore else { return true }
        guard retryNotBefore.timeIntervalSince1970.isFinite else { return true }
        return retryNotBefore <= now
    }

    static func nextRetryDate(_ dates: [Date?], after now: Date) -> Date? {
        dates.compactMap { $0 }.filter {
            $0.timeIntervalSince1970.isFinite && $0 > now
        }.min()
    }
}

@available(iOS 17.0, *)
final class MediaStateRemoteEnvelopeTransport: MediaStateSyncTransport {
    fileprivate let provider: CloudSyncProvider

    init(provider: CloudSyncProvider) {
        self.provider = provider
    }

    var providerDisplayName: String { provider.displayName }

    var isEnabled: Bool {
        guard provider != .iCloud else { return false }
        guard ExperimentalFeatureState.isEnabledAtLaunch else { return false }

        guard !UserDefaults.standard.bool(forKey: provider.accountBoundaryPendingKey) else {
            return false
        }
        return UserDefaults.standard.bool(forKey: provider.syncEnabledKey)
    }

    var accountContinuityToken: String? {
        let defaults = UserDefaults.standard
        let generation = defaults.integer(forKey: provider.accountGenerationKey)
        let identity = defaults.string(forKey: provider.accountIdentityKey) ?? ""
        return "\(generation)|\(identity)"
    }

    var retryNotBefore: Date? {
        let defaults = UserDefaults.standard
        let timestamp = defaults.double(forKey: provider.retryNotBeforeKey)
        guard timestamp != 0 else { return nil }
        guard let date = ExperimentalCloudPersistedSchedule.date(
            timestamp: timestamp,
            now: Date()
        ) else {
            defaults.removeObject(forKey: provider.retryNotBeforeKey)
            return nil
        }
        return date
    }

    func recordSuccessfulSynchronization() async {
        await MainActor.run {
            ExperimentalCloudSyncManager.shared.recordMediaStateTransportSuccess(for: provider)
        }
    }

    func recordFailedSynchronization(_ message: String) async {
        await MainActor.run {
            ExperimentalCloudSyncManager.shared.recordMediaStateTransportFailure(
                for: provider,
                message: message
            )
        }
    }

    func fetchRemoteEnvelopes(accountContinuityToken: String?) async throws -> MediaStateRemoteFetch {
        let fetched = try await ExperimentalCloudSyncManager.readMediaStateEnvelopeBundle(
            provider: provider,
            accountContinuityToken: accountContinuityToken
        )

        guard let data = fetched.data, !data.isEmpty else {
            return MediaStateRemoteFetch(records: [:], revision: fetched.revision)
        }
        let bundle = try MediaStateEnvelopeBundle.decoder().decode(
            MediaStateEnvelopeBundle.self,
            from: data
        )
        guard bundle.schemaVersion >= 1,
              bundle.schemaVersion <= MediaStateEnvelope.schemaVersion else {
            throw MediaStateRemoteBundleError.invalid("unsupported bundle schema")
        }
        if let reason = MediaStateEnvelopeValidator.aggregateRejectionReason(
            for: bundle.records,
            allowsSystemFields: false
        ) {
            throw MediaStateRemoteBundleError.invalid(reason)
        }
        let usable = MediaStateEnvelopeValidator.structurallyValidRemoteRecords(bundle.records)
        if !usable.droppedRecordNames.isEmpty {
            Logger.shared.log(
                "MediaStateSync: dropped \(usable.droppedRecordNames.count) invalid record(s) from the \(provider.rawValue) bundle and kept the remaining \(usable.records.count)",
                type: "Error"
            )
        }
        if !usable.repairedRecordNames.isEmpty {
            Logger.shared.log(
                "MediaStateSync: stripped invalid nested playback context from \(usable.repairedRecordNames.count) \(provider.rawValue) progress record(s) while retaining their watch progress",
                type: "Error"
            )
        }
        if let overflow = MediaStateEnvelopeValidator.rosterOverflowDescription(in: usable.records) {
            Logger.shared.log(
                "MediaStateSync: \(provider.rawValue) bundle carries \(overflow); loaded it and left the cap to the roster merge",
                type: "Error"
            )
        }
        let isComplete = usable.droppedRecordNames.isEmpty
            && usable.repairedRecordNames.isEmpty
            && fetched.revision?.isComplete != false
        return MediaStateRemoteFetch(
            records: usable.records,
            revision: fetched.revision,
            isComplete: isComplete
        )
    }

    func pushEnvelopes(
        _ merged: [String: MediaStateEnvelope],
        expecting revision: MediaStateRemoteRevision?,
        accountContinuityToken: String?
    ) async throws {
        guard !Task.isCancelled,
              !MediaStateAccountBoundaryRecoveryGate.isBlockingSync,
              isEnabled,
              self.accountContinuityToken == accountContinuityToken else {
            throw MediaStateSyncPassInvalidated()
        }
        let stripped = MediaStateEnvelopeReconciler.strippedForRemote(merged)
        if let reason = MediaStateEnvelopeValidator.rejectionReason(
            for: stripped,
            allowsSystemFields: false
        ) {
            Logger.shared.log(
                "MediaStateSync: refused to publish a \(provider.rawValue) bundle this device's own reader would refuse (\(reason)); the remote copy is untouched and local state is intact",
                type: "Error"
            )
            throw MediaStateRemoteBundleError.unpublishable(reason)
        }
        let publishable = MediaStateEnvelopeValidator.structurallyValidRemoteRecords(stripped)
        if !publishable.droppedRecordNames.isEmpty || !publishable.repairedRecordNames.isEmpty {
            Logger.shared.log(
                "MediaStateSync: refused an outgoing \(provider.rawValue) bundle that required record dropping or repair",
                type: "Error"
            )
            throw MediaStateRemoteBundleError.unpublishable("outgoing records require repair")
        }
        let outgoing = publishable.records
        let bundle = MediaStateEnvelopeBundle(records: outgoing)
        let data = try MediaStateEnvelopeBundle.encoder().encode(bundle)

        guard !Task.isCancelled,
              !MediaStateAccountBoundaryRecoveryGate.isBlockingSync,
              isEnabled,
              self.accountContinuityToken == accountContinuityToken else {
            throw MediaStateSyncPassInvalidated()
        }
        try await ExperimentalCloudSyncManager.writeMediaStateEnvelopeBundle(
            data,
            provider: provider,
            expecting: revision,
            accountContinuityToken: accountContinuityToken
        )
        guard !Task.isCancelled,
              !MediaStateAccountBoundaryRecoveryGate.isBlockingSync,
              self.accountContinuityToken == accountContinuityToken else {
            throw MediaStateSyncPassInvalidated()
        }
    }
}

private enum MediaStateRemoteBundleError: LocalizedError {
    case invalid(String)
    case unpublishable(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let reason):
            return "The remote media-state bundle is invalid (\(reason))."
        case .unpublishable(let reason):
            return "Eclipse did not upload this device's state because it exceeds the limits every device applies when reading synced data (\(reason))."
        }
    }
}

@available(iOS 17.0, *)
@MainActor
final class MediaStateRemoteTransportCoordinator {
    static let shared = MediaStateRemoteTransportCoordinator()

    private var transports: [CloudSyncProvider: MediaStateRemoteEnvelopeTransport] = [:]
    private var isSyncing = false
    private var activeSyncPassID: UUID?
    private var activeSyncTask: Task<Void, Never>?
    private var hasPendingRequest = false
    private var pendingRequestReason: String?
    private var lastActivationPassStartedAt: Date?

    private var deferredSyncTask: Task<Void, Never>?
    private var cooldownSyncTask: Task<Void, Never>?

    private let localChangeDebounce: TimeInterval = 8
    private let activationPassFloor: TimeInterval = 60

    private init() {}

    func scheduleDeferredSync(reason: String) {
        guard !MediaStateAccountBoundaryRecoveryGate.isBlockingSync,
              !enabledTransports.isEmpty,
              MediaStatePlaybackLeaseLifecyclePolicy.allowsAutomaticSynchronization(
                isPlaybackLeaseActive: MediaStatePlaybackLease.isActive
              ) else {
            deferredSyncTask?.cancel()
            deferredSyncTask = nil
            return
        }
        deferredSyncTask?.cancel()
        deferredSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.localChangeDebounce * 1_000_000_000))
            guard !Task.isCancelled,
                  MediaStatePlaybackLeaseLifecyclePolicy.allowsAutomaticSynchronization(
                    isPlaybackLeaseActive: MediaStatePlaybackLease.isActive
                  ) else { return }
            self.syncEnabledProviders(reason: reason)
        }
    }

    func invalidateActiveSyncPasses() {
        deferredSyncTask?.cancel()
        deferredSyncTask = nil
        hasPendingRequest = false
        pendingRequestReason = nil
        activeSyncPassID = nil
        isSyncing = false
        activeSyncTask?.cancel()
        activeSyncTask = nil
        cooldownSyncTask?.cancel()
        cooldownSyncTask = nil
    }

    private var enabledTransports: [MediaStateRemoteEnvelopeTransport] {
        CloudSyncProvider.allCases
            .filter { $0 != .iCloud }
            .compactMap { provider in
                let transport = transports[provider] ?? {
                    let created = MediaStateRemoteEnvelopeTransport(provider: provider)
                    transports[provider] = created
                    return created
                }()
                return transport.isEnabled ? transport : nil
            }
    }

    func syncEnabledProviders(reason: String) {
        let startingPlaybackLease = MediaStatePlaybackLease.snapshot
        guard !MediaStateAccountBoundaryRecoveryGate.isBlockingSync,
              MediaStatePlaybackLeaseLifecyclePolicy.automaticSynchronizationAuthorityIsCurrent(
                starting: startingPlaybackLease,
                current: startingPlaybackLease
              ) else { return }
        let now = Date()
        let enabled = enabledTransports
        let active = enabled.filter { transport in
            MediaStateRemoteTransportCooldownPolicy.isReady(
                retryNotBefore: transport.retryNotBefore,
                now: now
            )
        }
        if let nextRetry = MediaStateRemoteTransportCooldownPolicy.nextRetryDate(
            enabled.map(\.retryNotBefore),
            after: now
        ) {
            scheduleCooldownSync(at: nextRetry)
        }
        guard !active.isEmpty else { return }

        guard !isSyncing else {
            hasPendingRequest = true
            if pendingRequestReason == nil || reason != "activation" {
                pendingRequestReason = reason
            }
            return
        }
        if reason == "activation" {
            if let last = lastActivationPassStartedAt,
               Date().timeIntervalSince(last) < activationPassFloor {
                return
            }
            lastActivationPassStartedAt = Date()
        }
        isSyncing = true
        let passID = UUID()
        activeSyncPassID = passID

        MediaStateSyncManager.shared.prepareForRemoteTransports()

        activeSyncTask = Task { @MainActor in
            defer {
                if activeSyncPassID == passID {
                    activeSyncPassID = nil
                    activeSyncTask = nil
                    isSyncing = false
                    if hasPendingRequest {
                        hasPendingRequest = false
                        let followUpReason = pendingRequestReason ?? reason
                        pendingRequestReason = nil
                        scheduleDeferredSync(reason: followUpReason)
                    }
                }
            }

            for transport in active {
                guard activeSyncPassID == passID,
                      !Task.isCancelled,
                      !MediaStateAccountBoundaryRecoveryGate.isBlockingSync,
                      MediaStatePlaybackLeaseLifecyclePolicy.automaticSynchronizationAuthorityIsCurrent(
                        starting: startingPlaybackLease,
                        current: MediaStatePlaybackLease.snapshot
                      ) else {
                    return
                }
                try? await ExperimentalCloudProviderSyncLane.shared.perform(
                    provider: transport.provider
                ) {
                    let now = Date()
                    guard MediaStateRemoteTransportCooldownPolicy.isReady(
                        retryNotBefore: transport.retryNotBefore,
                        now: now
                    ) else { return }
                    await transport.synchronize(reason: reason)
                }
            }
            guard MediaStatePlaybackLeaseLifecyclePolicy.automaticSynchronizationAuthorityIsCurrent(
                starting: startingPlaybackLease,
                current: MediaStatePlaybackLease.snapshot
            ) else { return }
            let now = Date()
            if let nextRetry = MediaStateRemoteTransportCooldownPolicy.nextRetryDate(
                enabledTransports.map(\.retryNotBefore),
                after: now
            ) {
                scheduleCooldownSync(at: nextRetry)
            }
        }
    }

    func resumeAfterPlaybackLease(reason: String) {
        guard MediaStatePlaybackLeaseLifecyclePolicy.allowsAutomaticSynchronization(
            isPlaybackLeaseActive: MediaStatePlaybackLease.isActive
        ) else { return }
        deferredSyncTask?.cancel()
        deferredSyncTask = nil
        syncEnabledProviders(reason: reason)
    }

    private func scheduleCooldownSync(at date: Date) {
        cooldownSyncTask?.cancel()
        cooldownSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let rawDelay = date.timeIntervalSinceNow
            guard rawDelay.isFinite else { return }
            let delay = max(0, min(rawDelay, 86_400))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.cooldownSyncTask = nil
            self.syncEnabledProviders(reason: "provider-cooldown-ended")
        }
    }
}

#endif
