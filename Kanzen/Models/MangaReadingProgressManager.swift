//
//  MangaReadingProgressManager.swift
//  Kanzen
//
//  Created by Luna on 2026.
//

import Foundation

// MARK: - Progress Model

struct MangaProgress: Codable {
    var readChapterNumbers: Set<String> = []
    var lastReadChapter: String?
    var lastReadDate: Date?
    /// Page index keyed by chapter number, so reader can resume mid-chapter.
    var pagePositions: [String: Int] = [:]
    // Display metadata for history
    var title: String?
    var coverURL: String?
    var format: String?
    var totalChapters: Int?
    // Module routing (for module-search sourced content)
    var moduleUUID: String?
    var contentParams: String?
    var isNovel: Bool?
}

// MARK: - Progress Manager

final class MangaReadingProgressManager: ObservableObject {
    static let shared = MangaReadingProgressManager()

    /// Key = AniList manga ID, Value = progress data
    @Published private(set) var progressMap: [Int: MangaProgress] = [:]

    private let storageKey = "mangaReadingProgress"

    private init() {
        load()
    }

    // MARK: - Queries

    func isChapterRead(mangaId: Int, chapterNumber: String) -> Bool {
        progressMap[mangaId]?.readChapterNumbers.contains(chapterNumber) == true
    }

    func readChapters(for mangaId: Int) -> Set<String> {
        progressMap[mangaId]?.readChapterNumbers ?? []
    }

    func lastReadChapter(for mangaId: Int) -> String? {
        progressMap[mangaId]?.lastReadChapter
    }

    func pagePosition(mangaId: Int, chapterNumber: String) -> Int {
        progressMap[mangaId]?.pagePositions[chapterNumber] ?? 0
    }

    func savePagePosition(mangaId: Int, chapterNumber: String, page: Int, mangaTitle: String? = nil, coverURL: String? = nil) {
        var progress = progressMap[mangaId] ?? MangaProgress()
        progress.pagePositions[chapterNumber] = page
        progress.lastReadChapter = chapterNumber
        progress.lastReadDate = Date()
        if let t = mangaTitle { progress.title = t }
        if let c = coverURL { progress.coverURL = c }
        progressMap[mangaId] = progress
        save()
    }

    // MARK: - Mutations

    /// Mark a chapter as read and optionally sync to AniList.
    func markChapterRead(mangaId: Int, chapterNumber: String, mangaTitle: String? = nil, coverURL: String? = nil, format: String? = nil, totalChapters: Int? = nil, moduleUUID: String? = nil, contentParams: String? = nil, isNovel: Bool? = nil) {
        var progress = progressMap[mangaId] ?? MangaProgress()

        guard !progress.readChapterNumbers.contains(chapterNumber) else {
            // Still update metadata if provided even for already-read chapters
            var changed = false
            if let t = mangaTitle, progress.title != t { progress.title = t; changed = true }
            if let c = coverURL, progress.coverURL != c { progress.coverURL = c; changed = true }
            if let f = format, progress.format != f { progress.format = f; changed = true }
            if let tc = totalChapters, progress.totalChapters != tc { progress.totalChapters = tc; changed = true }
            if let m = moduleUUID, progress.moduleUUID != m { progress.moduleUUID = m; changed = true }
            if let cp = contentParams, progress.contentParams != cp { progress.contentParams = cp; changed = true }
            if let n = isNovel, progress.isNovel != n { progress.isNovel = n; changed = true }
            if changed { progressMap[mangaId] = progress; save() }
            return
        }

        progress.readChapterNumbers.insert(chapterNumber)
        progress.lastReadChapter = chapterNumber
        progress.lastReadDate = Date()
        if let t = mangaTitle { progress.title = t }
        if let c = coverURL { progress.coverURL = c }
        if let f = format { progress.format = f }
        if let tc = totalChapters { progress.totalChapters = tc }
        if let m = moduleUUID { progress.moduleUUID = m }
        if let cp = contentParams { progress.contentParams = cp }
        if let n = isNovel { progress.isNovel = n }
        progressMap[mangaId] = progress
        save()

        // Sync to AniList if connected — extract numeric chapter for the API
        if let numericChapter = extractChapterNumber(from: chapterNumber) {
            TrackerManager.shared.syncMangaProgress(aniListId: mangaId, chapterNumber: numericChapter)
        }
    }

    /// Mark a chapter as unread.
    func markChapterUnread(mangaId: Int, chapterNumber: String) {
        guard var progress = progressMap[mangaId] else { return }
        progress.readChapterNumbers.remove(chapterNumber)
        progressMap[mangaId] = progress
        save()
    }

    /// Mark multiple chapters as read and sync the highest chapter to AniList.
    func markAllRead(mangaId: Int, chapterNumbers: [String]) {
        var progress = progressMap[mangaId] ?? MangaProgress()
        for ch in chapterNumbers {
            progress.readChapterNumbers.insert(ch)
        }
        if let last = chapterNumbers.last {
            progress.lastReadChapter = last
            progress.lastReadDate = Date()
        }
        progressMap[mangaId] = progress
        save()

        // Sync highest chapter number to AniList
        let highest = chapterNumbers.compactMap { extractChapterNumber(from: $0) }.max()
        if let highest = highest {
            TrackerManager.shared.syncMangaProgress(aniListId: mangaId, chapterNumber: highest)
        }
    }

    /// Import chapters without syncing back to trackers. Existing local reads are only advanced.
    func bulkMarkChaptersReadForImport(mangaId: Int, throughChapter: Int, mangaTitle: String? = nil, coverURL: String? = nil, totalChapters: Int? = nil) {
        guard throughChapter >= 1 else { return }

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

    /// Mark all chapters as unread.
    func markAllUnread(mangaId: Int) {
        guard var progress = progressMap[mangaId] else { return }
        progress.readChapterNumbers.removeAll()
        progress.lastReadChapter = nil
        progressMap[mangaId] = progress
        save()
    }

    // MARK: - Persistence

    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([Int: MangaProgress].self, from: data) {
            progressMap = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(progressMap) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    // MARK: - History

    /// Returns all manga IDs that have reading progress, sorted by most recently read.
    func recentlyReadMangaIds() -> [(id: Int, progress: MangaProgress)] {
        progressMap
            .filter { $0.value.lastReadDate != nil }
            .sorted { ($0.value.lastReadDate ?? .distantPast) > ($1.value.lastReadDate ?? .distantPast) }
            .map { (id: $0.key, progress: $0.value) }
    }

    /// Bulk-replace progress map (used during backup restore).
    func replaceProgressMapForRestore(_ newMap: [Int: MangaProgress]) {
        progressMap = newMap
        save()
    }

    // MARK: - Helpers

    /// Extracts the leading integer from a chapter string like "Ch. 129" → 129, or "127.2" → 127.
    private func extractChapterNumber(from string: String) -> Int? {
        // Look for patterns like "Ch. 129", "Chapter 5", or just "129.2"
        let pattern = #"(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let range = Range(match.range(at: 1), in: string) else { return nil }
        return Int(string[range])
    }
}
