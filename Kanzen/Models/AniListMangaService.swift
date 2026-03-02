//
//  AniListMangaService.swift
//  Kanzen
//
//  Created by Luna on 2025.
//

import Foundation

/// Rate limiter shared with the manga service to stay under AniList's 90 req/min limit.
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

// MARK: - Models

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

    struct AniListMangaTitle: Codable, Hashable {
        let romaji: String?
        let english: String?
        let native: String?
    }

    struct AniListMangaStartDate: Codable, Hashable {
        let year: Int?
    }

    struct AniListMangaCover: Codable, Hashable {
        let large: String?
        let medium: String?
    }

    /// Preferred display title following the user's language preference.
    var displayTitle: String {
        AniListMangaTitlePicker.title(from: title)
    }

    /// Best available cover URL.
    var coverURL: String? {
        coverImage?.large ?? coverImage?.medium
    }

    /// Start year from AniList.
    var startYear: Int? {
        startDate?.year
    }

    /// All non-nil title variants for multi-language search.
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

enum AniListMangaTitlePicker {
    private static func cleanTitle(_ title: String) -> String {
        let cleaned = title
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? title : cleaned
    }

    static func title(from title: AniListManga.AniListMangaTitle) -> String {
        let lang = (UserDefaults.standard.string(forKey: "tmdbLanguage") ?? "en-US")
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

// MARK: - Service

final class AniListMangaService {
    static let shared = AniListMangaService()

    private let graphQLEndpoint = URL(string: "https://graphql.anilist.co")!

    /// Fragment for the fields we need on every manga query.
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

    // MARK: - Catalog Fetching

    /// Fetch all manga catalogs in a single aliased GraphQL query.
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
            popularLightNovels: Page(perPage: \(limit)) {
                media(type: MANGA, format: NOVEL, sort: [POPULARITY_DESC]) { \(mediaFragment) }
            }
            topRatedLightNovels: Page(perPage: \(limit)) {
                media(type: MANGA, format: NOVEL, sort: [SCORE_DESC]) { \(mediaFragment) }
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
                let popularLightNovels: PageData
                let topRatedLightNovels: PageData
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
            "popularLightNovels": decoded.data.popularLightNovels.media,
            "topRatedLightNovels": decoded.data.topRatedLightNovels.media,
            "recentlyUpdated": decoded.data.recentlyUpdated.media,
        ]

        Logger.shared.log("AniListMangaService: Fetched all manga catalogs in 1 query", type: "AniList")
        return result
    }

    // MARK: - Search

    /// Search AniList for manga matching a query string.
    func searchManga(query searchQuery: String, page: Int = 1, perPage: Int = 20) async throws -> [AniListManga] {
        let sanitized = searchQuery.replacingOccurrences(of: "\"", with: "\\\"")
        let query = """
        query {
            Page(page: \(page), perPage: \(perPage)) {
                media(search: "\(sanitized)", type: MANGA, sort: [POPULARITY_DESC]) {
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

    // MARK: - Detail

    /// Fetch full details for a single manga by AniList ID.
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

    // MARK: - Network

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
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    return data
                }

                if httpResponse.statusCode == 429 {
                    let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                        .flatMap(Double.init) ?? Double(2 * (attempt + 1))
                    let delay = min(retryAfter, 10)
                    Logger.shared.log("AniListManga rate limited (429), retry \(attempt + 1)/\(maxRetries) after \(delay)s", type: "AniList")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    lastError = NSError(domain: "AniListManga", code: 429, userInfo: [NSLocalizedDescriptionKey: "Rate limited"])
                    continue
                }

                let error = "AniListManga error (HTTP \(httpResponse.statusCode))"
                Logger.shared.log("AniListMangaService: GraphQL request failed with HTTP \(httpResponse.statusCode)", type: "Error")
                throw NSError(domain: "AniListManga", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: error])
            }

            throw NSError(domain: "AniListManga", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch from AniList"])
        }

        throw lastError ?? NSError(domain: "AniListManga", code: 429, userInfo: [NSLocalizedDescriptionKey: "Rate limited after \(maxRetries) retries"])
    }
}
