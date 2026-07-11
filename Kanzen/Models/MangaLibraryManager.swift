import Foundation
import Combine
#if !os(tvOS)
import AidokuRunner
#endif

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

    private let storageKey = "mangaLibraryCollections"
    private var collectionCancellables: [UUID: AnyCancellable] = [:]

    private init() {
        load()
        createDefaultBookmarksCollection()
        collections.forEach { observeCollection($0) }
    }

    // MARK: - Persistence

    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([MangaLibraryCollection].self, from: data) {
            collections = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(collections) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func createDefaultBookmarksCollection() {
        if !collections.contains(where: { $0.name == "Bookmarks" }) {
            let bookmarks = MangaLibraryCollection(name: "Bookmarks", description: "Your bookmarked manga")
            collections.insert(bookmarks, at: 0)
        }
    }

    // MARK: - Collection CRUD

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

    // MARK: - Item CRUD

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

    // MARK: - Bookmark Shortcuts

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

    // MARK: - Source Refresh

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

    // MARK: - Observation

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
        return merged
    }

    private func replaceSavedItem(_ item: MangaLibraryItem) {
        var changed = false
        for collection in collections {
            guard let index = collection.items.firstIndex(where: { $0.id == item.id }) else { continue }
            var updated = item
            updated.dateAdded = collection.items[index].dateAdded
            collection.items[index] = updated
            changed = true
        }
        if changed {
            save()
            objectWillChange.send()
        }
    }

    @MainActor
    private func refreshItems(_ items: [MangaLibraryItem]) async -> MangaLibraryRefreshSummary {
        var summary = MangaLibraryRefreshSummary()

        for item in items {
            guard fallbackRoute(for: item) != nil else {
                summary.skipped += 1
                continue
            }

            do {
                let refreshed = try await refreshItem(item)
                replaceSavedItem(refreshed)
                MangaReadingProgressManager.shared.updateSourceMetadata(
                    mangaId: refreshed.id,
                    title: refreshed.title,
                    coverURL: refreshed.coverURL,
                    format: refreshed.format,
                    latestChapterNumbers: refreshed.latestChapterNumbers ?? [],
                    route: refreshed.route,
                    sourceRefreshError: nil
                )
                summary.refreshed += 1
            } catch {
                var failedItem = item
                failedItem.lastSourceRefresh = Date()
                failedItem.sourceRefreshError = error.localizedDescription
                replaceSavedItem(failedItem)
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
        case .aidoku(let sourceId, let mangaKey):
            return try await refreshAidokuItem(item, sourceId: sourceId, mangaKey: mangaKey)
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
    private func refreshAidokuItem(_ item: MangaLibraryItem, sourceId: String, mangaKey: String) async throws -> MangaLibraryItem {
        let sourceManager = AidokuSourceManager.shared
        guard let metadata = sourceManager.metadata(id: sourceId) else {
            throw NSError(domain: "MangaLibraryRefresh", code: -2, userInfo: [NSLocalizedDescriptionKey: "Aidoku source is missing"])
        }
        guard metadata.isEnabled else {
            throw NSError(domain: "MangaLibraryRefresh", code: -3, userInfo: [NSLocalizedDescriptionKey: "\(metadata.name) is disabled"])
        }

        let seed = AidokuRunner.Manga(
            sourceKey: sourceId,
            key: mangaKey,
            title: item.title,
            cover: item.coverURL
        )
        let updated = try await sourceManager.mangaUpdate(
            sourceId: sourceId,
            manga: seed,
            needsDetails: true,
            needsChapters: true
        )

        var refreshed = item
        refreshed.title = updated.title
        refreshed.coverURL = updated.cover ?? item.coverURL
        refreshed.format = formatTitle(for: updated.viewer)
        refreshed.sourceName = metadata.name
        refreshed.latestChapterNumbers = chapterNumbers(from: updated.chapters ?? [])
        refreshed.totalChapters = refreshed.latestChapterNumbers?.count
        refreshed.lastSourceRefresh = Date()
        refreshed.sourceRefreshError = nil
        refreshed.route = .aidoku(sourceId: sourceId, mangaKey: updated.key)
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
        try engine.loadScript(script, isNovel: isNovel)
        let result = try await extractChapters(engine: engine, params: contentParams)
        let numbers = legacyChapterNumbers(from: result)

        var refreshed = item
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
        try await withCheckedThrowingContinuation { continuation in
            engine.extractChapters(params: params) { result in
                guard let result else {
                    continuation.resume(throwing: NSError(domain: "MangaLibraryRefresh", code: -5, userInfo: [NSLocalizedDescriptionKey: "Source returned no chapters"]))
                    return
                }
                continuation.resume(returning: result)
            }
        }
    }

    private func chapterNumbers(from chapters: [AidokuRunner.Chapter]) -> [String] {
        let numbers = chapters.enumerated().map { index, chapter in
            if let volume = chapter.volumeNumber, let number = chapter.chapterNumber {
                return "Vol. \(formatNumber(volume)) Ch. \(formatNumber(number))"
            }
            if let number = chapter.chapterNumber {
                return "Chapter \(formatNumber(number))"
            }
            if let title = chapter.title, !title.isEmpty {
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
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(value)
    }

    private func formatNumber(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(value)
    }

    private func formatTitle(for viewer: AidokuRunner.Viewer) -> String {
        switch viewer {
        case .vertical, .webtoon:
            return "WEBTOON"
        default:
            return "MANGA"
        }
    }
}
