import Foundation

/// Ensures AniList API calls are spaced out and adapts to AniList response headers.
/// Uses a slot-reservation pattern: each caller claims a future time slot BEFORE sleeping,
/// so concurrent callers queue up instead of bunching together.
private actor AniListRateLimiter {
    static let shared = AniListRateLimiter()
    
    private var minInterval: TimeInterval = 0.8
    private var nextAvailableTime: Date = .distantPast
    
    func waitForSlot() async {
        let now = Date()
        // Claim the next available slot
        let slotTime = max(now, nextAvailableTime)
        // Reserve it immediately so the next caller queues AFTER this one
        nextAvailableTime = slotTime.addingTimeInterval(minInterval)
        
        // Sleep until our reserved slot arrives
        let delay = slotTime.timeIntervalSince(now)
        if delay > 0.001 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    func recordResponse(_ response: HTTPURLResponse) {
        if let limitValue = response.value(forHTTPHeaderField: "X-RateLimit-Limit"),
           let limit = Double(limitValue),
           limit > 0 {
            minInterval = max(60.0 / limit, 0.8)
        }

        if response.statusCode == 429 {
            pauseUntilRetryAfter(response)
            return
        }

        guard let remainingValue = response.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
              let remaining = Int(remainingValue),
              remaining <= 1,
              let resetValue = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
              let reset = TimeInterval(resetValue) else {
            return
        }

        let resetDate = Date(timeIntervalSince1970: reset)
        if resetDate > Date() {
            nextAvailableTime = max(nextAvailableTime, resetDate)
        }
    }

    func pauseUntilRetryAfter(_ response: HTTPURLResponse) {
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
            .flatMap(TimeInterval.init) ?? 5
        nextAvailableTime = max(nextAvailableTime, Date().addingTimeInterval(min(max(retryAfter, 1), 120)))
    }
}

private struct AniMapMapping: Decodable {
    let anilistId: Int?
    let tmdbShowId: Int?
    let tmdbMovieId: Int?
    let tmdbSeason: Int?
    let tvdbSeason: Int?
    let tvdbEpisodeOffset: Int?
    let imdbId: String?
    let mediaType: String?

    enum CodingKeys: String, CodingKey {
        case anilistId = "anilist_id"
        case tmdbShowId = "tmdb_show_id"
        case tmdbMovieId = "tmdb_movie_id"
        case tmdbSeason = "tmdb_season"
        case tvdbSeason = "tvdb_season"
        case tvdbEpisodeOffset = "tvdb_epoffset"
        case imdbId = "imdb_id"
        case mediaType = "media_type"
    }
}

private actor AniMapSpecialsService {
    static let shared = AniMapSpecialsService()

    private let baseURL = URL(string: "https://animap.s0n1c.ca")!
    private var cacheByTMDBShowId: [Int: [AniMapMapping]] = [:]

    func specialMappings(forTMDBShowId tmdbShowId: Int) async -> [AniMapMapping] {
        if let cached = cacheByTMDBShowId[tmdbShowId] {
            return cached
        }

        let mappingsURL = baseURL
            .appendingPathComponent("mappings")
            .appendingPathComponent(String(tmdbShowId))
        guard var components = URLComponents(url: mappingsURL, resolvingAgainstBaseURL: false) else {
            cacheByTMDBShowId[tmdbShowId] = []
            return []
        }
        components.queryItems = [URLQueryItem(name: "mapping_key", value: "tmdb_show")]

        guard let url = components.url else {
            cacheByTMDBShowId[tmdbShowId] = []
            return []
        }

        do {
            let request = URLRequest(url: url, timeoutInterval: 4.0)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                cacheByTMDBShowId[tmdbShowId] = []
                return []
            }

            let decoded = try JSONDecoder().decode(AniMapMappingList.self, from: data)
            let mappings = decoded.mappings.filter { mapping in
                guard mapping.tmdbShowId == tmdbShowId,
                      let type = mapping.mediaType?.uppercased() else {
                    return false
                }
                return type == "SPECIAL" || type == "OVA"
            }
            cacheByTMDBShowId[tmdbShowId] = mappings
            return mappings
        } catch {
            Logger.shared.log("AniMapSpecialsService: lookup failed for TMDB show \(tmdbShowId): \(error.localizedDescription)", type: "AniList")
            cacheByTMDBShowId[tmdbShowId] = []
            return []
        }
    }

    private struct AniMapMappingList: Decodable {
        let mappings: [AniMapMapping]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let mappings = try? container.decode([AniMapMapping].self) {
                self.mappings = mappings
            } else if let mapping = try? container.decode(AniMapMapping.self) {
                self.mappings = [mapping]
            } else {
                self.mappings = []
            }
        }
    }
}

final class AniListService {
    static let shared = AniListService()

    private let graphQLEndpoint = URL(string: "https://graphql.anilist.co")!
    private var preferredLanguageCode: String {
        let raw = UserDefaults.standard.string(forKey: "tmdbLanguage") ?? "en-US"
        return raw.split(separator: "-").first.map(String.init) ?? "en"
    }

    // MARK: - In-Memory Cache for anime details (avoids re-fetching on back-navigation)
    private let animeDetailsCache = NSCache<NSNumber, AniListAnimeWithSeasonsWrapper>()
    private let animeCacheTTL: TimeInterval = 300 // 5 minutes

    /// NSCache requires reference-type values, so wrap the struct
    private final class AniListAnimeWithSeasonsWrapper {
        let value: AniListAnimeWithSeasons
        let timestamp: Date
        init(_ value: AniListAnimeWithSeasons) {
            self.value = value
            self.timestamp = Date()
        }
    }

    enum AniListCatalogKind {
        case trending
        case popular
        case topRated
        case airing
        case upcoming
    }

    // MARK: - Catalog Fetching

    /// Fetch all anime catalogs in a single AniList GraphQL query using aliases.
    /// Returns a dictionary keyed by AniListCatalogKind.
    func fetchAllAnimeCatalogs(
        limit: Int = 20,
        tmdbService: TMDBService
    ) async throws -> [AniListCatalogKind: [TMDBSearchResult]] {
        // Single aliased query fetches all 5 catalogs at once (1 API call instead of 5)
        let query = """
        query {
            trending: Page(perPage: \(limit)) {
                media(type: ANIME, sort: [TRENDING_DESC]) {
                    id
                    title { romaji english native }
                    episodes status seasonYear season
                    coverImage { large medium }
                    format
                }
            }
            popular: Page(perPage: \(limit)) {
                media(type: ANIME, sort: [POPULARITY_DESC]) {
                    id
                    title { romaji english native }
                    episodes status seasonYear season
                    coverImage { large medium }
                    format
                }
            }
            topRated: Page(perPage: \(limit)) {
                media(type: ANIME, sort: [SCORE_DESC]) {
                    id
                    title { romaji english native }
                    episodes status seasonYear season
                    coverImage { large medium }
                    format
                }
            }
            airing: Page(perPage: \(limit)) {
                media(type: ANIME, sort: [POPULARITY_DESC], status: RELEASING) {
                    id
                    title { romaji english native }
                    episodes status seasonYear season
                    coverImage { large medium }
                    format
                }
            }
            upcoming: Page(perPage: \(limit)) {
                media(type: ANIME, sort: [POPULARITY_DESC], status: NOT_YET_RELEASED) {
                    id
                    title { romaji english native }
                    episodes status seasonYear season
                    coverImage { large medium }
                    format
                }
            }
        }
        """

        struct PageData: Codable { let media: [AniListAnime] }
        struct AllCatalogsResponse: Codable {
            let data: DataWrapper
            struct DataWrapper: Codable {
                let trending: PageData
                let popular: PageData
                let topRated: PageData
                let airing: PageData
                let upcoming: PageData
            }
        }

        let data = try await executeGraphQLQuery(query, token: nil)
        let decoded = try JSONDecoder().decode(AllCatalogsResponse.self, from: data)

        // Hydrate all unique anime with TMDB matches in parallel (deduped)
        var allAnime: [AniListAnime] = []
        let lists: [(AniListCatalogKind, [AniListAnime])] = [
            (.trending, decoded.data.trending.media),
            (.popular, decoded.data.popular.media),
            (.topRated, decoded.data.topRated.media),
            (.airing, decoded.data.airing.media),
            (.upcoming, decoded.data.upcoming.media),
        ]
        var seenIds = Set<Int>()
        for (_, animeList) in lists {
            for anime in animeList {
                if seenIds.insert(anime.id).inserted {
                    allAnime.append(anime)
                }
            }
        }

        // Batch TMDB hydration for all unique anime
        let tmdbMap = await batchMapAniListToTMDB(allAnime, tmdbService: tmdbService)

        // Reassemble per-catalog results preserving order
        var result: [AniListCatalogKind: [TMDBSearchResult]] = [:]
        for (kind, animeList) in lists {
            result[kind] = animeList.compactMap { tmdbMap[$0.id] }
        }

        Logger.shared.log("AniListService: Fetched all 5 anime catalogs in 1 query (\(allAnime.count) unique anime)", type: "AniList")
        return result
    }

    /// Fetch a single anime catalog (kept for backward compatibility).
    func fetchAnimeCatalog(
        _ kind: AniListCatalogKind,
        limit: Int = 20,
        tmdbService: TMDBService
    ) async throws -> [TMDBSearchResult] {
        let sort: String
        let status: String?

        switch kind {
        case .trending:
            sort = "TRENDING_DESC"
            status = nil
        case .popular:
            sort = "POPULARITY_DESC"
            status = nil
        case .topRated:
            sort = "SCORE_DESC"
            status = nil
        case .airing:
            sort = "POPULARITY_DESC"
            status = "RELEASING"
        case .upcoming:
            sort = "POPULARITY_DESC"
            status = "NOT_YET_RELEASED"
        }

        let statusClause = status.map { ", status: \($0)" } ?? ""

        let query = """
        query {
            Page(perPage: \(limit)) {
                media(type: ANIME, sort: [\(sort)]\(statusClause)) {
                    id
                    title { romaji english native }
                    episodes
                    status
                    seasonYear
                    season
                    coverImage { large medium }
                    format
                }
            }
        }
        """

        struct CatalogResponse: Codable {
            let data: DataWrapper
            struct DataWrapper: Codable { let Page: PageData }
            struct PageData: Codable { let media: [AniListAnime] }
        }

        let data = try await executeGraphQLQuery(query, token: nil)
        let decoded = try JSONDecoder().decode(CatalogResponse.self, from: data)
        let animeList = decoded.data.Page.media
        return await mapAniListCatalogToTMDB(animeList, tmdbService: tmdbService)
    }

    // MARK: - Airing Schedule

    /// Fetch upcoming airing episodes for the next `daysAhead` days (default 7).
    func fetchAiringSchedule(daysAhead: Int = 7, perPage: Int = 50) async throws -> [AniListAiringScheduleEntry] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let today = calendar.startOfDay(for: Date())
        let upperDay = calendar.date(byAdding: .day, value: max(daysAhead, 1) + 1, to: today) ?? today

        let lowerBound = Int(today.timeIntervalSince1970)
        let upperBound = Int(upperDay.timeIntervalSince1970)

        struct Response: Codable {
            let data: DataWrapper
            struct DataWrapper: Codable {
                let Page: PageData
            }
            struct PageData: Codable {
                let pageInfo: PageInfo
                let airingSchedules: [AiringSchedule]
            }
            struct PageInfo: Codable {
                let hasNextPage: Bool
            }
            struct AiringSchedule: Codable {
                let id: Int
                let airingAt: Int
                let episode: Int
                let media: AniListAnime
            }
        }

        var allSchedules: [Response.AiringSchedule] = []
        var currentPage = 1
        var hasNextPage = true
        let maxPages = 10

        while hasNextPage && currentPage <= maxPages {
            let query = """
            query {
                Page(page: \(currentPage), perPage: \(perPage)) {
                    pageInfo { hasNextPage }
                    airingSchedules(airingAt_greater: \(lowerBound - 1), airingAt_lesser: \(upperBound), sort: TIME) {
                        id
                        airingAt
                        episode
                        media {
                            id
                            title { romaji english native }
                            coverImage { large medium }
                            format
                        }
                    }
                }
            }
            """

            let data = try await executeGraphQLQuery(query, token: nil)
            let decoded = try JSONDecoder().decode(Response.self, from: data)

            allSchedules.append(contentsOf: decoded.data.Page.airingSchedules)
            hasNextPage = decoded.data.Page.pageInfo.hasNextPage
            currentPage += 1

            // Brief pause between pages to avoid rate limiting
            if hasNextPage && currentPage <= maxPages {
                try await Task.sleep(nanoseconds: 400_000_000) // 0.4s
            }
        }

        let start = today
        let end = upperDay

        return allSchedules
            .map { schedule in
                let title = AniListTitlePicker.title(from: schedule.media.title, preferredLanguageCode: preferredLanguageCode)
                let cover = schedule.media.coverImage?.large ?? schedule.media.coverImage?.medium
                return AniListAiringScheduleEntry(
                    id: schedule.id,
                    mediaId: schedule.media.id,
                    title: title,
                    airingAt: Date(timeIntervalSince1970: TimeInterval(schedule.airingAt)),
                    episode: schedule.episode,
                    coverImage: cover,
                    englishTitle: schedule.media.title.english,
                    romajiTitle: schedule.media.title.romaji,
                    nativeTitle: schedule.media.title.native,
                    format: schedule.media.format
                )
            }
            .filter { entry in
                entry.airingAt >= start && entry.airingAt < end
            }
    }
    
    /// Fetch full anime details with seasons and episodes from AniList + TMDB
    /// Uses AniList for season structure and sequels, TMDB for episode details
    func fetchAnimeDetailsWithEpisodes(
        title: String,
        tmdbShowId: Int,
        tmdbService: TMDBService,
        tmdbShowPoster: String?,
        token: String?
    ) async throws -> AniListAnimeWithSeasons {
        // Check in-memory cache first
        let cacheKey = NSNumber(value: tmdbShowId)
        if let cached = animeDetailsCache.object(forKey: cacheKey),
           Date().timeIntervalSince(cached.timestamp) < animeCacheTTL {
            Logger.shared.log("AniListService: Cache HIT for tmdbId=\(tmdbShowId)", type: "AniList")
            return cached.value
        }

        Logger.shared.log("AniListService: fetchAnimeDetailsWithEpisodes START for '\(title)' tmdbId=\(tmdbShowId)", type: "AniList")
        // Query AniList for anime structure + sequels + coverImage (multiple candidates for better matching)
        let query = """
        query {
            Page(perPage: 6) {
                media(search: "\(title.replacingOccurrences(of: "\"", with: "\\\""))", type: ANIME, sort: POPULARITY_DESC) {
                    id
                    title {
                        romaji
                        english
                        native
                    }
                    episodes
                    status
                    seasonYear
                    season
                    coverImage {
                        large
                        medium
                    }
                    format
                    nextAiringEpisode {
                        episode
                        airingAt
                    }
                    relations {
                        edges {
                            relationType
                            node {
                                id
                                title {
                                    romaji
                                    english
                                    native
                                }
                                episodes
                                status
                                seasonYear
                                season
                                format
                                type
                                coverImage {
                                    large
                                    medium
                                }
                                relations {
                                    edges {
                                        relationType
                                        node {
                                            id
                                            title { romaji english native }
                                            episodes
                                            status
                                            seasonYear
                                            season
                                            format
                                            type
                                            coverImage { large medium }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        """
        
        Logger.shared.log("AniListService: Sending AniList GraphQL query for '\(title)'", type: "AniList")
        let response = try await executeGraphQLQuery(query, token: token)
        
        struct Response: Codable {
            let data: DataWrapper
            struct DataWrapper: Codable {
                let Page: PageData
                struct PageData: Codable { let media: [AniListAnime] }
            }
        }
        
        let result = try JSONDecoder().decode(Response.self, from: response)
        let candidates = result.data.Page.media
        Logger.shared.log("AniListService: AniList returned \(candidates.count) candidates for '\(title)'", type: "AniList")
        guard !candidates.isEmpty else {
            Logger.shared.log("AniListService: NO candidates from AniList for '\(title)' — throwing", type: "Error")
            throw NSError(domain: "AniListService", code: -1, userInfo: [NSLocalizedDescriptionKey: "AniList did not return any matches for \(title)"])
        }

        // Fetch TMDB show info early for hinting (episode count, first air year) and reuse later.
        let tvShowDetail: TMDBTVShowWithSeasons? = await {
            do {
                return try await tmdbService.getTVShowWithSeasons(id: tmdbShowId)
            } catch {
                Logger.shared.log("AniListService: Failed to prefetch TMDB show details: \(error.localizedDescription)", type: "TMDB")
                return nil
            }
        }()

        var anime = pickBestAniListMatch(from: candidates, tmdbShow: tvShowDetail)

        // If the best match looks suspicious (e.g. OVA with 2 eps when TMDB has 86),
        // check its relation edges for the parent/main TV series. OVAs/Specials always
        // have a PARENT or SOURCE relation to the main show. This avoids an extra API call.
        // (e.g. "Food Wars! Shokugeki no Soma" → AniList OVA → PARENT → main TV series)
        if let tmdbEps = tvShowDetail?.numberOfEpisodes, tmdbEps > 12,
           let selectedEps = anime.episodes, selectedEps < tmdbEps / 4 {
            Logger.shared.log("AniListService: Match looks suspicious (\(selectedEps) eps vs TMDB \(tmdbEps)) \u{2014} checking relation edges for main series", type: "AniList")
            let parentRelTypes: Set<String> = ["PARENT", "SOURCE", "PREQUEL"]
            let tvFormats: Set<String> = ["TV", "TV_SHORT", "ONA"]
            if let edges = anime.relations?.edges {
                let betterNode = edges
                    .filter { parentRelTypes.contains($0.relationType) && $0.node.type == "ANIME" }
                    .filter { node in
                        guard let fmt = node.node.format else { return true }
                        return tvFormats.contains(fmt)
                    }
                    .max(by: { ($0.node.episodes ?? 0) < ($1.node.episodes ?? 0) })

                if let better = betterNode, (better.node.episodes ?? 0) > selectedEps {
                    let betterAnime = better.node.asAnime()
                    Logger.shared.log("AniListService: Found better match via relations: '\(AniListTitlePicker.title(from: betterAnime.title, preferredLanguageCode: preferredLanguageCode))' with \(betterAnime.episodes ?? 0) eps", type: "AniList")
                    anime = betterAnime
                }
            }
        }

        let title = AniListTitlePicker.title(from: anime.title, preferredLanguageCode: preferredLanguageCode)
        Logger.shared.log("AniListService: Selected AniList match '\(title)' (id: \(anime.id))", type: "AniList")
        let seasonVal = anime.season ?? "UNKNOWN"
        Logger.shared.log(
            "AniListService: Raw response - episodes: \(anime.episodes ?? 0), seasonYear: \(anime.seasonYear ?? 0), season: \(seasonVal)",
            type: "AniList"
        )
        
        // Collect all anime to process (original + all recursive sequels) with posters
        var allAnimeToProcess: [(anime: AniListAnime, seasonOffset: Int, posterUrl: String?)] = []

        func appendAnime(_ entry: AniListAnime) {
            let poster = entry.coverImage?.large ?? entry.coverImage?.medium ?? tmdbShowPoster
            allAnimeToProcess.append((entry, 0, poster))
        }

        appendAnime(anime)
        
        Logger.shared.log("AniListService: Starting sequel detection for \(AniListTitlePicker.title(from: anime.title, preferredLanguageCode: preferredLanguageCode)) (ID: \(anime.id), episodes: \(anime.episodes ?? 0), relations: \(anime.relations?.edges.count ?? 0))", type: "AniList")

        // Allowed relation types we treat as season/continuation
        let allowedRelationTypes: Set<String> = ["SEQUEL", "PREQUEL", "SEASON"]

        // BFS over sequels/prequels/seasons, batch-fetching nodes that need deeper relations per level
        var queue: [AniListAnime] = [anime]
        var seenIds = Set<Int>([anime.id])

        while !queue.isEmpty {
            let currentLevel = queue
            queue.removeAll()

            var idsToFetch: [Int] = []
            var shallowNodes: [Int: AniListAnime.AniListRelationNode] = [:]

            for current in currentLevel {
                let currentTitle = AniListTitlePicker.title(from: current.title, preferredLanguageCode: preferredLanguageCode)
                let edges = current.relations?.edges ?? []
                Logger.shared.log("AniListService: Checking relations for '\(currentTitle)': \(edges.count) edges total", type: "AniList")

                for edge in edges {
                    guard allowedRelationTypes.contains(edge.relationType), edge.node.type == "ANIME" else {
                        continue
                    }
                    if let format = edge.node.format, !(format == "TV" || format == "TV_SHORT" || format == "ONA") {
                        continue
                    }
                    if !seenIds.insert(edge.node.id).inserted {
                        continue
                    }

                    let edgeTitle = AniListTitlePicker.title(from: edge.node.title, preferredLanguageCode: preferredLanguageCode)
                    Logger.shared.log("    \u{2192} Added sequel: \(edgeTitle)", type: "AniList")

                    if edge.node.relations != nil {
                        let fullNode = edge.node.asAnime()
                        appendAnime(fullNode)
                        queue.append(fullNode)
                    } else {
                        idsToFetch.append(edge.node.id)
                        shallowNodes[edge.node.id] = edge.node
                    }
                }
            }

            if !idsToFetch.isEmpty {
                Logger.shared.log("AniListService: Batch-fetching \(idsToFetch.count) sequel nodes in 1 query", type: "AniList")
                let fetchedNodes = await batchFetchAniListNodes(ids: idsToFetch)
                for id in idsToFetch {
                    let fullNode: AniListAnime
                    if let fetched = fetchedNodes[id] {
                        fullNode = fetched
                    } else if let shallow = shallowNodes[id] {
                        fullNode = shallow.asAnime()
                    } else {
                        continue
                    }
                    appendAnime(fullNode)
                    queue.append(fullNode)
                }
            }
        }

        // Fix B: If BFS found significantly fewer episodes than TMDB has, search AniList for orphaned entries
        // Handles disconnected AniList graphs (e.g. SAO where S2→S3 relation edge is missing)
        // Uses total episode count (not season count) to avoid false positives when TMDB splits seasons differently (e.g. Gintama)
        if let tvShowDetail, !allAnimeToProcess.isEmpty, let tmdbTotalEps = tvShowDetail.numberOfEpisodes, tmdbTotalEps > 0 {
            let anilistTotalEps = allAnimeToProcess.reduce(0) { $0 + ($1.anime.episodes ?? 0) }
            if anilistTotalEps < Int(Double(tmdbTotalEps) * 0.75) {
                Logger.shared.log("AniListService: BFS found \(anilistTotalEps) episodes but TMDB has \(tmdbTotalEps) \u{2014} searching for orphaned entries", type: "AniList")
                let searchTitle = tvShowDetail.name
                let orphanQuery = """
                query {
                    Page(perPage: 20) {
                        media(search: "\(searchTitle.replacingOccurrences(of: "\"", with: "\\\""))", type: ANIME, sort: POPULARITY_DESC) {
                            id
                            title { romaji english native }
                            episodes
                            status
                            seasonYear
                            season
                            coverImage { large medium }
                            format
                            type
                        }
                    }
                }
                """

                struct OrphanResponse: Codable {
                    let data: DataWrapper
                    struct DataWrapper: Codable {
                        let Page: PageData
                        struct PageData: Codable { let media: [AniListAnime] }
                    }
                }

                if let orphanData = try? await executeGraphQLQuery(orphanQuery, token: token),
                   let orphanDecoded = try? JSONDecoder().decode(OrphanResponse.self, from: orphanData) {
                    let orphanAllowedFormats: Set<String> = ["TV", "TV_SHORT", "ONA"]
                    let rootTitle = title.lowercased()
                    let rootWords = rootTitle.split(separator: " ").prefix(3).joined(separator: " ")
                    let spinoffKeywords = ["alternative", "movie", "special", "ova", "recap", "summary", "picture drama", "pilot"]

                    // Filter to valid orphan candidates (franchise match + no spinoffs)
                    var orphanCandidates: [AniListAnime] = []
                    for candidate in orphanDecoded.data.Page.media {
                        guard !seenIds.contains(candidate.id) else { continue }
                        guard candidate.type == "ANIME" else { continue }
                        if let format = candidate.format, !orphanAllowedFormats.contains(format) { continue }

                        let candidateTitle = AniListTitlePicker.title(from: candidate.title, preferredLanguageCode: preferredLanguageCode).lowercased()
                        let candidateRomaji = candidate.title.romaji?.lowercased() ?? ""
                        guard candidateTitle.contains(rootWords) || candidateRomaji.contains(rootWords) else { continue }

                        // Skip spinoffs/alternatives — only want direct continuations
                        let checkTitle = candidateTitle + " " + candidateRomaji
                        if spinoffKeywords.contains(where: { checkTitle.contains($0) }) { continue }

                        orphanCandidates.append(candidate)
                    }

                    // Pick the best orphan: the one chronologically closest after the last BFS-found season
                    // This ensures we grab the next continuation, not an arbitrary spinoff
                    let lastKnownYear = allAnimeToProcess.compactMap { $0.anime.seasonYear }.max() ?? 0
                    let sortedOrphans = orphanCandidates
                        .filter { ($0.seasonYear ?? Int.max) >= lastKnownYear }
                        .sorted { ($0.seasonYear ?? Int.max) < ($1.seasonYear ?? Int.max) }
                    if let bestOrphan = sortedOrphans.first ?? orphanCandidates.first {
                        seenIds.insert(bestOrphan.id)
                        appendAnime(bestOrphan)
                        Logger.shared.log("AniListService: Best orphan entry: '\(AniListTitlePicker.title(from: bestOrphan.title, preferredLanguageCode: preferredLanguageCode))' (id: \(bestOrphan.id), episodes: \(bestOrphan.episodes ?? 0))", type: "AniList")

                        // Fetch full relations for the orphan so we can BFS from it
                        let orphanWithRelations: AniListAnime
                        if bestOrphan.relations != nil {
                            orphanWithRelations = bestOrphan
                        } else if let fetched = (await batchFetchAniListNodes(ids: [bestOrphan.id]))[bestOrphan.id] {
                            orphanWithRelations = fetched
                        } else {
                            orphanWithRelations = bestOrphan
                        }

                        // BFS from orphan to discover its sequels (e.g. SAO Alicization → War of Underworld)
                        var orphanQueue: [AniListAnime] = [orphanWithRelations]
                        while !orphanQueue.isEmpty {
                            let currentOrphanLevel = orphanQueue
                            orphanQueue.removeAll()

                            var orphanIdsToFetch: [Int] = []
                            var orphanShallowNodes: [Int: AniListAnime.AniListRelationNode] = [:]

                            for current in currentOrphanLevel {
                                let edges = current.relations?.edges ?? []
                                for edge in edges {
                                    guard allowedRelationTypes.contains(edge.relationType), edge.node.type == "ANIME" else {
                                        continue
                                    }
                                    if let format = edge.node.format, !(format == "TV" || format == "TV_SHORT" || format == "ONA") { continue }
                                    if !seenIds.insert(edge.node.id).inserted { continue }

                                    let edgeTitle = AniListTitlePicker.title(from: edge.node.title, preferredLanguageCode: preferredLanguageCode)
                                    Logger.shared.log("    \u{2192} Added orphan sequel: \(edgeTitle)", type: "AniList")

                                    if edge.node.relations != nil {
                                        let fullNode = edge.node.asAnime()
                                        appendAnime(fullNode)
                                        orphanQueue.append(fullNode)
                                    } else {
                                        orphanIdsToFetch.append(edge.node.id)
                                        orphanShallowNodes[edge.node.id] = edge.node
                                    }
                                }
                            }

                            if !orphanIdsToFetch.isEmpty {
                                Logger.shared.log("AniListService: Batch-fetching \(orphanIdsToFetch.count) orphan sequel nodes", type: "AniList")
                                let fetchedOrphans = await batchFetchAniListNodes(ids: orphanIdsToFetch)
                                for id in orphanIdsToFetch {
                                    let fullNode: AniListAnime
                                    if let fetched = fetchedOrphans[id] {
                                        fullNode = fetched
                                    } else if let shallow = orphanShallowNodes[id] {
                                        fullNode = shallow.asAnime()
                                    } else {
                                        continue
                                    }
                                    appendAnime(fullNode)
                                    orphanQueue.append(fullNode)
                                }
                            }
                        }
                    }
                }
            }
        }

        // Fix A: Sort collected anime chronologically so seasons are in correct order
        // regardless of BFS traversal order or orphan discovery order
        allAnimeToProcess.sort { lhs, rhs in
            let lhsYear = lhs.anime.seasonYear ?? Int.max
            let rhsYear = rhs.anime.seasonYear ?? Int.max
            if lhsYear != rhsYear { return lhsYear < rhsYear }
            return lhs.anime.id < rhs.anime.id
        }

        // Fix C: Prune entries that belong to a separate TMDB show.
        // E.g. "Naruto" and "Naruto Shippuden" are separate TMDB entries;
        // when viewing one, we shouldn't merge episodes from the other.
        // Only keep entries contiguous with the root match that fit within the TMDB episode budget.
        if let tvShowDetail, let tmdbTotalEps = tvShowDetail.numberOfEpisodes, tmdbTotalEps > 0 {
            let anilistTotalEps = allAnimeToProcess.reduce(0) { $0 + ($1.anime.episodes ?? 0) }
            if anilistTotalEps > Int(Double(tmdbTotalEps) * 1.25) {
                let rootIndex = allAnimeToProcess.firstIndex(where: { $0.anime.id == anime.id }) ?? 0
                var keepStart = rootIndex
                var keepEnd = rootIndex
                var total = allAnimeToProcess[rootIndex].anime.episodes ?? 0
                let budget = Int(Double(tmdbTotalEps) * 1.25)

                var canExpandLeft = true, canExpandRight = true
                while canExpandLeft || canExpandRight {
                    if canExpandLeft && keepStart > 0 {
                        let eps = allAnimeToProcess[keepStart - 1].anime.episodes ?? 0
                        if total + eps <= budget { keepStart -= 1; total += eps }
                        else { canExpandLeft = false }
                    } else { canExpandLeft = false }

                    if canExpandRight && keepEnd < allAnimeToProcess.count - 1 {
                        let eps = allAnimeToProcess[keepEnd + 1].anime.episodes ?? 0
                        if total + eps <= budget { keepEnd += 1; total += eps }
                        else { canExpandRight = false }
                    } else { canExpandRight = false }
                }

                let pruned = allAnimeToProcess.count - (keepEnd - keepStart + 1)
                if pruned > 0 {
                    Logger.shared.log("AniListService: Pruned \(pruned) entries that exceed TMDB episode budget (\(anilistTotalEps) AniList eps vs \(tmdbTotalEps) TMDB eps)", type: "AniList")
                    allAnimeToProcess = Array(allAnimeToProcess[keepStart...keepEnd])
                }
            }
        }

        // Fetch all TMDB season data in parallel (excluding Season 0 specials)
        // Build an absolute episode index so we can map stills/runtime even when seasons reset numbering
        var tmdbEpisodesByAbsolute: [Int: TMDBEpisode] = [:]
        if let tvShowDetail {
            // Sort seasons by seasonNumber to keep ordering consistent
            let realSeasons = tvShowDetail.seasons.filter { $0.seasonNumber > 0 }.sorted { $0.seasonNumber < $1.seasonNumber }
            
            // Fetch all seasons in parallel for speed
            var seasonResults: [(seasonNumber: Int, episodes: [TMDBEpisode])] = []
            await withTaskGroup(of: (Int, [TMDBEpisode]?).self) { group in
                for season in realSeasons {
                    group.addTask {
                        do {
                            let detail = try await tmdbService.getSeasonDetails(tvShowId: tmdbShowId, seasonNumber: season.seasonNumber)
                            return (season.seasonNumber, detail.episodes)
                        } catch {
                            Logger.shared.log("AniListService: Failed to fetch TMDB season \(season.seasonNumber): \(error.localizedDescription)", type: "AniList")
                            return (season.seasonNumber, nil)
                        }
                    }
                }
                for await (seasonNum, episodes) in group {
                    if let episodes {
                        seasonResults.append((seasonNum, episodes))
                    }
                }
            }
            
            // Process results in season order
            seasonResults.sort { $0.seasonNumber < $1.seasonNumber }
            var absoluteIndex = 1
            for (seasonNum, episodes) in seasonResults {
                let sorted = episodes.sorted(by: { $0.episodeNumber < $1.episodeNumber })
                Logger.shared.log("AniListService: TMDB season \(seasonNum) returned \(sorted.count) episodes", type: "AniList")
                for episode in sorted {
                    tmdbEpisodesByAbsolute[absoluteIndex] = episode
                    if absoluteIndex <= 3 {
                        Logger.shared.log("  Episode \(episode.episodeNumber): '\(episode.name)', overview: \(episode.overview?.isEmpty == false ? "YES" : "NO"), stillPath: \(episode.stillPath != nil ? "YES" : "NO")", type: "AniList")
                    }
                    absoluteIndex += 1
                }
            }
        }
        
        // ALWAYS attempt fallback season fetch if we don't have enough episodes yet
        // This ensures we get episode metadata even when show detail fetch fails
        if tmdbEpisodesByAbsolute.isEmpty {
            Logger.shared.log("AniListService: No TMDB episodes loaded; attempting direct season fetch", type: "AniList")
            var absoluteIndex = 1
            var seasonNumber = 1
            // Keep fetching seasons until we hit an error or empty season
            // This handles any length anime (One Piece 20+ seasons, etc.)
            while true {
                do {
                    let seasonDetail = try await tmdbService.getSeasonDetails(tvShowId: tmdbShowId, seasonNumber: seasonNumber)
                    if seasonDetail.episodes.isEmpty {
                        Logger.shared.log("AniListService: Fallback found empty season \(seasonNumber), stopping", type: "AniList")
                        break
                    }
                    for episode in seasonDetail.episodes.sorted(by: { $0.episodeNumber < $1.episodeNumber }) {
                        tmdbEpisodesByAbsolute[absoluteIndex] = episode
                        absoluteIndex += 1
                    }
                    Logger.shared.log("AniListService: Fallback fetched season \(seasonNumber): \(seasonDetail.episodes.count) episodes", type: "AniList")
                    seasonNumber += 1
                } catch {
                    // Stop when we hit an error (likely season does not exist)
                    Logger.shared.log("AniListService: Fallback stopped at season \(seasonNumber) (no more seasons found)", type: "AniList")
                    break
                }
            }
        }
        
        // Build all seasons from AniList structure + TMDB episode details
        var seasons: [AniListSeasonWithPoster] = []
        var currentAbsoluteEpisode = 1
        var seasonIndex = 1
        
        for (currentAnime, _, posterUrl) in allAnimeToProcess {
            // Get the full AniList title for this season/sequel
            // Keep core anime season naming aligned with the user's preferred title language.
            let seasonTitle = AniListTitlePicker.title(from: currentAnime.title, preferredLanguageCode: preferredLanguageCode)
            
            // Use AniList episode count - this is authoritative
            let anilistEpisodeCount = currentAnime.episodes ?? 0
            
            // Only fall back to remaining TMDB episodes if AniList has no data
            let totalEpisodesInAnime: Int
            if anilistEpisodeCount > 0 {
                totalEpisodesInAnime = anilistEpisodeCount
                Logger.shared.log("AniListService: Season \(seasonIndex) '\(seasonTitle)' using AniList count: \(totalEpisodesInAnime) episodes", type: "AniList")
            } else {
                let remainingTmdb = max(0, tmdbEpisodesByAbsolute.count - (currentAbsoluteEpisode - 1))
                totalEpisodesInAnime = remainingTmdb > 0 ? remainingTmdb : 12
                Logger.shared.log("AniListService: Season \(seasonIndex) '\(seasonTitle)' AniList has no count, falling back to: \(totalEpisodesInAnime) episodes", type: "AniList")
            }
            
            // Each anime (original or sequel) is its own season with episodes numbered from 1
            // Use AniList S/E for service search, but pull metadata from TMDB using absolute index
            let seasonEpisodes: [AniListEpisode] = (0..<totalEpisodesInAnime).map { offset in
                let absoluteEp = currentAbsoluteEpisode + offset
                let localEp = offset + 1
                if let tmdbEp = tmdbEpisodesByAbsolute[absoluteEp] {
                    return AniListEpisode(
                        number: localEp,              // AniList episode (1-12) for search
                        title: tmdbEp.name,           // TMDB metadata
                        description: tmdbEp.overview, // TMDB metadata
                        seasonNumber: seasonIndex,    // AniList season for search
                        stillPath: tmdbEp.stillPath,  // TMDB metadata
                        airDate: tmdbEp.airDate,      // TMDB metadata
                        runtime: tmdbEp.runtime,      // TMDB metadata
                        tmdbSeasonNumber: tmdbEp.seasonNumber,    // Original TMDB S
                        tmdbEpisodeNumber: tmdbEp.episodeNumber   // Original TMDB E
                    )
                } else {
                    return AniListEpisode(
                        number: localEp,
                        title: "Episode \(localEp)",
                        description: nil,
                        seasonNumber: seasonIndex,
                        stillPath: nil,
                        airDate: nil,
                        runtime: nil,
                        tmdbSeasonNumber: nil,
                        tmdbEpisodeNumber: nil
                    )
                }
            }
            
            // Use AniList poster for proper season structure (don't mix with TMDB seasons)
            seasons.append(AniListSeasonWithPoster(
                seasonNumber: seasonIndex,
                anilistId: currentAnime.id,
                title: seasonTitle,
                episodes: seasonEpisodes,
                posterUrl: posterUrl
            ))
            
            currentAbsoluteEpisode += totalEpisodesInAnime
            seasonIndex += 1
        }
        
        let totalEpisodes = seasons.reduce(0) { $0 + $1.episodes.count }
        Logger.shared.log("AniListService: Fetched \(title) with \(totalEpisodes) total episodes grouped into \(seasons.count) seasons", type: "AniList")
        for season in seasons {
            Logger.shared.log("  Season \(season.seasonNumber): \(season.episodes.count) episodes, poster: \(season.posterUrl ?? "none")", type: "AniList")
        }

        let animeWithSeasons = AniListAnimeWithSeasons(
            id: anime.id,
            title: title,
            seasons: seasons,
            totalEpisodes: totalEpisodes,
            status: anime.status ?? "UNKNOWN"
        )
        
        // Cache the result for fast back-navigation
        animeDetailsCache.setObject(AniListAnimeWithSeasonsWrapper(animeWithSeasons), forKey: NSNumber(value: tmdbShowId))
        
        return animeWithSeasons
    }

    func fetchSpecialSearchEntries(
        tmdbShowId: Int,
        fallbackPosterURL: String?,
        tmdbService: TMDBService
    ) async -> [AniListSpecialSearchEntry] {
        let mappings = await AniMapSpecialsService.shared.specialMappings(forTMDBShowId: tmdbShowId)
        let uniqueMappings = mappings.reduce(into: [Int: AniMapMapping]()) { result, mapping in
            guard let anilistId = mapping.anilistId, result[anilistId] == nil else { return }
            result[anilistId] = mapping
        }

        guard !uniqueMappings.isEmpty else { return [] }

        let nodesById = await batchFetchAniListNodes(ids: Array(uniqueMappings.keys))
        // Some AniMap specials only expose a fallback season number for metadata.
        // Keep playback/search tied to tmdbSeason so specials stay isolated from the main anime flow.
        let metadataSeasonNumbers = Set(uniqueMappings.values.compactMap { $0.tmdbSeason ?? $0.tvdbSeason })
        var seasonDetailsByNumber: [Int: TMDBSeasonDetail] = [:]

        if !metadataSeasonNumbers.isEmpty {
            await withTaskGroup(of: (Int, TMDBSeasonDetail?).self) { group in
                for seasonNumber in metadataSeasonNumbers {
                    group.addTask {
                        do {
                            let detail = try await tmdbService.getSeasonDetails(
                                tvShowId: tmdbShowId,
                                seasonNumber: seasonNumber
                            )
                            return (seasonNumber, detail)
                        } catch {
                            Logger.shared.log(
                                "AniListService: Failed to fetch TMDB metadata for special season \(seasonNumber) on show \(tmdbShowId): \(error.localizedDescription)",
                                type: "AniList"
                            )
                            return (seasonNumber, nil)
                        }
                    }
                }

                for await (seasonNumber, detail) in group {
                    if let detail {
                        seasonDetailsByNumber[seasonNumber] = detail
                    }
                }
            }
        }

        let entries = uniqueMappings.compactMap { element -> AniListSpecialSearchEntry? in
            let anilistId = element.key
            let mapping = element.value
            let node = nodesById[anilistId]
            let title: String
            let englishTitle: String?
            let romajiTitle: String?
            let nativeTitle: String?
            if let node {
                title = AniListTitlePicker.englishPreferredTitle(from: node.title)
                englishTitle = node.title.english.map(AniListTitlePicker.cleanedTitle)
                romajiTitle = node.title.romaji.map(AniListTitlePicker.cleanedTitle)
                nativeTitle = node.title.native.map(AniListTitlePicker.cleanedTitle)
            } else {
                title = "Special \(anilistId)"
                englishTitle = nil
                romajiTitle = nil
                nativeTitle = nil
            }

            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanTitle.isEmpty else { return nil }

            let episodeCount = max(1, node?.episodes ?? 1)
            let mappedSeason = mapping.tmdbSeason
            let metadataSeason = mapping.tmdbSeason ?? mapping.tvdbSeason
            let episodeOffset = mapping.tvdbEpisodeOffset ?? 0
            let tmdbSeasonDetail = metadataSeason.flatMap { seasonDetailsByNumber[$0] }
            let episodes = (1...episodeCount).map { number in
                let mappedEpisodeNumber = mappedSeason.map { _ in episodeOffset + number }
                let metadataEpisodeNumber = metadataSeason.map { _ in episodeOffset + number }
                let tmdbEpisode = metadataEpisodeNumber.flatMap { episodeNumber in
                    tmdbSeasonDetail?.episodes.first(where: { $0.episodeNumber == episodeNumber })
                }

                return AniListEpisode(
                    number: number,
                    title: tmdbEpisode?.name ?? (episodeCount == 1 ? cleanTitle : "Episode \(number)"),
                    description: tmdbEpisode?.overview,
                    seasonNumber: mappedSeason ?? 0,
                    stillPath: tmdbEpisode?.stillPath,
                    airDate: tmdbEpisode?.airDate,
                    runtime: tmdbEpisode?.runtime,
                    tmdbSeasonNumber: mappedSeason,
                    tmdbEpisodeNumber: mappedEpisodeNumber
                )
            }

            return AniListSpecialSearchEntry(
                id: anilistId,
                title: cleanTitle,
                englishTitle: englishTitle,
                romajiTitle: romajiTitle,
                nativeTitle: nativeTitle,
                format: mapping.mediaType?.uppercased() ?? node?.format,
                episodeCount: episodeCount,
                posterUrl: node?.coverImage?.large
                    ?? node?.coverImage?.medium
                    ?? tmdbSeasonDetail?.fullPosterURL
                    ?? fallbackPosterURL,
                tmdbSeasonNumber: mapping.tmdbSeason,
                tvdbSeasonNumber: mapping.tvdbSeason,
                episodeOffset: mapping.tvdbEpisodeOffset,
                imdbId: mapping.imdbId,
                episodes: episodes
            )
        }

        return entries.sorted { lhs, rhs in
            if lhs.sortSeason != rhs.sortSeason {
                return lhs.sortSeason < rhs.sortSeason
            }
            if lhs.formatLabel != rhs.formatLabel {
                return lhs.formatLabel < rhs.formatLabel
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func pickBestAniListMatch(from candidates: [AniListAnime], tmdbShow: TMDBTVShowWithSeasons?) -> AniListAnime {
        // Hard selection rules (no weighted scoring):
        // 1) Prefer TV/TV_SHORT/OVA formats. If none, fall back to all candidates.
        // 2) If TMDB year is known, prefer exact year matches (user clicked on specific version).
        // 3) If TMDB episode count is known, pick the candidate with the smallest absolute diff.
        // 4) Tie-breakers: higher episode count first, then lower AniList ID for determinism.

        let allowedFormats: Set<String> = ["TV", "TV_SHORT", "OVA", "ONA"]
        let formatFiltered = candidates.filter { anime in
            guard let format = anime.format else { return false }
            return allowedFormats.contains(format)
        }

        let pool = formatFiltered.isEmpty ? candidates : formatFiltered

        guard let tmdbShow else {
            return pool.sorted(by: { lhs, rhs in
                let lhsEpisodes = lhs.episodes ?? 0
                let rhsEpisodes = rhs.episodes ?? 0
                if lhsEpisodes != rhsEpisodes { return lhsEpisodes > rhsEpisodes }
                return lhs.id < rhs.id
            }).first ?? candidates.first!
        }

        let tmdbYear = tmdbShow.firstAirDate.flatMap { dateStr in
            Int(String(dateStr.prefix(4)))
        }
        let tmdbEpisodes = tmdbShow.numberOfEpisodes

        // Prefer exact year match (user clicked on specific version)
        let yearFiltered: [AniListAnime]
        if let tmdbYear {
            let exactYear = pool.filter { $0.seasonYear == tmdbYear }
            yearFiltered = exactYear.isEmpty ? pool : exactYear
        } else {
            yearFiltered = pool
        }

        // If we know the TMDB episode count, pick the closest match; otherwise fall back to highest episodes.
        let chosen: AniListAnime?
        if let tmdbEpisodes {
            chosen = yearFiltered.min(by: { lhs, rhs in
                let lhsEpisodes = lhs.episodes ?? 0
                let rhsEpisodes = rhs.episodes ?? 0
                let lhsDiff = abs(lhsEpisodes - tmdbEpisodes)
                let rhsDiff = abs(rhsEpisodes - tmdbEpisodes)
                if lhsDiff != rhsDiff { return lhsDiff < rhsDiff }
                if lhsEpisodes != rhsEpisodes { return lhsEpisodes > rhsEpisodes }
                return lhs.id < rhs.id
            })
        } else {
            chosen = yearFiltered.sorted(by: { lhs, rhs in
                let lhsEpisodes = lhs.episodes ?? 0
                let rhsEpisodes = rhs.episodes ?? 0
                if lhsEpisodes != rhsEpisodes { return lhsEpisodes > rhsEpisodes }
                return lhs.id < rhs.id
            }).first
        }

        return chosen ?? candidates.first!
    }

    // MARK: - Update Watch Progress
    
    func updateAnimeProgress(
        mediaId: Int,
        episodeNumber: Int,
        token: String
    ) async throws {
        let mutation = """
        mutation {
            SaveMediaListEntry(mediaId: \(mediaId), progress: \(episodeNumber)) {
                id
                progress
            }
        }
        """
        
        _ = try await executeGraphQLQuery(mutation, token: token)
    }

    // MARK: - Catalog Mapping Helpers

    private func mapAniListCatalogToTMDB(_ animeList: [AniListAnime], tmdbService: TMDBService) async -> [TMDBSearchResult] {
        func normalized(_ value: String) -> String {
            return value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        }

        let langCode = self.preferredLanguageCode
        
        return await withTaskGroup(of: TMDBSearchResult?.self) { group in
            for anime in animeList {
                group.addTask {
                    let titleCandidates = AniListTitlePicker.titleCandidates(from: anime.title)
                    let expectedYear = anime.seasonYear

                    var bestMatch: TMDBTVShow?

                    for candidate in titleCandidates where !candidate.isEmpty {
                        guard let results = try? await tmdbService.searchTVShows(query: candidate), !results.isEmpty else { continue }
                        let candidateKey = normalized(candidate)

                        // Apply hierarchical filters instead of scoring
                        
                        // 1. Exact title match
                        let exactMatches = results.filter { normalized($0.name) == candidateKey }
                        if !exactMatches.isEmpty {
                            // Among exact matches, prefer by year then animation/poster
                            let bestExact = exactMatches.min { a, b in
                                let aYear = Int(a.firstAirDate?.prefix(4) ?? "")
                                let bYear = Int(b.firstAirDate?.prefix(4) ?? "")
                                
                                if let expectedYear = expectedYear {
                                    let aDiff = aYear.map { abs($0 - expectedYear) } ?? 10000
                                    let bDiff = bYear.map { abs($0 - expectedYear) } ?? 10000
                                    if aDiff != bDiff { return aDiff < bDiff }
                                }
                                
                                let aHasAnimation = a.genreIds?.contains(16) == true
                                let bHasAnimation = b.genreIds?.contains(16) == true
                                if aHasAnimation != bHasAnimation { return aHasAnimation }
                                
                                let aHasPoster = a.posterPath != nil
                                let bHasPoster = b.posterPath != nil
                                if aHasPoster != bHasPoster { return aHasPoster }
                                
                                return a.popularity > b.popularity
                            }
                            if let best = bestExact {
                                bestMatch = best
                                break
                            }
                        }
                        
                        // 2. Partial title match - prefer by year proximity if available, then animation/poster/popularity
                        let partialMatches = results.filter {
                            let nameKey = normalized($0.name)
                            return nameKey.contains(candidateKey) || candidateKey.contains(nameKey)
                        }
                        if !partialMatches.isEmpty {
                            let best = partialMatches.min { a, b in
                                // If we have year info, prioritize by year proximity
                                if let expectedYear = expectedYear {
                                    let aYear = Int(a.firstAirDate?.prefix(4) ?? "")
                                    let bYear = Int(b.firstAirDate?.prefix(4) ?? "")
                                    let aDiff = aYear.map { abs($0 - expectedYear) } ?? 10000
                                    let bDiff = bYear.map { abs($0 - expectedYear) } ?? 10000
                                    if aDiff != bDiff { return aDiff < bDiff }
                                }
                                
                                // Then animation genre
                                let aHasAnimation = a.genreIds?.contains(16) == true
                                let bHasAnimation = b.genreIds?.contains(16) == true
                                if aHasAnimation != bHasAnimation { return aHasAnimation }
                                
                                // Then poster
                                let aHasPoster = a.posterPath != nil
                                let bHasPoster = b.posterPath != nil
                                if aHasPoster != bHasPoster { return aHasPoster }
                                
                                // Finally popularity
                                return a.popularity > b.popularity
                            }
                            if let best = best {
                                bestMatch = best
                                break
                            }
                        }
                        
                        // 3. Last resort: any result (prefer animation, poster, popularity)
                        if bestMatch == nil {
                            let best = results.min { a, b in
                                let aHasAnimation = a.genreIds?.contains(16) == true
                                let bHasAnimation = b.genreIds?.contains(16) == true
                                if aHasAnimation != bHasAnimation { return aHasAnimation }
                                
                                let aHasPoster = a.posterPath != nil
                                let bHasPoster = b.posterPath != nil
                                if aHasPoster != bHasPoster { return aHasPoster }
                                
                                return a.popularity > b.popularity
                            }
                            bestMatch = best
                        }
                    }

                    if let bestMatch = bestMatch {
                        let aniTitle = AniListTitlePicker.title(from: anime.title, preferredLanguageCode: langCode)
                        Logger.shared.log("AniListService: Matched '\(aniTitle)' â†’ TMDB '\(bestMatch.name)' (ID: \(bestMatch.id))", type: "AniList")
                    }
                    return bestMatch?.asSearchResult
                }
            }

            var results: [TMDBSearchResult] = []
            var seenIds = Set<Int>()
            for await match in group {
                if let match = match, !seenIds.contains(match.id) {
                    seenIds.insert(match.id)
                    results.append(match)
                }
            }
            return results
        }
    }

    /// Batch map AniList anime to TMDB, returning a dict keyed by AniList ID for fast lookup.
    private func batchMapAniListToTMDB(_ animeList: [AniListAnime], tmdbService: TMDBService) async -> [Int: TMDBSearchResult] {
        func normalized(_ value: String) -> String {
            return value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        }

        let langCode = self.preferredLanguageCode

        return await withTaskGroup(of: (Int, TMDBSearchResult?).self) { group in
            for anime in animeList {
                group.addTask {
                    let titleCandidates = AniListTitlePicker.titleCandidates(from: anime.title)
                    let expectedYear = anime.seasonYear
                    var bestMatch: TMDBTVShow?

                    for candidate in titleCandidates where !candidate.isEmpty {
                        guard let results = try? await tmdbService.searchTVShows(query: candidate), !results.isEmpty else { continue }
                        let candidateKey = normalized(candidate)

                        let exactMatches = results.filter { normalized($0.name) == candidateKey }
                        if !exactMatches.isEmpty {
                            let bestExact = exactMatches.min { a, b in
                                if let expectedYear = expectedYear {
                                    let aDiff = Int(a.firstAirDate?.prefix(4) ?? "").map { abs($0 - expectedYear) } ?? 10000
                                    let bDiff = Int(b.firstAirDate?.prefix(4) ?? "").map { abs($0 - expectedYear) } ?? 10000
                                    if aDiff != bDiff { return aDiff < bDiff }
                                }
                                let aAnim = a.genreIds?.contains(16) == true
                                let bAnim = b.genreIds?.contains(16) == true
                                if aAnim != bAnim { return aAnim }
                                return a.popularity > b.popularity
                            }
                            if let best = bestExact { bestMatch = best; break }
                        }

                        let partialMatches = results.filter {
                            let nameKey = normalized($0.name)
                            return nameKey.contains(candidateKey) || candidateKey.contains(nameKey)
                        }
                        if !partialMatches.isEmpty {
                            let best = partialMatches.min { a, b in
                                if let expectedYear = expectedYear {
                                    let aDiff = Int(a.firstAirDate?.prefix(4) ?? "").map { abs($0 - expectedYear) } ?? 10000
                                    let bDiff = Int(b.firstAirDate?.prefix(4) ?? "").map { abs($0 - expectedYear) } ?? 10000
                                    if aDiff != bDiff { return aDiff < bDiff }
                                }
                                let aAnim = a.genreIds?.contains(16) == true
                                let bAnim = b.genreIds?.contains(16) == true
                                if aAnim != bAnim { return aAnim }
                                return a.popularity > b.popularity
                            }
                            if let best = best { bestMatch = best; break }
                        }

                        if bestMatch == nil {
                            bestMatch = results.min { a, b in
                                let aAnim = a.genreIds?.contains(16) == true
                                let bAnim = b.genreIds?.contains(16) == true
                                if aAnim != bAnim { return aAnim }
                                return a.popularity > b.popularity
                            }
                        }
                    }

                    if let bestMatch = bestMatch {
                        let aniTitle = AniListTitlePicker.title(from: anime.title, preferredLanguageCode: langCode)
                        Logger.shared.log("AniListService: Matched '\(aniTitle)' → TMDB '\(bestMatch.name)' (ID: \(bestMatch.id))", type: "AniList")
                    }
                    return (anime.id, bestMatch?.asSearchResult)
                }
            }

            var dict: [Int: TMDBSearchResult] = [:]
            for await (anilistId, match) in group {
                if let match = match {
                    dict[anilistId] = match
                }
            }
            return dict
        }
    }

    // MARK: - MAL ID to AniList ID Conversion
    
    /// Convert MyAnimeList ID to AniList ID for tracking purposes
    func getAniListId(fromMalId malId: Int) async throws -> Int? {
        let query = """
        query {
            Media(idMal: \(malId), type: ANIME) {
                id
            }
        }
        """
        
        struct Response: Codable {
            let data: DataWrapper?
            struct DataWrapper: Codable {
                let Media: MediaData?
                struct MediaData: Codable {
                    let id: Int
                }
            }
        }
        
        do {
            let data = try await executeGraphQLQuery(query, token: nil)
            let result = try JSONDecoder().decode(Response.self, from: data)
            return result.data?.Media?.id
        } catch {
            Logger.shared.log("AniListService: Failed to convert MAL ID \(malId) to AniList ID: \(error.localizedDescription)", type: "AniList")
            return nil
        }
    }
    
    // MARK: - Parent Relation Lookup
    
    /// Walk up the AniList relation chain (PREQUEL, PARENT, SOURCE) to find ancestor anime.
    /// Returns title candidates for each ancestor, ordered from closest to furthest parent.
    /// Used as a fallback when a sequel/season doesn't have its own TMDB entry.
    func fetchParentTitleCandidates(forMediaId mediaId: Int, maxDepth: Int = 3) async -> [(englishTitle: String?, romajiTitle: String?, nativeTitle: String?)] {
        var visited = Set<Int>([mediaId])
        var currentId = mediaId
        var results: [(englishTitle: String?, romajiTitle: String?, nativeTitle: String?)] = []
        
        for _ in 0..<maxDepth {
            let query = """
            query {
                Media(id: \(currentId), type: ANIME) {
                    relations {
                        edges {
                            relationType
                            node {
                                id
                                title { romaji english native }
                                format
                                type
                            }
                        }
                    }
                }
            }
            """
            
            struct Response: Codable {
                let data: DataWrapper?
                struct DataWrapper: Codable {
                    let Media: MediaData?
                }
                struct MediaData: Codable {
                    let relations: Relations?
                }
                struct Relations: Codable {
                    let edges: [Edge]
                }
                struct Edge: Codable {
                    let relationType: String
                    let node: Node
                }
                struct Node: Codable {
                    let id: Int
                    let title: TitleData
                    let format: String?
                    let type: String?
                }
                struct TitleData: Codable {
                    let romaji: String?
                    let english: String?
                    let native: String?
                }
            }
            
            guard let data = try? await executeGraphQLQuery(query, token: nil),
                  let decoded = try? JSONDecoder().decode(Response.self, from: data),
                  let edges = decoded.data?.Media?.relations?.edges else {
                break
            }
            
            let parentRelTypes: Set<String> = ["PREQUEL", "PARENT", "SOURCE"]
            let tvFormats: Set<String> = ["TV", "TV_SHORT", "ONA"]
            
            // Find the best parent: prefer TV formats, then any anime relation
            let parentEdge = edges
                .filter { parentRelTypes.contains($0.relationType) && $0.node.type == "ANIME" && !visited.contains($0.node.id) }
                .sorted { a, b in
                    let aIsTV = tvFormats.contains(a.node.format ?? "")
                    let bIsTV = tvFormats.contains(b.node.format ?? "")
                    if aIsTV != bIsTV { return aIsTV }
                    // Prefer PREQUEL over PARENT over SOURCE
                    let order = ["PREQUEL": 0, "PARENT": 1, "SOURCE": 2]
                    return (order[a.relationType] ?? 3) < (order[b.relationType] ?? 3)
                }
                .first
            
            guard let parent = parentEdge else { break }
            
            visited.insert(parent.node.id)
            results.append((
                englishTitle: parent.node.title.english,
                romajiTitle: parent.node.title.romaji,
                nativeTitle: parent.node.title.native
            ))
            currentId = parent.node.id
        }
        
        return results
    }

    // MARK: - User List Import

    /// An imported entry carrying both the TMDB result and the user's AniList progress.
    struct AniListImportEntry {
        let tmdbResult: TMDBSearchResult
        /// Number of episodes the user has watched on AniList.
        let episodesWatched: Int
    }

    /// Represents a categorized set of AniList user anime lists mapped to TMDB results.
    struct AniListUserListImport {
        var watching: [AniListImportEntry] = []
        var planning: [AniListImportEntry] = []
        var completed: [AniListImportEntry] = []
        var paused: [AniListImportEntry] = []
        var dropped: [AniListImportEntry] = []
        var repeating: [AniListImportEntry] = []
    }

    /// A raw list entry carrying both the anime metadata and user's watch progress.
    private struct AniListListEntry {
        let anime: AniListAnime
        let progress: Int
    }

    /// Fetch the authenticated user's anime lists and map each entry to a TMDBSearchResult using the standard matching system.
    func fetchUserAnimeListsForImport(
        token: String,
        userId: Int,
        tmdbService: TMDBService
    ) async throws -> AniListUserListImport {
        // AniList caps perPage at 50 so we paginate per status
        @Sendable func fetchList(status: String, token: String) async throws -> [AniListListEntry] {
            var entries: [AniListListEntry] = []
            var page = 1
            var hasNext = true

            while hasNext {
                let query = """
                query {
                    Page(page: \(page), perPage: 50) {
                        pageInfo { hasNextPage }
                        mediaList(userId: \(userId), type: ANIME, status: \(status)) {
                            progress
                            media {
                                id
                                idMal
                                title { romaji english native }
                                episodes
                                status
                                seasonYear
                                season
                                coverImage { large medium }
                                format
                            }
                        }
                    }
                }
                """

                struct Response: Codable {
                    let data: DataWrapper
                    struct DataWrapper: Codable { let Page: PageData }
                    struct PageData: Codable {
                        let pageInfo: PageInfo
                        let mediaList: [MediaListEntry]
                    }
                    struct PageInfo: Codable { let hasNextPage: Bool }
                    struct MediaListEntry: Codable {
                        let progress: Int?
                        let media: AniListAnime
                    }
                }

                let data = try await executeGraphQLQuery(query, token: token)
                let decoded = try JSONDecoder().decode(Response.self, from: data)
                entries.append(contentsOf: decoded.data.Page.mediaList.map {
                    AniListListEntry(anime: $0.media, progress: $0.progress ?? 0)
                })
                hasNext = decoded.data.Page.pageInfo.hasNextPage
                page += 1
            }

            return entries
        }

        Logger.shared.log("AniListService: Fetching user anime lists for import (userId: \(userId))", type: "AniList")

        // Fetch all six AniList statuses concurrently
        async let watchingEntries = fetchList(status: "CURRENT", token: token)
        async let planningEntries = fetchList(status: "PLANNING", token: token)
        async let completedEntries = fetchList(status: "COMPLETED", token: token)
        async let pausedEntries = fetchList(status: "PAUSED", token: token)
        async let droppedEntries = fetchList(status: "DROPPED", token: token)
        async let repeatingEntries = fetchList(status: "REPEATING", token: token)

        let watching = try await watchingEntries
        let planning = try await planningEntries
        let completed = try await completedEntries
        let paused = try await pausedEntries
        let dropped = try await droppedEntries
        let repeating = try await repeatingEntries

        Logger.shared.log("AniListService: User lists - Watching: \(watching.count), Planning: \(planning.count), Completed: \(completed.count), Paused: \(paused.count), Dropped: \(dropped.count), Repeating: \(repeating.count)", type: "AniList")

        // Dedupe all anime across all lists and batch-map to TMDB
        let allLists = watching + planning + completed + paused + dropped + repeating
        var allAnime: [AniListAnime] = []
        var seenIds = Set<Int>()
        for entry in allLists {
            if seenIds.insert(entry.anime.id).inserted {
                allAnime.append(entry.anime)
            }
        }

        let tmdbMap = await batchMapAniListToTMDB(allAnime, tmdbService: tmdbService)

        // Build progress lookup: anilistId -> episodes watched
        var progressMap: [Int: Int] = [:]
        for entry in allLists {
            progressMap[entry.anime.id] = entry.progress
        }

        // Helper to convert list entries to import entries
        func toImportEntries(_ list: [AniListListEntry]) -> [AniListImportEntry] {
            list.compactMap { entry in
                guard let tmdb = tmdbMap[entry.anime.id] else { return nil }
                return AniListImportEntry(tmdbResult: tmdb, episodesWatched: entry.progress)
            }
        }

        var result = AniListUserListImport()
        result.watching = toImportEntries(watching)
        result.planning = toImportEntries(planning)
        result.completed = toImportEntries(completed)
        result.paused = toImportEntries(paused)
        result.dropped = toImportEntries(dropped)
        result.repeating = toImportEntries(repeating)

        let totalFetched = allLists.count
        let totalMapped = result.watching.count + result.planning.count + result.completed.count + result.paused.count + result.dropped.count + result.repeating.count
        let unmapped = totalFetched - totalMapped
        Logger.shared.log("AniListService: Mapped \(totalMapped)/\(totalFetched) to TMDB (\(unmapped) unmapped) - Watching: \(result.watching.count), Planning: \(result.planning.count), Completed: \(result.completed.count), Paused: \(result.paused.count), Dropped: \(result.dropped.count), Repeating: \(result.repeating.count)", type: "AniList")

        return result
    }

    /// Exposes the existing AniList -> TMDB import mapper for tracker sync tools.
    func mapAniListAnimeIdsToTMDBForImport(
        _ ids: [Int],
        tmdbService: TMDBService
    ) async -> [Int: TMDBSearchResult] {
        let uniqueIds = Array(Set(ids))
        guard !uniqueIds.isEmpty else { return [:] }

        let nodes = await batchFetchAniListNodes(ids: uniqueIds)
        return await batchMapAniListToTMDB(Array(nodes.values), tmdbService: tmdbService)
    }

    // MARK: - Private Helpers
    
    private func executeGraphQLQuery(_ query: String, token: String?, maxRetries: Int = 3) async throws -> Data {
        // Throttle all AniList requests to stay under rate limit
        await AniListRateLimiter.shared.waitForSlot()
        
        var request = URLRequest(url: graphQLEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        
        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let body: [String: Any] = ["query": query]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        var lastError: Error?
        for attempt in 0..<maxRetries {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                await AniListRateLimiter.shared.recordResponse(httpResponse)

                if httpResponse.statusCode == 200 {
                    return data
                }
                
                // Rate limited — wait and retry
                if httpResponse.statusCode == 429 {
                    let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                        .flatMap(Double.init) ?? Double(2 * (attempt + 1))
                    let delay = min(retryAfter, 10)
                    Logger.shared.log("AniList rate limited (429), retry \(attempt + 1)/\(maxRetries) after \(delay)s", type: "AniList")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    lastError = NSError(domain: "AniList", code: 429, userInfo: [NSLocalizedDescriptionKey: "AniList rate limited (HTTP 429)"])
                    continue
                }
                
                let error = "AniList error (HTTP \(httpResponse.statusCode))"
                Logger.shared.log("AniListService: GraphQL request failed with HTTP \(httpResponse.statusCode)", type: "Error")
                throw NSError(domain: "AniList", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: error])
            }
            
            throw NSError(domain: "AniList", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch from AniList"])
        }
        
        throw lastError ?? NSError(domain: "AniList", code: 429, userInfo: [NSLocalizedDescriptionKey: "AniList rate limited after \(maxRetries) retries"])
    }

    /// Batch-fetch multiple anime nodes with relations in a single aliased GraphQL query
    private func batchFetchAniListNodes(ids: [Int]) async -> [Int: AniListAnime] {
        guard !ids.isEmpty else { return [:] }

        let fragment = """
            id
            idMal
            title { romaji english native }
            episodes
            status
            seasonYear
            season
            format
            type
            coverImage { large medium }
            relations {
                edges {
                    relationType
                    node {
                        id
                        title { romaji english native }
                        episodes
                        status
                        seasonYear
                        season
                        format
                        type
                        coverImage { large medium }
                        relations {
                            edges {
                                relationType
                                node {
                                    id
                                    title { romaji english native }
                                    episodes
                                    status
                                    seasonYear
                                    season
                                    format
                                    type
                                    coverImage { large medium }
                                }
                            }
                        }
                    }
                }
            }
        """

        let aliases = ids.enumerated().map { i, id in
            "m\(i): Media(id: \(id), type: ANIME) { \(fragment) }"
        }.joined(separator: "\n")

        let query = "query { \(aliases) }"

        do {
            let data = try await executeGraphQLQuery(query, token: nil)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let dataDict = json?["data"] as? [String: Any] else { return [:] }

            var result: [Int: AniListAnime] = [:]
            for (i, id) in ids.enumerated() {
                let key = "m\(i)"
                if let mediaJSON = dataDict[key],
                   let mediaData = try? JSONSerialization.data(withJSONObject: mediaJSON),
                   let anime = try? JSONDecoder().decode(AniListAnime.self, from: mediaData) {
                    result[id] = anime
                }
            }
            return result
        } catch {
            Logger.shared.log("AniListService: Batch fetch failed for \(ids.count) nodes: \(error.localizedDescription)", type: "AniList")
            return [:]
        }
    }

    /// Fetch a single anime node with relations for deeper traversal
    private func fetchAniListAnimeNode(id: Int) async throws -> AniListAnime {
        let query = """
        query {
            Media(id: \(id), type: ANIME) {
                id
                title { romaji english native }
                episodes
                status
                seasonYear
                season
                format
                type
                coverImage { large medium }
                relations {
                    edges {
                        relationType
                        node {
                            id
                            title { romaji english native }
                            episodes
                            status
                            seasonYear
                            season
                            format
                            type
                            coverImage { large medium }
                        }
                    }
                }
            }
        }
        """

        struct Response: Codable {
            let data: DataWrapper
            struct DataWrapper: Codable {
                let Media: AniListAnime
            }
        }

        let data = try await executeGraphQLQuery(query, token: nil)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.data.Media
    }

}

// MARK: - Helper Models

protocol AniListEpisodeProtocol {
    var number: Int { get }
    var title: String { get }
    var description: String? { get }
    var seasonNumber: Int { get }
}

struct AniListEpisode: AniListEpisodeProtocol {
    let number: Int                // AniList local episode number (1-12 per season) - used for search
    let title: String
    let description: String?
    let seasonNumber: Int          // AniList season number - used for search
    let stillPath: String?         // From TMDB for metadata
    let airDate: String?
    let runtime: Int?
    let tmdbSeasonNumber: Int?     // Original TMDB season number (before AniList restructuring)
    let tmdbEpisodeNumber: Int?    // Original TMDB episode number (before AniList restructuring)
}

struct AniListAiringScheduleEntry: Identifiable {
    let id: Int
    let mediaId: Int
    let title: String
    let airingAt: Date
    let episode: Int
    let coverImage: String?
    let englishTitle: String?
    let romajiTitle: String?
    let nativeTitle: String?
    let format: String?
}

struct AniListSeasonWithPoster {
    let seasonNumber: Int
    let anilistId: Int             // AniList anime ID for this specific season
    let title: String              // Full AniList title for this season (e.g., "SPYÃ—FAMILY Season 2")
    let episodes: [AniListEpisode]
    let posterUrl: String?
}

struct AniListSpecialSearchEntry: Identifiable {
    let id: Int
    let title: String
    let englishTitle: String?
    let romajiTitle: String?
    let nativeTitle: String?
    let format: String?
    let episodeCount: Int
    let posterUrl: String?
    let tmdbSeasonNumber: Int?
    let tvdbSeasonNumber: Int?
    let episodeOffset: Int?
    let imdbId: String?
    let episodes: [AniListEpisode]

    var formatLabel: String {
        let raw = format?.replacingOccurrences(of: "_", with: " ") ?? "Special"
        return raw.capitalized
    }

    var displaySeasonNumber: Int {
        tmdbSeasonNumber ?? tvdbSeasonNumber ?? 0
    }

    var sortSeason: Int {
        displaySeasonNumber
    }

    var titleCandidates: [String] {
        var seen = Set<String>()
        let ordered = [title, englishTitle, romajiTitle, nativeTitle].compactMap { raw in
            raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return ordered.compactMap { value in
            guard !value.isEmpty else { return nil }
            let key = value.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return value
        }
    }

    var preferredTitle: String {
        titleCandidates.first(where: { !Self.isGenericSpecialTitle($0) }) ?? titleCandidates.first ?? title
    }

    var alternateSearchTitle: String? {
        let primary = preferredTitle
        return titleCandidates.first {
            $0.caseInsensitiveCompare(primary) != .orderedSame && !Self.isGenericSpecialTitle($0)
        } ?? titleCandidates.first {
            $0.caseInsensitiveCompare(primary) != .orderedSame
        }
    }

    private static func isGenericSpecialTitle(_ title: String) -> Bool {
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalized.isEmpty else { return true }

        if ["special", "specials", "ova", "oad", "ona"].contains(normalized) {
            return true
        }

        let genericPatterns = [
            #"^special\s+\d+$"#,
            #"^ova\s+\d+$"#,
            #"^oad\s+\d+$"#,
            #"^ona\s+\d+$"#,
            #"^episode\s*\d+$"#
        ]

        return genericPatterns.contains {
            normalized.range(of: $0, options: .regularExpression) != nil
        }
    }
}

struct AniListAnimeWithSeasons {
    let id: Int
    let title: String
    let seasons: [AniListSeasonWithPoster]
    let totalEpisodes: Int
    let status: String
}

// MARK: - AniList Codable Models

struct AniListAnime: Codable {
    let id: Int
    let idMal: Int?
    let title: AniListTitle
    let episodes: Int?
    let status: String?
    let seasonYear: Int?
    let season: String?
    let coverImage: AniListCoverImage?
    let format: String?
    let type: String?
    let nextAiringEpisode: AniListNextAiringEpisode?
    let relations: AniListRelations?

    struct AniListTitle: Codable {
        let romaji: String?
        let english: String?
        let native: String?
    }

    struct AniListCoverImage: Codable {
        let large: String?
        let medium: String?
    }

    struct AniListNextAiringEpisode: Codable {
        let episode: Int?
        let airingAt: Int?
    }

    struct AniListRelations: Codable {
        let edges: [AniListRelationEdge]
    }

    struct AniListRelationEdge: Codable {
        let relationType: String
        let node: AniListRelationNode
    }

    struct AniListRelationNode: Codable {
        let id: Int
        let title: AniListTitle
        let episodes: Int?
        let status: String?
        let seasonYear: Int?
        let season: String?
        let format: String?
        let type: String?
        let coverImage: AniListCoverImage?
        let relations: AniListRelations?

        func asAnime() -> AniListAnime {
            return AniListAnime(
                id: id,
                idMal: nil,
                title: title,
                episodes: episodes,
                status: status,
                seasonYear: seasonYear,
                season: season,
                coverImage: coverImage,
                format: format,
                type: type,
                nextAiringEpisode: nil,
                relations: relations
            )
        }
    }
}

enum AniListTitlePicker {
    private static func cleanTitle(_ title: String) -> String {
        let cleaned = title
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? title : cleaned
    }

    static func cleanedTitle(_ title: String) -> String {
        cleanTitle(title)
    }

    static func englishPreferredTitle(from title: AniListAnime.AniListTitle) -> String {
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
    
    static func title(from title: AniListAnime.AniListTitle, preferredLanguageCode: String) -> String {
        let lang = preferredLanguageCode.lowercased()

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

    static func titleCandidates(from title: AniListAnime.AniListTitle) -> [String] {
        var seen = Set<String>()
        let ordered = [title.english, title.romaji, title.native].compactMap { $0 }
        return ordered.compactMap { value in
            let cleaned = value
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .trimmingCharacters(in: .whitespaces)
            let finalValue = cleaned.isEmpty ? value : cleaned
            
            if seen.contains(finalValue) { return nil }
            seen.insert(finalValue)
            return finalValue
        }
    }
}
