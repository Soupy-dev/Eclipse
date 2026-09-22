//
//  LibraryManager.swift
//  Sora
//
//  Created by Francesco on 08/09/25.
//

import Combine
import Foundation

struct CollectionImportValue<Item: Sendable>: Sendable {
    let id: UUID
    let name: String
    let items: [Item]
    let description: String?
}

struct CollectionImportSnapshot<Item: Sendable>: Sendable {
    let owner: UUID
    let storageKey: String
    let revision: UInt64
    let invalidation: UInt64
    let collections: [CollectionImportValue<Item>]
    let observedData: Data?
}

struct PreparedCollectionImport<Item: Sendable>: Sendable {
    let collections: [CollectionImportValue<Item>]
    let changedIndexes: Set<Int>
    let data: Data?
    let added: Int
}

final class LibraryManager: ObservableObject {
    static let shared = LibraryManager()

    static let bookmarksCollectionName = "Bookmarks"
    private static let bookmarksCollectionDescription = "Your bookmarked items"
    private static let bookmarksCollectionIDNamespace = UUID(
        uuid: (0x3e, 0x02, 0xad, 0x8c, 0x84, 0x2c, 0x4b, 0x9f, 0xae, 0x08, 0xb3, 0x7d, 0x44, 0x64, 0xb9, 0xc5)
    )

    @Published private(set) var collections: [LibraryCollection] = [] {
        didSet {
            if !isPublishingImport, !isAppendingCollection { importInvalidationGeneration &+= 1 }
            advanceMediaStateRevision()
            collections.forEach { observeCollection($0) }
            save()
        }
    }

    private static let legacyCollectionsKey = "libraryCollections"

    private var collectionsKey: String
    private var activeProfileID: UUID
    private var collectionCancellables: [UUID: AnyCancellable] = [:]
    private var collectionObservationGeneration = UUID()
    private let mediaStateRevisionLock = NSLock()
    private var mutationRevision: UInt64 = 0
    private var collectionSavePending = false
    private var cancellables = Set<AnyCancellable>()

    private var isSwitchingProfile = false
    private var isPublishingImport = false
    private var isAppendingCollection = false
    private var importInvalidationGeneration: UInt64 = 0

    private var storeLoadFailed = false

    var isApplyingTraktWatchlistSync = false

    var mediaStateRevision: UInt64 {
        mediaStateRevisionLock.lock()
        defer { mediaStateRevisionLock.unlock() }
        return mutationRevision
    }

    private func advanceMediaStateRevision() {
        mediaStateRevisionLock.lock()
        mutationRevision &+= 1
        mediaStateRevisionLock.unlock()
    }

    private convenience init() {
        self.init(profileID: ProfileManager.shared.activeProfileID)
    }

    init(profileID: UUID) {
        activeProfileID = profileID
        collectionsKey = Self.collectionsKey(for: profileID)
        Self.migrateLegacyStoreIfNeeded()
        load()
        createDefaultBookmarksCollection()

        collections.forEach { observeCollection($0) }
    }

    static func collectionsKey(for profileID: UUID) -> String {
        ProfileScopedStorage.defaultsKey(base: legacyCollectionsKey, profileID: profileID)
    }

    private static func migrateLegacyStoreIfNeeded() {
        ProfileScopedStorage.migrateLegacyStoreIfNeeded(marker: "library") {
            let defaults = UserDefaults.standard
            let destinationKey = collectionsKey(for: ProfileManager.defaultProfileID)
            guard defaults.object(forKey: destinationKey) == nil,
                  let legacy = defaults.data(forKey: legacyCollectionsKey) else { return }
            defaults.set(legacy, forKey: destinationKey)
            defaults.removeObject(forKey: legacyCollectionsKey)
        }
    }

    func switchProfile(to profileID: UUID) {
        guard profileID != activeProfileID else { return }
        if collectionSavePending {
            save()
        }
        isSwitchingProfile = true
        activeProfileID = profileID
        collectionsKey = Self.collectionsKey(for: profileID)
        collectionCancellables.removeAll()
        collectionObservationGeneration = UUID()
        if let loaded = Self.loadCollections(forKey: collectionsKey, profileID: profileID) {
            collections = loaded

            storeLoadFailed = false
        } else {
            collections = []
            storeLoadFailed = true
        }
        createDefaultBookmarksCollection()
        isSwitchingProfile = false
        collections.forEach { observeCollection($0) }

        save()
    }

    func collections(forProfile profileID: UUID) -> [LibraryCollection]? {
        guard profileID != activeProfileID else {
            return storeLoadFailed ? nil : collections
        }
        return Self.loadCollections(
            forKey: Self.collectionsKey(for: profileID),
            profileID: profileID
        )
    }

    func discardStore(forProfile profileID: UUID) {
        guard profileID != activeProfileID else { return }
        advanceMediaStateRevision()
        UserDefaults.standard.removeObject(forKey: Self.collectionsKey(for: profileID))
    }

    private static func loadCollections(forKey key: String, profileID: UUID) -> [LibraryCollection]? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else {

            return normalizedCollections([], forProfile: profileID)
        }
        guard let data = defaults.data(forKey: key) else {

            Logger.shared.log(
                "LibraryManager: collections under \(key) have an unsupported storage type; leaving them in place",
                type: "Error"
            )
            return nil
        }
        guard let decoded = try? JSONDecoder().decode([LibraryCollection].self, from: data) else {
            Logger.shared.log(
                "LibraryManager: collections under \(key) exist but do not decode; leaving them in place",
                type: "Error"
            )
            return nil
        }
        return normalizedCollections(decoded, forProfile: profileID)
    }

    static func normalizedCollections(
        _ source: [LibraryCollection],
        forProfile profileID: UUID = ProfileManager.defaultProfileID
    ) -> [LibraryCollection] {
        let bookmarkCandidates = source.filter { isBookmarksName($0.name) }
        let ordinaryCollections = source.filter { !isBookmarksName($0.name) }

        guard !bookmarkCandidates.isEmpty else {
            return [
                LibraryCollection(
                    id: bookmarksCollectionID(forProfile: profileID),
                    name: bookmarksCollectionName,
                    description: bookmarksCollectionDescription
                )
            ] + ordinaryCollections
        }

        let orderedCandidates = bookmarkCandidates.sorted { lhs, rhs in
            let lhsIsCanonical = lhs.name == bookmarksCollectionName
            let rhsIsCanonical = rhs.name == bookmarksCollectionName
            if lhsIsCanonical != rhsIsCanonical { return lhsIsCanonical }
            return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
        }
        let anchor = orderedCandidates[0]

        var mergedItems: [LibraryItem] = []
        var itemIndexByIdentity: [String: Int] = [:]
        for candidate in orderedCandidates {
            for item in candidate.items {
                let identity = item.searchResult.stableIdentity
                if let existingIndex = itemIndexByIdentity[identity] {

                    if item.dateAdded > mergedItems[existingIndex].dateAdded {
                        mergedItems[existingIndex] = item
                    }
                } else {
                    itemIndexByIdentity[identity] = mergedItems.count
                    mergedItems.append(item)
                }
            }
        }

        let bookmarks = LibraryCollection(
            id: anchor.id,
            name: bookmarksCollectionName,
            items: mergedItems,
            description: anchor.description ?? bookmarksCollectionDescription
        )
        return [bookmarks] + ordinaryCollections
    }

    static func bookmarksCollectionID(forProfile profileID: UUID) -> UUID {
        let profile = profileID.uuid
        let namespace = bookmarksCollectionIDNamespace.uuid
        let versionByte = ((profile.6 ^ namespace.6) & 0x0f) | 0x50
        let variantByte = ((profile.8 ^ namespace.8) & 0x3f) | 0x80
        return UUID(uuid: (
            profile.0 ^ namespace.0,
            profile.1 ^ namespace.1,
            profile.2 ^ namespace.2,
            profile.3 ^ namespace.3,
            profile.4 ^ namespace.4,
            profile.5 ^ namespace.5,
            versionByte,
            profile.7 ^ namespace.7,
            variantByte,
            profile.9 ^ namespace.9,
            profile.10 ^ namespace.10,
            profile.11 ^ namespace.11,
            profile.12 ^ namespace.12,
            profile.13 ^ namespace.13,
            profile.14 ^ namespace.14,
            profile.15 ^ namespace.15
        ))
    }

    static func isBookmarksName(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(bookmarksCollectionName) == .orderedSame
    }

    private func load() {
        guard let decoded = Self.loadCollections(
            forKey: collectionsKey,
            profileID: activeProfileID
        ) else {
            storeLoadFailed = true
            return
        }
        storeLoadFailed = false
        if !decoded.isEmpty {
            collections = decoded
        }
    }

    private func save() {
        guard !isSwitchingProfile, !isPublishingImport else { return }

        guard !storeLoadFailed else {
            Logger.shared.log(
                "LibraryManager: refused to save over collections that failed to decode",
                type: "Error"
            )
            return
        }
        if let data = try? JSONEncoder().encode(collections) {
            UserDefaults.standard.set(data, forKey: collectionsKey)
            collectionSavePending = false
        }
        NotificationCenter.default.post(name: .libraryDataDidChange, object: self)
    }

    func replaceCollectionsForMediaState(_ newCollections: [LibraryCollection]) {

        storeLoadFailed = false
        collectionCancellables.removeAll()
        collectionObservationGeneration = UUID()
        collections = Self.normalizedCollections(newCollections, forProfile: activeProfileID)
        collections.forEach { observeCollection($0) }
    }

    func replaceCollectionsForMediaState(_ newCollections: [LibraryCollection], forProfile profileID: UUID) {
        if profileID == activeProfileID {
            replaceCollectionsForMediaState(newCollections)
            return
        }
        let resolved = Self.normalizedCollections(newCollections, forProfile: profileID)
        guard let data = try? JSONEncoder().encode(resolved) else { return }
        advanceMediaStateRevision()
        UserDefaults.standard.set(data, forKey: Self.collectionsKey(for: profileID))
    }

    private func createDefaultBookmarksCollection() {
        if !collections.contains(where: { Self.isBookmarksName($0.name) }) {
            let bookmarksCollection = LibraryCollection(
                id: Self.bookmarksCollectionID(forProfile: activeProfileID),
                name: Self.bookmarksCollectionName,
                description: Self.bookmarksCollectionDescription
            )
            collections.insert(bookmarksCollection, at: 0)
        }
    }

    @discardableResult
    func createCollection(name: String, description: String? = nil) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !Self.isBookmarksName(trimmedName) else { return false }
        acceptExplicitMutation()
        let new = LibraryCollection(name: trimmedName, description: description)
        isAppendingCollection = true
        collections.append(new)
        isAppendingCollection = false
        return true
    }

    func renameCollection(_ collection: LibraryCollection, name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              !Self.isBookmarksName(trimmedName),
              let index = collections.firstIndex(where: { $0.id == collection.id }),
              !Self.isBookmarksName(collections[index].name) else { return }

        acceptExplicitMutation()
        importInvalidationGeneration &+= 1
        collections[index].name = trimmedName
    }

    func deleteCollection(_ collection: LibraryCollection) {
        guard let index = collections.firstIndex(where: { $0.id == collection.id }),
              !Self.isBookmarksName(collections[index].name) else { return }
        acceptExplicitMutation()
        collectionCancellables[collection.id] = nil
        collections.remove(at: index)
    }

    func addItem(to collectionId: UUID, item: LibraryItem) {
        guard let index = collections.firstIndex(where: { $0.id == collectionId }),
              !collections[index].items.contains(where: { $0.id == item.id }) else { return }
        acceptExplicitMutation()
        collections[index].items.append(item)
        notifyTraktWatchlistIfNeeded(collectionName: collections[index].name, item: item, added: true)
    }

    struct ImportedItem: Sendable {
        let collectionName: String
        let item: LibraryItem
    }

    static func mergingImportedItems(
        _ additions: [ImportedItem],
        into existing: [LibraryCollection],
        sourceName: String
    ) -> (collections: [LibraryCollection], added: Int) {
        var collections = existing
        var indexes: [String: Int] = [:]
        for (index, collection) in collections.enumerated() where indexes[collection.name] == nil {
            indexes[collection.name] = index
        }
        var items = collections.map(\.items)
        var identities = items.map { Set($0.map(\.id)) }
        var changed = Set<Int>()
        var added = 0
        for addition in additions {
            let index: Int
            if let existingIndex = indexes[addition.collectionName] {
                index = existingIndex
            } else {
                index = collections.count
                indexes[addition.collectionName] = index
                collections.append(LibraryCollection(name: addition.collectionName, description: "Imported from \(sourceName)"))
                items.append([])
                identities.append([])
            }
            guard identities[index].insert(addition.item.id).inserted else { continue }
            items[index].append(addition.item)
            changed.insert(index)
            added += 1
        }
        for index in changed {
            let collection = collections[index]
            collections[index] = LibraryCollection(
                id: collection.id, name: collection.name,
                items: items[index], description: collection.description
            )
        }
        return (collections, added)
    }

    @MainActor
    func captureImport(owner: UUID, invalidation: UInt64?) throws -> CollectionImportSnapshot<LibraryItem> {
        guard activeProfileID == owner,
              invalidation == nil || invalidation == importInvalidationGeneration else { throw CancellationError() }
        let rawValue = UserDefaults.standard.object(forKey: collectionsKey)
        guard !storeLoadFailed, rawValue == nil || rawValue is Data else {
            throw NSError(domain: "LibraryImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Your local collections could not be read. They were preserved without applying this import."])
        }
        return CollectionImportSnapshot(
            owner: owner, storageKey: collectionsKey, revision: mediaStateRevision,
            invalidation: importInvalidationGeneration,
            collections: collections.map { .init(id: $0.id, name: $0.name, items: $0.items, description: $0.description) },
            observedData: rawValue as? Data
        )
    }

    static func prepareImport(
        _ additions: [ImportedItem], sourceName: String, snapshot: CollectionImportSnapshot<LibraryItem>
    ) throws -> PreparedCollectionImport<LibraryItem> {
        try Task.checkCancellation()
        if let data = snapshot.observedData,
           (try? JSONDecoder().decode([LibraryCollection].self, from: data)) == nil {
            throw NSError(domain: "LibraryImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Your local collections could not be read. They were preserved without applying this import."])
        }
        let existing = snapshot.collections.map { LibraryCollection(id: $0.id, name: $0.name, items: $0.items, description: $0.description) }
        let merged = mergingImportedItems(additions, into: existing, sourceName: sourceName)
        let changedIndexes = Set(merged.collections.indices.filter { $0 >= existing.count || merged.collections[$0] !== existing[$0] })
        try Task.checkCancellation()
        let data = merged.added > 0 ? try JSONEncoder().encode(merged.collections) : nil
        try Task.checkCancellation()
        return PreparedCollectionImport(
            collections: merged.collections.map { .init(id: $0.id, name: $0.name, items: $0.items, description: $0.description) },
            changedIndexes: changedIndexes, data: data, added: merged.added
        )
    }

    @MainActor
    func commitImport(_ prepared: PreparedCollectionImport<LibraryItem>, snapshot: CollectionImportSnapshot<LibraryItem>) throws -> Bool {
        try Task.checkCancellation()
        guard activeProfileID == snapshot.owner, collectionsKey == snapshot.storageKey,
              importInvalidationGeneration == snapshot.invalidation, !storeLoadFailed else { throw CancellationError() }
        let rawValue = UserDefaults.standard.object(forKey: collectionsKey)
        guard rawValue == nil || rawValue is Data else {
            throw NSError(domain: "LibraryImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Your local collections could not be read. They were preserved without applying this import."])
        }
        guard mediaStateRevision == snapshot.revision,
              rawValue as? Data == snapshot.observedData else { return false }
        guard let data = prepared.data, prepared.added > 0 else { return true }
        UserDefaults.standard.set(data, forKey: snapshot.storageKey)
        isPublishingImport = true
        let existing = collections
        collections = prepared.collections.enumerated().map { index, candidate in
            guard index < existing.count else {
                return LibraryCollection(id: candidate.id, name: candidate.name, items: candidate.items, description: candidate.description)
            }
            let collection = existing[index]
            if prepared.changedIndexes.contains(index) { collection.items = candidate.items }
            return collection
        }
        isPublishingImport = false
        collectionSavePending = false
        NotificationCenter.default.post(name: .libraryDataDidChange, object: self)
        return true
    }

    @MainActor
    func mergeImportedItems(
        _ additions: [ImportedItem], sourceName: String, owner: UUID,
        validateAuthority: @MainActor () throws -> Void
    ) async throws -> Int {
        var invalidation: UInt64?
        while true {
            try Task.checkCancellation()
            try validateAuthority()
            let snapshot = try captureImport(owner: owner, invalidation: invalidation)
            invalidation = snapshot.invalidation
            let worker = Task.detached(priority: .utility) {
                try Self.prepareImport(additions, sourceName: sourceName, snapshot: snapshot)
            }
            let prepared = try await withTaskCancellationHandler(operation: {
                try await worker.value
            }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            try validateAuthority()
            if try commitImport(prepared, snapshot: snapshot) { return prepared.added }
            await Task.yield()
        }
    }

    func removeItem(from collectionId: UUID, item: LibraryItem) {
        guard let index = collections.firstIndex(where: { $0.id == collectionId }) else { return }
        let existed = collections[index].items.contains { $0.id == item.id }
        guard existed else { return }
        acceptExplicitMutation()
        importInvalidationGeneration &+= 1
        collections[index].items.removeAll { $0.id == item.id }
        notifyTraktWatchlistIfNeeded(collectionName: collections[index].name, item: item, added: false)
    }

    private func acceptExplicitMutation() {
        storeLoadFailed = false
    }

    private func notifyTraktWatchlistIfNeeded(collectionName: String, item: LibraryItem, added: Bool) {
        guard !isApplyingTraktWatchlistSync,
              collectionName == TrackerManager.traktWatchlistCollectionName else { return }
        TrackerManager.shared.pushTraktWatchlistChange(searchResult: item.searchResult, added: added)
    }

    func applyTraktWatchlistPull(_ results: [TMDBSearchResult]) {

        guard !storeLoadFailed else {
            Logger.shared.log(
                "LibraryManager: skipped Trakt watchlist pull because the active library store is unreadable",
                type: "Error"
            )
            return
        }
        isApplyingTraktWatchlistSync = true
        defer { isApplyingTraktWatchlistSync = false }
        let collection = collections.first { $0.name == TrackerManager.traktWatchlistCollectionName }
        var items = collection?.items ?? []
        let initialCount = items.count
        var identities = Set(items.map(\.id))
        for result in results {
            if identities.insert(result.stableIdentity).inserted {
                items.append(LibraryItem(searchResult: result))
            }
        }
        if let collection {
            if items.count != initialCount {
                collection.items = items
            }
        } else {
            isAppendingCollection = true
            collections.append(LibraryCollection(
                name: TrackerManager.traktWatchlistCollectionName,
                items: items,
                description: "Synced with your Trakt watchlist"
            ))
            isAppendingCollection = false
        }
    }

    func moveCollections(from source: IndexSet, to destination: Int) {
        var reorderable = collections.filter { !Self.isBookmarksName($0.name) }
        guard !reorderable.isEmpty else { return }
        acceptExplicitMutation()
        reorderable.move(fromOffsets: source, toOffset: destination)
        var iterator = reorderable.makeIterator()
        collections = collections.map { collection in
            Self.isBookmarksName(collection.name) ? collection : (iterator.next() ?? collection)
        }
    }

    func moveItem(in collectionId: UUID, from source: IndexSet, to destination: Int) {
        guard let index = collections.firstIndex(where: { $0.id == collectionId }) else { return }
        acceptExplicitMutation()
        collections[index].items.move(fromOffsets: source, toOffset: destination)
    }

    func isItemInCollection(_ collectionId: UUID, item: LibraryItem) -> Bool {
        guard let col = collections.first(where: { $0.id == collectionId }) else { return false }
        return col.items.contains { $0.id == item.id }
    }

    func collectionsContainingItem(_ item: LibraryItem) -> [LibraryCollection] {
        return collections.filter { $0.items.contains { $0.id == item.id } }
    }

    func toggleBookmark(for searchResult: TMDBSearchResult) {
        let item = LibraryItem(searchResult: searchResult)

        if let bookmarksCollection = collections.first(where: { Self.isBookmarksName($0.name) }) {
            if isItemInCollection(bookmarksCollection.id, item: item) {
                removeItem(from: bookmarksCollection.id, item: item)
            } else {
                var newItem = item
                newItem.dateAdded = Date()
                addItem(to: bookmarksCollection.id, item: newItem)
            }
        }
    }

    func isBookmarked(_ searchResult: TMDBSearchResult) -> Bool {
        let item = LibraryItem(searchResult: searchResult)
        guard let bookmarksCollection = collections.first(where: { Self.isBookmarksName($0.name) }) else { return false }
        return isItemInCollection(bookmarksCollection.id, item: item)
    }

    private func observeCollection(_ collection: LibraryCollection) {
        if collectionCancellables[collection.id] != nil { return }

        let owner = activeProfileID
        let generation = collectionObservationGeneration
        let cancellable = collection.objectWillChange
            .sink { [weak self, weak collection] _ in
                guard self?.isPublishingImport == false else { return }
                self?.advanceMediaStateRevision()
                self?.collectionSavePending = true
                DispatchQueue.main.async {
                    guard let self, let collection,
                          self.activeProfileID == owner,
                          self.collectionObservationGeneration == generation,
                          self.collections.contains(where: { $0 === collection }) else { return }
                    self.objectWillChange.send()
                    self.save()
                }
            }

        collectionCancellables[collection.id] = cancellable
    }
}
