import CloudKit
import Combine
import Foundation

enum MediaStatePlaybackLease {
    private static let lock = NSLock()
    private static var counter = MediaStatePlaybackLeaseCounter()

    static var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return counter.activeSessionCount > 0
    }

    static func begin() {
        lock.lock()
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

enum MediaStateSyncBootstrap {
    static var hasCloudKitEntitlement: Bool {
#if targetEnvironment(simulator) || ECLIPSE_UNSIGNED_BUILD
        // CKContainer traps before throwing when the running app has no iCloud
        // entitlement. Simulators and Eclipse's unsigned IPA lanes therefore
        // exercise the offline cache path; signed device/TestFlight builds
        // exercise CKSyncEngine with the target entitlement.
        return false
#else
        return true
#endif
    }

    static func startIfAvailable() {
        if #available(iOS 17.0, tvOS 17.0, *), hasCloudKitEntitlement {
            if Thread.isMainThread {
                // SwiftUI constructs the app on the main thread. Run the local
                // identity veto before its first view can read account-scoped
                // manager files; the fallback keeps unusual callers safe.
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

    static func syncOnActivation() {
        if #available(iOS 17.0, tvOS 17.0, *), hasCloudKitEntitlement {
            Task { @MainActor in
                MediaStateSyncManager.shared.syncNow()
            }
        }
    }
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
    private static let maxPayloadBytes = 800 * 1024

    private lazy var container = CKContainer(identifier: Self.containerIdentifier)
    private let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var engine: CKSyncEngine?
    private var archive: MediaStateLocalArchive
    private var started = false
    private var isPreparingEngine = false
    private var accountPreparationGeneration = 0
    private var isAccountRevalidationInProgress = false
    private var initialFetchCompleted = false
    private var isTrustedOfflineCacheActive = false
    private var initialLocalStatePolicy: MediaStateInitialLocalStatePolicy = .migrateLocalState
    private var isAccountIsolationInProgress = false
    private var verifiedAccountRecordName: String?
    private var suppressedDefaultRecordNames: Set<String> = []
    private var isApplyingRemoteState = false
    private var hasDeferredRemoteApply = false
    private var captureTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    private override init() {
        archive = Self.loadArchive()
        super.init()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
        if !MediaStateSyncBootstrap.hasCloudKitEntitlement {
            phase = .localOnly("This build has no iCloud entitlement. Eclipse remains usable with local media state.")
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        captureTask?.cancel()
    }

    func start() {
        guard !started else { return }
        started = true
        installObservers()
        if !archive.isAccountNeutralLocalStateActive {
            switch MediaStateLaunchCachePolicy.action(
                hasAccountOwner: archive.accountOwnerRecordName != nil,
                evidence: launchIdentityEvidence()
            ) {
            case .restoreOwnedCache where !archive.records.isEmpty:
                // A matching local identity token permits same-account offline
                // restore, but never authorizes a CloudKit engine or upload.
                isTrustedOfflineCacheActive = true
                applyArchiveToManagersOrDefer()
            case .isolateLoadedState:
                isAccountIsolationInProgress = true
                isolateLoadedStateOrDefer()
                archive.isAccountNeutralLocalStateActive = true
                persistArchive()
            case .restoreOwnedCache, .awaitCloudKitVerification:
                // Legacy/unknown ownership must not overwrite the managers before
                // CloudKit supplies the current-user record ID. Existing manager
                // files remain available for an offline same-account launch.
                break
            }
        }
        phase = .checkingAccount

        Task {
            await prepareEngineAndFetch()
        }
    }

    func syncNow() {
        guard started else {
            start()
            return
        }
        guard !isPreparingEngine else { return }
        guard let engine else {
            // A launch while signed out/offline never created an engine. Retry
            // must recheck the account instead of becoming a permanent no-op.
            Task { await prepareEngineAndFetch() }
            return
        }
        Task {
            do {
                try await engine.fetchChanges()
                if initialFetchCompleted {
                    captureAndQueueLocalChanges()
                } else {
                    completeInitialFetch()
                }
                try await engine.sendChanges()
                lastSyncDate = Date()
                phase = .ready
                lastErrorMessage = nil
            } catch {
                handleSyncError(error)
            }
        }
    }

    func resetLocalCacheWithoutDeletingRemoteState() {
        captureTask?.cancel()
        archive = .empty
        initialFetchCompleted = false
        isTrustedOfflineCacheActive = false
        initialLocalStatePolicy = .migrateLocalState
        isAccountIsolationInProgress = false
        verifiedAccountRecordName = nil
        suppressedDefaultRecordNames = []
        try? FileManager.default.removeItem(at: Self.archiveURL)
        try? FileManager.default.removeItem(at: Self.engineStateURL)
        phase = .fetching
        Task {
            await engine?.cancelOperations()
            engine = nil
            await prepareEngineAndFetch()
        }
    }

#if os(iOS)
    /// Legacy iCloud Documents snapshots also contain reader data. Preserve the
    /// live streaming domains around that whole-snapshot restore so a first run
    /// with no CK archive cannot treat older media fields as new local state.
    func performLegacySnapshotRestorePreservingMediaState(
        _ restore: () -> Bool
    ) -> Bool {
        captureTask?.cancel()
        let preservedMediaState = buildLocalSnapshot()
        let authoritativeCloudRecords = archive.records
        let succeeded = restore()
        guard succeeded else { return false }

        archive.records = preservedMediaState
        applyArchiveToManagers()
        archive.records = authoritativeCloudRecords
        archive.lastLocalRecordNames = Set(buildLocalSnapshot().keys)
        persistArchive()
        syncNow()
        return true
    }

#endif

    // MARK: - Engine setup

    private func prepareEngineAndFetch() async {
        guard MediaStateSyncBootstrap.hasCloudKitEntitlement else {
            phase = .localOnly("This build has no iCloud entitlement. Eclipse remains usable with local media state.")
            return
        }
        guard !isPreparingEngine else { return }
        let preparationGeneration = accountPreparationGeneration
        isPreparingEngine = true
        defer {
            if preparationGeneration == accountPreparationGeneration {
                isPreparingEngine = false
            }
        }
        do {
            let accountStatus = try await container.accountStatus()
            guard preparationGeneration == accountPreparationGeneration else { return }
            guard accountStatus == .available else {
                if accountStatus == .noAccount {
                    beginSignedOutIsolation()
                }
                phase = .localOnly(Self.accountStatusMessage(accountStatus))
                return
            }

            // `accountStatus == .available` is not an account identity. Resolve
            // the current user's stable CloudKit record name before loading a
            // serialized engine token or touching the private database.
            let currentUser = try await container.userRecordID()
            guard preparationGeneration == accountPreparationGeneration else { return }
            let currentAccountRecordName = currentUser.recordName
            let previousAccountRecordName = archive.accountOwnerRecordName
            let isSameKnownAccount = previousAccountRecordName == currentAccountRecordName
            let serializedEngineState = isSameKnownAccount ? Self.loadEngineState() : nil

            if let previousAccountRecordName,
               previousAccountRecordName != currentAccountRecordName {
                MediaStateAccountPlaybackBoundary.notifyWillChangeUser(sender: self)
                captureTask?.cancel()
                initialFetchCompleted = false
                isTrustedOfflineCacheActive = false
                initialLocalStatePolicy = .isolateIncomingAccount
                isAccountIsolationInProgress = true
                isolateLoadedStateOrDefer()
                archive = .empty
                try? FileManager.default.removeItem(at: Self.engineStateURL)
            } else if previousAccountRecordName == nil {
                // An ownerless archive predates account isolation. Preserve the
                // managers as first-sign-in local state, but refetch the remote
                // cache from scratch so an unowned serialized token can never
                // select another private database.
                archive = .empty
                try? FileManager.default.removeItem(at: Self.engineStateURL)
                initialLocalStatePolicy = .migrateLocalState
                isAccountIsolationInProgress = false
            } else {
                initialLocalStatePolicy = .migrateLocalState
                if !MediaStatePlaybackLease.isActive {
                    isAccountIsolationInProgress = false
                }
            }

            archive.accountOwnerRecordName = currentAccountRecordName
            archive.ubiquityIdentityTokenData = Self.currentUbiquityIdentityTokenData()
            verifiedAccountRecordName = currentAccountRecordName
            persistArchive()

            var configuration = CKSyncEngine.Configuration(
                database: container.privateCloudDatabase,
                stateSerialization: serializedEngineState,
                delegate: self
            )
            configuration.automaticallySync = true
            configuration.subscriptionID = Self.subscriptionID
            let engine = CKSyncEngine(configuration)
            self.engine = engine

            try await ensureRecordZone(in: engine.database)
            guard preparationGeneration == accountPreparationGeneration else { return }
            phase = .fetching
            try await engine.fetchChanges()
            guard preparationGeneration == accountPreparationGeneration else { return }
            completeInitialFetch()
            try await engine.sendChanges()
            guard preparationGeneration == accountPreparationGeneration else { return }
            lastSyncDate = Date()
            phase = .ready
            lastErrorMessage = nil
        } catch {
            if preparationGeneration == accountPreparationGeneration {
                handleSyncError(error)
            }
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

    private func beginSignedOutIsolation() {
        guard archive.accountOwnerRecordName != nil || isTrustedOfflineCacheActive else {
            return
        }
        if archive.isAccountNeutralLocalStateActive {
            initialFetchCompleted = false
            isTrustedOfflineCacheActive = false
            verifiedAccountRecordName = nil
            return
        }
        MediaStateAccountPlaybackBoundary.notifyWillChangeUser(sender: self)
        captureTask?.cancel()
        initialFetchCompleted = false
        isTrustedOfflineCacheActive = false
        verifiedAccountRecordName = nil
        initialLocalStatePolicy = .isolateIncomingAccount
        isAccountIsolationInProgress = true
        isolateLoadedStateOrDefer()
        if !MediaStatePlaybackLease.isActive {
            archive.isAccountNeutralLocalStateActive = true
        }
        persistArchive()
        if !MediaStatePlaybackLease.isActive {
            isAccountIsolationInProgress = false
        }
    }

    private func beginAccountIdentityRevalidation() {
        guard !isAccountRevalidationInProgress else { return }
        isAccountRevalidationInProgress = true
        let localStateAlreadyAccountNeutral = archive.isAccountNeutralLocalStateActive

        // Account notifications do not identify the replacement user. Freeze
        // all account-scoped UI/playback first, then let userRecordID decide
        // whether the quarantined archive may be restored or must be discarded.
        MediaStateAccountPlaybackBoundary.notifyWillChangeUser(sender: self)
        captureTask?.cancel()
        initialFetchCompleted = false
        isTrustedOfflineCacheActive = false
        verifiedAccountRecordName = nil
        initialLocalStatePolicy = .isolateIncomingAccount
        if localStateAlreadyAccountNeutral {
            // These managers contain signed-out/unverified local edits, not the
            // cached owner's state. Preserve them until userRecordID decides:
            // same owner migrates them, a different owner clears them below.
            isAccountIsolationInProgress = false
        } else {
            isAccountIsolationInProgress = true
            isolateLoadedStateOrDefer()
            if !MediaStatePlaybackLease.isActive {
                archive.isAccountNeutralLocalStateActive = true
            }
        }
        persistArchive()

        let staleEngine = engine
        engine = nil
        accountPreparationGeneration &+= 1
        // The superseded preparation checks its generation after every await
        // and must not keep a newer preparation locked out.
        isPreparingEngine = false
        phase = .checkingAccount

        Task { [weak self] in
            await staleEngine?.cancelOperations()
            guard let self else { return }
            await self.prepareEngineAndFetch()
            self.isAccountRevalidationInProgress = false
        }
    }

    private func completeInitialFetch() {
        let fullLocalSnapshot = buildLocalSnapshot()
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
        suppressedDefaultRecordNames = defaultRecordNames.subtracting(Set(archive.records.keys))

        applyArchiveToManagersOrDefer()
        if localStatePolicy == .isolateIncomingAccount,
           !MediaStatePlaybackLease.isActive {
            isAccountIsolationInProgress = false
        }
        archive.lastLocalRecordNames = Set(buildLocalSnapshot().keys)
        archive.isAccountNeutralLocalStateActive = false
        initialFetchCompleted = true
        isTrustedOfflineCacheActive = false
        initialLocalStatePolicy = .migrateLocalState
        persistArchive()
        queueRecordSaves(Array(Set(merge.pendingRecordNames).union(archive.pendingLocalRecordNames)))
    }

    // MARK: - Local observation

    private func installObservers() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .progressDataDidChange,
            .libraryDataDidChange,
            .userRatingDataDidChange,
            .catalogDataDidChange,
            UserDefaults.didChangeNotification
        ]

        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleLocalCapture() }
            })
        }

        for name in [Notification.Name.CKAccountChanged, .NSUbiquityIdentityDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // `queue: .main` is deliberate: account isolation and player
                // finalization must happen synchronously in this callback.
                MainActor.assumeIsolated {
                    self?.beginAccountIdentityRevalidation()
                }
            })
        }

        for name in [Notification.Name.playerDidClose, .mediaStatePlaybackLeaseDidEnd] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.hasDeferredRemoteApply, !MediaStatePlaybackLease.isActive else { return }
                    self.hasDeferredRemoteApply = false
                    if self.isAccountIsolationInProgress {
                        // Playback may have written one last outgoing-account
                        // position after the switch. Clear it again before the
                        // incoming archive becomes the live source of truth.
                        self.replaceLoadedStateWithAccountNeutralState()
                        if self.verifiedAccountRecordName == nil {
                            self.archive.isAccountNeutralLocalStateActive = true
                        }
                    }
                    if let verifiedAccountRecordName = self.verifiedAccountRecordName,
                       verifiedAccountRecordName == self.archive.accountOwnerRecordName {
                        self.applyArchiveToManagers()
                    }
                    self.isAccountIsolationInProgress = false
                    self.archive.lastLocalRecordNames = Set(self.buildLocalSnapshot().keys)
                    self.persistArchive()
                }
            })
        }
    }

    private func scheduleLocalCapture() {
        guard (initialFetchCompleted || isTrustedOfflineCacheActive),
              !isApplyingRemoteState,
              !isAccountIsolationInProgress else { return }
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_250_000_000)
            guard !Task.isCancelled else { return }
            self?.captureAndQueueLocalChanges()
        }
    }

    private func captureAndQueueLocalChanges() {
        guard (initialFetchCompleted || isTrustedOfflineCacheActive),
              !isApplyingRemoteState,
              !isAccountIsolationInProgress else { return }
        let now = Date()
        let current = buildLocalSnapshot()
        let currentlyDefaultRecordNames = defaultRecordNamesForInitialMigration(in: current)
        var pendingNames: [String] = []

        for (recordName, candidate) in current {
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
                changed.revision = existing.revision + 1
                changed.systemFields = existing.systemFields
                changed.isExplicitReset = progressWasExplicitlyReset(from: existing, to: candidate)
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

        let removedNames = archive.lastLocalRecordNames.subtracting(Set(current.keys))
        for recordName in removedNames {
            guard let existing = archive.records[recordName] else { continue }
            archive.records[recordName] = existing.tombstone(at: now)
            pendingNames.append(recordName)
        }

        archive.lastLocalRecordNames = Set(current.keys)
        archive.pendingLocalRecordNames.formUnion(pendingNames)
        persistArchive()
        queueRecordSaves(pendingNames)
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
        let uniqueNames = Set(names)
        guard !uniqueNames.isEmpty else { return }
        archive.pendingLocalRecordNames.formUnion(uniqueNames)
        persistArchive()
        guard let engine else { return }
        let changes = uniqueNames.compactMap { name -> CKSyncEngine.PendingRecordZoneChange? in
            guard let envelope = archive.records[name], envelope.payload.count <= Self.maxPayloadBytes else {
                Logger.shared.log("CloudKit media record skipped because its payload is too large name=\(name)", type: "iCloud")
                return nil
            }
            let recordID = CKRecord.ID(recordName: name, zoneID: zoneID)
            return .saveRecord(recordID)
        }
        engine.state.add(pendingRecordZoneChanges: changes)

        Task {
            do {
                try await engine.sendChanges()
                lastSyncDate = Date()
                phase = .ready
            } catch {
                handleSyncError(error)
            }
        }
    }

    // MARK: - Snapshot construction

    private func buildLocalSnapshot() -> [String: MediaStateEnvelope] {
        var result: [String: MediaStateEnvelope] = [:]
        addLibraryRecords(to: &result)
        addProgressRecords(to: &result)
        addRatingRecords(to: &result)
        addSettingRecords(to: &result)
        addCatalogRecord(to: &result)
        return result
    }

    /// Identifies records generated merely by manager initialization or
    /// UserDefaults registration. These stay local until the user makes a
    /// meaningful change, at which point live capture stops suppressing them.
    private func defaultRecordNamesForInitialMigration(
        in snapshot: [String: MediaStateEnvelope]
    ) -> Set<String> {
        var result: Set<String> = []

        if let bookmarksIndex = LibraryManager.shared.collections.firstIndex(where: {
            $0.name.caseInsensitiveCompare("Bookmarks") == .orderedSame
        }) {
            let bookmarks = LibraryManager.shared.collections[bookmarksIndex]
            let isPristineDefault = bookmarksIndex == 0 &&
                bookmarks.items.isEmpty &&
                bookmarks.description == "Your bookmarked items"
            if isPristineDefault {
                let name = MediaStateRecordName.make(kind: .libraryCollection, identifier: "bookmarks")
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
            // Failing closed avoids interpreting registration defaults as user
            // choices in unusual test/extension processes without a bundle ID.
            persistentSettingKeys = []
        }

        for key in MediaStateSettingRegistry.allKeys where !persistentSettingKeys.contains(key) {
            let name = MediaStateRecordName.make(kind: .setting, identifier: key)
            if snapshot[name] != nil {
                result.insert(name)
            }
        }

        if !CatalogManager.shared.hasMeaningfulLocalCustomization {
            let name = MediaStateRecordName.make(kind: .catalogOrder, identifier: "home")
            if snapshot[name] != nil {
                result.insert(name)
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
    }

    private struct RatingPayload: Codable {
        let tmdbID: Int
        let rating: Double?
        let note: String?
    }

    private struct BooleanPayload: Codable {
        let value: Bool
    }

    private func addLibraryRecords(to result: inout [String: MediaStateEnvelope]) {
        for (order, collection) in LibraryManager.shared.collections.enumerated() {
            let collectionKey = mediaCollectionKey(collection)
            let payload = LibraryCollectionPayload(
                id: collection.id,
                key: collectionKey,
                name: collection.name,
                description: collection.description,
                order: order
            )
            guard let data = try? encoder.encode(payload) else { continue }
            let name = MediaStateRecordName.make(kind: .libraryCollection, identifier: collectionKey)
            result[name] = MediaStateEnvelope(
                recordName: name,
                kind: .libraryCollection,
                payload: data,
                modifiedAt: collection.items.map(\.dateAdded).max() ?? .distantPast
            )

            for item in collection.items {
                let membership = LibraryMembershipPayload(collectionKey: collectionKey, item: item)
                guard let itemData = try? encoder.encode(membership) else { continue }
                let itemName = MediaStateRecordName.make(
                    kind: .libraryMembership,
                    identifier: "\(collectionKey):\(item.id)"
                )
                result[itemName] = MediaStateEnvelope(
                    recordName: itemName,
                    kind: .libraryMembership,
                    payload: itemData,
                    modifiedAt: item.dateAdded
                )
            }
        }
    }

    private func addProgressRecords(to result: inout [String: MediaStateEnvelope]) {
        let progress = ProgressManager.shared.getProgressData()
        for movie in progress.movieProgress {
            var sanitizedMovie = movie
            sanitizedMovie.lastHref = nil
            guard let data = try? encoder.encode(sanitizedMovie) else { continue }
            let name = MediaStateRecordName.make(kind: .movieProgress, identifier: String(sanitizedMovie.id))
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
            guard let data = try? encoder.encode(sanitizedEpisode) else { continue }
            let name = MediaStateRecordName.make(kind: .episodeProgress, identifier: sanitizedEpisode.id)
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
            let name = MediaStateRecordName.make(kind: .showMetadata, identifier: String(showID))
            result[name] = MediaStateEnvelope(
                recordName: name,
                kind: .showMetadata,
                payload: data,
                modifiedAt: .distantPast
            )
        }
        for showID in progress.hiddenUpNextShowIds {
            guard let data = try? encoder.encode(BooleanPayload(value: true)) else { continue }
            let name = MediaStateRecordName.make(kind: .hiddenUpNext, identifier: String(showID))
            result[name] = MediaStateEnvelope(
                recordName: name,
                kind: .hiddenUpNext,
                payload: data,
                modifiedAt: .distantPast
            )
        }
    }

    private func addRatingRecords(to result: inout [String: MediaStateEnvelope]) {
        let ratings = UserRatingManager.shared.getRatingsForBackup()
        let notes = UserRatingManager.shared.getNotesForBackup()
        let identifiers = Set(ratings.keys).union(notes.keys)
        for identifier in identifiers {
            guard let tmdbID = Int(identifier) else { continue }
            let payload = RatingPayload(tmdbID: tmdbID, rating: ratings[identifier], note: notes[identifier])
            guard let data = try? encoder.encode(payload) else { continue }
            let name = MediaStateRecordName.make(kind: .rating, identifier: identifier)
            result[name] = MediaStateEnvelope(
                recordName: name,
                kind: .rating,
                payload: data,
                modifiedAt: .distantPast
            )
        }
    }

    private func addSettingRecords(to result: inout [String: MediaStateEnvelope]) {
        let defaults = UserDefaults.standard
        for key in MediaStateSettingRegistry.allKeys.sorted() {
            guard let scope = MediaStateSettingRegistry.scope(for: key),
                  scope.appliesToCurrentPlatform,
                  let value = defaults.object(forKey: key),
                  let data = propertyListData(for: value) else {
                continue
            }
            let name = MediaStateRecordName.make(kind: .setting, identifier: key)
            result[name] = MediaStateEnvelope(
                recordName: name,
                kind: .setting,
                payload: data,
                modifiedAt: .distantPast,
                settingScope: scope
            )
        }
    }

    private func addCatalogRecord(to result: inout [String: MediaStateEnvelope]) {
        guard let data = try? encoder.encode(CatalogManager.shared.catalogsForMediaStateSync) else { return }
        let name = MediaStateRecordName.make(kind: .catalogOrder, identifier: "home")
        result[name] = MediaStateEnvelope(
            recordName: name,
            kind: .catalogOrder,
            payload: data,
            modifiedAt: .distantPast
        )
    }

    // MARK: - Applying merged state

    private func applyArchiveToManagersOrDefer() {
        if MediaStatePlaybackLease.isActive {
            hasDeferredRemoteApply = true
        } else {
            applyArchiveToManagers()
        }
    }

    private func isolateLoadedStateOrDefer() {
        if MediaStatePlaybackLease.isActive {
            hasDeferredRemoteApply = true
        } else {
            replaceLoadedStateWithAccountNeutralState()
        }
    }

    private func applyArchiveToManagers() {
        isApplyingRemoteState = true
        defer { isApplyingRemoteState = false }

        applyLibraryRecords()
        applyProgressRecords()
        applyRatingRecords()
        applySettingRecords()
        applyCatalogRecord()
        NotificationCenter.default.post(name: .mediaStateDidRestore, object: self)
    }

    private func activeRecords(of kind: MediaStateKind) -> [MediaStateEnvelope] {
        archive.records.values.filter {
            $0.kind == kind && !$0.isDeleted && $0.settingScope.appliesToCurrentPlatform
        }
    }

    private func applyLibraryRecords() {
        let allRecords = Array(archive.records.values)
        guard MediaStateLibraryRestorePolicy.hasCollectionDefinitionHistory(in: allRecords) else {
            return
        }

        let definitions = activeRecords(of: .libraryCollection).compactMap {
            try? decoder.decode(LibraryCollectionPayload.self, from: $0.payload)
        }

        let memberships = activeRecords(of: .libraryMembership).compactMap {
            try? decoder.decode(LibraryMembershipPayload.self, from: $0.payload)
        }
        let groupedItems = Dictionary(grouping: memberships, by: \.collectionKey)

        let collections = definitions.sorted { $0.order < $1.order }.map { definition in
            LibraryCollection(
                id: definition.id,
                name: definition.name,
                items: (groupedItems[definition.key] ?? []).map(\.item).sorted { $0.dateAdded < $1.dateAdded },
                description: definition.description
            )
        }
        LibraryManager.shared.replaceCollectionsForMediaState(collections)
    }

    private func applyProgressRecords() {
        let currentProgress = ProgressManager.shared.getProgressData()
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
        progress.movieProgress = activeRecords(of: .movieProgress).compactMap {
            try? decoder.decode(MovieProgressEntry.self, from: $0.payload)
        }.map { incoming in
            var merged = incoming
            merged.lastHref = currentMovies[incoming.id]?.lastHref
            merged.lastServiceId = currentMovies[incoming.id]?.lastServiceId ?? incoming.lastServiceId
            return merged
        }
        progress.episodeProgress = activeRecords(of: .episodeProgress).compactMap {
            try? decoder.decode(EpisodeProgressEntry.self, from: $0.payload)
        }.map { incoming in
            var merged = incoming
            merged.lastHref = currentEpisodes[incoming.id]?.lastHref
            merged.lastServiceId = currentEpisodes[incoming.id]?.lastServiceId ?? incoming.lastServiceId
            return merged
        }
        progress.showMetadata = Dictionary(
            activeRecords(of: .showMetadata).compactMap { envelope in
                guard let value = try? decoder.decode(ShowMetadata.self, from: envelope.payload) else { return nil }
                return (value.showId, value)
            },
            uniquingKeysWith: { _, candidate in candidate }
        )
        progress.hiddenUpNextShowIds = Set(activeRecords(of: .hiddenUpNext).compactMap { envelope in
            MediaStateRecordName.identifier(from: envelope.recordName).flatMap(Int.init)
        })
        ProgressManager.shared.replaceProgressDataForRestore(progress)
    }

    private func applyRatingRecords() {
        var ratings: [String: Double] = [:]
        var notes: [String: String] = [:]
        for envelope in activeRecords(of: .rating) {
            guard let value = try? decoder.decode(RatingPayload.self, from: envelope.payload) else { continue }
            let key = String(value.tmdbID)
            ratings[key] = value.rating
            notes[key] = value.note
        }
        UserRatingManager.shared.restoreRatingsAndNotes(ratings: ratings, notes: notes)
    }

    private func applySettingRecords() {
#if os(iOS)
        let previousNotificationSubscriptions = UserDefaults.standard.string(
            forKey: LocalNotificationManager.subscriptionsStorageKey
        )
#endif
        MediaStateSettingRestorePolicy.apply(
            records: Array(archive.records.values),
            to: UserDefaults.standard
        )
        HomeCatalogLayoutStore.shared.reloadFromStorage()
        EclipseTheme.shared.reloadMediaAppearanceFromDefaults()
#if os(iOS)
        reloadLocalNotificationSelectionsIfNeeded(
            previousSubscriptions: previousNotificationSubscriptions
        )
#endif
    }

    private func applyCatalogRecord() {
        let allRecords = Array(archive.records.values)
        guard MediaStateCatalogRestorePolicy.hasCatalogOrderHistory(in: allRecords) else {
            return
        }

        guard let envelope = activeRecords(of: .catalogOrder).first,
              let catalogs = try? decoder.decode([Catalog].self, from: envelope.payload),
              !catalogs.isEmpty else {
            CatalogManager.shared.resetCatalogsForMediaStateAccountChange()
            return
        }
        CatalogManager.shared.replaceCatalogsForMediaState(catalogs.sorted { $0.order < $1.order })
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

    // MARK: - CKSyncEngineDelegate helpers

    private func receiveFetchedChanges(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        for modification in event.modifications where modification.record.recordID.zoneID == zoneID {
            guard var candidate = MediaStateEnvelope(record: modification.record) else { continue }
            candidate.systemFields = modification.record.encodedSystemFields
            if let existing = archive.records[candidate.recordName] {
                var merged = existing.merged(with: candidate)
                merged.systemFields = candidate.systemFields
                archive.records[candidate.recordName] = merged
            } else {
                archive.records[candidate.recordName] = candidate
            }
        }

        for deletion in event.deletions where deletion.recordID.zoneID == zoneID {
            if archive.pendingLocalRecordNames.contains(deletion.recordID.recordName) {
                // A locally recreated record that has not been acknowledged yet
                // must survive an older server deletion observed during the
                // initial catch-up fetch.
                continue
            }
            guard let existing = archive.records[deletion.recordID.recordName] else { continue }
            archive.records[deletion.recordID.recordName] = existing.tombstone()
        }
        persistArchive()
        if initialFetchCompleted {
            applyArchiveToManagersOrDefer()
        }
    }

    private func receiveSentChanges(_ event: CKSyncEngine.Event.SentRecordZoneChanges) {
        for record in event.savedRecords {
            archive.pendingLocalRecordNames.remove(record.recordID.recordName)
            guard var envelope = archive.records[record.recordID.recordName] else { continue }
            envelope.systemFields = record.encodedSystemFields
            archive.records[record.recordID.recordName] = envelope
        }

        var retryNames: [String] = []
        for failure in event.failedRecordSaves {
            guard let serverRecord = failure.error.serverRecord,
                  var serverEnvelope = MediaStateEnvelope(record: serverRecord) else {
                continue
            }
            serverEnvelope.systemFields = serverRecord.encodedSystemFields
            let recordName = failure.record.recordID.recordName
            if let localEnvelope = archive.records[recordName] {
                var merged = serverEnvelope.merged(with: localEnvelope)
                merged.systemFields = serverRecord.encodedSystemFields
                archive.records[recordName] = merged
                if merged != serverEnvelope {
                    retryNames.append(recordName)
                }
            } else {
                archive.records[recordName] = serverEnvelope
            }
        }
        persistArchive()
        if !retryNames.isEmpty {
            queueRecordSaves(retryNames)
        }
    }

    private func resetForAccountChange(
        _ changeType: CKSyncEngine.Event.AccountChange.ChangeType
    ) {
        let lastKnownAccountRecordName = archive.accountOwnerRecordName

        let shouldFetch: Bool
        switch changeType {
        case .signIn(let currentUser):
            // The identity-first setup already verified this user before it
            // constructed the engine. Ignore the engine's corresponding
            // bootstrap event instead of clearing/refetching the same cache.
            if verifiedAccountRecordName == currentUser.recordName {
                return
            }
            captureTask?.cancel()
            initialFetchCompleted = false
            isTrustedOfflineCacheActive = false
            suppressedDefaultRecordNames = []

            // A first sign-in remains a supported local-to-iCloud migration.
            // Signed-out edits migrate only when returning to the same known
            // account. A different private database is an isolation boundary.
            initialLocalStatePolicy = MediaStateAccountTransitionPolicy.signInPolicy(
                lastKnownAccountRecordName: lastKnownAccountRecordName,
                currentAccountRecordName: currentUser.recordName,
                requiresIsolation: false
            )

            if initialLocalStatePolicy == .isolateIncomingAccount {
                MediaStateAccountPlaybackBoundary.notifyWillChangeUser(sender: self)
                isAccountIsolationInProgress = true
                isolateLoadedStateOrDefer()
                archive = .empty
                try? FileManager.default.removeItem(at: Self.engineStateURL)
            } else if lastKnownAccountRecordName == nil {
                // Ownerless cache data cannot be selected safely. The managers
                // remain the first-sign-in local migration source.
                archive = .empty
                try? FileManager.default.removeItem(at: Self.engineStateURL)
                isAccountIsolationInProgress = false
            } else if !MediaStatePlaybackLease.isActive {
                isAccountIsolationInProgress = false
            }
            archive.accountOwnerRecordName = currentUser.recordName
            archive.ubiquityIdentityTokenData = Self.currentUbiquityIdentityTokenData()
            verifiedAccountRecordName = currentUser.recordName
            shouldFetch = true

        case .switchAccounts(_, let currentUser):
            // Delivery is synchronous on the main actor: every player freezes
            // and flushes its outgoing-user progress before live state changes.
            MediaStateAccountPlaybackBoundary.notifyWillChangeUser(sender: self)
            captureTask?.cancel()
            initialFetchCompleted = false
            isTrustedOfflineCacheActive = false
            suppressedDefaultRecordNames = []
            initialLocalStatePolicy = .isolateIncomingAccount
            isAccountIsolationInProgress = true
            isolateLoadedStateOrDefer()
            archive = .empty
            archive.accountOwnerRecordName = currentUser.recordName
            archive.ubiquityIdentityTokenData = Self.currentUbiquityIdentityTokenData()
            verifiedAccountRecordName = currentUser.recordName
            try? FileManager.default.removeItem(at: Self.engineStateURL)
            shouldFetch = true

        case .signOut(let previousUser):
            MediaStateAccountPlaybackBoundary.notifyWillChangeUser(sender: self)
            captureTask?.cancel()
            initialFetchCompleted = false
            isTrustedOfflineCacheActive = false
            suppressedDefaultRecordNames = []
            initialLocalStatePolicy = .isolateIncomingAccount
            isAccountIsolationInProgress = true
            archive.accountOwnerRecordName = archive.accountOwnerRecordName ?? previousUser.recordName
            verifiedAccountRecordName = nil
            isolateLoadedStateOrDefer()
            if !MediaStatePlaybackLease.isActive {
                archive.isAccountNeutralLocalStateActive = true
            }
            let signedOutEngine = engine
            engine = nil
            try? FileManager.default.removeItem(at: Self.engineStateURL)
            Task { await signedOutEngine?.cancelOperations() }
            if !MediaStatePlaybackLease.isActive {
                isAccountIsolationInProgress = false
            }
            shouldFetch = false

        @unknown default:
            // New CloudKit account-transition cases must default to isolation;
            // treating an unknown boundary as a normal migration risks copying
            // one private database into another.
            MediaStateAccountPlaybackBoundary.notifyWillChangeUser(sender: self)
            captureTask?.cancel()
            initialFetchCompleted = false
            isTrustedOfflineCacheActive = false
            suppressedDefaultRecordNames = []
            initialLocalStatePolicy = .isolateIncomingAccount
            isAccountIsolationInProgress = true
            verifiedAccountRecordName = nil
            isolateLoadedStateOrDefer()
            archive = .empty
            archive.accountOwnerRecordName = lastKnownAccountRecordName
            archive.isAccountNeutralLocalStateActive = !MediaStatePlaybackLease.isActive
            try? FileManager.default.removeItem(at: Self.engineStateURL)
            shouldFetch = true
        }

        persistArchive()

        guard shouldFetch else {
            phase = .localOnly("Sign in to iCloud to keep media state durable. Eclipse remains usable locally.")
            return
        }
        guard let activeEngine = engine else {
            // A superseded engine can finish delivering its account event after
            // an identity notification has already quarantined and cleared it.
            // The replacement identity-first preparation owns the next fetch.
            return
        }

        phase = .fetching
        Task {
            do {
                try await activeEngine.fetchChanges()
                completeInitialFetch()
                lastSyncDate = Date()
                lastErrorMessage = nil
                phase = .ready
            } catch {
                handleSyncError(error)
            }
        }
    }

    /// Replaces every CloudKit-synced domain with a neutral local baseline.
    /// This is intentionally destructive only at an iCloud account boundary;
    /// credentials remain in Keychain and reader state is outside this store.
    private func replaceLoadedStateWithAccountNeutralState() {
        let wasApplyingRemoteState = isApplyingRemoteState
        isApplyingRemoteState = true
        defer { isApplyingRemoteState = wasApplyingRemoteState }

        LibraryManager.shared.replaceCollectionsForMediaState([])
        ProgressManager.shared.replaceProgressDataForRestore(ProgressData())
        UserRatingManager.shared.restoreRatingsAndNotes(ratings: [:], notes: [:])

        let defaults = UserDefaults.standard
#if os(iOS)
        let previousNotificationSubscriptions = defaults.string(
            forKey: LocalNotificationManager.subscriptionsStorageKey
        )
#endif
        for key in MediaStateSettingRegistry.allKeys {
            guard let scope = MediaStateSettingRegistry.scope(for: key),
                  scope.appliesToCurrentPlatform else {
                continue
            }
            defaults.removeObject(forKey: key)
        }
        HomeCatalogLayoutStore.shared.reloadFromStorage()
        EclipseTheme.shared.reloadMediaAppearanceFromDefaults()
        CatalogManager.shared.resetCatalogsForMediaStateAccountChange()
#if os(iOS)
        reloadLocalNotificationSelectionsIfNeeded(
            previousSubscriptions: previousNotificationSubscriptions
        )
#endif
        NotificationCenter.default.post(name: .mediaStateDidRestore, object: self)
    }

#if os(iOS)
    private func reloadLocalNotificationSelectionsIfNeeded(previousSubscriptions: String?) {
        guard previousSubscriptions != UserDefaults.standard.string(
            forKey: LocalNotificationManager.subscriptionsStorageKey
        ) else { return }

        // The manager owns device authorization and pending requests. Let it
        // install the restored intent and rebuild locally after this synchronous
        // CloudKit apply finishes, without ever prompting on the destination.
        Task { @MainActor in
            await LocalNotificationManager.shared.reloadPersistedSelectionsAfterRestore()
        }
    }
#endif

    private func record(for recordID: CKRecord.ID) -> CKRecord? {
        guard let envelope = archive.records[recordID.recordName] else { return nil }
        return envelope.makeRecord(recordID: recordID, recordType: Self.recordType)
    }

    private func persistEngineState(_ serialization: CKSyncEngine.State.Serialization) {
        guard verifiedAccountRecordName != nil else {
            try? FileManager.default.removeItem(at: Self.engineStateURL)
            return
        }
        do {
            try Self.ensureStorageDirectory()
            let data = try JSONEncoder().encode(serialization)
            try data.write(to: Self.engineStateURL, options: .atomic)
        } catch {
            Logger.shared.log("Failed to persist CloudKit sync engine state: \(error.localizedDescription)", type: "iCloud")
        }
    }

    private func persistArchive() {
        do {
            try Self.ensureStorageDirectory()
            let data = try encoder.encode(archive)
            try data.write(to: Self.archiveURL, options: .atomic)
        } catch {
            Logger.shared.log("Failed to persist media state cache: \(error.localizedDescription)", type: "iCloud")
        }
    }

    private func handleSyncError(_ error: Error) {
        let message: String
        if let ckError = error as? CKError {
            switch ckError.code {
            case .notAuthenticated:
                message = "Sign in to iCloud to keep media state durable. Local changes will remain on this Apple TV."
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited:
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

    private static var engineStateURL: URL {
        storageDirectory.appendingPathComponent("engine-state.json")
    }

    private static func ensureStorageDirectory() throws {
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
    }

    private static func loadArchive() -> MediaStateLocalArchive {
        guard let data = try? Data(contentsOf: archiveURL),
              let value = decodeArchive(data) else {
            return .empty
        }
        return value
    }

    private static func loadEngineState() -> CKSyncEngine.State.Serialization? {
        // An incremental CloudKit token is only valid alongside the record
        // cache it describes. If tvOS purged/corrupted records.json, discard
        // the token so the next engine performs a complete reconstruction.
        guard let archiveData = try? Data(contentsOf: archiveURL),
              decodeArchive(archiveData) != nil else {
            return nil
        }
        guard let data = try? Data(contentsOf: engineStateURL) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private static func decodeArchive(_ data: Data) -> MediaStateLocalArchive? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(MediaStateLocalArchive.self, from: data)
    }
}

@available(iOS 17.0, tvOS 17.0, *)
extension MediaStateSyncManager: CKSyncEngineDelegate {
    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            await MainActor.run {
                guard engine === syncEngine else { return }
                persistEngineState(update.stateSerialization)
            }
        case .accountChange(let change):
            await MainActor.run {
                guard engine === syncEngine else { return }
                resetForAccountChange(change.changeType)
            }
        case .fetchedRecordZoneChanges(let changes):
            await MainActor.run {
                guard engine === syncEngine else { return }
                receiveFetchedChanges(changes)
            }
        case .sentRecordZoneChanges(let changes):
            await MainActor.run {
                guard engine === syncEngine else { return }
                receiveSentChanges(changes)
            }
        case .didFetchChanges:
            await MainActor.run {
                guard engine === syncEngine else { return }
                lastSyncDate = Date()
                if initialFetchCompleted { phase = .ready }
            }
        case .didSendChanges:
            await MainActor.run {
                guard engine === syncEngine else { return }
                lastSyncDate = Date()
                phase = .ready
            }
        default:
            break
        }
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let isCurrentEngine = await MainActor.run { self.engine === syncEngine }
        guard isCurrentEngine else { return nil }
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
private extension MediaStateEnvelope {
    init?(record: CKRecord) {
        guard let kindRaw = record["kind"] as? String,
              let kind = MediaStateKind(rawValue: kindRaw),
              let payload = record["payload"] as? Data,
              let modifiedAt = record["modifiedAt"] as? Date else {
            return nil
        }
        self.init(
            recordName: record.recordID.recordName,
            kind: kind,
            payload: payload,
            modifiedAt: modifiedAt,
            deletedAt: record["deletedAt"] as? Date,
            revision: (record["revision"] as? NSNumber)?.int64Value ?? 1,
            settingScope: MediaStateSettingScope(rawValue: record["settingScope"] as? String ?? "shared") ?? .shared,
            isCompleted: (record["isCompleted"] as? NSNumber)?.boolValue ?? false,
            isExplicitReset: (record["isExplicitReset"] as? NSNumber)?.boolValue ?? false,
            schemaVersion: (record["schemaVersion"] as? NSNumber)?.intValue ?? 1
        )
    }

    func makeRecord(recordID: CKRecord.ID, recordType: CKRecord.RecordType) -> CKRecord {
        let record = systemFields.flatMap { CKRecord.record(fromSystemFields: $0) } ?? CKRecord(recordType: recordType, recordID: recordID)
        record["kind"] = kind.rawValue as CKRecordValue
        record["payload"] = payload as CKRecordValue
        record["modifiedAt"] = modifiedAt as CKRecordValue
        record["revision"] = NSNumber(value: revision)
        record["settingScope"] = settingScope.rawValue as CKRecordValue
        record["isCompleted"] = NSNumber(value: isCompleted)
        record["isExplicitReset"] = NSNumber(value: isExplicitReset)
        record["schemaVersion"] = NSNumber(value: schemaVersion)
        if let deletedAt {
            record["deletedAt"] = deletedAt as CKRecordValue
        } else {
            record["deletedAt"] = nil
        }
        return record
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
