import Foundation

import Network

enum AnimeMetadataSource: String, Codable {
    case anilistLive
    case anilistCache
    case malFallback
}

enum AnimeExternalID: Hashable, Codable {
    case anilist(Int)
    case mal(Int)
}

enum AnimeMetadataRatingSource: String, Codable, Equatable {
    case myAnimeList
    case aniList
    case tmdb

    var label: String {
        switch self {
        case .myAnimeList: return "MAL"
        case .aniList: return "AniList"
        case .tmdb: return "TMDB"
        }
    }
}

struct AnimeMetadataRating: Codable, Equatable {
    let value: Double
    let source: AnimeMetadataRatingSource

    var displayText: String {
        "\(String(format: "%.1f/10", value)) (\(source.label))"
    }
}

enum AnimeProviderFailureReason: String {
    case offline
    case anilistUnavailable
    case anilistRateLimited
    case malUnavailable
    case unknown
}

extension Notification.Name {
    static let animeMetadataDidSwitchToMALFallback = Notification.Name("animeMetadataDidSwitchToMALFallback")
}

final class AnimeProviderHealthCenter {
    static let shared = AnimeProviderHealthCenter()

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "anime.provider.network")
    private let lock = NSLock()
    private var networkReachable = true
    private var anilistUnavailableUntil: Date?
    private var consecutiveAniListUnavailableFailures = 0
    private var firstAniListUnavailableFailureAt: Date?
    private var sentFallbackPrompt = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.lock.lock()
            self?.networkReachable = path.status == .satisfied
            self?.lock.unlock()
        }
        monitor.start(queue: monitorQueue)
    }

    var isAniListTemporarilyUnavailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let until = anilistUnavailableUntil else { return false }
        return until > Date()
    }

    @discardableResult
    func recordAniListFailure(_ error: Error) -> AnimeProviderFailureReason {
        let reason = classifyAniListFailure(error)
        switch reason {
        case .offline:
            resetAniListUnavailableFailures()
            Logger.shared.log("AnimeMetadata: AniList failure classified as offline: \(error.localizedDescription)", type: "AniList")
        case .anilistRateLimited:
            resetAniListUnavailableFailures()
            Logger.shared.log("AnimeMetadata: AniList rate limited, fallback allowed: \(error.localizedDescription)", type: "AniList")
        case .anilistUnavailable:
            if noteAniListUnavailableFailure() {
                markAniListUnavailable(seconds: 180)
                Logger.shared.log("AnimeMetadata: AniList unavailable confirmed, fallback allowed: \(error.localizedDescription)", type: "AniList")
            } else {
                Logger.shared.log("AnimeMetadata: AniList unavailable suspected, fallback allowed without popup: \(error.localizedDescription)", type: "AniList")
            }
        case .malUnavailable, .unknown:
            resetAniListUnavailableFailures()
            Logger.shared.log("AnimeMetadata: AniList failure left as unknown: \(error.localizedDescription)", type: "AniList")
        }
        return reason
    }

    func recordAniListSuccess() {
        lock.lock()
        anilistUnavailableUntil = nil
        consecutiveAniListUnavailableFailures = 0
        firstAniListUnavailableFailureAt = nil
        lock.unlock()
    }

    func recordMALFailure(_ error: Error) {
        Logger.shared.log("AnimeMetadata: MAL fallback failed: \(error.localizedDescription)", type: "AniList")
    }

    func notifyMALFallbackIfNeeded(reason: String) {
        lock.lock()
        let isConfirmedUnavailable = anilistUnavailableUntil.map { $0 > Date() } ?? false
        guard isConfirmedUnavailable else {
            lock.unlock()
            Logger.shared.log("AnimeMetadata: skipped MAL fallback notice reason=\(reason) because AniList outage is not confirmed", type: "AniList")
            return
        }
        guard !sentFallbackPrompt else {
            lock.unlock()
            return
        }
        sentFallbackPrompt = true
        lock.unlock()

        Logger.shared.log("AnimeMetadata: presenting MAL fallback notice reason=\(reason)", type: "AniList")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .animeMetadataDidSwitchToMALFallback, object: nil)
        }
    }

    private func markAniListUnavailable(seconds: TimeInterval) {
        lock.lock()
        anilistUnavailableUntil = Date().addingTimeInterval(seconds)
        lock.unlock()
    }

    private func resetAniListUnavailableFailures() {
        lock.lock()
        consecutiveAniListUnavailableFailures = 0
        firstAniListUnavailableFailureAt = nil
        lock.unlock()
    }

    private func noteAniListUnavailableFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        if let first = firstAniListUnavailableFailureAt, now.timeIntervalSince(first) <= 90 {
            consecutiveAniListUnavailableFailures += 1
        } else {
            firstAniListUnavailableFailureAt = now
            consecutiveAniListUnavailableFailures = 1
        }

        return consecutiveAniListUnavailableFailures >= 2
    }

    func shouldUseMALFallback(for reason: AnimeProviderFailureReason) -> Bool {
        switch reason {
        case .anilistUnavailable, .anilistRateLimited:
            return true
        case .offline, .malUnavailable, .unknown:
            return false
        }
    }

    private func classifyAniListFailure(_ error: Error) -> AnimeProviderFailureReason {
        let nsError = error as NSError
        if let urlCode = urlErrorCode(from: error) {
            switch urlCode {
            case .notConnectedToInternet, .dataNotAllowed:
                return .offline
            case .networkConnectionLost:
                return currentNetworkReachable() ? .unknown : .offline
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return currentNetworkReachable() ? .anilistUnavailable : .offline
            case .cancelled:
                return .unknown
            default:
                break
            }
        }

        if nsError.domain == "AniList" {
            if nsError.code == 429 { return .anilistRateLimited }
            if nsError.code >= 500 {
                return currentNetworkReachable() ? .anilistUnavailable : .offline
            }
            if nsError.code == NSURLErrorNotConnectedToInternet { return .offline }
            return .unknown
        }

        return currentNetworkReachable() ? .unknown : .offline
    }

    private func currentNetworkReachable() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return networkReachable
    }

    private func urlErrorCode(from error: Error) -> URLError.Code? {
        if let urlError = error as? URLError {
            return urlError.code
        }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return nil }
        return URLError.Code(rawValue: nsError.code)
    }
}

private enum AnimeTMDBMatchSource: String, Codable {
    case anilist
    case myAnimeList
}

private struct AnimeTMDBMatchCacheKey: Hashable {
    let source: AnimeTMDBMatchSource
    let id: Int
    let language: String
    let titleSignature: String
    let expectedYear: Int?
    let format: String?

    init(
        source: AnimeTMDBMatchSource,
        id: Int,
        language: String,
        titleCandidates: [String],
        expectedYear: Int?,
        format: String?
    ) {
        self.source = source
        self.id = id
        self.language = language
        self.titleSignature = Self.titleSignature(from: titleCandidates)
        self.expectedYear = expectedYear
        self.format = format?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    var storageKey: String {
        [
            source.rawValue,
            String(id),
            language.lowercased(),
            expectedYear.map(String.init) ?? "-",
            format ?? "-",
            titleSignature
        ].joined(separator: "|")
    }

    private static func titleSignature(from titleCandidates: [String]) -> String {
        var seen = Set<String>()
        let normalized = titleCandidates.compactMap { candidate -> String? in
            let key = candidate
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .joined()
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return key
        }
        return normalized.sorted().joined(separator: ",")
    }
}

private struct AnimeTMDBMatchCacheLookup {
    let result: TMDBSearchResult?
}

private struct AnimeTMDBMatchCacheRecord {
    let key: AnimeTMDBMatchCacheKey
    let result: TMDBSearchResult?
}

private actor AnimeTMDBMatchCache {
    static let shared = AnimeTMDBMatchCache()

    private struct Entry: Codable {
        let result: TMDBSearchResult?
        let storedAt: TimeInterval
    }

    private let successMaxAge: TimeInterval = 60 * 60 * 24 * 30
    private let missMaxAge: TimeInterval = 60 * 60 * 24
    private let maxEntries = 800
    private let fileURL: URL
    private var entries: [String: Entry]

    private init() {
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        fileURL = cacheDirectory.appendingPathComponent("anime-tmdb-match-cache-v1.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    func lookup(_ key: AnimeTMDBMatchCacheKey) -> AnimeTMDBMatchCacheLookup? {
        let storageKey = key.storageKey
        guard let entry = entries[storageKey] else { return nil }

        let maxAge = entry.result == nil ? missMaxAge : successMaxAge
        guard Date().timeIntervalSince1970 - entry.storedAt <= maxAge else {
            entries.removeValue(forKey: storageKey)
            return nil
        }

        return AnimeTMDBMatchCacheLookup(result: entry.result)
    }

    func store(_ records: [AnimeTMDBMatchCacheRecord]) {
        guard !records.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        for record in records {
            entries[record.key.storageKey] = Entry(result: record.result, storedAt: now)
        }
        prune(now: now)
        persist()
    }

    private func prune(now: TimeInterval) {
        entries = entries.filter { _, entry in
            let maxAge = entry.result == nil ? missMaxAge : successMaxAge
            return now - entry.storedAt <= maxAge
        }

        guard entries.count > maxEntries else { return }
        let keep = entries
            .sorted { $0.value.storedAt > $1.value.storedAt }
            .prefix(maxEntries)
        entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    private func persist() {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Logger.shared.log("AnimeTMDBMatchCache: persist failed: \(error.localizedDescription)", type: "AniList")
        }
    }
}

actor AnimeIdentityCache {
    static let shared = AnimeIdentityCache()

    private struct CachedDetails: Codable {
        let value: AniListAnimeWithSeasons
        let storedAt: TimeInterval
        let languageCode: String?
    }

    private let detailsKey = "anime.metadata.details.cache.v1"
    private let maxAge: TimeInterval = 60 * 60 * 24 * 45
    // Full episode graphs can gain newly aired metadata. Keep the fast path
    // short while retaining the separate 45-day stale-on-error fallback.
    private let freshMaxAge: TimeInterval = 60 * 60
    private let maxEntries = 40
    private var details: [String: CachedDetails]

    private init() {
        if let data = UserDefaults.standard.data(forKey: detailsKey),
           let decoded = try? JSONDecoder().decode([String: CachedDetails].self, from: data) {
            details = decoded
        } else {
            details = [:]
        }
    }

    func cachedDetails(
        tmdbShowId: Int,
        title: String,
        languageCode: String
    ) -> AniListAnimeWithSeasons? {
        let keys = detailKeys(tmdbShowId: tmdbShowId, title: title)
        let now = Date().timeIntervalSince1970
        for key in keys {
            guard let cached = details[key],
                  now - cached.storedAt <= maxAge,
                  cached.languageCode == nil || cached.languageCode == languageCode else {
                continue
            }
            Logger.shared.log("AnimeMetadataCache: details cache hit key=\(key)", type: "AniList")
            return cached.value
        }
        return nil
    }

    func cachedFreshDetails(
        tmdbShowId: Int,
        title: String,
        languageCode: String
    ) -> AniListAnimeWithSeasons? {
        let now = Date().timeIntervalSince1970
        for key in detailKeys(tmdbShowId: tmdbShowId, title: title) {
            guard let cached = details[key],
                  cached.languageCode == languageCode,
                  now - cached.storedAt <= freshMaxAge else {
                continue
            }
            Logger.shared.log("AnimeMetadataCache: fresh details cache hit key=\(key)", type: "AniList")
            return cached.value
        }
        return nil
    }

    func storeAniListDetails(
        _ value: AniListAnimeWithSeasons,
        tmdbShowId: Int,
        title: String,
        languageCode: String
    ) {
        let cached = CachedDetails(
            value: value,
            storedAt: Date().timeIntervalSince1970,
            languageCode: languageCode
        )
        // Store the full episode graph once. Older versions duplicated the
        // complete value under both TMDB and title keys, doubling encode/write
        // work for long-running shows.
        details[tmdbKey(tmdbShowId)] = cached
        let titleKey = legacyTitleKey(title)
        if !titleKey.isEmpty {
            details[titleKey] = nil
        }
        prune()
        persist()
    }

    private func detailKeys(tmdbShowId: Int, title: String) -> [String] {
        var keys = [tmdbKey(tmdbShowId)]
        let titleKey = legacyTitleKey(title)
        if !titleKey.isEmpty {
            keys.append(titleKey)
        }
        return keys
    }

    private func tmdbKey(_ tmdbShowId: Int) -> String {
        "tmdb:\(tmdbShowId)"
    }

    private func legacyTitleKey(_ title: String) -> String {
        let normalizedTitle = normalize(title)
        return normalizedTitle.isEmpty ? "" : "title:\(normalizedTitle)"
    }

    private func normalize(_ value: String) -> String {
        value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    private func prune() {
        let cutoff = Date().timeIntervalSince1970 - maxAge
        details = details.filter { $0.value.storedAt >= cutoff }
        guard details.count > maxEntries else { return }
        let kept = details
            .sorted { $0.value.storedAt > $1.value.storedAt }
            .prefix(maxEntries)
        details = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(details) else { return }
        UserDefaults.standard.set(data, forKey: detailsKey)
    }
}

final class AnimeMetadataService {
    static let shared = AnimeMetadataService()

    private let aniListService = AniListService.shared

    private init() {}

    func fetchAllAnimeCatalogs(
        limit: Int = 20,
        tmdbService: TMDBService
    ) async throws -> [AniListService.AniListCatalogKind: [TMDBSearchResult]] {
        try await aniListService.fetchAllAnimeCatalogs(limit: limit, tmdbService: tmdbService)
    }

    func fetchAiringSchedule(daysAhead: Int = 7, perPage: Int = 50) async throws -> [AniListAiringScheduleEntry] {
        try await aniListService.fetchAiringSchedule(daysAhead: daysAhead, perPage: perPage)
    }

    func fetchAnimeDetailsWithEpisodes(
        title: String,
        tmdbShowId: Int,
        tmdbService: TMDBService,
        tmdbShowPoster: String?,
        token: String?
    ) async throws -> AniListAnimeWithSeasons {
        try await aniListService.fetchAnimeDetailsWithEpisodes(
            title: title,
            tmdbShowId: tmdbShowId,
            tmdbService: tmdbService,
            tmdbShowPoster: tmdbShowPoster,
            token: token
        )
    }

    func fetchSpecialSearchEntries(
        tmdbShowId: Int,
        fallbackPosterURL: String?,
        baseAniListIds: [Int] = [],
        tmdbService: TMDBService
    ) async -> [AniListSpecialSearchEntry] {
        await aniListService.fetchSpecialSearchEntries(
            tmdbShowId: tmdbShowId,
            fallbackPosterURL: fallbackPosterURL,
            baseAniListIds: baseAniListIds,
            tmdbService: tmdbService
        )
    }

    func fetchParentTitleCandidates(
        forMediaId mediaId: Int,
        maxDepth: Int = 3
    ) async -> [(englishTitle: String?, romajiTitle: String?, nativeTitle: String?)] {
        await aniListService.fetchParentTitleCandidates(forMediaId: mediaId, maxDepth: maxDepth)
    }
}

/// Ensures AniList API calls are spaced out and adapts to AniList response headers.
/// Uses a slot-reservation pattern: each caller claims a future time slot BEFORE sleeping,
/// so concurrent callers queue up instead of bunching together.
actor AniListRateLimiter {
    static let shared = AniListRateLimiter()

    private var minInterval: TimeInterval
    private var nextAvailableTime: Date = .distantPast
    private var globalPauseUntil: Date = .distantPast

    init(minInterval: TimeInterval = 0.8) {
        self.minInterval = max(0, minInterval)
    }

    func waitForSlot() async throws {
        while true {
            try Task.checkCancellation()
            let now = Date()
            // Claim the next available slot, including any server-directed
            // pause already known when this caller enters the queue.
            let slotTime = max(max(now, nextAvailableTime), globalPauseUntil)
            nextAvailableTime = slotTime.addingTimeInterval(minInterval)

            let delay = slotTime.timeIntervalSince(now)
            if delay > 0.001 {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            try Task.checkCancellation()

            // Actors are reentrant while sleeping. A 429 from another request
            // may therefore extend the pause after this slot was reserved.
            // Requeue instead of allowing that stale reservation through.
            if globalPauseUntil > Date() {
                continue
            }
            return
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
            pause(until: resetDate)
        }
    }

    func pauseUntilRetryAfter(_ response: HTTPURLResponse) {
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
            .flatMap(TimeInterval.init) ?? 5
        pause(for: retryAfter.isFinite ? max(retryAfter, 1) : 5)
    }

    func pause(for interval: TimeInterval) {
        guard interval.isFinite, interval > 0 else { return }
        pause(until: Date().addingTimeInterval(interval))
    }

    private func pause(until date: Date) {
        globalPauseUntil = max(globalPauseUntil, date)
        nextAvailableTime = max(nextAvailableTime, date)
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

struct AniMapTMDBImportMatch {
    let tmdbResult: TMDBSearchResult
    let tmdbSeason: Int?
}

private struct AniMapLookupResult {
    let mappings: [AniMapMapping]
    let isComplete: Bool
}

private actor AniMapMappingService {
    static let shared = AniMapMappingService()

    private struct CacheEntry {
        let result: AniMapLookupResult
        let expiresAt: Date
    }

    private static let baseURL = URL(string: "https://animap.s0n1c.ca")!
    private var cacheByTMDBShowId: [Int: CacheEntry] = [:]
    private var cacheByAniListId: [Int: CacheEntry] = [:]
    private var inFlightByTMDBShowId: [Int: Task<AniMapLookupResult, Never>] = [:]
    private var inFlightByAniListId: [Int: Task<AniMapLookupResult, Never>] = [:]

    private let populatedTTL: TimeInterval = 24 * 60 * 60
    private let emptyTTL: TimeInterval = 15 * 60
    private let failureTTL: TimeInterval = 30

    func mappings(forTMDBShowId tmdbShowId: Int) async -> [AniMapMapping] {
        await mappingsResult(forTMDBShowId: tmdbShowId).mappings
    }

    func mappingsResult(forTMDBShowId tmdbShowId: Int) async -> AniMapLookupResult {
        guard tmdbShowId > 0, !Task.isCancelled else {
            return AniMapLookupResult(mappings: [], isComplete: false)
        }

        if let cached = cacheByTMDBShowId[tmdbShowId] {
            if cached.expiresAt > Date() {
                return cached.result
            }
            cacheByTMDBShowId[tmdbShowId] = nil
        }

        if let inFlight = inFlightByTMDBShowId[tmdbShowId] {
            return await inFlight.value
        }

        let task = Task {
            await Self.fetchMappings(value: tmdbShowId, mappingKey: "tmdb_show") { mapping in
                mapping.tmdbShowId == tmdbShowId
            }
        }
        inFlightByTMDBShowId[tmdbShowId] = task
        let result = await task.value
        inFlightByTMDBShowId[tmdbShowId] = nil
        cacheByTMDBShowId[tmdbShowId] = cacheEntry(for: result)
        return result
    }

    func specialMappings(forTMDBShowId tmdbShowId: Int) async -> [AniMapMapping] {
        await specialMappingsResult(forTMDBShowId: tmdbShowId).mappings
    }

    func specialMappingsResult(forTMDBShowId tmdbShowId: Int) async -> AniMapLookupResult {
        let result = await mappingsResult(forTMDBShowId: tmdbShowId)
        let mappings = result.mappings.filter { mapping in
            guard let type = mapping.mediaType?.uppercased() else {
                return false
            }
            return type == "SPECIAL" || type == "OVA"
        }
        return AniMapLookupResult(mappings: mappings, isComplete: result.isComplete)
    }

    func mappings(forAniListId anilistId: Int) async -> [AniMapMapping] {
        await mappingsResult(forAniListId: anilistId).mappings
    }

    func mappingsResult(forAniListId anilistId: Int) async -> AniMapLookupResult {
        guard anilistId > 0, !Task.isCancelled else {
            return AniMapLookupResult(mappings: [], isComplete: false)
        }

        if let cached = cacheByAniListId[anilistId] {
            if cached.expiresAt > Date() {
                return cached.result
            }
            cacheByAniListId[anilistId] = nil
        }

        if let inFlight = inFlightByAniListId[anilistId] {
            return await inFlight.value
        }

        let task = Task {
            await Self.fetchMappings(value: anilistId, mappingKey: "anilist") { mapping in
                mapping.anilistId == nil || mapping.anilistId == anilistId
            }
        }
        inFlightByAniListId[anilistId] = task
        let result = await task.value
        inFlightByAniListId[anilistId] = nil
        cacheByAniListId[anilistId] = cacheEntry(for: result)
        return result
    }

    private func cacheEntry(for result: AniMapLookupResult) -> CacheEntry {
        let ttl: TimeInterval
        if !result.isComplete {
            ttl = failureTTL
        } else if result.mappings.isEmpty {
            ttl = emptyTTL
        } else {
            ttl = populatedTTL
        }
        return CacheEntry(result: result, expiresAt: Date().addingTimeInterval(ttl))
    }

    private static func fetchMappings(
        value: Int,
        mappingKey: String,
        filter: @escaping (AniMapMapping) -> Bool
    ) async -> AniMapLookupResult {
        let mappingsURL = baseURL
            .appendingPathComponent("mappings")
            .appendingPathComponent(String(value))
        guard var components = URLComponents(url: mappingsURL, resolvingAgainstBaseURL: false) else {
            return AniMapLookupResult(mappings: [], isComplete: false)
        }
        components.queryItems = [URLQueryItem(name: "mapping_key", value: mappingKey)]
        guard let url = components.url else {
            return AniMapLookupResult(mappings: [], isComplete: false)
        }

        do {
            var request = URLRequest(url: url, timeoutInterval: 4.0)
            request.cachePolicy = .returnCacheDataElseLoad
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return AniMapLookupResult(mappings: [], isComplete: false)
            }

            let decoded = try JSONDecoder().decode(AniMapMappingList.self, from: data)
            return AniMapLookupResult(mappings: decoded.mappings.filter(filter), isComplete: true)
        } catch is CancellationError {
            return AniMapLookupResult(mappings: [], isComplete: false)
        } catch {
            Logger.shared.log(
                "AniMapMappingService: lookup failed key=\(mappingKey) value=\(value): \(error.localizedDescription)",
                type: "AniList"
            )
            return AniMapLookupResult(mappings: [], isComplete: false)
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

private struct AnimeDetailRequestKey: Hashable {
    let tmdbShowId: Int
    let languageCode: String
}

/// Shares one complete metadata traversal among concurrent consumers such as
/// Media Detail, Continue Watching, skip-data resolution and the player episode
/// browser. The underlying task is intentionally independent of any one
/// waiter: cancelling one screen cannot cancel or poison the result used by
/// another waiter. Cancelled waiters still reject the value before returning.
private actor AnimeDetailRequestCoordinator {
    static let shared = AnimeDetailRequestCoordinator()

    private var inFlight: [AnimeDetailRequestKey: Task<AniListAnimeWithSeasons, Error>] = [:]

    func value(
        for key: AnimeDetailRequestKey,
        operation: @escaping () async throws -> AniListAnimeWithSeasons
    ) async throws -> AniListAnimeWithSeasons {
        try Task.checkCancellation()

        if let existing = inFlight[key] {
            let value = try await existing.value
            try Task.checkCancellation()
            return value
        }

        let task = Task {
            try await operation()
        }
        inFlight[key] = task

        do {
            let value = try await task.value
            inFlight[key] = nil
            try Task.checkCancellation()
            return value
        } catch {
            inFlight[key] = nil
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            throw error
        }
    }
}

struct AniListSeasonIdentity: Equatable {
    let anilistId: Int
    let malId: Int?
    let kitsuId: Int?
    let title: String
    let englishTitle: String?
    let romajiTitle: String?
    let nativeTitle: String?
    let episodeCount: Int?
    let posterURL: String?
}

struct AnimeSeasonIdentityRequestKey: Hashable {
    let anilistId: Int
    let languageCode: String
}

actor AnimeSeasonIdentityRequestCoordinator {
    static let shared = AnimeSeasonIdentityRequestCoordinator()

    private struct CachedValue {
        let value: AniListSeasonIdentity
        let expiresAt: Date
    }

    private var cached: [AnimeSeasonIdentityRequestKey: CachedValue] = [:]
    private var pending: [AnimeSeasonIdentityRequestKey: [CheckedContinuation<AniListSeasonIdentity?, Never>]] = [:]
    private var flushTask: Task<Void, Never>?
    private let ttl: TimeInterval = 30 * 60

    func value(
        for key: AnimeSeasonIdentityRequestKey,
        operation: @escaping ([AnimeSeasonIdentityRequestKey]) async -> [AnimeSeasonIdentityRequestKey: AniListSeasonIdentity]
    ) async -> AniListSeasonIdentity? {
        guard !Task.isCancelled else { return nil }
        if let cachedValue = cached[key] {
            if cachedValue.expiresAt > Date() {
                return cachedValue.value
            }
            cached[key] = nil
        }

        return await withCheckedContinuation { continuation in
            pending[key, default: []].append(continuation)
            guard flushTask == nil else { return }
            flushTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 25_000_000)
                guard !Task.isCancelled else { return }
                await self?.flush(operation: operation)
            }
        }
    }

    private func flush(
        operation: @escaping ([AnimeSeasonIdentityRequestKey]) async -> [AnimeSeasonIdentityRequestKey: AniListSeasonIdentity]
    ) async {
        let waiters = pending
        pending = [:]
        flushTask = nil
        guard !waiters.isEmpty else { return }

        let values = await operation(Array(waiters.keys))
        let expiresAt = Date().addingTimeInterval(ttl)
        for (key, continuations) in waiters {
            let value = values[key]
            if let value {
                cached[key] = CachedValue(value: value, expiresAt: expiresAt)
            }
            continuations.forEach { $0.resume(returning: value) }
        }
    }
}

struct AniListCatalogPageRequest: Equatable {
    static let maximumPageSize = 50

    let page: Int
    let perPage: Int

    init(page: Int, requestedPageSize: Int) {
        self.page = max(page, 1)
        self.perPage = min(max(requestedPageSize, 1), Self.maximumPageSize)
    }

    var graphQLArguments: String {
        "page: \(page), perPage: \(perPage)"
    }
}

final class AniListService {
    static let shared = AniListService()

    private let graphQLEndpoint = URL(string: "https://graphql.anilist.co")!
    private var preferredLanguageCode: String {
        let raw = UserDefaults.standard.string(forKey: "tmdbLanguage") ?? "en-US"
        return raw.split(separator: "-").first.map(String.init) ?? "en"
    }
    private var tmdbMatchCacheLanguage: String {
        UserDefaults.standard.string(forKey: "tmdbLanguage") ?? "en-US"
    }

    // MARK: - In-Memory Cache for anime details (avoids re-fetching on back-navigation)
    private let animeDetailsCache = NSCache<NSString, AniListAnimeWithSeasonsWrapper>()
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

    private final class SpecialEntriesCacheWrapper {
        let entries: [AniListSpecialSearchEntry]
        let timestamp = Date()

        init(entries: [AniListSpecialSearchEntry]) {
            self.entries = entries
        }
    }

    private struct SpecialEntriesFetchResult {
        let entries: [AniListSpecialSearchEntry]
        let isComplete: Bool
    }

    private let specialEntriesCache = NSCache<NSString, SpecialEntriesCacheWrapper>()
    private let specialEntriesCacheTTL: TimeInterval = 15 * 60

    enum AniListCatalogKind: CaseIterable, Hashable {
        case trending
        case popular
        case topRated
        case airing
        case upcoming

        fileprivate var queryAlias: String {
            switch self {
            case .trending: return "trending"
            case .popular: return "popular"
            case .topRated: return "topRated"
            case .airing: return "airing"
            case .upcoming: return "upcoming"
            }
        }

        fileprivate var querySort: String {
            switch self {
            case .trending: return "TRENDING_DESC"
            case .popular, .airing, .upcoming: return "POPULARITY_DESC"
            case .topRated: return "SCORE_DESC"
            }
        }

        fileprivate var queryStatus: String? {
            switch self {
            case .airing: return "RELEASING"
            case .upcoming: return "NOT_YET_RELEASED"
            case .trending, .popular, .topRated: return nil
            }
        }
    }

    struct CatalogQueryPlan {
        let orderedKinds: [AniListCatalogKind]
        let limit: Int

        init(kinds: Set<AniListCatalogKind>, requestedLimit: Int) {
            orderedKinds = AniListCatalogKind.allCases.filter(kinds.contains)
            limit = min(max(requestedLimit, 1), AniListCatalogPageRequest.maximumPageSize)
        }

        var query: String {
            let selections = orderedKinds.map { kind in
                let statusClause = kind.queryStatus.map { ", status: \($0)" } ?? ""
                return """
                    \(kind.queryAlias): Page(perPage: \(limit)) {
                        media(type: ANIME, sort: [\(kind.querySort)]\(statusClause)) {
                            id
                            title { romaji english native }
                            episodes status seasonYear season
                            coverImage { large medium }
                            format
                        }
                    }
                """
            }.joined(separator: "\n")

            return """
            query {
            \(selections)
            }
            """
        }
    }

    // MARK: - Catalog Fetching

    /// Fetch all anime catalogs in a single AniList GraphQL query using aliases.
    /// Returns a dictionary keyed by AniListCatalogKind.
    func fetchAllAnimeCatalogs(
        limit: Int = 20,
        tmdbService: TMDBService
    ) async throws -> [AniListCatalogKind: [TMDBSearchResult]] {
        try await fetchAnimeCatalogs(
            kinds: Set(AniListCatalogKind.allCases),
            limit: limit,
            tmdbService: tmdbService
        )
    }

    /// Fetches only the requested Home anime rows while retaining a single aliased GraphQL call.
    func fetchAnimeCatalogs(
        kinds: Set<AniListCatalogKind>,
        limit: Int = 20,
        tmdbService: TMDBService
    ) async throws -> [AniListCatalogKind: [TMDBSearchResult]] {
        guard !kinds.isEmpty else { return [:] }

        do {
            let result = try await fetchAnimeCatalogsFromAniList(
                kinds: kinds,
                limit: limit,
                tmdbService: tmdbService
            )
            AnimeProviderHealthCenter.shared.recordAniListSuccess()
            return result
        } catch {
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            let reason = AnimeProviderHealthCenter.shared.recordAniListFailure(error)
            guard AnimeProviderHealthCenter.shared.shouldUseMALFallback(for: reason) else { throw error }
            AnimeProviderHealthCenter.shared.notifyMALFallbackIfNeeded(reason: "catalogs-\(reason.rawValue)")
            do {
                let fallback = try await MALMetadataService.shared.fetchAllAnimeCatalogs(
                    limit: limit,
                    tmdbService: tmdbService
                )
                return fallback.filter { kinds.contains($0.key) }
            } catch {
                AnimeProviderHealthCenter.shared.recordMALFailure(error)
                throw error
            }
        }
    }

    private func fetchAnimeCatalogsFromAniList(
        kinds: Set<AniListCatalogKind>,
        limit: Int = 20,
        tmdbService: TMDBService
    ) async throws -> [AniListCatalogKind: [TMDBSearchResult]] {
        let plan = CatalogQueryPlan(kinds: kinds, requestedLimit: limit)

        struct PageData: Codable { let media: [AniListAnime] }
        struct CatalogsResponse: Codable {
            let data: [String: PageData]
        }

        let data = try await executeGraphQLQuery(plan.query, token: nil)
        let decoded = try JSONDecoder().decode(CatalogsResponse.self, from: data)

        var allAnime: [AniListAnime] = []
        let lists: [(AniListCatalogKind, [AniListAnime])] = try plan.orderedKinds.map { kind in
            guard let page = decoded.data[kind.queryAlias] else {
                throw NSError(
                    domain: "AniList",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Missing catalog response for \(kind.queryAlias)"]
                )
            }
            return (kind, page.media)
        }
        var seenIds = Set<Int>()
        for (_, animeList) in lists {
            for anime in animeList {
                if seenIds.insert(anime.id).inserted {
                    allAnime.append(anime)
                }
            }
        }

        let tmdbMap = await batchMapAniListToTMDB(allAnime, tmdbService: tmdbService)

        var result: [AniListCatalogKind: [TMDBSearchResult]] = [:]
        for (kind, animeList) in lists {
            result[kind] = animeList.compactMap { tmdbMap[$0.id] }
        }

        Logger.shared.log(
            "AniListService: Fetched \(lists.count) requested anime catalogs in 1 query (\(allAnime.count) unique anime)",
            type: "AniList"
        )
        return result
    }

    /// Fetch a single anime catalog (kept for backward compatibility).
    func fetchAnimeCatalog(
        _ kind: AniListCatalogKind,
        page: Int = 1,
        limit: Int = 20,
        tmdbService: TMDBService
    ) async throws -> [TMDBSearchResult] {
        let pageRequest = AniListCatalogPageRequest(page: page, requestedPageSize: limit)
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
            Page(\(pageRequest.graphQLArguments)) {
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
        let tmdbMap = await batchMapAniListToTMDB(animeList, tmdbService: tmdbService)
        return animeList.compactMap { tmdbMap[$0.id] }
    }

    // MARK: - Airing Schedule

    /// Fetch upcoming airing episodes for the next `daysAhead` days (default 7).
    func fetchAiringSchedule(daysAhead: Int = 7, perPage: Int = 50) async throws -> [AniListAiringScheduleEntry] {
        try await fetchAiringScheduleResult(daysAhead: daysAhead, perPage: perPage).entries
    }

    func fetchAiringScheduleResult(
        daysAhead: Int = 7,
        perPage: Int = 50
    ) async throws -> AnimeAiringScheduleResult {
        do {
            let result = try await fetchAiringScheduleFromAniList(daysAhead: daysAhead, perPage: perPage)
            AnimeProviderHealthCenter.shared.recordAniListSuccess()
            return result
        } catch {
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            let reason = AnimeProviderHealthCenter.shared.recordAniListFailure(error)
            guard AnimeProviderHealthCenter.shared.shouldUseMALFallback(for: reason) else { throw error }
            AnimeProviderHealthCenter.shared.notifyMALFallbackIfNeeded(reason: "schedule-\(reason.rawValue)")
            do {
                let fallback = try await MALMetadataService.shared.fetchAiringSchedule(daysAhead: daysAhead, perPage: perPage)
                return AnimeAiringScheduleResult(entries: fallback, isAuthoritativeForNotifications: false)
            } catch {
                AnimeProviderHealthCenter.shared.recordMALFailure(error)
                throw error
            }
        }
    }

    private func fetchAiringScheduleFromAniList(
        daysAhead: Int = 7,
        perPage: Int = 50
    ) async throws -> AnimeAiringScheduleResult {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let today = calendar.startOfDay(for: Date())
        // `daysAhead` is a count including today, matching ScheduleViewModel's
        // configured visible buckets and the Western Trakt/TVMaze requests.
        let upperDay = calendar.date(byAdding: .day, value: max(daysAhead, 1), to: today) ?? today

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
        // Thirty days can exceed 500 airing rows during a busy season. Keep a
        // hard safety cap, but do not silently mark a capped result authoritative.
        let maxPages = 20

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
                            isAdult
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

        let entries = allSchedules
            .filter { $0.media.isAdult != true }
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
                    format: schedule.media.format,
                    hasKnownAiringTime: true
                )
            }
            .filter { entry in
                entry.airingAt >= start && entry.airingAt < end
            }
        return AnimeAiringScheduleResult(
            entries: entries,
            isAuthoritativeForNotifications: !hasNextPage
        )
    }

    /// Resolves one already-known AniList season without traversing its relation
    /// graph or fetching every TMDB season. Continue Watching uses this compact
    /// path to enrich card-local search identity without competing with Home's
    /// catalog assembly.
    func fetchAnimeSeasonIdentity(
        anilistId: Int,
        tmdbShowId: Int? = nil,
        title: String? = nil
    ) async -> AniListSeasonIdentity? {
        guard anilistId > 0 else { return nil }
        let languageCode = preferredLanguageCode

        if let tmdbShowId,
           let cached = animeDetailsCache.object(forKey: animeDetailsCacheKey(tmdbShowId: tmdbShowId))?.value,
           let identity = seasonIdentity(anilistId: anilistId, from: cached) {
            return identity
        }

        if let tmdbShowId, let title,
           let cached = await AnimeIdentityCache.shared.cachedFreshDetails(
               tmdbShowId: tmdbShowId,
               title: title,
               languageCode: languageCode
           ),
           let identity = seasonIdentity(anilistId: anilistId, from: cached) {
            animeDetailsCache.setObject(
                AniListAnimeWithSeasonsWrapper(cached),
                forKey: animeDetailsCacheKey(tmdbShowId: tmdbShowId)
            )
            return identity
        }

        let key = AnimeSeasonIdentityRequestKey(
            anilistId: anilistId,
            languageCode: languageCode
        )

        return await AnimeSeasonIdentityRequestCoordinator.shared.value(for: key) { [self] keys in
            await fetchAnimeSeasonIdentities(keys: keys)
        }
    }

    private func seasonIdentity(
        anilistId: Int,
        from anime: AniListAnimeWithSeasons
    ) -> AniListSeasonIdentity? {
        guard let season = anime.seasons.first(where: { $0.anilistId == anilistId }) else {
            return nil
        }
        return AniListSeasonIdentity(
            anilistId: season.anilistId,
            malId: season.anilistId == anime.id ? anime.malId : nil,
            kitsuId: season.kitsuId,
            title: season.title,
            englishTitle: season.englishTitle,
            romajiTitle: season.romajiTitle,
            nativeTitle: season.nativeTitle,
            episodeCount: season.episodes.count,
            posterURL: season.posterUrl
        )
    }

    private func fetchAnimeSeasonIdentities(
        keys: [AnimeSeasonIdentityRequestKey]
    ) async -> [AnimeSeasonIdentityRequestKey: AniListSeasonIdentity] {
        guard !keys.isEmpty, !Task.isCancelled else { return [:] }
        let uniqueIDs = Array(Set(keys.map(\.anilistId))).sorted()
        let aliases = uniqueIDs.enumerated().map { index, id in
            """
            m\(index): Media(id: \(id), type: ANIME) {
                id
                idMal
                externalLinks { site siteId url }
                title { romaji english native }
                episodes
                coverImage { large medium }
            }
            """
        }.joined(separator: "\n")
        let query = "query { \(aliases) }"

        do {
            let data = try await executeGraphQLQuery(query, token: nil)
            guard !Task.isCancelled,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataDictionary = json["data"] as? [String: Any] else {
                return [:]
            }

            var animeByID: [Int: AniListAnime] = [:]
            for (index, id) in uniqueIDs.enumerated() {
                let alias = "m\(index)"
                guard let mediaJSON = dataDictionary[alias],
                      !(mediaJSON is NSNull),
                      let mediaData = try? JSONSerialization.data(withJSONObject: mediaJSON),
                      let anime = try? JSONDecoder().decode(AniListAnime.self, from: mediaData) else {
                    continue
                }
                animeByID[id] = anime
            }

            AnimeProviderHealthCenter.shared.recordAniListSuccess()
            return keys.reduce(into: [:]) { result, key in
                guard let anime = animeByID[key.anilistId] else { return }
                result[key] = AniListSeasonIdentity(
                    anilistId: anime.id,
                    malId: anime.idMal,
                    kitsuId: anime.kitsuId,
                    title: AniListTitlePicker.title(
                        from: anime.title,
                        preferredLanguageCode: key.languageCode
                    ),
                    englishTitle: anime.title.english.map(AniListTitlePicker.cleanedTitle),
                    romajiTitle: anime.title.romaji.map(AniListTitlePicker.cleanedTitle),
                    nativeTitle: anime.title.native.map(AniListTitlePicker.cleanedTitle),
                    episodeCount: anime.episodes,
                    posterURL: anime.coverImage?.large ?? anime.coverImage?.medium
                )
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                return [:]
            }
            AnimeProviderHealthCenter.shared.recordAniListFailure(error)
            Logger.shared.log(
                "AniListService: exact season identity batch failed count=\(keys.count): \(error.localizedDescription)",
                type: "AniList"
            )
            return [:]
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
        let memoryCacheKey = animeDetailsCacheKey(tmdbShowId: tmdbShowId)
        if let cached = animeDetailsCache.object(forKey: memoryCacheKey),
           Date().timeIntervalSince(cached.timestamp) < animeCacheTTL {
            return cached.value
        }
        let key = AnimeDetailRequestKey(
            tmdbShowId: tmdbShowId,
            languageCode: preferredLanguageCode
        )
        return try await AnimeDetailRequestCoordinator.shared.value(for: key) { [self] in
            try await fetchAnimeDetailsWithEpisodesUncoalesced(
                title: title,
                tmdbShowId: tmdbShowId,
                tmdbService: tmdbService,
                tmdbShowPoster: tmdbShowPoster,
                token: token
            )
        }
    }

    private func fetchAnimeDetailsWithEpisodesUncoalesced(
        title: String,
        tmdbShowId: Int,
        tmdbService: TMDBService,
        tmdbShowPoster: String?,
        token: String?
    ) async throws -> AniListAnimeWithSeasons {
        if let cached = await AnimeIdentityCache.shared.cachedFreshDetails(
            tmdbShowId: tmdbShowId,
            title: title,
            languageCode: preferredLanguageCode
        ) {
            animeDetailsCache.setObject(
                AniListAnimeWithSeasonsWrapper(cached),
                forKey: animeDetailsCacheKey(tmdbShowId: tmdbShowId)
            )
            return cached
        }

        do {
            let result = try await fetchAnimeDetailsWithEpisodesFromAniList(
                title: title,
                tmdbShowId: tmdbShowId,
                tmdbService: tmdbService,
                tmdbShowPoster: tmdbShowPoster,
                token: token
            )
            AnimeProviderHealthCenter.shared.recordAniListSuccess()
            await AnimeIdentityCache.shared.storeAniListDetails(
                result,
                tmdbShowId: tmdbShowId,
                title: title,
                languageCode: preferredLanguageCode
            )
            return result
        } catch {
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            let reason = AnimeProviderHealthCenter.shared.recordAniListFailure(error)
            if let cached = await AnimeIdentityCache.shared.cachedDetails(
                tmdbShowId: tmdbShowId,
                title: title,
                languageCode: preferredLanguageCode
            ) {
                if AnimeProviderHealthCenter.shared.shouldUseMALFallback(for: reason) {
                    AnimeProviderHealthCenter.shared.notifyMALFallbackIfNeeded(reason: "details-cache-\(reason.rawValue)")
                }
                return cached
            }
            guard AnimeProviderHealthCenter.shared.shouldUseMALFallback(for: reason) else { throw error }
            AnimeProviderHealthCenter.shared.notifyMALFallbackIfNeeded(reason: "details-\(reason.rawValue)")
            do {
                return try await MALMetadataService.shared.fetchAnimeDetailsWithEpisodes(
                    title: title,
                    tmdbShowId: tmdbShowId,
                    tmdbService: tmdbService,
                    tmdbShowPoster: tmdbShowPoster
                )
            } catch {
                AnimeProviderHealthCenter.shared.recordMALFailure(error)
                throw error
            }
        }
    }

    func preferredAnimeRating(
        title: String,
        tmdbShowId: Int,
        tmdbShowDetail: TMDBTVShowWithSeasons,
        tmdbService: TMDBService,
        animeData: AniListAnimeWithSeasons?
    ) async -> AnimeMetadataRating? {
        if let existing = animeData?.rating, existing.source == .myAnimeList {
            Logger.shared.log("AnimeRating: using MAL rating from metadata value=\(String(format: "%.1f", existing.value)) tmdbId=\(tmdbShowId)", type: "AniList")
            return existing
        }

        if let malId = animeData?.malId {
            do {
                if let rating = try await MALMetadataService.shared.fetchAnimeRating(id: malId) {
                    Logger.shared.log("AnimeRating: using MAL rating by id=\(malId) value=\(String(format: "%.1f", rating.value)) tmdbId=\(tmdbShowId)", type: "AniList")
                    return rating
                }
            } catch {
                Logger.shared.log("AnimeRating: MAL rating by id failed malId=\(malId) tmdbId=\(tmdbShowId) error=\(error.localizedDescription)", type: "AniList")
            }
        }

        do {
            if let rating = try await MALMetadataService.shared.fetchAnimeRating(
                title: title,
                tmdbShowId: tmdbShowId,
                tmdbShow: tmdbShowDetail,
                tmdbService: tmdbService
            ) {
                Logger.shared.log("AnimeRating: using MAL rating by search value=\(String(format: "%.1f", rating.value)) tmdbId=\(tmdbShowId)", type: "AniList")
                return rating
            }
        } catch {
            Logger.shared.log("AnimeRating: MAL rating search failed tmdbId=\(tmdbShowId) error=\(error.localizedDescription)", type: "AniList")
        }

        if let existing = animeData?.rating,
           existing.source == .aniList,
           !AnimeProviderHealthCenter.shared.isAniListTemporarilyUnavailable {
            Logger.shared.log("AnimeRating: using AniList rating value=\(String(format: "%.1f", existing.value)) tmdbId=\(tmdbShowId)", type: "AniList")
            return existing
        } else if animeData?.rating?.source == .aniList {
            Logger.shared.log("AnimeRating: skipping AniList rating because AniList is currently marked unavailable tmdbId=\(tmdbShowId)", type: "AniList")
        }

        guard tmdbShowDetail.voteAverage > 0 else {
            Logger.shared.log("AnimeRating: no MAL/AniList/TMDB rating available tmdbId=\(tmdbShowId)", type: "AniList")
            return nil
        }

        let tmdbRating = AnimeMetadataRating(value: tmdbShowDetail.voteAverage, source: .tmdb)
        Logger.shared.log("AnimeRating: using TMDB fallback value=\(String(format: "%.1f", tmdbRating.value)) tmdbId=\(tmdbShowId)", type: "AniList")
        return tmdbRating
    }

    private func aniListRating(from averageScore: Int?) -> AnimeMetadataRating? {
        guard let averageScore, averageScore > 0 else { return nil }
        let value = min(max(Double(averageScore) / 10.0, 0), 10)
        return AnimeMetadataRating(value: value, source: .aniList)
    }

    private func fetchTMDBShowForAnimeTraversal(
        tmdbShowId: Int,
        tmdbService: TMDBService
    ) async -> TMDBTVShowWithSeasons? {
        do {
            return try await tmdbService.getTVShowWithSeasons(id: tmdbShowId)
        } catch {
            if !Task.isCancelled {
                Logger.shared.log(
                    "AniListService: Failed to prefetch TMDB show details: \(error.localizedDescription)",
                    type: "TMDB"
                )
            }
            return nil
        }
    }

    private func fetchTMDBEpisodesByAbsolute(
        tmdbShowId: Int,
        tvShowDetail: TMDBTVShowWithSeasons?,
        tmdbService: TMDBService
    ) async -> [Int: TMDBEpisode] {
        var episodesByAbsolute: [Int: TMDBEpisode] = [:]

        if let tvShowDetail {
            let realSeasons = tvShowDetail.seasons
                .filter { $0.seasonNumber > 0 }
                .sorted { $0.seasonNumber < $1.seasonNumber }
            var seasonResults: [(seasonNumber: Int, episodes: [TMDBEpisode])] = []

            await withTaskGroup(of: (Int, [TMDBEpisode]?).self) { group in
                for season in realSeasons {
                    group.addTask {
                        guard !Task.isCancelled else { return (season.seasonNumber, nil) }
                        do {
                            let detail = try await tmdbService.getSeasonDetails(
                                tvShowId: tmdbShowId,
                                seasonNumber: season.seasonNumber
                            )
                            return (season.seasonNumber, detail.episodes)
                        } catch {
                            Logger.shared.log(
                                "AniListService: Failed to fetch TMDB season \(season.seasonNumber): \(error.localizedDescription)",
                                type: "AniList"
                            )
                            return (season.seasonNumber, nil)
                        }
                    }
                }

                for await (seasonNumber, episodes) in group {
                    if Task.isCancelled {
                        group.cancelAll()
                        break
                    }
                    if let episodes {
                        seasonResults.append((seasonNumber, episodes))
                    }
                }
            }

            var absoluteIndex = 1
            for (seasonNumber, episodes) in seasonResults.sorted(by: { $0.seasonNumber < $1.seasonNumber }) {
                let sortedEpisodes = episodes.sorted { $0.episodeNumber < $1.episodeNumber }
                Logger.shared.log(
                    "AniListService: TMDB season \(seasonNumber) returned \(sortedEpisodes.count) episodes",
                    type: "AniList"
                )
                for episode in sortedEpisodes {
                    episodesByAbsolute[absoluteIndex] = episode
                    absoluteIndex += 1
                }
            }
        }

        guard episodesByAbsolute.isEmpty, !Task.isCancelled else {
            return episodesByAbsolute
        }

        Logger.shared.log(
            "AniListService: No TMDB episodes loaded; attempting direct season fetch",
            type: "AniList"
        )
        var absoluteIndex = 1
        var seasonNumber = 1
        while !Task.isCancelled {
            do {
                let seasonDetail = try await tmdbService.getSeasonDetails(
                    tvShowId: tmdbShowId,
                    seasonNumber: seasonNumber
                )
                guard !seasonDetail.episodes.isEmpty else {
                    Logger.shared.log(
                        "AniListService: Fallback found empty season \(seasonNumber), stopping",
                        type: "AniList"
                    )
                    break
                }
                for episode in seasonDetail.episodes.sorted(by: { $0.episodeNumber < $1.episodeNumber }) {
                    episodesByAbsolute[absoluteIndex] = episode
                    absoluteIndex += 1
                }
                Logger.shared.log(
                    "AniListService: Fallback fetched season \(seasonNumber): \(seasonDetail.episodes.count) episodes",
                    type: "AniList"
                )
                seasonNumber += 1
            } catch {
                Logger.shared.log(
                    "AniListService: Fallback stopped at season \(seasonNumber) (no more seasons found)",
                    type: "AniList"
                )
                break
            }
        }
        return episodesByAbsolute
    }

    private struct AniMapSeasonSeedPlan {
        let ids: [Int]
    }

    private func aniMapSeasonSeedPlan(forTMDBShowId tmdbShowId: Int, limit: Int = 12) async -> AniMapSeasonSeedPlan {
        let lookup = await AniMapMappingService.shared.mappingsResult(forTMDBShowId: tmdbShowId)
        guard !lookup.mappings.isEmpty else {
            return AniMapSeasonSeedPlan(ids: [])
        }

        var seen = Set<Int>()
        let ids = lookup.mappings
            .filter { mapping in
                guard mapping.tmdbShowId == tmdbShowId else { return false }
                guard let mediaType = mapping.mediaType?.uppercased() else { return true }
                return mediaType == "TV" || mediaType == "TV_SHORT" || mediaType == "ONA"
            }
            .sorted { lhs, rhs in
                let lhsScore = aniMapCandidateScore(lhs)
                let rhsScore = aniMapCandidateScore(rhs)
                if lhsScore != rhsScore {
                    return lhsScore < rhsScore
                }
                return (lhs.anilistId ?? Int.max) < (rhs.anilistId ?? Int.max)
            }
            .compactMap { mapping -> Int? in
                guard let id = mapping.anilistId, id > 0, seen.insert(id).inserted else {
                    return nil
                }
                return id
            }

        return AniMapSeasonSeedPlan(ids: Array(ids.prefix(limit)))
    }

    private func aniMapCandidateScore(_ mapping: AniMapMapping) -> Int {
        let typeScore: Int
        switch mapping.mediaType?.uppercased() {
        case "TV", "TV_SHORT", "ONA":
            typeScore = 0
        case nil:
            typeScore = 1
        case "MOVIE":
            typeScore = 2
        case "SPECIAL", "OVA":
            typeScore = 4
        default:
            typeScore = 3
        }

        let seasonScore = mapping.tmdbSeason.map { min(max($0, 0), 99) } ?? 50
        return typeScore * 1_000 + seasonScore
    }

    private func isNormalAniListSeasonCandidate(_ anime: AniListAnime) -> Bool {
        if anime.status == "NOT_YET_RELEASED" {
            return false
        }
        if let format = anime.format, !["TV", "TV_SHORT", "ONA"].contains(format) {
            return false
        }
        let title = AniListTitlePicker.title(from: anime.title, preferredLanguageCode: preferredLanguageCode).lowercased()
        return !["recap", "summary", "music", "trailer", "pv", "cm"].contains { title.contains($0) }
    }

    private func aniListSeasonOrdinal(_ season: String?) -> Int {
        switch season?.uppercased() {
        case "WINTER": return 0
        case "SPRING": return 1
        case "SUMMER": return 2
        case "FALL": return 3
        default: return 4
        }
    }

    private func fetchAnimeDetailsWithEpisodesFromAniList(
        title: String,
        tmdbShowId: Int,
        tmdbService: TMDBService,
        tmdbShowPoster: String?,
        token: String?
    ) async throws -> AniListAnimeWithSeasons {
        try Task.checkCancellation()
        // Check in-memory cache first
        let cacheKey = animeDetailsCacheKey(tmdbShowId: tmdbShowId)
        if let cached = animeDetailsCache.object(forKey: cacheKey),
           Date().timeIntervalSince(cached.timestamp) < animeCacheTTL {
            Logger.shared.log("AniListService: Cache HIT for tmdbId=\(tmdbShowId)", type: "AniList")
            return cached.value
        }

        Logger.shared.log("AniListService: fetchAnimeDetailsWithEpisodes START for '\(title)' tmdbId=\(tmdbShowId)", type: "AniList")
        async let tvShowDetailTask = fetchTMDBShowForAnimeTraversal(
            tmdbShowId: tmdbShowId,
            tmdbService: tmdbService
        )
        var candidates: [AniListAnime] = []
        let aniMapSeedPlan = await aniMapSeasonSeedPlan(forTMDBShowId: tmdbShowId)
        let aniMapCandidateIds = aniMapSeedPlan.ids
        try Task.checkCancellation()
        if !aniMapCandidateIds.isEmpty {
            let nodeResult = await batchFetchAniListNodesResult(ids: aniMapCandidateIds)
            try Task.checkCancellation()
            candidates = aniMapCandidateIds.compactMap { nodeResult.nodes[$0] }
            let hydratedCandidateCount = candidates.count
            let normalSeasonCandidates = candidates.filter { isNormalAniListSeasonCandidate($0) }
            if !candidates.isEmpty, normalSeasonCandidates.isEmpty {
                Logger.shared.log("AniListService: AniMap hydrated \(candidates.count) nodes for tmdbId=\(tmdbShowId), but none looked like normal anime seasons; falling back to title search", type: "AniList")
                candidates = []
            } else if !normalSeasonCandidates.isEmpty {
                candidates = normalSeasonCandidates
            }
            if candidates.isEmpty, hydratedCandidateCount == 0 {
                Logger.shared.log("AniListService: AniMap returned \(aniMapCandidateIds.count) mapped AniList IDs for tmdbId=\(tmdbShowId), but none hydrated from AniList", type: "AniList")
            } else if !candidates.isEmpty {
                Logger.shared.log("AniListService: AniMap seeded \(candidates.count)/\(aniMapCandidateIds.count) AniList candidates for tmdbId=\(tmdbShowId)", type: "AniList")
            }
        }

        if candidates.isEmpty {
        // Query AniList for anime structure + sequels + coverImage (multiple candidates for better matching)
        let query = """
        query {
            Page(perPage: 6) {
                media(search: "\(title.replacingOccurrences(of: "\"", with: "\\\""))", type: ANIME, sort: POPULARITY_DESC) {
                    id
                    idMal
                    externalLinks { site siteId url }
                    averageScore
                    genres
                    tags { name rank isMediaSpoiler }
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
                                idMal
                                externalLinks { site siteId url }
                                averageScore
                                genres
                                tags { name rank isMediaSpoiler }
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
                                            idMal
                                            externalLinks { site siteId url }
                                            averageScore
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
        candidates = result.data.Page.media
        }
        Logger.shared.log("AniListService: AniList returned \(candidates.count) candidates for '\(title)'", type: "AniList")
        guard !candidates.isEmpty else {
            Logger.shared.log("AniListService: NO candidates from AniList for '\(title)' - throwing", type: "Error")
            throw NSError(domain: "AniListService", code: -1, userInfo: [NSLocalizedDescriptionKey: "AniList did not return any matches for \(title)"])
        }

        // TMDB show lookup started alongside AniMap/AniList discovery above.
        let tvShowDetail = await tvShowDetailTask
        async let tmdbEpisodesTask = fetchTMDBEpisodesByAbsolute(
            tmdbShowId: tmdbShowId,
            tvShowDetail: tvShowDetail,
            tmdbService: tmdbService
        )

        var anime = pickBestAniListMatch(from: candidates, tmdbShow: tvShowDetail)

        // If the best match looks suspicious (e.g.
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
        // AniMap is a high-confidence identity source, not proof of the complete
        // cour/season graph. It may select the root above, but only the normal AniList
        // relation traversal (and guarded orphan recovery below) may add seasons.
        var queue: [AniListAnime] = [anime]
        var seenIds = Set<Int>([anime.id])

        while !queue.isEmpty {
            try Task.checkCancellation()
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
                    if edge.node.status == "NOT_YET_RELEASED" {
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
                try Task.checkCancellation()
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

        // Fix B: If BFS found significantly fewer episodes than TMDB has, search AniList for orphaned entries Handles
        // disconnected.
        if let tvShowDetail, !allAnimeToProcess.isEmpty, let tmdbTotalEps = tvShowDetail.numberOfEpisodes, tmdbTotalEps > 0 {
            let anilistTotalEps = allAnimeToProcess.reduce(0) { $0 + ($1.anime.episodes ?? 0) }
            if anilistTotalEps < Int(Double(tmdbTotalEps) * 0.75) {
                try Task.checkCancellation()
                Logger.shared.log("AniListService: BFS found \(anilistTotalEps) episodes but TMDB has \(tmdbTotalEps) \u{2014} searching for orphaned entries", type: "AniList")
                let searchTitle = tvShowDetail.name
                let orphanQuery = """
                query {
                    Page(perPage: 20) {
                        media(search: "\(searchTitle.replacingOccurrences(of: "\"", with: "\\\""))", type: ANIME, sort: POPULARITY_DESC) {
                            id
                            idMal
                            externalLinks { site siteId url }
                            averageScore
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

                        // Skip spinoffs/alternatives - only want direct continuations
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

                        // BFS from orphan to discover its sequels (e.g. SAO Alicization to War of Underworld)
                        var orphanQueue: [AniListAnime] = [orphanWithRelations]
                        while !orphanQueue.isEmpty {
                            try Task.checkCancellation()
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
                                    if edge.node.status == "NOT_YET_RELEASED" { continue }
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
                                try Task.checkCancellation()
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
            let lhsSeason = aniListSeasonOrdinal(lhs.anime.season)
            let rhsSeason = aniListSeasonOrdinal(rhs.anime.season)
            if lhsSeason != rhsSeason { return lhsSeason < rhsSeason }
            return lhs.anime.id < rhs.anime.id
        }

        // Fix C: Prune entries that belong to a separate TMDB show.
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

        // This hydration began as soon as TMDB show metadata was available and ran
        // concurrently with AniList relation/orphan discovery.
        let tmdbEpisodesByAbsolute = await tmdbEpisodesTask
        try Task.checkCancellation()
        
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
                kitsuId: currentAnime.kitsuId,
                title: seasonTitle,
                englishTitle: currentAnime.title.english.map(AniListTitlePicker.cleanedTitle),
                romajiTitle: currentAnime.title.romaji.map(AniListTitlePicker.cleanedTitle),
                nativeTitle: currentAnime.title.native.map(AniListTitlePicker.cleanedTitle),
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
            malId: anime.idMal,
            title: title,
            genres: anime.detailGenreLabels,
            seasons: seasons,
            totalEpisodes: totalEpisodes,
            status: anime.status ?? "UNKNOWN",
            rating: aniListRating(from: anime.averageScore)
        )

        try Task.checkCancellation()
        // Cache the result for fast back-navigation
        animeDetailsCache.setObject(
            AniListAnimeWithSeasonsWrapper(animeWithSeasons),
            forKey: animeDetailsCacheKey(tmdbShowId: tmdbShowId)
        )
        
        return animeWithSeasons
    }

    private func animeDetailsCacheKey(tmdbShowId: Int) -> NSString {
        "\(tmdbShowId)|\(preferredLanguageCode)" as NSString
    }

    func fetchSpecialSearchEntries(
        tmdbShowId: Int,
        fallbackPosterURL: String?,
        baseAniListIds: [Int] = [],
        tmdbService: TMDBService
    ) async -> [AniListSpecialSearchEntry] {
        let cacheKey = specialEntriesCacheKey(
            tmdbShowId: tmdbShowId,
            baseAniListIds: baseAniListIds,
            fallbackPosterURL: fallbackPosterURL
        )
        if let cached = specialEntriesCache.object(forKey: cacheKey as NSString),
           Date().timeIntervalSince(cached.timestamp) < specialEntriesCacheTTL {
            return cached.entries
        }

        let aniListResult = await fetchSpecialSearchEntriesFromAniList(
            tmdbShowId: tmdbShowId,
            fallbackPosterURL: fallbackPosterURL,
            baseAniListIds: baseAniListIds,
            tmdbService: tmdbService
        )
        let entries = aniListResult.entries

        // A successful, authoritative empty result means this title simply has
        // no mapped specials. Do not turn that into MAL's much larger title and
        // per-candidate detail traversal.
        if entries.isEmpty,
           aniListResult.isComplete,
           !AnimeProviderHealthCenter.shared.isAniListTemporarilyUnavailable {
            specialEntriesCache.setObject(
                SpecialEntriesCacheWrapper(entries: []),
                forKey: cacheKey as NSString
            )
            return []
        }

        guard entries.isEmpty || AnimeProviderHealthCenter.shared.isAniListTemporarilyUnavailable else {
            if aniListResult.isComplete {
                specialEntriesCache.setObject(
                    SpecialEntriesCacheWrapper(entries: entries),
                    forKey: cacheKey as NSString
                )
            }
            return entries
        }

        let malEntries = await MALMetadataService.shared.fetchSpecialSearchEntries(
            tmdbShowId: tmdbShowId,
            fallbackPosterURL: fallbackPosterURL,
            tmdbService: tmdbService
        )
        guard !malEntries.isEmpty else { return entries }
        if AnimeProviderHealthCenter.shared.isAniListTemporarilyUnavailable {
            AnimeProviderHealthCenter.shared.notifyMALFallbackIfNeeded(reason: "specials")
        }
        let existingIds = Set(entries.map(\.id))
        return (entries + malEntries.filter { !existingIds.contains($0.id) })
            .sorted { $0.isOrderedBeforeSpecialEntry($1) }
    }

    private func specialEntriesCacheKey(
        tmdbShowId: Int,
        baseAniListIds: [Int],
        fallbackPosterURL: String?
    ) -> String {
        let ids = Set(baseAniListIds.filter { $0 > 0 }).sorted().map(String.init).joined(separator: ",")
        return "\(tmdbShowId)|\(preferredLanguageCode)|\(ids)|\(fallbackPosterURL ?? "-")"
    }

    private func fetchSpecialSearchEntriesFromAniList(
        tmdbShowId: Int,
        fallbackPosterURL: String?,
        baseAniListIds: [Int] = [],
        tmdbService: TMDBService
    ) async -> SpecialEntriesFetchResult {
        let mappingResult = await AniMapMappingService.shared.specialMappingsResult(forTMDBShowId: tmdbShowId)
        let mappings = mappingResult.mappings
        let uniqueMappings = mappings.reduce(into: [Int: AniMapMapping]()) { result, mapping in
            guard let anilistId = mapping.anilistId, result[anilistId] == nil else { return }
            result[anilistId] = mapping
        }

        let nodeResult = await batchFetchAniListNodesResult(ids: Array(uniqueMappings.keys))
        let nodesById = nodeResult.nodes
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

        var entries = uniqueMappings.compactMap { element -> AniListSpecialSearchEntry? in
            buildSpecialSearchEntry(
                anilistId: element.key,
                node: nodesById[element.key],
                mapping: element.value,
                fallbackPosterURL: fallbackPosterURL,
                seasonDetailsByNumber: seasonDetailsByNumber
            )
        }

        let relationResult = await relationSpecialSearchEntries(
            baseAniListIds: baseAniListIds,
            tmdbShowId: tmdbShowId,
            fallbackPosterURL: fallbackPosterURL,
            tmdbService: tmdbService,
            excluding: Set(entries.map { $0.id })
        )
        let relationEntries = relationResult.entries
        if !relationEntries.isEmpty {
            let existingIds = Set(entries.map { $0.id })
            entries.append(contentsOf: relationEntries.filter { !existingIds.contains($0.id) })
            Logger.shared.log("AniListService: relation fallback added \(relationEntries.count) special/OVA entries for TMDB \(tmdbShowId)", type: "AniList")
        }

        let hasRelationSeeds = baseAniListIds.contains { $0 > 0 }
        return SpecialEntriesFetchResult(
            entries: entries.sorted { lhs, rhs in
                lhs.isOrderedBeforeSpecialEntry(rhs)
            },
            // Empty AniMap output alone is not proof that a show has no
            // specials. Only suppress MAL fallback after the known base season
            // relations were also inspected successfully.
            isComplete: hasRelationSeeds
                && mappingResult.isComplete
                && nodeResult.isComplete
                && relationResult.isComplete
        )
    }

    private func buildSpecialSearchEntry(
        anilistId: Int,
        node: AniListAnime?,
        mapping: AniMapMapping?,
        fallbackPosterURL: String?,
        seasonDetailsByNumber: [Int: TMDBSeasonDetail]
    ) -> AniListSpecialSearchEntry? {
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
        let mappedSeason = mapping?.tmdbSeason
        let metadataSeason = mapping?.tmdbSeason ?? mapping?.tvdbSeason
        let episodeOffset = mapping?.tvdbEpisodeOffset ?? 0
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
        let exactEpisodeDate = episodes.compactMap(\.airDate).min()
        let releaseDate = node?.startDate?.exactDateString
            ?? exactEpisodeDate
            ?? node?.startDate?.approximateDateString
            ?? AniListDate.approximateDateString(year: node?.seasonYear, season: node?.season)

        return AniListSpecialSearchEntry(
            id: anilistId,
            title: cleanTitle,
            englishTitle: englishTitle,
            romajiTitle: romajiTitle,
            nativeTitle: nativeTitle,
            format: mapping?.mediaType?.uppercased() ?? node?.format,
            episodeCount: episodeCount,
            posterUrl: node?.coverImage?.large
                ?? node?.coverImage?.medium
                ?? tmdbSeasonDetail?.fullPosterURL
                ?? fallbackPosterURL,
            tmdbSeasonNumber: mapping?.tmdbSeason,
            tvdbSeasonNumber: mapping?.tvdbSeason,
            episodeOffset: mapping?.tvdbEpisodeOffset,
            imdbId: mapping?.imdbId,
            releaseDate: releaseDate,
            episodes: episodes
        )
    }

    private func relationSpecialSearchEntries(
        baseAniListIds: [Int],
        tmdbShowId: Int,
        fallbackPosterURL: String?,
        tmdbService: TMDBService,
        excluding existingIds: Set<Int>
    ) async -> SpecialEntriesFetchResult {
        let baseIds = Array(Set(baseAniListIds)).filter { $0 > 0 && !existingIds.contains($0) }
        guard !baseIds.isEmpty else {
            return SpecialEntriesFetchResult(entries: [], isComplete: true)
        }

        let baseNodeResult = await batchFetchAniListNodesResult(ids: baseIds)
        let baseNodes = baseNodeResult.nodes
        var candidates: [Int: AniListAnime] = [:]

        for base in baseNodes.values {
            for edge in base.relations?.edges ?? [] {
                let relationNode = edge.node
                guard relationNode.type == "ANIME",
                      !baseIds.contains(relationNode.id),
                      !existingIds.contains(relationNode.id),
                      isSpecialRelationCandidate(edge) else {
                    continue
                }
                candidates[relationNode.id] = relationNode.asAnime()
            }
        }

        guard !candidates.isEmpty else {
            return SpecialEntriesFetchResult(entries: [], isComplete: baseNodeResult.isComplete)
        }
        let hydratedResult = await batchFetchAniListNodesResult(ids: Array(candidates.keys))
        let hydratedCandidates = hydratedResult.nodes
        let candidateNodes = candidates.mapValues { relationNode in
            hydratedCandidates[relationNode.id] ?? relationNode
        }

        var mappingsById: [Int: AniMapMapping] = [:]
        var mappingsAreComplete = true
        await withTaskGroup(of: (Int, AniMapMapping?, Bool).self) { group in
            for id in candidates.keys {
                group.addTask {
                    let result = await AniMapMappingService.shared.mappingsResult(forAniListId: id)
                    let specialMapping = result.mappings.first { mapping in
                        let type = mapping.mediaType?.uppercased()
                        let isSpecial = type == nil || type == "SPECIAL" || type == "OVA" || type == "ONA"
                        let matchesShow = mapping.tmdbShowId == nil || mapping.tmdbShowId == tmdbShowId
                        return isSpecial && matchesShow
                    }
                    return (id, specialMapping, result.isComplete)
                }
            }

            for await (id, mapping, isComplete) in group {
                mappingsAreComplete = mappingsAreComplete && isComplete
                if let mapping {
                    mappingsById[id] = mapping
                }
            }
        }

        let metadataSeasonNumbers = Set(mappingsById.values.compactMap { $0.tmdbSeason ?? $0.tvdbSeason })
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
                                "AniListService: relation special metadata season \(seasonNumber) failed for show \(tmdbShowId): \(error.localizedDescription)",
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

        return SpecialEntriesFetchResult(
            entries: candidateNodes.compactMap { id, node in
                buildSpecialSearchEntry(
                    anilistId: id,
                    node: node,
                    mapping: mappingsById[id],
                    fallbackPosterURL: fallbackPosterURL,
                    seasonDetailsByNumber: seasonDetailsByNumber
                )
            },
            isComplete: baseNodeResult.isComplete && hydratedResult.isComplete && mappingsAreComplete
        )
    }

    private func isSpecialRelationCandidate(_ edge: AniListAnime.AniListRelationEdge) -> Bool {
        let relationType = edge.relationType.uppercased()
        let format = edge.node.format?.uppercased()
        let specialFormats: Set<String> = ["SPECIAL", "OVA", "ONA"]

        if let format, specialFormats.contains(format) {
            return true
        }

        let relationTypes: Set<String> = ["SIDE_STORY", "SPIN_OFF", "OTHER"]
        guard relationTypes.contains(relationType) else { return false }

        let titleText = AniListTitlePicker.titleCandidates(from: edge.node.title)
            .joined(separator: " ")
            .lowercased()
        let keywords = ["special", "ova", "oad", "ona", "extra", "another world"]
        return keywords.contains { titleText.contains($0) }
    }

    private func pickBestAniListMatch(from candidates: [AniListAnime], tmdbShow: TMDBTVShowWithSeasons?) -> AniListAnime {
        // Hard selection rules (no weighted scoring): 1) Prefer TV/TV_SHORT/OVA formats.

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

        let titleFiltered: [AniListAnime] = {
            let tmdbTitle = normalizedAnimeTitle(tmdbShow.name)
            guard !tmdbTitle.isEmpty else { return yearFiltered }

            let exactMatches = yearFiltered.filter { anime in
                AniListTitlePicker.titleCandidates(from: anime.title)
                    .map(normalizedAnimeTitle)
                    .contains(tmdbTitle)
            }
            return exactMatches.isEmpty ? yearFiltered : exactMatches
        }()

        // If we know the TMDB episode count, pick the closest match within exact title matches;
        // otherwise fall back to highest episodes. This keeps side-story/short entries out of
        // multi-season roots like Link Click, where a side story can be closer to TMDB's total.
        let chosen: AniListAnime?
        if let tmdbEpisodes {
            chosen = titleFiltered.min(by: { lhs, rhs in
                let lhsEpisodes = lhs.episodes ?? 0
                let rhsEpisodes = rhs.episodes ?? 0
                let lhsDiff = abs(lhsEpisodes - tmdbEpisodes)
                let rhsDiff = abs(rhsEpisodes - tmdbEpisodes)
                if lhsDiff != rhsDiff { return lhsDiff < rhsDiff }
                if lhsEpisodes != rhsEpisodes { return lhsEpisodes > rhsEpisodes }
                return lhs.id < rhs.id
            })
        } else {
            chosen = titleFiltered.sorted(by: { lhs, rhs in
                let lhsEpisodes = lhs.episodes ?? 0
                let rhsEpisodes = rhs.episodes ?? 0
                if lhsEpisodes != rhsEpisodes { return lhsEpisodes > rhsEpisodes }
                return lhs.id < rhs.id
            }).first
        }

        return chosen ?? candidates.first!
    }

    private func normalizedAnimeTitle(_ value: String) -> String {
        value
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
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
                        Logger.shared.log("AniListService: Matched '\(aniTitle)' -> TMDB '\(bestMatch.name)' (ID: \(bestMatch.id))", type: "AniList")
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
        let cacheLanguage = self.tmdbMatchCacheLanguage

        return await withTaskGroup(of: (Int, TMDBSearchResult?, AnimeTMDBMatchCacheRecord?).self) { group in
            for anime in animeList {
                group.addTask {
                    let titleCandidates = AniListTitlePicker.titleCandidates(from: anime.title)
                    let expectedYear = anime.seasonYear
                    let cacheKey = AnimeTMDBMatchCacheKey(
                        source: .anilist,
                        id: anime.id,
                        language: cacheLanguage,
                        titleCandidates: titleCandidates,
                        expectedYear: expectedYear,
                        format: anime.format
                    )

                    if let cached = await AnimeTMDBMatchCache.shared.lookup(cacheKey) {
                        return (anime.id, cached.result, nil)
                    }

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
                        Logger.shared.log("AniListService: Matched '\(aniTitle)' -> TMDB '\(bestMatch.name)' (ID: \(bestMatch.id))", type: "AniList")
                    }
                    let result = bestMatch?.asSearchResult
                    return (anime.id, result, AnimeTMDBMatchCacheRecord(key: cacheKey, result: result))
                }
            }

            var dict: [Int: TMDBSearchResult] = [:]
            var cacheRecords: [AnimeTMDBMatchCacheRecord] = []
            for await (anilistId, match, cacheRecord) in group {
                if let match = match {
                    dict[anilistId] = match
                }
                if let cacheRecord {
                    cacheRecords.append(cacheRecord)
                }
            }
            await AnimeTMDBMatchCache.shared.store(cacheRecords)
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
        if mediaId < 0 {
            return await MALMetadataService.shared.fetchParentTitleCandidates(forMalMediaId: mediaId, maxDepth: maxDepth)
        }

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

        let nodes = await batchFetchAniListImportNodes(ids: uniqueIds)
        return await batchMapAniListToTMDB(Array(nodes.values), tmdbService: tmdbService)
    }

    /// MAL library import only: prefer AniMap's direct AniList -> TMDB IDs before title-search fallback.
    func mapAniListAnimeIdsToTMDBViaAniMapForMALImport(
        _ ids: [Int],
        tmdbService: TMDBService
    ) async -> [Int: AniMapTMDBImportMatch] {
        let uniqueIds = Array(Set(ids))
        guard !uniqueIds.isEmpty else { return [:] }

        return await withTaskGroup(of: (Int, AniMapTMDBImportMatch?).self) { group in
            for anilistId in uniqueIds {
                group.addTask {
                    let mappings = await AniMapMappingService.shared.mappings(forAniListId: anilistId)
                    guard let mapping = Self.bestAniMapImportMapping(mappings, anilistId: anilistId),
                          let match = await Self.tmdbImportMatch(from: mapping, tmdbService: tmdbService) else {
                        return (anilistId, nil)
                    }
                    return (anilistId, match)
                }
            }

            var result: [Int: AniMapTMDBImportMatch] = [:]
            for await (anilistId, match) in group {
                if let match {
                    result[anilistId] = match
                }
            }
            return result
        }
    }

    private static func bestAniMapImportMapping(_ mappings: [AniMapMapping], anilistId: Int) -> AniMapMapping? {
        mappings
            .filter { $0.anilistId == nil || $0.anilistId == anilistId }
            .max { lhs, rhs in
                Self.aniMapImportScore(lhs) < Self.aniMapImportScore(rhs)
            }
    }

    private static func aniMapImportScore(_ mapping: AniMapMapping) -> Int {
        let type = mapping.mediaType?.uppercased()
        var score = 0
        if type == "MOVIE", mapping.tmdbMovieId != nil {
            score += 50
        }
        if mapping.tmdbShowId != nil {
            score += 40
        }
        if mapping.tmdbMovieId != nil {
            score += 30
        }
        if mapping.tmdbSeason != nil {
            score += 5
        }
        let isSpecialLike = type == "SPECIAL" || type == "OVA"
        if !isSpecialLike {
            score += 2
        }
        return score
    }

    private static func tmdbImportMatch(from mapping: AniMapMapping, tmdbService: TMDBService) async -> AniMapTMDBImportMatch? {
        if mapping.mediaType?.uppercased() == "MOVIE",
           let movieId = mapping.tmdbMovieId,
           let detail = try? await tmdbService.getMovieDetails(id: movieId) {
            return AniMapTMDBImportMatch(
                tmdbResult: Self.tmdbSearchResult(from: detail),
                tmdbSeason: nil
            )
        }

        if let showId = mapping.tmdbShowId,
           let detail = try? await tmdbService.getTVShowDetails(id: showId) {
            return AniMapTMDBImportMatch(
                tmdbResult: Self.tmdbSearchResult(from: detail),
                tmdbSeason: mapping.tmdbSeason
            )
        }

        if let movieId = mapping.tmdbMovieId,
           let detail = try? await tmdbService.getMovieDetails(id: movieId) {
            return AniMapTMDBImportMatch(
                tmdbResult: Self.tmdbSearchResult(from: detail),
                tmdbSeason: nil
            )
        }

        return nil
    }

    private static func tmdbSearchResult(from detail: TMDBTVShowDetail) -> TMDBSearchResult {
        TMDBSearchResult(
            id: detail.id,
            mediaType: "tv",
            title: nil,
            name: detail.name,
            overview: detail.overview,
            posterPath: detail.posterPath,
            backdropPath: detail.backdropPath,
            releaseDate: nil,
            firstAirDate: detail.firstAirDate,
            voteAverage: detail.voteAverage,
            popularity: detail.popularity,
            adult: detail.adult,
            genreIds: detail.genres.map(\.id)
        )
    }

    private static func tmdbSearchResult(from detail: TMDBMovieDetail) -> TMDBSearchResult {
        TMDBSearchResult(
            id: detail.id,
            mediaType: "movie",
            title: detail.title,
            name: nil,
            overview: detail.overview,
            posterPath: detail.posterPath,
            backdropPath: detail.backdropPath,
            releaseDate: detail.releaseDate,
            firstAirDate: nil,
            voteAverage: detail.voteAverage,
            popularity: detail.popularity,
            adult: detail.adult,
            genreIds: detail.genres.map(\.id)
        )
    }

    // MARK: - Private Helpers
    
    private func executeGraphQLQuery(_ query: String, token: String?, maxRetries: Int = 3) async throws -> Data {
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
            // Every network attempt, including transport and 429 retries, must
            // claim a fresh slot and honor pauses learned by other requests.
            try await AniListRateLimiter.shared.waitForSlot()

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                lastError = error
                if attempt < maxRetries - 1, shouldRetryAniListTransportError(error) {
                    let delay = min(Double(attempt + 1) * 1.5, 5)
                    Logger.shared.log("AniList transport error, retry \(attempt + 1)/\(maxRetries) after \(delay)s: \(error.localizedDescription)", type: "AniList")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw error
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                await AniListRateLimiter.shared.recordResponse(httpResponse)

                if httpResponse.statusCode == 200 {
                    if let graphQLError = graphQLErrorMessage(from: data) {
                        throw NSError(
                            domain: "AniList",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "AniList returned an invalid GraphQL response: \(graphQLError)"]
                        )
                    }
                    return data
                }
                
                // Rate limited - wait and retry
                if httpResponse.statusCode == 429 {
                    lastError = NSError(domain: "AniList", code: 429, userInfo: [NSLocalizedDescriptionKey: "AniList rate limited (HTTP 429)"])
                    if attempt < maxRetries - 1 {
                        Logger.shared.log(
                            "AniList rate limited (429); attempt \(attempt + 2)/\(maxRetries) will honor the global server retry window",
                            type: "AniList"
                        )
                    }
                    continue
                }
                
                let details = graphQLErrorMessage(from: data) ?? responseBodyPreview(from: data)
                let error = "AniList error (HTTP \(httpResponse.statusCode)): \(details)"
                Logger.shared.log("AniListService: GraphQL request failed with HTTP \(httpResponse.statusCode): \(details)", type: "Error")
                throw NSError(domain: "AniList", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: error])
            }
            
            throw NSError(domain: "AniList", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch from AniList"])
        }
        
        throw lastError ?? NSError(domain: "AniList", code: 429, userInfo: [NSLocalizedDescriptionKey: "AniList rate limited after \(maxRetries) retries"])
    }

    private func shouldRetryAniListTransportError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return [.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost].contains(urlError.code)
        }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorNetworkConnectionLost
        ].contains(nsError.code)
    }

    private func graphQLErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = json["errors"] as? [[String: Any]],
              let first = errors.first else {
            return nil
        }
        return first["message"] as? String
    }

    private func responseBodyPreview(from data: Data, limit: Int = 500) -> String {
        let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 response>"
        guard raw.count > limit else { return raw }
        return String(raw.prefix(limit)) + "..."
    }

    /// Import mapping can involve hundreds of library IDs, so keep each GraphQL
    /// request small and avoid the nested relation payload used by detail flows.
    private func batchFetchAniListImportNodes(ids: [Int]) async -> [Int: AniListAnime] {
        guard !ids.isEmpty else { return [:] }

        let fragment = """
            id
            idMal
            externalLinks { site siteId url }
            averageScore
            title { romaji english native }
            episodes
            status
            seasonYear
            season
            format
            type
            coverImage { large medium }
        """

        let uniqueIds = Array(Set(ids))
        let chunkSize = 20
        var result: [Int: AniListAnime] = [:]
        var start = 0

        while start < uniqueIds.count {
            let chunk = Array(uniqueIds[start..<min(start + chunkSize, uniqueIds.count)])
            let aliases = chunk.enumerated().map { index, id in
                "m\(index): Media(id: \(id), type: ANIME) { \(fragment) }"
            }.joined(separator: "\n")
            let query = "query { \(aliases) }"

            do {
                let data = try await executeGraphQLQuery(query, token: nil)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let dataDict = json?["data"] as? [String: Any] else {
                    start += chunkSize
                    continue
                }

                for (index, id) in chunk.enumerated() {
                    let key = "m\(index)"
                    if let mediaJSON = dataDict[key],
                       !(mediaJSON is NSNull),
                       let mediaData = try? JSONSerialization.data(withJSONObject: mediaJSON),
                       let anime = try? JSONDecoder().decode(AniListAnime.self, from: mediaData) {
                        result[id] = anime
                    }
                }
            } catch {
                AnimeProviderHealthCenter.shared.recordAniListFailure(error)
                Logger.shared.log("AniListService: Import batch fetch failed for \(chunk.count) nodes: \(error.localizedDescription)", type: "AniList")
            }

            start += chunkSize
        }

        return result
    }

    private struct AniListNodeBatchResult {
        let nodes: [Int: AniListAnime]
        let isComplete: Bool
    }

    /// Batch-fetch multiple anime nodes with relations in a single aliased GraphQL query.
    private func batchFetchAniListNodes(ids: [Int]) async -> [Int: AniListAnime] {
        await batchFetchAniListNodesResult(ids: ids).nodes
    }

    private func batchFetchAniListNodesResult(ids: [Int]) async -> AniListNodeBatchResult {
        guard !ids.isEmpty else {
            return AniListNodeBatchResult(nodes: [:], isComplete: true)
        }

        let fragment = """
            id
            idMal
            externalLinks { site siteId url }
            averageScore
            isAdult
            genres
            tags { name rank isMediaSpoiler }
            title { romaji english native }
            episodes
            status
            startDate { year month day }
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
                        idMal
                        externalLinks { site siteId url }
                        averageScore
                        isAdult
                        genres
                        tags { name rank isMediaSpoiler }
                        title { romaji english native }
                        episodes
                        status
                        startDate { year month day }
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
                                    idMal
                                    externalLinks { site siteId url }
                                    averageScore
                                    isAdult
                                    title { romaji english native }
                                    episodes
                                    status
                                    startDate { year month day }
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
            guard let dataDict = json?["data"] as? [String: Any] else {
                return AniListNodeBatchResult(nodes: [:], isComplete: false)
            }

            var result: [Int: AniListAnime] = [:]
            for (i, id) in ids.enumerated() {
                let key = "m\(i)"
                if let mediaJSON = dataDict[key],
                   let mediaData = try? JSONSerialization.data(withJSONObject: mediaJSON),
                   let anime = try? JSONDecoder().decode(AniListAnime.self, from: mediaData) {
                    result[id] = anime
                }
            }
            let requestedIDs = Set(ids)
            return AniListNodeBatchResult(
                nodes: result,
                isComplete: requestedIDs.isSubset(of: Set(result.keys))
            )
        } catch {
            if Task.isCancelled || error is CancellationError {
                return AniListNodeBatchResult(nodes: [:], isComplete: false)
            }
            AnimeProviderHealthCenter.shared.recordAniListFailure(error)
            Logger.shared.log("AniListService: Batch fetch failed for \(ids.count) nodes: \(error.localizedDescription)", type: "AniList")
            return AniListNodeBatchResult(nodes: [:], isComplete: false)
        }
    }

    /// Fetch a single anime node with relations for deeper traversal
    private func fetchAniListAnimeNode(id: Int) async throws -> AniListAnime {
        let query = """
        query {
            Media(id: \(id), type: ANIME) {
                id
                externalLinks { site siteId url }
                title { romaji english native }
                episodes
                status
                startDate { year month day }
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
                            externalLinks { site siteId url }
                            title { romaji english native }
                            episodes
                            status
                            startDate { year month day }
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

    /// Returns the bounded normal-season relation graph used by local
    /// notification follows. Unlike detail traversal, this intentionally keeps
    /// NOT_YET_RELEASED sequels so Eclipse can baseline and later discover them.
    func fetchNotificationSeasons(
        startingMediaIDs: [Int],
        limit: Int = 32
    ) async -> AniListNotificationSeasonGraph {
        var visited = Set<Int>()
        var pending = startingMediaIDs.filter { $0 > 0 }
        var results: [Int: AniListNotificationSeason] = [:]
        var isComplete = true
        let relationTypes: Set<String> = ["SEQUEL", "PREQUEL", "SEASON"]

        while !pending.isEmpty, visited.count < limit, !Task.isCancelled {
            let takeCount = min(12, limit - visited.count, pending.count)
            let batch = Array(pending.prefix(takeCount))
                .filter { visited.insert($0).inserted }
            pending.removeFirst(takeCount)
            guard !batch.isEmpty else { continue }

            let nodeResult = await batchFetchAniListNodesResult(ids: batch)
            isComplete = isComplete && nodeResult.isComplete
            for node in nodeResult.nodes.values {
                if isNotificationSeasonCandidate(node) {
                    let title = AniListTitlePicker.title(
                        from: node.title,
                        preferredLanguageCode: preferredLanguageCode
                    )
                    results[node.id] = AniListNotificationSeason(
                        id: node.id,
                        title: title,
                        status: node.status,
                        season: node.season,
                        seasonYear: node.seasonYear,
                        premiereDate: notificationPremiereDate(node.startDate)
                    )
                }

                for edge in node.relations?.edges ?? [] {
                    guard relationTypes.contains(edge.relationType),
                          edge.node.type == "ANIME",
                          edge.node.isAdult != true else {
                        continue
                    }
                    let related = edge.node.asAnime()
                    guard isNotificationSeasonCandidate(related) else { continue }
                    if results[related.id] == nil {
                        let title = AniListTitlePicker.title(
                            from: related.title,
                            preferredLanguageCode: preferredLanguageCode
                        )
                        results[related.id] = AniListNotificationSeason(
                            id: related.id,
                            title: title,
                            status: related.status,
                            season: related.season,
                            seasonYear: related.seasonYear,
                            premiereDate: notificationPremiereDate(related.startDate)
                        )
                    }
                    if !visited.contains(related.id), !pending.contains(related.id) {
                        if visited.count + pending.count < limit {
                            pending.append(related.id)
                        } else {
                            isComplete = false
                        }
                    }
                }
            }
        }

        isComplete = isComplete && pending.isEmpty && !Task.isCancelled
        let seasons = results.values.sorted {
            switch ($0.premiereDate, $1.premiereDate) {
            case let (lhs?, rhs?) where lhs != rhs: return lhs < rhs
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.id < $1.id
            }
        }
        return AniListNotificationSeasonGraph(seasons: seasons, isComplete: isComplete)
    }

    private func isNotificationSeasonCandidate(_ anime: AniListAnime) -> Bool {
        guard anime.isAdult != true else { return false }
        if let format = anime.format, !["TV", "TV_SHORT", "ONA"].contains(format) {
            return false
        }
        let title = AniListTitlePicker.title(
            from: anime.title,
            preferredLanguageCode: preferredLanguageCode
        ).lowercased()
        return !["recap", "summary", "music", "trailer", " pv", " cm"].contains {
            title.contains($0)
        }
    }

    private func notificationPremiereDate(_ date: AniListDate?) -> Date? {
        guard let year = date?.year, let month = date?.month, let day = date?.day else {
            return nil
        }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = year
        components.month = month
        components.day = day
        components.hour = 9
        return components.date
    }

}

// MARK: - Helper Models

actor AnimeFillerService {
    static let shared = AnimeFillerService()

    private struct EpisodesResponse: Decodable {
        struct Pagination: Decodable {
            let hasNextPage: Bool

            enum CodingKeys: String, CodingKey {
                case hasNextPage = "has_next_page"
            }
        }

        struct Episode: Decodable {
            let number: Int
            let filler: Bool

            enum CodingKeys: String, CodingKey {
                case number = "mal_id"
                case filler
            }
        }

        let pagination: Pagination
        let data: [Episode]
    }

    private enum ServiceError: LocalizedError {
        case invalidURL
        case invalidResponse
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "The filler metadata URL is invalid."
            case .invalidResponse:
                return "The filler metadata response was invalid."
            case .httpStatus(let status):
                return "The filler metadata request returned HTTP \(status)."
            }
        }
    }

    private var cachedEpisodeNumbers: [Int: Set<Int>] = [:]
    private var inFlightRequests: [Int: Task<Set<Int>, Error>] = [:]

    func fillerEpisodeNumbers(malId: Int) async throws -> Set<Int> {
        let normalizedId = abs(malId)
        guard normalizedId > 0 else { return [] }

        if let cached = cachedEpisodeNumbers[normalizedId] {
            return cached
        }
        if let inFlight = inFlightRequests[normalizedId] {
            return try await inFlight.value
        }

        let task = Task {
            try await Self.fetchFillerEpisodeNumbers(malId: normalizedId)
        }
        inFlightRequests[normalizedId] = task

        do {
            let episodeNumbers = try await task.value
            cachedEpisodeNumbers[normalizedId] = episodeNumbers
            inFlightRequests[normalizedId] = nil
            return episodeNumbers
        } catch {
            inFlightRequests[normalizedId] = nil
            throw error
        }
    }

    private static func fetchFillerEpisodeNumbers(malId: Int) async throws -> Set<Int> {
        var page = 1
        var fillerEpisodeNumbers = Set<Int>()

        while true {
            guard var components = URLComponents(string: "https://api.jikan.moe/v4/anime/\(malId)/episodes") else {
                throw ServiceError.invalidURL
            }
            components.queryItems = [URLQueryItem(name: "page", value: String(page))]
            guard let url = components.url else { throw ServiceError.invalidURL }

            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ServiceError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw ServiceError.httpStatus(httpResponse.statusCode)
            }

            let decoded = try JSONDecoder().decode(EpisodesResponse.self, from: data)
            fillerEpisodeNumbers.formUnion(
                decoded.data.lazy.filter(\.filler).map(\.number)
            )

            guard decoded.pagination.hasNextPage else { break }
            page += 1

            // Jikan allows three requests per second. Stay below that limit for long shows.
            try await Task.sleep(nanoseconds: 400_000_000)
        }

        return fillerEpisodeNumbers
    }
}

protocol AniListEpisodeProtocol {
    var number: Int { get }
    var title: String { get }
    var description: String? { get }
    var seasonNumber: Int { get }
}

struct AniListEpisode: AniListEpisodeProtocol, Codable {
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

struct AniListAiringScheduleEntry: Identifiable, Codable {
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
    let hasKnownAiringTime: Bool
}

struct AnimeAiringScheduleResult {
    let entries: [AniListAiringScheduleEntry]
    let isAuthoritativeForNotifications: Bool
}

struct AniListSeasonWithPoster: Codable {
    let seasonNumber: Int
    let anilistId: Int             // AniList anime ID for this specific season
    let kitsuId: Int?              // Kitsu anime ID for Stremio anime catalogs, when AniList exposes it
    let title: String              // AniList title for this season.
    let englishTitle: String?
    let romajiTitle: String?
    let nativeTitle: String?
    let episodes: [AniListEpisode]
    let posterUrl: String?
}

struct AniListSpecialSearchEntry: Identifiable, Codable {
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
    let releaseDate: String?
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

    func isOrderedBeforeSpecialEntry(_ other: AniListSpecialSearchEntry) -> Bool {
        switch (releaseDate, other.releaseDate) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate < rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }

        if sortSeason != other.sortSeason {
            return sortSeason < other.sortSeason
        }
        if formatLabel != other.formatLabel {
            return formatLabel < other.formatLabel
        }
        return title.localizedCaseInsensitiveCompare(other.title) == .orderedAscending
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

struct AniListAnimeWithSeasons: Codable {
    let id: Int
    let malId: Int?
    let title: String
    let genres: [String]?
    let seasons: [AniListSeasonWithPoster]
    let totalEpisodes: Int
    let status: String
    let rating: AnimeMetadataRating?
}

struct AniListNotificationSeason: Identifiable, Sendable {
    let id: Int
    let title: String
    let status: String?
    let season: String?
    let seasonYear: Int?
    let premiereDate: Date?

    var isUpcoming: Bool {
        status == "NOT_YET_RELEASED" || (premiereDate.map { $0 > Date() } ?? false)
    }

    var seasonLabel: String {
        if let season, let seasonYear {
            return "\(season.capitalized) \(seasonYear)"
        }
        if let seasonYear {
            return "\(seasonYear) season"
        }
        return "Upcoming season"
    }
}

struct AniListNotificationSeasonGraph: Sendable {
    let seasons: [AniListNotificationSeason]
    let isComplete: Bool
}

// MARK: - AniList Codable Models

struct AniListDate: Codable {
    let year: Int?
    let month: Int?
    let day: Int?

    var exactDateString: String? {
        guard let year, let month, let day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    var approximateDateString: String? {
        guard let year else { return nil }
        return String(format: "%04d-%02d-%02d", year, month ?? 1, day ?? 1)
    }

    static func approximateDateString(year: Int?, season: String?) -> String? {
        guard let year else { return nil }
        let month: Int
        switch season?.uppercased() {
        case "WINTER":
            month = 1
        case "SPRING":
            month = 4
        case "SUMMER":
            month = 7
        case "FALL":
            month = 10
        default:
            month = 1
        }
        return String(format: "%04d-%02d-01", year, month)
    }
}

struct AniListAnime: Codable {
    let id: Int
    let idMal: Int?
    let externalLinks: [AniListExternalLink]?
    let averageScore: Int?
    let isAdult: Bool?
    let genres: [String]?
    let tags: [AniListTag]?
    let title: AniListTitle
    let episodes: Int?
    let status: String?
    let startDate: AniListDate?
    let seasonYear: Int?
    let season: String?
    let coverImage: AniListCoverImage?
    let format: String?
    let type: String?
    let nextAiringEpisode: AniListNextAiringEpisode?
    let relations: AniListRelations?

    var kitsuId: Int? {
        Self.kitsuId(from: externalLinks)
    }

    /// AniList's `genres` are supplemented with a small set of high-confidence,
    /// genre-like tags. AniList models Isekai as a tag rather than a genre, so
    /// ignoring tags would omit the anime-specific metadata this surface needs.
    var detailGenreLabels: [String] {
        var values: [String] = []
        var seen = Set<String>()

        func append(_ rawValue: String) {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = Self.normalizedGenreLabel(value)
            guard !value.isEmpty, !key.isEmpty, seen.insert(key).inserted else { return }
            values.append(value)
        }

        for genre in genres ?? [] {
            append(genre)
        }

        let allowedTagKeys = Set([
            "isekai", "reincarnation", "sliceoflife", "supernatural", "psychological",
            "mecha", "sports", "school", "historical", "harem", "mahou shoujo",
            "magicalgirl", "samurai", "superpower", "timetravel", "videogame",
            "shounen", "shoujo", "seinen", "josei"
        ].map(Self.normalizedGenreLabel))

        let genreLikeTags = (tags ?? [])
            .filter { $0.isMediaSpoiler != true && ($0.rank ?? 0) >= 50 }
            .filter { allowedTagKeys.contains(Self.normalizedGenreLabel($0.name)) }
            .sorted { ($0.rank ?? 0) > ($1.rank ?? 0) }
            .prefix(6)
        for tag in genreLikeTags {
            append(tag.name)
        }

        return values
    }

    private static func normalizedGenreLabel(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    struct AniListTitle: Codable {
        let romaji: String?
        let english: String?
        let native: String?
    }

    struct AniListCoverImage: Codable {
        let large: String?
        let medium: String?
    }

    struct AniListTag: Codable {
        let name: String
        let rank: Int?
        let isMediaSpoiler: Bool?
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
        let idMal: Int?
        let externalLinks: [AniListExternalLink]?
        let averageScore: Int?
        let isAdult: Bool?
        let genres: [String]?
        let tags: [AniListTag]?
        let title: AniListTitle
        let episodes: Int?
        let status: String?
        let startDate: AniListDate?
        let seasonYear: Int?
        let season: String?
        let format: String?
        let type: String?
        let coverImage: AniListCoverImage?
        let relations: AniListRelations?

        func asAnime() -> AniListAnime {
            return AniListAnime(
                id: id,
                idMal: idMal,
                externalLinks: externalLinks,
                averageScore: averageScore,
                isAdult: isAdult,
                genres: genres,
                tags: tags,
                title: title,
                episodes: episodes,
                status: status,
                startDate: startDate,
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

    private static func kitsuId(from links: [AniListExternalLink]?) -> Int? {
        guard let links else { return nil }

        for link in links where link.looksLikeKitsu {
            if let siteId = link.siteId, siteId > 0 {
                return siteId
            }
            if let parsedId = link.numericKitsuIdFromURL {
                return parsedId
            }
        }

        return nil
    }
}

struct AniListExternalLink: Codable {
    let site: String?
    let siteId: Int?
    let url: String?

    var looksLikeKitsu: Bool {
        if site?.localizedCaseInsensitiveContains("kitsu") == true {
            return true
        }
        guard let host = URL(string: url ?? "")?.host?.lowercased() else {
            return false
        }
        return host.contains("kitsu")
    }

    var numericKitsuIdFromURL: Int? {
        guard looksLikeKitsu,
              let url,
              let components = URLComponents(string: url) else {
            return nil
        }

        if let queryId = components.queryItems?.first(where: { $0.name.caseInsensitiveCompare("id") == .orderedSame })?.value,
           let value = Int(queryId), value > 0 {
            return value
        }

        for segment in components.path.split(separator: "/").reversed() {
            if let value = Int(segment), value > 0 {
                return value
            }

            let prefix = segment.prefix { $0.isNumber }
            if let value = Int(prefix), value > 0 {
                return value
            }
        }

        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case site, siteId, url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        site = try? container.decodeIfPresent(String.self, forKey: .site)
        url = try? container.decodeIfPresent(String.self, forKey: .url)

        if let intSiteId = try? container.decodeIfPresent(Int.self, forKey: .siteId) {
            siteId = intSiteId
        } else if let stringSiteId = try? container.decodeIfPresent(String.self, forKey: .siteId),
                  let parsed = Int(stringSiteId) {
            siteId = parsed
        } else {
            siteId = nil
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

private final class MALMetadataService {
    static let shared = MALMetadataService()

    private let apiBase = URL(string: "https://api.myanimelist.net/v2")!
    private let detailFields = [
        "id", "title", "main_picture", "alternative_titles", "start_date", "end_date",
        "synopsis", "mean", "rank", "popularity", "num_list_users", "media_type",
        "status", "genres", "num_episodes", "start_season", "broadcast", "source",
        "average_episode_duration", "rating", "related_anime"
    ].joined(separator: ",")

    private init() {}

    private var tmdbMatchCacheLanguage: String {
        UserDefaults.standard.string(forKey: "tmdbLanguage") ?? "en-US"
    }

    private var clientID: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "MALClientID") as? String ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("$(") ? "" : trimmed
    }

    func fetchAllAnimeCatalogs(
        limit: Int,
        tmdbService: TMDBService
    ) async throws -> [AniListService.AniListCatalogKind: [TMDBSearchResult]] {
        async let trending = fetchRankingCatalog(type: "airing", limit: limit, tmdbService: tmdbService)
        async let popular = fetchRankingCatalog(type: "bypopularity", limit: limit, tmdbService: tmdbService)
        async let topRated = fetchRankingCatalog(type: "all", limit: limit, tmdbService: tmdbService)
        async let airing = fetchRankingCatalog(type: "airing", limit: limit, tmdbService: tmdbService)
        async let upcoming = fetchRankingCatalog(type: "upcoming", limit: limit, tmdbService: tmdbService)

        return [
            .trending: try await trending,
            .popular: try await popular,
            .topRated: try await topRated,
            .airing: try await airing,
            .upcoming: try await upcoming
        ]
    }

    func fetchAiringSchedule(daysAhead: Int, perPage: Int) async throws -> [AniListAiringScheduleEntry] {
        let current = malSeason(for: Date())
        let next = nextSeason(after: current)
        let currentAnime = try await fetchSeasonAnime(year: current.year, season: current.season, limit: perPage)
        let nextAnime = (try? await fetchSeasonAnime(year: next.year, season: next.season, limit: perPage)) ?? []
        let all = Array((currentAnime + nextAnime)
            .filter { !isAdultScheduleAnime($0) }
            .prefix(perPage * 2))

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: max(daysAhead, 1), to: start) ?? start

        return all.compactMap { detail in
            guard let airingAt = estimatedNextAiringDate(for: detail, start: start, end: end) else { return nil }
            let episode = estimatedNextEpisode(for: detail, airingAt: airingAt)
            return AniListAiringScheduleEntry(
                id: malProviderId(detail.id),
                mediaId: malProviderId(detail.id),
                title: displayTitle(for: detail),
                airingAt: airingAt,
                episode: episode,
                coverImage: detail.mainPicture?.large ?? detail.mainPicture?.medium,
                englishTitle: detail.alternativeTitles?.en,
                romajiTitle: detail.title,
                nativeTitle: detail.alternativeTitles?.ja,
                format: aniListFormat(from: detail.mediaType),
                hasKnownAiringTime: false
            )
        }
        .sorted { $0.airingAt < $1.airingAt }
    }

    func fetchAnimeDetailsWithEpisodes(
        title: String,
        tmdbShowId: Int,
        tmdbService: TMDBService,
        tmdbShowPoster: String?
    ) async throws -> AniListAnimeWithSeasons {
        let tvShowDetail = try? await tmdbService.getTVShowWithSeasons(id: tmdbShowId)
        let candidates = try await searchCandidates(title: title, tmdbShowId: tmdbShowId, tmdbShow: tvShowDetail, tmdbService: tmdbService)
        guard let root = pickBestMALMatch(from: candidates, tmdbShow: tvShowDetail) else {
            throw NSError(domain: "MALMetadata", code: 404, userInfo: [NSLocalizedDescriptionKey: "MAL did not return a usable anime match for \(title)"])
        }

        var collected: [MALAnimeDetails] = []
        var queue: [MALAnimeDetails] = [root]
        var seen = Set<Int>([root.id])

        func append(_ detail: MALAnimeDetails) {
            collected.append(detail)
        }
        append(root)

        while !queue.isEmpty && collected.count < 12 {
            let current = queue.removeFirst()
            for relation in current.relatedAnime ?? [] {
                guard isNormalSeasonRelation(relation.relationType) else { continue }
                let id = relation.node.id
                guard seen.insert(id).inserted else { continue }
                guard let detail = try? await fetchAnimeDetails(id: id), isNormalSeasonCandidate(detail) else { continue }
                append(detail)
                queue.append(detail)
            }
        }

        if let tmdbTotal = tvShowDetail?.numberOfEpisodes, tmdbTotal > 0 {
            let total = collected.reduce(0) { $0 + max($1.numEpisodes ?? 0, 0) }
            if total < Int(Double(tmdbTotal) * 0.75) {
                let orphans = await orphanCandidates(root: root, title: title, tmdbShow: tvShowDetail)
                for orphan in orphans where !seen.contains(orphan.id) && collected.count < 12 {
                    seen.insert(orphan.id)
                    collected.append(orphan)
                }
            }

            let newTotal = collected.reduce(0) { $0 + max($1.numEpisodes ?? 0, 0) }
            if newTotal > Int(Double(tmdbTotal) * 1.25), let rootIndex = collected.firstIndex(where: { $0.id == root.id }) {
                collected = pruneMALSeasons(collected, rootIndex: rootIndex, tmdbEpisodeBudget: Int(Double(tmdbTotal) * 1.25))
            }
        }

        collected.sort { lhs, rhs in
            let lhsDate = sortableDate(for: lhs) ?? "9999-99-99"
            let rhsDate = sortableDate(for: rhs) ?? "9999-99-99"
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return lhs.id < rhs.id
        }

        let tmdbEpisodesByAbsolute = await fetchTMDBEpisodesByAbsolute(tmdbShowId: tmdbShowId, tvShowDetail: tvShowDetail, tmdbService: tmdbService)
        var currentAbsoluteEpisode = 1
        var seasonNumber = 1
        var seasons: [AniListSeasonWithPoster] = []

        for detail in collected {
            let episodeCount = resolvedEpisodeCount(for: detail, currentAbsoluteEpisode: currentAbsoluteEpisode, tmdbEpisodesByAbsolute: tmdbEpisodesByAbsolute)
            let seasonTitle = displayTitle(for: detail)
            let episodes = (0..<episodeCount).map { offset -> AniListEpisode in
                let absolute = currentAbsoluteEpisode + offset
                let local = offset + 1
                if let tmdbEpisode = tmdbEpisodesByAbsolute[absolute] {
                    return AniListEpisode(
                        number: local,
                        title: tmdbEpisode.name,
                        description: tmdbEpisode.overview,
                        seasonNumber: seasonNumber,
                        stillPath: tmdbEpisode.stillPath,
                        airDate: tmdbEpisode.airDate,
                        runtime: tmdbEpisode.runtime,
                        tmdbSeasonNumber: tmdbEpisode.seasonNumber,
                        tmdbEpisodeNumber: tmdbEpisode.episodeNumber
                    )
                }
                return AniListEpisode(
                    number: local,
                    title: "Episode \(local)",
                    description: nil,
                    seasonNumber: seasonNumber,
                    stillPath: nil,
                    airDate: nil,
                    runtime: nil,
                    tmdbSeasonNumber: nil,
                    tmdbEpisodeNumber: nil
                )
            }

            seasons.append(AniListSeasonWithPoster(
                seasonNumber: seasonNumber,
                anilistId: malProviderId(detail.id),
                kitsuId: nil,
                title: seasonTitle,
                englishTitle: detail.alternativeTitles?.en,
                romajiTitle: detail.title,
                nativeTitle: detail.alternativeTitles?.ja,
                episodes: episodes,
                posterUrl: detail.mainPicture?.large ?? detail.mainPicture?.medium ?? tmdbShowPoster
            ))

            currentAbsoluteEpisode += episodeCount
            seasonNumber += 1
        }

        let totalEpisodes = seasons.reduce(0) { $0 + $1.episodes.count }
        Logger.shared.log("MALMetadata: built fallback structure title='\(displayTitle(for: root))' seasons=\(seasons.count) episodes=\(totalEpisodes)", type: "AniList")
        return AniListAnimeWithSeasons(
            id: malProviderId(root.id),
            malId: root.id,
            title: displayTitle(for: root),
            genres: root.genres?.compactMap(\.name),
            seasons: seasons,
            totalEpisodes: totalEpisodes,
            status: root.status?.uppercased() ?? "UNKNOWN",
            rating: rating(from: root)
        )
    }

    func fetchAnimeRating(id: Int) async throws -> AnimeMetadataRating? {
        let detail = try await fetchAnimeDetails(id: abs(id))
        return rating(from: detail)
    }

    func fetchAnimeRating(
        title: String,
        tmdbShowId: Int,
        tmdbShow: TMDBTVShowWithSeasons,
        tmdbService: TMDBService
    ) async throws -> AnimeMetadataRating? {
        let candidates = try await searchCandidates(
            title: title,
            tmdbShowId: tmdbShowId,
            tmdbShow: tmdbShow,
            tmdbService: tmdbService
        )
        guard let root = pickBestMALMatch(from: candidates, tmdbShow: tmdbShow) else {
            throw NSError(domain: "MALMetadata", code: 404, userInfo: [NSLocalizedDescriptionKey: "MAL did not return a usable rating match for \(title)"])
        }
        return rating(from: root)
    }

    func fetchSpecialSearchEntries(
        tmdbShowId: Int,
        fallbackPosterURL: String?,
        tmdbService: TMDBService
    ) async -> [AniListSpecialSearchEntry] {
        guard let show = try? await tmdbService.getTVShowWithSeasons(id: tmdbShowId),
              let candidates = try? await searchCandidates(title: show.name, tmdbShowId: tmdbShowId, tmdbShow: show, tmdbService: tmdbService),
              let root = candidates.first else {
            return []
        }

        let related = root.relatedAnime ?? []
        var results: [AniListSpecialSearchEntry] = []
        for relation in related where isSpecialRelation(relation.relationType) {
            guard let detail = try? await fetchAnimeDetails(id: relation.node.id), isSpecialCandidate(detail) else { continue }
            let episodeCount = max(detail.numEpisodes ?? 1, 1)
            let title = displayTitle(for: detail)
            let episodes = (1...episodeCount).map { number in
                AniListEpisode(
                    number: number,
                    title: episodeCount == 1 ? title : "Episode \(number)",
                    description: nil,
                    seasonNumber: 0,
                    stillPath: nil,
                    airDate: nil,
                    runtime: nil,
                    tmdbSeasonNumber: nil,
                    tmdbEpisodeNumber: nil
                )
            }
            results.append(AniListSpecialSearchEntry(
                id: malProviderId(detail.id),
                title: title,
                englishTitle: detail.alternativeTitles?.en,
                romajiTitle: detail.title,
                nativeTitle: detail.alternativeTitles?.ja,
                format: aniListFormat(from: detail.mediaType),
                episodeCount: episodeCount,
                posterUrl: detail.mainPicture?.large ?? detail.mainPicture?.medium ?? fallbackPosterURL,
                tmdbSeasonNumber: nil,
                tvdbSeasonNumber: nil,
                episodeOffset: nil,
                imdbId: nil,
                releaseDate: detail.startDate,
                episodes: episodes
            ))
        }
        return results.sorted { $0.isOrderedBeforeSpecialEntry($1) }
    }

    func fetchParentTitleCandidates(forMalMediaId mediaId: Int, maxDepth: Int) async -> [(englishTitle: String?, romajiTitle: String?, nativeTitle: String?)] {
        var currentId = abs(mediaId)
        var visited = Set<Int>([currentId])
        var results: [(englishTitle: String?, romajiTitle: String?, nativeTitle: String?)] = []

        for _ in 0..<maxDepth {
            guard let detail = try? await fetchAnimeDetails(id: currentId) else { break }
            let parent = (detail.relatedAnime ?? [])
                .filter { ["prequel", "parent_story", "main_story", "full_story"].contains($0.relationType.lowercased()) }
                .first { !visited.contains($0.node.id) }
            guard let parent else { break }
            visited.insert(parent.node.id)
            results.append((parent.node.title, parent.node.title, nil))
            currentId = parent.node.id
        }

        return results
    }

    private func fetchRankingCatalog(type: String, limit: Int, tmdbService: TMDBService) async throws -> [TMDBSearchResult] {
        let details = try await fetchRanking(type: type, limit: limit)
        let mapped = await mapMALAnimeToTMDB(details, tmdbService: tmdbService)
        return details.compactMap { mapped[$0.id] }
    }

    private func searchCandidates(
        title: String,
        tmdbShowId: Int,
        tmdbShow: TMDBTVShowWithSeasons?,
        tmdbService: TMDBService
    ) async throws -> [MALAnimeDetails] {
        var candidates = [title, tmdbShow?.name, tmdbShow?.originalName]
        if let alternatives = try? await tmdbService.getTVShowAlternativeTitles(id: tmdbShowId) {
            candidates.append(contentsOf: alternatives.results.map(\.title))
        }

        var seenQueries = Set<String>()
        var seenIds = Set<Int>()
        var details: [MALAnimeDetails] = []
        for candidate in candidates.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }) where !candidate.isEmpty {
            let key = normalized(candidate)
            guard seenQueries.insert(key).inserted else { continue }
            let nodes = (try? await searchAnime(query: candidate, limit: 8)) ?? []
            for node in nodes where seenIds.insert(node.id).inserted {
                if let detail = try? await fetchAnimeDetails(id: node.id) {
                    details.append(detail)
                }
            }
            if details.count >= 12 { break }
        }
        return details
    }

    private func orphanCandidates(root: MALAnimeDetails, title: String, tmdbShow: TMDBTVShowWithSeasons?) async -> [MALAnimeDetails] {
        let rootKey = normalized(displayTitle(for: root))
        let rootPrefix = String(rootKey.prefix(min(rootKey.count, 12)))
        let searchTitles = [title, root.title, root.alternativeTitles?.en].compactMap { $0 }
        var seenIds = Set<Int>([root.id])
        var candidates: [MALAnimeDetails] = []

        for title in searchTitles {
            guard let nodes = try? await searchAnime(query: title, limit: 20) else { continue }
            for node in nodes where seenIds.insert(node.id).inserted {
                guard let detail = try? await fetchAnimeDetails(id: node.id), isNormalSeasonCandidate(detail) else { continue }
                let candidateKey = normalized(displayTitle(for: detail))
                guard candidateKey.hasPrefix(rootPrefix) || rootKey.hasPrefix(String(candidateKey.prefix(min(candidateKey.count, 12)))) else { continue }
                candidates.append(detail)
            }
        }

        let lastKnownYear = root.startSeason?.year ?? root.startDate.flatMap { Int(String($0.prefix(4))) } ?? 0
        return candidates
            .filter { ($0.startSeason?.year ?? $0.startDate.flatMap { Int(String($0.prefix(4))) } ?? Int.max) >= lastKnownYear }
            .sorted { (sortableDate(for: $0) ?? "9999") < (sortableDate(for: $1) ?? "9999") }
    }

    private func fetchRanking(type: String, limit: Int) async throws -> [MALAnimeDetails] {
        var components = URLComponents(url: apiBase.appendingPathComponent("anime/ranking"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "ranking_type", value: type),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fields", value: detailFields)
        ]
        let response: MALListResponse = try await fetch(components.url!)
        return response.data.map(\.node)
    }

    private func fetchSeasonAnime(year: Int, season: String, limit: Int) async throws -> [MALAnimeDetails] {
        var components = URLComponents(url: apiBase.appendingPathComponent("anime/season/\(year)/\(season)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "sort", value: "anime_num_list_users"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fields", value: detailFields)
        ]
        let response: MALListResponse = try await fetch(components.url!)
        return response.data.map(\.node)
    }

    private func searchAnime(query: String, limit: Int) async throws -> [MALAnimeNode] {
        var components = URLComponents(url: apiBase.appendingPathComponent("anime"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fields", value: "id,title,main_picture,alternative_titles,media_type,num_episodes,start_season,start_date")
        ]
        let response: MALSearchResponse = try await fetch(components.url!)
        return response.data.map(\.node)
    }

    private func fetchAnimeDetails(id: Int) async throws -> MALAnimeDetails {
        var components = URLComponents(url: apiBase.appendingPathComponent("anime/\(id)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "fields", value: detailFields)]
        return try await fetch(components.url!)
    }

    private func fetch<T: Decodable>(_ url: URL) async throws -> T {
        guard !clientID.isEmpty else {
            throw NSError(domain: "MALMetadata", code: -2, userInfo: [NSLocalizedDescriptionKey: "MAL_CLIENT_ID is not configured."])
        }
        var request = URLRequest(url: url)
        request.setValue(clientID, forHTTPHeaderField: "X-MAL-CLIENT-ID")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw NSError(domain: "MALMetadata", code: status, userInfo: [NSLocalizedDescriptionKey: "MAL request failed (\(status))"])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func mapMALAnimeToTMDB(_ animeList: [MALAnimeDetails], tmdbService: TMDBService) async -> [Int: TMDBSearchResult] {
        let cacheLanguage = tmdbMatchCacheLanguage

        return await withTaskGroup(of: (Int, TMDBSearchResult?, AnimeTMDBMatchCacheRecord?).self) { group in
            for anime in animeList {
                group.addTask {
                    let isMovie = self.aniListFormat(from: anime.mediaType) == "MOVIE"
                    let candidates = self.titleCandidates(for: anime)
                    let expectedYear = anime.startSeason?.year ?? anime.startDate.flatMap { Int(String($0.prefix(4))) }
                    let format = self.aniListFormat(from: anime.mediaType)
                    let cacheKey = AnimeTMDBMatchCacheKey(
                        source: .myAnimeList,
                        id: anime.id,
                        language: cacheLanguage,
                        titleCandidates: candidates,
                        expectedYear: expectedYear,
                        format: format
                    )

                    if let cached = await AnimeTMDBMatchCache.shared.lookup(cacheKey) {
                        return (anime.id, cached.result, nil)
                    }

                    var result: TMDBSearchResult?
                    for candidate in candidates {
                        if isMovie,
                           let movies = try? await tmdbService.searchMovies(query: candidate),
                           let best = self.bestMovieMatch(results: movies, candidate: candidate, expectedYear: expectedYear) {
                            result = best.asSearchResult
                            break
                        }
                        if let shows = try? await tmdbService.searchTVShows(query: candidate),
                           let best = self.bestTVMatch(results: shows, candidate: candidate, expectedYear: expectedYear) {
                            result = best.asSearchResult
                            break
                        }
                    }
                    return (anime.id, result, AnimeTMDBMatchCacheRecord(key: cacheKey, result: result))
                }
            }

            var result: [Int: TMDBSearchResult] = [:]
            var cacheRecords: [AnimeTMDBMatchCacheRecord] = []
            for await (id, match, cacheRecord) in group {
                if let match {
                    result[id] = match
                }
                if let cacheRecord {
                    cacheRecords.append(cacheRecord)
                }
            }
            await AnimeTMDBMatchCache.shared.store(cacheRecords)
            return result
        }
    }

    private func bestTVMatch(results: [TMDBTVShow], candidate: String, expectedYear: Int?) -> TMDBTVShow? {
        let key = normalized(candidate)
        return results.min { lhs, rhs in
            matchScore(title: lhs.name, year: lhs.firstAirDate, isAnimation: lhs.genreIds?.contains(16) == true, popularity: lhs.popularity, key: key, expectedYear: expectedYear)
                > matchScore(title: rhs.name, year: rhs.firstAirDate, isAnimation: rhs.genreIds?.contains(16) == true, popularity: rhs.popularity, key: key, expectedYear: expectedYear)
        }
    }

    private func bestMovieMatch(results: [TMDBMovie], candidate: String, expectedYear: Int?) -> TMDBMovie? {
        let key = normalized(candidate)
        return results.min { lhs, rhs in
            matchScore(title: lhs.title, year: lhs.releaseDate, isAnimation: lhs.genreIds?.contains(16) == true, popularity: lhs.popularity, key: key, expectedYear: expectedYear)
                > matchScore(title: rhs.title, year: rhs.releaseDate, isAnimation: rhs.genreIds?.contains(16) == true, popularity: rhs.popularity, key: key, expectedYear: expectedYear)
        }
    }

    private func matchScore(title: String, year: String?, isAnimation: Bool, popularity: Double, key: String, expectedYear: Int?) -> Double {
        let titleKey = normalized(title)
        var score = 0.0
        if titleKey == key { score += 100 }
        if titleKey.contains(key) || key.contains(titleKey) { score += 40 }
        if isAnimation { score += 20 }
        if let expectedYear, let actualYear = year.flatMap({ Int(String($0.prefix(4))) }) {
            score += max(0, 15 - Double(abs(actualYear - expectedYear) * 3))
        }
        score += min(popularity / 100.0, 10)
        return score
    }

    private func pickBestMALMatch(from candidates: [MALAnimeDetails], tmdbShow: TMDBTVShowWithSeasons?) -> MALAnimeDetails? {
        guard let tmdbShow else {
            return candidates
                .filter(isNormalSeasonCandidate)
                .max { ($0.numEpisodes ?? 0) < ($1.numEpisodes ?? 0) } ?? candidates.first
        }

        let tmdbYear = tmdbShow.firstAirDate.flatMap { Int(String($0.prefix(4))) }
        let tmdbEpisodes = tmdbShow.numberOfEpisodes
        let tmdbTitle = normalized(tmdbShow.name)
        let pool = candidates.filter(isNormalSeasonCandidate)
        return (pool.isEmpty ? candidates : pool).max { lhs, rhs in
            malMatchScore(lhs, tmdbTitle: tmdbTitle, tmdbYear: tmdbYear, tmdbEpisodes: tmdbEpisodes)
                < malMatchScore(rhs, tmdbTitle: tmdbTitle, tmdbYear: tmdbYear, tmdbEpisodes: tmdbEpisodes)
        }
    }

    private func malMatchScore(_ anime: MALAnimeDetails, tmdbTitle: String, tmdbYear: Int?, tmdbEpisodes: Int?) -> Int {
        let titles = titleCandidates(for: anime).map(normalized)
        var score = 0
        if titles.contains(tmdbTitle) { score += 100 }
        if titles.contains(where: { $0.contains(tmdbTitle) || tmdbTitle.contains($0) }) { score += 35 }
        if let tmdbYear, let year = anime.startSeason?.year ?? anime.startDate.flatMap({ Int(String($0.prefix(4))) }) {
            score += max(0, 18 - abs(year - tmdbYear) * 4)
        }
        if let tmdbEpisodes, let episodes = anime.numEpisodes, episodes > 0 {
            score += max(0, 20 - abs(episodes - tmdbEpisodes))
        }
        if ["TV", "TV_SHORT", "ONA"].contains(aniListFormat(from: anime.mediaType)) {
            score += 10
        }
        return score
    }

    private func pruneMALSeasons(_ seasons: [MALAnimeDetails], rootIndex: Int, tmdbEpisodeBudget: Int) -> [MALAnimeDetails] {
        guard seasons.indices.contains(rootIndex) else { return seasons }
        var keepStart = rootIndex
        var keepEnd = rootIndex
        var total = seasons[rootIndex].numEpisodes ?? 0
        var canExpandLeft = true
        var canExpandRight = true
        while canExpandLeft || canExpandRight {
            if canExpandLeft && keepStart > 0 {
                let eps = seasons[keepStart - 1].numEpisodes ?? 0
                if total + eps <= tmdbEpisodeBudget { keepStart -= 1; total += eps } else { canExpandLeft = false }
            } else {
                canExpandLeft = false
            }
            if canExpandRight && keepEnd < seasons.count - 1 {
                let eps = seasons[keepEnd + 1].numEpisodes ?? 0
                if total + eps <= tmdbEpisodeBudget { keepEnd += 1; total += eps } else { canExpandRight = false }
            } else {
                canExpandRight = false
            }
        }
        return Array(seasons[keepStart...keepEnd])
    }

    private func fetchTMDBEpisodesByAbsolute(tmdbShowId: Int, tvShowDetail: TMDBTVShowWithSeasons?, tmdbService: TMDBService) async -> [Int: TMDBEpisode] {
        var byAbsolute: [Int: TMDBEpisode] = [:]
        let seasonNumbers = tvShowDetail?.seasons.filter { $0.seasonNumber > 0 }.map(\.seasonNumber).sorted() ?? Array(1...12)
        var absolute = 1
        for seasonNumber in seasonNumbers {
            guard let detail = try? await tmdbService.getSeasonDetails(tvShowId: tmdbShowId, seasonNumber: seasonNumber),
                  !detail.episodes.isEmpty else {
                if tvShowDetail == nil { break }
                continue
            }
            for episode in detail.episodes.sorted(by: { $0.episodeNumber < $1.episodeNumber }) {
                byAbsolute[absolute] = episode
                absolute += 1
            }
        }
        return byAbsolute
    }

    private func resolvedEpisodeCount(for detail: MALAnimeDetails, currentAbsoluteEpisode: Int, tmdbEpisodesByAbsolute: [Int: TMDBEpisode]) -> Int {
        if let count = detail.numEpisodes, count > 0 { return count }
        let remaining = max(0, tmdbEpisodesByAbsolute.count - currentAbsoluteEpisode + 1)
        return remaining > 0 ? remaining : 12
    }

    private func isNormalSeasonRelation(_ relationType: String) -> Bool {
        ["sequel", "prequel", "parent_story", "main_story", "full_story"].contains(relationType.lowercased())
    }

    private func isSpecialRelation(_ relationType: String) -> Bool {
        ["side_story", "spin_off", "other", "summary", "alternative_version"].contains(relationType.lowercased())
    }

    private func isNormalSeasonCandidate(_ detail: MALAnimeDetails) -> Bool {
        let format = aniListFormat(from: detail.mediaType)
        guard ["TV", "TV_SHORT", "ONA"].contains(format) else { return false }
        let text = titleCandidates(for: detail).joined(separator: " ").lowercased()
        return !["recap", "summary", "music", "trailer", "pv", "cm"].contains { text.contains($0) }
    }

    private func isSpecialCandidate(_ detail: MALAnimeDetails) -> Bool {
        let format = aniListFormat(from: detail.mediaType)
        if ["SPECIAL", "OVA", "ONA", "MOVIE"].contains(format) { return true }
        let text = titleCandidates(for: detail).joined(separator: " ").lowercased()
        return ["special", "ova", "oad", "ona", "side story", "movie"].contains { text.contains($0) }
    }

    private func isAdultScheduleAnime(_ detail: MALAnimeDetails) -> Bool {
        if detail.rating?.lowercased() == "rx" {
            return true
        }

        let genreText = detail.genres?.compactMap(\.name).joined(separator: " ").lowercased() ?? ""
        return ["hentai", "erotica"].contains { genreText.contains($0) }
    }

    private func titleCandidates(for detail: MALAnimeDetails) -> [String] {
        var seen = Set<String>()
        let ordered = [
            detail.alternativeTitles?.en,
            detail.title,
            detail.alternativeTitles?.ja
        ] + (detail.alternativeTitles?.synonyms ?? [])
        return ordered.compactMap { raw in
            let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else { return nil }
            let key = value.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return value
        }
    }

    private func displayTitle(for detail: MALAnimeDetails) -> String {
        guard let englishTitle = detail.alternativeTitles?.en,
              !englishTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return detail.title
        }
        return englishTitle
    }

    private func rating(from detail: MALAnimeDetails) -> AnimeMetadataRating? {
        guard let mean = detail.mean, mean > 0 else { return nil }
        return AnimeMetadataRating(value: min(max(mean, 0), 10), source: .myAnimeList)
    }

    private func estimatedNextAiringDate(for detail: MALAnimeDetails, start: Date, end: Date) -> Date? {
        guard detail.status == "currently_airing" else { return nil }
        var calendar = Calendar.current
        calendar.timeZone = .current
        let weekday = weekdayNumber(from: detail.broadcast?.dayOfTheWeek) ?? calendar.component(.weekday, from: start)
        var candidate = start
        for _ in 0..<8 {
            if calendar.component(.weekday, from: candidate) == weekday {
                let timeParts = (detail.broadcast?.startTime ?? "20:00").split(separator: ":").compactMap { Int($0) }
                var components = calendar.dateComponents([.year, .month, .day], from: candidate)
                components.hour = timeParts.first ?? 20
                components.minute = timeParts.dropFirst().first ?? 0
                if let date = calendar.date(from: components), date >= start, date < end {
                    return date
                }
            }
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        return nil
    }

    private func estimatedNextEpisode(for detail: MALAnimeDetails, airingAt: Date) -> Int {
        guard let startDate = detail.startDate,
              let start = MALMetadataService.dateFormatter.date(from: startDate) else {
            return 1
        }
        let weeks = max(0, Calendar.current.dateComponents([.weekOfYear], from: start, to: airingAt).weekOfYear ?? 0)
        let maxEpisodes = detail.numEpisodes ?? Int.max
        return min(max(weeks + 1, 1), maxEpisodes)
    }

    private func weekdayNumber(from value: String?) -> Int? {
        switch value?.lowercased() {
        case "sunday": return 1
        case "monday": return 2
        case "tuesday": return 3
        case "wednesday": return 4
        case "thursday": return 5
        case "friday": return 6
        case "saturday": return 7
        default: return nil
        }
    }

    private func malSeason(for date: Date) -> (year: Int, season: String) {
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        let month = components.month ?? 1
        let season: String
        switch month {
        case 1...3: season = "winter"
        case 4...6: season = "spring"
        case 7...9: season = "summer"
        default: season = "fall"
        }
        return (components.year ?? 2026, season)
    }

    private func nextSeason(after current: (year: Int, season: String)) -> (year: Int, season: String) {
        switch current.season {
        case "winter": return (current.year, "spring")
        case "spring": return (current.year, "summer")
        case "summer": return (current.year, "fall")
        default: return (current.year + 1, "winter")
        }
    }

    private func sortableDate(for detail: MALAnimeDetails) -> String? {
        detail.startDate ?? detail.startSeason.map { String(format: "%04d-%02d-01", $0.year, month(forMALSeason: $0.season)) }
    }

    private func month(forMALSeason season: String) -> Int {
        switch season.lowercased() {
        case "winter": return 1
        case "spring": return 4
        case "summer": return 7
        case "fall": return 10
        default: return 1
        }
    }

    private func aniListFormat(from malMediaType: String?) -> String {
        switch malMediaType?.lowercased() {
        case "tv": return "TV"
        case "ova": return "OVA"
        case "movie": return "MOVIE"
        case "special", "tv_special": return "SPECIAL"
        case "ona": return "ONA"
        default: return "TV"
        }
    }

    private func malProviderId(_ malId: Int) -> Int {
        -abs(malId)
    }

    private func normalized(_ value: String) -> String {
        value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private struct MALSearchResponse: Decodable {
        let data: [Entry]
        struct Entry: Decodable { let node: MALAnimeNode }
    }

    private struct MALListResponse: Decodable {
        let data: [Entry]
        struct Entry: Decodable { let node: MALAnimeDetails }
    }

    private struct MALAnimeNode: Decodable {
        let id: Int
        let title: String
    }

    private struct MALAnimeDetails: Decodable {
        let id: Int
        let title: String
        let mainPicture: MALPicture?
        let alternativeTitles: MALAlternativeTitles?
        let mean: Double?
        let startDate: String?
        let mediaType: String?
        let status: String?
        let numEpisodes: Int?
        let startSeason: MALStartSeason?
        let broadcast: MALBroadcast?
        let rating: String?
        let genres: [MALGenre]?
        let relatedAnime: [MALRelatedAnime]?

        enum CodingKeys: String, CodingKey {
            case id, title, mean, status, broadcast, rating, genres
            case mainPicture = "main_picture"
            case alternativeTitles = "alternative_titles"
            case startDate = "start_date"
            case mediaType = "media_type"
            case numEpisodes = "num_episodes"
            case startSeason = "start_season"
            case relatedAnime = "related_anime"
        }
    }

    private struct MALPicture: Decodable {
        let medium: String?
        let large: String?
    }

    private struct MALAlternativeTitles: Decodable {
        let synonyms: [String]?
        let en: String?
        let ja: String?
    }

    private struct MALStartSeason: Decodable {
        let year: Int
        let season: String
    }

    private struct MALBroadcast: Decodable {
        let dayOfTheWeek: String?
        let startTime: String?

        enum CodingKeys: String, CodingKey {
            case dayOfTheWeek = "day_of_the_week"
            case startTime = "start_time"
        }
    }

    private struct MALGenre: Decodable {
        let name: String?
    }

    private struct MALRelatedAnime: Decodable {
        let node: MALAnimeNode
        let relationType: String

        enum CodingKeys: String, CodingKey {
            case node
            case relationType = "relation_type"
        }
    }
}
