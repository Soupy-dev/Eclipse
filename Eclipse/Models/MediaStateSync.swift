import CloudKit
import Combine
import CoreData
import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

struct MediaStateAccountNeutralIsolationPersistencePolicy {
    static func isDurablyComplete(
        progressCleared: Bool,
        ratingsCleared: Bool,
        sourcesCleared: Bool,
        trackerCleanupProtected: Bool
    ) -> Bool {
        progressCleared
            && ratingsCleared
            && sourcesCleared
            && trackerCleanupProtected
    }
}

struct MediaStatePlaybackLeaseSnapshot: Equatable, Sendable {
    let generation: UInt64
    let isActive: Bool
}

enum MediaStatePlaybackLease {
    private static let lock = NSLock()
    private static var counter = MediaStatePlaybackLeaseCounter()
    private static var generation: UInt64 = 0

    static var isActive: Bool {
        snapshot.isActive
    }

    static var snapshot: MediaStatePlaybackLeaseSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return MediaStatePlaybackLeaseSnapshot(
            generation: generation,
            isActive: counter.activeSessionCount > 0
        )
    }

    static func begin() {
        lock.lock()
        generation &+= 1
        counter.begin()
        lock.unlock()
    }

    static func end() {
        lock.lock()
        let didEndFinalSession = counter.end()
        lock.unlock()
        if didEndFinalSession {
            NotificationCenter.default.post(name: .mediaStatePlaybackLeaseDidEnd, object: nil)
        }
    }
}

enum MediaStatePlaybackLeaseLifecyclePolicy {
    static func shouldBegin(hasFinalizedPlayback: Bool, hasBegunLease: Bool) -> Bool {
        !hasFinalizedPlayback && !hasBegunLease
    }

    static func shouldEnd(hasBegunLease: Bool, hasEndedLease: Bool) -> Bool {
        hasBegunLease && !hasEndedLease
    }

    static func allowsAutomaticSynchronization(isPlaybackLeaseActive: Bool) -> Bool {
        !isPlaybackLeaseActive
    }

    static func automaticSynchronizationAuthorityIsCurrent(
        starting: MediaStatePlaybackLeaseSnapshot,
        current: MediaStatePlaybackLeaseSnapshot
    ) -> Bool {
        !starting.isActive && starting == current
    }
}

enum MediaStateAccountBoundaryRecoveryGate {
    private static let maximumManifestBytes = 64 * 1024

    private struct PreparationAuthority: Decodable {
        let schemaVersion: Int
        let transactionID: UUID
        let state: String
    }

    private static var manifestURL: URL? {
#if os(iOS)
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return applicationSupport
            .appendingPathComponent("Eclipse", isDirectory: true)
            .appendingPathComponent("CloudSyncRestoreRecovery.manifest.json")
#else
        return nil
#endif
    }

    static var isBlockingSync: Bool {
#if os(iOS)
        if UserDefaults.standard.bool(forKey: "experimentalCloudRestorePendingV1") {
            return true
        }
        guard let manifestURL else {

            return true
        }
        return FileManager.default.fileExists(atPath: manifestURL.path)
#else
        return false
#endif
    }

    static func authorizesPreparation(transactionID: UUID) -> Bool {
#if os(iOS)
        guard let manifestURL,
              let handle = try? FileHandle(forReadingFrom: manifestURL) else {
            return false
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumManifestBytes + 1),
              data.count <= maximumManifestBytes,
              let authority = try? JSONDecoder().decode(
                  PreparationAuthority.self,
                  from: data
              ) else {
            return false
        }
        return authority.schemaVersion == 2
            && authority.transactionID == transactionID
            && authority.state == "preparing"
#else
        return false
#endif
    }
}

enum MediaStateCloudKitDeletionPolicy {
    static func describesAlreadyAbsentItem(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        switch ckError.code {
        case .zoneNotFound, .unknownItem:
            return true
        case .partialFailure:
            let partialErrors = ckError.partialErrorsByItemID ?? [:]
            return !partialErrors.isEmpty
                && partialErrors.values.allSatisfy { describesAlreadyAbsentItem($0) }
        default:
            return false
        }
    }
}

enum MediaStateCloudKitSaveFailurePolicy {
    static func permanentFailureMessage(for code: CKError.Code) -> String? {
        switch code {
        case .quotaExceeded:
            return "The iCloud account has no available storage for Eclipse media state. Local changes are waiting to upload."
        case .permissionFailure, .managedAccountRestricted:
            return "iCloud denied access to Eclipse media state. Local changes are waiting to upload."
        case .notAuthenticated:
            return "Sign in to iCloud to upload Eclipse media state. Local changes remain on this device."
        case .invalidArguments, .serverRejectedRequest, .constraintViolation,
             .missingEntitlement, .badContainer, .badDatabase,
             .incompatibleVersion, .referenceViolation, .limitExceeded:
            return "iCloud rejected part of Eclipse media state. Local changes remain on this device."
        default:
            return nil
        }
    }

    static func shouldRetryAutomatically(_ code: CKError.Code) -> Bool {
        switch code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable,
             .requestRateLimited, .zoneBusy, .serverResponseLost,
             .batchRequestFailed, .operationCancelled,
             .accountTemporarilyUnavailable:
            return true
        default:
            return false
        }
    }

    static func retryDelay(
        for code: CKError.Code,
        retryAfter: TimeInterval?,
        consecutiveFailureCount: Int,
        jitterFraction: Double = Double.random(in: 0...1)
    ) -> TimeInterval? {
        guard shouldRetryAutomatically(code) else { return nil }
        let fallbackBase: TimeInterval
        let fallbackMaximum: TimeInterval
        switch code {
        case .requestRateLimited, .serviceUnavailable, .zoneBusy,
             .accountTemporarilyUnavailable:
            fallbackBase = 60
            fallbackMaximum = 3_600
        case .batchRequestFailed, .serverResponseLost:
            fallbackBase = 15
            fallbackMaximum = 900
        case .networkUnavailable, .networkFailure:
            fallbackBase = 5
            fallbackMaximum = 300
        case .operationCancelled:
            fallbackBase = 2
            fallbackMaximum = 60
        default:
            fallbackBase = 30
            fallbackMaximum = 900
        }
        return MediaStateSyncRequestBackoffPolicy.retryDelay(
            serverSuggested: retryAfter,
            consecutiveFailureCount: consecutiveFailureCount,
            fallbackBase: fallbackBase,
            fallbackMaximum: fallbackMaximum,
            jitterFraction: jitterFraction
        )
    }
}

enum MediaStateSyncRequestBackoffPolicy {
    static let maximumServerDelay: TimeInterval = 7 * 24 * 60 * 60
    static let iCloudRetryNotBeforeKey = "experimentalCloudSyncRetryNotBeforeV1.icloud"

    static func boundedServerDelay(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return min(max(value, 1), maximumServerDelay)
    }

    static func retryDelay(
        serverSuggested: TimeInterval?,
        consecutiveFailureCount: Int,
        fallbackBase: TimeInterval,
        fallbackMaximum: TimeInterval,
        jitterFraction: Double
    ) -> TimeInterval {
        if let serverDelay = boundedServerDelay(serverSuggested) {
            return serverDelay
        }
        let safeBase = fallbackBase.isFinite ? max(0.1, fallbackBase) : 60
        let safeMaximum = fallbackMaximum.isFinite
            ? max(safeBase, fallbackMaximum)
            : max(safeBase, 3_600)
        let exponent = min(max(consecutiveFailureCount - 1, 0), 10)
        let exponential = min(safeMaximum, safeBase * pow(2, Double(exponent)))
        let safeJitter = jitterFraction.isFinite ? min(max(jitterFraction, 0), 1) : 0
        return min(safeMaximum, exponential + exponential * 0.2 * safeJitter)
    }

    static func revisionConflictDelay(
        attempt: Int,
        jitterFraction: Double = Double.random(in: 0...1)
    ) -> TimeInterval {
        retryDelay(
            serverSuggested: nil,
            consecutiveFailureCount: attempt + 1,
            fallbackBase: 0.5,
            fallbackMaximum: 4,
            jitterFraction: jitterFraction
        )
    }

    static func persistedRetryDate(timestamp: TimeInterval, now: Date) -> Date? {
        let nowTimestamp = now.timeIntervalSince1970
        guard timestamp.isFinite,
              nowTimestamp.isFinite,
              timestamp > 0,
              timestamp <= nowTimestamp + maximumServerDelay else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    static func shouldClear(retryNotBefore: Date?, now: Date) -> Bool {
        guard let retryNotBefore else { return true }
        guard retryNotBefore.timeIntervalSince1970.isFinite else { return true }
        return retryNotBefore <= now
    }

    static func laterDeadline(
        existing: Date?,
        proposed: Date,
        now: Date
    ) -> Date {
        let existingFuture = existing.flatMap {
            $0.timeIntervalSince1970.isFinite && $0 > now ? $0 : nil
        }
        guard proposed.timeIntervalSince1970.isFinite else {
            return existingFuture ?? now
        }
        return max(existingFuture ?? proposed, proposed)
    }
}

struct MediaStateSyncSingleFlightGate {
    private(set) var isActive = false

    mutating func begin() -> Bool {
        guard !isActive else { return false }
        isActive = true
        return true
    }

    mutating func reset() {
        isActive = false
    }
}

enum MediaStateCloudKitTaskBoundary {
    static func detached<Success: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Success
    ) -> Task<Success, Error> {
        Task.detached {
            try await operation()
        }
    }
}

enum MediaStateCloudKitPendingSavePolicy {
    static func namesToStage(
        requested: Set<String>,
        alreadyPending: Set<String>
    ) -> Set<String> {
        requested.subtracting(alreadyPending)
    }
}

enum MediaStateRemoteDeletionError: LocalizedError {
    case accountWorkInProgress

    var errorDescription: String? {
        "Eclipse is still finishing an iCloud account change. Try deleting the cloud copy again in a moment."
    }
}

enum MediaStateCloudKitSuspension {
    static let storageKey = "mediaStateCloudKitSuspendedAfterDeletionV1"

    static var isSuspended: Bool {
#if os(iOS)
        return UserDefaults.standard.bool(forKey: storageKey)
#else
        return false
#endif
    }

    static func suspend() {
        UserDefaults.standard.set(true, forKey: storageKey)
    }

    static func resume() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    static var needsUserVisibleResume: Bool {
        guard MediaStateSyncBootstrap.hasCloudKitEntitlement else { return false }
        if #available(iOS 17.0, tvOS 17.0, *) { return isSuspended }
        return false
    }
}

enum MediaStateLocalCapturePolicy {
    static func capturesLocalChanges(
        initialFetchCompleted: Bool,
        isTrustedOfflineCacheActive: Bool,
        isRemoteTransportModeActive: Bool
    ) -> Bool {
        initialFetchCompleted || isTrustedOfflineCacheActive || isRemoteTransportModeActive
    }
}

enum MediaStateServicesSettingSyncPolicy {
    static func participatesInGlobalSync(sharesServices: Bool) -> Bool {
        sharesServices
    }
}

enum MediaStateSkyStreamScopePolicy {
    static func profileIDs(
        from profileIDs: [UUID],
        sharesServices: Bool
    ) -> [UUID] {
        guard !sharesServices else { return [ProfileManager.defaultProfileID] }
        var seen = Set<UUID>()
        return profileIDs.filter { seen.insert($0).inserted }
    }

    static func recordName(for profileID: UUID) -> String {
        MediaStateRecordName.make(
            kind: .skyStreamMetadata,
            identifier: "safe-cloud-v1",
            profileID: profileID
        )
    }
}

enum MediaStateInvalidLocalDomainPolicy {
    static func shouldPreserveLocalDomain(
        invalidRecordNames: Set<String>,
        domainKinds: Set<MediaStateKind>,
        profileID: UUID
    ) -> Bool {
        invalidRecordNames.contains { recordName in
            guard let kind = MediaStateRecordName.kind(from: recordName),
                  domainKinds.contains(kind) else { return false }
            return MediaStateRecordName.profileID(from: recordName) == profileID
        }
    }
}

enum MediaStateCloudKitPreparationAuthorityPolicy {
    static func mayInstallEngine(
        preparationGeneration: Int,
        currentGeneration: Int,
        isSyncEnabled: Bool,
        isRecoveryBlocked: Bool,
        isDeletingRemoteState: Bool
    ) -> Bool {
        preparationGeneration == currentGeneration
            && isSyncEnabled
            && !isRecoveryBlocked
            && !isDeletingRemoteState
    }
}

enum MediaStateSameAccountRevalidationPolicy {
    static func shouldMigrateLocalState(
        isRevalidationInProgress: Bool,
        hadPendingIsolation: Bool,
        isAccountNeutralLocalStateActive: Bool,
        hasDeliberateLocalCacheReset: Bool,
        previousAccountRecordName: String?,
        currentAccountRecordName: String
    ) -> Bool {
        isRevalidationInProgress
            && !hadPendingIsolation
            && !isAccountNeutralLocalStateActive
            && !hasDeliberateLocalCacheReset
            && previousAccountRecordName == currentAccountRecordName
    }
}

enum MediaStateDeferredApplyPolicy {
    static func shouldFlushPendingCapture(
        isSignedOutIdentityConfirmed: Bool,
        verifiedOwnerMatchesArchive: Bool,
        isTrustedOfflineCacheActive: Bool,
        hasArchiveOwner: Bool
    ) -> Bool {
        !isSignedOutIdentityConfirmed
            && (verifiedOwnerMatchesArchive
                || (isTrustedOfflineCacheActive && hasArchiveOwner))
    }
}

enum MediaStatePendingIsolationCancellationPolicy {
    static func canReturnToOwnerWithoutCleanup(
        archiveOwnerRecordName: String?,
        currentAccountRecordName: String,
        isAccountNeutralLocalStateActive: Bool,
        hasPendingProfiles: Bool,
        pendingTargetMatchesCurrentAccount: Bool
    ) -> Bool {
        archiveOwnerRecordName == currentAccountRecordName
            && !isAccountNeutralLocalStateActive
            && hasPendingProfiles
            && !pendingTargetMatchesCurrentAccount
    }
}

enum MediaStateCloudKitUpgradeNoticePolicy {
    static func shouldPresent(
        hasCloudKitEntitlement: Bool,
        isSyncPreferenceEnabled: Bool,
        isCloudKitSyncSuspended: Bool,
        isAccountBoundaryRecoveryBlocking: Bool,
        hasDurablePriorSyncEvidence: Bool
    ) -> Bool {
        hasCloudKitEntitlement
            && !isSyncPreferenceEnabled
            && !isCloudKitSyncSuspended
            && !isAccountBoundaryRecoveryBlocking
            && hasDurablePriorSyncEvidence
    }
}

enum MediaStateSyncBootstrap {
    static var hasCloudKitEntitlement: Bool {
#if targetEnvironment(simulator) || ECLIPSE_UNSIGNED_BUILD

        return false
#else
        return true
#endif
    }

    static var isCloudKitSyncPreferenceEnabled: Bool {
        ProfileSettingsStore.device.bool(
            forKey: ExperimentalFeatureState.iCloudSyncEnabledKey
        )
    }

    static var isCloudKitSyncEnabled: Bool {
        hasCloudKitEntitlement
            && isCloudKitSyncPreferenceEnabled
            && !MediaStateCloudKitSuspension.isSuspended
    }

    static let cloudKitUpgradeNoticeHandledKey =
        "mediaStateCloudKitOptInUpgradeNoticeHandledV1"

    @MainActor
    static func prepareCloudKitUpgradeNoticeIfNeeded() -> Bool {
        let defaults = ProfileSettingsStore.device
        guard !defaults.bool(forKey: cloudKitUpgradeNoticeHandledKey) else {
            return false
        }

        guard #available(iOS 17.0, tvOS 17.0, *) else {
            defaults.set(true, forKey: cloudKitUpgradeNoticeHandledKey)
            return false
        }

        if MediaStateAccountBoundaryRecoveryGate.isBlockingSync {
            return false
        }

        let shouldPresent = MediaStateCloudKitUpgradeNoticePolicy.shouldPresent(
            hasCloudKitEntitlement: hasCloudKitEntitlement,
            isSyncPreferenceEnabled: isCloudKitSyncPreferenceEnabled,
            isCloudKitSyncSuspended: MediaStateCloudKitSuspension.isSuspended,
            isAccountBoundaryRecoveryBlocking: false,
            hasDurablePriorSyncEvidence:
                MediaStateSyncManager.hasDurablePriorCloudKitSyncEvidence
        )
        if !shouldPresent {
            defaults.set(true, forKey: cloudKitUpgradeNoticeHandledKey)
        }
        return shouldPresent
    }

    static func markCloudKitUpgradeNoticeHandled() {
        ProfileSettingsStore.device.set(
            true,
            forKey: cloudKitUpgradeNoticeHandledKey
        )
    }

    static func startIfAvailable() {
        guard hasCloudKitEntitlement,
              isCloudKitSyncPreferenceEnabled,
              !MediaStateAccountBoundaryRecoveryGate.isBlockingSync else { return }
        if #available(iOS 17.0, tvOS 17.0, *), hasCloudKitEntitlement {
            if Thread.isMainThread {

                MainActor.assumeIsolated {
                    MediaStateSyncManager.shared.start()
                }
            } else {
                Task { @MainActor in
                    MediaStateSyncManager.shared.start()
                }
            }
        }
    }

    @MainActor
    static func setCloudKitSyncEnabled(_ enabled: Bool) {
        ExperimentalFeatureState.registerDefaults(defaults: ProfileSettingsStore.device)
        ProfileSettingsStore.device.set(
            enabled,
            forKey: ExperimentalFeatureState.iCloudSyncEnabledKey
        )
        guard #available(iOS 17.0, tvOS 17.0, *), hasCloudKitEntitlement else {
            return
        }
        MediaStateSyncManager.shared.setCloudKitSyncEnabled(enabled)
    }

    @MainActor
    static var manualRestoreCanPropagate: Bool {
#if os(iOS)
        if #available(iOS 17.0, *) {
            return MediaStateSyncManager.shared.restoreCanPropagateToOtherDevices
        }
#endif
        return false
    }

    @MainActor
    @discardableResult
    static func adoptRemoteSettingsAfterEnablingSync() -> Bool {
        if #available(iOS 17.0, tvOS 17.0, *) {
            return MediaStateSyncManager.shared.adoptRemoteSettingsAfterEnablingSync()
        }
        return true
    }

    @MainActor
    @discardableResult
    static func publishLocalSettingsAfterEnablingSync() -> Bool {
        if #available(iOS 17.0, tvOS 17.0, *) {
            return MediaStateSyncManager.shared.publishLocalSettingsAfterEnablingSync()
        }
        return true
    }

    static func syncOnActivation() {
        guard !MediaStateAccountBoundaryRecoveryGate.isBlockingSync,
              MediaStatePlaybackLeaseLifecyclePolicy.allowsAutomaticSynchronization(
                isPlaybackLeaseActive: MediaStatePlaybackLease.isActive
              ) else { return }
        if #available(iOS 17.0, tvOS 17.0, *) {
            let cloudKit = MediaStateCloudKitTransport.shared
            if cloudKit.isEnabled {
                Task { await cloudKit.synchronize(reason: "activation") }
            }
#if os(iOS)

            Task { @MainActor in
                MediaStateRemoteTransportCoordinator.shared.syncEnabledProviders(
                    reason: "activation"
                )
            }
#endif
        }
    }

    static func resumeAfterAccountBoundaryRecovery() {
        guard !MediaStateAccountBoundaryRecoveryGate.isBlockingSync else { return }
        startIfAvailable()
        syncOnActivation()
    }
}

private struct MediaStateRemoteAccountBoundaryRecoverySidecar: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let transactionID: UUID
    let archive: MediaStateLocalArchive

    init(transactionID: UUID, archive: MediaStateLocalArchive) {
        schemaVersion = Self.currentSchemaVersion
        self.transactionID = transactionID
        self.archive = archive
    }
}

@available(iOS 17.0, tvOS 17.0, *)
private struct MediaStateEngineStateDocument: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let accountOwnerRecordName: String
    let serialization: CKSyncEngine.State.Serialization

    init(
        accountOwnerRecordName: String,
        serialization: CKSyncEngine.State.Serialization
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.accountOwnerRecordName = accountOwnerRecordName
        self.serialization = serialization
    }
}

private enum MediaStateLocalArchiveLoadResult {
    case missing
    case loaded(MediaStateLocalArchive)
    case unavailable(String)
}

@available(iOS 17.0, tvOS 17.0, *)
@MainActor
final class MediaStateSyncManager: NSObject, ObservableObject {
    static let shared = MediaStateSyncManager()

    @Published private(set) var phase: MediaStateSyncPhase = .idle
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var lastErrorMessage: String?

    private static let containerIdentifier = "iCloud.Eclipse.Soupy"
    private static let zoneName = "EclipseMediaState"
    private static let recordType = "EclipseMediaState"
    private static let subscriptionID = "EclipseMediaStateChanges"
    private static let maxPayloadBytes = MediaStateEnvelope.maximumPayloadBytes

    private static let maximumArchiveBytes = 256 * 1_024 * 1_024
    private static let maximumAccountBoundaryRecoveryBytes =
        maximumArchiveBytes + (8 * 1_024 * 1_024)

    private static let maximumEngineStateBytes = 16 * 1_024 * 1_024
    static var hasDurablePriorCloudKitSyncEvidence: Bool {
        switch loadArchive() {
        case .loaded(let archive):
            if archive.accountOwnerRecordName != nil {
                return true
            }
        case .missing, .unavailable:
            break
        }

        return FileManager.default.fileExists(atPath: engineStateURL.path)
            || FileManager.default.fileExists(
                atPath: accountBoundaryRecoveryURL.path
            )
    }

    private lazy var container = CKContainer(identifier: Self.containerIdentifier)
    private let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var engine: CKSyncEngine?
    private var archive: MediaStateLocalArchive

    private var isArchiveStateDurable = true

    private var pendingEngineStateSerialization: CKSyncEngine.State.Serialization?

    private var isLocalArchiveUnavailable = false
    private var localArchiveUnavailableDetail = "Media state storage is temporarily unavailable."
    private var started = false
    private var isPreparingEngine = false
    private var accountPreparationGeneration = 0
    private var isAccountRevalidationInProgress = false
    private var accountRevalidationTask: Task<Void, Never>?
    private var accountRevalidationPassID: UUID?
    private var initialFetchCompleted = false
    private var isTrustedOfflineCacheActive = false
    private var initialLocalStatePolicy: MediaStateInitialLocalStatePolicy = .migrateLocalState
    private var isAccountIsolationInProgress = false
    private var verifiedAccountRecordName: String?
    private var suppressedDefaultRecordNames: Set<String> = []
    private var pendingAccountBoundaryPayloadHashes: [String: String] = [:]
    private var lastAppliedSkyStreamPayloadHashes: [String: String] = [:]
    private var inFlightSkyStreamPayloadHashes: [String: String] = [:]
    private var lastSkyStreamMetadataEncodingFailure: String?
    private var isApplyingRemoteState = false
    private var hasDeferredRemoteApply = false

    private var hasDeferredDestructiveAccountIsolation = false

    private var isReversibleAccountIdentityRevalidation = false

    private var isSignedOutIdentityConfirmed = false

    private var isWholeSnapshotRestoreInProgress = false

    private var isPreparedRecoverySyncSuspended = false
    private var preparedRecoverySuspensionTransactionID: UUID?
    private var isPreparedRecoverySyncBlocked: Bool {
        isLocalArchiveUnavailable
            || isPreparedRecoverySyncSuspended
            || MediaStateAccountBoundaryRecoveryGate.isBlockingSync
    }
    private var hasPendingAccountIsolationJournal: Bool {
        !archive.pendingAccountIsolationProfileIDs.isEmpty
            || archive.pendingAccountIsolationTarget != nil
    }

    private var isDeletingRemoteMediaState = false
    private var isRemoteTransportModeActive = false
    private var captureTask: Task<Void, Never>?
    private var explicitSyncTask: Task<Void, Never>?
    private var explicitSyncPassID: UUID?
    private var explicitSyncGate = MediaStateSyncSingleFlightGate()
    private var cloudKitTransientFailureCount = 0
    private var hasPlaybackDeferredLocalCapture = false
    private var preparationRetryTask: Task<Void, Never>?
    private var skyStreamRestoreTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var observersInstalled = false

    private override init() {
        switch Self.loadArchive() {
        case .missing:
            archive = .empty
            if FileManager.default.fileExists(atPath: Self.accountBoundaryRecoveryURL.path) {
                isLocalArchiveUnavailable = true
                isArchiveStateDurable = false
                localArchiveUnavailableDetail =
                    "A sync recovery point from an interrupted account change is waiting to be restored."
            }
        case .loaded(let loadedArchive):
            archive = loadedArchive
        case .unavailable(let detail):
            archive = .empty
            isLocalArchiveUnavailable = true
            isArchiveStateDurable = false
            localArchiveUnavailableDetail = detail
        }
        super.init()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        decoder.dateDecodingStrategy = .millisecondsSince1970
        configureIsolationStateFromLoadedArchive()
        if isLocalArchiveUnavailable {
            phase = .localOnly(localArchiveUnavailableDetail)
            lastErrorMessage = localArchiveUnavailableDetail
        } else if !MediaStateSyncBootstrap.hasCloudKitEntitlement {
            phase = .localOnly("This build has no iCloud entitlement. Eclipse remains usable with local media state.")
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        captureTask?.cancel()
        explicitSyncTask?.cancel()
        preparationRetryTask?.cancel()
        skyStreamRestoreTask?.cancel()
        accountRevalidationTask?.cancel()
    }

    private func configureIsolationStateFromLoadedArchive() {
        initialLocalStatePolicy = .migrateLocalState
        isAccountIsolationInProgress = false
        hasDeferredDestructiveAccountIsolation = false
        hasDeferredRemoteApply = false
        guard hasPendingAccountIsolationJournal else { return }

        initialLocalStatePolicy = .isolateIncomingAccount
        isAccountIsolationInProgress = true
        hasDeferredDestructiveAccountIsolation = true
        hasDeferredRemoteApply = true
    }

    @discardableResult
    private func retryUnavailableLocalArchiveIfPossible() -> Bool {
        guard isLocalArchiveUnavailable else { return true }
        switch Self.loadArchive() {
        case .loaded(let loadedArchive):
            archive = loadedArchive
            isLocalArchiveUnavailable = false
            isArchiveStateDurable = true
            localArchiveUnavailableDetail = ""
            configureIsolationStateFromLoadedArchive()
            phase = .idle
            lastErrorMessage = nil
            return true
        case .missing:
            if installRetainedAccountBoundarySidecarArchive() {
                return true
            }

            localArchiveUnavailableDetail =
                "Existing media state became unavailable. Eclipse will not replace it automatically."
        case .unavailable(let detail):
            localArchiveUnavailableDetail = detail
        }
        phase = .localOnly(localArchiveUnavailableDetail)
        lastErrorMessage = localArchiveUnavailableDetail
        return false
    }

    private func decodedRetainedAccountBoundarySidecar() -> MediaStateRemoteAccountBoundaryRecoverySidecar? {
        guard let data = try? Self.boundedLocalData(
                at: Self.accountBoundaryRecoveryURL,
                maximumBytes: Self.maximumAccountBoundaryRecoveryBytes
              ),
              let sidecar = Self.decodeAccountBoundaryRecoverySidecar(data),
              sidecar.archive.pendingAccountIsolationProfileIDs.isEmpty,
              sidecar.archive.pendingAccountIsolationTarget == nil else {
            return nil
        }
        return sidecar
    }

    private func installRetainedAccountBoundarySidecarArchive() -> Bool {
        guard !MediaStatePlaybackLease.isActive,
              let sidecar = decodedRetainedAccountBoundarySidecar() else {
            return false
        }
        captureTask?.cancel()
        captureTask = nil
        let previousArchive = archive
        let previousDetail = localArchiveUnavailableDetail
        archive = sidecar.archive
        isLocalArchiveUnavailable = false
        isArchiveStateDurable = true
        localArchiveUnavailableDetail = ""
        guard persistArchive() else {
            archive = previousArchive
            isLocalArchiveUnavailable = true
            isArchiveStateDurable = false
            localArchiveUnavailableDetail = previousDetail
            phase = .localOnly(localArchiveUnavailableDetail)
            lastErrorMessage = localArchiveUnavailableDetail
            return false
        }
        configureIsolationStateFromLoadedArchive()
        applyArchiveToManagers(allowsConfirmedEmptyRoster: true)
        archive.lastLocalRecordNames = buildLocalSnapshot().recordNames
        persistArchive()
        phase = .idle
        lastErrorMessage = nil
        Logger.shared.log(
            "MediaStateSync: installed the retained account-boundary recovery point as the canonical archive",
            type: "iCloud"
        )
        return true
    }

    func recoverRetainedAccountBoundaryArchiveAfterUserConfirmation() -> Bool {
        guard !MediaStatePlaybackLease.isActive else { return false }
        if retryUnavailableLocalArchiveIfPossible() {
            return completeRemoteAccountBoundaryArchiveRecovery(transactionID: nil)
        }
        guard isLocalArchiveUnavailable,
              decodedRetainedAccountBoundarySidecar() != nil else {
            return false
        }
        let quarantineURL = Self.archiveURL.appendingPathExtension("quarantined")
        let quarantinedExistingArchive: Bool
        if FileManager.default.fileExists(atPath: Self.archiveURL.path) {
            try? FileManager.default.removeItem(at: quarantineURL)
            guard (try? FileManager.default.moveItem(
                at: Self.archiveURL,
                to: quarantineURL
            )) != nil else {
                return false
            }
            quarantinedExistingArchive = true
        } else {
            quarantinedExistingArchive = false
        }
        guard installRetainedAccountBoundarySidecarArchive() else {
            if quarantinedExistingArchive {
                try? FileManager.default.moveItem(at: quarantineURL, to: Self.archiveURL)
            }
            return false
        }
        return completeRemoteAccountBoundaryArchiveRecovery(transactionID: nil)
    }

    var isCanonicalStateUnavailableForSnapshotWrites: Bool {
        isLocalArchiveUnavailable || isRetainingAccountBoundaryRecovery
    }

    var isRetainingAccountBoundaryRecovery: Bool {
        FileManager.default.fileExists(atPath: Self.accountBoundaryRecoveryURL.path)
    }

    var canonicalArchiveUnavailabilityDetail: String? {
        isLocalArchiveUnavailable ? localArchiveUnavailableDetail : nil
    }

    var userActionAccountGeneration: Int {
        accountPreparationGeneration
    }

    func setCloudKitSyncEnabled(_ enabled: Bool) {
        if enabled {
            flushPendingCapture()
            start()
            return
        }

        captureTask?.cancel()
        captureTask = nil
        explicitSyncTask?.cancel()
        explicitSyncTask = nil
        explicitSyncPassID = nil
        explicitSyncGate.reset()
        _ = captureAndQueueLocalChanges(queueChanges: false)
        preparationRetryTask?.cancel()
        preparationRetryTask = nil
        accountRevalidationTask?.cancel()
        accountRevalidationTask = nil
        accountRevalidationPassID = nil
        isAccountRevalidationInProgress = false
        let staleEngine = detachActiveEngineForAccountIsolation()
        started = isRemoteTransportModeActive
        if !hasPendingAccountIsolationJournal,
           !archive.isAccountNeutralLocalStateActive {
            isTrustedOfflineCacheActive = archive.accountOwnerRecordName != nil
        }
        phase = .localOnly("iCloud media-state sync is off. This device keeps its local data.")
        lastErrorMessage = nil
        Task { await staleEngine?.cancelOperations() }
    }

    func start() {
        guard !isDeletingRemoteMediaState else { return }
        guard MediaStateSyncBootstrap.isCloudKitSyncPreferenceEnabled else {
            phase = .localOnly("iCloud media-state sync is off. This device keeps its local data.")
            return
        }
        if isLocalArchiveUnavailable {
            installObservers()
            guard retryUnavailableLocalArchiveIfPossible() else { return }
        }
        guard !isPreparedRecoverySyncBlocked else { return }
        guard !MediaStateCloudKitSuspension.isSuspended else {
            startLocalOnlyWhileCloudKitIsSuspended()
            return
        }
        guard !started else {
            if engine == nil, !isPreparingEngine, !isAccountRevalidationInProgress {
                Task { await prepareEngineAndFetch() }
            }
            return
        }
        started = true
        installObservers()
        if !hasPendingAccountIsolationJournal,
           !archive.isAccountNeutralLocalStateActive {
            switch MediaStateLaunchCachePolicy.action(
                hasAccountOwner: archive.accountOwnerRecordName != nil,
                evidence: launchIdentityEvidence()
            ) {
            case .restoreOwnedCache where !archive.records.isEmpty:

                isTrustedOfflineCacheActive = true
                if applyArchiveToManagersOrDefer() {
                    archive.lastLocalRecordNames = buildLocalSnapshot().recordNames
                    captureAndQueueLocalChanges()
                }
            case .isolateLoadedState:

                break
            case .restoreOwnedCache, .awaitCloudKitVerification:

                break
            }
        }
        phase = .checkingAccount

        Task {
            await prepareEngineAndFetch()
        }
    }

    private func startLocalOnlyWhileCloudKitIsSuspended() {
        guard !started,
              !hasPendingAccountIsolationJournal,
              !isAccountIsolationInProgress,
              !archive.isAccountNeutralLocalStateActive,
              archive.accountOwnerRecordName != nil else { return }
        started = true
        installObservers()
        isTrustedOfflineCacheActive = true
        _ = captureAndQueueLocalChanges(queueChanges: false)
        phase = .localOnly("Eclipse deleted its iCloud copy. This device keeps its own library and watch progress.")
    }

    private var cloudKitRetryNotBefore: Date? {
        let defaults = UserDefaults.standard
        let timestamp = defaults.double(
            forKey: MediaStateSyncRequestBackoffPolicy.iCloudRetryNotBeforeKey
        )
        guard timestamp != 0 else { return nil }
        guard let date = MediaStateSyncRequestBackoffPolicy.persistedRetryDate(
            timestamp: timestamp,
            now: Date()
        ) else {
            defaults.removeObject(
                forKey: MediaStateSyncRequestBackoffPolicy.iCloudRetryNotBeforeKey
            )
            return nil
        }
        return date
    }

    private func cloudKitRetryDelayRemaining(now: Date = Date()) -> TimeInterval? {
        guard let retryNotBefore = cloudKitRetryNotBefore else { return nil }
        let delay = retryNotBefore.timeIntervalSince(now)
        return delay.isFinite && delay > 0 ? delay : nil
    }

    private func recordCloudKitTransientFailure(
        codes: [CKError.Code],
        retryAfter: TimeInterval?
    ) {
        guard !codes.isEmpty else { return }
        cloudKitTransientFailureCount = min(cloudKitTransientFailureCount + 1, 1_024)
        let delay = codes.compactMap {
            MediaStateCloudKitSaveFailurePolicy.retryDelay(
                for: $0,
                retryAfter: retryAfter,
                consecutiveFailureCount: cloudKitTransientFailureCount
            )
        }.max()
        guard let delay, delay.isFinite else { return }
        let now = Date()
        let proposed = now.addingTimeInterval(delay)
        let retryNotBefore = max(cloudKitRetryNotBefore ?? now, proposed)
        UserDefaults.standard.set(
            retryNotBefore.timeIntervalSince1970,
            forKey: MediaStateSyncRequestBackoffPolicy.iCloudRetryNotBeforeKey
        )
    }

    private func clearCloudKitTransientFailure() {
        let now = Date()
        cloudKitTransientFailureCount = 0
        guard MediaStateSyncRequestBackoffPolicy.shouldClear(
            retryNotBefore: cloudKitRetryNotBefore,
            now: now
        ) else { return }
        UserDefaults.standard.removeObject(
            forKey: MediaStateSyncRequestBackoffPolicy.iCloudRetryNotBeforeKey
        )
    }

    func syncNow() {
        guard MediaStateSyncBootstrap.isCloudKitSyncEnabled else { return }
        if isLocalArchiveUnavailable {
            start()
            return
        }
        guard !isPreparedRecoverySyncBlocked else { return }
        guard started else {
            start()
            return
        }
        if let retryDelay = cloudKitRetryDelayRemaining() {
            let message = "iCloud is temporarily limiting media-state sync. Eclipse will retry later."
            phase = .localOnly(message)
            lastErrorMessage = message
            if engine == nil {
                schedulePreparationRetry(after: retryDelay)
            }
            return
        }
        guard !isPreparingEngine else { return }
        guard explicitSyncGate.begin() else { return }
        guard let activeEngine = engine else {
            explicitSyncGate.reset()
            Task { await prepareEngineAndFetch() }
            return
        }
        let operationGeneration = accountPreparationGeneration
        let passID = UUID()
        explicitSyncPassID = passID
        let fetchTask = MediaStateCloudKitTaskBoundary.detached {
            try await activeEngine.fetchChanges()
        }
        explicitSyncTask = Task { [weak self] in
            guard let self else {
                fetchTask.cancel()
                return
            }
            defer {
                if self.explicitSyncPassID == passID {
                    self.explicitSyncTask = nil
                    self.explicitSyncPassID = nil
                    self.explicitSyncGate.reset()
                }
            }
            do {
                try await withTaskCancellationHandler {
                    try await fetchTask.value
                } onCancel: {
                    fetchTask.cancel()
                }
                guard operationGeneration == self.accountPreparationGeneration,
                      !self.isPreparedRecoverySyncBlocked,
                      MediaStateSyncBootstrap.isCloudKitSyncEnabled,
                      self.engine === activeEngine else { return }
                guard !self.hasPendingAccountIsolationJournal else {
                    self.hasDeferredRemoteApply = true
                    self.hasDeferredDestructiveAccountIsolation = true
                    return
                }
                if self.initialFetchCompleted {
                    let newlyStagedNames = Set(
                        self.captureAndQueueLocalChanges()
                    )
                    self.stageRecordSaves(
                        self.archive.pendingLocalRecordNames
                            .subtracting(newlyStagedNames),
                        on: activeEngine
                    )
                } else {
                    guard self.completeInitialFetch() else { return }
                }
                guard operationGeneration == self.accountPreparationGeneration,
                      !self.isPreparedRecoverySyncBlocked,
                      MediaStateSyncBootstrap.isCloudKitSyncEnabled,
                      self.engine === activeEngine else { return }
                if self.archive.pendingLocalRecordNames.isEmpty {
                    self.lastSyncDate = Date()
                    self.phase = .ready
                    self.lastErrorMessage = nil
                }
            } catch {
                guard operationGeneration == self.accountPreparationGeneration,
                      !self.isPreparedRecoverySyncBlocked,
                      MediaStateSyncBootstrap.isCloudKitSyncEnabled,
                      self.engine === activeEngine else { return }
                self.handleSyncError(error)
            }
        }
    }

    func prepareForRemoteTransports() {
        if isLocalArchiveUnavailable {
            installObservers()
            guard retryUnavailableLocalArchiveIfPossible() else { return }
        }
        guard !isPreparedRecoverySyncBlocked,
              !hasPendingAccountIsolationJournal,
              !isAccountIsolationInProgress else { return }
        guard !isRemoteTransportModeActive else { return }
        isRemoteTransportModeActive = true
        if !started {
            started = true
            installObservers()
        }
        if archive.lastLocalRecordNames.isEmpty {

            archive.lastLocalRecordNames = buildLocalSnapshot().recordNames
            persistArchive()
        }
    }

    func envelopesForRemoteTransport(
        allowsPreparedRecoveryTransaction: Bool = false
    ) -> [String: MediaStateEnvelope] {
        guard !isLocalArchiveUnavailable,
              !hasPendingAccountIsolationJournal,
              !isAccountIsolationInProgress,
              allowsPreparedRecoveryTransaction || !isPreparedRecoverySyncBlocked else {
            Logger.shared.log(
                "MediaStateSync: refused archive materialization during prepared recovery",
                type: "iCloud"
            )
            return [:]
        }

        if !isPreparedRecoverySyncBlocked {
            flushPendingCapture()
        }
        return archive.records
    }

    @discardableResult
    func replaceMediaStateForRemoteAccountBoundary(
        with remote: [String: MediaStateEnvelope],
        rejecting rejectedRemote: [String: MediaStateEnvelope] = [:],
        queuesRemoteChanges: Bool = true
    ) -> Bool {
        guard !isLocalArchiveUnavailable,
              !hasPendingAccountIsolationJournal,
              !isAccountIsolationInProgress,
              !MediaStatePlaybackLease.isActive,
              !isWholeSnapshotRestoreInProgress,
              let authoritative = MediaStateAccountBoundaryAuthority.replacing(
                existing: archive.records,
                selected: remote,
                rejected: rejectedRemote
              ) else {
            Logger.shared.log(
                "MediaStateSync: refused authoritative account-boundary replacement",
                type: "Error"
            )
            return false
        }

        let previousArchive = archive
        MediaStateAccountPlaybackBoundary.notifyWillChangeUser(sender: self)
        captureTask?.cancel()
        captureTask = nil
        archive.records = authoritative
        applyArchiveToManagers(allowsConfirmedEmptyRoster: true)
        archive.lastLocalRecordNames = buildLocalSnapshot().recordNames
        var capturePersisted = false
        let corrections = captureAndQueueLocalChanges(
            queueChanges: false,
            forPreparedRecoveryTransaction: true,
            persistenceResult: { capturePersisted = $0 }
        )
        guard capturePersisted else {
            _ = restoreArchiveAfterFailedAccountBoundaryMutation(previousArchive)
            return false
        }
        let changedNames = Array(Set(authoritative.keys).union(corrections))
        archive.pendingLocalRecordNames.formUnion(changedNames)
        guard persistArchive() else {
            _ = restoreArchiveAfterFailedAccountBoundaryMutation(previousArchive)
            return false
        }
        if queuesRemoteChanges {
            queueRecordSaves(changedNames)
        }
        return true
    }

    @discardableResult
    func finalizeMediaStateRemoteAccountBoundary() -> Bool {
        guard !isLocalArchiveUnavailable,
              !hasPendingAccountIsolationJournal,
              !isAccountIsolationInProgress else { return false }
        let names = Array(archive.records.keys)
        archive.pendingLocalRecordNames.formUnion(names)
        guard persistArchive() else { return false }

        if !isPreparedRecoverySyncBlocked {
            queueRecordSaves(names)
#if os(iOS)
            MediaStateRemoteTransportCoordinator.shared.scheduleDeferredSync(
                reason: "account-boundary-resolved"
            )
#endif
        }
        return true
    }

    @discardableResult
    func suspendMediaStateSyncForPreparedRecovery(transactionID: UUID) -> Bool {
        guard MediaStateAccountBoundaryRecoveryGate.authorizesPreparation(
            transactionID: transactionID
        ) else {
            return false
        }
        if isPreparedRecoverySyncSuspended {
            guard preparedRecoverySuspensionTransactionID == transactionID else {
                return false
            }
            return durablyRemovePreparedRecoveryEngineState()
        }
        captureTask?.cancel()
        captureTask = nil
        var capturePersisted = false
        _ = captureAndQueueLocalChanges(
            queueChanges: false,
            forPreparedRecoveryTransaction: true,
            persistenceResult: { capturePersisted = $0 }
        )
        guard capturePersisted else {
            Logger.shared.log(
                "MediaStateSync: failed to capture state before prepared recovery suspension",
                type: "Error"
            )
            return false
        }
        return suspendPreparedRecoverySync(transactionID: transactionID)
    }

    @discardableResult
    func completeMediaStateSyncPreparedRecovery(transactionID: UUID) -> Bool {
        guard preparedRecoverySuspensionMatches(transactionID) else {
            Logger.shared.log(
                "MediaStateSync: refused to release recovery suspension for another transaction",
                type: "Error"
            )
            return false
        }
        guard detachSyncForPreparedRecoveryCleanup(transactionID: transactionID) else {
            return false
        }
        clearPreparedRecoverySyncSuspension()
        return true
    }

    private func suspendPreparedRecoverySync(transactionID: UUID) -> Bool {
        detachSyncForPreparedRecoveryCleanup(transactionID: transactionID)
    }

    private func detachSyncForPreparedRecoveryCleanup(transactionID: UUID?) -> Bool {
        if isPreparedRecoverySyncSuspended {
            if let activeTransactionID = preparedRecoverySuspensionTransactionID,
               let transactionID,
               activeTransactionID != transactionID {
                return false
            }
            return durablyRemovePreparedRecoveryEngineState()
        }

        let staleEngine = engine
        isPreparedRecoverySyncSuspended = true
        preparedRecoverySuspensionTransactionID = transactionID
        accountPreparationGeneration &+= 1
        skyStreamRestoreTask?.cancel()
        skyStreamRestoreTask = nil
        engine = nil
        pendingEngineStateSerialization = nil
        isPreparingEngine = false
        initialFetchCompleted = false
#if os(iOS)
        MediaStateRemoteTransportCoordinator.shared.invalidateActiveSyncPasses()
#endif

        Task {
            await staleEngine?.cancelOperations()
        }

        guard durablyRemovePreparedRecoveryEngineState() else {

            return false
        }
        return true
    }

    private func durablyRemovePreparedRecoveryEngineState() -> Bool {
        durablyRemoveEngineState(
            failureContext: "prepared recovery"
        )
    }

    private func durablyRemoveEngineState(failureContext: String) -> Bool {
        do {
            if FileManager.default.fileExists(atPath: Self.engineStateURL.path) {
                try FileManager.default.removeItem(at: Self.engineStateURL)
            }
            guard !FileManager.default.fileExists(atPath: Self.engineStateURL.path) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return true
        } catch {
            Logger.shared.log(
                "MediaStateSync: failed to durably reset engine state for \(failureContext): \(error.localizedDescription)",
                type: "Error"
            )
            return false
        }
    }

    private func recordAccountIsolationFailure(_ detail: String) {
        let message = "Media state is waiting for account isolation to finish safely."
        phase = .localOnly(message)
        lastErrorMessage = message
        Logger.shared.log(
            "MediaStateSync: account isolation remains blocked (\(detail))",
            type: "Error"
        )
    }

    private func preparedRecoverySuspensionMatches(_ transactionID: UUID) -> Bool {
        guard let activeTransactionID = preparedRecoverySuspensionTransactionID else {
            return true
        }
        return activeTransactionID == transactionID
    }

    private func clearPreparedRecoverySyncSuspension() {
        isPreparedRecoverySyncSuspended = false
        preparedRecoverySuspensionTransactionID = nil
    }

    func prepareRemoteAccountBoundaryArchiveRecovery(transactionID: UUID) -> Bool {
        guard !isLocalArchiveUnavailable,
              !hasPendingAccountIsolationJournal,
              !isAccountIsolationInProgress else {
            Logger.shared.log(
                "MediaStateSync: refused account-boundary recovery preparation while canonical state is unavailable or still isolated",
                type: "Error"
            )
            return false
        }
        guard MediaStateAccountBoundaryRecoveryGate.authorizesPreparation(
            transactionID: transactionID
        ) else {
            Logger.shared.log(
                "MediaStateSync: refused account-boundary preparation without matching durable authority",
                type: "Error"
            )
            return false
        }
        guard preparedRecoverySuspensionMatches(transactionID) else {
            Logger.shared.log(
                "MediaStateSync: refused to prepare recovery over another suspended transaction",
                type: "Error"
            )
            return false
        }
        if FileManager.default.fileExists(atPath: Self.accountBoundaryRecoveryURL.path) {
            guard let existingData = try? Self.boundedLocalData(
                    at: Self.accountBoundaryRecoveryURL,
                    maximumBytes: Self.maximumAccountBoundaryRecoveryBytes
                  ),
                  let existing = Self.decodeAccountBoundaryRecoverySidecar(existingData),
                  existing.transactionID == transactionID else {
                Logger.shared.log(
                    "MediaStateSync: refused to overwrite another account-boundary recovery artifact",
                    type: "Error"
                )
                return false
            }

            return suspendPreparedRecoverySync(transactionID: transactionID)
        }
        do {

            captureTask?.cancel()
            captureTask = nil
            var capturePersisted = false
            _ = captureAndQueueLocalChanges(
                queueChanges: false,
                forPreparedRecoveryTransaction: true,
                persistenceResult: { capturePersisted = $0 }
            )
            guard capturePersisted else {
                Logger.shared.log(
                    "MediaStateSync: failed to capture the account-boundary archive recovery",
                    type: "Error"
                )
                return false
            }
            try Self.ensureStorageDirectory()
            let data = try encoder.encode(
                MediaStateRemoteAccountBoundaryRecoverySidecar(
                    transactionID: transactionID,
                    archive: archive
                )
            )
            guard data.count <= Self.maximumAccountBoundaryRecoveryBytes else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try data.write(
                to: Self.accountBoundaryRecoveryURL,
                options: [.atomic, .completeFileProtection]
            )
            return suspendPreparedRecoverySync(transactionID: transactionID)
        } catch {
            Logger.shared.log(
                "MediaStateSync: failed to persist account-boundary archive recovery: \(error.localizedDescription)",
                type: "Error"
            )
            return false
        }
    }

    @discardableResult
    func restoreRemoteAccountBoundaryArchiveRecovery(transactionID: UUID) -> Bool {
        guard !isLocalArchiveUnavailable,
              !hasPendingAccountIsolationJournal,
              !isAccountIsolationInProgress,
              preparedRecoverySuspensionMatches(transactionID),
              let data = try? Self.boundedLocalData(
                at: Self.accountBoundaryRecoveryURL,
                maximumBytes: Self.maximumAccountBoundaryRecoveryBytes
              ),
              let sidecar = Self.decodeAccountBoundaryRecoverySidecar(data),
              sidecar.transactionID == transactionID,
              sidecar.archive.pendingAccountIsolationProfileIDs.isEmpty,
              sidecar.archive.pendingAccountIsolationTarget == nil else {
            Logger.shared.log(
                "MediaStateSync: account-boundary archive recovery is missing, invalid, or owned by another transaction",
                type: "Error"
            )
            return false
        }
        captureTask?.cancel()
        captureTask = nil
        archive = sidecar.archive
        applyArchiveToManagers(allowsConfirmedEmptyRoster: true)
        archive.lastLocalRecordNames = buildLocalSnapshot().recordNames
        guard persistArchive() else {
            Logger.shared.log(
                "MediaStateSync: restored account-boundary archive could not be persisted",
                type: "Error"
            )
            return false
        }
        return true
    }

    @discardableResult
    func completeRemoteAccountBoundaryArchiveRecovery(transactionID: UUID?) -> Bool {
        if isLocalArchiveUnavailable {
            retryUnavailableLocalArchiveIfPossible()
        }
        guard !isLocalArchiveUnavailable else {
            Logger.shared.log(
                "MediaStateSync: retained account-boundary recovery while canonical state is unavailable",
                type: "Error"
            )
            return false
        }
        if let transactionID,
           !preparedRecoverySuspensionMatches(transactionID) {
            Logger.shared.log(
                "MediaStateSync: refused recovery cleanup for another suspended transaction",
                type: "Error"
            )
            return false
        }
        guard FileManager.default.fileExists(atPath: Self.accountBoundaryRecoveryURL.path) else {

            let hasScopedPreparingAuthority = transactionID.map {
                MediaStateAccountBoundaryRecoveryGate.authorizesPreparation(
                    transactionID: $0
                )
            } ?? false
            guard isPreparedRecoverySyncSuspended || hasScopedPreparingAuthority else {
                return true
            }
            guard detachSyncForPreparedRecoveryCleanup(
                transactionID: transactionID
            ) else {
                return false
            }
            clearPreparedRecoverySyncSuspension()
            return true
        }
        if let transactionID {
            guard let data = try? Self.boundedLocalData(
                    at: Self.accountBoundaryRecoveryURL,
                    maximumBytes: Self.maximumAccountBoundaryRecoveryBytes
                  ),
                  let sidecar = Self.decodeAccountBoundaryRecoverySidecar(data),
                  sidecar.transactionID == transactionID else {
                Logger.shared.log(
                    "MediaStateSync: refused to remove account-boundary recovery owned by another transaction",
                    type: "Error"
                )
                return false
            }
        }
        guard detachSyncForPreparedRecoveryCleanup(
            transactionID: transactionID
        ) else {
            return false
        }
        do {
            try FileManager.default.removeItem(at: Self.accountBoundaryRecoveryURL)
            clearPreparedRecoverySyncSuspension()
            return true
        } catch {
            Logger.shared.log(
                "MediaStateSync: failed to remove account-boundary archive recovery: \(error.localizedDescription)",
                type: "Error"
            )
            return false
        }
    }

    @discardableResult
    private func restoreArchiveAfterFailedAccountBoundaryMutation(
        _ previousArchive: MediaStateLocalArchive
    ) -> Bool {
        archive = previousArchive
        applyArchiveToManagers(allowsConfirmedEmptyRoster: true)
        archive.lastLocalRecordNames = buildLocalSnapshot().recordNames
        let persisted = persistArchive()
        if !persisted {
            Logger.shared.log(
                "MediaStateSync: failed to persist account-boundary archive rollback",
                type: "Error"
            )
        }
        return persisted
    }

    func performConfirmedRemoteAccountBoundaryRestore(
        with remote: [String: MediaStateEnvelope],
        restore: () async -> Set<UUID>?,
        commit: @MainActor (Set<UUID>, Set<UUID>) -> Bool
    ) async -> Bool {
        guard !MediaStatePlaybackLease.isActive,
              !isWholeSnapshotRestoreInProgress else { return false }

        let outgoingProfileIDs = Set(ProfileManager.shared.profiles.map(\.id))
        TrackerManager.shared.beginTentativeAccountBoundaryCredentialPreservation(
            profileIDs: outgoingProfileIDs
        )
        let previousArchive = archive
        guard replaceMediaStateForRemoteAccountBoundary(
            with: remote,
            queuesRemoteChanges: false
        ) else {
            TrackerManager.shared.endTentativeAccountBoundaryCredentialPreservation(
                profileIDs: outgoingProfileIDs
            )
            return false
        }

        isWholeSnapshotRestoreInProgress = true
        defer { isWholeSnapshotRestoreInProgress = false }

        guard replaceLoadedStateWithAccountNeutralState(
            clearsDefaultTrackerCredentials: false,
            schedulesSourceManagerReload: false
        ), await reloadSourceManagersAfterAccountBoundary() else {
            TrackerManager.shared.endTentativeAccountBoundaryCredentialPreservation(
                profileIDs: outgoingProfileIDs
            )
            _ = restoreArchiveAfterFailedAccountBoundaryMutation(previousArchive)
            return false
        }
        applyArchiveToManagers(allowsConfirmedEmptyRoster: true)
        archive.lastLocalRecordNames = buildLocalSnapshot().recordNames

        guard let restoredTrackerProfileIDs = await restore() else {
            TrackerManager.shared.endTentativeAccountBoundaryCredentialPreservation(
                profileIDs: outgoingProfileIDs
            )
            _ = restoreArchiveAfterFailedAccountBoundaryMutation(previousArchive)
            return false
        }

        applyArchiveToManagers(allowsConfirmedEmptyRoster: true)
        archive.lastLocalRecordNames = buildLocalSnapshot().recordNames
        var capturePersisted = false
        _ = captureAndQueueLocalChanges(
            queueChanges: false,
            forPreparedRecoveryTransaction: true,
            persistenceResult: { capturePersisted = $0 }
        )
        guard capturePersisted, persistArchive() else {
            TrackerManager.shared.endTentativeAccountBoundaryCredentialPreservation(
                profileIDs: outgoingProfileIDs
            )
            _ = restoreArchiveAfterFailedAccountBoundaryMutation(previousArchive)
            return false
        }
        guard commit(outgoingProfileIDs, restoredTrackerProfileIDs) else {
            TrackerManager.shared.endTentativeAccountBoundaryCredentialPreservation(
                profileIDs: outgoingProfileIDs
            )
            _ = restoreArchiveAfterFailedAccountBoundaryMutation(previousArchive)
            return false
        }
        TrackerManager.shared.endTentativeAccountBoundaryCredentialPreservation(
            profileIDs: outgoingProfileIDs
        )
        return true
    }

    func performConfirmedRemoteAccountBoundaryWithoutLegacySnapshot(
        with remote: [String: MediaStateEnvelope],
        commit: @MainActor (Set<UUID>) -> Bool
    ) async -> Bool {
        guard !MediaStatePlaybackLease.isActive,
              !isWholeSnapshotRestoreInProgress else { return false }

        let outgoingProfileIDs = Set(ProfileManager.shared.profiles.map(\.id))
        TrackerManager.shared.beginTentativeAccountBoundaryCredentialPreservation(
            profileIDs: outgoingProfileIDs
        )
        let previousArchive = archive
        guard replaceMediaStateForRemoteAccountBoundary(
                with: remote,
                queuesRemoteChanges: false
              ) else {
            TrackerManager.shared.endTentativeAccountBoundaryCredentialPreservation(
                profileIDs: outgoingProfileIDs
            )
            return false
        }

        isWholeSnapshotRestoreInProgress = true
        defer { isWholeSnapshotRestoreInProgress = false }
        guard replaceLoadedStateWithAccountNeutralState(
            clearsDefaultTrackerCredentials: false,
            schedulesSourceManagerReload: false
        ), await reloadSourceManagersAfterAccountBoundary() else {
            TrackerManager.shared.endTentativeAccountBoundaryCredentialPreservation(
                profileIDs: outgoingProfileIDs
            )
            _ = restoreArchiveAfterFailedAccountBoundaryMutation(previousArchive)
            return false
        }
        applyArchiveToManagers(allowsConfirmedEmptyRoster: true)
        archive.lastLocalRecordNames = buildLocalSnapshot().recordNames
        var capturePersisted = false
        _ = captureAndQueueLocalChanges(
            queueChanges: false,
            forPreparedRecoveryTransaction: true,
            persistenceResult: { capturePersisted = $0 }
        )
        guard capturePersisted, persistArchive() else {
            TrackerManager.shared.endTentativeAccountBoundaryCredentialPreservation(
                profileIDs: outgoingProfileIDs
            )
            _ = restoreArchiveAfterFailedAccountBoundaryMutation(previousArchive)
            return false
        }
        guard commit(outgoingProfileIDs) else {
            TrackerManager.shared.endTentativeAccountBoundaryCredentialPreservation(
                profileIDs: outgoingProfileIDs
            )
            _ = restoreArchiveAfterFailedAccountBoundaryMutation(previousArchive)
            return false
        }
        TrackerManager.shared.endTentativeAccountBoundaryCredentialPreservation(
            profileIDs: outgoingProfileIDs
        )
        return true
    }

    @discardableResult
    func applyRemoteTransportMerge(
        from remote: [String: MediaStateEnvelope]
    ) -> MediaStateEnvelopeReconciler.Result? {
        guard !isPreparedRecoverySyncBlocked else {
            Logger.shared.log(
                "MediaStateSync: deferred remote envelope merge during prepared recovery",
                type: "iCloud"
            )
            return nil
        }
        guard !hasPendingAccountIsolationJournal else {
            Logger.shared.log(
                "MediaStateSync: deferred remote envelope merge during pending account isolation",
                type: "iCloud"
            )
            return nil
        }
        guard !isWholeSnapshotRestoreInProgress else {
            Logger.shared.log(
                "MediaStateSync: deferred remote envelope merge during whole-snapshot restore",
                type: "iCloud"
            )
            return nil
        }
        guard !MediaStatePlaybackLease.isActive else {
            Logger.shared.log(
                "MediaStateSync: refused to apply a remote transport merge while playback holds the media-state lease",
                type: "iCloud"
            )
            return nil
        }
        if let reason = MediaStateEnvelopeValidator.aggregateRejectionReason(
            for: remote,
            allowsSystemFields: false
        ) {
            Logger.shared.log(
                "MediaStateSync: refused an oversized remote envelope bundle (\(reason))",
                type: "Error"
            )
            return nil
        }
        let usableRemote = MediaStateEnvelopeValidator.structurallyValidRemoteRecords(remote)
        if !usableRemote.droppedRecordNames.isEmpty {
            Logger.shared.log(
                "MediaStateSync: dropped \(usableRemote.droppedRecordNames.count) invalid record(s) from the remote envelope bundle and kept the remaining \(usableRemote.records.count)",
                type: "Error"
            )
        }
        if let overflow = MediaStateEnvelopeValidator.rosterOverflowDescription(in: usableRemote.records) {
            Logger.shared.log(
                "MediaStateSync: remote envelope bundle carries \(overflow); merged it and left the cap to the roster merge",
                type: "Error"
            )
        }

        flushPendingCapture()

        guard !isAccountIsolationInProgress else {
            Logger.shared.log(
                "MediaStateSync: refused to apply a remote transport merge during account isolation",
                type: "iCloud"
            )
            return nil
        }

        let rebased = MediaStateEnvelopeReconciler.reconcile(
            local: archive.records,
            remote: usableRemote.records
        )
        guard rebased.localDidChange else {

            return rebased
        }

        let archiveBeforeMerge = archive
        archive.records = rebased.merged
        guard applyArchiveToManagers() else {
            archive = archiveBeforeMerge
            hasDeferredRemoteApply = true
            Logger.shared.log(
                "MediaStateSync: restored the pre-merge archive because the merged archive could not be applied",
                type: "Error"
            )
            return nil
        }

        archive.lastLocalRecordNames = buildLocalSnapshot().recordNames
        let correctiveNames = captureAndQueueLocalChanges(queueChanges: false)
        guard persistArchive() else {
            archive = archiveBeforeMerge
            _ = applyArchiveToManagers()
            hasDeferredRemoteApply = true
            Logger.shared.log(
                "MediaStateSync: rolled back a remote transport merge because the canonical archive could not be made durable",
                type: "Error"
            )
            return nil
        }

        queueRecordSaves(Array(Set(rebased.namesChangedLocally).union(correctiveNames)))

        return MediaStateEnvelopeReconciler.reconcile(
            local: archive.records,
            remote: usableRemote.records
        )
    }

    func resetLocalCacheWithoutDeletingRemoteState() {
        guard !isPreparedRecoverySyncBlocked,
              !hasPendingAccountIsolationJournal,
              !isAccountRevalidationInProgress,
              !isAccountIsolationInProgress,
              !hasDeferredDestructiveAccountIsolation else {
            Logger.shared.log(
                "MediaStateSync: refused local cache reset during account isolation or identity revalidation",
                type: "iCloud"
            )
            return
        }
        let preservedAccountOwnerRecordName = archive.accountOwnerRecordName
        let preservedUbiquityIdentityTokenData = archive.ubiquityIdentityTokenData
        let preservedSuppressedPayloadHashes = archive.suppressedLocalRecordPayloadHashes
        let preservedNeutralState = archive.isAccountNeutralLocalStateActive
        let preservedBoundaryPayloadHashes = pendingAccountBoundaryPayloadHashes

        let staleEngine = detachActiveEngineForAccountIsolation()
        let resetGeneration = accountPreparationGeneration
        captureTask?.cancel()
        captureTask = nil
        skyStreamRestoreTask?.cancel()
        skyStreamRestoreTask = nil
        lastAppliedSkyStreamPayloadHashes = [:]
        inFlightSkyStreamPayloadHashes = [:]
        archive = .empty
        archive.accountOwnerRecordName = preservedAccountOwnerRecordName
        archive.ubiquityIdentityTokenData = preservedUbiquityIdentityTokenData
        archive.suppressedLocalRecordPayloadHashes = preservedSuppressedPayloadHashes
        archive.isAccountNeutralLocalStateActive = preservedNeutralState
        pendingAccountBoundaryPayloadHashes = preservedBoundaryPayloadHashes
        initialFetchCompleted = false
        isTrustedOfflineCacheActive = false
        let preservesAccountAuthority = preservedAccountOwnerRecordName != nil
            || preservedNeutralState
            || !preservedSuppressedPayloadHashes.isEmpty
            || !preservedBoundaryPayloadHashes.isEmpty
        initialLocalStatePolicy = preservesAccountAuthority
            ? .isolateIncomingAccount
            : .migrateLocalState
        isAccountIsolationInProgress = preservesAccountAuthority
        archive.hasDeliberateLocalCacheReset = preservesAccountAuthority
        verifiedAccountRecordName = nil
        suppressedDefaultRecordNames = []
        isReversibleAccountIdentityRevalidation = false
        isSignedOutIdentityConfirmed = false
        hasDeferredRemoteApply = false
        hasDeferredDestructiveAccountIsolation = false
        guard persistArchive() else {
            recordAccountIsolationFailure("local cache reset could not be persisted")
            Task { await staleEngine?.cancelOperations() }
            return
        }
        guard durablyRemoveEngineState(failureContext: "local cache reset") else {
            recordAccountIsolationFailure("local cache engine-state reset failed")
            Task { await staleEngine?.cancelOperations() }
            return
        }
        phase = .fetching
        Task { [weak self] in
            await staleEngine?.cancelOperations()
            guard let self,
                  resetGeneration == self.accountPreparationGeneration,
                  !self.isPreparedRecoverySyncBlocked,
                  self.engine == nil else { return }
            await self.prepareEngineAndFetch()
        }
    }

#if os(iOS)

    func performLegacySnapshotRestorePreservingMediaState(
        _ restore: () async -> Bool
    ) async -> Bool {
        guard !isLocalArchiveUnavailable,
              !hasPendingAccountIsolationJournal,
              !isWholeSnapshotRestoreInProgress else { return false }
        isWholeSnapshotRestoreInProgress = true
        defer { isWholeSnapshotRestoreInProgress = false }
        captureTask?.cancel()
        let preservedMediaState = buildLocalSnapshot().records
        let authoritativeCloudRecords = archive.records
        let preservedDeferredApplyHashes = archive.deferredApplyManagerPayloadHashes
        let succeeded = await restore()
        guard succeeded else { return false }

        archive.records = Self.repairedArchiveRecords(preservedMediaState)
        applyArchiveToManagers()
        archive.records = authoritativeCloudRecords
        archive.deferredApplyManagerPayloadHashes = preservedDeferredApplyHashes
        archive.lastLocalRecordNames = buildLocalSnapshot().recordNames
        persistArchive()
        syncNow()
        return true
    }

    var restoreCanPropagateToOtherDevices: Bool {
        guard !isLocalArchiveUnavailable,
              !isPreparedRecoverySyncBlocked,
              !hasPendingAccountIsolationJournal,
              !isAccountIsolationInProgress else { return false }
        guard MediaStateSyncBootstrap.isCloudKitSyncEnabled
                || isRemoteTransportModeActive else { return false }
        guard !MediaStateCloudKitSuspension.isSuspended
                || isRemoteTransportModeActive else { return false }
        return initialFetchCompleted
            || isTrustedOfflineCacheActive
            || isRemoteTransportModeActive
    }

    var canPerformProtectedSnapshotRestore: Bool {
        !isLocalArchiveUnavailable
            && !hasPendingAccountIsolationJournal
            && !isWholeSnapshotRestoreInProgress
    }

    func performAuthoritativeSnapshotRestore(
        _ restore: () async -> Bool
    ) async -> Bool {
        guard !isWholeSnapshotRestoreInProgress else { return false }
        guard !isLocalArchiveUnavailable,
              !hasPendingAccountIsolationJournal else { return await restore() }
        captureTask?.cancel()
        isWholeSnapshotRestoreInProgress = true
        let succeeded = await restore()
        guard succeeded else {
            archive.lastLocalRecordNames = buildLocalSnapshot().recordNames
            persistArchive()
            isWholeSnapshotRestoreInProgress = false
            Logger.shared.log(
                "MediaStateSync: rebased the local record baseline after a failed authoritative restore so a partial restore cannot propagate deletions",
                type: "iCloud"
            )
            return false
        }
        isWholeSnapshotRestoreInProgress = false
        _ = captureAndQueueLocalChanges()
        persistArchive()
        syncNow()
        return true
    }

#endif

    private var canResolveSettingsSyncDirection: Bool {
        !isLocalArchiveUnavailable
            && !isWholeSnapshotRestoreInProgress
            && !hasPendingAccountIsolationJournal
            && !isAccountIsolationInProgress
            && !isPreparedRecoverySyncBlocked
            && !isApplyingRemoteState
    }

    @discardableResult
    func adoptRemoteSettingsAfterEnablingSync() -> Bool {
        guard ProfileManager.shared.activeProfile?.isKidsProfile != true,
              canResolveSettingsSyncDirection else { return false }
        EclipseSettingsSyncPreference.isEnabled = true
        captureTask?.cancel()
        applySettingRecords()
        archive.lastLocalRecordNames = buildLocalSnapshot().recordNames
        persistArchive()
        syncNow()
        return true
    }

    @discardableResult
    func publishLocalSettingsAfterEnablingSync() -> Bool {
        guard ProfileManager.shared.activeProfile?.isKidsProfile != true,
              canResolveSettingsSyncDirection,
              MediaStateLocalCapturePolicy.capturesLocalChanges(
                  initialFetchCompleted: initialFetchCompleted,
                  isTrustedOfflineCacheActive: isTrustedOfflineCacheActive,
                  isRemoteTransportModeActive: isRemoteTransportModeActive
              ) else { return false }
        EclipseSettingsSyncPreference.isEnabled = true
        captureTask?.cancel()
        _ = captureAndQueueLocalChanges()
        persistArchive()
        syncNow()
        return true
    }

    private func prepareEngineAndFetch() async {
        guard !isPreparedRecoverySyncBlocked else { return }
        guard MediaStateSyncBootstrap.isCloudKitSyncEnabled,
              !isDeletingRemoteMediaState else { return }
        guard MediaStateSyncBootstrap.hasCloudKitEntitlement else {
            phase = .localOnly("This build has no iCloud entitlement. Eclipse remains usable with local media state.")
            return
        }
        guard !isPreparingEngine else { return }
        let preparationGeneration = accountPreparationGeneration
        var mayResumeAccountOwnedLocalStateAfterFailure = false
        var zonePreparationFailed = false
        isPreparingEngine = true
        defer {
            if preparationGeneration == accountPreparationGeneration {
                isPreparingEngine = false
            }
        }
        do {
            let accountStatus = try await container.accountStatus()
            guard preparationGeneration == accountPreparationGeneration,
                  !isPreparedRecoverySyncBlocked,
                  MediaStateSyncBootstrap.isCloudKitSyncEnabled,
                  !isDeletingRemoteMediaState else { return }
            guard accountStatus == .available else {
                if accountStatus == .noAccount {
                    guard beginSignedOutIsolation() else { return }
                } else if isReversibleAccountIdentityRevalidation {

                    resumeAccountOwnedLocalStateAfterRevalidationFailure(
                        cancelsCurrentEngine: false
                    )
                }
                let accountStatusMessage = Self.accountStatusMessage(accountStatus)
                phase = .localOnly(accountStatusMessage)
                lastErrorMessage = accountStatusMessage
                if accountStatus == .temporarilyUnavailable
                    || accountStatus == .couldNotDetermine {
                    schedulePreparationRetry()
                }
                return
            }

            let currentUser = try await container.userRecordID()
            guard preparationGeneration == accountPreparationGeneration,
                  !isPreparedRecoverySyncBlocked,
                  MediaStateSyncBootstrap.isCloudKitSyncEnabled,
                  !isDeletingRemoteMediaState else { return }
            let currentAccountRecordName = currentUser.recordName
            let previousAccountRecordName = archive.accountOwnerRecordName
            var serializedEngineState: CKSyncEngine.State.Serialization?

            if let previousAccountRecordName,
               previousAccountRecordName != currentAccountRecordName {
                isReversibleAccountIdentityRevalidation = false
                isSignedOutIdentityConfirmed = false
                MediaStateAccountPlaybackBoundary.notifyWillChangeUser(sender: self)
                captureTask?.cancel()
                initialFetchCompleted = false
                isTrustedOfflineCacheActive = false
                initialLocalStatePolicy = .isolateIncomingAccount
                isAccountIsolationInProgress = true
                guard durablyRemoveEngineState(failureContext: "account switch") else {
                    recordAccountIsolationFailure("engine-state reset failed")
                    return
                }
                guard isolateLoadedStateOrDefer(
                    target: .account(recordName: currentAccountRecordName)
                ) else {
                    recordAccountIsolationFailure("outgoing stores could not be durably quarantined")
                    return
                }
                if hasPendingAccountIsolationJournal {
                    verifiedAccountRecordName = currentAccountRecordName
                    phase = .localOnly(
                        "Media state is waiting for playback to end before changing iCloud accounts."
                    )
                    return
                }
                let pendingIsolationProfileIDs = archive.pendingAccountIsolationProfileIDs
                let pendingIsolationTarget = archive.pendingAccountIsolationTarget
                archive = .empty
                archive.pendingAccountIsolationProfileIDs = pendingIsolationProfileIDs
                archive.pendingAccountIsolationTarget = pendingIsolationTarget
                serializedEngineState = nil
            } else if previousAccountRecordName == nil {

                guard durablyRemoveEngineState(failureContext: "ownerless archive migration") else {
                    recordAccountIsolationFailure("ownerless engine-state reset failed")
                    return
                }
                let hadPendingIsolation = hasPendingAccountIsolationJournal
                let ownerlessSuppressedPayloadHashes =
                    archive.suppressedLocalRecordPayloadHashes
                let ownerlessNeutralState = archive.isAccountNeutralLocalStateActive
                let ownerlessDeliberateReset = archive.hasDeliberateLocalCacheReset
                if hadPendingIsolation {
                    guard archive.pendingAccountIsolationTarget
                        == .account(recordName: currentAccountRecordName) else {
                        recordAccountIsolationFailure(
                            "ownerless account isolation did not match the verified account"
                        )
                        return
                    }
                    guard !MediaStatePlaybackLease.isActive else {
                        initialFetchCompleted = false
                        isTrustedOfflineCacheActive = false
                        initialLocalStatePolicy = .isolateIncomingAccount
                        isAccountIsolationInProgress = true
                        hasDeferredRemoteApply = true
                        hasDeferredDestructiveAccountIsolation = true
                        recordAccountIsolationFailure(
                            "ownerless account isolation is waiting for playback to end"
                        )
                        return
                    }
                    guard completePendingDestructiveAccountIsolation(
                        expectedTarget: .account(recordName: currentAccountRecordName)
                    ) else {
                        recordAccountIsolationFailure(
                            "ownerless account isolation did not match the verified account"
                        )
                        return
                    }
                }
                archive = .empty
                archive.suppressedLocalRecordPayloadHashes =
                    ownerlessSuppressedPayloadHashes
                archive.isAccountNeutralLocalStateActive = ownerlessNeutralState
                archive.hasDeliberateLocalCacheReset = ownerlessDeliberateReset
                let hasOwnerlessQuarantine = hadPendingIsolation
                    || ownerlessDeliberateReset
                    || !ownerlessSuppressedPayloadHashes.isEmpty
                    || !pendingAccountBoundaryPayloadHashes.isEmpty
                initialLocalStatePolicy = hasOwnerlessQuarantine
                    ? .isolateIncomingAccount
                    : .migrateLocalState
                isAccountIsolationInProgress = hasOwnerlessQuarantine
                isReversibleAccountIdentityRevalidation = false
                isSignedOutIdentityConfirmed = false
                hasDeferredRemoteApply = false
                hasDeferredDestructiveAccountIsolation = false
                serializedEngineState = nil
            } else {
                var hadPendingIsolation = hasPendingAccountIsolationJournal
                if hasPendingAccountIsolationJournal,
                   archive.pendingAccountIsolationTarget
                    != .account(recordName: currentAccountRecordName) {
                    guard cancelPendingAccountIsolationReturningToOwner(
                        currentAccountRecordName: currentAccountRecordName
                    ) else {
                        recordAccountIsolationFailure(
                            "pending account isolation did not match the verified account"
                        )
                        return
                    }
                    hadPendingIsolation = false
                }
                if hasPendingAccountIsolationJournal {
                    guard durablyRemoveEngineState(
                        failureContext: "pending same-account isolation"
                    ) else {
                        recordAccountIsolationFailure("pending isolation engine-state reset failed")
                        return
                    }
                    serializedEngineState = nil
                    if !MediaStatePlaybackLease.isActive {
                        guard completePendingDestructiveAccountIsolation(
                            expectedTarget: .account(recordName: currentAccountRecordName)
                        ) else {
                            recordAccountIsolationFailure("deferred outgoing-store quarantine failed")
                            return
                        }
                        hasDeferredDestructiveAccountIsolation = false
                    } else {
                        hasDeferredRemoteApply = true
                        hasDeferredDestructiveAccountIsolation = true
                    }
                }

                let returnsToSameAccountAfterSignOut = archive.isAccountNeutralLocalStateActive
                    && !hadPendingIsolation
                    && !hasDeferredDestructiveAccountIsolation
                    && !archive.hasDeliberateLocalCacheReset
                let revalidatedUnchangedOwnedAccount =
                    MediaStateSameAccountRevalidationPolicy.shouldMigrateLocalState(
                        isRevalidationInProgress: isAccountRevalidationInProgress,
                        hadPendingIsolation: hadPendingIsolation,
                        isAccountNeutralLocalStateActive: archive.isAccountNeutralLocalStateActive,
                        hasDeliberateLocalCacheReset: archive.hasDeliberateLocalCacheReset,
                        previousAccountRecordName: previousAccountRecordName,
                        currentAccountRecordName: currentAccountRecordName
                    )
                if isReversibleAccountIdentityRevalidation
                    || revalidatedUnchangedOwnedAccount {
                    initialLocalStatePolicy = .migrateLocalState
                    isAccountIsolationInProgress = false
                } else if initialLocalStatePolicy != .isolateIncomingAccount
                            || returnsToSameAccountAfterSignOut {
                    initialLocalStatePolicy = MediaStateAccountTransitionPolicy.signInPolicy(
                        lastKnownAccountRecordName: previousAccountRecordName,
                        currentAccountRecordName: currentAccountRecordName,
                        requiresIsolation: false
                    )
                }

                if !hasDeferredDestructiveAccountIsolation,
                   initialLocalStatePolicy != .isolateIncomingAccount {
                    isAccountIsolationInProgress = false
                }
                mayResumeAccountOwnedLocalStateAfterFailure =
                    initialLocalStatePolicy != .isolateIncomingAccount

                if !isAccountRevalidationInProgress {
                    isReversibleAccountIdentityRevalidation = false
                }
                isSignedOutIdentityConfirmed = false
                if !hasPendingAccountIsolationJournal {
                    serializedEngineState = serializedEngineState ?? Self.loadEngineState(
                        expectedAccountOwnerRecordName: currentAccountRecordName
                    )
                }
            }

            archive.accountOwnerRecordName = currentAccountRecordName
            archive.ubiquityIdentityTokenData = Self.currentUbiquityIdentityTokenData()
            verifiedAccountRecordName = currentAccountRecordName
            guard persistArchive() else {
                if mayResumeAccountOwnedLocalStateAfterFailure {
                    resumeAccountOwnedLocalStateAfterRevalidationFailure(
                        cancelsCurrentEngine: false
                    )
                }
                recordAccountIsolationFailure("account ownership could not be persisted")
                return
            }

            if let retryDelay = cloudKitRetryDelayRemaining() {
                let message = "iCloud is temporarily limiting media-state sync. Eclipse will retry later."
                phase = .localOnly(message)
                lastErrorMessage = message
                schedulePreparationRetry(after: retryDelay)
                return
            }

            var configuration = CKSyncEngine.Configuration(
                database: container.privateCloudDatabase,
                stateSerialization: serializedEngineState,
                delegate: self
            )
            configuration.automaticallySync = true
            configuration.subscriptionID = Self.subscriptionID
            let candidateEngine = CKSyncEngine(configuration)
            guard MediaStateCloudKitPreparationAuthorityPolicy.mayInstallEngine(
                preparationGeneration: preparationGeneration,
                currentGeneration: accountPreparationGeneration,
                isSyncEnabled: MediaStateSyncBootstrap.isCloudKitSyncEnabled,
                isRecoveryBlocked: isPreparedRecoverySyncBlocked,
                isDeletingRemoteState: isDeletingRemoteMediaState
            ) else {
                await candidateEngine.cancelOperations()
                return
            }
            self.engine = candidateEngine
            do {
                try await ensureRecordZone(in: candidateEngine.database)
            } catch {
                zonePreparationFailed = true
                throw error
            }
            guard preparationGeneration == accountPreparationGeneration,
                  !isPreparedRecoverySyncBlocked,
                  MediaStateSyncBootstrap.isCloudKitSyncEnabled,
                  !isDeletingRemoteMediaState,
                  self.engine === candidateEngine else {
                await candidateEngine.cancelOperations()
                return
            }
            phase = .fetching
            try await candidateEngine.fetchChanges()
            guard preparationGeneration == accountPreparationGeneration,
                  !isPreparedRecoverySyncBlocked,
                  MediaStateSyncBootstrap.isCloudKitSyncEnabled,
                  !isDeletingRemoteMediaState,
                  self.engine === candidateEngine else { return }
            guard completeInitialFetch() else { return }
            guard preparationGeneration == accountPreparationGeneration,
                  !isPreparedRecoverySyncBlocked,
                  MediaStateSyncBootstrap.isCloudKitSyncEnabled,
                  !isDeletingRemoteMediaState,
                  self.engine === candidateEngine else { return }
            if archive.pendingLocalRecordNames.isEmpty {
                lastSyncDate = Date()
                phase = .ready
                lastErrorMessage = nil
            }
        } catch {
            if preparationGeneration == accountPreparationGeneration,
               !isPreparedRecoverySyncBlocked,
               MediaStateSyncBootstrap.isCloudKitSyncEnabled,
               !isDeletingRemoteMediaState {

                let shouldRetryPreparation = Self.shouldRetryPreparation(after: error)

                if !initialFetchCompleted,
                   isReversibleAccountIdentityRevalidation
                    || mayResumeAccountOwnedLocalStateAfterFailure {
                    resumeAccountOwnedLocalStateAfterRevalidationFailure(
                        cancelsCurrentEngine: engine != nil
                    )
                }
                if engine != nil,
                   zonePreparationFailed || (!initialFetchCompleted && shouldRetryPreparation) {
                    let failedEngine = detachActiveEngineForAccountIsolation()
                    Task { await failedEngine?.cancelOperations() }
                }
                handleSyncError(error)
                if self.engine == nil,
                   shouldRetryPreparation {
                    schedulePreparationRetry(
                        after: cloudKitRetryDelayRemaining() ?? 30
                    )
                }
            }
        }
    }

    private static func shouldRetryPreparation(after error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        switch ckError.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable,
             .requestRateLimited, .zoneBusy, .serverResponseLost,
             .operationCancelled, .accountTemporarilyUnavailable:
            return true
        default:
            return false
        }
    }

    private func schedulePreparationRetry(after requestedDelay: TimeInterval = 30) {
        guard preparationRetryTask == nil,
              engine == nil,
              started,
              MediaStateSyncBootstrap.isCloudKitSyncEnabled,
              !isPreparedRecoverySyncBlocked,
              !isDeletingRemoteMediaState else { return }
        preparationRetryTask = Task { [weak self] in
            let delay = requestedDelay.isFinite
                ? max(1, min(requestedDelay, MediaStateSyncRequestBackoffPolicy.maximumServerDelay))
                : 30
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.preparationRetryTask = nil
            guard self.engine == nil,
                  self.started,
                  MediaStateSyncBootstrap.isCloudKitSyncEnabled,
                  !self.isPreparedRecoverySyncBlocked,
                  !self.isDeletingRemoteMediaState else { return }
            await self.prepareEngineAndFetch()
        }
    }

    private func resumeAccountOwnedLocalStateAfterRevalidationFailure(
        cancelsCurrentEngine: Bool
    ) {
        let staleEngine = cancelsCurrentEngine
            ? detachActiveEngineForAccountIsolation()
            : nil
        initialLocalStatePolicy = .migrateLocalState
        isAccountIsolationInProgress = false
        isReversibleAccountIdentityRevalidation = false
        isTrustedOfflineCacheActive = archive.accountOwnerRecordName != nil
        if isTrustedOfflineCacheActive {

            _ = captureAndQueueLocalChanges(queueChanges: false)
        }
        if let staleEngine {
            Task { await staleEngine.cancelOperations() }
        }
    }

    private func ensureRecordZone(in database: CKDatabase) async throws {
        let zone = CKRecordZone(zoneID: zoneID)
        let result = try await database.modifyRecordZones(saving: [zone], deleting: [])
        if let saveResult = result.saveResults[zoneID], case .failure(let error) = saveResult {
            throw error
        }
    }

    private func launchIdentityEvidence() -> MediaStateLaunchIdentityEvidence {
        guard let archivedData = archive.ubiquityIdentityTokenData else {
            return .unavailable
        }
        guard let currentToken = FileManager.default.ubiquityIdentityToken else {
            return .differentAccountOrSignedOut
        }
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: archivedData) else {
            return .unavailable
        }
        unarchiver.requiresSecureCoding = false
        let archivedObject = unarchiver.decodeObject(
            forKey: NSKeyedArchiveRootObjectKey
        ) as? NSObjectProtocol
        unarchiver.finishDecoding()
        guard let archivedObject else { return .unavailable }
        return archivedObject.isEqual(currentToken)
            ? .sameAccount
            : .differentAccountOrSignedOut
    }

    private static func currentUbiquityIdentityTokenData() -> Data? {
        guard let token = FileManager.default.ubiquityIdentityToken else { return nil }
        return try? NSKeyedArchiver.archivedData(
            withRootObject: token,
            requiringSecureCoding: false
        )
    }

    @discardableResult
    private func beginSignedOutIsolation() -> Bool {
        isReversibleAccountIdentityRevalidation = false
        isSignedOutIdentityConfirmed = true
        if hasPendingAccountIsolationJournal {
            guard archive.pendingAccountIsolationTarget == .signedOut else {
                recordAccountIsolationFailure(
                    "pending account isolation does not authorize signed-out cleanup"
                )
                return false
            }
            initialFetchCompleted = false
            isTrustedOfflineCacheActive = false
            initialLocalStatePolicy = .isolateIncomingAccount
            isAccountIsolationInProgress = true
            hasDeferredRemoteApply = true
            hasDeferredDestructiveAccountIsolation = true
            guard !MediaStatePlaybackLease.isActive else { return true }
            guard completePendingDestructiveAccountIsolation(
                expectedTarget: .signedOut
            ) else {
                recordAccountIsolationFailure("signed-out pending-store cleanup failed")
                return false
            }
            archive.isAccountNeutralLocalStateActive = true
            hasDeferredRemoteApply = false
            hasDeferredDestructiveAccountIsolation = false
            isAccountIsolationInProgress = false
            guard persistArchive() else {
                recordAccountIsolationFailure("signed-out neutral state could not be persisted")
                return false
            }
            return true
        }
        guard archive.accountOwnerRecordName != nil || isTrustedOfflineCacheActive else {
            return true
        }
        if archive.isAccountNeutralLocalStateActive {
            initialFetchCompleted = false
            isTrustedOfflineCacheActive = false
            verifiedAccountRecordName = nil
            return true
        }
        MediaStateAccountPlaybackBoundary.notifyWillChangeUser(sender: self)
        captureTask?.cancel()
        initialFetchCompleted = false
        isTrustedOfflineCacheActive = false
        verifiedAccountRecordName = nil
        initialLocalStatePolicy = .isolateIncomingAccount
        isAccountIsolationInProgress = true
        guard durablyRemoveEngineState(failureContext: "iCloud sign-out") else {
            recordAccountIsolationFailure("signed-out engine-state reset failed")
            return false
        }
        guard isolateLoadedStateOrDefer(target: .signedOut) else {
            recordAccountIsolationFailure("signed-out stores could not be durably quarantined")
            return false
        }
        if !hasPendingAccountIsolationJournal {
            archive.isAccountNeutralLocalStateActive = true
        }
        guard persistArchive() else {
            recordAccountIsolationFailure("signed-out quarantine could not be persisted")
            return false
        }
        if !hasPendingAccountIsolationJournal {
            isAccountIsolationInProgress = false
        }
        return true
    }

    private func beginAccountIdentityRevalidation() {
        guard MediaStateSyncBootstrap.isCloudKitSyncEnabled else { return }
        guard !MediaStateCloudKitSuspension.isSuspended else {
            Logger.shared.log(
                "MediaStateSync: deferred account revalidation until Apple account sync is resumed",
                type: "CloudSync"
            )
            return
        }
        let wasAlreadyRevalidating = isAccountRevalidationInProgress

        accountRevalidationTask?.cancel()
        accountRevalidationTask = nil
        accountRevalidationPassID = nil

        if isPreparedRecoverySyncBlocked {
            let staleEngine = detachActiveEngineForAccountIsolation()
            Task { await staleEngine?.cancelOperations() }
            isAccountRevalidationInProgress = false
            return
        }

        isAccountRevalidationInProgress = true
        if !wasAlreadyRevalidating {
            isReversibleAccountIdentityRevalidation =
                !isAccountIsolationInProgress
                && !hasDeferredDestructiveAccountIsolation
                && !hasPendingAccountIsolationJournal
                && !archive.isAccountNeutralLocalStateActive
                && verifiedAccountRecordName != nil
                && verifiedAccountRecordName == archive.accountOwnerRecordName
                && (initialFetchCompleted || isTrustedOfflineCacheActive)
        }
        isSignedOutIdentityConfirmed = false

        captureTask?.cancel()
        captureTask = nil

        let staleEngine = detachActiveEngineForAccountIsolation()
        MediaStateAccountPlaybackBoundary.notifyWillChangeUser(sender: self)
        if isReversibleAccountIdentityRevalidation {

            _ = captureAndQueueLocalChanges(
                queueChanges: false,
                forAccountIdentityRevalidation: true
            )
        }
        initialFetchCompleted = false
        isTrustedOfflineCacheActive = false
        verifiedAccountRecordName = nil
        initialLocalStatePolicy = .isolateIncomingAccount
        isAccountIsolationInProgress = true
        guard persistArchive() else {
            recordAccountIsolationFailure("account revalidation could not be persisted")
            isAccountRevalidationInProgress = false
            accountRevalidationPassID = nil
            Task { await staleEngine?.cancelOperations() }
            return
        }
        phase = .checkingAccount

        let passID = UUID()
        let passGeneration = accountPreparationGeneration
        accountRevalidationPassID = passID

        Task { await staleEngine?.cancelOperations() }
        accountRevalidationTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled,
                  let self,
                  self.accountRevalidationPassID == passID,
                  self.accountPreparationGeneration == passGeneration else { return }
            await self.prepareEngineAndFetch()
            guard self.accountRevalidationPassID == passID else { return }
            self.isAccountRevalidationInProgress = false
            self.isReversibleAccountIdentityRevalidation = false
            self.accountRevalidationPassID = nil
            self.accountRevalidationTask = nil
            self.finishDeferredRemoteApplyIfPossible()
        }
    }

    var isAccountWorkInProgress: Bool {
        isPreparedRecoverySyncBlocked
            || hasPendingAccountIsolationJournal
            || isAccountRevalidationInProgress
            || isAccountIsolationInProgress
            || hasDeferredDestructiveAccountIsolation
    }

    func deleteAllRemoteMediaState() async throws -> Int {
        guard !isPreparedRecoverySyncBlocked,
              !hasPendingAccountIsolationJournal,
              !isAccountRevalidationInProgress,
              !isAccountIsolationInProgress,
              !hasDeferredDestructiveAccountIsolation else {
            throw MediaStateRemoteDeletionError.accountWorkInProgress
        }
        isDeletingRemoteMediaState = true
        defer { isDeletingRemoteMediaState = false }
        let staleEngine = detachActiveEngineForAccountIsolation()
        await staleEngine?.cancelOperations()
        started = false
        captureTask?.cancel()
        captureTask = nil

        let database = container.privateCloudDatabase
        var removed = 0

        let wasAlreadySuspended = MediaStateCloudKitSuspension.isSuspended
        let archiveBeforeDeletion = archive
        MediaStateCloudKitSuspension.suspend()
        adoptDeletedRemoteMediaState()
        do {
            let zoneChanges = try await database.modifyRecordZones(saving: [], deleting: [zoneID])
            switch zoneChanges.deleteResults[zoneID] {
            case .success:
                removed += 1
            case .failure(let error):
                guard MediaStateCloudKitDeletionPolicy.describesAlreadyAbsentItem(error) else { throw error }
            case nil:
                break
            }
        } catch {
            isDeletingRemoteMediaState = false
            if wasAlreadySuspended {
                Logger.shared.log(
                    "MediaStateSync: a repeat iCloud record zone deletion failed, so this device stayed suspended as the user left it",
                    type: "CloudSync"
                )
            } else {
                archive = archiveBeforeDeletion
                _ = persistArchive()
                MediaStateCloudKitSuspension.resume()
                initialLocalStatePolicy = .migrateLocalState
                _ = durablyRemoveEngineState(failureContext: "unverified cloud data deletion")
                Logger.shared.log(
                    "MediaStateSync: the iCloud record zone deletion could not be confirmed, so this device's media state sync was restarted from a fresh engine state",
                    type: "CloudSync"
                )
            }
            start()
            throw error
        }

        isDeletingRemoteMediaState = false
        start()

        do {
            _ = try await database.deleteSubscription(withID: Self.subscriptionID)
        } catch {
            guard MediaStateCloudKitDeletionPolicy.describesAlreadyAbsentItem(error) else {
                Logger.shared.log(
                    "MediaStateSync: the iCloud record zone was deleted but its change subscription was not: \(error.localizedDescription)",
                    type: "Error"
                )
                return removed
            }
        }

        Logger.shared.log(
            "MediaStateSync: deleted the iCloud record zone and subscription removed=\(removed)",
            type: "CloudSync"
        )
        return removed
    }

    private func adoptDeletedRemoteMediaState() {
        for recordName in archive.records.keys {
            archive.records[recordName]?.systemFields = nil
        }
        archive.pendingLocalRecordNames = Set(archive.records.keys)
        initialLocalStatePolicy = .migrateLocalState
        isTrustedOfflineCacheActive = archive.accountOwnerRecordName != nil
        if !persistArchive() {
            Logger.shared.log(
                "MediaStateSync: could not persist the archive after deleting the iCloud copy",
                type: "Error"
            )
        }
        _ = durablyRemoveEngineState(failureContext: "cloud data deletion")
        lastSyncDate = nil
        lastErrorMessage = nil
        phase = .localOnly("Eclipse deleted its iCloud copy. This device's data is unchanged.")
    }

    private func detachActiveEngineForAccountIsolation() -> CKSyncEngine? {
        let staleEngine = engine
        engine = nil
        explicitSyncTask?.cancel()
        explicitSyncTask = nil
        explicitSyncPassID = nil
        explicitSyncGate.reset()
        pendingEngineStateSerialization = nil
        accountPreparationGeneration &+= 1
        isPreparingEngine = false
        initialFetchCompleted = false
        preparationRetryTask?.cancel()
        preparationRetryTask = nil
        skyStreamRestoreTask?.cancel()
        skyStreamRestoreTask = nil
#if os(iOS)
        MediaStateRemoteTransportCoordinator.shared.invalidateActiveSyncPasses()
#endif
        return staleEngine
    }

    @discardableResult
    private func completeInitialFetch() -> Bool {
        if hasPendingAccountIsolationJournal {
            guard !MediaStatePlaybackLease.isActive,
                  let expectedTarget = confirmedCurrentAccountIsolationTarget,
                  completePendingDestructiveAccountIsolation(
                    expectedTarget: expectedTarget
                  ) else {

                initialFetchCompleted = true
                isTrustedOfflineCacheActive = false
                isAccountIsolationInProgress = true
                initialLocalStatePolicy = .isolateIncomingAccount
                hasDeferredRemoteApply = true
                hasDeferredDestructiveAccountIsolation = true
                _ = persistArchive()
                if !MediaStatePlaybackLease.isActive {
                    recordAccountIsolationFailure(
                        "pending account isolation could not be consumed before initial apply"
                    )
                    let staleEngine = detachActiveEngineForAccountIsolation()
                    _ = durablyRemoveEngineState(
                        failureContext: "unconsumed account-isolation journal"
                    )
                    Task { await staleEngine?.cancelOperations() }
                }
                return false
            }
            hasDeferredDestructiveAccountIsolation = false
            hasDeferredRemoteApply = false
        }

        var fullLocalSnapshot = buildLocalSnapshot().records
        let migrationClock = Date()

        for (recordName, rawCandidate) in Array(fullLocalSnapshot) {
            let candidate = MediaStateEnvelopeValidator.normalizingImplausibleClocks(
                of: rawCandidate,
                now: migrationClock
            )
            if let reason = MediaStateEnvelopeValidator.rejectionReason(
                for: candidate,
                dictionaryKey: recordName,
                allowsSystemFields: true
            ) {
                fullLocalSnapshot.removeValue(forKey: recordName)
                Logger.shared.log(
                    "MediaStateSync: omitted invalid initial-migration record \(recordName) (\(reason))",
                    type: "Error"
                )
            } else {
                fullLocalSnapshot[recordName] = candidate
            }
        }
        let defaultRecordNames = defaultRecordNamesForInitialMigration(in: fullLocalSnapshot)
        let localSnapshot = MediaStateLocalMigrationPolicy.recordsEligibleForMigration(
            localSnapshot: fullLocalSnapshot,
            defaultRecordNames: defaultRecordNames
        )
        let localStatePolicy = initialLocalStatePolicy
        let merge = MediaStateInitialMergePolicy.merge(
            fetchedRecords: archive.records,
            localSnapshot: localSnapshot,
            localStatePolicy: localStatePolicy
        )
        archive.records = merge.records
        if localStatePolicy == .isolateIncomingAccount {
            archive.suppressedLocalRecordPayloadHashes.merge(
                pendingAccountBoundaryPayloadHashes,
                uniquingKeysWith: { _, incoming in incoming }
            )
        } else {
            for (recordName, hash) in pendingAccountBoundaryPayloadHashes
            where archive.suppressedLocalRecordPayloadHashes[recordName] == hash {
                archive.suppressedLocalRecordPayloadHashes.removeValue(forKey: recordName)
            }
        }
        pendingAccountBoundaryPayloadHashes = [:]
        suppressedDefaultRecordNames = defaultRecordNames.subtracting(Set(archive.records.keys))

        let appliedImmediately = applyArchiveToManagersOrDefer()
        if localStatePolicy == .isolateIncomingAccount,
           !MediaStatePlaybackLease.isActive {
            isAccountIsolationInProgress = false
        }
        archive.lastLocalRecordNames = buildLocalSnapshot().recordNames
        archive.isAccountNeutralLocalStateActive = false
        initialFetchCompleted = true
        isTrustedOfflineCacheActive = false
        initialLocalStatePolicy = .migrateLocalState
        archive.hasDeliberateLocalCacheReset = false
        let correctiveNames = appliedImmediately
            ? captureAndQueueLocalChanges(queueChanges: false)
            : []
        guard persistArchive() else {
            recordAccountIsolationFailure(
                "initial fetch could not make the merged archive durable"
            )
            return false
        }
        queueRecordSaves(
            Array(
                Set(merge.pendingRecordNames)
                    .union(archive.pendingLocalRecordNames)
                    .union(correctiveNames)
            )
        )
        return true
    }

    private func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .progressDataDidChange,
            .libraryDataDidChange,
            .userRatingDataDidChange,
            .catalogDataDidChange,
            .skyStreamMetadataDidChange,
            NSManagedObjectContext.didSaveObjectsNotification,
            UserDefaults.didChangeNotification
        ]

        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard UserRatingManager.notificationBelongsToActiveProfile(notification) else {
                    return
                }
                MainActor.assumeIsolated {
                    self?.scheduleLocalCapture()
                }
            })
        }

#if canImport(UIKit)

        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushPendingCapture()
            }
        })
        observers.append(center.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isLocalArchiveUnavailable else { return }
                self.start()
            }
        })
#endif

        for name in [Notification.Name.CKAccountChanged, .NSUbiquityIdentityDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in

                MainActor.assumeIsolated {
                    self?.beginAccountIdentityRevalidation()
                }
            })
        }

        observers.append(center.addObserver(
            forName: .mediaStatePlaybackLeaseDidEnd,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      MediaStatePlaybackLeaseLifecyclePolicy.allowsAutomaticSynchronization(
                        isPlaybackLeaseActive: MediaStatePlaybackLease.isActive
                      ) else { return }
                self.finishDeferredRemoteApplyIfPossible(queueChanges: false)
                if self.hasPlaybackDeferredLocalCapture {
                    self.flushPendingCapture(queueChanges: false)
                }
                guard !self.isPreparedRecoverySyncBlocked,
                      !self.hasPlaybackDeferredLocalCapture else { return }
                if MediaStateSyncBootstrap.isCloudKitSyncEnabled {
                    self.syncNow()
                }
#if os(iOS)
                guard self.isRemoteTransportModeActive,
                      !self.hasPlaybackDeferredLocalCapture else { return }
                MediaStateRemoteTransportCoordinator.shared.resumeAfterPlaybackLease(
                    reason: "playback-lease-released"
                )
#endif
            }
        })
    }

    private func finishDeferredRemoteApplyIfPossible(queueChanges: Bool = true) {
        guard !isPreparedRecoverySyncBlocked,
              !isAccountRevalidationInProgress,
              hasDeferredRemoteApply,
              !MediaStatePlaybackLease.isActive else { return }

        if hasPendingAccountIsolationJournal {
            guard let expectedTarget = confirmedCurrentAccountIsolationTarget else {

                if engine == nil, !isPreparingEngine {
                    Task { [weak self] in await self?.prepareEngineAndFetch() }
                }
                return
            }
            guard completePendingDestructiveAccountIsolation(
                expectedTarget: expectedTarget
            ) else {
                hasDeferredRemoteApply = true
                hasDeferredDestructiveAccountIsolation = true
                recordAccountIsolationFailure(
                    "deferred outgoing stores could not be durably quarantined"
                )
                let staleEngine = detachActiveEngineForAccountIsolation()
                _ = durablyRemoveEngineState(
                    failureContext: "failed deferred account isolation"
                )
                Task { await staleEngine?.cancelOperations() }
                return
            }
            hasDeferredDestructiveAccountIsolation = false
            if case .account(let recordName) = expectedTarget,
               archive.accountOwnerRecordName != recordName {
                archive = .empty
                archive.accountOwnerRecordName = recordName
                archive.ubiquityIdentityTokenData = Self.currentUbiquityIdentityTokenData()
                initialFetchCompleted = false
                isTrustedOfflineCacheActive = false
                initialLocalStatePolicy = .isolateIncomingAccount
                isAccountIsolationInProgress = true
                hasDeferredRemoteApply = false
                guard persistArchive() else {
                    recordAccountIsolationFailure(
                        "incoming account state could not be initialized after deferred isolation"
                    )
                    return
                }
                _ = durablyRemoveEngineState(
                    failureContext: "completed deferred account switch"
                )
                if engine == nil, !isPreparingEngine,
                   MediaStateSyncBootstrap.isCloudKitSyncEnabled {
                    Task { [weak self] in await self?.prepareEngineAndFetch() }
                }
                return
            }
        }

        guard !hasPendingAccountIsolationJournal else { return }

        if initialLocalStatePolicy == .isolateIncomingAccount,
           verifiedAccountRecordName != nil {
            hasDeferredRemoteApply = false
            if initialFetchCompleted {
                guard completeInitialFetch() else {
                    hasDeferredRemoteApply = true
                    return
                }
                lastSyncDate = Date()
                phase = .ready
                lastErrorMessage = nil
            }
            return
        }

        let verifiedOwnerMatchesArchive = verifiedAccountRecordName != nil
            && verifiedAccountRecordName == archive.accountOwnerRecordName
        if MediaStateDeferredApplyPolicy.shouldFlushPendingCapture(
            isSignedOutIdentityConfirmed: isSignedOutIdentityConfirmed,
            verifiedOwnerMatchesArchive: verifiedOwnerMatchesArchive,
            isTrustedOfflineCacheActive: isTrustedOfflineCacheActive,
            hasArchiveOwner: archive.accountOwnerRecordName != nil
        ) {
            flushPendingCapture(queueChanges: queueChanges)
        }

        if isSignedOutIdentityConfirmed {
            archive.isAccountNeutralLocalStateActive = true
        } else if let verifiedAccountRecordName,
                  verifiedAccountRecordName == archive.accountOwnerRecordName {
            guard applyArchiveToManagers() else { return }
            archive.isAccountNeutralLocalStateActive = false
        } else if isTrustedOfflineCacheActive,
                  archive.accountOwnerRecordName != nil {
            guard applyArchiveToManagers() else { return }
        } else {

            return
        }

        hasDeferredRemoteApply = false
        isAccountIsolationInProgress = false
        initialLocalStatePolicy = .migrateLocalState
        archive.lastLocalRecordNames = buildLocalSnapshot().recordNames
        _ = captureAndQueueLocalChanges(queueChanges: queueChanges)
        _ = persistArchive()
    }

    private func scheduleLocalCapture() {
        guard !isPreparedRecoverySyncBlocked,
              !hasPendingAccountIsolationJournal,
              MediaStateLocalCapturePolicy.capturesLocalChanges(
                initialFetchCompleted: initialFetchCompleted,
                isTrustedOfflineCacheActive: isTrustedOfflineCacheActive,
                isRemoteTransportModeActive: isRemoteTransportModeActive
              ),
              !isApplyingRemoteState,
              !isWholeSnapshotRestoreInProgress,
              !isAccountIsolationInProgress else { return }
        guard MediaStatePlaybackLeaseLifecyclePolicy.allowsAutomaticSynchronization(
            isPlaybackLeaseActive: MediaStatePlaybackLease.isActive
        ) else {
            captureTask?.cancel()
            captureTask = nil
            hasPlaybackDeferredLocalCapture = true
            return
        }
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_250_000_000)
            guard !Task.isCancelled, let self else { return }
            guard MediaStatePlaybackLeaseLifecyclePolicy.allowsAutomaticSynchronization(
                    isPlaybackLeaseActive: MediaStatePlaybackLease.isActive
                  ) else {
                self.hasPlaybackDeferredLocalCapture = true
                return
            }
            _ = self.captureAndQueueLocalChanges()
        }
    }

    private func flushPendingCapture(queueChanges: Bool = true) {
        captureTask?.cancel()
        captureTask = nil
        captureAndQueueLocalChanges(queueChanges: queueChanges) { [weak self] persisted in
            if persisted {
                self?.hasPlaybackDeferredLocalCapture = false
            }
        }
    }

    @discardableResult
    private func captureAndQueueLocalChanges(
        queueChanges: Bool = true,
        forPreparedRecoveryTransaction: Bool = false,
        forAccountIdentityRevalidation: Bool = false,
        persistenceResult: ((Bool) -> Void)? = nil
    ) -> [String] {
        guard !isLocalArchiveUnavailable,
              (!isPreparedRecoverySyncBlocked || forPreparedRecoveryTransaction),
              !hasPendingAccountIsolationJournal,
              (MediaStateLocalCapturePolicy.capturesLocalChanges(
                initialFetchCompleted: initialFetchCompleted,
                isTrustedOfflineCacheActive: isTrustedOfflineCacheActive,
                isRemoteTransportModeActive: isRemoteTransportModeActive
              )
                || forPreparedRecoveryTransaction
                || forAccountIdentityRevalidation),
              !isApplyingRemoteState,
              (!isWholeSnapshotRestoreInProgress || forPreparedRecoveryTransaction),
              !isAccountIsolationInProgress else {
            persistenceResult?(false)
            return []
        }
        let now = Date()
        let snapshot = buildLocalSnapshot()
        var current = snapshot.records
        var invalidLocalRecordNames = Set<String>()
        for (recordName, envelope) in Array(current) {

            var validationCandidate = envelope
            validationCandidate.modifiedAt = now
            if let reason = MediaStateEnvelopeValidator.rejectionReason(
                for: validationCandidate,
                dictionaryKey: recordName,
                allowsSystemFields: true
            ) {
                current.removeValue(forKey: recordName)
                invalidLocalRecordNames.insert(recordName)
                Logger.shared.log(
                    "MediaStateSync: omitted invalid local record \(recordName) (\(reason))",
                    type: "Error"
                )
            }
        }
        let currentlyDefaultRecordNames = defaultRecordNamesForInitialMigration(in: current)
        var pendingNames: [String] = []

        for (recordName, candidate) in current {
            if let suppressedHash = archive.suppressedLocalRecordPayloadHashes[recordName] {
                guard Self.payloadSHA256(candidate.payload) != suppressedHash else {
                    continue
                }
                archive.suppressedLocalRecordPayloadHashes.removeValue(forKey: recordName)
            }
            if let deferredApplyHash = archive.deferredApplyManagerPayloadHashes[recordName] {
                guard Self.payloadSHA256(candidate.payload) != deferredApplyHash else {
                    continue
                }
                archive.deferredApplyManagerPayloadHashes.removeValue(forKey: recordName)
            }
            if let existing = archive.records[recordName] {
                if existing.isDeleted,
                   MediaStateLocalMigrationPolicy.shouldSuppressTombstoneResurrection(
                       named: recordName,
                       currentDefaultRecordNames: currentlyDefaultRecordNames
                   ) {
                    continue
                }
                guard existing.payload != candidate.payload ||
                        existing.isDeleted ||
                        existing.isCompleted != candidate.isCompleted ||
                        existing.settingScope != candidate.settingScope else {
                    continue
                }
                var changed = candidate
                changed.modifiedAt = now
                changed.revision = MediaStateEnvelope.nextRevision(after: existing.revision)
                changed.systemFields = existing.systemFields
                let isExplicitReset = progressWasExplicitlyReset(from: existing, to: candidate)
                changed.isExplicitReset = isExplicitReset
                if isExplicitReset {
                    changed.resetAt = now
                } else if candidate.isCompleted {
                    changed.resetAt = nil
                } else {
                    changed.resetAt = (existing.resetAt
                        ?? (existing.isExplicitReset ? existing.modifiedAt : nil))
                        .map { min($0, now) }
                }
                if let reason = MediaStateEnvelopeValidator.rejectionReason(
                    for: changed,
                    dictionaryKey: recordName,
                    allowsSystemFields: true
                ) {
                    Logger.shared.log(
                        "MediaStateSync: omitted invalid captured record \(recordName) (\(reason))",
                        type: "Error"
                    )
                    continue
                }
                archive.records[recordName] = changed
            } else {
                if MediaStateLocalMigrationPolicy.shouldSuppressNewRecord(
                    named: recordName,
                    suppressedDefaultRecordNames: suppressedDefaultRecordNames,
                    currentDefaultRecordNames: currentlyDefaultRecordNames
                ) {
                    continue
                }
                suppressedDefaultRecordNames.remove(recordName)
                var added = candidate
                added.modifiedAt = now
                archive.records[recordName] = added
            }
            pendingNames.append(recordName)
        }

        let removedNames = archive.lastLocalRecordNames
            .subtracting(Set(current.keys))
            .subtracting(snapshot.unreadableRecordNames)
            .subtracting(invalidLocalRecordNames)
        for recordName in removedNames {
            guard let existing = archive.records[recordName] else { continue }
            guard mayTombstoneVanishedRecord(named: recordName, kind: existing.kind) else { continue }
            archive.records[recordName] = existing.tombstone(at: now)
            pendingNames.append(recordName)
        }

        archive.lastLocalRecordNames = Set(current.keys)
            .union(snapshot.unreadableRecordNames)
            .union(invalidLocalRecordNames)
        archive.pendingLocalRecordNames.formUnion(pendingNames)
        let persisted = persistArchive()
        persistenceResult?(persisted)
        guard persisted else { return pendingNames }
        if queueChanges {
            queueRecordSaves(pendingNames)
        }
#if os(iOS)
        if queueChanges, !pendingNames.isEmpty, isRemoteTransportModeActive {
            MediaStateRemoteTransportCoordinator.shared.scheduleDeferredSync(reason: "local-change")
        }
#endif
        return pendingNames
    }

    private func progressWasExplicitlyReset(from existing: MediaStateEnvelope, to candidate: MediaStateEnvelope) -> Bool {
        guard existing.kind == .movieProgress || existing.kind == .episodeProgress else { return false }
        guard !candidate.isCompleted else { return false }

        if existing.kind == .movieProgress,
           let old = try? decoder.decode(MovieProgressEntry.self, from: existing.payload),
           let new = try? decoder.decode(MovieProgressEntry.self, from: candidate.payload) {
            return (old.isWatched || old.currentTime > 0) && new.currentTime == 0 && !new.isWatched
        }
        if existing.kind == .episodeProgress,
           let old = try? decoder.decode(EpisodeProgressEntry.self, from: existing.payload),
           let new = try? decoder.decode(EpisodeProgressEntry.self, from: candidate.payload) {
            return (old.isWatched || old.currentTime > 0) && new.currentTime == 0 && !new.isWatched
        }
        return false
    }

    private func queueRecordSaves(_ names: [String]) {
        guard !isPreparedRecoverySyncBlocked,
              !hasPendingAccountIsolationJournal,
              !isAccountIsolationInProgress else { return }
        let uniqueNames = Set(names)
        guard !uniqueNames.isEmpty else { return }
        archive.pendingLocalRecordNames.formUnion(uniqueNames)
        guard persistArchive() else { return }
        guard MediaStateSyncBootstrap.isCloudKitSyncEnabled,
              let activeEngine = engine else { return }
        stageRecordSaves(uniqueNames, on: activeEngine)
    }

    private func stageRecordSaves(
        _ names: Set<String>,
        on activeEngine: CKSyncEngine
    ) {
        let alreadyPending = Set(
            activeEngine.state.pendingRecordZoneChanges.compactMap {
                change -> String? in
                guard case .saveRecord(let recordID) = change,
                      recordID.zoneID == zoneID else { return nil }
                return recordID.recordName
            }
        )
        let namesToStage = MediaStateCloudKitPendingSavePolicy.namesToStage(
            requested: names,
            alreadyPending: alreadyPending
        )
        let changes = namesToStage.compactMap { name -> CKSyncEngine.PendingRecordZoneChange? in
            guard let envelope = archive.records[name], envelope.payload.count <= Self.maxPayloadBytes else {
                Logger.shared.log("CloudKit media record skipped because its payload is too large name=\(name)", type: "iCloud")
                return nil
            }
            let recordID = CKRecord.ID(recordName: name, zoneID: zoneID)
            return .saveRecord(recordID)
        }
        activeEngine.state.add(pendingRecordZoneChanges: changes)
    }

    private struct LocalSnapshot {
        var records: [String: MediaStateEnvelope] = [:]
        var unreadableRecordNames: Set<String> = []

        var recordNames: Set<String> {
            Set(records.keys).union(unreadableRecordNames)
        }
    }

    private static let progressDomainKinds: Set<MediaStateKind> = [
        .movieProgress, .episodeProgress, .showMetadata, .hiddenUpNext
    ]

    private static let ratingDomainKinds: Set<MediaStateKind> = [.rating]

    private static let libraryDomainKinds: Set<MediaStateKind> = [
        .libraryCollection, .libraryMembership
    ]

    private static let catalogDomainKinds: Set<MediaStateKind> = [.catalogOrder]

    private func recordNames(
        ofKinds kinds: Set<MediaStateKind>,
        ofProfile profileID: UUID,
        in names: Set<String>
    ) -> Set<String> {
        names.filter { name in
            guard let kind = MediaStateRecordName.kind(from: name),
                  kinds.contains(kind) else { return false }
            return MediaStateRecordName.profileID(from: name) == profileID
        }
    }

    private func preserveIfUnreadable(
        _ didCapture: Bool,
        kinds: Set<MediaStateKind>,
        domain: String,
        profileID: UUID,
        into snapshot: inout LocalSnapshot
    ) {
        guard !didCapture else { return }
        let preserved = recordNames(
            ofKinds: kinds,
            ofProfile: profileID,
            in: archive.lastLocalRecordNames
        )
        snapshot.unreadableRecordNames.formUnion(preserved)
        Logger.shared.log(
            "MediaStateSync: refused to snapshot unreadable \(domain) for profile \(profileID); preserving \(preserved.count) record names",
            type: "iCloud"
        )
    }

    private func buildLocalSnapshot() -> LocalSnapshot {
        var snapshot = LocalSnapshot()
        guard let authoritativeProfiles = ProfileManager.shared.profilesForMediaStateSync else {

            let preserved = archive.lastLocalRecordNames.filter { name in
                guard let kind = MediaStateRecordName.kind(from: name) else { return false }
                return kind == .profile || kind.isProfileScoped
            }
            snapshot.unreadableRecordNames.formUnion(preserved)
            addSettingRecords(to: &snapshot.records, profileID: nil)
            Logger.shared.log(
                "MediaStateSync: refused to snapshot an unreadable profile roster; preserving \(preserved.count) profile-owned record names",
                type: "iCloud"
            )
            return snapshot
        }

        addProfileRecords(authoritativeProfiles, to: &snapshot.records)
        for profile in authoritativeProfiles {

            preserveIfUnreadable(
                addLibraryRecords(to: &snapshot.records, profileID: profile.id),
                kinds: Self.libraryDomainKinds,
                domain: "library",
                profileID: profile.id,
                into: &snapshot
            )
            preserveIfUnreadable(
                addProgressRecords(to: &snapshot.records, profileID: profile.id),
                kinds: Self.progressDomainKinds,
                domain: "progress",
                profileID: profile.id,
                into: &snapshot
            )
            preserveIfUnreadable(
                addRatingRecords(to: &snapshot.records, profileID: profile.id),
                kinds: Self.ratingDomainKinds,
                domain: "ratings",
                profileID: profile.id,
                into: &snapshot
            )
            preserveIfUnreadable(
                addCatalogRecord(to: &snapshot.records, profileID: profile.id),
                kinds: Self.catalogDomainKinds,
                domain: "catalog ordering",
                profileID: profile.id,
                into: &snapshot
            )
            if !ProfileSettingsStore.sharesServices
                || profile.id == ProfileManager.defaultProfileID {
                let capturedSources = addServiceSourcesRecord(
                    to: &snapshot.records,
                    profileID: profile.id
                )
                if !capturedSources {
                    let name = MediaStateRecordName.make(
                        kind: .setting,
                        identifier: MediaStateServiceSourcesPayload.settingKey,
                        profileID: profile.id
                    )
                    if archive.lastLocalRecordNames.contains(name) {
                        snapshot.unreadableRecordNames.insert(name)
                    }
                    Logger.shared.log(
                        "MediaStateSync: refused to snapshot unreadable service sources for profile \(profile.id)",
                        type: "iCloud"
                    )
                }
            }
            addSettingRecords(to: &snapshot.records, profileID: profile.id)
        }

        for profileID in MediaStateSkyStreamScopePolicy.profileIDs(
            from: authoritativeProfiles.map(\.id),
            sharesServices: ProfileSettingsStore.sharesServices
        ) {
            guard !addSkyStreamMetadataRecord(
                to: &snapshot.records,
                profileID: profileID
            ) else { continue }
            let recordName = MediaStateSkyStreamScopePolicy.recordName(for: profileID)
            if archive.lastLocalRecordNames.contains(recordName) {
                snapshot.unreadableRecordNames.insert(recordName)
            }
            Logger.shared.log(
                "MediaStateSync: refused to snapshot unreadable SkyStream metadata for profile \(profileID)",
                type: "iCloud"
            )
        }
        addSettingRecords(to: &snapshot.records, profileID: nil)
        return snapshot
    }

    private func mayTombstoneVanishedRecord(named recordName: String, kind: MediaStateKind) -> Bool {
        let owner: UUID?
        switch kind {
        case .profile:
            owner = MediaStateRecordName.identifier(from: recordName).flatMap(UUID.init(uuidString:))
        case _ where kind.isProfileScoped:
            owner = MediaStateRecordName.profileID(from: recordName)
        default:
            return true
        }
        guard let owner else { return true }
        guard ProfileManager.shared.profiles.contains(where: { $0.id == owner }) else {
            return ProfileManager.shared.wasDeletedLocally(owner)
        }
        if kind == .setting {
            if MediaStateRecordName.identifier(from: recordName)
                == MediaStateServiceSourcesPayload.settingKey {
                return true
            }
            guard EclipseSettingsSyncPreference.isEnabled,
                  let key = MediaStateRecordName.identifier(from: recordName),
                  MediaStateSettingRegistry.scope(for: key)?.appliesToCurrentPlatform == true else {
                return false
            }
            if EclipseSettingsRegistry.scope(for: key) == .services,
               !MediaStateServicesSettingSyncPolicy.participatesInGlobalSync(
                   sharesServices: ProfileSettingsStore.sharesServices
               ) {
                return false
            }
        }
        return true
    }

    private func defaultRecordNamesForInitialMigration(
        in snapshot: [String: MediaStateEnvelope]
    ) -> Set<String> {
        var result: Set<String> = []

        for profile in ProfileManager.shared.profiles {

            let collections = LibraryManager.shared.collections(forProfile: profile.id) ?? []
            if let bookmarksIndex = collections.firstIndex(where: {
                $0.name.caseInsensitiveCompare("Bookmarks") == .orderedSame
            }) {
                let bookmarks = collections[bookmarksIndex]
                let isPristineDefault = bookmarksIndex == 0 &&
                    bookmarks.items.isEmpty &&
                    bookmarks.description == "Your bookmarked items"
                if isPristineDefault {
                    let name = MediaStateRecordName.make(
                        kind: .libraryCollection,
                        identifier: "bookmarks",
                        profileID: profile.id
                    )
                    if snapshot[name] != nil {
                        result.insert(name)
                    }
                }
            }

            if !CatalogManager.shared.hasMeaningfulCustomization(forProfile: profile.id) {
                let name = MediaStateRecordName.make(
                    kind: .catalogOrder,
                    identifier: "home",
                    profileID: profile.id
                )
                if snapshot[name] != nil {
                    result.insert(name)
                }
            }
        }

        let persistentSettingKeys: Set<String>
        if let bundleIdentifier = Bundle.main.bundleIdentifier,
           let persistentDomain = UserDefaults.standard.persistentDomain(forName: bundleIdentifier) {
            persistentSettingKeys = Set(persistentDomain.keys)
        } else {

            persistentSettingKeys = []
        }

        for key in MediaStateSettingRegistry.allKeys {
            guard key != MediaStateServiceSourcesPayload.settingKey else { continue }
            let storageScope = EclipseSettingsRegistry.scope(for: key)
            guard storageScope == .profile else {
                if storageScope == .services,
                   !MediaStateServicesSettingSyncPolicy.participatesInGlobalSync(
                       sharesServices: ProfileSettingsStore.sharesServices
                   ) {
                    continue
                }
                let hasExplicitValue = persistentSettingKeys.contains(key)
                guard !hasExplicitValue else { continue }
                let name = MediaStateRecordName.make(kind: .setting, identifier: key)
                if snapshot[name] != nil { result.insert(name) }
                continue
            }
            for profile in ProfileManager.shared.profiles {
                let hasExplicitValue = profile.id == ProfileManager.defaultProfileID
                    ? persistentSettingKeys.contains(key)
                    : ProfileSettingsStore.shared.hasExplicitValue(forKey: key, profile: profile.id)
                guard !hasExplicitValue else { continue }
                let name = MediaStateRecordName.make(
                    kind: .setting,
                    identifier: key,
                    profileID: profile.id
                )
                if snapshot[name] != nil { result.insert(name) }
            }
        }

        return result
    }

    private struct LibraryCollectionPayload: Codable {
        let id: UUID
        let key: String
        let name: String
        let description: String?
        let order: Int
    }

    private struct LibraryMembershipPayload: Codable {
        let collectionKey: String
        let item: LibraryItem

        let order: Int?

        init(collectionKey: String, item: LibraryItem, order: Int? = nil) {
            self.collectionKey = collectionKey
            self.item = item
            self.order = order
        }
    }

    private struct DecodedLibraryMembership {
        let envelope: MediaStateEnvelope
        let payload: LibraryMembershipPayload
    }

    private struct RatingPayload: Codable {
        let tmdbID: Int
        let rating: Double?
        let note: String?
    }

    private struct BooleanPayload: Codable {
        let value: Bool
    }

    private func addProfileRecords(
        _ profiles: [Profile],
        to result: inout [String: MediaStateEnvelope]
    ) {
        for profile in profiles {
            guard let data = MediaStateEnvelope.stableProfileData(profile) else { continue }
            guard data.count <= Self.maxPayloadBytes else {
                Logger.shared.log(
                    "MediaStateSync: profile record skipped because its payload is too large id=\(profile.id)",
                    type: "iCloud"
                )
                continue
            }
            let name = MediaStateRecordName.make(
                kind: .profile,
                identifier: profile.id.uuidString.lowercased()
            )
            result[name] = MediaStateEnvelope(
                recordName: name,
                kind: .profile,
                payload: data,
                modifiedAt: .distantPast
            )
        }
    }

    @discardableResult
    private func addLibraryRecords(to result: inout [String: MediaStateEnvelope], profileID: UUID) -> Bool {
        guard let storedCollections = LibraryManager.shared.collections(forProfile: profileID) else {
            return false
        }
        var capturedEveryItem = true
        for (order, collection) in storedCollections.enumerated() {
            let collectionKey = mediaCollectionKey(collection)
            let payload = LibraryCollectionPayload(
                id: collection.id,
                key: collectionKey,
                name: collection.name,
                description: collection.description,
                order: order
            )
            guard let data = try? encoder.encode(payload) else {
                capturedEveryItem = false
                continue
            }
            let name = MediaStateRecordName.make(
                kind: .libraryCollection,
                identifier: collectionKey,
                profileID: profileID
            )
            result[name] = MediaStateEnvelope(
                recordName: name,
                kind: .libraryCollection,
                payload: data,
                modifiedAt: collection.items.map(\.dateAdded).max() ?? .distantPast
            )

            for (itemOrder, item) in collection.items.enumerated() {
                guard let sanitizedResult = item.searchResult.sanitizedForPersistence else {
                    capturedEveryItem = false
                    continue
                }
                let sanitizedItem = LibraryItem(
                    searchResult: sanitizedResult,
                    dateAdded: item.dateAdded
                )
                let membership = LibraryMembershipPayload(
                    collectionKey: collectionKey,
                    item: sanitizedItem,
                    order: itemOrder
                )
                guard let itemData = try? encoder.encode(membership) else {
                    capturedEveryItem = false
                    continue
                }
                let itemName = MediaStateRecordName.make(
                    kind: .libraryMembership,

                    identifier: "\(collectionKey):\(sanitizedResult.stableIdentity)",
                    profileID: profileID
                )
                result[itemName] = MediaStateEnvelope(
                    recordName: itemName,
                    kind: .libraryMembership,
                    payload: itemData,
                    modifiedAt: item.dateAdded
                )
            }
        }
        return capturedEveryItem
    }

    @discardableResult
    private func addProgressRecords(to result: inout [String: MediaStateEnvelope], profileID: UUID) -> Bool {
        guard let progress = ProgressManager.shared.progressData(forProfile: profileID) else {
            return false
        }
        for movie in progress.movieProgress {
            var sanitizedMovie = movie
            sanitizedMovie.lastHref = nil
            sanitizedMovie.lastContentReference = nil
            guard let data = try? encoder.encode(sanitizedMovie) else { continue }
            let name = MediaStateRecordName.make(
                kind: .movieProgress,
                identifier: String(sanitizedMovie.id),
                profileID: profileID
            )
            result[name] = MediaStateEnvelope(
                recordName: name,
                kind: .movieProgress,
                payload: data,
                modifiedAt: sanitizedMovie.lastUpdated,
                isCompleted: sanitizedMovie.isWatched || sanitizedMovie.progress >= 0.85
            )
        }
        for episode in progress.episodeProgress {
            var sanitizedEpisode = episode
            sanitizedEpisode.lastHref = nil
            sanitizedEpisode.lastContentReference = nil
            guard let data = try? encoder.encode(sanitizedEpisode) else { continue }
            let name = MediaStateRecordName.make(
                kind: .episodeProgress,
                identifier: sanitizedEpisode.id,
                profileID: profileID
            )
            result[name] = MediaStateEnvelope(
                recordName: name,
                kind: .episodeProgress,
                payload: data,
                modifiedAt: sanitizedEpisode.lastUpdated,
                isCompleted: sanitizedEpisode.isWatched || sanitizedEpisode.progress >= 0.85
            )
        }
        for (showID, metadata) in progress.showMetadata {
            guard let data = try? encoder.encode(metadata) else { continue }
            let name = MediaStateRecordName.make(
                kind: .showMetadata,
                identifier: String(showID),
                profileID: profileID
            )
            result[name] = MediaStateEnvelope(
                recordName: name,
                kind: .showMetadata,
                payload: data,
                modifiedAt: .distantPast
            )
        }
        for showID in progress.hiddenUpNextShowIds {
            guard let data = try? encoder.encode(BooleanPayload(value: true)) else { continue }
            let name = MediaStateRecordName.make(
                kind: .hiddenUpNext,
                identifier: String(showID),
                profileID: profileID
            )
            result[name] = MediaStateEnvelope(
                recordName: name,
                kind: .hiddenUpNext,
                payload: data,
                modifiedAt: .distantPast
            )
        }
        return true
    }

    @discardableResult
    private func addRatingRecords(to result: inout [String: MediaStateEnvelope], profileID: UUID) -> Bool {
        guard let store = UserRatingManager.shared.ratingsAndNotes(forProfile: profileID) else {
            return false
        }
        let ratings = store.ratings
        let notes = store.notes
        let identifiers = Set(ratings.keys).union(notes.keys)
        for identifier in identifiers {
            guard let tmdbID = Int(identifier) else { continue }
            let payload = RatingPayload(tmdbID: tmdbID, rating: ratings[identifier], note: notes[identifier])
            guard let data = try? encoder.encode(payload) else { continue }
            let name = MediaStateRecordName.make(kind: .rating, identifier: identifier, profileID: profileID)
            result[name] = MediaStateEnvelope(
                recordName: name,
                kind: .rating,
                payload: data,
                modifiedAt: .distantPast
            )
        }
        return true
    }

    private func addSettingRecords(
        to result: inout [String: MediaStateEnvelope],
        profileID: UUID?
    ) {
        guard EclipseSettingsSyncPreference.isEnabled else { return }
        for key in MediaStateSettingRegistry.allKeys.sorted() {
            guard key != MediaStateServiceSourcesPayload.settingKey else { continue }
            guard let platformScope = MediaStateSettingRegistry.scope(for: key),
                  platformScope.appliesToCurrentPlatform else {
                continue
            }
            let storageScope = EclipseSettingsRegistry.scope(for: key)
            let defaults: UserDefaults
            switch (storageScope, profileID) {
            case (.profile, let owner?):
                defaults = ProfileSettingsStore.shared.store(for: owner)
            case (.profile, nil):

                continue
            case (_, .some):

                continue
            case (.services, nil):
                guard MediaStateServicesSettingSyncPolicy.participatesInGlobalSync(
                    sharesServices: ProfileSettingsStore.sharesServices
                ) else {
                    continue
                }
                defaults = ProfileSettingsStore.shared.store(for: ProfileManager.defaultProfileID)
            case (.device, nil):
                defaults = ProfileSettingsStore.device
            }
            guard let value = defaults.object(forKey: key),
                  let data = propertyListData(
                    for: MediaStateSettingValueValidator.capturableLocalValue(value, forKey: key)
                  ) else {
                continue
            }

            let name = MediaStateRecordName.make(
                kind: .setting,
                identifier: key,
                profileID: storageScope == .profile ? profileID : nil
            )
            result[name] = MediaStateEnvelope(
                recordName: name,
                kind: .setting,
                payload: data,
                modifiedAt: .distantPast,
                settingScope: platformScope
            )
        }
    }

    @discardableResult
    private func addServiceSourcesRecord(
        to result: inout [String: MediaStateEnvelope],
        profileID: UUID
    ) -> Bool {
        guard let captured = capturedServiceSources(forProfile: profileID) else { return false }
        guard var payload = MediaStateServiceSourcesPayload.captured(
            services: captured.services,
            stremioAddons: captured.addons,
            nuvioPluginsData: captured.nuvioPluginsData
        ) else { return false }
        let name = MediaStateRecordName.make(
            kind: .setting,
            identifier: MediaStateServiceSourcesPayload.settingKey,
            profileID: profileID
        )
        if payload.nuvioPluginsData == nil,
           let existing = archive.records[name], !existing.isDeleted,
           let existingData = MediaStateSettingValueValidator.validatedValue(
               from: existing.payload,
               forKey: MediaStateServiceSourcesPayload.settingKey
           ) as? Data,
           let existingPayload = try? decoder.decode(
               MediaStateServiceSourcesPayload.self,
               from: existingData
           ) {
            payload.nuvioPluginsData = existingPayload.nuvioPluginsData
        }
        guard let canonical = MediaStateServiceSourcesPayload.canonicalData(payload),
              let data = propertyListData(for: canonical),
              data.count <= MediaStateEnvelope.maximumPayloadBytes else {
            return false
        }
        result[name] = MediaStateEnvelope(
            recordName: name,
            kind: .setting,
            payload: data,
            modifiedAt: .distantPast,
            settingScope: .shared
        )
        return true
    }

    private struct CapturedServiceSources {
        let services: [MediaStateServiceSource]
        let addons: [MediaStateStremioAddon]
        let nuvioPluginsData: Data?
    }

    private func capturedServiceSources(forProfile profileID: UUID) -> CapturedServiceSources? {
        if !FileManager.default.fileExists(atPath: ServiceStoreScope.storeURL(for: profileID).path) {
            return CapturedServiceSources(
                services: [],
                addons: [],
                nuvioPluginsData: capturedNuvioMetadata(forProfile: profileID)
            )
        }
        typealias Captured = ([MediaStateServiceSource], [MediaStateStremioAddon])
        guard let captured = ServiceStoreScope.withReadOnlyStore(
            forProfile: profileID,
            { context -> Result<Captured, Error> in
                Result {
                    let serviceRequest = NSFetchRequest<NSManagedObject>(entityName: "ServiceEntity")
                    var serviceRowsWereComplete = true
                    let serviceEntities = try context.fetch(serviceRequest)
                    let services = serviceEntities.compactMap {
                        entity -> MediaStateServiceSource? in
                        guard let id = entity.value(forKey: "id") as? UUID else {
                            serviceRowsWereComplete = false
                            return nil
                        }
                        return MediaStateServiceSource(
                            id: id,
                            url: entity.value(forKey: "url") as? String ?? "",
                            jsonMetadata: entity.value(forKey: "jsonMetadata") as? String ?? "",
                            jsScript: entity.value(forKey: "jsScript") as? String ?? "",
                            isActive: entity.value(forKey: "isActive") as? Bool ?? true,
                            sortIndex: entity.value(forKey: "sortIndex") as? Int64 ?? 0
                        )
                    }

                    let addonRequest = NSFetchRequest<NSManagedObject>(entityName: "StremioAddonEntity")
                    var addonRowsWereComplete = true
                    let addonEntities = try context.fetch(addonRequest)
                    let addons = addonEntities.compactMap {
                        entity -> MediaStateStremioAddon? in
                        guard let id = entity.value(forKey: "id") as? UUID else {
                            addonRowsWereComplete = false
                            return nil
                        }
                        let persistedURL = entity.value(forKey: "configuredURL") as? String ?? ""
                        return MediaStateStremioAddon(
                            id: id,
                            configuredURL: StremioConfiguredURLVault.resolve(
                                addonID: id,
                                persistedURL: persistedURL,
                                profileID: profileID
                            ),
                            manifestJSON: entity.value(forKey: "manifestJSON") as? String ?? "",
                            isActive: entity.value(forKey: "isActive") as? Bool ?? true,
                            sortIndex: entity.value(forKey: "sortIndex") as? Int64 ?? 0
                        )
                    }
                    guard serviceRowsWereComplete,
                          addonRowsWereComplete,
                          services.count == serviceEntities.count,
                          addons.count == addonEntities.count else {
                        throw CocoaError(.coderInvalidValue)
                    }
                    return (services, addons)
                }
            }
        ), case .success(let values) = captured else {
            return nil
        }

        return CapturedServiceSources(
            services: values.0,
            addons: values.1,
            nuvioPluginsData: capturedNuvioMetadata(forProfile: profileID)
        )
    }

    private func capturedNuvioMetadata(forProfile profileID: UUID) -> Data? {
#if os(iOS) && !targetEnvironment(macCatalyst)
        let settingsStore = ProfileSettingsStore.sharesServices
            ? UserDefaults.standard
            : ProfileSettingsStore.shared.store(for: profileID)
        return BackupData.nuvioMetadataForMediaState(
            persistedValue: settingsStore.object(forKey: "nuvioPluginsState.v2")
        )
#else
        return nil
#endif
    }

    @discardableResult
    private func addCatalogRecord(to result: inout [String: MediaStateEnvelope], profileID: UUID) -> Bool {
        guard let catalogs = CatalogManager.shared.catalogsForMediaStateSync(forProfile: profileID),
              let data = try? encoder.encode(catalogs) else { return false }
        let name = MediaStateRecordName.make(kind: .catalogOrder, identifier: "home", profileID: profileID)
        result[name] = MediaStateEnvelope(
            recordName: name,
            kind: .catalogOrder,
            payload: data,
            modifiedAt: .distantPast
        )
        return true
    }

    @discardableResult
    private func addSkyStreamMetadataRecord(
        to result: inout [String: MediaStateEnvelope],
        profileID: UUID
    ) -> Bool {
        let recordName = MediaStateSkyStreamScopePolicy.recordName(for: profileID)
        if let data = localSkyStreamMetadataPayload(forProfile: profileID) {
            result[recordName] = MediaStateEnvelope(
                recordName: recordName,
                kind: .skyStreamMetadata,
                payload: data,
                modifiedAt: .distantPast
            )
            return true
        }

        if let existing = archive.records[recordName],
           !existing.isDeleted,
           let snapshot = try? SkyStreamMediaStateDocument.decodeMetadataOnly(existing.payload),
           let canonical = try? SkyStreamMediaStateDocument.encodeMetadataOnly(snapshot) {
            var retained = existing
            retained.payload = canonical
            result[recordName] = retained
            return true
        }
        return false
    }

    private func localSkyStreamMetadataPayload(forProfile profileID: UUID) -> Data? {
        let settings = ProfileSettingsStore.sharesServices
            ? UserDefaults.standard
            : ProfileSettingsStore.shared.store(for: profileID)
        if let pendingValue = settings.object(
            forKey: SkyStreamPluginManager.pendingSafeCloudSnapshotKey
        ) {
            guard let pendingData = pendingValue as? Data,
                  pendingData.count <= 50_000_000 else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let pending = try? decoder.decode(
                SkyStreamBackupSnapshot.self,
                from: pendingData
            ) else { return nil }
            return canonicalSkyStreamMetadataPayload(pending)
        }
#if os(iOS) && !targetEnvironment(macCatalyst)
        guard PlatformCapabilities.current.supportsSkyStreamPlugins else { return nil }
        let targetStoreURL = ServiceStoreScope.storeURL(for: profileID).standardizedFileURL
        if targetStoreURL == ServiceStoreScope.activeStoreURL.standardizedFileURL {
            let manager = SkyStreamPluginManager.shared
            guard manager.isLoaded,
                  let snapshot = manager.completePrivateCloudMetadataSnapshot() else {
                return nil
            }
            return canonicalSkyStreamMetadataPayload(snapshot)
        }

        guard FileManager.default.fileExists(atPath: targetStoreURL.path) else {
            return canonicalSkyStreamMetadataPayload(emptySkyStreamMetadataSnapshot())
        }
        let captured = ServiceStoreScope.withReadOnlyStore(
            forProfile: profileID
        ) { context -> Result<Data?, Error> in
            Result {
                let request = NSFetchRequest<NSManagedObject>(
                    entityName: "SkyStreamStateEntity"
                )
                request.predicate = NSPredicate(
                    format: "id == %@",
                    SkyStreamStateEntity.singletonID
                )
                request.fetchLimit = 1
                guard let entity = try context.fetch(request).first else { return nil }
                guard let json = entity.value(forKey: "jsonState") as? String,
                      let data = json.data(using: .utf8),
                      data.count <= 8 * 1_024 * 1_024 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return data
            }
        }
        guard case .success(let persistedData)? = captured else { return nil }
        guard let persistedData else {
            return canonicalSkyStreamMetadataPayload(emptySkyStreamMetadataSnapshot())
        }
        guard let snapshot = SkyStreamPluginManager
            .completePrivateCloudMetadataSnapshot(fromPersistedStateData: persistedData) else {
            return nil
        }
        return canonicalSkyStreamMetadataPayload(snapshot)
#else
        guard profileID == ProfileManager.defaultProfileID else { return nil }
        guard let data = SkyStreamPluginManager.shared.opaqueMediaStateSnapshotData(),
              let snapshot = try? SkyStreamMediaStateDocument.decodeMetadataOnly(data) else {
            return nil
        }
        return canonicalSkyStreamMetadataPayload(snapshot)
#endif
    }

    private func canonicalSkyStreamMetadataPayload(
        _ snapshot: SkyStreamBackupSnapshot
    ) -> Data? {
#if os(iOS)
        guard let safeSnapshot = BackupData.skyStreamSnapshotForExperimentalCloudSync(
            snapshot
        ) else { return nil }
#else
        let safeSnapshot = snapshot
#endif
        do {
            let canonical = try SkyStreamMediaStateDocument.encodeMetadataOnly(safeSnapshot)
            lastSkyStreamMetadataEncodingFailure = nil
            return canonical
        } catch {
            logSkyStreamMetadataEncodingFailureOnce(error)
            return nil
        }
    }

    private func emptySkyStreamMetadataSnapshot() -> SkyStreamBackupSnapshot {
        SkyStreamBackupSnapshot(
            repositories: [],
            plugins: [],
            createdAt: Date(timeIntervalSince1970: 0),
            isSafeCloudSnapshot: true,
            privateCloudConfigurationIsComplete: true
        )
    }

    private func logSkyStreamMetadataEncodingFailureOnce(_ error: Error) {
        let failure = String(reflecting: error)
        guard failure != lastSkyStreamMetadataEncodingFailure else { return }
        lastSkyStreamMetadataEncodingFailure = failure
        Logger.shared.log(
            "SkyStream CloudKit metadata capture omitted; prior account record retained error=\(failure)",
            type: "iCloud"
        )
    }

    @discardableResult
    private func applyArchiveToManagersOrDefer() -> Bool {
        guard !isLocalArchiveUnavailable else { return false }
        guard !hasPendingAccountIsolationJournal else {
            hasDeferredRemoteApply = true
            hasDeferredDestructiveAccountIsolation = true
            return false
        }
        if MediaStatePlaybackLease.isActive {
            markManagerValuesAwaitingDeferredApply()
            hasDeferredRemoteApply = true
            return false
        } else {
            let applied = applyArchiveToManagers()
            hasDeferredRemoteApply = !applied
            return applied
        }
    }

    static func mergedArchiveValueMovedOffManagerValue(
        merged: MediaStateEnvelope,
        managerValue: MediaStateEnvelope
    ) -> Bool {
        merged.payload != managerValue.payload
            || merged.isDeleted
            || merged.isCompleted != managerValue.isCompleted
            || merged.settingScope != managerValue.settingScope
    }

    private func markManagerValuesAwaitingDeferredApply() {
        let managerValues = buildLocalSnapshot().records
        var additions: [String: String] = [:]
        for (recordName, managerValue) in managerValues {
            guard archive.deferredApplyManagerPayloadHashes[recordName] == nil,
                  let merged = archive.records[recordName],
                  Self.mergedArchiveValueMovedOffManagerValue(
                    merged: merged,
                    managerValue: managerValue
                  ) else { continue }
            additions[recordName] = Self.payloadSHA256(managerValue.payload)
        }
        guard !additions.isEmpty else { return }
        guard archive.deferredApplyManagerPayloadHashes.count + additions.count
                <= MediaStateLocalArchive.maximumDeferredApplyManagerPayloadHashes else {
            Logger.shared.log(
                "MediaStateSync: refused to mark \(additions.count) playback-deferred records; the deferral map would exceed its ceiling",
                type: "Error"
            )
            return
        }
        archive.deferredApplyManagerPayloadHashes.merge(additions) { existing, _ in existing }
        _ = persistArchive()
    }

    @discardableResult
    private func isolateLoadedStateOrDefer(
        target: MediaStatePendingAccountIsolationTarget
    ) -> Bool {
        stageCurrentSkyStreamPayloadForAccountBoundary()
        skyStreamRestoreTask?.cancel()
        skyStreamRestoreTask = nil
        lastAppliedSkyStreamPayloadHashes = [:]
        inFlightSkyStreamPayloadHashes = [:]
        if archive.pendingAccountIsolationProfileIDs.isEmpty {
            guard let profileIDs = accountIsolationProfileIDsFromLocalEvidence() else {
                hasDeferredRemoteApply = true
                hasDeferredDestructiveAccountIsolation = true
                return false
            }
            archive.pendingAccountIsolationProfileIDs = profileIDs
            archive.pendingAccountIsolationTarget = target
            guard persistArchive() else {
                hasDeferredRemoteApply = true
                hasDeferredDestructiveAccountIsolation = true
                return false
            }
        } else if archive.pendingAccountIsolationTarget != target {

            hasDeferredRemoteApply = true
            hasDeferredDestructiveAccountIsolation = true
            Logger.shared.log(
                "MediaStateSync: refused account isolation with missing or mismatched target authority",
                type: "Error"
            )
            return false
        }
        if MediaStatePlaybackLease.isActive {
            hasDeferredRemoteApply = true
            hasDeferredDestructiveAccountIsolation = true
            return true
        } else {
            let isolated = completePendingDestructiveAccountIsolation(
                expectedTarget: target
            )
            hasDeferredDestructiveAccountIsolation = !isolated
            hasDeferredRemoteApply = !isolated
            return isolated
        }
    }

    private func accountIsolationProfileIDsFromLocalEvidence() -> Set<UUID>? {
        var result = Set(ProfileManager.shared.profiles.map(\.id))
        result.insert(ProfileManager.defaultProfileID)

        func insertOwner(from recordName: String) -> Bool {
            guard let kind = MediaStateRecordName.kind(from: recordName) else {
                return true
            }
            if kind == .profile {
                if let identifier = MediaStateRecordName.identifier(from: recordName),
                   let profileID = UUID(uuidString: identifier) {
                    result.insert(profileID)
                }
            } else if kind.isProfileScoped {
                result.insert(MediaStateRecordName.profileID(from: recordName))
            }
            return result.count
                <= MediaStateLocalArchive.maximumPendingAccountIsolationProfileIDs
        }

        for recordName in archive.lastLocalRecordNames {
            guard insertOwner(from: recordName) else {
                Logger.shared.log(
                    "MediaStateSync: refused an oversized account-isolation profile journal from the last local snapshot",
                    type: "Error"
                )
                return nil
            }
        }

        for envelope in archive.records.values
        where envelope.kind == .profile && !envelope.isDeleted {
            guard insertOwner(from: envelope.recordName) else {
                Logger.shared.log(
                    "MediaStateSync: refused an oversized account-isolation profile journal from canonical records",
                    type: "Error"
                )
                return nil
            }
        }
        return result
    }

    private func cancelPendingAccountIsolationReturningToOwner(
        currentAccountRecordName: String
    ) -> Bool {
        guard MediaStatePendingIsolationCancellationPolicy
            .canReturnToOwnerWithoutCleanup(
                archiveOwnerRecordName: archive.accountOwnerRecordName,
                currentAccountRecordName: currentAccountRecordName,
                isAccountNeutralLocalStateActive: archive.isAccountNeutralLocalStateActive,
                hasPendingProfiles: !archive.pendingAccountIsolationProfileIDs.isEmpty,
                pendingTargetMatchesCurrentAccount: archive.pendingAccountIsolationTarget
                    == .account(recordName: currentAccountRecordName)
            ) else {
            return false
        }
        let pendingProfileIDs = archive.pendingAccountIsolationProfileIDs
        let pendingTarget = archive.pendingAccountIsolationTarget
        archive.pendingAccountIsolationProfileIDs = []
        archive.pendingAccountIsolationTarget = nil
        guard persistArchive() else {
            archive.pendingAccountIsolationProfileIDs = pendingProfileIDs
            archive.pendingAccountIsolationTarget = pendingTarget
            return false
        }
        initialLocalStatePolicy = .migrateLocalState
        isAccountIsolationInProgress = false
        hasDeferredRemoteApply = false
        hasDeferredDestructiveAccountIsolation = false
        isTrustedOfflineCacheActive = true
        return true
    }

    private func completePendingDestructiveAccountIsolation(
        expectedTarget: MediaStatePendingAccountIsolationTarget
    ) -> Bool {
        guard !archive.pendingAccountIsolationProfileIDs.isEmpty,
              archive.pendingAccountIsolationTarget == expectedTarget else {
            Logger.shared.log(
                "MediaStateSync: refused destructive cleanup without exact target authority",
                type: "Error"
            )
            return false
        }
        let pendingProfileIDs = archive.pendingAccountIsolationProfileIDs
        let pendingTarget = archive.pendingAccountIsolationTarget
        let isolated = replaceLoadedStateWithAccountNeutralState(
            outgoingProfileIDsOverride: pendingProfileIDs
        )
        if isolated {
            archive.pendingAccountIsolationProfileIDs = []
            archive.pendingAccountIsolationTarget = nil
            guard persistArchive() else {

                archive.pendingAccountIsolationProfileIDs = pendingProfileIDs
                archive.pendingAccountIsolationTarget = pendingTarget
                return false
            }
        }
        return isolated
    }

    private var confirmedCurrentAccountIsolationTarget: MediaStatePendingAccountIsolationTarget? {
        if let verifiedAccountRecordName {
            return .account(recordName: verifiedAccountRecordName)
        }
        return isSignedOutIdentityConfirmed ? .signedOut : nil
    }

    private func invalidLocalProgressRecordNames() -> Set<String> {
        let validationClock = Date()
        return Set(buildLocalSnapshot().records.compactMap { recordName, envelope in
            guard Self.progressDomainKinds.contains(envelope.kind) else { return nil }
            var candidate = envelope
            candidate.modifiedAt = validationClock
            return MediaStateEnvelopeValidator.rejectionReason(
                for: candidate,
                dictionaryKey: recordName,
                allowsSystemFields: true
            ) == nil ? nil : recordName
        })
    }

    @discardableResult
    private func applyArchiveToManagers(allowsConfirmedEmptyRoster: Bool = false) -> Bool {
        guard !isLocalArchiveUnavailable,
              !hasPendingAccountIsolationJournal else {
            Logger.shared.log(
                "MediaStateSync: refused archive apply while canonical state is unavailable or account isolation is pending",
                type: "Error"
            )
            return false
        }
        if let reason = MediaStateEnvelopeValidator.rejectionReason(
            for: archive.records,
            allowsSystemFields: true
        ) {
            Logger.shared.log(
                "MediaStateSync: refused to apply an invalid archive (\(reason))",
                type: "Error"
            )
            return false
        }
        let invalidLocalProgressRecordNames = invalidLocalProgressRecordNames()
        isApplyingRemoteState = true
        defer { isApplyingRemoteState = false }

        applyProfileRecords(allowsConfirmedEmptyRoster: allowsConfirmedEmptyRoster)
        for profileID in profileIDsPresentInArchive() {
            applyLibraryRecords(forProfile: profileID)
            if MediaStateInvalidLocalDomainPolicy.shouldPreserveLocalDomain(
                invalidRecordNames: invalidLocalProgressRecordNames,
                domainKinds: Self.progressDomainKinds,
                profileID: profileID
            ) {
                Logger.shared.log(
                    "MediaStateSync: preserved local progress for profile \(profileID) because it contains a record that cannot be represented safely",
                    type: "Error"
                )
            } else {
                applyProgressRecords(forProfile: profileID)
            }
            applyRatingRecords(forProfile: profileID)
            applyCatalogRecord(forProfile: profileID)
        }
        applyServiceSourcesRecords()
        applySettingRecords()
        applySkyStreamMetadataRecords()
        archive.deferredApplyManagerPayloadHashes.removeAll()
        NotificationCenter.default.post(name: .mediaStateDidRestore, object: self)
        return true
    }

    private func profileIDsPresentInArchive() -> [UUID] {
        var ids = ProfileManager.shared.profiles.map(\.id)
        let known = Set(ids)

        let deletedOwners = Set(
            archive.records.values
                .filter { $0.kind == .profile && $0.isDeleted }
                .compactMap { MediaStateRecordName.identifier(from: $0.recordName) }
                .compactMap(UUID.init(uuidString:))
        )
        for envelope in archive.records.values where envelope.kind.isProfileScoped {

            guard !envelope.isDeleted else { continue }
            let owner = MediaStateRecordName.profileID(from: envelope.recordName)
            if !known.contains(owner), !ids.contains(owner), !deletedOwners.contains(owner) {
                ids.append(owner)
            }
        }
        return ids
    }

    private func applyProfileRecords(allowsConfirmedEmptyRoster: Bool = false) {

        guard archive.records.values.contains(where: { $0.kind == .profile }) else { return }

        let liveProfileRecords = activeRecords(of: .profile)
        guard !liveProfileRecords.isEmpty else {
            if allowsConfirmedEmptyRoster {
                ProfileManager.shared.replaceProfilesForMediaState(
                    [],
                    allowsEmptyRosterForConfirmedAccountBoundary: true
                )
                return
            }
            Logger.shared.log(
                "MediaStateSync: every profile record in the archive is a tombstone; kept the local roster rather than collapsing it to a fresh default",
                type: "iCloud"
            )
            return
        }
        let localProfiles = Dictionary(
            ProfileManager.shared.profiles.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var resolved: [Profile] = []

        for envelope in liveProfileRecords {
            if let profile = try? decoder.decode(Profile.self, from: envelope.payload) {

                resolved.append(localProfiles[profile.id]?.applyingSyncedRecord(profile) ?? profile)
                continue
            }

            guard let owner = MediaStateRecordName.identifier(from: envelope.recordName)
                .flatMap(UUID.init(uuidString:)) else {

                Logger.shared.log(
                    "MediaStateSync: profile record \(envelope.recordName) did not decode and names no profile; skipped the roster merge rather than risk deleting one",
                    type: "iCloud"
                )
                return
            }

            if let local = localProfiles[owner] {
                Logger.shared.log(
                    "MediaStateSync: profile record \(envelope.recordName) did not decode; kept the local profile instead of reading it as a deletion",
                    type: "iCloud"
                )
                resolved.append(local)
            } else {
                Logger.shared.log(
                    "MediaStateSync: profile record \(envelope.recordName) did not decode and is unknown to this device; left it out of the roster",
                    type: "iCloud"
                )
            }
        }

        ProfileManager.shared.replaceProfilesForMediaState(resolved)
    }

    private func activeRecords(of kind: MediaStateKind) -> [MediaStateEnvelope] {
        archive.records.values.filter {
            $0.kind == kind && !$0.isDeleted && $0.settingScope.appliesToCurrentPlatform
        }
    }

    private func activeRecords(of kind: MediaStateKind, forProfile profileID: UUID) -> [MediaStateEnvelope] {
        activeRecords(of: kind).filter {
            MediaStateRecordName.profileID(from: $0.recordName) == profileID
        }
    }

    private func recordsOwned(by profileID: UUID) -> [MediaStateEnvelope] {
        archive.records.values.filter {
            $0.kind.isProfileScoped &&
                MediaStateRecordName.profileID(from: $0.recordName) == profileID
        }
    }

    private func applyLibraryRecords(forProfile profileID: UUID) {
        let allRecords = recordsOwned(by: profileID)
        guard MediaStateLibraryRestorePolicy.hasCollectionDefinitionHistory(in: allRecords) else {
            return
        }

        let definitions = activeRecords(of: .libraryCollection, forProfile: profileID).compactMap {
            try? decoder.decode(LibraryCollectionPayload.self, from: $0.payload)
        }

        let memberships = activeRecords(of: .libraryMembership, forProfile: profileID).compactMap {
            envelope -> DecodedLibraryMembership? in
            guard let payload = try? decoder.decode(
                LibraryMembershipPayload.self,
                from: envelope.payload
            ) else { return nil }
            return DecodedLibraryMembership(envelope: envelope, payload: payload)
        }
        var membershipsByCollection: [String: [String: DecodedLibraryMembership]] = [:]
        for membership in memberships {
            let collectionKey = membership.payload.collectionKey
            let stableIdentity = membership.payload.item.searchResult.stableIdentity
            if let current = membershipsByCollection[collectionKey]?[stableIdentity],
               !prefersLibraryMembership(membership, over: current) {
                continue
            }
            membershipsByCollection[collectionKey, default: [:]][stableIdentity] = membership
        }

        let collections = definitions.sorted { $0.order < $1.order }.map { definition in
            LibraryCollection(
                id: definition.id,
                name: definition.name,

                items: (membershipsByCollection[definition.key].map { Array($0.values) } ?? [])
                    .sorted { lhs, rhs in
                        switch (lhs.payload.order, rhs.payload.order) {
                        case let (l?, r?):
                            if l != r { return l < r }
                        case (_?, nil):
                            return true
                        case (nil, _?):
                            return false
                        case (nil, nil):
                            break
                        }
                        if lhs.payload.item.dateAdded != rhs.payload.item.dateAdded {
                            return lhs.payload.item.dateAdded < rhs.payload.item.dateAdded
                        }
                        return lhs.payload.item.searchResult.stableIdentity <
                            rhs.payload.item.searchResult.stableIdentity
                    }
                    .map(\.payload.item),
                description: definition.description
            )
        }
        LibraryManager.shared.replaceCollectionsForMediaState(collections, forProfile: profileID)
    }

    private func prefersLibraryMembership(
        _ candidate: DecodedLibraryMembership,
        over current: DecodedLibraryMembership
    ) -> Bool {
        if candidate.envelope.modifiedAt != current.envelope.modifiedAt {
            return candidate.envelope.modifiedAt > current.envelope.modifiedAt
        }
        if candidate.envelope.revision != current.envelope.revision {
            return candidate.envelope.revision > current.envelope.revision
        }
        let expectedIdentifier = "\(candidate.payload.collectionKey):\(candidate.payload.item.searchResult.stableIdentity)"
        let candidateIsTyped = MediaStateRecordName.identifier(
            from: candidate.envelope.recordName
        ) == expectedIdentifier
        let currentIsTyped = MediaStateRecordName.identifier(
            from: current.envelope.recordName
        ) == expectedIdentifier
        if candidateIsTyped != currentIsTyped { return candidateIsTyped }
        return candidate.envelope.recordName > current.envelope.recordName
    }

    private func applyProgressRecords(forProfile profileID: UUID) {

        guard let currentProgress = ProgressManager.shared.progressData(forProfile: profileID) else {
            Logger.shared.log(
                "MediaStateSync: refused to apply progress records for profile \(profileID) because the local store could not be read",
                type: "iCloud"
            )
            return
        }

        guard MediaStateProgressRestorePolicy.hasWatchHistory(in: recordsOwned(by: profileID)) else {
            let localEntryCount = currentProgress.movieProgress.count
                + currentProgress.episodeProgress.count
            if localEntryCount > 0 {
                Logger.shared.log(
                    "MediaStateSync: refused to apply progress records with no watch history over \(localEntryCount) local entries for profile \(profileID)",
                    type: "iCloud"
                )
            }
            return
        }
        let currentMovies = Dictionary(
            currentProgress.movieProgress.map { ($0.id, $0) },
            uniquingKeysWith: { current, candidate in
                candidate.lastUpdated >= current.lastUpdated ? candidate : current
            }
        )
        let currentEpisodes = Dictionary(
            currentProgress.episodeProgress.map { ($0.id, $0) },
            uniquingKeysWith: { current, candidate in
                candidate.lastUpdated >= current.lastUpdated ? candidate : current
            }
        )
        var progress = ProgressData()
        progress.movieProgress = activeRecords(of: .movieProgress, forProfile: profileID).compactMap {
            try? decoder.decode(MovieProgressEntry.self, from: $0.payload)
        }.map { incoming in
            var merged = incoming
            merged.lastHref = currentMovies[incoming.id]?.lastHref
            merged.lastServiceId = currentMovies[incoming.id]?.lastServiceId ?? incoming.lastServiceId
            merged.lastSourceId = currentMovies[incoming.id]?.lastSourceId ?? incoming.lastSourceId
            merged.lastContentReference = currentMovies[incoming.id]?.lastContentReference
            return merged
        }
        progress.episodeProgress = activeRecords(of: .episodeProgress, forProfile: profileID).compactMap {
            try? decoder.decode(EpisodeProgressEntry.self, from: $0.payload)
        }.map { incoming in
            var merged = incoming
            merged.lastHref = currentEpisodes[incoming.id]?.lastHref
            merged.lastServiceId = currentEpisodes[incoming.id]?.lastServiceId ?? incoming.lastServiceId
            merged.lastSourceId = currentEpisodes[incoming.id]?.lastSourceId ?? incoming.lastSourceId
            merged.lastContentReference = currentEpisodes[incoming.id]?.lastContentReference
            return merged
        }
        progress.showMetadata = Dictionary(
            activeRecords(of: .showMetadata, forProfile: profileID).compactMap { envelope in
                guard let value = try? decoder.decode(ShowMetadata.self, from: envelope.payload) else { return nil }
                return (value.showId, value)
            },
            uniquingKeysWith: { _, candidate in candidate }
        )
        progress.hiddenUpNextShowIds = Set(activeRecords(of: .hiddenUpNext, forProfile: profileID).compactMap { envelope in
            MediaStateRecordName.identifier(from: envelope.recordName).flatMap(Int.init)
        })
        ProgressManager.shared.applyRestoredProgressData(progress, forProfile: profileID)
    }

    private func applyRatingRecords(forProfile profileID: UUID) {

        guard let localStore = UserRatingManager.shared.ratingsAndNotes(forProfile: profileID) else {
            Logger.shared.log(
                "MediaStateSync: skipped rating restore for profile \(profileID); local store is unreadable",
                type: "iCloud"
            )
            return
        }

        guard MediaStateRatingRestorePolicy.hasRatingHistory(in: recordsOwned(by: profileID)) else {
            let localEntryCount = Set(localStore.ratings.keys).union(localStore.notes.keys).count
            if localEntryCount > 0 {
                Logger.shared.log(
                    "MediaStateSync: refused to apply rating records with no rating history over \(localEntryCount) local entries for profile \(profileID)",
                    type: "iCloud"
                )
            }
            return
        }

        var ratings: [String: Double] = [:]
        var notes: [String: String] = [:]
        for envelope in activeRecords(of: .rating, forProfile: profileID) {
            guard let value = try? decoder.decode(RatingPayload.self, from: envelope.payload) else { continue }
            let key = String(value.tmdbID)
            ratings[key] = value.rating
            notes[key] = value.note
        }
        UserRatingManager.shared.restoreRatingsAndNotes(
            ratings: ratings,
            notes: notes,
            forProfile: profileID
        )
    }

    private func applySettingRecords() {
        guard EclipseSettingsSyncPreference.isEnabled else { return }
#if os(iOS)

        let notificationStore = ProfileSettingsStore.active
        let previousNotificationSubscriptions = notificationStore.string(
            forKey: LocalNotificationManager.subscriptionsStorageKey
        )
        let previousEpisodeReminders = notificationStore.string(
            forKey: LocalNotificationManager.episodeRemindersStorageKey
        )
#endif
        let liveProfileIDs = Set(ProfileManager.shared.profiles.map(\.id))
        MediaStateSettingRestorePolicy.apply(
            records: archive.records.values.filter { envelope in
                guard envelope.kind == .setting,
                      let key = MediaStateRecordName.identifier(from: envelope.recordName) else {
                    return false
                }
                guard key != MediaStateServiceSourcesPayload.settingKey else { return false }
                if EclipseSettingsRegistry.scope(for: key) == .services,
                   !MediaStateServicesSettingSyncPolicy.participatesInGlobalSync(
                       sharesServices: ProfileSettingsStore.sharesServices
                   ) {
                    return false
                }
                guard EclipseSettingsRegistry.scope(for: key) == .profile else { return true }
                return liveProfileIDs.contains(
                    MediaStateRecordName.profileID(from: envelope.recordName)
                )
            }
        ) { key, owner in
            switch EclipseSettingsRegistry.scope(for: key) {
            case .profile:
                return ProfileSettingsStore.shared.store(for: owner)
            case .services:
                return ProfileSettingsStore.shared.store(for: ProfileManager.defaultProfileID)
            case .device:
                return ProfileSettingsStore.device
            }
        }
        HomeCatalogLayoutStore.shared.reloadFromStorage()
        EclipseTheme.shared.reloadForActiveProfile()
        AlgorithmManager.shared.reloadForActiveProfile()
        AccentColorManager.shared.reloadForActiveProfile()
        Settings.current?.reloadForActiveProfile()
#if os(iOS)
        reloadLocalNotificationSelectionsIfNeeded(
            previousSubscriptions: previousNotificationSubscriptions,
            previousEpisodeReminders: previousEpisodeReminders
        )
#endif
    }

    private func applyServiceSourcesRecords() {
        let targetProfileIDs = ProfileSettingsStore.sharesServices
            ? [ProfileManager.defaultProfileID]
            : ProfileManager.shared.profiles.map(\.id)
        for profileID in targetProfileIDs {
            let name = MediaStateRecordName.make(
                kind: .setting,
                identifier: MediaStateServiceSourcesPayload.settingKey,
                profileID: profileID
            )
            guard let envelope = archive.records[name], !envelope.isDeleted,
                  let encoded = MediaStateSettingValueValidator.validatedValue(
                      from: envelope.payload,
                      forKey: MediaStateServiceSourcesPayload.settingKey
                  ) as? Data,
                  let payload = try? decoder.decode(
                      MediaStateServiceSourcesPayload.self,
                      from: encoded
                  ), payload.isCanonicalAndCloudSafe else {
                continue
            }
            applyServiceSources(payload, forProfile: profileID)
        }
    }

    private func applyServiceSources(
        _ incoming: MediaStateServiceSourcesPayload,
        forProfile profileID: UUID
    ) {
        guard incoming.isCanonicalAndCloudSafe,
              let current = capturedServiceSources(forProfile: profileID) else {
            return
        }
        var comparableCurrent = MediaStateServiceSourcesPayload.sanitized(
            services: current.services,
            stremioAddons: current.addons,
            nuvioPluginsData: current.nuvioPluginsData
        )
        if incoming.nuvioPluginsData == nil {
            comparableCurrent.nuvioPluginsData = nil
        }
        guard comparableCurrent != incoming else { return }

        let services = MediaStateServiceSourcesPayload.mergedServices(
            current: current.services,
            incoming: incoming.services
        )
        let addons = MediaStateServiceSourcesPayload.mergedStremioAddons(
            current: current.addons,
            incoming: incoming.stremioAddons
        )
        ServiceStoreScope.replaceSources(
            services: services.map {
                ServiceStoreScope.RestoredService(
                    id: $0.id,
                    url: $0.url,
                    jsonMetadata: $0.jsonMetadata,
                    jsScript: $0.jsScript,
                    isActive: $0.isActive,
                    sortIndex: $0.sortIndex
                )
            },
            addons: addons.map {
                ServiceStoreScope.RestoredAddon(
                    id: $0.id,
                    configuredURL: $0.configuredURL,
                    manifestJSON: $0.manifestJSON,
                    isActive: $0.isActive,
                    sortIndex: $0.sortIndex
                )
            },
            forProfile: profileID
        )

#if os(iOS) && !targetEnvironment(macCatalyst)
        applyNuvioMetadata(incoming.nuvioPluginsData, forProfile: profileID)
#endif
    }

#if os(iOS) && !targetEnvironment(macCatalyst)
    private func applyNuvioMetadata(_ data: Data?, forProfile profileID: UUID) {
        guard let data,
              let incoming = try? decoder.decode(NuvioStoredPluginsState.self, from: data) else {
            return
        }
        guard let safeIncoming = BackupData.nuvioStateForExperimentalCloudSync(incoming) else {
            Logger.shared.log(
                "MediaStateSync: refused incomplete Nuvio metadata for profile \(profileID)",
                type: "Error"
            )
            return
        }
        let canonicalEncoder = JSONEncoder()
        canonicalEncoder.outputFormatting = [.sortedKeys]
        guard let canonicalIncoming = try? canonicalEncoder.encode(safeIncoming),
              canonicalIncoming == data else {
            Logger.shared.log(
                "MediaStateSync: refused non-canonical Nuvio metadata for profile \(profileID)",
                type: "Error"
            )
            return
        }

        let settingsStore = ProfileSettingsStore.sharesServices
            ? UserDefaults.standard
            : ProfileSettingsStore.shared.store(for: profileID)
        let current = settingsStore.data(forKey: "nuvioPluginsState.v2").flatMap {
            try? decoder.decode(NuvioStoredPluginsState.self, from: $0)
        } ?? NuvioStoredPluginsState()
        let merged = BackupData.nuvioRestorePlanForExperimentalCloudSync(
            incoming: safeIncoming,
            current: current
        ).state

        guard let encoded = try? encoder.encode(merged) else { return }
        settingsStore.set(encoded, forKey: "nuvioPluginsState.v2")

        let targetsActiveStore = ServiceStoreScope.storeURL(for: profileID).standardizedFileURL
            == ServiceStoreScope.activeStoreURL.standardizedFileURL
        if targetsActiveStore, PlatformCapabilities.current.supportsNuvioPlugins {
            let expectedProfileID = ProfileManager.shared.activeProfileID
            let expectedScopeGeneration = ServiceStoreScope.generation
            guard expectedProfileID == profileID else { return }
            Task { @MainActor in
                guard ProfileManager.shared.activeProfileID == expectedProfileID,
                      ServiceStoreScope.isCurrent(expectedScopeGeneration) else { return }
                await NuvioPluginManager.shared.restoreBackupState(
                    merged,
                    expectedScopeGeneration: expectedScopeGeneration
                )
            }
        }
    }
#endif

    private func applyCatalogRecord(forProfile profileID: UUID) {
        let allRecords = recordsOwned(by: profileID)
        guard MediaStateCatalogRestorePolicy.hasCatalogOrderHistory(in: allRecords) else {
            return
        }

        guard let envelope = activeRecords(of: .catalogOrder, forProfile: profileID).first,
              let catalogs = try? decoder.decode([Catalog].self, from: envelope.payload),
              !catalogs.isEmpty else {

            if profileID == ProfileManager.shared.activeProfileID {
                CatalogManager.shared.resetCatalogsForMediaStateAccountChange()
            } else {
                CatalogManager.shared.discardStore(forProfile: profileID)
            }
            return
        }
        CatalogManager.shared.replaceCatalogsForMediaState(
            catalogs.sorted { $0.order < $1.order },
            forProfile: profileID
        )
    }

    private func applySkyStreamMetadataRecords() {
        guard archive.records.values.contains(where: { $0.kind == .skyStreamMetadata }) else {
            return
        }
        let profileIDs = MediaStateSkyStreamScopePolicy.profileIDs(
            from: ProfileManager.shared.profiles.map(\.id),
            sharesServices: ProfileSettingsStore.sharesServices
        )
        for profileID in profileIDs {
            applySkyStreamMetadataRecord(forProfile: profileID)
        }
    }

    private func applySkyStreamMetadataRecord(forProfile profileID: UUID) {
        let recordName = MediaStateSkyStreamScopePolicy.recordName(for: profileID)
        guard let envelope = archive.records[recordName],
              !envelope.isDeleted,
              let snapshot = try? SkyStreamMediaStateDocument.decodeMetadataOnly(envelope.payload),
              let canonicalData = canonicalSkyStreamMetadataPayload(snapshot) else {
            return
        }
        let payloadHash = Self.payloadSHA256(canonicalData)
        guard lastAppliedSkyStreamPayloadHashes[recordName] != payloadHash,
              inFlightSkyStreamPayloadHashes[recordName] != payloadHash else { return }

#if os(iOS) && !targetEnvironment(macCatalyst)
        guard PlatformCapabilities.current.supportsSkyStreamPlugins else {
            lastAppliedSkyStreamPayloadHashes[recordName] = payloadHash
            return
        }
        guard let owner = archive.accountOwnerRecordName,
              owner == verifiedAccountRecordName else { return }
        let settings = ProfileSettingsStore.sharesServices
            ? UserDefaults.standard
            : ProfileSettingsStore.shared.store(for: profileID)
        let pendingKey = SkyStreamPluginManager.pendingSafeCloudSnapshotKey
        if settings.object(forKey: pendingKey) == nil,
           localSkyStreamMetadataPayload(forProfile: profileID) == canonicalData {
            lastAppliedSkyStreamPayloadHashes[recordName] = payloadHash
            return
        }
        guard let pendingData = pendingSkyStreamSnapshotData(snapshot) else { return }
        settings.set(pendingData, forKey: pendingKey)
        guard settings.synchronize(),
              settings.data(forKey: pendingKey) == pendingData else {
            Logger.shared.log(
                "SkyStream CloudKit metadata staging failed for profile \(profileID)",
                type: "iCloud"
            )
            return
        }

        let targetsActiveStore = ServiceStoreScope.storeURL(for: profileID).standardizedFileURL
            == ServiceStoreScope.activeStoreURL.standardizedFileURL
        guard targetsActiveStore else {
            lastAppliedSkyStreamPayloadHashes[recordName] = payloadHash
            return
        }
        let scopeAuthority = SkyStreamServiceScopeAuthority.capture()
        let generation = accountPreparationGeneration
        skyStreamRestoreTask?.cancel()
        inFlightSkyStreamPayloadHashes[recordName] = payloadHash
        skyStreamRestoreTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.inFlightSkyStreamPayloadHashes[recordName] == payloadHash {
                    self.inFlightSkyStreamPayloadHashes.removeValue(forKey: recordName)
                }
            }
            let manager = SkyStreamPluginManager.shared
            var attemptsRemaining = 600
            while !manager.isLoaded,
                  attemptsRemaining > 0,
                  !Task.isCancelled,
                  scopeAuthority.isCurrent {
                attemptsRemaining -= 1
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !Task.isCancelled,
                  manager.isLoaded,
                  scopeAuthority.isCurrent,
                  generation == self.accountPreparationGeneration,
                  owner == self.archive.accountOwnerRecordName,
                  owner == self.verifiedAccountRecordName else { return }
            do {
                var retryIndex = 0
                while true {
                    guard !Task.isCancelled,
                          scopeAuthority.isCurrent,
                          generation == self.accountPreparationGeneration,
                          owner == self.archive.accountOwnerRecordName,
                          owner == self.verifiedAccountRecordName,
                          self.inFlightSkyStreamPayloadHashes[recordName] == payloadHash else {
                        return
                    }
                    let result = try await manager.restoreSafeCloudSnapshot(
                        snapshot,
                        expectedScopeAuthority: scopeAuthority
                    )
                    guard !Task.isCancelled,
                          scopeAuthority.isCurrent,
                          generation == self.accountPreparationGeneration,
                          owner == self.archive.accountOwnerRecordName,
                          owner == self.verifiedAccountRecordName,
                          self.inFlightSkyStreamPayloadHashes[recordName] == payloadHash else {
                        return
                    }
                    if result.isComplete {
                        settings.removeObject(forKey: pendingKey)
                        guard settings.synchronize(), settings.object(forKey: pendingKey) == nil else {
                            Logger.shared.log(
                                "SkyStream CloudKit metadata completion could not clear its pending marker for profile \(profileID)",
                                type: "iCloud"
                            )
                            return
                        }
                        self.lastAppliedSkyStreamPayloadHashes[recordName] = payloadHash
                        return
                    }
                    guard retryIndex < 2 else {
                        Logger.shared.log(
                            "SkyStream CloudKit metadata restore remains partial unresolvedCount=\(result.unresolvedPackageIDs.count)",
                            type: "iCloud"
                        )
                        return
                    }
                    let delays: [UInt64] = [2_000_000_000, 5_000_000_000]
                    let delay = delays[retryIndex]
                    retryIndex += 1
                    try await Task.sleep(nanoseconds: delay)
                }
            } catch {
                guard !Task.isCancelled else { return }
                Logger.shared.log(
                    "SkyStream CloudKit metadata restore failed errorType=\(String(reflecting: type(of: error)))",
                    type: "iCloud"
                )
            }
        }
#else
        if profileID == ProfileManager.defaultProfileID {
            do {
                try SkyStreamPluginManager.shared.preserveOpaqueMediaStateSnapshotData(canonicalData)
            } catch {
                Logger.shared.log("SkyStream metadata preservation failed", type: "iCloud")
                return
            }
        }
        lastAppliedSkyStreamPayloadHashes[recordName] = payloadHash
#endif
    }

    private func pendingSkyStreamSnapshotData(
        _ snapshot: SkyStreamBackupSnapshot
    ) -> Data? {
#if os(iOS)
        guard let safeSnapshot = BackupData.skyStreamSnapshotForExperimentalCloudSync(
            snapshot
        ) else {
            return nil
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(safeSnapshot), data.count <= 50_000_000 else {
            return nil
        }
        return data
#else
        return try? SkyStreamMediaStateDocument.encodeMetadataOnly(snapshot)
#endif
    }

    private func stageCurrentSkyStreamPayloadForAccountBoundary() {
        let profileIDs = MediaStateSkyStreamScopePolicy.profileIDs(
            from: ProfileManager.shared.profiles.map(\.id),
            sharesServices: ProfileSettingsStore.sharesServices
        )
        for profileID in profileIDs {
            let recordName = MediaStateSkyStreamScopePolicy.recordName(for: profileID)
            let payload = localSkyStreamMetadataPayload(forProfile: profileID)
                ?? archive.records[recordName].flatMap { envelope in
                    guard !envelope.isDeleted,
                          let snapshot = try? SkyStreamMediaStateDocument.decodeMetadataOnly(
                            envelope.payload
                          ) else { return nil }
                    return canonicalSkyStreamMetadataPayload(snapshot)
                }
            guard let payload else { continue }
            pendingAccountBoundaryPayloadHashes[recordName] = Self.payloadSHA256(payload)
        }
    }

    private static func payloadSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func mediaCollectionKey(_ collection: LibraryCollection) -> String {
        collection.name.caseInsensitiveCompare("Bookmarks") == .orderedSame
            ? "bookmarks"
            : collection.id.uuidString.lowercased()
    }

    private func propertyListData(for value: Any) -> Data? {
        guard PropertyListSerialization.propertyList(value, isValidFor: .binary) else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    private func propertyListValue(from data: Data) -> Any? {
        try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }

    private func receiveFetchedChanges(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) {

        if initialFetchCompleted {
            flushPendingCapture()
        }
        var recordsToSave: [String] = []
        for modification in event.modifications where modification.record.recordID.zoneID == zoneID {
            guard var candidate = MediaStateEnvelope(record: modification.record) else { continue }
            candidate.systemFields = modification.record.encodedSystemFields
            if let existing = archive.records[candidate.recordName] {
                var merged = existing.merged(with: candidate)
                merged.systemFields = candidate.systemFields
                archive.records[candidate.recordName] = merged
                if !envelopesHaveSameLogicalValue(merged, candidate) {
                    recordsToSave.append(candidate.recordName)
                }
            } else {
                archive.records[candidate.recordName] = candidate
            }
        }

        for deletion in event.deletions where deletion.recordID.zoneID == zoneID {
            if archive.pendingLocalRecordNames.contains(deletion.recordID.recordName) {

                continue
            }
            guard let existing = archive.records[deletion.recordID.recordName] else { continue }
            archive.records[deletion.recordID.recordName] = existing.tombstone()
        }
        persistArchive()
        if !recordsToSave.isEmpty {

            archive.pendingLocalRecordNames.formUnion(recordsToSave)
            persistArchive()
            if initialFetchCompleted {
                queueRecordSaves(recordsToSave)
            }
        }
        if initialFetchCompleted, applyArchiveToManagersOrDefer() {
            archive.lastLocalRecordNames = buildLocalSnapshot().recordNames
            captureAndQueueLocalChanges()
        }
    }

    private func envelopesHaveSameLogicalValue(
        _ lhs: MediaStateEnvelope,
        _ rhs: MediaStateEnvelope
    ) -> Bool {
        var lhs = lhs
        var rhs = rhs
        lhs.systemFields = nil
        rhs.systemFields = nil
        lhs.modifiedAt = MediaStateCloudKitPayloadCodec.wirePrecisionDate(lhs.modifiedAt)
        rhs.modifiedAt = MediaStateCloudKitPayloadCodec.wirePrecisionDate(rhs.modifiedAt)
        lhs.deletedAt = lhs.deletedAt.map(MediaStateCloudKitPayloadCodec.wirePrecisionDate)
        rhs.deletedAt = rhs.deletedAt.map(MediaStateCloudKitPayloadCodec.wirePrecisionDate)
        lhs.resetAt = lhs.resetAt.map(MediaStateCloudKitPayloadCodec.wirePrecisionDate)
        rhs.resetAt = rhs.resetAt.map(MediaStateCloudKitPayloadCodec.wirePrecisionDate)
        return lhs == rhs
    }

    private func receiveSentChanges(_ event: CKSyncEngine.Event.SentRecordZoneChanges) {
        guard !hasPendingAccountIsolationJournal,
              !isAccountIsolationInProgress else { return }
        var immediateRetryNames = Set<String>()
        var automaticRetryNames = Set<String>()
        var permanentFailureNames = Set<String>()
        var permanentFailureMessage: String?
        var automaticRetryCodes: [CKError.Code] = []
        var longestRetryAfter: TimeInterval?
        var failureCountsByCode: [Int: Int] = [:]
        for record in event.savedRecords {
            let recordName = record.recordID.recordName
            guard var currentEnvelope = archive.records[recordName] else {
                continue
            }
            guard var acknowledgedEnvelope = MediaStateEnvelope(record: record) else {
                immediateRetryNames.insert(recordName)
                continue
            }
            acknowledgedEnvelope.systemFields = record.encodedSystemFields
            let acknowledgedCurrentValue = envelopesHaveSameLogicalValue(
                acknowledgedEnvelope,
                currentEnvelope
            )

            currentEnvelope.systemFields = acknowledgedEnvelope.systemFields
            archive.records[recordName] = currentEnvelope
            if acknowledgedCurrentValue {
                archive.pendingLocalRecordNames.remove(recordName)
            } else {

                immediateRetryNames.insert(recordName)
            }
        }

        var staleSystemFieldRecordNames = Set<String>()
        var zoneRequiresRecreation = false

        for failure in event.failedRecordSaves {
            let failureCode = failure.error.code
            failureCountsByCode[failureCode.rawValue, default: 0] += 1
            guard let serverRecord = failure.error.serverRecord,
                  var serverEnvelope = MediaStateEnvelope(record: serverRecord) else {
                let unresolvedName = failure.record.recordID.recordName
                switch failureCode {
                case .unknownItem:
                    staleSystemFieldRecordNames.insert(unresolvedName)
                    immediateRetryNames.insert(unresolvedName)
                case .zoneNotFound, .userDeletedZone:
                    zoneRequiresRecreation = true
                    staleSystemFieldRecordNames.insert(unresolvedName)
                    automaticRetryNames.insert(unresolvedName)
                default:
                    if let message = MediaStateCloudKitSaveFailurePolicy
                        .permanentFailureMessage(for: failureCode) {
                        permanentFailureNames.insert(unresolvedName)
                        permanentFailureMessage = permanentFailureMessage ?? message
                    } else if MediaStateCloudKitSaveFailurePolicy.shouldRetryAutomatically(
                        failureCode
                    ) {
                        automaticRetryNames.insert(unresolvedName)
                        automaticRetryCodes.append(failureCode)
                        if let retryAfter = failure.error.retryAfterSeconds,
                           retryAfter.isFinite,
                           retryAfter >= 0 {
                            longestRetryAfter = max(longestRetryAfter ?? 0, retryAfter)
                        }
                    }
                }
                continue
            }
            serverEnvelope.systemFields = serverRecord.encodedSystemFields
            let recordName = failure.record.recordID.recordName
            if let localEnvelope = archive.records[recordName] {
                var merged = serverEnvelope.merged(with: localEnvelope)
                merged.systemFields = serverRecord.encodedSystemFields
                archive.records[recordName] = merged
                if envelopesHaveSameLogicalValue(merged, serverEnvelope) {
                    archive.pendingLocalRecordNames.remove(recordName)
                } else {
                    immediateRetryNames.insert(recordName)
                }
            } else {
                archive.records[recordName] = serverEnvelope
            }
        }
        for code in failureCountsByCode.keys.sorted() {
            Logger.shared.log(
                "MediaStateSync: record save failures count=\(failureCountsByCode[code] ?? 0) code=\(code)",
                type: "Error"
            )
        }
        for recordName in staleSystemFieldRecordNames {
            archive.records[recordName]?.systemFields = nil
        }
        if zoneRequiresRecreation, let activeEngine = engine {
            activeEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            Logger.shared.log(
                "MediaStateSync: queued a record zone rebuild after the server reported it missing",
                type: "iCloud"
            )
        }
        let retryNames = immediateRetryNames
            .union(automaticRetryNames)
            .union(permanentFailureNames)
        archive.pendingLocalRecordNames.formUnion(retryNames)
        guard persistArchive() else { return }
        if let permanentFailureMessage {
            phase = .localOnly(permanentFailureMessage)
            lastErrorMessage = permanentFailureMessage
        }
        if !automaticRetryCodes.isEmpty {
            recordCloudKitTransientFailure(
                codes: automaticRetryCodes,
                retryAfter: longestRetryAfter
            )
        }
        if !zoneRequiresRecreation, !immediateRetryNames.isEmpty {
            queueRecordSaves(Array(immediateRetryNames))
        }
        if retryNames.isEmpty, archive.pendingLocalRecordNames.isEmpty {
            clearCloudKitTransientFailure()
            lastErrorMessage = nil
        }
    }

    private func receiveSentDatabaseChanges(
        _ event: CKSyncEngine.Event.SentDatabaseChanges
    ) {
        guard !hasPendingAccountIsolationJournal,
              !isAccountIsolationInProgress else { return }
        if event.savedZones.contains(where: { $0.zoneID == zoneID }),
           let activeEngine = engine,
           !archive.pendingLocalRecordNames.isEmpty {
            stageRecordSaves(archive.pendingLocalRecordNames, on: activeEngine)
        }
        var automaticRetryCodes: [CKError.Code] = []
        var longestRetryAfter: TimeInterval?
        for failure in event.failedZoneSaves where failure.zone.zoneID == zoneID {
            if let message = MediaStateCloudKitSaveFailurePolicy.permanentFailureMessage(
                for: failure.error.code
            ) {
                phase = .localOnly(message)
                lastErrorMessage = message
            } else if MediaStateCloudKitSaveFailurePolicy.shouldRetryAutomatically(
                failure.error.code
            ) {
                automaticRetryCodes.append(failure.error.code)
                if let retryAfter = failure.error.retryAfterSeconds,
                   retryAfter.isFinite,
                   retryAfter >= 0 {
                    longestRetryAfter = max(longestRetryAfter ?? 0, retryAfter)
                }
            }
            Logger.shared.log(
                "MediaStateSync: record zone save failed code=\(failure.error.code.rawValue)",
                type: "Error"
            )
        }
        if !automaticRetryCodes.isEmpty {
            recordCloudKitTransientFailure(
                codes: automaticRetryCodes,
                retryAfter: longestRetryAfter
            )
        }
    }

    private func receiveFetchedDatabaseChanges(
        _ event: CKSyncEngine.Event.FetchedDatabaseChanges
    ) {
        guard event.deletions.contains(where: { $0.zoneID == zoneID }) else { return }
        guard !hasPendingAccountIsolationJournal,
              !isAccountIsolationInProgress,
              !isAccountRevalidationInProgress,
              let verifiedAccountRecordName,
              verifiedAccountRecordName == archive.accountOwnerRecordName,
              !archive.records.isEmpty else { return }

        for recordName in archive.records.keys {
            archive.records[recordName]?.systemFields = nil
        }
        archive.pendingLocalRecordNames = Set(archive.records.keys)
        guard persistArchive() else { return }
        engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        queueRecordSaves(Array(archive.records.keys))
        Logger.shared.log(
            "MediaStateSync: another device deleted the iCloud record zone, so this device queued its whole archive for re-upload count=\(archive.records.count)",
            type: "CloudSync"
        )
    }

    private func resetForAccountChange(
        _ changeType: CKSyncEngine.Event.AccountChange.ChangeType
    ) {
        switch changeType {
        case .signIn(let currentUser):

            if verifiedAccountRecordName == currentUser.recordName {
                return
            }
        case .switchAccounts(_, let currentUser):

            if verifiedAccountRecordName == currentUser.recordName,
               archive.accountOwnerRecordName == currentUser.recordName {
                return
            }
        case .signOut:
            break
        @unknown default:
            break
        }

        beginAccountIdentityRevalidation()
    }

    @discardableResult
    private func replaceLoadedStateWithAccountNeutralState(
        clearsDefaultTrackerCredentials: Bool = true,
        schedulesSourceManagerReload: Bool = true,
        outgoingProfileIDsOverride: Set<UUID>? = nil
    ) -> Bool {
        let wasApplyingRemoteState = isApplyingRemoteState
        isApplyingRemoteState = true
        defer { isApplyingRemoteState = wasApplyingRemoteState }

        let outgoingProfileIDs = Array(
            outgoingProfileIDsOverride
                ?? Set(ProfileManager.shared.profiles.map(\.id))
        )

#if os(iOS)
        guard BackupManager.shared.prepareReaderExtensionAuthenticationForAccountBoundary(
            outgoingProfileIDs: Set(outgoingProfileIDs)
        ) else { return false }
#endif
        ProfileManager.shared.replaceProfilesForMediaState([ProfileManager.makeDefaultProfile()])
        var trackerCleanupIsDurablyProtected = true
        if clearsDefaultTrackerCredentials {
            for profileID in outgoingProfileIDs {
                trackerCleanupIsDurablyProtected = TrackerManager.shared
                    .clearStoreForConfirmedAccountBoundary(profileID: profileID)
                    && trackerCleanupIsDurablyProtected
            }
        }
        for profileID in outgoingProfileIDs where profileID != ProfileManager.defaultProfileID {

            ProfileSettingsStore.shared.discardStore(forProfile: profileID)
            for store in ProfileScopedStoreRegistry.all {
                store.discardStore(forProfile: profileID)
            }
#if os(iOS)
            LocalNotificationManager.shared.discardStore(forProfile: profileID)
#endif
        }

        let clearedSources = replaceActiveSourcesWithAccountNeutralState(
            outgoingProfileIDs: Set(outgoingProfileIDs),
            readerAuthenticationCleanupPrepared: true
        )

        LibraryManager.shared.replaceCollectionsForMediaState([])
        let progressCleared = ProgressManager.shared.replaceProgressDataForRestore(
            ProgressData(),
            expectedProfileID: ProfileManager.defaultProfileID
        )
        let ratingsCleared = UserRatingManager.shared.restoreRatingsAndNotes(
            ratings: [:],
            notes: [:],
            forProfile: ProfileManager.defaultProfileID
        )
        RecommendationEngine.shared.invalidateCache()

#if os(iOS)
        MangaLibraryManager.shared.applyRestoredCollections(
            [],
            forProfile: ProfileManager.defaultProfileID
        )
        MangaReadingProgressManager.shared.applyRestoredProgress(
            [:],
            forProfile: ProfileManager.defaultProfileID
        )
        MangaCatalogManager.shared.applyRestoredCatalogs(
            [],
            forProfile: ProfileManager.defaultProfileID
        )
        KanzenCustomCatalogManager.shared.applyRestoredCatalogs(
            [],
            forProfile: ProfileManager.defaultProfileID
        )
        let previousNotificationSubscriptions = ProfileSettingsStore
            .store(for: LocalNotificationManager.subscriptionsStorageKey)
            .string(forKey: LocalNotificationManager.subscriptionsStorageKey)
        let previousEpisodeReminders = ProfileSettingsStore
            .store(for: LocalNotificationManager.episodeRemindersStorageKey)
            .string(forKey: LocalNotificationManager.episodeRemindersStorageKey)
#endif
        for key in MediaStateSettingRegistry.allKeys {

            let defaults = ProfileSettingsStore.store(for: key)
            guard let scope = MediaStateSettingRegistry.scope(for: key),
                  scope.appliesToCurrentPlatform else {
                continue
            }
            defaults.removeObject(forKey: key)
        }
        HomeCatalogLayoutStore.shared.reloadFromStorage()
        EclipseTheme.shared.reloadMediaAppearanceFromDefaults()
        CatalogManager.shared.resetCatalogsForMediaStateAccountChange()
#if !os(iOS) || targetEnvironment(macCatalyst)

        SkyStreamPluginManager.shared.clearOpaqueMediaStateSnapshotData()
#endif
#if os(iOS)
        reloadLocalNotificationSelectionsIfNeeded(
            previousSubscriptions: previousNotificationSubscriptions,
            previousEpisodeReminders: previousEpisodeReminders
        )
#endif
        if schedulesSourceManagerReload {
            Task { @MainActor in
                guard await self.reloadSourceManagersAfterAccountBoundary() else {
                    Logger.shared.log(
                        "MediaStateSync: source managers did not reload after account-neutral isolation; they reload on the next launch",
                        type: "Error"
                    )
                    return
                }
            }
        }
        archive.deferredApplyManagerPayloadHashes.removeAll()
        NotificationCenter.default.post(name: .mediaStateDidRestore, object: self)
        let isolationIsDurablyComplete = MediaStateAccountNeutralIsolationPersistencePolicy
            .isDurablyComplete(
                progressCleared: progressCleared,
                ratingsCleared: ratingsCleared,
                sourcesCleared: clearedSources,
                trackerCleanupProtected: trackerCleanupIsDurablyProtected
            )
        if !isolationIsDurablyComplete {
            Logger.shared.log(
                "MediaStateSync: account-neutral isolation remains pending because at least one local store could not be durably cleared",
                type: "Error"
            )
        }
        return isolationIsDurablyComplete
    }

    private func replaceActiveSourcesWithAccountNeutralState(
        outgoingProfileIDs: Set<UUID>,
        readerAuthenticationCleanupPrepared: Bool
    ) -> Bool {
#if os(iOS)
        return BackupManager.shared.replaceActiveSourcesWithAccountNeutralState(
            outgoingProfileIDs: outgoingProfileIDs,
            readerAuthenticationCleanupPrepared: readerAuthenticationCleanupPrepared
        )
#else
        _ = outgoingProfileIDs
        _ = readerAuthenticationCleanupPrepared
        let serviceStore = ServiceStore.shared
        TVServiceSettingVault.removeAllAccountsForAccountBoundary()
        StremioConfiguredURLVault.removeAllAccountsForAccountBoundary()

        let clearedServices = serviceStore.removeAllServicesForAccountBoundary()
        let clearedAddons = StremioAddonStore.shared.removeAll()
        let clearedSkyStream = serviceStore.clearSkyStreamStateDataForAccountBoundary()

        let defaults = ProfileSettingsStore.services
        for key in defaults.dictionaryRepresentation().keys
            where EclipseSettingsRegistry.scope(for: key) == .services {
            defaults.removeObject(forKey: key)
        }

        ServiceManager.shared.loadServicesFromCloud()
        StremioAddonManager.shared.loadAddons()
        SourceHealthStore.shared.reloadPersistedStateAfterRestore()
        return clearedServices && clearedAddons && clearedSkyStream
#endif
    }

    private func reloadSourceManagersAfterAccountBoundary() async -> Bool {
#if os(iOS)
        return await BackupManager.shared.reloadSourceManagersAfterAccountBoundary()
#else
        let expectedProfileID = ProfileManager.shared.activeProfileID
        let expectedServicesGeneration = ServiceStoreScope.generation
        let expectedRosterGeneration = ProfileManager.shared.rosterGeneration

        ServiceManager.shared.loadServicesFromCloud()
        StremioAddonManager.shared.loadAddons()
        SourceHealthStore.shared.reloadPersistedStateAfterRestore()
        await SkyStreamPluginManager.shared.reloadPersistedStateAfterRestore()

        return ProfileManager.shared.activeProfileID == expectedProfileID
            && ServiceStoreScope.isCurrent(expectedServicesGeneration)
            && ProfileManager.shared.rosterGeneration == expectedRosterGeneration
#endif
    }

#if os(iOS)
    private func reloadLocalNotificationSelectionsIfNeeded(
        previousSubscriptions: String?,
        previousEpisodeReminders: String?
    ) {
        let subscriptionsChanged = previousSubscriptions != ProfileSettingsStore.active.string(
            forKey: LocalNotificationManager.subscriptionsStorageKey
        )
        let remindersChanged = previousEpisodeReminders != ProfileSettingsStore.active.string(
            forKey: LocalNotificationManager.episodeRemindersStorageKey
        )
        guard subscriptionsChanged || remindersChanged else { return }

        Task { @MainActor in
            await LocalNotificationManager.shared.reloadPersistedSelectionsAfterRestore()
        }
    }
#endif

    private func record(for recordID: CKRecord.ID) -> CKRecord? {
        guard MediaStateSyncBootstrap.isCloudKitSyncEnabled,
              !isPreparedRecoverySyncBlocked,
              !hasPendingAccountIsolationJournal,
              !isAccountIsolationInProgress else { return nil }
        guard let envelope = archive.records[recordID.recordName] else { return nil }
        guard let record = envelope.makeRecord(
            recordID: recordID,
            recordType: Self.recordType
        ) else {
            Logger.shared.log(
                "MediaStateSync: refused a CloudKit record whose reset lineage would exceed or invalidate the existing payload field name=\(recordID.recordName)",
                type: "Error"
            )
            return nil
        }
        return record
    }

    private func stageEngineState(
        _ serialization: CKSyncEngine.State.Serialization
    ) {
        pendingEngineStateSerialization = serialization
    }

    private func persistPendingEngineStateAfterDurableArchive() {
        guard let serialization = pendingEngineStateSerialization,
              persistEngineState(serialization) else { return }
        pendingEngineStateSerialization = nil
    }

    @discardableResult
    private func persistEngineState(
        _ serialization: CKSyncEngine.State.Serialization
    ) -> Bool {
        guard !isPreparedRecoverySyncBlocked else { return false }
        guard isArchiveStateDurable else {

            _ = durablyRemoveEngineState(
                failureContext: "non-durable media-state archive"
            )
            return false
        }
        guard let accountOwnerRecordName = verifiedAccountRecordName,
              archive.accountOwnerRecordName == accountOwnerRecordName else {
            _ = durablyRemoveEngineState(
                failureContext: "unverified media-state archive owner"
            )
            return false
        }
        do {
            try Self.ensureStorageDirectory()
            let document = MediaStateEngineStateDocument(
                accountOwnerRecordName: accountOwnerRecordName,
                serialization: serialization
            )
            let data = try JSONEncoder().encode(document)
            guard data.count <= Self.maximumEngineStateBytes else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try data.write(to: Self.engineStateURL, options: .atomic)
            return true
        } catch {
            Logger.shared.log("Failed to persist CloudKit sync engine state: \(error.localizedDescription)", type: "iCloud")
            return false
        }
    }

    @discardableResult
    private func persistArchive() -> Bool {
        guard !isLocalArchiveUnavailable else {
            Logger.shared.log(
                "MediaStateSync: refused to overwrite an existing unavailable media-state archive",
                type: "Error"
            )
            return false
        }

        if initialLocalStatePolicy == .isolateIncomingAccount {
            archive.suppressedLocalRecordPayloadHashes.merge(
                pendingAccountBoundaryPayloadHashes,
                uniquingKeysWith: { _, incoming in incoming }
            )
        }
        isArchiveStateDurable = false
        do {
            try Self.ensureStorageDirectory()
            let data = try encoder.encode(archive)
            guard data.count <= Self.maximumArchiveBytes else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try data.write(to: Self.archiveURL, options: .atomic)
            isArchiveStateDurable = true
            return true
        } catch {
            Logger.shared.log("Failed to persist media state cache: \(error.localizedDescription)", type: "iCloud")

            _ = durablyRemoveEngineState(
                failureContext: "failed media-state archive persistence"
            )
            return false
        }
    }

    private func handleSyncError(_ error: Error) {
        let message: String
        if let ckError = error as? CKError {
            if MediaStateCloudKitSaveFailurePolicy.shouldRetryAutomatically(
                ckError.code
            ) {
                recordCloudKitTransientFailure(
                    codes: [ckError.code],
                    retryAfter: ckError.retryAfterSeconds
                )
            }
            switch ckError.code {
            case .notAuthenticated:
                message = "Sign in to iCloud to keep media state durable. Local changes will remain on this Apple TV."
            case .networkUnavailable, .networkFailure, .serviceUnavailable,
                 .requestRateLimited, .zoneBusy, .serverResponseLost,
                 .batchRequestFailed, .operationCancelled,
                 .accountTemporarilyUnavailable:
                message = "iCloud is temporarily unavailable. Eclipse will retry without blocking local playback."
            case .quotaExceeded:
                message = "The iCloud account has no available storage for Eclipse media state."
            default:
                message = "Media state sync is temporarily unavailable."
            }
        } else {
            message = "Media state sync is temporarily unavailable."
        }
        phase = .localOnly(message)
        lastErrorMessage = message
        Logger.shared.log("CloudKit media sync error category=\(String(describing: type(of: error)))", type: "iCloud")
    }

    private static func accountStatusMessage(_ status: CKAccountStatus) -> String {
        switch status {
        case .noAccount:
            return "Sign in to iCloud to keep media state durable. Eclipse remains usable locally."
        case .restricted:
            return "iCloud access is restricted for this Apple TV user. Eclipse remains usable locally."
        case .temporarilyUnavailable, .couldNotDetermine:
            return "iCloud account status is temporarily unavailable. Eclipse will retry later."
        case .available:
            return "iCloud is available."
        @unknown default:
            return "iCloud account status could not be determined. Eclipse remains usable locally."
        }
    }

    private static var storageDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MediaStateSync", isDirectory: true)
    }

    private static var archiveURL: URL {
        storageDirectory.appendingPathComponent("records.json")
    }

    private static var accountBoundaryRecoveryURL: URL {
        storageDirectory.appendingPathComponent("account-boundary-recovery.json")
    }

    private static var engineStateURL: URL {
        storageDirectory.appendingPathComponent("engine-state.json")
    }

    private static func ensureStorageDirectory() throws {
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
    }

    private static func boundedLocalData(
        at url: URL,
        maximumBytes: Int
    ) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              (values.fileSize ?? 0) <= maximumBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: maximumBytes + 1),
              data.count <= maximumBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }

    private static func loadArchive() -> MediaStateLocalArchiveLoadResult {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: archiveURL.path)
        } catch let error as CocoaError
            where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            return .unavailable(
                "Existing media state could not be inspected. Eclipse will retry without replacing it."
            )
        }

        do {
            let data = try boundedLocalData(
                at: archiveURL,
                maximumBytes: maximumArchiveBytes
            )
            guard let value = decodeArchive(data) else {
                return .unavailable(
                    "Existing media state is invalid or incompatible. Eclipse will not overwrite it."
                )
            }
            return .loaded(value)
        } catch {
            return .unavailable(
                "Existing media state is protected or temporarily unreadable. Eclipse will retry when data becomes available."
            )
        }
    }

    private static func loadEngineState(
        expectedAccountOwnerRecordName: String
    ) -> CKSyncEngine.State.Serialization? {
        guard let data = try? boundedLocalData(
                at: engineStateURL,
                maximumBytes: maximumEngineStateBytes
              ),
              let document = try? JSONDecoder().decode(
                MediaStateEngineStateDocument.self,
                from: data
              ),
              document.schemaVersion == MediaStateEngineStateDocument.currentSchemaVersion,
              document.accountOwnerRecordName == expectedAccountOwnerRecordName else {

            return nil
        }
        return document.serialization
    }

    private static func repairedArchiveRecords(
        _ records: [String: MediaStateEnvelope]
    ) -> [String: MediaStateEnvelope] {
        var repaired = records
        for (recordName, envelope) in records {
            let candidate = MediaStateEnvelopeValidator.normalizingImplausibleClocks(
                of: MediaStateCloudKitArchiveMigration.repaired(envelope)
            )
            if let reason = MediaStateEnvelopeValidator.rejectionReason(
                for: candidate,
                dictionaryKey: recordName,
                allowsSystemFields: true
            ) {
                repaired.removeValue(forKey: recordName)
                Logger.shared.log(
                    "MediaStateSync: dropped invalid archived record \(recordName) (\(reason))",
                    type: "Error"
                )
            } else {
                repaired[recordName] = candidate
            }
        }
        if repaired.values.lazy.filter({ $0.kind == .profile && !$0.isDeleted }).count
            > ProfileManager.maximumProfiles {

            Logger.shared.log(
                "MediaStateSync: archived roster exceeds \(ProfileManager.maximumProfiles) live profiles; loaded it and left the cap to the roster merge",
                type: "Error"
            )
        }
        return repaired
    }

    private static func decodeArchive(_ data: Data) -> MediaStateLocalArchive? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard var archive = try? decoder.decode(MediaStateLocalArchive.self, from: data) else {
            return nil
        }
        archive.records = repairedArchiveRecords(archive.records)
        return archive
    }

    private static func decodeAccountBoundaryRecoverySidecar(
        _ data: Data
    ) -> MediaStateRemoteAccountBoundaryRecoverySidecar? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let sidecar = try? decoder.decode(
            MediaStateRemoteAccountBoundaryRecoverySidecar.self,
            from: data
        ), sidecar.schemaVersion == MediaStateRemoteAccountBoundaryRecoverySidecar.currentSchemaVersion else {
            return nil
        }
        var archive = sidecar.archive
        archive.records = repairedArchiveRecords(archive.records)
        return MediaStateRemoteAccountBoundaryRecoverySidecar(
            transactionID: sidecar.transactionID,
            archive: archive
        )
    }
}

@available(iOS 17.0, tvOS 17.0, *)
extension MediaStateSyncManager: CKSyncEngineDelegate {
    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            await MainActor.run {
                guard engine === syncEngine,
                      MediaStateSyncBootstrap.isCloudKitSyncEnabled,
                      !isPreparedRecoverySyncBlocked else { return }
                stageEngineState(update.stateSerialization)
            }
        case .accountChange(let change):
            await MainActor.run {
                guard engine === syncEngine,
                      MediaStateSyncBootstrap.isCloudKitSyncEnabled,
                      !isPreparedRecoverySyncBlocked else { return }
                resetForAccountChange(change.changeType)
            }
        case .fetchedDatabaseChanges(let changes):
            await MainActor.run {
                guard engine === syncEngine,
                      MediaStateSyncBootstrap.isCloudKitSyncEnabled,
                      !isPreparedRecoverySyncBlocked else { return }
                receiveFetchedDatabaseChanges(changes)
            }
        case .fetchedRecordZoneChanges(let changes):
            await MainActor.run {
                guard engine === syncEngine,
                      MediaStateSyncBootstrap.isCloudKitSyncEnabled,
                      !isPreparedRecoverySyncBlocked else { return }
                receiveFetchedChanges(changes)
            }
        case .sentDatabaseChanges(let changes):
            await MainActor.run {
                guard engine === syncEngine,
                      MediaStateSyncBootstrap.isCloudKitSyncEnabled,
                      !isPreparedRecoverySyncBlocked else { return }
                receiveSentDatabaseChanges(changes)
            }
        case .sentRecordZoneChanges(let changes):
            await MainActor.run {
                guard engine === syncEngine,
                      MediaStateSyncBootstrap.isCloudKitSyncEnabled,
                      !isPreparedRecoverySyncBlocked else { return }
                receiveSentChanges(changes)
            }
        case .didFetchChanges:
            await MainActor.run {
                guard engine === syncEngine,
                      MediaStateSyncBootstrap.isCloudKitSyncEnabled,
                      !isPreparedRecoverySyncBlocked else { return }

                guard persistArchive() else { return }
                persistPendingEngineStateAfterDurableArchive()
                if initialFetchCompleted,
                   !hasPendingAccountIsolationJournal,
                   !isAccountIsolationInProgress,
                   archive.pendingLocalRecordNames.isEmpty {
                    lastSyncDate = Date()
                    phase = .ready
                    lastErrorMessage = nil
                }
            }
        case .didSendChanges:
            await MainActor.run {
                guard engine === syncEngine,
                      MediaStateSyncBootstrap.isCloudKitSyncEnabled,
                      !isPreparedRecoverySyncBlocked,
                      !hasPendingAccountIsolationJournal,
                      !isAccountIsolationInProgress else { return }
                guard persistArchive() else { return }
                persistPendingEngineStateAfterDurableArchive()
                if archive.pendingLocalRecordNames.isEmpty {
                    clearCloudKitTransientFailure()
                    lastSyncDate = Date()
                    phase = .ready
                    lastErrorMessage = nil
                }
            }
        default:
            break
        }
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let mayMaterializeRecords = await MainActor.run {
            self.engine === syncEngine
                && MediaStateSyncBootstrap.isCloudKitSyncEnabled
                && !self.isPreparedRecoverySyncBlocked
                && !self.hasPendingAccountIsolationJournal
                && !self.isAccountIsolationInProgress
        }
        guard mayMaterializeRecords else { return nil }
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { [weak self] recordID in
            await self?.record(for: recordID)
        }
    }

    nonisolated func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        var options = context.options
        let currentZoneID = self.zoneID
        options.scope = .zoneIDs([currentZoneID])
        return options
    }
}

@available(iOS 17.0, tvOS 17.0, *)
enum MediaStateCloudKitRecordCodec {
    static func envelope(from record: CKRecord) -> MediaStateEnvelope? {
        guard let kindRaw = record["kind"] as? String,
              let kind = MediaStateKind(rawValue: kindRaw),
              let wirePayload = record["payload"] as? Data,
              let decodedPayload = MediaStateCloudKitPayloadCodec.decode(wirePayload),
              let modifiedAt = record["modifiedAt"] as? Date else {
            return nil
        }
        let isCompleted = (record["isCompleted"] as? NSNumber)?.boolValue ?? false
        let isExplicitReset = (record["isExplicitReset"] as? NSNumber)?.boolValue ?? false
        let decodedResetAt = decodedPayload.resetAt
            ?? ((kind == .movieProgress || kind == .episodeProgress) && isExplicitReset
                ? modifiedAt
                : nil)
        let resetAt = MediaStateCloudKitPayloadCodec.resetAtClampedForWirePrecision(
            decodedResetAt,
            modifiedAt: modifiedAt
        )
        let candidate = MediaStateEnvelope(
            recordName: record.recordID.recordName,
            kind: kind,
            payload: decodedPayload.payload,
            modifiedAt: modifiedAt,
            deletedAt: record["deletedAt"] as? Date,
            revision: (record["revision"] as? NSNumber)?.int64Value ?? 1,
            settingScope: MediaStateSettingScope(rawValue: record["settingScope"] as? String ?? "shared") ?? .shared,
            isCompleted: isCompleted,
            isExplicitReset: isExplicitReset,
            resetAt: resetAt,
            schemaVersion: (record["schemaVersion"] as? NSNumber)?.intValue ?? 1
        )

        let repaired = MediaStateEnvelopeValidator.normalizingImplausibleClocks(of: candidate)
        guard MediaStateEnvelopeValidator.rejectionReason(
            for: repaired,
            dictionaryKey: record.recordID.recordName,
            allowsSystemFields: true
        ) == nil else {
            return nil
        }
        return repaired
    }

    static func record(
        from envelope: MediaStateEnvelope,
        recordID: CKRecord.ID,
        recordType: CKRecord.RecordType
    ) -> CKRecord? {
        let effectiveResetAt = envelope.resetAt
            ?? (envelope.isExplicitReset ? envelope.modifiedAt : nil)
        guard let wirePayload = MediaStateCloudKitPayloadCodec.encode(
            payload: envelope.payload,
            resetAt: effectiveResetAt
        ) else {
            return nil
        }
        let record = envelope.systemFields.flatMap { CKRecord.record(fromSystemFields: $0) }
            ?? CKRecord(recordType: recordType, recordID: recordID)
        record["kind"] = envelope.kind.rawValue as CKRecordValue
        record["payload"] = wirePayload as CKRecordValue
        record["modifiedAt"] = envelope.modifiedAt as CKRecordValue
        record["revision"] = NSNumber(value: envelope.revision)
        record["settingScope"] = envelope.settingScope.rawValue as CKRecordValue
        record["isCompleted"] = NSNumber(value: envelope.isCompleted)
        record["isExplicitReset"] = NSNumber(value: envelope.isExplicitReset)
        record["schemaVersion"] = NSNumber(value: envelope.schemaVersion)
        if let deletedAt = envelope.deletedAt {
            record["deletedAt"] = deletedAt as CKRecordValue
        } else {
            record["deletedAt"] = nil
        }
        return record
    }
}

@available(iOS 17.0, tvOS 17.0, *)
private extension MediaStateEnvelope {
    init?(record: CKRecord) {
        guard let envelope = MediaStateCloudKitRecordCodec.envelope(from: record) else {
            return nil
        }
        self = envelope
    }

    func makeRecord(
        recordID: CKRecord.ID,
        recordType: CKRecord.RecordType
    ) -> CKRecord? {
        MediaStateCloudKitRecordCodec.record(
            from: self,
            recordID: recordID,
            recordType: recordType
        )
    }
}

@available(iOS 17.0, tvOS 17.0, *)
private extension CKRecord {
    var encodedSystemFields: Data? {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        return CKRecord(coder: unarchiver)
    }
}
