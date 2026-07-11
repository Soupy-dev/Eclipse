import Combine
import Foundation

final class LibraryManager: ObservableObject {
    static let shared = LibraryManager()
    
    @Published var collections: [LibraryCollection] = [] {
        didSet {
            collections.forEach { observeCollection($0) }
            save()
        }
    }
    
    private let collectionsKey = "libraryCollections"
    private var collectionCancellables: [UUID: AnyCancellable] = [:]
    private var cancellables = Set<AnyCancellable>()

    /// Set while applying a remote Trakt watchlist pull so the resulting collection
    /// mutations don't echo straight back up to Trakt.
    var isApplyingTraktWatchlistSync = false
    
    private init() {
        load()
        createDefaultBookmarksCollection()
        
        collections.forEach { observeCollection($0) }
    }
    
    private func load() {
        if let data = UserDefaults.standard.data(forKey: collectionsKey),
           let decoded = try? JSONDecoder().decode([LibraryCollection].self, from: data) {
            collections = decoded
        }
    }
    
    private func save() {
        if let data = try? JSONEncoder().encode(collections) {
            UserDefaults.standard.set(data, forKey: collectionsKey)
        }
        NotificationCenter.default.post(name: .libraryDataDidChange, object: self)
    }

    /// Applies the media-only state produced by CloudKit. Reader collections are
    /// intentionally owned by a different manager and never enter this path.
    func replaceCollectionsForMediaState(_ newCollections: [LibraryCollection]) {
        collectionCancellables.removeAll()
        collections = newCollections
        createDefaultBookmarksCollection()
        collections.forEach { observeCollection($0) }
    }
    
    private func createDefaultBookmarksCollection() {
        if !collections.contains(where: { $0.name == "Bookmarks" }) {
            let bookmarksCollection = LibraryCollection(name: "Bookmarks", description: "Your bookmarked items")
            collections.insert(bookmarksCollection, at: 0)
        }
    }
    
    func createCollection(name: String, description: String? = nil) {
        let new = LibraryCollection(name: name, description: description)
        collections.append(new)
    }

    func renameCollection(_ collection: LibraryCollection, name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              trimmedName.caseInsensitiveCompare("Bookmarks") != .orderedSame,
              let index = collections.firstIndex(where: { $0.id == collection.id }) else { return }

        collections[index].name = trimmedName
    }

    func deleteCollection(_ collection: LibraryCollection) {
        guard collection.name != "Bookmarks" else { return }
        collectionCancellables[collection.id] = nil
        collections.removeAll { $0.id == collection.id }
    }
    
    func addItem(to collectionId: UUID, item: LibraryItem) {
        guard let index = collections.firstIndex(where: { $0.id == collectionId }),
              !collections[index].items.contains(where: { $0.id == item.id }) else { return }
        collections[index].items.append(item)
        notifyTraktWatchlistIfNeeded(collectionName: collections[index].name, item: item, added: true)
    }

    func removeItem(from collectionId: UUID, item: LibraryItem) {
        guard let index = collections.firstIndex(where: { $0.id == collectionId }) else { return }
        let existed = collections[index].items.contains { $0.id == item.id }
        collections[index].items.removeAll { $0.id == item.id }
        if existed {
            notifyTraktWatchlistIfNeeded(collectionName: collections[index].name, item: item, added: false)
        }
    }

    // MARK: - Trakt Watchlist Sync

    private func notifyTraktWatchlistIfNeeded(collectionName: String, item: LibraryItem, added: Bool) {
        guard !isApplyingTraktWatchlistSync,
              collectionName == TrackerManager.traktWatchlistCollectionName else { return }
        TrackerManager.shared.pushTraktWatchlistChange(searchResult: item.searchResult, added: added)
    }

    /// Merge Trakt watchlist results into the local "Trakt Watchlist" collection without
    /// deleting anything. Suppresses the push hook so the pull doesn't echo back to Trakt.
    func applyTraktWatchlistPull(_ results: [TMDBSearchResult]) {
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
    
    func isItemInCollection(_ collectionId: UUID, item: LibraryItem) -> Bool {
        guard let col = collections.first(where: { $0.id == collectionId }) else { return false }
        return col.items.contains { $0.id == item.id }
    }
    
    func collectionsContainingItem(_ item: LibraryItem) -> [LibraryCollection] {
        return collections.filter { $0.items.contains { $0.id == item.id } }
    }
    
    // MARK: - Bookmark Functions
    func toggleBookmark(for searchResult: TMDBSearchResult) {
        let item = LibraryItem(searchResult: searchResult)
        
        if let bookmarksCollection = collections.first(where: { $0.name == "Bookmarks" }) {
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
        guard let bookmarksCollection = collections.first(where: { $0.name == "Bookmarks" }) else { return false }
        return isItemInCollection(bookmarksCollection.id, item: item)
    }
    
    // MARK: - Observation
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
