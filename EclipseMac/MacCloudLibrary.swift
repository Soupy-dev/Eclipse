import CloudKit
import Foundation
import Security

@MainActor
final class MacCloudLibrarySync: ObservableObject {
    static let shared = MacCloudLibrarySync()

    static let verifiedOwnerKey = "macCloudVerifiedOwner.v1"
    private static let signedOutIsolationOwnerKey = "macCloudSignedOutIsolationOwner.v1"
    static var hasPersistedOwner: Bool {
        UserDefaults.standard.string(forKey: verifiedOwnerKey) != nil
    }

    enum Phase: Equatable {
        case idle, syncing, ready, localOnly(String)

        var label: String {
            switch self {
            case .idle: "Not Synced"
            case .syncing: "Syncing…"
            case .ready: "Up to Date"
            case .localOnly(let reason): reason
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastSyncDate: Date?

    private struct CloudSession: Equatable {
        let ownerRecordName: String
        let generation: UInt64
    }

    private struct PendingBookmark: Codable {
        let item: MacMediaItem
        let bookmarked: Bool
        let revision: UUID
    }

    private struct PendingRating: Codable {
        let tmdbID: Int
        let rating: Double?
        let revision: UUID
    }

    private struct PendingProgress: Codable {
        let progress: MacPlaybackProgress
        let revision: UUID
    }

    private struct PendingEnvelope: Codable {
        let version: Int
        let bookmarks: [PendingBookmark]
        let ratings: [PendingRating]
        let progress: [PendingProgress]
    }

    private lazy var container: CKContainer? = {
        guard let task = SecTaskCreateFromSelf(nil),
              let identifiers = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.icloud-container-identifiers" as CFString,
                nil
              ) as? [String],
              identifiers.contains("iCloud.Eclipse.Soupy") else { return nil }
        return CKContainer(identifier: "iCloud.Eclipse.Soupy")
    }()
    private let zoneID = CKRecordZone.ID(zoneName: "EclipseMediaState", ownerName: CKCurrentUserDefaultName)
    private let recordType = "EclipseMediaState"
    private let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .millisecondsSince1970
        return value
    }()
    private let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .millisecondsSince1970
        return value
    }()

    private let pendingKey = "macCloudPendingMediaMutations.v1"
    private var verifiedOwnerRecordName: String?
    private var identityGeneration: UInt64 = 0
    private var identityCheckSequence: UInt64 = 0
    private var lastAppliedIdentityCheckSequence: UInt64 = 0
    private var pendingBookmarks: [String: PendingBookmark] = [:]
    private var pendingRatings: [Int: PendingRating] = [:]
    private var pendingProgress: [String: PendingProgress] = [:]
    private var mutationStateVersion: UInt64 = 0
    private var bookmarkWorker: Task<Void, Never>?
    private var ratingWorkers: [Int: Task<Void, Never>] = [:]
    private var progressWorkers: [String: Task<Void, Never>] = [:]
    private var accountObservers: [NSObjectProtocol] = []

    private init() {
        loadPendingMutations()
        for name in [Notification.Name.CKAccountChanged, .NSUbiquityIdentityDidChange] {
            accountObservers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.beginAccountRevalidation()
                }
            })
        }
    }

    func accountStatusLabel() async -> String {
        do {
            _ = try await authorizedSession()
            return "Available"
        } catch {
            if let accessError = error as? CloudAccessError {
                return switch accessError {
                case .missingEntitlement: "Requires a signed build"
                case .staleIdentity: "Account Changed"
                case .pendingPersistence: "Pending Changes Not Saved"
                case .accountUnavailable(let status):
                    switch status {
                    case .noAccount: "Sign in to iCloud"
                    case .restricted: "Restricted"
                    case .temporarilyUnavailable: "Temporarily Unavailable"
                    default: "Unavailable"
                    }
                }
            }
            return Self.safeMessage(for: error)
        }
    }

    func pullBookmarks() async -> [MacMediaItem]? {
        phase = .syncing
        do {
            let session = try await authorizedSession()
            try await ensureZone(session: session)
            let startingMutationVersion = mutationStateVersion
            let records = try await fetchAllRecords()
            guard isCurrent(session), startingMutationVersion == mutationStateVersion else {
                phase = .idle
                return nil
            }
            let definitions = records.compactMap(decodeDefinition)
            let hasRemoteCollection = definitions.contains(where: { $0.key == "bookmarks" })
            if !hasRemoteCollection && pendingBookmarks.isEmpty {
                phase = .ready
                lastSyncDate = Date()
                return nil
            }
            var items = Dictionary(uniqueKeysWithValues: records.compactMap(decodeMembership)
                .filter { $0.collectionKey == "bookmarks" }
                .sorted { $0.item.dateAdded < $1.item.dateAdded }
                .map { ($0.item.searchResult.mediaItem.stableID, $0.item.searchResult.mediaItem) })
            for mutation in pendingBookmarks.values {
                if mutation.bookmarked { items[mutation.item.stableID] = mutation.item }
                else { items.removeValue(forKey: mutation.item.stableID) }
            }
            phase = .ready
            lastSyncDate = Date()
            return items.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        } catch {
            phase = .localOnly(Self.safeMessage(for: error))
            return nil
        }
    }

    /// Returns once the latest desired state has been durably queued locally.
    /// The serialized worker keeps retryable mutations across app launches.
    @discardableResult
    func setBookmarked(_ item: MacMediaItem, bookmarked: Bool) -> Bool {
        pendingBookmarks[item.stableID] = PendingBookmark(item: item, bookmarked: bookmarked, revision: UUID())
        let persisted = didChangePendingMutations()
        startBookmarkWorkerIfNeeded()
        return persisted
    }

    func pullPlaybackProgress() async -> [MacPlaybackProgress]? {
        do {
            let session = try await authorizedSession()
            try await ensureZone(session: session)
            let startingMutationVersion = mutationStateVersion
            let records = try await fetchAllRecords()
            guard isCurrent(session), startingMutationVersion == mutationStateVersion else { return nil }
            let showMetadata = Dictionary(uniqueKeysWithValues: records.compactMap { record -> (Int, CloudShowMetadata)? in
                guard record["kind"] as? String == "showMetadata", record["deletedAt"] == nil,
                      let payload = record["payload"] as? Data,
                      let value = try? decoder.decode(CloudShowMetadata.self, from: payload) else { return nil }
                return (value.showId, value)
            })
            var values = Dictionary(uniqueKeysWithValues: records.compactMap { record -> MacPlaybackProgress? in
                guard record["deletedAt"] == nil,
                      let kind = record["kind"] as? String,
                      kind == "movieProgress" || kind == "episodeProgress",
                      let payload = record["payload"] as? Data else { return nil }
                if kind == "movieProgress", let value = try? decoder.decode(CloudMovieProgress.self, from: payload) {
                    return value.macValue
                }
                if kind == "episodeProgress", let value = try? decoder.decode(CloudEpisodeProgress.self, from: payload) {
                    return value.macValue(metadata: showMetadata[value.showId])
                }
                return nil
            }.map { ($0.id, $0) })
            for mutation in pendingProgress.values { values[mutation.progress.id] = mutation.progress }
            return values.values.sorted { $0.lastUpdated > $1.lastUpdated }
        } catch {
            phase = .localOnly(Self.safeMessage(for: error))
            return nil
        }
    }

    func pullRatings() async -> [Int: Double]? {
        do {
            let session = try await authorizedSession()
            try await ensureZone(session: session)
            let startingMutationVersion = mutationStateVersion
            var values = Dictionary(uniqueKeysWithValues: try await fetchAllRecords().compactMap { record -> (Int, Double)? in
                guard record["kind"] as? String == "rating", record["deletedAt"] == nil,
                      let payload = record["payload"] as? Data,
                      let value = try? decoder.decode(CloudRating.self, from: payload), let rating = value.rating else { return nil }
                return (value.tmdbID, rating)
            })
            guard isCurrent(session), startingMutationVersion == mutationStateVersion else { return nil }
            for mutation in pendingRatings.values {
                if let rating = mutation.rating { values[mutation.tmdbID] = rating }
                else { values.removeValue(forKey: mutation.tmdbID) }
            }
            return values
        } catch { return nil }
    }

    @discardableResult
    func saveRating(tmdbID: Int, rating: Double?) -> Bool {
        pendingRatings[tmdbID] = PendingRating(tmdbID: tmdbID, rating: rating, revision: UUID())
        let persisted = didChangePendingMutations()
        startRatingWorkerIfNeeded(tmdbID: tmdbID)
        return persisted
    }

    @discardableResult
    func savePlaybackProgress(_ progress: MacPlaybackProgress) -> Bool {
        pendingProgress[progress.id] = PendingProgress(progress: progress, revision: UUID())
        let persisted = didChangePendingMutations()
        startProgressWorkerIfNeeded(progressID: progress.id)
        return persisted
    }

    func retryPendingMutations() {
        startBookmarkWorkerIfNeeded()
        for id in pendingRatings.keys { startRatingWorkerIfNeeded(tmdbID: id) }
        for id in pendingProgress.keys { startProgressWorkerIfNeeded(progressID: id) }
    }

    private func ensureZone(session: CloudSession) async throws {
        try await revalidate(session)
        guard let container else { throw CloudAccessError.missingEntitlement }
        let zone = CKRecordZone(zoneID: zoneID)
        let result = try await container.privateCloudDatabase.modifyRecordZones(saving: [zone], deleting: [])
        if let save = result.saveResults[zoneID], case .failure(let error) = save { throw error }
        guard isCurrent(session) else { throw CloudAccessError.staleIdentity }
    }

    private func fetchAllRecords() async throws -> [CKRecord] {
        var records: [CKRecord] = []
        var cursor: CKQueryOperation.Cursor?
        repeat {
            let page = try await fetchPage(cursor: cursor)
            records.append(contentsOf: page.records)
            cursor = page.cursor
        } while cursor != nil
        return records
    }

    private func fetchPage(cursor: CKQueryOperation.Cursor?) async throws -> (records: [CKRecord], cursor: CKQueryOperation.Cursor?) {
        guard let container else { throw CloudAccessError.missingEntitlement }
        let database = container.privateCloudDatabase
        return try await withCheckedThrowingContinuation { continuation in
            let operation = cursor.map(CKQueryOperation.init(cursor:)) ?? CKQueryOperation(
                query: CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
            )
            operation.zoneID = zoneID
            operation.desiredKeys = ["kind", "payload", "deletedAt", "modifiedAt", "revision", "settingScope"]
            operation.resultsLimit = CKQueryOperation.maximumResults
            let lock = NSLock()
            var records: [CKRecord] = []
            operation.recordMatchedBlock = { _, result in
                if case .success(let record) = result {
                    lock.lock(); records.append(record); lock.unlock()
                }
            }
            operation.queryResultBlock = { result in
                switch result {
                case .success(let cursor):
                    lock.lock(); let snapshot = records; lock.unlock()
                    continuation.resume(returning: (snapshot, cursor))
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    // MARK: - Account identity fencing

    private func beginAccountRevalidation() {
        identityGeneration &+= 1
        verifiedOwnerRecordName = nil
        MacCatalogStore.shared.suspendCloudBackedStateForIdentityRevalidation()
        MacMediaStateStore.shared.suspendCloudBackedStateForIdentityRevalidation()
        identityCheckSequence &+= 1
        let invalidationSequence = identityCheckSequence
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.authorizedSession(sequence: invalidationSequence)
                self.retryPendingMutations()
            } catch {
                if !Task.isCancelled { self.phase = .localOnly(Self.safeMessage(for: error)) }
            }
        }
    }

    private func authorizedSession() async throws -> CloudSession {
        identityCheckSequence &+= 1
        return try await authorizedSession(sequence: identityCheckSequence)
    }

    private func authorizedSession(sequence: UInt64) async throws -> CloudSession {
        guard let container else {
            activateCachedStateWithoutCloudAccess()
            throw CloudAccessError.missingEntitlement
        }

        let status: CKAccountStatus
        do {
            status = try await container.accountStatus()
        } catch {
            if let cloudError = error as? CKError, cloudError.code == .notAuthenticated {
                applySignedOut(sequence: sequence)
            } else if verifiedOwnerRecordName != nil {
                activateCachedStateWithoutCloudAccess()
            }
            throw error
        }

        guard status == .available else {
            if status == .noAccount { applySignedOut(sequence: sequence) }
            else if verifiedOwnerRecordName != nil { activateCachedStateWithoutCloudAccess() }
            throw CloudAccessError.accountUnavailable(status)
        }

        let ownerRecordName: String
        do {
            ownerRecordName = try await container.userRecordID().recordName
        } catch {
            if let cloudError = error as? CKError, cloudError.code == .notAuthenticated {
                applySignedOut(sequence: sequence)
            } else if verifiedOwnerRecordName != nil {
                activateCachedStateWithoutCloudAccess()
            }
            throw error
        }

        if sequence < lastAppliedIdentityCheckSequence {
            guard verifiedOwnerRecordName == ownerRecordName else { throw CloudAccessError.staleIdentity }
            return CloudSession(ownerRecordName: ownerRecordName, generation: identityGeneration)
        }
        lastAppliedIdentityCheckSequence = sequence

        let defaults = UserDefaults.standard
        let persistedOwner = defaults.string(forKey: Self.verifiedOwnerKey)
        if persistedOwner == nil {
            // Existing unscoped local state belongs to the first account the
            // user explicitly verifies. Capture it before persisting an owner,
            // because owned state stays hidden at launch until verification.
            let catalog = MacCatalogStore.shared
            let mediaState = MacMediaStateStore.shared
            let bookmarks = catalog.cloudLibrarySnapshot
            let progress = mediaState.cloudProgressSnapshot
            let ratings = mediaState.cloudRatingsSnapshot

            catalog.activateCloudBackedStateForVerifiedOwner()
            mediaState.activateCloudBackedStateForVerifiedOwner()
            guard adoptOwnerlessState(bookmarks: bookmarks, progress: progress, ratings: ratings) else {
                throw CloudAccessError.pendingPersistence
            }
            // Commit ownership only after the migration queue is durable. A
            // crash before this write remains an ownerless, retryable import.
            defaults.set(ownerRecordName, forKey: Self.verifiedOwnerKey)
            guard defaults.synchronize(),
                  defaults.string(forKey: Self.verifiedOwnerKey) == ownerRecordName else {
                throw CloudAccessError.pendingPersistence
            }
            verifiedOwnerRecordName = ownerRecordName
            identityGeneration &+= 1
            defaults.removeObject(forKey: Self.signedOutIsolationOwnerKey)
        } else if persistedOwner != ownerRecordName {
            identityGeneration &+= 1
            verifiedOwnerRecordName = ownerRecordName
            isolateCloudBackedLocalState()
            defaults.set(ownerRecordName, forKey: Self.verifiedOwnerKey)
            defaults.removeObject(forKey: Self.signedOutIsolationOwnerKey)
            MacCatalogStore.shared.activateCloudBackedStateForVerifiedOwner()
            MacMediaStateStore.shared.activateCloudBackedStateForVerifiedOwner()
        } else {
            if verifiedOwnerRecordName != ownerRecordName {
                identityGeneration &+= 1
                verifiedOwnerRecordName = ownerRecordName
            }
            MacCatalogStore.shared.activateCloudBackedStateForVerifiedOwner()
            MacMediaStateStore.shared.activateCloudBackedStateForVerifiedOwner()
            defaults.removeObject(forKey: Self.signedOutIsolationOwnerKey)
        }

        return CloudSession(ownerRecordName: ownerRecordName, generation: identityGeneration)
    }

    private func applySignedOut(sequence: UInt64) {
        guard sequence >= lastAppliedIdentityCheckSequence else { return }
        lastAppliedIdentityCheckSequence = sequence
        identityGeneration &+= 1
        verifiedOwnerRecordName = nil
        let defaults = UserDefaults.standard
        if let persistedOwner = defaults.string(forKey: Self.verifiedOwnerKey) {
            if defaults.string(forKey: Self.signedOutIsolationOwnerKey) == persistedOwner {
                // The outgoing account was already isolated. Preserve edits
                // made intentionally while signed out for a same-owner return.
                MacCatalogStore.shared.activateCloudBackedStateForVerifiedOwner()
                MacMediaStateStore.shared.activateCloudBackedStateForVerifiedOwner()
            } else {
                isolateCloudBackedLocalState()
                defaults.set(persistedOwner, forKey: Self.signedOutIsolationOwnerKey)
            }
        }
        phase = .localOnly("Sign in to iCloud")
    }

    private func activateCachedStateWithoutCloudAccess() {
        MacCatalogStore.shared.activateCloudBackedStateForVerifiedOwner()
        MacMediaStateStore.shared.activateCloudBackedStateForVerifiedOwner()
    }

    private func isolateCloudBackedLocalState() {
        bookmarkWorker?.cancel()
        bookmarkWorker = nil
        ratingWorkers.values.forEach { $0.cancel() }
        ratingWorkers.removeAll()
        progressWorkers.values.forEach { $0.cancel() }
        progressWorkers.removeAll()
        pendingBookmarks.removeAll()
        pendingRatings.removeAll()
        pendingProgress.removeAll()
        didChangePendingMutations()
        MacCatalogStore.shared.resetCloudBackedStateForAccountIsolation()
        MacMediaStateStore.shared.resetCloudBackedStateForAccountIsolation()
    }

    private func isCurrent(_ session: CloudSession) -> Bool {
        verifiedOwnerRecordName == session.ownerRecordName && identityGeneration == session.generation
    }

    private func revalidate(_ session: CloudSession) async throws {
        let current = try await authorizedSession()
        guard current == session, isCurrent(session) else { throw CloudAccessError.staleIdentity }
    }

    // MARK: - Durable latest-wins mutation workers

    private func startBookmarkWorkerIfNeeded() {
        guard !pendingBookmarks.isEmpty, bookmarkWorker == nil else { return }
        bookmarkWorker = Task { [weak self] in await self?.drainBookmarkMutations() }
    }

    private func drainBookmarkMutations() async {
        while !Task.isCancelled, let mutation = pendingBookmarks.values.first {
            do {
                phase = .syncing
                let session = try await authorizedSession()
                try await ensureZone(session: session)
                if mutation.bookmarked { try await saveBookmark(mutation, session: session) }
                else { try await tombstoneBookmark(mutation, session: session) }
                guard isCurrent(session) else { throw CloudAccessError.staleIdentity }
                guard pendingBookmarks[mutation.item.stableID]?.revision == mutation.revision else { continue }
                pendingBookmarks.removeValue(forKey: mutation.item.stableID)
                didChangePendingMutations()
                phase = .ready
                lastSyncDate = Date()
            } catch {
                if !Task.isCancelled { phase = .localOnly(Self.safeMessage(for: error)) }
                break
            }
        }
        bookmarkWorker = nil
    }

    private func startRatingWorkerIfNeeded(tmdbID: Int) {
        guard pendingRatings[tmdbID] != nil, ratingWorkers[tmdbID] == nil else { return }
        ratingWorkers[tmdbID] = Task { [weak self] in await self?.drainRatingMutation(tmdbID: tmdbID) }
    }

    private func drainRatingMutation(tmdbID: Int) async {
        while !Task.isCancelled, let mutation = pendingRatings[tmdbID] {
            do {
                let session = try await authorizedSession()
                try await ensureZone(session: session)
                let id = CKRecord.ID(recordName: "rating|\(tmdbID)", zoneID: zoneID)
                let record = try await fetchRecords(ids: [id])[id] ?? CKRecord(recordType: recordType, recordID: id)
                guard pendingRatings[tmdbID]?.revision == mutation.revision else { continue }
                try await revalidate(session)
                guard pendingRatings[tmdbID]?.revision == mutation.revision else { continue }
                try populate(record, kind: "rating", payload: encoder.encode(CloudRating(tmdbID: tmdbID, rating: mutation.rating, note: nil)), modifiedAt: Date())
                try await saveRecords([record])
                guard isCurrent(session) else { throw CloudAccessError.staleIdentity }
                if pendingRatings[tmdbID]?.revision == mutation.revision {
                    pendingRatings.removeValue(forKey: tmdbID)
                    didChangePendingMutations()
                    lastSyncDate = Date()
                }
            } catch {
                if !Task.isCancelled { phase = .localOnly(Self.safeMessage(for: error)) }
                break
            }
        }
        ratingWorkers[tmdbID] = nil
    }

    private func startProgressWorkerIfNeeded(progressID: String) {
        guard pendingProgress[progressID] != nil, progressWorkers[progressID] == nil else { return }
        progressWorkers[progressID] = Task { [weak self] in await self?.drainProgressMutation(progressID: progressID) }
    }

    private func drainProgressMutation(progressID: String) async {
        while !Task.isCancelled, let mutation = pendingProgress[progressID] {
            do {
                let session = try await authorizedSession()
                try await ensureZone(session: session)
                let value = mutation.progress
                let kind = value.identity.isEpisode ? "episodeProgress" : "movieProgress"
                let identifier = value.identity.isEpisode
                    ? "ep_\(value.identity.item.id)_s\(value.identity.season ?? 1)_e\(value.identity.episode ?? 1)"
                    : String(value.identity.item.id)
                let id = CKRecord.ID(recordName: "\(kind)|\(identifier)", zoneID: zoneID)
                var ids = [id]
                let metadataID = CKRecord.ID(recordName: "showMetadata|\(value.identity.item.id)", zoneID: zoneID)
                if value.identity.isEpisode { ids.append(metadataID) }
                let existing = try await fetchRecords(ids: ids)
                guard pendingProgress[progressID]?.revision == mutation.revision else { continue }
                try await revalidate(session)
                guard pendingProgress[progressID]?.revision == mutation.revision else { continue }

                let record = existing[id] ?? CKRecord(recordType: recordType, recordID: id)
                let payload = value.identity.isEpisode
                    ? try encoder.encode(CloudEpisodeProgress(value))
                    : try encoder.encode(CloudMovieProgress(value))
                try populate(record, kind: kind, payload: payload, modifiedAt: value.lastUpdated)
                record["isCompleted"] = NSNumber(value: value.isWatched)
                var records = [record]
                if value.identity.isEpisode {
                    let metadata = existing[metadataID] ?? CKRecord(recordType: recordType, recordID: metadataID)
                    try populate(
                        metadata,
                        kind: "showMetadata",
                        payload: encoder.encode(CloudShowMetadata(
                            showId: value.identity.item.id,
                            title: value.identity.item.title,
                            posterURL: value.identity.item.posterURL?.absoluteString
                        )),
                        modifiedAt: value.lastUpdated
                    )
                    records.append(metadata)
                }
                try await saveRecords(records)
                guard isCurrent(session) else { throw CloudAccessError.staleIdentity }
                if pendingProgress[progressID]?.revision == mutation.revision {
                    pendingProgress.removeValue(forKey: progressID)
                    didChangePendingMutations()
                    lastSyncDate = Date()
                }
            } catch {
                if !Task.isCancelled { phase = .localOnly(Self.safeMessage(for: error)) }
                break
            }
        }
        progressWorkers[progressID] = nil
    }

    private func adoptOwnerlessState(
        bookmarks: [MacMediaItem],
        progress: [MacPlaybackProgress],
        ratings: [Int: Double]
    ) -> Bool {
        for item in bookmarks where pendingBookmarks[item.stableID] == nil {
            pendingBookmarks[item.stableID] = PendingBookmark(item: item, bookmarked: true, revision: UUID())
        }
        for value in progress where pendingProgress[value.id] == nil {
            pendingProgress[value.id] = PendingProgress(progress: value, revision: UUID())
        }
        for (id, rating) in ratings where pendingRatings[id] == nil {
            pendingRatings[id] = PendingRating(tmdbID: id, rating: rating, revision: UUID())
        }
        return didChangePendingMutations()
    }

    private func loadPendingMutations() {
        guard let data = UserDefaults.standard.data(forKey: pendingKey),
              let envelope = try? JSONDecoder().decode(PendingEnvelope.self, from: data),
              envelope.version == 1 else { return }
        pendingBookmarks = envelope.bookmarks.reduce(into: [String: PendingBookmark]()) { $0[$1.item.stableID] = $1 }
        pendingRatings = envelope.ratings.reduce(into: [Int: PendingRating]()) { $0[$1.tmdbID] = $1 }
        pendingProgress = envelope.progress.reduce(into: [String: PendingProgress]()) { $0[$1.progress.id] = $1 }
    }

    @discardableResult
    private func didChangePendingMutations() -> Bool {
        mutationStateVersion &+= 1
        let envelope = PendingEnvelope(
            version: 1,
            bookmarks: Array(pendingBookmarks.values),
            ratings: Array(pendingRatings.values),
            progress: Array(pendingProgress.values)
        )
        if let data = try? JSONEncoder().encode(envelope) {
            UserDefaults.standard.set(data, forKey: pendingKey)
            return UserDefaults.standard.synchronize()
                && UserDefaults.standard.data(forKey: pendingKey) == data
        }
        return false
    }

    private func saveBookmark(_ mutation: PendingBookmark, session: CloudSession) async throws {
        let item = mutation.item
        let now = Date()
        let definitionID = CKRecord.ID(recordName: "libraryCollection|bookmarks", zoneID: zoneID)
        let membershipID = CKRecord.ID(recordName: "libraryMembership|bookmarks:\(item.id)", zoneID: zoneID)
        let existing = try await fetchRecords(ids: [definitionID, membershipID])

        let definition = existing[definitionID] ?? CKRecord(recordType: recordType, recordID: definitionID)
        let definitionPayload = CollectionPayload(
            id: existingBookmarkCollectionID(from: definition) ?? UUID(),
            key: "bookmarks",
            name: "Bookmarks",
            description: "Your bookmarked items",
            order: 0
        )
        try populate(definition, kind: "libraryCollection", payload: encoder.encode(definitionPayload), modifiedAt: now)

        let membership = existing[membershipID] ?? CKRecord(recordType: recordType, recordID: membershipID)
        let payload = MembershipPayload(collectionKey: "bookmarks", item: CloudLibraryItem(searchResult: CloudSearchResult(item), dateAdded: now))
        try populate(membership, kind: "libraryMembership", payload: encoder.encode(payload), modifiedAt: now)

        guard pendingBookmarks[item.stableID]?.revision == mutation.revision else { return }
        try await revalidate(session)
        guard pendingBookmarks[item.stableID]?.revision == mutation.revision else { return }
        try await saveRecords([definition, membership])
    }

    private func tombstoneBookmark(_ mutation: PendingBookmark, session: CloudSession) async throws {
        let item = mutation.item
        let id = CKRecord.ID(recordName: "libraryMembership|bookmarks:\(item.id)", zoneID: zoneID)
        guard let record = try await fetchRecords(ids: [id])[id] else { return }
        let now = Date()
        record["payload"] = Data() as CKRecordValue
        record["modifiedAt"] = now as CKRecordValue
        record["deletedAt"] = now as CKRecordValue
        record["revision"] = NSNumber(value: ((record["revision"] as? NSNumber)?.int64Value ?? 1) + 1)
        record["isCompleted"] = NSNumber(value: false)
        record["isExplicitReset"] = NSNumber(value: false)
        guard pendingBookmarks[item.stableID]?.revision == mutation.revision else { return }
        try await revalidate(session)
        guard pendingBookmarks[item.stableID]?.revision == mutation.revision else { return }
        try await saveRecords([record])
    }

    private func fetchRecords(ids: [CKRecord.ID]) async throws -> [CKRecord.ID: CKRecord] {
        guard let container else { throw CloudAccessError.missingEntitlement }
        let result = try await container.privateCloudDatabase.records(for: ids, desiredKeys: nil)
        var records: [CKRecord.ID: CKRecord] = [:]
        for (id, value) in result {
            switch value {
            case .success(let record):
                records[id] = record
            case .failure(let error):
                if let cloudError = error as? CKError, cloudError.code == .unknownItem { continue }
                throw error
            }
        }
        return records
    }

    private func saveRecords(_ records: [CKRecord]) async throws {
        guard let container else { throw CloudAccessError.missingEntitlement }
        let result = try await container.privateCloudDatabase.modifyRecords(
            saving: records,
            deleting: [],
            savePolicy: .changedKeys,
            atomically: true
        )
        for value in result.saveResults.values { if case .failure(let error) = value { throw error } }
    }

    private func populate(_ record: CKRecord, kind: String, payload: Data, modifiedAt: Date) throws {
        record["kind"] = kind as CKRecordValue
        record["payload"] = payload as CKRecordValue
        record["modifiedAt"] = modifiedAt as CKRecordValue
        record["deletedAt"] = nil
        record["revision"] = NSNumber(value: ((record["revision"] as? NSNumber)?.int64Value ?? 0) + 1)
        record["settingScope"] = "shared" as CKRecordValue
        record["isCompleted"] = NSNumber(value: false)
        record["isExplicitReset"] = NSNumber(value: false)
        record["schemaVersion"] = NSNumber(value: 1)
    }

    private func decodeDefinition(_ record: CKRecord) -> CollectionPayload? {
        guard record["kind"] as? String == "libraryCollection", record["deletedAt"] == nil,
              let payload = record["payload"] as? Data else { return nil }
        return try? decoder.decode(CollectionPayload.self, from: payload)
    }

    private func decodeMembership(_ record: CKRecord) -> MembershipPayload? {
        guard record["kind"] as? String == "libraryMembership", record["deletedAt"] == nil,
              let payload = record["payload"] as? Data, !payload.isEmpty else { return nil }
        return try? decoder.decode(MembershipPayload.self, from: payload)
    }

    private func existingBookmarkCollectionID(from record: CKRecord) -> UUID? {
        guard let data = record["payload"] as? Data else { return nil }
        return (try? decoder.decode(CollectionPayload.self, from: data))?.id
    }

    private static func safeMessage(for error: Error) -> String {
        if let accessError = error as? CloudAccessError {
            return switch accessError {
            case .missingEntitlement: "iCloud requires a signed build"
            case .accountUnavailable(let status): status == .noAccount ? "Sign in to iCloud" : "iCloud temporarily unavailable"
            case .staleIdentity: "iCloud account changed; sync will retry"
            case .pendingPersistence: "Couldn’t safely save pending iCloud changes"
            }
        }
        guard let cloudError = error as? CKError else { return "iCloud sync unavailable" }
        return switch cloudError.code {
        case .notAuthenticated: "Sign in to iCloud"
        case .networkFailure, .networkUnavailable, .serviceUnavailable: "iCloud temporarily unavailable"
        case .quotaExceeded: "iCloud storage is full"
        default: "iCloud sync unavailable"
        }
    }

    private enum CloudAccessError: Error {
        case missingEntitlement
        case accountUnavailable(CKAccountStatus)
        case staleIdentity
        case pendingPersistence
    }
}

struct MacPlaybackIdentity: Codable, Hashable {
    let item: MacMediaItem
    let season: Int?
    let episode: Int?

    var isEpisode: Bool { item.mediaType == "tv" && season != nil && episode != nil }
    var progressID: String {
        isEpisode ? "episode-\(item.id)-\(season ?? 1)-\(episode ?? 1)" : "movie-\(item.id)"
    }
    var displayTitle: String {
        isEpisode ? "\(item.title) · S\(season ?? 1) E\(episode ?? 1)" : item.title
    }
}

struct MacPlaybackProgress: Codable, Identifiable, Hashable {
    var id: String { identity.progressID }
    let identity: MacPlaybackIdentity
    var currentTime: Double
    var totalDuration: Double
    var isWatched: Bool
    var lastUpdated: Date

    var fraction: Double {
        guard totalDuration > 0 else { return 0 }
        return min(1, max(0, currentTime / totalDuration))
    }
}

@MainActor
final class MacMediaStateStore: ObservableObject {
    static let shared = MacMediaStateStore()

    @Published private(set) var progress: [MacPlaybackProgress] = []
    @Published private(set) var ratings: [Int: Double] = [:]
    private let key = "macPlaybackProgress.v1"
    private let ratingsKey = "macMediaRatings.v1"
    private var cloudStateActivated: Bool

    private init() {
        cloudStateActivated = !MacCloudLibrarySync.hasPersistedOwner
        if cloudStateActivated { loadPersistedCloudBackedState() }
        Task { await refreshFromCloud() }
    }

    var continueWatching: [MacPlaybackProgress] {
        progress.filter { !$0.isWatched && $0.fraction >= 0.02 && $0.fraction < 0.85 }
            .sorted { $0.lastUpdated > $1.lastUpdated }
    }

    func value(for identity: MacPlaybackIdentity) -> MacPlaybackProgress? {
        progress.first { $0.id == identity.progressID }
    }

    func rating(for item: MacMediaItem) -> Double? { ratings[item.id] }

    func setRating(_ rating: Double?, for item: MacMediaItem) {
        ratings[item.id] = rating
        if let data = try? JSONEncoder().encode(ratings) { UserDefaults.standard.set(data, forKey: ratingsKey) }
        MacCloudLibrarySync.shared.saveRating(tmdbID: item.id, rating: rating)
        Task { await MacTrackerStore.shared.syncRating(rating, for: item) }
    }

    /// Imports a tracker's watched state additively. Existing watched entries
    /// and episodes outside the imported range are intentionally untouched.
    /// CloudKit writes are queued only after the whole batch is persisted.
    @discardableResult
    func importWatchedProgress(
        item: MacMediaItem,
        season: Int?,
        fromEpisode: Int = 1,
        throughEpisode: Int
    ) -> Int {
        let identities: [MacPlaybackIdentity]
        switch item.mediaType.lowercased() {
        case "movie":
            guard season == nil, fromEpisode == 1, throughEpisode == 1 else { return 0 }
            identities = [MacPlaybackIdentity(item: item, season: nil, episode: nil)]
        case "tv":
            guard let season, season >= 0,
                  (1...5_000).contains(fromEpisode),
                  (fromEpisode...5_000).contains(throughEpisode) else { return 0 }
            identities = (fromEpisode...throughEpisode).map {
                MacPlaybackIdentity(item: item, season: season, episode: $0)
            }
        default:
            return 0
        }

        let now = Date()
        var advanced: [MacPlaybackProgress] = []
        advanced.reserveCapacity(identities.count)

        for identity in identities {
            if let index = progress.firstIndex(where: { $0.id == identity.progressID }) {
                guard !progress[index].isWatched else { continue }

                var value = progress[index]
                value.totalDuration = max(value.totalDuration, 1)
                value.currentTime = max(value.currentTime, value.totalDuration)
                value.isWatched = true
                value.lastUpdated = now
                progress[index] = value
                advanced.append(value)
            } else {
                let value = MacPlaybackProgress(
                    identity: identity,
                    currentTime: 1,
                    totalDuration: 1,
                    isWatched: true,
                    lastUpdated: now
                )
                progress.append(value)
                advanced.append(value)
            }
        }

        guard !advanced.isEmpty else { return 0 }
        persist()
        for value in advanced {
            MacCloudLibrarySync.shared.savePlaybackProgress(value)
        }
        return advanced.count
    }

    func record(identity: MacPlaybackIdentity, currentTime: Double, duration: Double, forceCloud: Bool = false) {
        guard currentTime.isFinite, duration.isFinite, currentTime >= 0, duration > 0 else { return }
        let now = Date()
        let watched = currentTime / duration >= 0.85
        let value = MacPlaybackProgress(
            identity: identity,
            currentTime: watched ? duration : min(currentTime, duration),
            totalDuration: duration,
            isWatched: watched,
            lastUpdated: now
        )
        if let index = progress.firstIndex(where: { $0.id == value.id }) { progress[index] = value }
        else { progress.append(value) }
        persist()
        MacCloudLibrarySync.shared.savePlaybackProgress(value)
        Task { await MacTrackerStore.shared.scrobble(value) }
    }

    func markWatched(_ value: MacPlaybackProgress, watched: Bool) {
        var copy = value
        copy.isWatched = watched
        copy.currentTime = watched ? max(copy.totalDuration, 1) : 0
        copy.lastUpdated = Date()
        if let index = progress.firstIndex(where: { $0.id == copy.id }) { progress[index] = copy }
        persist()
        MacCloudLibrarySync.shared.savePlaybackProgress(copy)
        Task { await MacTrackerStore.shared.scrobble(copy, force: true) }
    }

    func remove(_ value: MacPlaybackProgress) {
        progress.removeAll { $0.id == value.id }
        persist()
    }

    func refreshFromCloud() async {
        if let remote = await MacCloudLibrarySync.shared.pullPlaybackProgress() {
            var merged = Dictionary(uniqueKeysWithValues: progress.map { ($0.id, $0) })
            for item in remote where item.lastUpdated >= (merged[item.id]?.lastUpdated ?? .distantPast) { merged[item.id] = item }
            progress = merged.values.sorted { $0.lastUpdated > $1.lastUpdated }
            persist()
        }
        if let remoteRatings = await MacCloudLibrarySync.shared.pullRatings() {
            ratings = remoteRatings
            if let data = try? JSONEncoder().encode(ratings) { UserDefaults.standard.set(data, forKey: ratingsKey) }
        }
        MacCloudLibrarySync.shared.retryPendingMutations()
    }

    var cloudProgressSnapshot: [MacPlaybackProgress] { progress }
    var cloudRatingsSnapshot: [Int: Double] { ratings }

    func activateCloudBackedStateForVerifiedOwner() {
        guard !cloudStateActivated else { return }
        cloudStateActivated = true
        loadPersistedCloudBackedState()
    }

    func resetCloudBackedStateForAccountIsolation() {
        progress = []
        ratings = [:]
        cloudStateActivated = false
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: ratingsKey)
    }

    func suspendCloudBackedStateForIdentityRevalidation() {
        progress = []
        ratings = [:]
        cloudStateActivated = false
    }

    private func loadPersistedCloudBackedState() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([MacPlaybackProgress].self, from: data) {
            progress = decoded
        }
        if let data = UserDefaults.standard.data(forKey: ratingsKey),
           let decoded = try? JSONDecoder().decode([Int: Double].self, from: data) {
            ratings = decoded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(progress) { UserDefaults.standard.set(data, forKey: key) }
    }
}

private extension MacCloudLibrarySync {
    struct CloudRating: Codable { let tmdbID: Int; let rating: Double?; let note: String? }
    struct CloudShowMetadata: Codable { let showId: Int; let title: String; let posterURL: String? }
    struct CloudMovieProgress: Codable {
        let id: Int
        let title: String
        var posterURL: String?
        var currentTime: Double
        var totalDuration: Double
        var isWatched: Bool
        var lastUpdated: Date
        var lastServiceId: UUID?
        var lastHref: String?

        init(_ value: MacPlaybackProgress) {
            id = value.identity.item.id; title = value.identity.item.title
            posterURL = value.identity.item.posterURL?.absoluteString
            currentTime = value.currentTime; totalDuration = value.totalDuration
            isWatched = value.isWatched; lastUpdated = value.lastUpdated
        }
        var macValue: MacPlaybackProgress {
            let item = MacMediaItem(id: id, mediaType: "movie", title: title, overview: "", posterPath: Self.imagePath(posterURL), backdropPath: nil, date: nil, rating: 0)
            return MacPlaybackProgress(identity: .init(item: item, season: nil, episode: nil), currentTime: currentTime, totalDuration: totalDuration, isWatched: isWatched, lastUpdated: lastUpdated)
        }
        static func imagePath(_ value: String?) -> String? {
            guard let value, let range = value.range(of: "/t/p/") else { return nil }
            let suffix = value[range.upperBound...]
            guard let slash = suffix.firstIndex(of: "/") else { return nil }
            return String(suffix[slash...])
        }
    }

    struct CloudEpisodeProgress: Codable {
        let id: String
        let showId: Int
        let seasonNumber: Int
        let episodeNumber: Int
        var currentTime: Double
        var totalDuration: Double
        var isWatched: Bool
        var lastUpdated: Date
        var lastServiceId: UUID?
        var lastHref: String?
        var playbackContext: EmptyPlaybackContext?
        var isAnime: Bool?

        init(_ value: MacPlaybackProgress) {
            showId = value.identity.item.id; seasonNumber = value.identity.season ?? 1; episodeNumber = value.identity.episode ?? 1
            id = "ep_\(showId)_s\(seasonNumber)_e\(episodeNumber)"
            currentTime = value.currentTime; totalDuration = value.totalDuration
            isWatched = value.isWatched; lastUpdated = value.lastUpdated
        }
        func macValue(metadata: CloudShowMetadata?) -> MacPlaybackProgress {
            let item = MacMediaItem(
                id: showId, mediaType: "tv", title: metadata?.title ?? "Show \(showId)", overview: "",
                posterPath: CloudMovieProgress.imagePath(metadata?.posterURL), backdropPath: nil, date: nil, rating: 0
            )
            return MacPlaybackProgress(identity: .init(item: item, season: seasonNumber, episode: episodeNumber), currentTime: currentTime, totalDuration: totalDuration, isWatched: isWatched, lastUpdated: lastUpdated)
        }
    }

    /// Existing iOS records may contain a rich context. A permissive empty
    /// value lets this target ignore fields it does not need without changing
    /// the shared CloudKit schema.
    struct EmptyPlaybackContext: Codable {}

    struct CollectionPayload: Codable {
        let id: UUID
        let key: String
        let name: String
        let description: String?
        let order: Int
    }

    struct MembershipPayload: Codable {
        let collectionKey: String
        let item: CloudLibraryItem
    }

    struct CloudLibraryItem: Codable {
        let searchResult: CloudSearchResult
        let dateAdded: Date
    }

    struct CloudSearchResult: Codable {
        let id: Int
        let mediaType: String
        let title: String?
        let name: String?
        let overview: String?
        let posterPath: String?
        let backdropPath: String?
        let releaseDate: String?
        let firstAirDate: String?
        let voteAverage: Double?
        let popularity: Double
        let adult: Bool?
        let genreIds: [Int]?
        let originalLanguage: String?
        let originCountry: [String]?
        let voteCount: Int?

        enum CodingKeys: String, CodingKey {
            case id, title, name, overview, popularity, adult
            case mediaType = "media_type", posterPath = "poster_path", backdropPath = "backdrop_path"
            case releaseDate = "release_date", firstAirDate = "first_air_date", voteAverage = "vote_average"
            case genreIds = "genre_ids", originalLanguage = "original_language", originCountry = "origin_country", voteCount = "vote_count"
        }

        init(_ item: MacMediaItem) {
            id = item.id; mediaType = item.mediaType
            title = item.mediaType == "movie" ? item.title : nil
            name = item.mediaType == "tv" ? item.title : nil
            overview = item.overview; posterPath = item.posterPath; backdropPath = item.backdropPath
            releaseDate = item.mediaType == "movie" ? item.date : nil
            firstAirDate = item.mediaType == "tv" ? item.date : nil
            voteAverage = item.rating; popularity = 0; adult = nil; genreIds = nil
            originalLanguage = nil; originCountry = nil; voteCount = nil
        }

        var mediaItem: MacMediaItem {
            MacMediaItem(
                id: id, mediaType: mediaType, title: title ?? name ?? "Unknown Title", overview: overview ?? "",
                posterPath: posterPath, backdropPath: backdropPath, date: releaseDate ?? firstAirDate, rating: voteAverage ?? 0
            )
        }
    }
}
