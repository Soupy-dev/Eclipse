//
//  MangaLibraryItem.swift
//  Kanzen
//
//  Created by Eclipse on 2026.
//

import Foundation

struct MangaLibraryItem: Codable, Identifiable, Equatable, Sendable {
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

    func unreadCount(readChapters: Set<String>) -> Int {
        let readKeys = Set(readChapters.map { ChapterIdentityNormalizer.key(for: $0) })
        if let latestChapterNumbers, !latestChapterNumbers.isEmpty {
            return ChapterIdentityNormalizer.deduplicatedNumbers(latestChapterNumbers).reduce(into: 0) { count, chapter in
                if !readKeys.contains(ChapterIdentityNormalizer.key(for: chapter)) {
                    count += 1
                }
            }
        }
        guard let totalChapters, totalChapters > 0 else { return 0 }
        let readCount = readKeys.reduce(into: 0) { count, key in
            guard let number = ChapterIdentityNormalizer.numericValue(in: key),
                  let chapter = Int(exactly: number),
                  chapter > 0, chapter <= totalChapters,
                  ChapterIdentityNormalizer.key(for: String(chapter)) == key else { return }
            count += 1
        }
        return totalChapters - readCount
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
        contentRating: Int? = nil,
        mangaID: Int? = nil
    ) -> MangaLibraryItem {
        let uniqueChapterNumbers = latestChapterNumbers.map(ChapterIdentityNormalizer.deduplicatedNumbers)
        let route = MangaContentRoute.readerExtension(
            source: sourceID,
            itemKey: itemKey,
            legacyStableKey: legacyStableKey
        )
        return MangaLibraryItem(
            aniListId: mangaID ?? route.stableNegativeId,
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

    func attachingReaderSource(_ source: MangaLibraryItem) -> MangaLibraryItem {
        var linked = self
        linked.route = source.route
        linked.sourceName = source.sourceName
        linked.moduleUUID = nil
        linked.contentParams = nil
        linked.isNovel = source.format == "NOVEL"
        linked.format = source.format ?? format
        linked.coverURL = source.coverURL ?? coverURL
        linked.latestChapterNumbers = source.latestChapterNumbers
        linked.totalChapters = source.totalChapters ?? totalChapters
        linked.sourceRefreshError = nil
        linked.trackerAniListId = trackerAniListId ?? (aniListId > 0 ? aniListId : nil)
        if let rating = source.contentRating {
            linked.contentRating = max(contentRating ?? rating, rating)
        }
        return linked
    }

    func applyingTrackerSelection(aniListID: Int?, malID: Int?) -> MangaLibraryItem {
        if id > 0 {
            if let aniListID, aniListID != id { return self }
            if aniListID == nil, let malID, malID != trackerMALId { return self }
        }
        var linked = self
        let knownAniListID = trackerAniListId ?? (id > 0 ? id : nil)
        if let aniListID {
            linked.trackerAniListId = aniListID
            linked.trackerMALId = malID ?? (aniListID == knownAniListID ? trackerMALId : nil)
        } else if let malID {
            linked.trackerMALId = malID
            linked.trackerAniListId = id > 0 || malID == trackerMALId ? knownAniListID : nil
        }
        linked.trackerMatchConfidence = 1
        linked.trackerResolvedAt = Date()
        return linked
    }

    static func == (lhs: MangaLibraryItem, rhs: MangaLibraryItem) -> Bool {
        lhs.aniListId == rhs.aniListId
    }
}
