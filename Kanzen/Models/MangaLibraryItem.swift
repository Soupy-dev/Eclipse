//
//  MangaLibraryItem.swift
//  Kanzen
//
//  Created by Eclipse on 2026.
//

import Foundation

struct MangaLibraryItem: Codable, Identifiable, Equatable {
    var id: Int { aniListId }

    let aniListId: Int
    var title: String
    var coverURL: String?
    var format: String?
    var totalChapters: Int?
    var moduleUUID: String? = nil
    var contentParams: String? = nil
    var isNovel: Bool? = nil
    var route: MangaContentRoute? = nil
    var dateAdded: Date = Date()
    var sourceName: String? = nil
    var latestChapterNumbers: [String]? = nil
    var lastSourceRefresh: Date? = nil
    var sourceRefreshError: String? = nil
    var trackerAniListId: Int? = nil
    var trackerMALId: Int? = nil
    var trackerMatchConfidence: Double? = nil
    var trackerResolvedAt: Date? = nil

    var contentRating: Int? = nil

    var knownChapterNumbers: [String] {
        if let latestChapterNumbers, !latestChapterNumbers.isEmpty {
            return ChapterIdentityNormalizer.deduplicatedNumbers(latestChapterNumbers)
        }
        if let totalChapters, totalChapters > 0 {
            return (1...totalChapters).map(String.init)
        }
        return []
    }

    func unreadCount(readChapters: Set<String>) -> Int {
        let known = knownChapterNumbers
        guard !known.isEmpty else { return 0 }
        let readKeys = Set(readChapters.map { ChapterIdentityNormalizer.key(for: $0) })
        return known.reduce(into: 0) { count, chapter in
            if !readKeys.contains(ChapterIdentityNormalizer.key(for: chapter)) {
                count += 1
            }
        }
    }

    static func fromModule(
        moduleId: UUID,
        contentId: String,
        title: String,
        coverURL: String?,
        isNovel: Bool,
        sourceName: String? = nil,
        latestChapterNumbers: [String]? = nil,
        contentRating: Int? = nil
    ) -> MangaLibraryItem {
        let uniqueChapterNumbers = latestChapterNumbers.map(ChapterIdentityNormalizer.deduplicatedNumbers)
        let combined = "\(moduleId.uuidString):\(contentId)"

        let hash = combined.utf8.reduce(into: 5381) { h, c in h = ((h &<< 5) &+ h) &+ Int(c) }
        let stableId = hash < 0 ? hash : -hash - 1
        return MangaLibraryItem(
            aniListId: stableId,
            title: title,
            coverURL: coverURL,
            format: isNovel ? "NOVEL" : "MANGA",
            totalChapters: uniqueChapterNumbers?.count,
            moduleUUID: moduleId.uuidString,
            contentParams: contentId,
            isNovel: isNovel,
            route: .legacyModule(moduleUUID: moduleId.uuidString, contentParams: contentId, isNovel: isNovel),
            sourceName: sourceName,
            latestChapterNumbers: uniqueChapterNumbers,
            contentRating: contentRating
        )
    }

    static func fromReaderExtension(
        sourceID: ReaderExtensionSourceID,
        itemKey: String,
        legacyStableKey: String? = nil,
        title: String,
        coverURL: String?,
        sourceName: String? = nil,
        latestChapterNumbers: [String]? = nil,
        format: String? = "MANGA",
        contentRating: Int? = nil
    ) -> MangaLibraryItem {
        let uniqueChapterNumbers = latestChapterNumbers.map(ChapterIdentityNormalizer.deduplicatedNumbers)
        let route = MangaContentRoute.readerExtension(
            source: sourceID,
            itemKey: itemKey,
            legacyStableKey: legacyStableKey
        )
        return MangaLibraryItem(
            aniListId: route.stableNegativeId,
            title: title,
            coverURL: coverURL,
            format: format,
            totalChapters: uniqueChapterNumbers?.count,
            route: route,
            sourceName: sourceName,
            latestChapterNumbers: uniqueChapterNumbers,
            contentRating: contentRating
        )
    }

    static func == (lhs: MangaLibraryItem, rhs: MangaLibraryItem) -> Bool {
        lhs.aniListId == rhs.aniListId
    }
}
