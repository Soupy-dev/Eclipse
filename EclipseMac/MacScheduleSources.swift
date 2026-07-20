import Foundation

actor MacWesternScheduleService {
    static let shared = MacWesternScheduleService()

    private let traktBaseURL = URL(string: "https://api.trakt.tv")!
    private let tvMazeBaseURL = URL(string: "https://api.tvmaze.com")!
    private var extendedTVMazeCache: (fetchedAt: Date, entries: [MacScheduleEntry])?

    private init() {}

    func fetchSchedule(dayCount: Int) async throws -> [MacScheduleEntry] {
        do {
            return try await fetchTraktSchedule(dayCount: dayCount)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try await fetchTVMazeSchedule(dayCount: dayCount)
        }
    }

    private func fetchTraktSchedule(dayCount: Int) async throws -> [MacScheduleEntry] {
        let rawClientID = Bundle.main.object(forInfoDictionaryKey: "TraktClientID") as? String ?? ""
        let clientID = rawClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !clientID.contains("$(") else {
            throw MacScheduleSourceError.missingTraktClientID
        }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let startDate = formatter.string(from: start)

        var components = URLComponents(
            url: traktBaseURL.appendingPathComponent("calendars/all/shows/\(startDate)/\(max(dayCount, 1))"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "extended", value: "full"),
            URLQueryItem(name: "languages", value: "en")
        ]
        guard let url = components?.url else { throw MacScheduleSourceError.invalidURL }

        var request = URLRequest(url: url, timeoutInterval: 25)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        let data = try await responseData(for: request, expectedHost: "api.trakt.tv", maximumBytes: 12_000_000)
        let items = try JSONDecoder().decode([MacTraktCalendarItem].self, from: data)

        var seenEpisodeIDs = Set<String>()
        let candidates = items.compactMap { item -> (item: MacTraktCalendarItem, airingAt: Date, key: String)? in
            guard item.show.isWesternScheduleCandidate,
                  let airingAt = Self.isoDate(item.firstAired) else { return nil }
            let episodeKey = item.episode.ids?.trakt.map { "trakt-\($0)" }
                ?? item.episode.ids?.tmdb.map { "tmdb-\($0)" }
                ?? "\(item.showKey)-\(item.episode.season ?? 0)-\(item.episode.number ?? 0)-\(item.firstAired)"
            guard seenEpisodeIDs.insert(episodeKey).inserted else { return nil }
            return (item, airingAt, item.showKey)
        }

        let dailyShowKeys = Set(
            Dictionary(grouping: candidates, by: { $0.key })
                .compactMap { Self.hasDailyScheduleDensity($0.value.map { $0.airingAt }) ? $0.key : nil }
        )

        let entries = candidates
            .filter { !dailyShowKeys.contains($0.key) }
            .map { value in
                let item = value.item
                let tmdbID = item.show.ids.tmdb
                let providerID = item.show.ids.trakt ?? tmdbID ?? 0
                let showID = tmdbID ?? -max(providerID, 1)
                let show = MacMediaItem(
                    id: showID,
                    mediaType: tmdbID == nil ? "trakt" : "tv",
                    title: item.show.title,
                    overview: item.show.overview ?? "",
                    posterPath: nil,
                    backdropPath: nil,
                    date: item.show.year.map(String.init),
                    rating: item.show.rating ?? 0
                )
                let season = item.episode.season ?? 0
                let episode = item.episode.number ?? 0
                let stableEpisodeID = item.episode.ids?.trakt
                    ?? item.episode.ids?.tmdb
                    ?? Self.syntheticEpisodeID(providerID: providerID, season: season, episode: episode)
                let network = item.show.network?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return MacScheduleEntry(
                    show: show,
                    episodeID: stableEpisodeID,
                    episodeTitle: item.episode.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    seasonNumber: season,
                    episodeNumber: episode,
                    airDate: value.airingAt,
                    seriesStatus: network.isEmpty ? "Trakt" : "Trakt · \(network)",
                    classification: .western,
                    source: .trakt,
                    hasKnownAiringTime: true
                )
            }
            .sorted { $0.airDate < $1.airDate }
        return Self.entries(entries, within: dayCount)
    }

    private func fetchTVMazeSchedule(dayCount: Int) async throws -> [MacScheduleEntry] {
        if dayCount > 7 {
            return try await fetchExtendedTVMazeSchedule(dayCount: dayCount)
        }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let regionCode = Locale.current.region?.identifier.uppercased() ?? "US"
        var episodesByID: [Int: MacTVMazeEpisode] = [:]

        for offset in 0..<max(dayCount, 1) {
            try Task.checkCancellation()
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            let dateString = formatter.string(from: date)
            let broadcast = try await fetchTVMazeEpisodes(
                path: "schedule",
                queryItems: [
                    URLQueryItem(name: "country", value: regionCode),
                    URLQueryItem(name: "date", value: dateString)
                ]
            )
            for episode in broadcast where episode.show.isWesternScheduleCandidate {
                episodesByID[episode.id] = episode
            }

            if let streaming = try? await fetchTVMazeEpisodes(
                path: "schedule/web",
                queryItems: [
                    URLQueryItem(name: "country", value: ""),
                    URLQueryItem(name: "date", value: dateString)
                ]
            ) {
                for episode in streaming where episode.show.isWesternScheduleCandidate && episode.show.isEnglishLanguage {
                    episodesByID[episode.id] = episode
                }
            }
        }
        return Self.entries(Self.tvMazeEntries(from: episodesByID), within: dayCount)
    }

    private func fetchExtendedTVMazeSchedule(dayCount: Int) async throws -> [MacScheduleEntry] {
        if let cache = extendedTVMazeCache,
           Calendar.current.isDate(cache.fetchedAt, inSameDayAs: Date()),
           Date().timeIntervalSince(cache.fetchedAt) < 6 * 60 * 60 {
            return Self.entries(cache.entries, within: dayCount)
        }

        let episodes = try await fetchTVMazeEpisodes(path: "schedule/full", queryItems: [])
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 30, to: start) ?? .distantFuture
        let regionCode = Locale.current.region?.identifier.uppercased() ?? "US"
        var episodesByID: [Int: MacTVMazeEpisode] = [:]
        for episode in episodes {
            guard episode.show.isWesternScheduleCandidate,
                  episode.show.isIncludedInFullSchedule(regionCode: regionCode),
                  let airing = episode.airing,
                  airing.date >= start,
                  airing.date < end else { continue }
            episodesByID[episode.id] = episode
        }
        let entries = Self.tvMazeEntries(from: episodesByID).sorted { $0.airDate < $1.airDate }
        extendedTVMazeCache = (Date(), entries)
        return Self.entries(entries, within: dayCount)
    }

    private func fetchTVMazeEpisodes(
        path: String,
        queryItems: [URLQueryItem],
        retryAfterRateLimit: Bool = true
    ) async throws -> [MacTVMazeEpisode] {
        var components = URLComponents(url: tvMazeBaseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        guard let url = components?.url else { throw MacScheduleSourceError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Eclipse macOS", forHTTPHeaderField: "User-Agent")

        do {
            let data = try await responseData(for: request, expectedHost: "api.tvmaze.com", maximumBytes: 32_000_000)
            return try JSONDecoder().decode([MacTVMazeEpisode].self, from: data)
        } catch MacScheduleSourceError.httpStatus(429) where retryAfterRateLimit {
            try await Task.sleep(for: .seconds(2))
            return try await fetchTVMazeEpisodes(path: path, queryItems: queryItems, retryAfterRateLimit: false)
        }
    }

    private func responseData(for request: URLRequest, expectedHost: String, maximumBytes: Int) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MacScheduleSourceError.invalidResponse }
        guard http.url?.scheme?.lowercased() == "https", http.url?.host?.lowercased() == expectedHost else {
            throw MacScheduleSourceError.invalidURL
        }
        guard 200..<300 ~= http.statusCode else { throw MacScheduleSourceError.httpStatus(http.statusCode) }
        guard data.count <= maximumBytes else { throw MacScheduleSourceError.responseTooLarge }
        return data
    }

    private static func tvMazeEntries(from episodesByID: [Int: MacTVMazeEpisode]) -> [MacScheduleEntry] {
        let dailyShowIDs = Set(
            Dictionary(grouping: episodesByID.values, by: { $0.show.id })
                .compactMap { hasDailyScheduleDensity($0.value.compactMap { $0.airing?.date }) ? $0.key : nil }
        )
        return episodesByID.values.compactMap { episode in
            guard !dailyShowIDs.contains(episode.show.id), let airing = episode.airing else { return nil }
            let show = MacMediaItem(
                id: -max(episode.show.id, 1),
                mediaType: "tvmaze",
                title: episode.show.name,
                overview: episode.show.summary?.strippingHTML ?? "",
                posterPath: episode.show.image?.medium ?? episode.show.image?.original,
                backdropPath: nil,
                date: episode.show.premiered,
                rating: episode.show.rating?.average ?? 0
            )
            let channel = episode.show.webChannel?.name ?? episode.show.network?.name
            return MacScheduleEntry(
                show: show,
                episodeID: episode.id,
                episodeTitle: episode.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                seasonNumber: episode.season,
                episodeNumber: episode.number ?? 0,
                airDate: airing.date,
                seriesStatus: channel.map { "TVMaze · \($0)" } ?? "TVMaze",
                classification: .western,
                source: .tvMaze,
                hasKnownAiringTime: airing.hasKnownAiringTime
            )
        }
    }

    private static func entries(_ entries: [MacScheduleEntry], within dayCount: Int) -> [MacScheduleEntry] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: max(dayCount, 1), to: start) ?? .distantFuture
        return entries.filter { $0.airDate >= start && $0.airDate < end }
    }

    private static func isoDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func hasDailyScheduleDensity(_ dates: [Date]) -> Bool {
        guard dates.count >= 4 else { return false }
        let days = dates.map { Calendar.current.startOfDay(for: $0) }.sorted()
        for lowerBound in days.indices {
            var upperBound = lowerBound
            while upperBound + 1 < days.count,
                  Calendar.current.dateComponents([.day], from: days[lowerBound], to: days[upperBound + 1]).day ?? 99 <= 6 {
                upperBound += 1
            }
            if upperBound - lowerBound + 1 >= 4 { return true }
        }
        return false
    }

    private static func syntheticEpisodeID(providerID: Int, season: Int, episode: Int) -> Int {
        let value = (abs(providerID) &* 1_000_003) &+ (max(season, 0) &* 1_009) &+ max(episode, 0)
        return max(1, value & Int.max)
    }
}

actor MacMALCatalogService {
    static let shared = MacMALCatalogService()

    private let apiBase = URL(string: "https://api.myanimelist.net/v2")!
    private let detailFields = [
        "id", "title", "main_picture", "alternative_titles", "start_date", "mean",
        "media_type", "status", "num_episodes", "start_season", "broadcast", "rating", "genres"
    ].joined(separator: ",")
    private var tmdbCache: [Int: (expiresAt: Date, item: MacMediaItem?)] = [:]

    private init() {}

    func fetchAiringSchedule(dayCount: Int, perPage: Int = 50) async throws -> [MacScheduleEntry] {
        let boundedPageSize = min(max(perPage, 1), 100)
        let current = season(for: Date())
        let following = nextSeason(after: current)
        let currentAnime = try await fetchSeasonAnime(
            year: current.year,
            season: current.name,
            limit: boundedPageSize
        )
        let nextAnime = (try? await fetchSeasonAnime(
            year: following.year,
            season: following.name,
            limit: boundedPageSize
        )) ?? []
        let anime = Array((currentAnime + nextAnime)
            .filter { !$0.isAdult }
            .prefix(boundedPageSize * 2))

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: max(dayCount, 1), to: start) ?? start

        return anime.compactMap { detail -> MacScheduleEntry? in
            guard let airDate = estimatedNextAiringDate(for: detail, start: start, end: end) else {
                return nil
            }
            let episode = estimatedNextEpisode(for: detail, airingAt: airDate)
            let show = MacMediaItem(
                id: -max(abs(detail.id), 1),
                mediaType: "mal",
                title: detail.displayTitle,
                overview: "",
                posterPath: detail.mainPicture?.large ?? detail.mainPicture?.medium,
                backdropPath: nil,
                date: detail.startDate,
                rating: detail.mean ?? 0
            )
            return MacScheduleEntry(
                show: show,
                episodeID: Self.syntheticEpisodeID(mediaID: detail.id, episode: episode),
                episodeTitle: "",
                seasonNumber: nil,
                episodeNumber: episode,
                airDate: airDate,
                seriesStatus: "MyAnimeList · Estimated",
                classification: .anime,
                source: .myAnimeList,
                hasKnownAiringTime: false,
                isAnimeSpecial: detail.isSpecial
            )
        }
        .sorted {
            if $0.airDate != $1.airDate { return $0.airDate < $1.airDate }
            return $0.show.title.localizedStandardCompare($1.show.title) == .orderedAscending
        }
    }

    func fetchHomeCatalogs(
        apiKey: String,
        requiredKinds: Set<MacAniListCatalogKind>,
        limit: Int = 20
    ) async throws -> [MacAniListCatalogKind: [MacMediaItem]] {
        guard !requiredKinds.isEmpty else { return [:] }
        let boundedLimit = min(max(limit, 1), 30)
        var detailsByKind: [MacAniListCatalogKind: [MacMALAnimeDetails]] = [:]
        var firstFailure: Error?

        await withTaskGroup(of: (MacAniListCatalogKind, Result<[MacMALAnimeDetails], Error>).self) { group in
            for kind in requiredKinds {
                group.addTask {
                    do {
                        let values = try await self.fetchRanking(type: Self.rankingType(for: kind), limit: boundedLimit)
                        return (kind, .success(values))
                    } catch {
                        return (kind, .failure(error))
                    }
                }
            }
            for await (kind, result) in group {
                switch result {
                case .success(let details): detailsByKind[kind] = details
                case .failure(let error): if firstFailure == nil { firstFailure = error }
                }
            }
        }

        guard !detailsByKind.isEmpty else {
            throw firstFailure ?? MacMALCatalogError.noUsableCatalogs
        }

        var uniqueDetails: [MacMALAnimeDetails] = []
        var seenMALIDs = Set<Int>()
        for kind in requiredKinds {
            for detail in detailsByKind[kind, default: []]
                where !detail.isAdult && seenMALIDs.insert(detail.id).inserted {
                uniqueDetails.append(detail)
            }
        }

        var mappedByMALID: [Int: MacMediaItem] = [:]
        let concurrencyLimit = 6
        for startIndex in stride(from: 0, to: uniqueDetails.count, by: concurrencyLimit) {
            try Task.checkCancellation()
            let chunk = Array(uniqueDetails[startIndex..<min(startIndex + concurrencyLimit, uniqueDetails.count)])
            let mapped = await withTaskGroup(
                of: (Int, MacMediaItem?).self,
                returning: [(Int, MacMediaItem?)].self
            ) { group in
                for detail in chunk {
                    group.addTask {
                        let item = try? await self.resolveTMDBItem(for: detail, apiKey: apiKey)
                        return (detail.id, item)
                    }
                }
                var values: [(Int, MacMediaItem?)] = []
                for await value in group { values.append(value) }
                return values
            }
            for (malID, item) in mapped {
                if let item { mappedByMALID[malID] = item }
            }
        }

        guard !mappedByMALID.isEmpty else { throw MacMALCatalogError.noMappedMedia }
        var result: [MacAniListCatalogKind: [MacMediaItem]] = [:]
        for kind in requiredKinds {
            var seenTMDBIDs = Set<String>()
            result[kind] = detailsByKind[kind, default: []]
                .compactMap { mappedByMALID[$0.id] }
                .filter { seenTMDBIDs.insert($0.stableID).inserted }
        }
        return result
    }

    private func fetchRanking(type: String, limit: Int) async throws -> [MacMALAnimeDetails] {
        var components = URLComponents(
            url: apiBase.appendingPathComponent("anime/ranking"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "ranking_type", value: type),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fields", value: detailFields)
        ]
        guard let url = components?.url else { throw MacMALCatalogError.invalidURL }
        let response: MacMALListResponse = try await fetch(url)
        return response.data.map(\.node)
    }

    private func fetchSeasonAnime(year: Int, season: String, limit: Int) async throws -> [MacMALAnimeDetails] {
        var components = URLComponents(
            url: apiBase.appendingPathComponent("anime/season/\(year)/\(season)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "sort", value: "anime_num_list_users"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fields", value: detailFields)
        ]
        guard let url = components?.url else { throw MacMALCatalogError.invalidURL }
        let response: MacMALListResponse = try await fetch(url)
        return response.data.map(\.node)
    }

    private func fetch<Value: Decodable>(_ url: URL) async throws -> Value {
        let rawClientID = Bundle.main.object(forInfoDictionaryKey: "MALClientID") as? String ?? ""
        let clientID = rawClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !clientID.contains("$(") else {
            throw MacMALCatalogError.missingClientID
        }
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "api.myanimelist.net" else {
            throw MacMALCatalogError.invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.setValue(clientID, forHTTPHeaderField: "X-MAL-CLIENT-ID")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MacMALCatalogError.invalidResponse }
        guard 200..<300 ~= http.statusCode else { throw MacMALCatalogError.httpStatus(http.statusCode) }
        guard data.count <= 12_000_000 else { throw MacMALCatalogError.responseTooLarge }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private func resolveTMDBItem(for detail: MacMALAnimeDetails, apiKey: String) async throws -> MacMediaItem? {
        if let cached = tmdbCache[detail.id], cached.expiresAt > Date() { return cached.item }
        let expectedType = detail.mediaType?.lowercased() == "movie" ? "movie" : "tv"
        var components = URLComponents(string: "https://api.themoviedb.org/3/search/multi")
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: detail.displayTitle),
            URLQueryItem(name: "include_adult", value: "false")
        ]
        guard let url = components?.url else { throw MacMALCatalogError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw MacMALCatalogError.invalidResponse
        }
        let payload = try JSONDecoder().decode(MacMALTMDBSearchResponse.self, from: data)
        let expectedTitle = Self.normalizedTitle(detail.displayTitle)
        let expectedYear = detail.startDate.flatMap { Int(String($0.prefix(4))) }
        let item = payload.results
            .filter { $0.mediaType == expectedType }
            .max {
                $0.matchScore(title: expectedTitle, year: expectedYear)
                    < $1.matchScore(title: expectedTitle, year: expectedYear)
            }?
            .mediaItem
        tmdbCache[detail.id] = (Date().addingTimeInterval(item == nil ? 15 * 60 : 24 * 60 * 60), item)
        return item
    }

    private func estimatedNextAiringDate(
        for detail: MacMALAnimeDetails,
        start: Date,
        end: Date
    ) -> Date? {
        guard detail.status == "currently_airing" else { return nil }
        var calendar = Calendar.current
        calendar.timeZone = .current
        let weekday = Self.weekdayNumber(from: detail.broadcast?.dayOfTheWeek)
            ?? calendar.component(.weekday, from: start)
        var candidate = start
        for _ in 0..<8 {
            if calendar.component(.weekday, from: candidate) == weekday {
                let time = (detail.broadcast?.startTime ?? "20:00")
                    .split(separator: ":")
                    .compactMap { Int($0) }
                var components = calendar.dateComponents([.year, .month, .day], from: candidate)
                components.hour = time.first ?? 20
                components.minute = time.dropFirst().first ?? 0
                if let date = calendar.date(from: components), date >= start, date < end { return date }
            }
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        return nil
    }

    private func estimatedNextEpisode(for detail: MacMALAnimeDetails, airingAt: Date) -> Int {
        guard let startDate = detail.startDate,
              let start = Self.malDateFormatter.date(from: startDate) else { return 1 }
        let weeks = max(
            0,
            Calendar.current.dateComponents([.weekOfYear], from: start, to: airingAt).weekOfYear ?? 0
        )
        return min(max(weeks + 1, 1), detail.numEpisodes ?? Int.max)
    }

    private func season(for date: Date) -> (year: Int, name: String) {
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        let name: String
        switch components.month ?? 1 {
        case 1...3: name = "winter"
        case 4...6: name = "spring"
        case 7...9: name = "summer"
        default: name = "fall"
        }
        return (components.year ?? 2026, name)
    }

    private func nextSeason(after current: (year: Int, name: String)) -> (year: Int, name: String) {
        switch current.name {
        case "winter": (current.year, "spring")
        case "spring": (current.year, "summer")
        case "summer": (current.year, "fall")
        default: (current.year + 1, "winter")
        }
    }

    private static func rankingType(for kind: MacAniListCatalogKind) -> String {
        switch kind {
        case .trending, .airing: "airing"
        case .popular: "bypopularity"
        case .topRated: "all"
        case .upcoming: "upcoming"
        }
    }

    private static func weekdayNumber(from value: String?) -> Int? {
        switch value?.lowercased() {
        case "sunday": 1
        case "monday": 2
        case "tuesday": 3
        case "wednesday": 4
        case "thursday": 5
        case "friday": 6
        case "saturday": 7
        default: nil
        }
    }

    private static func syntheticEpisodeID(mediaID: Int, episode: Int) -> Int {
        max(1, ((abs(mediaID) &* 1_000) &+ max(episode, 1)) & Int.max)
    }

    fileprivate static func normalizedTitle(_ value: String) -> String {
        value.lowercased()
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined()
    }

    private static let malDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private enum MacMALCatalogError: LocalizedError {
    case missingClientID
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case responseTooLarge
    case noMappedMedia
    case noUsableCatalogs

    var errorDescription: String? {
        switch self {
        case .missingClientID: "MyAnimeList is not configured."
        case .invalidURL: "MyAnimeList returned an unsafe URL."
        case .invalidResponse: "MyAnimeList returned an invalid response."
        case .httpStatus(let status): "MyAnimeList returned HTTP \(status)."
        case .responseTooLarge: "MyAnimeList returned more data than Eclipse can safely process."
        case .noMappedMedia: "MyAnimeList titles could not be matched to playable media."
        case .noUsableCatalogs: "MyAnimeList did not return a usable anime catalog."
        }
    }
}

private struct MacMALListResponse: Decodable, Sendable {
    let data: [Entry]

    struct Entry: Decodable, Sendable {
        let node: MacMALAnimeDetails
    }
}

private struct MacMALAnimeDetails: Decodable, Sendable {
    let id: Int
    let title: String
    let mainPicture: MacMALPicture?
    let alternativeTitles: MacMALAlternativeTitles?
    let mean: Double?
    let startDate: String?
    let mediaType: String?
    let status: String?
    let numEpisodes: Int?
    let startSeason: MacMALStartSeason?
    let broadcast: MacMALBroadcast?
    let rating: String?
    let genres: [MacMALGenre]?

    enum CodingKeys: String, CodingKey {
        case id, title, mean, status, broadcast, rating, genres
        case mainPicture = "main_picture"
        case alternativeTitles = "alternative_titles"
        case startDate = "start_date"
        case mediaType = "media_type"
        case numEpisodes = "num_episodes"
        case startSeason = "start_season"
    }

    var displayTitle: String {
        let english = alternativeTitles?.en?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return english.isEmpty ? title : english
    }

    var isAdult: Bool {
        if rating?.lowercased() == "rx" { return true }
        let genreText = genres?.compactMap(\.name).joined(separator: " ").lowercased() ?? ""
        return genreText.contains("hentai") || genreText.contains("erotica")
    }

    var isSpecial: Bool {
        ["ova", "ona", "special", "tv_special"].contains(mediaType?.lowercased() ?? "")
    }
}

private struct MacMALPicture: Decodable, Sendable {
    let medium: String?
    let large: String?
}

private struct MacMALAlternativeTitles: Decodable, Sendable {
    let synonyms: [String]?
    let en: String?
    let ja: String?
}

private struct MacMALStartSeason: Decodable, Sendable {
    let year: Int
    let season: String
}

private struct MacMALBroadcast: Decodable, Sendable {
    let dayOfTheWeek: String?
    let startTime: String?

    enum CodingKeys: String, CodingKey {
        case dayOfTheWeek = "day_of_the_week"
        case startTime = "start_time"
    }
}

private struct MacMALGenre: Decodable, Sendable {
    let name: String?
}

private struct MacMALTMDBSearchResponse: Decodable, Sendable {
    let results: [MacMALTMDBSearchRow]
}

private struct MacMALTMDBSearchRow: Decodable, Sendable {
    let id: Int
    let mediaType: String?
    let title: String?
    let name: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let voteAverage: Double?

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview
        case mediaType = "media_type"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
    }

    var mediaItem: MacMediaItem? {
        guard let mediaType, mediaType == "tv" || mediaType == "movie" else { return nil }
        let displayTitle = mediaType == "movie" ? title : name
        guard let displayTitle, !displayTitle.isEmpty else { return nil }
        return MacMediaItem(
            id: id,
            mediaType: mediaType,
            title: displayTitle,
            overview: overview ?? "",
            posterPath: posterPath,
            backdropPath: backdropPath,
            date: mediaType == "movie" ? releaseDate : firstAirDate,
            rating: voteAverage ?? 0
        )
    }

    func matchScore(title expectedTitle: String, year expectedYear: Int?) -> Int {
        let normalizedTitle = (mediaType == "movie" ? title : name).map(MacMALCatalogService.normalizedTitle) ?? ""
        var score = normalizedTitle == expectedTitle ? 100 : 0
        if !expectedTitle.isEmpty,
           normalizedTitle.contains(expectedTitle) || expectedTitle.contains(normalizedTitle) { score += 30 }
        let rawDate = mediaType == "movie" ? releaseDate : firstAirDate
        if let expectedYear,
           let candidateYear = rawDate.flatMap({ Int(String($0.prefix(4))) }) {
            score += max(0, 20 - abs(expectedYear - candidateYear) * 5)
        }
        return score
    }
}

private enum MacScheduleSourceError: LocalizedError {
    case missingTraktClientID
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .missingTraktClientID: "Trakt is not configured."
        case .invalidURL: "The schedule provider returned an unsafe URL."
        case .invalidResponse: "The schedule provider returned an invalid response."
        case .httpStatus(let status): "The schedule provider returned HTTP \(status)."
        case .responseTooLarge: "The schedule provider returned more data than Eclipse can safely process."
        }
    }
}

private struct MacTraktCalendarItem: Decodable, Sendable {
    let firstAired: String
    let episode: MacTraktEpisode
    let show: MacTraktShow

    enum CodingKeys: String, CodingKey {
        case firstAired = "first_aired"
        case episode, show
    }

    var showKey: String {
        show.ids.trakt.map { "trakt-\($0)" }
            ?? show.ids.tmdb.map { "tmdb-\($0)" }
            ?? show.title.lowercased()
    }
}

private struct MacTraktEpisode: Decodable, Sendable {
    let season: Int?
    let number: Int?
    let title: String?
    let ids: MacTraktIDs?
}

private struct MacTraktShow: Decodable, Sendable {
    let title: String
    let year: Int?
    let ids: MacTraktIDs
    let language: String?
    let network: String?
    let genres: [String]?
    let overview: String?
    let rating: Double?

    var isWesternScheduleCandidate: Bool {
        guard language?.lowercased() == "en" else { return false }
        let excluded: Set<String> = [
            "anime", "documentary", "food", "game-show", "home-and-garden", "news",
            "reality", "soap", "special-interest", "sport", "talk-show"
        ]
        return Set((genres ?? []).map { $0.lowercased() }).isDisjoint(with: excluded)
    }
}

private struct MacTraktIDs: Decodable, Sendable {
    let trakt: Int?
    let tmdb: Int?
}

private struct MacTVMazeEpisode: Decodable, Sendable {
    let id: Int
    let name: String?
    let season: Int
    let number: Int?
    let airdate: String
    let airtime: String?
    let airstamp: String?
    let show: MacTVMazeShow

    private enum CodingKeys: String, CodingKey {
        case id, name, season, number, airdate, airtime, airstamp, show
        case embedded = "_embedded"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        season = try container.decode(Int.self, forKey: .season)
        number = try container.decodeIfPresent(Int.self, forKey: .number)
        airdate = try container.decode(String.self, forKey: .airdate)
        airtime = try container.decodeIfPresent(String.self, forKey: .airtime)
        airstamp = try container.decodeIfPresent(String.self, forKey: .airstamp)
        show = try container.decodeIfPresent(MacTVMazeShow.self, forKey: .show)
            ?? container.decode(MacTVMazeEmbedded.self, forKey: .embedded).show
    }

    var airing: MacTVMazeAiring? {
        let knownTime = airtime?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if let airstamp, let date = ISO8601DateFormatter().date(from: airstamp) {
            return MacTVMazeAiring(date: date, hasKnownAiringTime: knownTime)
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = knownTime ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        if let identifier = show.network?.country?.timezone ?? show.webChannel?.country?.timezone {
            formatter.timeZone = TimeZone(identifier: identifier)
        }
        let value = knownTime ? "\(airdate) \(airtime ?? "")" : airdate
        return formatter.date(from: value).map { MacTVMazeAiring(date: $0, hasKnownAiringTime: knownTime) }
    }
}

private struct MacTVMazeAiring: Sendable {
    let date: Date
    let hasKnownAiringTime: Bool
}

private struct MacTVMazeEmbedded: Decodable, Sendable {
    let show: MacTVMazeShow
}

private struct MacTVMazeShow: Decodable, Sendable {
    let id: Int
    let name: String
    let language: String?
    let type: String?
    let genres: [String]
    let summary: String?
    let premiered: String?
    let image: MacTVMazeImage?
    let rating: MacTVMazeRating?
    let network: MacTVMazeChannel?
    let webChannel: MacTVMazeChannel?
    let schedule: MacTVMazeShowSchedule?

    var isLikelyAnime: Bool {
        let animation = genres.contains { ["anime", "animation"].contains($0.lowercased()) }
        return language?.lowercased() == "japanese" && animation
    }

    var isWesternScheduleCandidate: Bool {
        guard !isLikelyAnime, (schedule?.days.count ?? 0) < 4 else { return false }
        return ["scripted", "animation"].contains(type?.lowercased() ?? "")
    }

    var isEnglishLanguage: Bool { language?.lowercased() == "english" }

    func isIncludedInFullSchedule(regionCode: String) -> Bool {
        if network?.country?.code?.uppercased() == regionCode.uppercased() { return true }
        if let webCountry = webChannel?.country { return webCountry.code?.uppercased() == regionCode.uppercased() }
        return webChannel != nil && isEnglishLanguage
    }
}

private struct MacTVMazeImage: Decodable, Sendable {
    let medium: String?
    let original: String?
}

private struct MacTVMazeRating: Decodable, Sendable {
    let average: Double?
}

private struct MacTVMazeShowSchedule: Decodable, Sendable {
    let days: [String]
}

private struct MacTVMazeChannel: Decodable, Sendable {
    let name: String?
    let country: MacTVMazeCountry?
}

private struct MacTVMazeCountry: Decodable, Sendable {
    let code: String?
    let timezone: String?
}

private extension String {
    var strippingHTML: String {
        replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
