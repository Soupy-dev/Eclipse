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
}

struct MediaStateRemoteRevision: Sendable, Equatable {

    var fileID: String?

    var token: String?

    var observedFiles: [MediaStateRemoteFileVersion] = []
}

struct MediaStateRemoteFileVersion: Sendable, Equatable {
    var fileID: String
    var token: String?
}

struct MediaStateRemoteFetch: Sendable {
    var records: [String: MediaStateEnvelope]

    var revision: MediaStateRemoteRevision?
}

struct MediaStateRemoteRevisionConflict: Error {}

private struct MediaStateSyncPassInvalidated: Error {}

@available(iOS 17.0, tvOS 17.0, *)
extension MediaStateSyncTransport {

    var accountContinuityToken: String? { nil }

    func synchronize(reason: String) async {

        let maximumAttempts = 3
        for _ in 0..<maximumAttempts {
            if await reconcileOnce(reason: reason) { return }
        }
        Logger.shared.log(
            "MediaStateSync: \(providerDisplayName) abandoned (\(reason)); the remote copy moved under every write",
            type: "iCloud"
        )
    }

    private func reconcileOnce(reason: String) async -> Bool {

        guard isEnabled,
              !MediaStateAccountBoundaryRecoveryGate.isBlockingSync,
              !Task.isCancelled else { return true }

        let startingAccount = accountContinuityToken
        do {
            let fetched = try await fetchRemoteEnvelopes(accountContinuityToken: startingAccount)
            guard !Task.isCancelled,
                  !MediaStateAccountBoundaryRecoveryGate.isBlockingSync,
                  isEnabled,
                  accountContinuityToken == startingAccount else {
                return true
            }

            let outcome = await MainActor.run { () -> MediaStateEnvelopeReconciler.Result? in

                guard !MediaStateAccountBoundaryRecoveryGate.isBlockingSync,
                      !Task.isCancelled,
                      isEnabled,
                      accountContinuityToken == startingAccount else { return nil }
                return MediaStateSyncManager.shared.applyRemoteTransportMerge(from: fetched.records)
            }

            guard let outcome else {
                let cause = accountContinuityToken == startingAccount
                    ? "the archive refused the merge"
                    : "the account changed during the fetch"
                Logger.shared.log(
                    "MediaStateSync: \(providerDisplayName) deferred (\(reason)); \(cause)",
                    type: "iCloud"
                )
                return true
            }

            if outcome.remoteNeedsPush {
                guard !Task.isCancelled,
                      !MediaStateAccountBoundaryRecoveryGate.isBlockingSync,
                      isEnabled,
                      accountContinuityToken == startingAccount else {
                    Logger.shared.log(
                        "MediaStateSync: \(providerDisplayName) push abandoned (\(reason)); the account or recovery state changed mid-pass",
                        type: "iCloud"
                    )
                    return true
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
                          accountContinuityToken == startingAccount else {
                        return true
                    }
                } catch is MediaStateRemoteRevisionConflict {
                    Logger.shared.log(
                        "MediaStateSync: \(providerDisplayName) re-reading (\(reason)); another device wrote the bundle first",
                        type: "iCloud"
                    )
                    return false
                }
            }
            Logger.shared.log(
                "MediaStateSync: \(providerDisplayName) reconciled (\(reason)) applied=\(outcome.namesChangedLocally.count) pushed=\(outcome.namesOwedToRemote.count)",
                type: "iCloud"
            )
            return true
        } catch is MediaStateSyncPassInvalidated {
            Logger.shared.log(
                "MediaStateSync: \(providerDisplayName) deferred (\(reason)); the account or recovery state changed",
                type: "iCloud"
            )
            return true
        } catch is MediaStateRemoteRevisionConflict {
            Logger.shared.log(
                "MediaStateSync: \(providerDisplayName) re-reading (\(reason)); the fetched candidate set changed",
                type: "iCloud"
            )
            return false
        } catch {
            Logger.shared.log(
                "MediaStateSync: \(providerDisplayName) transport failed (\(reason)): \(error.localizedDescription)",
                type: "Error"
            )
            return true
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
        MediaStateSyncBootstrap.hasCloudKitEntitlement
            && !MediaStateCloudKitSuspension.isSuspended
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

@available(iOS 17.0, *)
final class MediaStateRemoteEnvelopeTransport: MediaStateSyncTransport {
    private let provider: CloudSyncProvider

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
        if let overflow = MediaStateEnvelopeValidator.rosterOverflowDescription(in: usable.records) {
            Logger.shared.log(
                "MediaStateSync: \(provider.rawValue) bundle carries \(overflow); loaded it and left the cap to the roster merge",
                type: "Error"
            )
        }
        return MediaStateRemoteFetch(records: usable.records, revision: fetched.revision)
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
        if let reason = MediaStateEnvelopeValidator.aggregateRejectionReason(
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
        if !publishable.droppedRecordNames.isEmpty {
            Logger.shared.log(
                "MediaStateSync: dropped \(publishable.droppedRecordNames.count) invalid record(s) from the outgoing \(provider.rawValue) bundle and published the remaining \(publishable.records.count)",
                type: "Error"
            )
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

    private let localChangeDebounce: TimeInterval = 8
    private let activationPassFloor: TimeInterval = 60

    private init() {}

    func scheduleDeferredSync(reason: String) {
        guard !MediaStateAccountBoundaryRecoveryGate.isBlockingSync,
              !enabledTransports.isEmpty else { return }
        deferredSyncTask?.cancel()
        deferredSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.localChangeDebounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
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
        guard !MediaStateAccountBoundaryRecoveryGate.isBlockingSync else { return }
        let active = enabledTransports
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
                        syncEnabledProviders(reason: followUpReason)
                    }
                }
            }

            for transport in active {
                guard activeSyncPassID == passID,
                      !Task.isCancelled,
                      !MediaStateAccountBoundaryRecoveryGate.isBlockingSync else {
                    return
                }
                await transport.synchronize(reason: reason)
            }
        }
    }
}

#endif
