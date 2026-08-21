//
//  MangaReadingProgressManager.swift
//  Kanzen
//
//  Created by Eclipse on 2026.
//

import Foundation

struct MangaProgress: Codable {
    var readChapterNumbers: Set<String> = []
    var lastReadChapter: String?
    var lastReadDate: Date?

    var pagePositions: [String: Int] = [:]

    var pageCounts: [String: Int] = [:]

    var title: String?
    var coverURL: String?
    var format: String?
    var totalChapters: Int?
    var latestChapterNumbers: [String]?
    var lastSourceRefresh: Date?
    var sourceRefreshError: String?
    var trackerAniListId: Int?
    var trackerMALId: Int?
    var trackerMatchConfidence: Double?
    var trackerResolvedAt: Date?

    var moduleUUID: String?
    var contentParams: String?
    var isNovel: Bool?
    var route: MangaContentRoute?

    enum CodingKeys: String, CodingKey {
        case readChapterNumbers
        case lastReadChapter
        case lastReadDate
        case pagePositions
        case pageCounts
        case title
        case coverURL
        case format
        case totalChapters
        case latestChapterNumbers
        case lastSourceRefresh
        case sourceRefreshError
        case trackerAniListId
        case trackerMALId
        case trackerMatchConfidence
        case trackerResolvedAt
        case moduleUUID
        case contentParams
        case isNovel
        case route
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        readChapterNumbers = try container.decodeIfPresent(Set<String>.self, forKey: .readChapterNumbers) ?? []
        lastReadChapter = try container.decodeIfPresent(String.self, forKey: .lastReadChapter)
        lastReadDate = try container.decodeIfPresent(Date.self, forKey: .lastReadDate)
        pagePositions = try container.decodeIfPresent([String: Int].self, forKey: .pagePositions) ?? [:]
        pageCounts = try container.decodeIfPresent([String: Int].self, forKey: .pageCounts) ?? [:]
        title = try container.decodeIfPresent(String.self, forKey: .title)
        coverURL = try container.decodeIfPresent(String.self, forKey: .coverURL)
        format = try container.decodeIfPresent(String.self, forKey: .format)
        totalChapters = try container.decodeIfPresent(Int.self, forKey: .totalChapters)
        latestChapterNumbers = try container.decodeIfPresent([String].self, forKey: .latestChapterNumbers)
        lastSourceRefresh = try container.decodeIfPresent(Date.self, forKey: .lastSourceRefresh)
        sourceRefreshError = try container.decodeIfPresent(String.self, forKey: .sourceRefreshError)
        trackerAniListId = try container.decodeIfPresent(Int.self, forKey: .trackerAniListId)
        trackerMALId = try container.decodeIfPresent(Int.self, forKey: .trackerMALId)
        trackerMatchConfidence = try container.decodeIfPresent(Double.self, forKey: .trackerMatchConfidence)
        trackerResolvedAt = try container.decodeIfPresent(Date.self, forKey: .trackerResolvedAt)
        moduleUUID = try container.decodeIfPresent(String.self, forKey: .moduleUUID)
        contentParams = try container.decodeIfPresent(String.self, forKey: .contentParams)
        isNovel = try container.decodeIfPresent(Bool.self, forKey: .isNovel)
        route = try container.decodeIfPresent(MangaContentRoute.self, forKey: .route)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(readChapterNumbers.sorted(), forKey: .readChapterNumbers)
        try container.encodeIfPresent(lastReadChapter, forKey: .lastReadChapter)
        try container.encodeIfPresent(lastReadDate, forKey: .lastReadDate)
        try container.encode(pagePositions, forKey: .pagePositions)
        try container.encode(pageCounts, forKey: .pageCounts)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(coverURL, forKey: .coverURL)
        try container.encodeIfPresent(format, forKey: .format)
        try container.encodeIfPresent(totalChapters, forKey: .totalChapters)
        try container.encodeIfPresent(latestChapterNumbers, forKey: .latestChapterNumbers)
        try container.encodeIfPresent(lastSourceRefresh, forKey: .lastSourceRefresh)
        try container.encodeIfPresent(sourceRefreshError, forKey: .sourceRefreshError)
        try container.encodeIfPresent(trackerAniListId, forKey: .trackerAniListId)
        try container.encodeIfPresent(trackerMALId, forKey: .trackerMALId)
        try container.encodeIfPresent(trackerMatchConfidence, forKey: .trackerMatchConfidence)
        try container.encodeIfPresent(trackerResolvedAt, forKey: .trackerResolvedAt)
        try container.encodeIfPresent(moduleUUID, forKey: .moduleUUID)
        try container.encodeIfPresent(contentParams, forKey: .contentParams)
        try container.encodeIfPresent(isNovel, forKey: .isNovel)
        try container.encodeIfPresent(route, forKey: .route)
    }
}

final class MangaReadingProgressManager: ObservableObject {
    static let shared = MangaReadingProgressManager()

    @Published private(set) var progressMap: [Int: MangaProgress] = [:]

    private static let legacyStorageKey = "mangaReadingProgress"

    private var storageKey: String
    private var activeProfileID: UUID

    private var activeStoreLoadFailed = false

    private init() {
        let profileID = ProfileManager.shared.activeProfileID
        activeProfileID = profileID
        storageKey = Self.storageKey(for: profileID)
        Self.migrateLegacyStoreIfNeeded()
        load()
    }

    static func storageKey(for profileID: UUID) -> String {
        ProfileScopedStorage.defaultsKey(base: legacyStorageKey, profileID: profileID)
    }

    private static func migrateLegacyStoreIfNeeded() {
        ProfileScopedStorage.migrateLegacyStoreIfNeeded(marker: "readerProgress") {
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
        activeProfileID = profileID
        storageKey = Self.storageKey(for: profileID)

        progressMap = [:]
        load()
    }

    func discardStore(forProfile profileID: UUID) {
        guard profileID != activeProfileID else { return }
        UserDefaults.standard.removeObject(forKey: Self.storageKey(for: profileID))
    }

    func isChapterRead(mangaId: Int, chapterNumber: String) -> Bool {
        guard let progress = progressMap[mangaId] else { return false }
        return containsChapter(chapterNumber, in: progress.readChapterNumbers)
    }

    func readChapters(for mangaId: Int) -> Set<String> {
        progressMap[mangaId]?.readChapterNumbers ?? []
    }

    func lastReadChapter(for mangaId: Int) -> String? {
        progressMap[mangaId]?.lastReadChapter
    }

    func pagePosition(mangaId: Int, chapterNumber: String) -> Int {
        guard let positions = progressMap[mangaId]?.pagePositions else { return 0 }
        return storedValue(in: positions, for: chapterNumber) ?? 0
    }

    func pagePosition(mangaId: Int, chapterNumber: String, forProfile profileID: UUID) -> Int {
        guard profileID != activeProfileID else {
            return pagePosition(mangaId: mangaId, chapterNumber: chapterNumber)
        }
        guard let positions = progress(forProfile: profileID)[mangaId]?.pagePositions else { return 0 }
        return storedValue(in: positions, for: chapterNumber) ?? 0
    }

    func pageProgress(mangaId: Int, chapterNumber: String) -> (page: Int, total: Int)? {
        guard let progress = progressMap[mangaId] else { return nil }
        let zeroBasedPage = storedValue(in: progress.pagePositions, for: chapterNumber)
        let total = storedValue(in: progress.pageCounts, for: chapterNumber)
        guard let zeroBasedPage, let total, total > 0 else { return nil }
        return (page: min(max(zeroBasedPage + 1, 1), total), total: total)
    }

    func pageProgressLabel(mangaId: Int, chapterNumber: String) -> String? {
        guard let pageProgress = pageProgress(mangaId: mangaId, chapterNumber: chapterNumber) else { return nil }
        return "Page \(pageProgress.page) of \(pageProgress.total)"
    }

    func progress(for mangaId: Int) -> MangaProgress? {
        progressMap[mangaId]
    }

    private func storedProgress(mangaId: Int, forProfile profileID: UUID) -> MangaProgress {
        if profileID == activeProfileID {
            return progressMap[mangaId] ?? MangaProgress()
        }
        return progress(forProfile: profileID)[mangaId] ?? MangaProgress()
    }

    private func commitProgress(_ entry: MangaProgress, mangaId: Int, forProfile profileID: UUID) {
        guard profileID != activeProfileID else {
            progressMap[mangaId] = entry
            save()
            return
        }
        let key = Self.storageKey(for: profileID)
        var map: [Int: MangaProgress] = [:]
        if let data = UserDefaults.standard.data(forKey: key) {

            guard let decoded = try? JSONDecoder().decode([Int: MangaProgress].self, from: data) else {
                ReaderLogger.shared.log(
                    "Dropping late reading progress for profile \(profileID): its store could not be read",
                    type: "Error"
                )
                return
            }
            map = decoded
        }
        map[mangaId] = entry
        guard let encoded = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(encoded, forKey: key)
    }

    private func canSyncTracker(forProfile profileID: UUID) -> Bool {
        guard profileID == activeProfileID else {
            ReaderLogger.shared.log(
                "Skipping tracker sync for profile \(profileID): no longer the active profile",
                type: "Tracker"
            )
            return false
        }
        return true
    }

    func savePagePosition(
        mangaId: Int,
        chapterNumber: String,
        page: Int,
        pageCount: Int? = nil,
        mangaTitle: String? = nil,
        coverURL: String? = nil,
        format: String? = nil,
        totalChapters: Int? = nil,
        latestChapterNumbers: [String]? = nil,
        moduleUUID: String? = nil,
        contentParams: String? = nil,
        isNovel: Bool? = nil,
        route: MangaContentRoute? = nil,
        trackerAniListId: Int? = nil,
        trackerMALId: Int? = nil,
        readThreshold: Double = 0.8,
        forProfile profileID: UUID? = nil
    ) {
        let owner = profileID ?? activeProfileID
        var progress = storedProgress(mangaId: mangaId, forProfile: owner)
        let safePageCount = pageCount.map { max($0, 0) }
        let safePage = max(page, 0)
        let chapterKeys = chapterKeyCandidates(for: chapterNumber)
        for key in chapterKeys {
            progress.pagePositions[key] = safePage
        }
        if let safePageCount, safePageCount > 0 {
            for key in chapterKeys {
                progress.pageCounts[key] = safePageCount
            }
        }
        progress.lastReadChapter = chapterNumber
        progress.lastReadDate = Date()
        if let t = mangaTitle { progress.title = t }
        if let c = coverURL { progress.coverURL = c }
        if let f = format { progress.format = f }
        let uniqueLatestChapterNumbers = latestChapterNumbers.map(ChapterIdentityNormalizer.deduplicatedNumbers)
        if let uniqueLatestChapterNumbers {
            progress.latestChapterNumbers = uniqueLatestChapterNumbers
            progress.totalChapters = uniqueLatestChapterNumbers.count
        } else if let totalChapters {
            progress.totalChapters = totalChapters
        }
        if let moduleUUID { progress.moduleUUID = moduleUUID }
        if let contentParams { progress.contentParams = contentParams }
        if let isNovel { progress.isNovel = isNovel }
        if let trackerAniListId { progress.trackerAniListId = trackerAniListId }
        if let trackerMALId { progress.trackerMALId = trackerMALId }
        applyRoute(route, to: &progress)

        let totalPages = safePageCount ?? storedValue(in: progress.pageCounts, for: chapterNumber) ?? 0
        var didMarkRead = false
        if totalPages > 0 {
            let completion = Double(min(safePage + 1, totalPages)) / Double(totalPages)
            if completion >= readThreshold, !containsChapter(chapterNumber, in: progress.readChapterNumbers) {
                insertChapter(chapterNumber, into: &progress.readChapterNumbers)
                didMarkRead = true
            }
        }

        commitProgress(progress, mangaId: mangaId, forProfile: owner)

        if didMarkRead, canSyncTracker(forProfile: owner), let numericChapter = extractChapterNumber(from: chapterNumber) {
            syncTrackerProgress(
                mangaId: mangaId,
                progress: progress,
                chapterNumber: numericChapter,
                explicitTitle: mangaTitle,
                explicitTotalChapters: totalChapters
            )
        }
    }

    func markChapterRead(mangaId: Int, chapterNumber: String, mangaTitle: String? = nil, coverURL: String? = nil, format: String? = nil, totalChapters: Int? = nil, latestChapterNumbers: [String]? = nil, moduleUUID: String? = nil, contentParams: String? = nil, isNovel: Bool? = nil, route: MangaContentRoute? = nil, trackerAniListId: Int? = nil, trackerMALId: Int? = nil, forProfile profileID: UUID? = nil) {
        let owner = profileID ?? activeProfileID
        var progress = storedProgress(mangaId: mangaId, forProfile: owner)
        let uniqueLatestChapterNumbers = latestChapterNumbers.map(ChapterIdentityNormalizer.deduplicatedNumbers)

        guard !containsChapter(chapterNumber, in: progress.readChapterNumbers) else {

            var changed = false
            if let t = mangaTitle, progress.title != t { progress.title = t; changed = true }
            if let c = coverURL, progress.coverURL != c { progress.coverURL = c; changed = true }
            if let f = format, progress.format != f { progress.format = f; changed = true }
            if let uniqueLatestChapterNumbers {
                if progress.totalChapters != uniqueLatestChapterNumbers.count {
                    progress.totalChapters = uniqueLatestChapterNumbers.count
                    changed = true
                }
                if progress.latestChapterNumbers != uniqueLatestChapterNumbers {
                    progress.latestChapterNumbers = uniqueLatestChapterNumbers
                    changed = true
                }
            } else if let tc = totalChapters, progress.totalChapters != tc {
                progress.totalChapters = tc
                changed = true
            }
            if let m = moduleUUID, progress.moduleUUID != m { progress.moduleUUID = m; changed = true }
            if let cp = contentParams, progress.contentParams != cp { progress.contentParams = cp; changed = true }
            if let n = isNovel, progress.isNovel != n { progress.isNovel = n; changed = true }
            if let trackerAniListId, progress.trackerAniListId != trackerAniListId { progress.trackerAniListId = trackerAniListId; changed = true }
            if let trackerMALId, progress.trackerMALId != trackerMALId { progress.trackerMALId = trackerMALId; changed = true }
            if let route, progress.route != route {
                applyRoute(route, to: &progress)
                changed = true
            }
            if changed { commitProgress(progress, mangaId: mangaId, forProfile: owner) }
            return
        }

        insertChapter(chapterNumber, into: &progress.readChapterNumbers)
        progress.lastReadChapter = chapterNumber
        progress.lastReadDate = Date()
        if let t = mangaTitle { progress.title = t }
        if let c = coverURL { progress.coverURL = c }
        if let f = format { progress.format = f }
        if let uniqueLatestChapterNumbers {
            progress.latestChapterNumbers = uniqueLatestChapterNumbers
            progress.totalChapters = uniqueLatestChapterNumbers.count
        } else if let tc = totalChapters {
            progress.totalChapters = tc
        }
        if let m = moduleUUID { progress.moduleUUID = m }
        if let cp = contentParams { progress.contentParams = cp }
        if let n = isNovel { progress.isNovel = n }
        if let trackerAniListId { progress.trackerAniListId = trackerAniListId }
        if let trackerMALId { progress.trackerMALId = trackerMALId }
        applyRoute(route, to: &progress)
        commitProgress(progress, mangaId: mangaId, forProfile: owner)

        if canSyncTracker(forProfile: owner), let numericChapter = extractChapterNumber(from: chapterNumber) {
            syncTrackerProgress(
                mangaId: mangaId,
                progress: progress,
                chapterNumber: numericChapter,
                explicitTitle: mangaTitle,
                explicitTotalChapters: totalChapters
            )
        }
    }

    func markChapterUnread(mangaId: Int, chapterNumber: String) {
        guard var progress = progressMap[mangaId] else { return }
        removeChapter(chapterNumber, from: &progress.readChapterNumbers)
        progressMap[mangaId] = progress
        save()
    }

    func markAllRead(mangaId: Int, chapterNumbers: [String], mangaTitle: String? = nil, coverURL: String? = nil, format: String? = nil, totalChapters: Int? = nil, latestChapterNumbers: [String]? = nil, moduleUUID: String? = nil, contentParams: String? = nil, isNovel: Bool? = nil, route: MangaContentRoute? = nil, trackerAniListId: Int? = nil, trackerMALId: Int? = nil) {
        guard !activeStoreLoadFailed else {
            ReaderLogger.shared.log(
                "MangaReadingProgressManager: refusing to mark all chapters read for profile \(activeProfileID): its progress store is unreadable; preserving its bytes",
                type: "Error"
            )
            return
        }
        var progress = progressMap[mangaId] ?? MangaProgress()
        let uniqueChapterNumbers = ChapterIdentityNormalizer.deduplicatedNumbers(chapterNumbers)
        let uniqueLatestChapterNumbers = latestChapterNumbers.map(ChapterIdentityNormalizer.deduplicatedNumbers)
        for ch in uniqueChapterNumbers {
            insertChapter(ch, into: &progress.readChapterNumbers)
        }
        if let last = uniqueChapterNumbers.last {
            progress.lastReadChapter = last
            progress.lastReadDate = Date()
        }
        if let mangaTitle { progress.title = mangaTitle }
        if let coverURL { progress.coverURL = coverURL }
        if let format { progress.format = format }
        if let uniqueLatestChapterNumbers {
            progress.latestChapterNumbers = uniqueLatestChapterNumbers
            progress.totalChapters = uniqueLatestChapterNumbers.count
        } else if let totalChapters {
            progress.totalChapters = totalChapters
        }
        if let moduleUUID { progress.moduleUUID = moduleUUID }
        if let contentParams { progress.contentParams = contentParams }
        if let isNovel { progress.isNovel = isNovel }
        if let trackerAniListId { progress.trackerAniListId = trackerAniListId }
        if let trackerMALId { progress.trackerMALId = trackerMALId }
        applyRoute(route, to: &progress)
        progressMap[mangaId] = progress
        save()

        let highest = uniqueChapterNumbers.compactMap { extractChapterNumber(from: $0) }.max()
        if let highest = highest {
            syncTrackerProgress(
                mangaId: mangaId,
                progress: progress,
                chapterNumber: highest,
                explicitTitle: mangaTitle,
                explicitTotalChapters: totalChapters
            )
        }
    }

    func updateSourceMetadata(mangaId: Int, title: String? = nil, coverURL: String? = nil, format: String? = nil, latestChapterNumbers: [String], route: MangaContentRoute? = nil, sourceRefreshError: String? = nil, forProfile profileID: UUID? = nil) {
        let owner = profileID ?? activeProfileID
        var progress = storedProgress(mangaId: mangaId, forProfile: owner)
        let uniqueLatestChapterNumbers = ChapterIdentityNormalizer.deduplicatedNumbers(latestChapterNumbers)
        if let title { progress.title = title }
        if let coverURL { progress.coverURL = coverURL }
        if let format { progress.format = format }
        progress.latestChapterNumbers = uniqueLatestChapterNumbers
        progress.totalChapters = uniqueLatestChapterNumbers.count
        progress.lastSourceRefresh = Date()
        progress.sourceRefreshError = sourceRefreshError
        applyRoute(route, to: &progress)
        commitProgress(progress, mangaId: mangaId, forProfile: owner)
    }

    func updateTrackerMatch(mangaId: Int, aniListId: Int?, malId: Int?, confidence: Double?) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.updateTrackerMatch(mangaId: mangaId, aniListId: aniListId, malId: malId, confidence: confidence)
            }
            return
        }

        var progress = progressMap[mangaId] ?? MangaProgress()
        var changed = false

        if let aniListId, aniListId > 0, progress.trackerAniListId != aniListId {
            progress.trackerAniListId = aniListId
            changed = true
        }
        if let malId, malId > 0, progress.trackerMALId != malId {
            progress.trackerMALId = malId
            changed = true
        }
        if let confidence, progress.trackerMatchConfidence != confidence {
            progress.trackerMatchConfidence = confidence
            changed = true
        }
        if changed {
            progress.trackerResolvedAt = Date()
            progressMap[mangaId] = progress
            save()
        }
    }

    func bulkMarkChaptersReadForImport(mangaId: Int, throughChapter: Int, mangaTitle: String? = nil, coverURL: String? = nil, totalChapters: Int? = nil) {
        guard throughChapter >= 1 else { return }

        guard !activeStoreLoadFailed else {
            ReaderLogger.shared.log(
                "MangaReadingProgressManager: refusing a bulk import mark-read for profile \(activeProfileID): its progress store is unreadable; preserving its bytes",
                type: "Error"
            )
            return
        }
        var progress = progressMap[mangaId] ?? MangaProgress()
        for chapter in 1...throughChapter {
            progress.readChapterNumbers.insert(String(chapter))
        }

        let highest = progress.readChapterNumbers.compactMap { extractChapterNumber(from: $0) }.max() ?? throughChapter
        progress.lastReadChapter = String(highest)
        progress.lastReadDate = Date()
        if let mangaTitle { progress.title = mangaTitle }
        if let coverURL { progress.coverURL = coverURL }
        if let totalChapters { progress.totalChapters = totalChapters }

        progressMap[mangaId] = progress
        save()
    }

    func markAllUnread(mangaId: Int) {
        guard var progress = progressMap[mangaId] else { return }
        progress.readChapterNumbers.removeAll()
        progress.lastReadChapter = nil
        progressMap[mangaId] = progress
        save()
    }

    func removeFromHistory(mangaId: Int) {
        guard var progress = progressMap[mangaId] else { return }
        progress.lastReadChapter = nil
        progress.lastReadDate = nil
        progress.pagePositions.removeAll()
        progress.pageCounts.removeAll()
        progressMap[mangaId] = progress
        save()
    }

    func clearHistory() {
        guard progressMap.values.contains(where: { $0.lastReadDate != nil }) else { return }
        for mangaId in progressMap.keys {
            progressMap[mangaId]?.lastReadChapter = nil
            progressMap[mangaId]?.lastReadDate = nil
            progressMap[mangaId]?.pagePositions.removeAll()
            progressMap[mangaId]?.pageCounts.removeAll()
        }
        save()
    }

    private static func loadProgress(
        forKey key: String
    ) -> (progress: [Int: MangaProgress], unreadable: Bool) {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return ([:], false)
        }
        guard let decoded = try? JSONDecoder().decode([Int: MangaProgress].self, from: data) else {
            return ([:], true)
        }
        return (decoded, false)
    }

    static func persistedProgressSchemaIsValid(_ data: Data) -> Bool {
        (try? JSONDecoder().decode([Int: MangaProgress].self, from: data)) != nil
    }

    private func load() {
        let loaded = Self.loadProgress(forKey: storageKey)
        activeStoreLoadFailed = loaded.unreadable
        progressMap = loaded.progress
        if loaded.unreadable {
            ReaderLogger.shared.log(
                "MangaReadingProgressManager: profile \(activeProfileID) has an unreadable progress store; preserving its bytes",
                type: "Error"
            )
        }
    }

    private func save() {
        guard !activeStoreLoadFailed else { return }
        if let data = try? JSONEncoder().encode(progressMap) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func allowOverwritingUnreadableStore() {
        activeStoreLoadFailed = false
    }

    func progress(forProfile profileID: UUID) -> [Int: MangaProgress] {
        progressSnapshot(forProfile: profileID) ?? [:]
    }

    func progressSnapshot(forProfile profileID: UUID) -> [Int: MangaProgress]? {
        let key = profileID == activeProfileID ? storageKey : Self.storageKey(for: profileID)
        let loaded = Self.loadProgress(forKey: key)
        guard !loaded.unreadable else {
            ReaderLogger.shared.log(
                "MangaReadingProgressManager: profile \(profileID) has an unreadable progress store; preserving its bytes",
                type: "Error"
            )
            return nil
        }
        return loaded.progress
    }

    func applyRestoredProgress(_ progress: [Int: MangaProgress], forProfile profileID: UUID) {
        guard profileID != activeProfileID else {
            allowOverwritingUnreadableStore()
            progressMap = progress
            save()
            objectWillChange.send()
            return
        }
        guard let data = try? JSONEncoder().encode(progress) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey(for: profileID))
    }

    func recentlyReadMangaIds() -> [(id: Int, progress: MangaProgress)] {
        progressMap
            .filter { $0.value.lastReadDate != nil }
            .sorted { ($0.value.lastReadDate ?? .distantPast) > ($1.value.lastReadDate ?? .distantPast) }
            .map { (id: $0.key, progress: $0.value) }
    }

    func replaceProgressMapForRestore(_ newMap: [Int: MangaProgress]) {
        allowOverwritingUnreadableStore()
        progressMap = newMap
        save()
    }

    private func extractChapterNumber(from string: String) -> Int? {

        let pattern = #"(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let range = Range(match.range(at: 1), in: string) else { return nil }
        return Int(string[range])
    }

    private func applyRoute(_ route: MangaContentRoute?, to progress: inout MangaProgress) {
        guard let route else { return }
        progress.route = route

        if case .legacyModule(let moduleUUID, let contentParams, let isNovel) = route {
            progress.moduleUUID = moduleUUID
            progress.contentParams = contentParams
            progress.isNovel = isNovel
        }
    }

    private func chapterKeyCandidates(for chapterNumber: String) -> [String] {
        let trimmed = chapterNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = ChapterIdentityNormalizer.key(for: chapterNumber)
        var keys: [String] = []
        for key in [chapterNumber, trimmed, normalized] where !key.isEmpty && !keys.contains(key) {
            keys.append(key)
        }
        return keys
    }

    private func containsChapter(_ chapterNumber: String, in chapters: Set<String>) -> Bool {
        let candidates = Set(chapterKeyCandidates(for: chapterNumber))
        if !chapters.isDisjoint(with: candidates) {
            return true
        }

        let normalized = ChapterIdentityNormalizer.key(for: chapterNumber)
        return chapters.contains { ChapterIdentityNormalizer.key(for: $0) == normalized }
    }

    private func insertChapter(_ chapterNumber: String, into chapters: inout Set<String>) {
        for key in chapterKeyCandidates(for: chapterNumber) {
            chapters.insert(key)
        }
    }

    private func removeChapter(_ chapterNumber: String, from chapters: inout Set<String>) {
        let candidates = Set(chapterKeyCandidates(for: chapterNumber))
        let normalized = ChapterIdentityNormalizer.key(for: chapterNumber)
        chapters = chapters.filter { saved in
            !candidates.contains(saved) && ChapterIdentityNormalizer.key(for: saved) != normalized
        }
    }

    private func storedValue<Value>(in dictionary: [String: Value], for chapterNumber: String) -> Value? {
        for key in chapterKeyCandidates(for: chapterNumber) {
            if let value = dictionary[key] {
                return value
            }
        }

        let normalized = ChapterIdentityNormalizer.key(for: chapterNumber)
        return dictionary.first { ChapterIdentityNormalizer.key(for: $0.key) == normalized }?.value
    }

    private func syncTrackerProgress(mangaId: Int, progress: MangaProgress, chapterNumber: Int, explicitTitle: String?, explicitTotalChapters: Int?) {
        if mangaId > 0 {
            TrackerManager.shared.syncMangaProgress(
                aniListId: mangaId,
                malId: progress.trackerMALId,
                title: explicitTitle ?? progress.title,
                chapterNumber: chapterNumber,
                totalChapters: explicitTotalChapters ?? progress.totalChapters ?? progress.latestChapterNumbers?.count,
                format: progress.format,
                routeKey: progress.route?.stableKey
            )
            return
        }

        guard let title = explicitTitle ?? progress.title else {
            ReaderLogger.shared.log("Skipping tracker sync for generated manga id \(mangaId): missing title", type: "Tracker")
            return
        }

        TrackerManager.shared.syncMangaProgress(
            title: title,
            chapterNumber: chapterNumber,
            totalChapters: explicitTotalChapters ?? progress.totalChapters ?? progress.latestChapterNumbers?.count,
            format: progress.format,
            routeKey: progress.route?.stableKey,
            knownAniListId: progress.trackerAniListId,
            knownMALId: progress.trackerMALId
        )
    }
}
