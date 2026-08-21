//
//  LibraryManager.swift
//  Sora
//
//  Created by Francesco on 08/09/25.
//

import Combine
import Foundation

final class LibraryManager: ObservableObject {
    static let shared = LibraryManager()

    static let bookmarksCollectionName = "Bookmarks"
    private static let bookmarksCollectionDescription = "Your bookmarked items"
    private static let bookmarksCollectionIDNamespace = UUID(
        uuid: (0x3e, 0x02, 0xad, 0x8c, 0x84, 0x2c, 0x4b, 0x9f, 0xae, 0x08, 0xb3, 0x7d, 0x44, 0x64, 0xb9, 0xc5)
    )

    @Published private(set) var collections: [LibraryCollection] = [] {
        didSet {
            collections.forEach { observeCollection($0) }
            save()
        }
    }

    private static let legacyCollectionsKey = "libraryCollections"

    private var collectionsKey: String
    private var activeProfileID: UUID
    private var collectionCancellables: [UUID: AnyCancellable] = [:]
    private var cancellables = Set<AnyCancellable>()

    private var isSwitchingProfile = false

    private var storeLoadFailed = false

    var isApplyingTraktWatchlistSync = false

    private init() {
        let profileID = ProfileManager.shared.activeProfileID
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
        isSwitchingProfile = true
        activeProfileID = profileID
        collectionsKey = Self.collectionsKey(for: profileID)
        collectionCancellables.removeAll()
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
        guard !isSwitchingProfile else { return }

        guard !storeLoadFailed else {
            Logger.shared.log(
                "LibraryManager: refused to save over collections that failed to decode",
                type: "Error"
            )
            return
        }
        if let data = try? JSONEncoder().encode(collections) {
            UserDefaults.standard.set(data, forKey: collectionsKey)
        }
        NotificationCenter.default.post(name: .libraryDataDidChange, object: self)
    }

    func replaceCollectionsForMediaState(_ newCollections: [LibraryCollection]) {

        storeLoadFailed = false
        collectionCancellables.removeAll()
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
        collections.append(new)
        return true
    }

    func renameCollection(_ collection: LibraryCollection, name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              !Self.isBookmarksName(trimmedName),
              let index = collections.firstIndex(where: { $0.id == collection.id }),
              !Self.isBookmarksName(collections[index].name) else { return }

        acceptExplicitMutation()
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

    func removeItem(from collectionId: UUID, item: LibraryItem) {
        guard let index = collections.firstIndex(where: { $0.id == collectionId }) else { return }
        let existed = collections[index].items.contains { $0.id == item.id }
        guard existed else { return }
        acceptExplicitMutation()
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
        guard let index = ensureTraktWatchlistCollectionIndex() else { return }
        isApplyingTraktWatchlistSync = true
        defer { isApplyingTraktWatchlistSync = false }
        for result in results {
            let item = LibraryItem(searchResult: result)
            if !collections[index].items.contains(where: { $0.id == item.id }) {
                collections[index].items.append(item)
            }
        }
    }

    private func ensureTraktWatchlistCollectionIndex() -> Int? {
        if let idx = collections.firstIndex(where: { $0.name == TrackerManager.traktWatchlistCollectionName }) {
            return idx
        }
        createCollection(name: TrackerManager.traktWatchlistCollectionName, description: "Synced with your Trakt watchlist")
        return collections.firstIndex(where: { $0.name == TrackerManager.traktWatchlistCollectionName })
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

        let cancellable = collection.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.objectWillChange.send()
                    self?.save()
                }
            }

        collectionCancellables[collection.id] = cancellable
    }
}
