import Foundation

enum MacAniListCatalogKind: String, CaseIterable, Sendable {
    case trending
    case popular
    case topRated
    case airing
    case upcoming
}

struct MacAniListScheduleResult: Sendable {
    let entries: [MacScheduleEntry]
    let isAuthoritative: Bool
}

actor MacAniListCatalogService {
    static let shared = MacAniListCatalogService()

    private struct CacheEntry: Sendable {
        let item: MacMediaItem?
        let expiresAt: Date
    }

    private struct ReverseCacheEntry: Sendable {
        let anilistIDs: Set<Int>
        let expiresAt: Date
    }

    private var mediaCache: [Int: CacheEntry] = [:]
    private var reverseMappingCache: [Int: ReverseCacheEntry] = [:]

    func fetchHomeCatalogs(
        apiKey: String,
        requiredKinds: Set<MacAniListCatalogKind>,
        limit: Int = 20
    ) async throws -> [MacAniListCatalogKind: [MacMediaItem]] {
        guard !requiredKinds.isEmpty else { return [:] }
        let boundedLimit = min(max(limit, 1), 30)
        let fieldsByKind: [MacAniListCatalogKind: String] = [
            .trending: "trending: Page(page: 1, perPage: $limit) { media(type: ANIME, sort: TRENDING_DESC, isAdult: false) { id format } }",
            .popular: "popular: Page(page: 1, perPage: $limit) { media(type: ANIME, sort: POPULARITY_DESC, isAdult: false) { id format } }",
            .topRated: "topRated: Page(page: 1, perPage: $limit) { media(type: ANIME, sort: SCORE_DESC, isAdult: false) { id format } }",
            .airing: "airing: Page(page: 1, perPage: $limit) { media(type: ANIME, status: RELEASING, sort: POPULARITY_DESC, isAdult: false) { id format } }",
            .upcoming: "upcoming: Page(page: 1, perPage: $limit) { media(type: ANIME, status: NOT_YET_RELEASED, sort: POPULARITY_DESC, isAdult: false) { id format } }"
        ]
        let requestedFields = MacAniListCatalogKind.allCases
            .filter { requiredKinds.contains($0) }
            .compactMap { fieldsByKind[$0] }
            .joined(separator: "\n")
        let query = """
        query($limit: Int!) {
          \(requestedFields)
        }
        """
        let data: AniListCatalogData = try await graphQL(query: query, variables: ["limit": boundedLimit])
        let nodesByKind: [MacAniListCatalogKind: [AniListCatalogNode]] = [
            .trending: data.trending?.media ?? [],
            .popular: data.popular?.media ?? [],
            .topRated: data.topRated?.media ?? [],
            .airing: data.airing?.media ?? [],
            .upcoming: data.upcoming?.media ?? []
        ]

        var uniqueNodes: [AniListCatalogNode] = []
        var seenAniListIDs = Set<Int>()
        for kind in MacAniListCatalogKind.allCases where requiredKinds.contains(kind) {
            for node in nodesByKind[kind, default: []] where seenAniListIDs.insert(node.id).inserted {
                uniqueNodes.append(node)
            }
        }

        var mappedByAniListID: [Int: MacMediaItem] = [:]
        let concurrencyLimit = 6
        for start in stride(from: 0, to: uniqueNodes.count, by: concurrencyLimit) {
            try Task.checkCancellation()
            let chunk = Array(uniqueNodes[start..<min(start + concurrencyLimit, uniqueNodes.count)])
            let values = await withTaskGroup(of: (Int, MacMediaItem?).self, returning: [(Int, MacMediaItem?)].self) { group in
                for node in chunk {
                    group.addTask {
                        let item = try? await self.resolveMedia(anilistID: node.id, format: node.format, apiKey: apiKey)
                        return (node.id, item)
                    }
                }
                var output: [(Int, MacMediaItem?)] = []
                for await value in group { output.append(value) }
                return output
            }
            for (anilistID, item) in values {
                if let item { mappedByAniListID[anilistID] = item }
            }
        }

        guard !mappedByAniListID.isEmpty else { throw MacAniListError.noMappedMedia }
        var result: [MacAniListCatalogKind: [MacMediaItem]] = [:]
        for kind in MacAniListCatalogKind.allCases where requiredKinds.contains(kind) {
            var seenTMDBIDs = Set<String>()
            result[kind] = nodesByKind[kind, default: []]
                .compactMap { mappedByAniListID[$0.id] }
                .filter { seenTMDBIDs.insert($0.stableID).inserted }
        }
        return result
    }

    func fetchAiringSchedule(daysAhead: Int = 30, perPage: Int = 50) async throws -> MacAniListScheduleResult {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: min(max(daysAhead, 1), 37), to: start) ?? start
        let lowerBound = Int(start.timeIntervalSince1970) - 1
        let upperBound = Int(end.timeIntervalSince1970)
        let boundedPageSize = min(max(perPage, 1), 50)
        let maxPages = 20
        let query = """
        query($page: Int!, $perPage: Int!, $start: Int!, $end: Int!) {
          Page(page: $page, perPage: $perPage) {
            pageInfo { hasNextPage }
            airingSchedules(airingAt_greater: $start, airingAt_lesser: $end, sort: TIME) {
              id
              airingAt
              episode
              media {
                id
                isAdult
                format
                status
                title { english romaji native }
                coverImage { extraLarge large }
                bannerImage
              }
            }
          }
        }
        """

        var schedules: [AniListAiringNode] = []
        var page = 1
        var hasNextPage = true
        while hasNextPage && page <= maxPages {
            try Task.checkCancellation()
            let data: AniListScheduleData = try await graphQL(
                query: query,
                variables: ["page": page, "perPage": boundedPageSize, "start": lowerBound, "end": upperBound]
            )
            schedules.append(contentsOf: data.Page.airingSchedules)
            hasNextPage = data.Page.pageInfo.hasNextPage
            page += 1
            if hasNextPage && page <= maxPages {
                try await Task.sleep(for: .milliseconds(250))
            }
        }

        var seenScheduleIDs = Set<Int>()
        let entries = schedules
            .filter { $0.media.isAdult != true && seenScheduleIDs.insert($0.id).inserted }
            .compactMap { schedule -> MacScheduleEntry? in
                let airDate = Date(timeIntervalSince1970: TimeInterval(schedule.airingAt))
                guard airDate >= start && airDate < end else { return nil }
                let title = Self.preferredTitle(schedule.media.title)
                guard !title.isEmpty else { return nil }
                let show = MacMediaItem(
                    id: schedule.media.id,
                    mediaType: "anilist",
                    title: title,
                    overview: "",
                    posterPath: schedule.media.coverImage?.extraLarge ?? schedule.media.coverImage?.large,
                    backdropPath: schedule.media.bannerImage,
                    date: nil,
                    rating: 0
                )
                let format = schedule.media.format?.uppercased()
                return MacScheduleEntry(
                    show: show,
                    episodeID: schedule.id,
                    episodeTitle: "",
                    seasonNumber: nil,
                    episodeNumber: max(schedule.episode, 1),
                    airDate: airDate,
                    seriesStatus: "AniList · Airing",
                    classification: .anime,
                    source: .aniList,
                    hasKnownAiringTime: true,
                    anilistMediaID: schedule.media.id,
                    isAnimeSpecial: format == "SPECIAL" || format == "OVA"
                )
            }
            .sorted {
                if $0.airDate != $1.airDate { return $0.airDate < $1.airDate }
                return $0.show.title.localizedStandardCompare($1.show.title) == .orderedAscending
            }
        return MacAniListScheduleResult(entries: entries, isAuthoritative: !hasNextPage)
    }

    func resolveMedia(anilistID: Int, apiKey: String) async throws -> MacMediaItem? {
        try await resolveMedia(anilistID: anilistID, format: nil, apiKey: apiKey)
    }

    func aniListIDsByTMDBShowID(_ tmdbShowIDs: [Int]) async -> [Int: Set<Int>] {
        let uniqueIDs = Array(Set(tmdbShowIDs.filter { $0 > 0 }))
        var result: [Int: Set<Int>] = [:]
        let concurrencyLimit = 6
        for start in stride(from: 0, to: uniqueIDs.count, by: concurrencyLimit) {
            let chunk = Array(uniqueIDs[start..<min(start + concurrencyLimit, uniqueIDs.count)])
            let values = await withTaskGroup(of: (Int, Set<Int>).self, returning: [(Int, Set<Int>)].self) { group in
                for tmdbID in chunk {
                    group.addTask {
                        (tmdbID, await self.aniListIDs(forTMDBShowID: tmdbID))
                    }
                }
                var output: [(Int, Set<Int>)] = []
                for await value in group { output.append(value) }
                return output
            }
            for (tmdbID, ids) in values { result[tmdbID] = ids }
        }
        return result
    }

    private func resolveMedia(anilistID: Int, format: String?, apiKey: String) async throws -> MacMediaItem? {
        if let cached = mediaCache[anilistID], cached.expiresAt > Date() { return cached.item }
        let mappings = try await fetchMappings(value: anilistID, mappingKey: "anilist")
        let mapping = Self.bestMapping(mappings, anilistID: anilistID, format: format)
        guard let mapping, let identity = Self.tmdbIdentity(mapping, format: format) else {
            mediaCache[anilistID] = CacheEntry(item: nil, expiresAt: Date().addingTimeInterval(15 * 60))
            return nil
        }
        let item = try await fetchTMDBItem(identity: identity, apiKey: apiKey)
        mediaCache[anilistID] = CacheEntry(item: item, expiresAt: Date().addingTimeInterval(24 * 60 * 60))
        return item
    }

    private func aniListIDs(forTMDBShowID tmdbShowID: Int) async -> Set<Int> {
        if let cached = reverseMappingCache[tmdbShowID], cached.expiresAt > Date() { return cached.anilistIDs }
        let ids: Set<Int>
        do {
            let mappings = try await fetchMappings(value: tmdbShowID, mappingKey: "tmdb_show")
            ids = Set(mappings.compactMap { mapping in
                guard mapping.tmdbShowID == tmdbShowID else { return nil }
                return mapping.anilistID.flatMap { $0 > 0 ? $0 : nil }
            })
        } catch {
            ids = []
        }
        reverseMappingCache[tmdbShowID] = ReverseCacheEntry(
            anilistIDs: ids,
            expiresAt: Date().addingTimeInterval(ids.isEmpty ? 15 * 60 : 24 * 60 * 60)
        )
        return ids
    }

    private func graphQL<Value: Decodable>(query: String, variables: [String: Any]) async throws -> Value {
        guard let url = URL(string: "https://graphql.anilist.co") else { throw MacAniListError.invalidURL }
        let body = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await responseData(for: request, expectedHost: "graphql.anilist.co", maximumBytes: 8_000_000)
        let response = try JSONDecoder().decode(AniListGraphQLResponse<Value>.self, from: data)
        if let errors = response.errors, !errors.isEmpty {
            throw MacAniListError.graphQL(errors.map(\.message).joined(separator: "; "))
        }
        guard let value = response.data else { throw MacAniListError.missingData }
        return value
    }

    private func fetchMappings(value: Int, mappingKey: String) async throws -> [MacAniMapMapping] {
        guard value > 0, ["anilist", "tmdb_show"].contains(mappingKey) else { throw MacAniListError.invalidURL }
        let base = URL(string: "https://animap.s0n1c.ca")!
            .appendingPathComponent("mappings")
            .appendingPathComponent(String(value))
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "mapping_key", value: mappingKey)]
        guard let url = components?.url else { throw MacAniListError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.cachePolicy = .returnCacheDataElseLoad
        do {
            let data = try await responseData(for: request, expectedHost: "animap.s0n1c.ca", maximumBytes: 2_000_000)
            return try JSONDecoder().decode(MacAniMapMappingList.self, from: data).mappings
        } catch MacAniListError.httpStatus(404) {
            return []
        }
    }

    private func fetchTMDBItem(identity: TMDBIdentity, apiKey: String) async throws -> MacMediaItem? {
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(identity.mediaType)/\(identity.id)")
        components?.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        guard let url = components?.url else { throw MacAniListError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await responseData(for: request, expectedHost: "api.themoviedb.org", maximumBytes: 4_000_000)
        let detail = try JSONDecoder().decode(TMDBAniListDetail.self, from: data)
        let title = detail.title ?? detail.name ?? detail.originalTitle ?? detail.originalName
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return MacMediaItem(
            id: identity.id,
            mediaType: identity.mediaType,
            title: title,
            overview: detail.overview ?? "",
            posterPath: detail.posterPath,
            backdropPath: detail.backdropPath,
            date: detail.releaseDate ?? detail.firstAirDate,
            rating: detail.voteAverage ?? 0
        )
    }

    private func responseData(for request: URLRequest, expectedHost: String, maximumBytes: Int) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MacAniListError.invalidResponse }
        guard http.url?.scheme?.lowercased() == "https", http.url?.host?.lowercased() == expectedHost else {
            throw MacAniListError.invalidURL
        }
        guard 200..<300 ~= http.statusCode else { throw MacAniListError.httpStatus(http.statusCode) }
        guard data.count <= maximumBytes else { throw MacAniListError.responseTooLarge }
        return data
    }

    private static func preferredTitle(_ title: AniListTitle) -> String {
        for candidate in [title.english, title.romaji, title.native] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    private static func bestMapping(_ mappings: [MacAniMapMapping], anilistID: Int, format: String?) -> MacAniMapMapping? {
        mappings
            .filter { $0.anilistID == nil || $0.anilistID == anilistID }
            .max { mappingScore($0, format: format) < mappingScore($1, format: format) }
    }

    private static func mappingScore(_ mapping: MacAniMapMapping, format: String?) -> Int {
        let resolvedFormat = (format ?? mapping.mediaType ?? "").uppercased()
        let movieLike = ["MOVIE", "SPECIAL", "OVA"].contains(resolvedFormat)
        var score = 0
        if movieLike, mapping.tmdbMovieID.map({ $0 > 0 }) == true { score += 60 }
        if !movieLike, mapping.tmdbShowID.map({ $0 > 0 }) == true { score += 55 }
        if mapping.tmdbShowID.map({ $0 > 0 }) == true { score += 30 }
        if mapping.tmdbMovieID.map({ $0 > 0 }) == true { score += 20 }
        if mapping.tmdbSeason != nil { score += 3 }
        return score
    }

    private static func tmdbIdentity(_ mapping: MacAniMapMapping, format: String?) -> TMDBIdentity? {
        let resolvedFormat = (format ?? mapping.mediaType ?? "").uppercased()
        if ["MOVIE", "SPECIAL", "OVA"].contains(resolvedFormat), let id = mapping.tmdbMovieID, id > 0 {
            return TMDBIdentity(id: id, mediaType: "movie")
        }
        if let id = mapping.tmdbShowID, id > 0 { return TMDBIdentity(id: id, mediaType: "tv") }
        if let id = mapping.tmdbMovieID, id > 0 { return TMDBIdentity(id: id, mediaType: "movie") }
        return nil
    }
}

private struct AniListGraphQLResponse<Value: Decodable>: Decodable {
    let data: Value?
    let errors: [AniListGraphQLError]?
}

private struct AniListGraphQLError: Decodable {
    let message: String
}

private struct AniListCatalogData: Decodable {
    let trending: AniListCatalogPage?
    let popular: AniListCatalogPage?
    let topRated: AniListCatalogPage?
    let airing: AniListCatalogPage?
    let upcoming: AniListCatalogPage?
}

private struct AniListCatalogPage: Decodable {
    let media: [AniListCatalogNode]
}

private struct AniListCatalogNode: Decodable, Sendable {
    let id: Int
    let format: String?
}

private struct AniListScheduleData: Decodable {
    let Page: AniListSchedulePage
}

private struct AniListSchedulePage: Decodable {
    let pageInfo: AniListPageInfo
    let airingSchedules: [AniListAiringNode]
}

private struct AniListPageInfo: Decodable {
    let hasNextPage: Bool
}

private struct AniListAiringNode: Decodable {
    let id: Int
    let airingAt: Int
    let episode: Int
    let media: AniListAiringMedia
}

private struct AniListAiringMedia: Decodable {
    let id: Int
    let isAdult: Bool?
    let format: String?
    let status: String?
    let title: AniListTitle
    let coverImage: AniListCoverImage?
    let bannerImage: String?
}

private struct AniListTitle: Decodable {
    let english: String?
    let romaji: String?
    let native: String?
}

private struct AniListCoverImage: Decodable {
    let extraLarge: String?
    let large: String?
}

private struct MacAniMapMapping: Decodable {
    let anilistID: Int?
    let tmdbShowID: Int?
    let tmdbMovieID: Int?
    let tmdbSeason: Int?
    let mediaType: String?

    enum CodingKeys: String, CodingKey {
        case anilistID = "anilist_id"
        case tmdbShowID = "tmdb_show_id"
        case tmdbMovieID = "tmdb_movie_id"
        case tmdbSeason = "tmdb_season"
        case mediaType = "media_type"
    }
}

private struct MacAniMapMappingList: Decodable {
    let mappings: [MacAniMapMapping]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let values = try? container.decode([MacAniMapMapping].self) {
            mappings = values
        } else if let value = try? container.decode(MacAniMapMapping.self) {
            mappings = [value]
        } else {
            mappings = []
        }
    }
}

private struct TMDBIdentity: Sendable {
    let id: Int
    let mediaType: String
}

private struct TMDBAniListDetail: Decodable {
    let title: String?
    let name: String?
    let originalTitle: String?
    let originalName: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let voteAverage: Double?

    enum CodingKeys: String, CodingKey {
        case title, name, overview
        case originalTitle = "original_title"
        case originalName = "original_name"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
    }
}

private enum MacAniListError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case responseTooLarge
    case graphQL(String)
    case missingData
    case noMappedMedia

    var errorDescription: String? {
        switch self {
        case .invalidURL: "AniList returned an unsafe URL."
        case .invalidResponse: "AniList returned an invalid response."
        case .httpStatus(let status): "AniList request failed with HTTP \(status)."
        case .responseTooLarge: "AniList returned more data than Eclipse can safely process."
        case .graphQL(let message): "AniList request failed: \(message)"
        case .missingData: "AniList did not return catalog data."
        case .noMappedMedia: "AniList responded, but none of its titles could be matched to TMDB."
        }
    }
}
