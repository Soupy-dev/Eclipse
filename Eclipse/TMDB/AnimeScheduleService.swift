import Foundation

enum AnimeScheduleError: Error, LocalizedError {
    case unconfigured
    case invalidResponse
    case http(Int)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unconfigured: return "AnimeSchedule is not configured in this build."
        case .invalidResponse: return "AnimeSchedule returned an invalid schedule."
        case .http(let status): return "AnimeSchedule request failed (HTTP \(status))."
        case .unavailable: return "AnimeSchedule has no available timetable for these dates."
        }
    }
}

struct AnimeScheduleWeek: Hashable, Codable {
    let year: Int
    let week: Int

    var key: String { "\(year)-\(week)" }

    static func covering(_ window: DateInterval) -> [AnimeScheduleWeek] {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        guard var date = calendar.dateInterval(of: .weekOfYear, for: window.start)?.start else { return [] }
        var weeks: [AnimeScheduleWeek] = []
        while date < window.end, weeks.count < 7 {
            weeks.append(AnimeScheduleWeek(
                year: calendar.component(.yearForWeekOfYear, from: date),
                week: calendar.component(.weekOfYear, from: date)
            ))
            guard let next = calendar.date(byAdding: .day, value: 7, to: date), next > date else { break }
            date = next
        }
        return weeks
    }
}

struct AnimeScheduleCategory: Codable {
    let name: String?
    let route: String
}

struct AnimeScheduleTimetableEntry: Codable {
    let title: String
    let route: String
    let romaji: String?
    let english: String?
    let native: String?
    let episodeDate: String
    let episodeNumber: Int
    let subtractedEpisodeNumber: Int?
    let episodes: Int?
    let airType: String
    let airingStatus: String?
    let delayedFrom: String?
    let delayedUntil: String?
    let mediaTypes: [AnimeScheduleCategory]?
    let imageVersionRoute: String?
}

struct AnimeScheduleAnime: Codable {
    struct Websites: Codable {
        let aniList: String?
        let mal: String?
    }

    let route: String
    let websites: Websites?
    let genres: [AnimeScheduleCategory]?

    var aniListID: Int? { Self.identifier(websites?.aniList, host: "anilist.co") }
    var malID: Int? { Self.identifier(websites?.mal, host: "myanimelist.net") }

    var isAdult: Bool {
        genres?.contains { ["hentai", "adult", "erotica"].contains($0.route.lowercased()) } == true
    }

    static func identifier(_ text: String?, host: String) -> Int? {
        guard let text, text.utf8.count <= 2048,
              let url = URL(string: text.contains("://") ? text : "https://" + text),
              [host, "www." + host].contains(url.host?.lowercased() ?? ""),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[0] == "anime", let id = Int(parts[1]),
              id > 0, id <= 1_000_000_000 else { return nil }
        return id
    }
}

enum AnimeScheduleEntryMapper {
    static func date(_ value: String?) -> Date? {
        guard let value, value.count <= 40, !value.hasPrefix("0001-") else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }

    static func validRoute(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 200
            && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0) }
    }

    static func entries(
        from row: AnimeScheduleTimetableEntry,
        anime: AnimeScheduleAnime?,
        window: DateInterval,
        preferredLanguageCode: String,
        stale: Bool = false
    ) -> [AniListAiringScheduleEntry] {
        guard row.airType == "raw", validRoute(row.route), anime?.route == row.route,
              anime?.isAdult != true,
              !row.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              row.title.utf8.count <= 1024,
              row.episodeNumber > 0, row.episodeNumber <= 100_000,
              let date = date(row.episodeDate), date >= window.start, date < window.end else { return [] }
        let firstEpisode = row.subtractedEpisodeNumber ?? row.episodeNumber
        guard firstEpisode > 0, firstEpisode <= row.episodeNumber,
              row.episodeNumber - firstEpisode < 200 else { return [] }
        let mediaID = anime?.aniListID ?? anime?.malID.map { -$0 } ?? 0
        guard mediaID != 0 else { return [] }
        let formats = row.mediaTypes?.map(\.route) ?? []
        let format: String?
        if formats.contains(where: { $0.hasPrefix("movie") }) { format = "MOVIE" }
        else if formats.contains("tv-short") { format = "TV_SHORT" }
        else if formats.contains(where: { $0.hasPrefix("tv") }) { format = "TV" }
        else if formats.contains(where: { $0.hasPrefix("ona") }) { format = "ONA" }
        else if formats.contains("ova") { format = "OVA" }
        else if formats.contains("special") { format = "SPECIAL" }
        else if formats.contains("music") { format = "MUSIC" }
        else { format = nil }
        let names = AniListAnime.AniListTitle(romaji: row.romaji ?? row.title, english: row.english, native: row.native)
        let delayed = row.airingStatus?.lowercased().hasPrefix("delayed") == true
            || (Self.date(row.delayedFrom).map { start in
                date >= start && (Self.date(row.delayedUntil).map { date < $0 } ?? true)
            } ?? false)
        let knownTime = !delayed && !stale
        let image: String?
        if let route = row.imageVersionRoute, route.utf8.count <= 1024,
           !route.contains(".."), !route.contains("://"), !route.hasPrefix("/") {
            image = URL(string: "https://img.animeschedule.net/production/assets/public/img/" + route)?.absoluteString
        } else { image = nil }
        return (firstEpisode...row.episodeNumber).map { episode in
            AniListAiringScheduleEntry(
                id: -(abs(mediaID) * 100_001 + episode),
                mediaId: mediaID,
                title: AniListTitlePicker.title(from: names, preferredLanguageCode: preferredLanguageCode),
                airingAt: date,
                episode: episode,
                coverImage: image,
                englishTitle: row.english,
                romajiTitle: row.romaji ?? row.title,
                nativeTitle: row.native,
                format: format,
                hasKnownAiringTime: knownTime,
                scheduleProvider: .animeSchedule,
                malID: anime?.malID,
                airingTimeWithdrawn: delayed && !stale
            )
        }
    }
}

actor AnimeScheduleService {
    static let shared = AnimeScheduleService()

    private struct CachedWeek: Codable {
        let fetchedAt: Date
        let rows: [AnimeScheduleTimetableEntry]
    }

    private struct CachedAnime: Codable {
        let fetchedAt: Date
        let anime: AnimeScheduleAnime
    }

    private struct Cache: Codable {
        var weeks: [String: CachedWeek] = [:]
        var anime: [String: CachedAnime] = [:]
    }

    private struct AnimePage: Decodable {
        let page: Int
        let totalAmount: Int
        let anime: [AnimeScheduleAnime]
    }

    private let session: URLSession
    private let token: String
    private let cacheURL: URL?
    private let requestSpacing: TimeInterval
    private var nextRequestAt = Date.distantPast
    private var cache = Cache()
    private var didLoadCache = false
    private var catalogFetchedAt: Date?

    init(session: URLSession = .shared, token: String? = nil, cacheURL: URL? = nil, requestSpacing: TimeInterval = 0.55) {
        self.session = session
        let configured = token ?? Bundle.main.object(forInfoDictionaryKey: "AnimeScheduleAPIToken") as? String ?? ""
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = trimmed.contains("$(") || trimmed.utf8.count > 512 ? "" : trimmed
        self.cacheURL = cacheURL ?? (token == nil ? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("animeschedule-v1.json") : nil)
        self.requestSpacing = requestSpacing
    }

    func fetchSchedule(daysAhead: Int, now: Date = Date(), preferredLanguageCode: String = "en") async throws -> AnimeAiringScheduleResult {
        guard !token.isEmpty else { throw AnimeScheduleError.unconfigured }
        guard (1...30).contains(daysAhead) else { throw AnimeScheduleError.invalidResponse }
        try Task.checkCancellation()
        loadCache(now: now)
        let deadline = Date().addingTimeInterval(45)
        let window = ScheduleDateWindow.envelope(dayCount: daysAhead, now: now)
        let weeks = AnimeScheduleWeek.covering(window)
        var rows: [(AnimeScheduleTimetableEntry, Bool)] = []
        var complete = true
        var usedStale = false
        var loadedWeeks = 0
        var requestsUnavailable = false
        for week in weeks {
            try Task.checkCancellation()
            if let cached = cache.weeks[week.key], isFresh(cached.fetchedAt, now: now, age: 900) {
                rows += cached.rows.map { ($0, false) }
                loadedWeeks += 1
                continue
            }
            do {
                guard !requestsUnavailable else { throw AnimeScheduleError.unavailable }
                let data = try await request(path: "timetables/raw", query: [
                    URLQueryItem(name: "year", value: String(week.year)),
                    URLQueryItem(name: "week", value: String(week.week)),
                    URLQueryItem(name: "tz", value: "UTC")
                ], deadline: deadline)
                let entries = try JSONDecoder().decode([AnimeScheduleTimetableEntry].self, from: data)
                guard entries.count <= 2000 else { throw AnimeScheduleError.invalidResponse }
                cache.weeks[week.key] = CachedWeek(fetchedAt: now, rows: entries)
                rows += entries.map { ($0, false) }
                loadedWeeks += 1
            } catch {
                try Self.rethrowCancellation(error)
                complete = false
                if let cached = cache.weeks[week.key], isFresh(cached.fetchedAt, now: now, age: 48 * 3600) {
                    rows += cached.rows.map { ($0, true) }
                    loadedWeeks += 1
                    usedStale = true
                }
                if case AnimeScheduleError.http(404) = error {} else { requestsUnavailable = true }
            }
        }
        guard loadedWeeks > 0 else { throw AnimeScheduleError.unavailable }
        let wantedRoutes = Set(rows.compactMap { row, _ -> String? in
            guard AnimeScheduleEntryMapper.validRoute(row.route),
                  let date = AnimeScheduleEntryMapper.date(row.episodeDate),
                  date >= window.start, date < window.end else { return nil }
            return row.route
        })
        if !requestsUnavailable, wantedRoutes.contains(where: { cachedAnime($0, now: now) == nil }),
           !isFresh(catalogFetchedAt, now: now, age: 3600) {
            do { try await fetchOngoingAnime(now: now, wantedRoutes: wantedRoutes, deadline: deadline) }
            catch {
                try Self.rethrowCancellation(error)
                if case AnimeScheduleError.http(404) = error {} else { requestsUnavailable = true }
            }
        }
        var detailRequests = 0
        for route in wantedRoutes.sorted() where cachedAnime(route, now: now) == nil {
            guard !requestsUnavailable, detailRequests < 80 else { complete = false; break }
            detailRequests += 1
            do {
                let data = try await request(path: "anime/" + route, deadline: deadline)
                let anime = try JSONDecoder().decode(AnimeScheduleAnime.self, from: data)
                guard anime.route == route else { throw AnimeScheduleError.invalidResponse }
                cache.anime[route] = CachedAnime(fetchedAt: now, anime: anime)
            } catch {
                try Self.rethrowCancellation(error)
                complete = false
                if case AnimeScheduleError.http(404) = error {} else { break }
            }
        }
        var entriesByID: [String: AniListAiringScheduleEntry] = [:]
        for (row, stale) in rows {
            if row.airType != "raw" || !AnimeScheduleEntryMapper.validRoute(row.route) || AnimeScheduleEntryMapper.date(row.episodeDate) == nil {
                complete = false
            }
            let anime = cachedAnime(row.route, now: now)
            if wantedRoutes.contains(row.route), anime == nil || (anime?.aniListID == nil && anime?.malID == nil) {
                complete = false
            }
            let mapped = AnimeScheduleEntryMapper.entries(from: row, anime: anime, window: window, preferredLanguageCode: preferredLanguageCode, stale: stale)
            if wantedRoutes.contains(row.route), anime?.isAdult != true, mapped.isEmpty { complete = false }
            for entry in mapped {
                let key = "\(entry.mediaId)-\(entry.episode)"
                if let previous = entriesByID[key], previous.airingAt == entry.airingAt,
                   previous.airingTimeWithdrawn == true { continue }
                entriesByID[key] = entry
            }
        }
        try Task.checkCancellation()
        persistCache(now: now)
        guard !entriesByID.isEmpty || complete else { throw AnimeScheduleError.unavailable }
        let notice = usedStale
            ? "AnimeSchedule fallback · Saved schedule; refresh unavailable."
            : complete ? "Schedule provided by AnimeSchedule.net."
            : "AnimeSchedule fallback · Some dates or shows are unavailable."
        return AnimeAiringScheduleResult(
            entries: entriesByID.values.sorted { $0.airingAt == $1.airingAt ? $0.mediaId < $1.mediaId : $0.airingAt < $1.airingAt },
            isAuthoritativeForNotifications: false,
            notice: notice
        )
    }

    private func fetchOngoingAnime(now: Date, wantedRoutes: Set<String>, deadline: Date) async throws {
        for page in 1...32 {
            let data = try await request(path: "anime", query: [
                URLQueryItem(name: "airing-statuses", value: "ongoing"),
                URLQueryItem(name: "page", value: String(page))
            ], deadline: deadline)
            let result = try JSONDecoder().decode(AnimePage.self, from: data)
            guard result.page == page, result.anime.count <= 18,
                  result.totalAmount >= 0, result.totalAmount <= 10_000 else { throw AnimeScheduleError.invalidResponse }
            for anime in result.anime where wantedRoutes.contains(anime.route) {
                cache.anime[anime.route] = CachedAnime(fetchedAt: now, anime: anime)
            }
            if page * 18 >= result.totalAmount || result.anime.isEmpty {
                catalogFetchedAt = now
                break
            }
        }
    }

    private func request(path: String, query: [URLQueryItem] = [], deadline: Date) async throws -> Data {
        try Task.checkCancellation()
        let slot = max(Date(), nextRequestAt)
        guard slot < deadline else { throw AnimeScheduleError.unavailable }
        nextRequestAt = slot.addingTimeInterval(requestSpacing)
        let delay = slot.timeIntervalSinceNow
        guard delay < 30 else { throw AnimeScheduleError.http(429) }
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        guard var components = URLComponents(string: "https://animeschedule.net/api/v3/" + path) else { throw AnimeScheduleError.invalidResponse }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw AnimeScheduleError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = min(12, max(0.1, deadline.timeIntervalSinceNow))
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Eclipse/AnimeSchedule", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.boundedData(for: request, maximumResponseBytes: 2 * 1024 * 1024)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw AnimeScheduleError.invalidResponse }
        if response.statusCode == 429 {
            let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
            let delay = max(60, min(retry ?? reset.map { $0 - Date().timeIntervalSince1970 } ?? 60, 3600))
            nextRequestAt = Date().addingTimeInterval(delay)
        }
        guard response.statusCode == 200 else { throw AnimeScheduleError.http(response.statusCode) }
        return data
    }

    private func cachedAnime(_ route: String, now: Date) -> AnimeScheduleAnime? {
        guard let cached = cache.anime[route], isFresh(cached.fetchedAt, now: now, age: 7 * 86400) else { return nil }
        return cached.anime
    }

    private func isFresh(_ fetchedAt: Date?, now: Date, age: TimeInterval) -> Bool {
        guard let fetchedAt else { return false }
        let elapsed = now.timeIntervalSince(fetchedAt)
        return elapsed >= 0 && elapsed < age
    }

    private func loadCache(now: Date) {
        guard !didLoadCache else { return }
        didLoadCache = true
        guard let cacheURL,
              let size = try? cacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 4 * 1024 * 1024,
              let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode(Cache.self, from: data),
              decoded.weeks.count <= 7, decoded.anime.count <= 512,
              decoded.weeks.values.allSatisfy({ $0.rows.count <= 2000 }) else { return }
        cache = decoded
    }

    private func persistCache(now: Date) {
        cache.weeks = Dictionary(uniqueKeysWithValues: cache.weeks.filter { isFresh($0.value.fetchedAt, now: now, age: 48 * 3600) }
            .sorted { $0.value.fetchedAt > $1.value.fetchedAt }.prefix(7).map { ($0.key, $0.value) })
        cache.anime = Dictionary(uniqueKeysWithValues: cache.anime.filter { isFresh($0.value.fetchedAt, now: now, age: 7 * 86400) }
            .sorted { $0.value.fetchedAt > $1.value.fetchedAt }.prefix(512).map { ($0.key, $0.value) })
        guard let cacheURL, let data = try? JSONEncoder().encode(cache), data.count <= 4 * 1024 * 1024 else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    static func rethrowCancellation(_ error: Error) throws {
        if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
    }
}

enum AnimeScheduleFallback {
    static func load(
        aniList: () async throws -> AnimeAiringScheduleResult,
        animeSchedule: () async throws -> AnimeAiringScheduleResult,
        mal: () async throws -> AnimeAiringScheduleResult,
        permitsFallback: (Error) -> Bool
    ) async throws -> AnimeAiringScheduleResult {
        do { return try await aniList() }
        catch {
            try AnimeScheduleService.rethrowCancellation(error)
            guard permitsFallback(error) else { throw error }
        }
        do { return try await animeSchedule() }
        catch { try AnimeScheduleService.rethrowCancellation(error) }
        return try await mal()
    }
}
