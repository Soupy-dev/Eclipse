//
//  MangaLibraryManager.swift
//  Kanzen
//
//  Created by Eclipse on 2026.
//

import Foundation
import Combine

struct MangaLibraryRefreshSummary {
    var refreshed = 0
    var failed = 0
    var skipped = 0

    var statusText: String {
        if refreshed == 0 && failed == 0 && skipped == 0 {
            return "No saved titles to refresh."
        }
        var parts: [String] = []
        if refreshed > 0 { parts.append("\(refreshed) refreshed") }
        if failed > 0 { parts.append("\(failed) failed") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        return parts.joined(separator: ", ")
    }
}

final class MangaLibraryManager: ObservableObject {
    static let shared = MangaLibraryManager()

    @Published var collections: [MangaLibraryCollection] = [] {
        didSet {
            collections.forEach { observeCollection($0) }
            save()
        }
    }

    private static let legacyStorageKey = "mangaLibraryCollections"

    private var storageKey: String
    private var activeProfileID: UUID
    private var collectionCancellables: [UUID: AnyCancellable] = [:]

    private var isSwitchingProfile = false

    private init() {
        let profileID = ProfileManager.shared.activeProfileID
        activeProfileID = profileID
        storageKey = Self.storageKey(for: profileID)
        Self.migrateLegacyStoreIfNeeded()
        isSwitchingProfile = true
        load()
        createDefaultBookmarksCollection()
        isSwitchingProfile = false
        save()
        collections.forEach { observeCollection($0) }
    }

    static func storageKey(for profileID: UUID) -> String {
        ProfileScopedStorage.defaultsKey(base: legacyStorageKey, profileID: profileID)
    }

    private static func migrateLegacyStoreIfNeeded() {
        ProfileScopedStorage.migrateLegacyStoreIfNeeded(marker: "readerLibrary") {
            let defaults = UserDefaults.standard
            let destinationKey = storageKey(for: ProfileManager.defaultProfileID)
            guard defaults.data(forKey: destinationKey) == nil,
                  let legacy = defaults.data(forKey: legacyStorageKey) else { return }
            defaults.set(legacy, forKey: destinationKey)
            defaults.removeObject(forKey: legacyStorageKey)
        }
    }

    func switchProfile(to profileID: UUID) {
        guard profileID != activeProfileID else { return }
        isSwitchingProfile = true
        activeProfileID = profileID
        storageKey = Self.storageKey(for: profileID)
        collectionCancellables.removeAll()
        collections = Self.adoptCollections(forKey: storageKey)
        createDefaultBookmarksCollection()
        isSwitchingProfile = false
        collections.forEach { observeCollection($0) }
        save()
    }

    func discardStore(forProfile profileID: UUID) {
        guard profileID != activeProfileID else { return }
        UserDefaults.standard.removeObject(forKey: Self.storageKey(for: profileID))
    }

    private static func loadCollections(
        forKey key: String
    ) -> (collections: [MangaLibraryCollection], unreadable: Bool) {
        persistedCollections(from: UserDefaults.standard.data(forKey: key))
    }

    static func persistedCollections(
        from data: Data?
    ) -> (collections: [MangaLibraryCollection], unreadable: Bool) {
        guard let data, !data.isEmpty else {
            return ([], false)
        }
        guard let decoded = try? JSONDecoder().decode([MangaLibraryCollection].self, from: data) else {
            return ([], true)
        }
        return (decoded, false)
    }

    static func persistedCollectionsSchemaIsValid(_ data: Data) -> Bool {
        (try? JSONDecoder().decode([MangaLibraryCollection].self, from: data)) != nil
    }

    private func load() {
        collections = Self.adoptCollections(forKey: storageKey)
    }

    private static func adoptCollections(forKey key: String) -> [MangaLibraryCollection] {
        let loaded = loadCollections(forKey: key)
        if loaded.unreadable {
            quarantineUnreadableStore(forKey: key)
        }
        return loaded.collections
    }

    private static func quarantineUnreadableStore(forKey key: String) {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: key) else { return }
        let quarantineKey = "\(key)-unreadable-\(Int(Date().timeIntervalSince1970))"
        defaults.set(data, forKey: quarantineKey)
        defaults.removeObject(forKey: key)
        ReaderLogger.shared.log(
            "MangaLibraryManager: moved an unreadable collections store aside as \(quarantineKey) and started a fresh store",
            type: "Error"
        )
    }

    private func save() {
        guard !isSwitchingProfile else { return }
        if let data = try? JSONEncoder().encode(collections) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    func collections(forProfile profileID: UUID) -> [MangaLibraryCollection] {
        collectionsSnapshot(forProfile: profileID) ?? []
    }

    func collectionsSnapshot(forProfile profileID: UUID) -> [MangaLibraryCollection]? {
        let key = profileID == activeProfileID ? storageKey : Self.storageKey(for: profileID)
        let loaded = Self.loadCollections(forKey: key)
        guard !loaded.unreadable else {
            ReaderLogger.shared.log(
                "MangaLibraryManager: profile \(profileID) has an unreadable collections store; preserving its bytes",
                type: "Error"
            )
            return nil
        }
        return loaded.collections
    }

    func applyRestoredCollections(_ restored: [MangaLibraryCollection], forProfile profileID: UUID) {
        guard profileID != activeProfileID else {
            collectionCancellables.removeAll()
            collections = restored
            createDefaultBookmarksCollection()
            collections.forEach { observeCollection($0) }
            save()
            return
        }
        guard let data = try? JSONEncoder().encode(restored) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey(for: profileID))
    }

    private func createDefaultBookmarksCollection() {
        if !collections.contains(where: { $0.name == "Bookmarks" }) {
            let bookmarks = MangaLibraryCollection(name: "Bookmarks", description: "Your bookmarked manga")
            collections.insert(bookmarks, at: 0)
        }
    }

    func createCollection(name: String, description: String? = nil) {
        let collection = MangaLibraryCollection(name: name, description: description)
        collections.append(collection)
    }

    func renameCollection(_ collection: MangaLibraryCollection, name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              trimmedName.caseInsensitiveCompare("Bookmarks") != .orderedSame,
              let index = collections.firstIndex(where: { $0.id == collection.id }) else { return }

        collections[index].name = trimmedName
    }

    func deleteCollection(_ collection: MangaLibraryCollection) {
        guard collection.name != "Bookmarks" else { return }
        collectionCancellables[collection.id] = nil
        collections.removeAll { $0.id == collection.id }
    }

    func addItem(to collectionId: UUID, item: MangaLibraryItem) {
        guard let idx = collections.firstIndex(where: { $0.id == collectionId }),
              !collections[idx].items.contains(where: { $0.id == item.id }) else { return }
        collections[idx].items.append(mergedWithKnownMetadata(item))
    }

    func removeItem(from collectionId: UUID, item: MangaLibraryItem) {
        guard let idx = collections.firstIndex(where: { $0.id == collectionId }) else { return }
        collections[idx].items.removeAll { $0.id == item.id }
    }

    func isItemInCollection(_ collectionId: UUID, item: MangaLibraryItem) -> Bool {
        guard let col = collections.first(where: { $0.id == collectionId }) else { return false }
        return col.items.contains { $0.id == item.id }
    }

    func collectionsContainingItem(_ item: MangaLibraryItem) -> [MangaLibraryCollection] {
        collections.filter { $0.items.contains { $0.id == item.id } }
    }

    func toggleBookmark(_ item: MangaLibraryItem) {
        guard let bookmarks = collections.first(where: { $0.name == "Bookmarks" }) else { return }
        if isItemInCollection(bookmarks.id, item: item) {
            removeItem(from: bookmarks.id, item: item)
        } else {
            var newItem = item
            newItem.dateAdded = Date()
            addItem(to: bookmarks.id, item: newItem)
        }
    }

    func isBookmarked(_ item: MangaLibraryItem) -> Bool {
        guard let bookmarks = collections.first(where: { $0.name == "Bookmarks" }) else { return false }
        return isItemInCollection(bookmarks.id, item: item)
    }

    @MainActor
    func refreshAllSources() async -> MangaLibraryRefreshSummary {
        await refreshItems(uniqueSavedItems())
    }

    @MainActor
    func refreshSource(for collection: MangaLibraryCollection) async -> MangaLibraryRefreshSummary {
        await refreshItems(uniqueItems(collection.items))
    }

    func updateSavedItem(_ item: MangaLibraryItem) {
        replaceSavedItem(item)
    }

    private func observeCollection(_ collection: MangaLibraryCollection) {
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

    private func uniqueSavedItems() -> [MangaLibraryItem] {
        uniqueItems(collections.flatMap(\.items))
    }

    private func uniqueItems(_ items: [MangaLibraryItem]) -> [MangaLibraryItem] {
        var seen = Set<Int>()
        var unique: [MangaLibraryItem] = []
        for item in items where !seen.contains(item.id) {
            seen.insert(item.id)
            unique.append(mergedWithKnownMetadata(item))
        }
        return unique
    }

    private func mergedWithKnownMetadata(_ item: MangaLibraryItem) -> MangaLibraryItem {
        guard let existing = collections.flatMap(\.items).first(where: { $0.id == item.id }) else {
            return item
        }

        var merged = item
        if merged.latestChapterNumbers == nil { merged.latestChapterNumbers = existing.latestChapterNumbers }
        if merged.totalChapters == nil { merged.totalChapters = existing.totalChapters }
        if merged.sourceName == nil { merged.sourceName = existing.sourceName }
        if merged.lastSourceRefresh == nil { merged.lastSourceRefresh = existing.lastSourceRefresh }
        if merged.sourceRefreshError == nil { merged.sourceRefreshError = existing.sourceRefreshError }
        if merged.trackerAniListId == nil { merged.trackerAniListId = existing.trackerAniListId }
        if merged.trackerMALId == nil { merged.trackerMALId = existing.trackerMALId }
        if merged.trackerMatchConfidence == nil { merged.trackerMatchConfidence = existing.trackerMatchConfidence }
        if merged.trackerResolvedAt == nil { merged.trackerResolvedAt = existing.trackerResolvedAt }
        merged.contentRating = mergedContentRating(incoming: merged.contentRating, existing: existing.contentRating)
        return merged
    }

    private func mergedContentRating(incoming: Int?, existing: Int?) -> Int? {
        guard let incoming else { return existing }
        guard let existing else { return incoming }
        return max(incoming, existing)
    }

    private func replaceSavedItem(_ item: MangaLibraryItem) {
        var changed = false
        for collection in collections {
            guard let index = collection.items.firstIndex(where: { $0.id == item.id }) else { continue }
            let stored = collection.items[index]
            var updated = item
            updated.dateAdded = stored.dateAdded
            updated.contentRating = mergedContentRating(incoming: item.contentRating, existing: stored.contentRating)
            collection.items[index] = updated
            changed = true
        }
        if changed {
            save()
            objectWillChange.send()
        }
    }

    private func replaceSavedItem(_ item: MangaLibraryItem, inStoreForProfile profileID: UUID) {
        let key = Self.storageKey(for: profileID)
        let loaded = Self.loadCollections(forKey: key)
        guard !loaded.unreadable else {
            ReaderLogger.shared.log(
                "Dropping a late library write for profile \(profileID): its store could not be read",
                type: "Error"
            )
            return
        }
        var changed = false
        for collection in loaded.collections {
            guard let index = collection.items.firstIndex(where: { $0.id == item.id }) else { continue }
            let stored = collection.items[index]
            var updated = item
            updated.dateAdded = stored.dateAdded
            updated.contentRating = mergedContentRating(incoming: item.contentRating, existing: stored.contentRating)
            collection.items[index] = updated
            changed = true
        }
        guard changed, let data = try? JSONEncoder().encode(loaded.collections) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    @MainActor
    private func refreshItems(_ items: [MangaLibraryItem]) async -> MangaLibraryRefreshSummary {
        var summary = MangaLibraryRefreshSummary()

        let owner = activeProfileID

        for item in items {
            guard activeProfileID == owner else {
                ReaderLogger.shared.log(
                    "Library refresh abandoned: the active profile changed while it was running",
                    type: "Reader"
                )
                summary.skipped += items.count - summary.refreshed - summary.failed - summary.skipped
                return summary
            }
            guard fallbackRoute(for: item) != nil else {
                summary.skipped += 1
                continue
            }

            do {
                let refreshed = try await refreshItem(item)
                if activeProfileID == owner {
                    replaceSavedItem(refreshed)
                } else {
                    replaceSavedItem(refreshed, inStoreForProfile: owner)
                }
                MangaReadingProgressManager.shared.updateSourceMetadata(
                    mangaId: refreshed.id,
                    title: refreshed.title,
                    coverURL: refreshed.coverURL,
                    format: refreshed.format,
                    latestChapterNumbers: refreshed.latestChapterNumbers ?? [],
                    route: refreshed.route,
                    sourceRefreshError: nil,
                    forProfile: owner
                )
                summary.refreshed += 1
            } catch {
                var failedItem = item
                failedItem.lastSourceRefresh = Date()
                failedItem.sourceRefreshError = error.localizedDescription
                if activeProfileID == owner {
                    replaceSavedItem(failedItem)
                } else {
                    replaceSavedItem(failedItem, inStoreForProfile: owner)
                }
                ReaderLogger.shared.log("Library refresh failed title='\(item.title)': \(error.localizedDescription)", type: "Reader")
                summary.failed += 1
            }
        }

        return summary
    }

    @MainActor
    private func refreshItem(_ item: MangaLibraryItem) async throws -> MangaLibraryItem {
        let route = item.route ?? fallbackRoute(for: item)
        guard let route else {
            throw NSError(domain: "MangaLibraryRefresh", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing source route"])
        }

        switch route {
        case .readerExtension(let sourceID, let itemKey, let legacyStableKey):
            return try await refreshReaderExtensionItem(
                item,
                sourceID: sourceID,
                itemKey: itemKey,
                legacyStableKey: legacyStableKey
            )
        case .aidoku:
            throw NSError(
                domain: "MangaLibraryRefresh",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Previous Reader source unavailable. Reconnect this title to refresh it."]
            )
        case .legacyModule(let moduleUUID, let contentParams, let isNovel):
            return try await refreshLegacyModuleItem(item, moduleUUIDString: moduleUUID, contentParams: contentParams, isNovel: isNovel)
        }
    }

    private func fallbackRoute(for item: MangaLibraryItem) -> MangaContentRoute? {
        if let route = item.route {
            return route
        }
        if let moduleUUID = item.moduleUUID, let contentParams = item.contentParams {
            return .legacyModule(moduleUUID: moduleUUID, contentParams: contentParams, isNovel: item.isNovel ?? false)
        }
        if let progress = MangaReadingProgressManager.shared.progress(for: item.id), let route = progress.route {
            return route
        }
        return nil
    }

    @MainActor
    private func refreshReaderExtensionItem(
        _ item: MangaLibraryItem,
        sourceID: ReaderExtensionSourceID,
        itemKey: String,
        legacyStableKey: String?
    ) async throws -> MangaLibraryItem {
        let sourceManager = ReaderExtensionManager.shared
        guard let metadata = sourceManager.installedSources.first(where: { $0.id == sourceID }) else {
            throw NSError(domain: "MangaLibraryRefresh", code: -2, userInfo: [NSLocalizedDescriptionKey: "Reader Extension is missing"])
        }
        guard metadata.enabled else {
            throw NSError(domain: "MangaLibraryRefresh", code: -3, userInfo: [NSLocalizedDescriptionKey: "\(metadata.name) is disabled"])
        }

        let provider = try sourceManager.provider(for: sourceID)
        let seed = ReaderExtensionItem(
            key: itemKey,
            title: item.title,
            coverURL: item.coverURL.flatMap(URL.init(string:)),
            maturity: metadata.maturity
        )
        let updated = seed.mergingDetail(try await provider.detail(itemKey: itemKey))
        let chapters = try await provider.chapters(itemKey: itemKey)

        var refreshed = item
        refreshed.title = updated.title
        refreshed.coverURL = ReaderExtensionSafeMetadata.sanitizedURLString(
            updated.coverURL,
            fallback: item.coverURL
        )
        refreshed.format = metadata.mediaType == .novel ? "NOVEL" : "MANGA"
        refreshed.contentRating = ReaderContentFilter.shared.derivedReaderExtensionRating(for: updated)
        refreshed.sourceName = metadata.name
        refreshed.latestChapterNumbers = chapterNumbers(from: chapters)
        refreshed.totalChapters = refreshed.latestChapterNumbers?.count
        refreshed.lastSourceRefresh = Date()
        refreshed.sourceRefreshError = nil
        refreshed.route = .readerExtension(
            source: sourceID,
            itemKey: updated.key,
            legacyStableKey: legacyStableKey
        )
        return refreshed
    }

    @MainActor
    private func refreshLegacyModuleItem(_ item: MangaLibraryItem, moduleUUIDString: String, contentParams: String, isNovel: Bool) async throws -> MangaLibraryItem {
        guard let moduleUUID = UUID(uuidString: moduleUUIDString),
              let module = ModuleManager.shared.getModule(moduleUUID) else {
            throw NSError(domain: "MangaLibraryRefresh", code: -4, userInfo: [NSLocalizedDescriptionKey: "Legacy source module is missing"])
        }

        let engine = KanzenEngine()
        let script = try ModuleManager.shared.getModuleScript(module: module)
        try await engine.loadScript(script, module: module)
        let result = try await extractChapters(engine: engine, params: contentParams)
        let numbers = legacyChapterNumbers(from: result)
        let details = await extractDetails(engine: engine, params: contentParams)

        var refreshed = item
        if let derivedRating = ReaderContentFilter.shared.derivedLegacyRating(
            tags: details?["tags"] as? [String],
            description: details?["description"] as? String
        ) {
            refreshed.contentRating = derivedRating
        }
        refreshed.sourceName = module.moduleData.sourceName
        refreshed.format = isNovel ? "NOVEL" : (item.format ?? "MANGA")
        refreshed.latestChapterNumbers = numbers
        refreshed.totalChapters = numbers.count
        refreshed.lastSourceRefresh = Date()
        refreshed.sourceRefreshError = nil
        refreshed.route = .legacyModule(moduleUUID: moduleUUIDString, contentParams: contentParams, isNovel: isNovel)
        refreshed.moduleUUID = moduleUUIDString
        refreshed.contentParams = contentParams
        refreshed.isNovel = isNovel
        return refreshed
    }

    private func extractChapters(engine: KanzenEngine, params: String) async throws -> Any {
        guard let result = try await engine.extractChapters(params: params) else {
            throw NSError(
                domain: "MangaLibraryRefresh",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "Source returned no chapters"]
            )
        }
        return result
    }

    private func extractDetails(engine: KanzenEngine, params: String) async -> [String: Any]? {
        try? await engine.extractDetails(params: params)
    }

    private func chapterNumbers(from chapters: [ReaderExtensionChapter]) -> [String] {
        let numbers = chapters.enumerated().map { index, chapter in
            let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                return title
            }
            return "Chapter \(index + 1)"
        }
        return ChapterIdentityNormalizer.deduplicatedNumbers(numbers)
    }

    private func legacyChapterNumbers(from result: Any) -> [String] {
        if let dict = result as? [String: Any] {
            let groups = dict.values.map { legacyChapterNumbers(from: $0) }
            return groups.max(by: { $0.count < $1.count }) ?? []
        }

        if let array = result as? [Any] {
            var numbers: [String] = []
            for (index, raw) in array.enumerated() {
                if let chapter = raw as? [Any], let first = chapter.first as? String {
                    numbers.append(first)
                } else if let chapter = raw as? [String: Any] {
                    if let number = chapter["number"] as? Int {
                        numbers.append(String(number))
                    } else if let number = chapter["number"] as? Double {
                        numbers.append(formatNumber(number))
                    } else if let title = chapter["title"] as? String, !title.isEmpty {
                        numbers.append(title)
                    } else {
                        numbers.append("Chapter \(index + 1)")
                    }
                } else {
                    numbers.append("Chapter \(index + 1)")
                }
            }
            return ChapterIdentityNormalizer.deduplicatedNumbers(numbers)
        }

        return []
    }

    private func formatNumber(_ value: Float) -> String {
        guard value.isFinite,
              value.truncatingRemainder(dividingBy: 1) == 0,
              let integer = Int(exactly: value) else {
            return String(value)
        }
        return String(integer)
    }

    private func formatNumber(_ value: Double) -> String {
        guard value.isFinite,
              value.truncatingRemainder(dividingBy: 1) == 0,
              let integer = Int(exactly: value) else {
            return String(value)
        }
        return String(integer)
    }

}
