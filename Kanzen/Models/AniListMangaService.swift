//
//  AniListMangaService.swift
//  Kanzen
//
//  Created by Eclipse on 2025.
//

import Foundation

private actor MangaRateLimiter {
    static let shared = MangaRateLimiter()

    private let minInterval: TimeInterval = 0.5
    private var nextAvailableTime: Date = .distantPast

    func waitForSlot() async {
        let now = Date()
        let slotTime = max(now, nextAvailableTime)
        nextAvailableTime = slotTime.addingTimeInterval(minInterval)

        let delay = slotTime.timeIntervalSince(now)
        if delay > 0.001 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}

struct AniListManga: Identifiable, Codable, Hashable {
    let id: Int
    let title: AniListMangaTitle
    let chapters: Int?
    let volumes: Int?
    let status: String?
    let coverImage: AniListMangaCover?
    let format: String?
    let description: String?
    let genres: [String]?
    let averageScore: Int?
    let countryOfOrigin: String?
    let startDate: AniListMangaStartDate?

    private enum CodingKeys: String, CodingKey {
        case id, title, chapters, volumes, status, coverImage, format
        case description, genres, averageScore, countryOfOrigin, startDate
    }

    struct AniListMangaTitle: Codable, Hashable {
        let romaji: String?
        let english: String?
        let native: String?
    }

    struct AniListMangaStartDate: Codable, Hashable {
        let year: Int?

        private enum CodingKeys: String, CodingKey {
            case year
        }
    }

    struct AniListMangaCover: Codable, Hashable {
        let large: String?
        let medium: String?
    }

    var displayTitle: String {
        AniListMangaTitlePicker.title(from: title)
    }

    var coverURL: String? {
        coverImage?.large ?? coverImage?.medium
    }

    var startYear: Int? {
        startDate?.year
    }

    var allTitleCandidates: [String] {
        var seen = Set<String>()
        return [title.english, title.romaji, title.native].compactMap { $0 }.filter { value in
            let cleaned = value.trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty, !seen.contains(cleaned.lowercased()) else { return false }
            seen.insert(cleaned.lowercased())
            return true
        }
    }
}

extension AniListManga.AniListMangaStartDate {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawYear = try container.decodeIfPresent(Int.self, forKey: .year)
        if let rawYear, rawYear != 0 {
            guard let year = RemoteMediaNumericBoundary.year(rawYear) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .year,
                    in: container,
                    debugDescription: "AniList manga year is outside the supported range."
                )
            }
            self.year = year
        } else {
            year = nil
        }
    }
}

extension AniListManga {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let rawID = try container.decode(Int.self, forKey: .id)
        guard let id = RemoteMediaNumericBoundary.positiveIdentifier(rawID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "AniList manga identifier is outside the supported range."
            )
        }
        self.id = id
        title = try container.decode(AniListMangaTitle.self, forKey: .title)

        let rawChapters = try container.decodeIfPresent(Int.self, forKey: .chapters)
        if let rawChapters, rawChapters != 0 {
            guard let chapters = RemoteMediaNumericBoundary.episodeCount(rawChapters) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .chapters,
                    in: container,
                    debugDescription: "AniList manga chapter count is outside the supported range."
                )
            }
            self.chapters = chapters
        } else {
            chapters = nil
        }

        let rawVolumes = try container.decodeIfPresent(Int.self, forKey: .volumes)
        if let rawVolumes, rawVolumes != 0 {
            guard let volumes = RemoteMediaNumericBoundary.episodeCount(rawVolumes) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .volumes,
                    in: container,
                    debugDescription: "AniList manga volume count is outside the supported range."
                )
            }
            self.volumes = volumes
        } else {
            volumes = nil
        }

        if let rawScore = try container.decodeIfPresent(Int.self, forKey: .averageScore) {
            guard (0...100).contains(rawScore) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .averageScore,
                    in: container,
                    debugDescription: "AniList manga score is outside the supported range."
                )
            }
            averageScore = rawScore
        } else {
            averageScore = nil
        }

        status = try container.decodeIfPresent(String.self, forKey: .status)
        coverImage = try container.decodeIfPresent(AniListMangaCover.self, forKey: .coverImage)
        format = try container.decodeIfPresent(String.self, forKey: .format)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        let decodedGenres = try container.decodeIfPresent([String].self, forKey: .genres)
        guard (decodedGenres?.count ?? 0) <= 64 else {
            throw DecodingError.dataCorruptedError(
                forKey: .genres,
                in: container,
                debugDescription: "AniList manga genre collection exceeds the supported limit."
            )
        }
        genres = decodedGenres
        countryOfOrigin = try container.decodeIfPresent(String.self, forKey: .countryOfOrigin)
        startDate = try container.decodeIfPresent(AniListMangaStartDate.self, forKey: .startDate)
    }
}

enum AniListMangaTitlePicker {
    private static func cleanTitle(_ title: String) -> String {
        let cleaned = title
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? title : cleaned
    }

    static func title(from title: AniListManga.AniListMangaTitle) -> String {
        let lang = (ProfileSettingsStore.active.string(forKey: "tmdbLanguage") ?? "en-US")
            .split(separator: "-").first.map(String.init) ?? "en"

        if lang.hasPrefix("en"), let english = title.english, !english.isEmpty {
            return cleanTitle(english)
        }
        if lang.hasPrefix("ja"), let native = title.native, !native.isEmpty {
            return cleanTitle(native)
        }
        if let english = title.english, !english.isEmpty {
            return cleanTitle(english)
        }
        if let romaji = title.romaji, !romaji.isEmpty {
            return cleanTitle(romaji)
        }
        if let native = title.native, !native.isEmpty {
            return cleanTitle(native)
        }
        return "Unknown"
    }
}

final class AniListMangaService {
    static let shared = AniListMangaService()

    static func boundedRetryDelay(_ rawValue: String?, fallback: TimeInterval) -> TimeInterval {
        let boundedFallback = fallback.isFinite ? min(max(fallback, 0.1), 10) : 2
        guard let rawValue,
              let value = TimeInterval(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite,
              value > 0 else {
            return boundedFallback
        }
        return min(value, 10)
    }

    private let graphQLEndpoint = URL(string: "https://graphql.anilist.co")!

    private let mediaFragment = """
        id
        title { romaji english native }
        chapters
        volumes
        status
        coverImage { large medium }
        format
        description(asHtml: false)
        genres
        averageScore
        countryOfOrigin
        startDate { year }
    """

    func fetchAllMangaCatalogs(limit: Int = 20) async throws -> [String: [AniListManga]] {
        let query = """
        query {
            trendingManga: Page(perPage: \(limit)) {
                media(type: MANGA, format_not: NOVEL, sort: [TRENDING_DESC]) { \(mediaFragment) }
            }
            popularManga: Page(perPage: \(limit)) {
                media(type: MANGA, format_not: NOVEL, sort: [POPULARITY_DESC]) { \(mediaFragment) }
            }
            topRatedManga: Page(perPage: \(limit)) {
                media(type: MANGA, format_not: NOVEL, sort: [SCORE_DESC]) { \(mediaFragment) }
            }
            publishingManga: Page(perPage: \(limit)) {
                media(type: MANGA, format_not: NOVEL, sort: [POPULARITY_DESC], status: RELEASING) { \(mediaFragment) }
            }
            popularManhwa: Page(perPage: \(limit)) {
                media(type: MANGA, format_not: NOVEL, sort: [POPULARITY_DESC], countryOfOrigin: "KR") { \(mediaFragment) }
            }
            trendingManhwa: Page(perPage: \(limit)) {
                media(type: MANGA, format_not: NOVEL, sort: [TRENDING_DESC], countryOfOrigin: "KR") { \(mediaFragment) }
            }
            topRatedManhwa: Page(perPage: \(limit)) {
                media(type: MANGA, format_not: NOVEL, sort: [SCORE_DESC], countryOfOrigin: "KR") { \(mediaFragment) }
            }
            recentlyUpdated: Page(perPage: \(limit)) {
                media(type: MANGA, format_not: NOVEL, sort: [UPDATED_AT_DESC], status: RELEASING) { \(mediaFragment) }
            }
        }
        """

        struct PageData: Codable { let media: [AniListManga] }
        struct AllCatalogsResponse: Codable {
            let data: DataWrapper
            struct DataWrapper: Codable {
                let trendingManga: PageData
                let popularManga: PageData
                let topRatedManga: PageData
                let publishingManga: PageData
                let popularManhwa: PageData
                let trendingManhwa: PageData
                let topRatedManhwa: PageData
                let recentlyUpdated: PageData
            }
        }

        let data = try await executeGraphQLQuery(query)
        let decoded = try JSONDecoder().decode(AllCatalogsResponse.self, from: data)

        let result: [String: [AniListManga]] = [
            "trendingManga": decoded.data.trendingManga.media,
            "popularManga": decoded.data.popularManga.media,
            "topRatedManga": decoded.data.topRatedManga.media,
            "publishingManga": decoded.data.publishingManga.media,
            "popularManhwa": decoded.data.popularManhwa.media,
            "trendingManhwa": decoded.data.trendingManhwa.media,
            "topRatedManhwa": decoded.data.topRatedManhwa.media,
            "recentlyUpdated": decoded.data.recentlyUpdated.media,
        ]

        ReaderLogger.shared.log("AniListMangaService: Fetched all manga catalogs in 1 query", type: "AniList")
        return result
    }

    func fetchAllLightNovelCatalogs(limit: Int = 20) async throws -> [String: [AniListManga]] {
        let query = """
        query {
            trendingNovels: Page(perPage: \(limit)) {
                media(type: MANGA, format: NOVEL, sort: [TRENDING_DESC]) { \(mediaFragment) }
            }
            popularNovels: Page(perPage: \(limit)) {
                media(type: MANGA, format: NOVEL, sort: [POPULARITY_DESC]) { \(mediaFragment) }
            }
            topRatedNovels: Page(perPage: \(limit)) {
                media(type: MANGA, format: NOVEL, sort: [SCORE_DESC]) { \(mediaFragment) }
            }
            publishingNovels: Page(perPage: \(limit)) {
                media(type: MANGA, format: NOVEL, sort: [POPULARITY_DESC], status: RELEASING) { \(mediaFragment) }
            }
        }
        """

        struct PageData: Codable { let media: [AniListManga] }
        struct LNResponse: Codable {
            let data: DataWrapper
            struct DataWrapper: Codable {
                let trendingNovels: PageData
                let popularNovels: PageData
                let topRatedNovels: PageData
                let publishingNovels: PageData
            }
        }

        let data = try await executeGraphQLQuery(query)
        let decoded = try JSONDecoder().decode(LNResponse.self, from: data)

        let result: [String: [AniListManga]] = [
            "trendingNovels": decoded.data.trendingNovels.media,
            "popularNovels": decoded.data.popularNovels.media,
            "topRatedNovels": decoded.data.topRatedNovels.media,
            "publishingNovels": decoded.data.publishingNovels.media,
        ]

        ReaderLogger.shared.log("AniListMangaService: Fetched all light novel catalogs in 1 query", type: "AniList")
        return result
    }

    func searchManga(query searchQuery: String, page: Int = 1, perPage: Int = 20) async throws -> [AniListManga] {
        let sanitized = searchQuery.replacingOccurrences(of: "\"", with: "\\\"")
        let query = """
        query {
            Page(page: \(page), perPage: \(perPage)) {
                media(search: "\(sanitized)", type: MANGA, format_not: NOVEL, sort: [POPULARITY_DESC]) {
                    \(mediaFragment)
                }
            }
        }
        """

        struct SearchResponse: Codable {
            let data: DataWrapper
            struct DataWrapper: Codable { let Page: PageData }
            struct PageData: Codable { let media: [AniListManga] }
        }

        let data = try await executeGraphQLQuery(query)
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return decoded.data.Page.media
    }

    func searchLightNovels(query searchQuery: String, page: Int = 1, perPage: Int = 20) async throws -> [AniListManga] {
        let sanitized = searchQuery.replacingOccurrences(of: "\"", with: "\\\"")
        let query = """
        query {
            Page(page: \(page), perPage: \(perPage)) {
                media(search: "\(sanitized)", type: MANGA, format: NOVEL, sort: [POPULARITY_DESC]) {
                    \(mediaFragment)
                }
            }
        }
        """

        struct SearchResponse: Codable {
            let data: DataWrapper
            struct DataWrapper: Codable { let Page: PageData }
            struct PageData: Codable { let media: [AniListManga] }
        }

        let data = try await executeGraphQLQuery(query)
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return decoded.data.Page.media
    }

    func fetchRandomManga(format: String? = nil) async throws -> AniListManga {
        let randomPage = Int.random(in: 1...300)
        let formatFilter = format != nil ? "format: \(format!)" : "format_not: NOVEL"
        let query = """
        query {
            Page(page: \(randomPage), perPage: 20) {
                media(type: MANGA, \(formatFilter), sort: [POPULARITY_DESC]) {
                    \(mediaFragment)
                }
            }
        }
        """

        struct RandomResponse: Codable {
            let data: DataWrapper
            struct DataWrapper: Codable { let Page: PageData }
            struct PageData: Codable { let media: [AniListManga] }
        }

        let data = try await executeGraphQLQuery(query)
        let decoded = try JSONDecoder().decode(RandomResponse.self, from: data)
        let results = decoded.data.Page.media
        guard let pick = results.randomElement() else {
            throw NSError(domain: "AniListManga", code: -1, userInfo: [NSLocalizedDescriptionKey: "No manga found"])
        }
        return pick
    }

    func fetchMangaDetail(id: Int) async throws -> AniListManga {
        let query = """
        query {
            Media(id: \(id), type: MANGA) {
                \(mediaFragment)
            }
        }
        """

        struct DetailResponse: Codable {
            let data: DataWrapper
            struct DataWrapper: Codable { let Media: AniListManga }
        }

        let data = try await executeGraphQLQuery(query)
        let decoded = try JSONDecoder().decode(DetailResponse.self, from: data)
        return decoded.data.Media
    }

    private func executeGraphQLQuery(_ query: String, maxRetries: Int = 3) async throws -> Data {
        await MangaRateLimiter.shared.waitForSlot()

        var request = URLRequest(url: graphQLEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = ["query": query]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var lastError: Error?
        for attempt in 0..<maxRetries {
            let (data, response) = try await URLSession.shared.boundedData(
                for: request,
                maximumResponseBytes: RemoteMediaNumericBoundary.maximumMetadataResponseBytes
            )

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    return data
                }

                if httpResponse.statusCode == 429 {
                    let delay = Self.boundedRetryDelay(
                        httpResponse.value(forHTTPHeaderField: "Retry-After"),
                        fallback: Double(2 * (attempt + 1))
                    )
                    ReaderLogger.shared.log("AniListManga rate limited (429), retry \(attempt + 1)/\(maxRetries) after \(delay)s", type: "AniList")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    lastError = NSError(domain: "AniListManga", code: 429, userInfo: [NSLocalizedDescriptionKey: "Rate limited"])
                    continue
                }

                let error = "AniListManga error (HTTP \(httpResponse.statusCode))"
                ReaderLogger.shared.log("AniListMangaService: GraphQL request failed with HTTP \(httpResponse.statusCode)", type: "Error")
                throw NSError(domain: "AniListManga", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: error])
            }

            throw NSError(domain: "AniListManga", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch from AniList"])
        }

        throw lastError ?? NSError(domain: "AniListManga", code: 429, userInfo: [NSLocalizedDescriptionKey: "Rate limited after \(maxRetries) retries"])
    }
}
