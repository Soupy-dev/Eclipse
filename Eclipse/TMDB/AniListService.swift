import Foundation

import Network
#if canImport(UIKit)
import UIKit
#endif

/// Numeric values received from catalog providers are not trusted until they
/// pass this boundary. The limits are intentionally much larger than any
/// plausible title while still preventing attacker-controlled ranges,
/// allocations, and composite arithmetic from becoming release-time crashes.
enum RemoteMediaNumericBoundary {
    static let maximumIdentifier = Int(Int32.max)
    static let maximumSeasonNumber = 10_000
    static let maximumEpisodeCount = 10_000
    static let maximumTotalEpisodeCount = 20_000
    static let maximumEpisodeOffset = 1_000_000
    static let minimumYear = 1_800
    static let maximumYear = 3_000
    static let maximumRemoteRows = 10_000
    static let maximumRelationCount = 512
    static let maximumMetadataResponseBytes = 8 * 1_024 * 1_024

    static func positiveIdentifier(_ value: Int?) -> Int? {
        guard let value, (1...maximumIdentifier).contains(value) else { return nil }
        return value
    }

    static func seasonNumber(_ value: Int?, allowsZero: Bool = false) -> Int? {
        guard let value else { return nil }
        let range = allowsZero ? 0...maximumSeasonNumber : 1...maximumSeasonNumber
        return range.contains(value) ? value : nil
    }

    static func episodeCount(_ value: Int?) -> Int? {
        guard let value, (1...maximumEpisodeCount).contains(value) else { return nil }
        return value
    }

    static func episodeNumber(_ value: Int?) -> Int? {
        episodeCount(value)
    }

    static func signedEpisodeOffset(_ value: Int?) -> Int? {
        guard let value, (-maximumEpisodeOffset...maximumEpisodeOffset).contains(value) else {
            return nil
        }
        return value
    }

    static func year(_ value: Int?) -> Int? {
        guard let value, (minimumYear...maximumYear).contains(value) else { return nil }
        return value
    }

    static func boundedSum<S: Sequence>(
        _ values: S,
        maximum: Int = maximumTotalEpisodeCount
    ) -> Int? where S.Element == Int {
        var total = 0
        for value in values {
            guard value >= 0, value <= maximum - total else { return nil }
            total += value
        }
        return total
    }

    static func adding(_ lhs: Int, _ rhs: Int) -> Int? {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : value
    }

    static func saturatingNonnegativeSum<S>(_ values: S) -> Int where S: Sequence, S.Element == Int {
        var total = 0
        for value in values {
            let (next, overflow) = total.addingReportingOverflow(max(0, value))
            if overflow { return Int.max }
            total = next
        }
        return total
    }

    static func saturatingNonnegativeProduct(_ lhs: Int, _ rhs: Int) -> Int {
        let (product, overflow) = max(0, lhs).multipliedReportingOverflow(by: max(0, rhs))
        return overflow ? Int.max : product
    }

    static func scaledEpisodeCount(
        _ value: Int,
        numerator: Int,
        denominator: Int
    ) -> Int? {
        guard value >= 0,
              value <= maximumTotalEpisodeCount,
              numerator >= 0,
              denominator > 0 else { return nil }
        let (product, overflow) = value.multipliedReportingOverflow(by: numerator)
        guard !overflow else { return nil }
        return product / denominator
    }

    static func absoluteDifference(_ lhs: Int, _ rhs: Int) -> Int? {
        let (difference, overflow) = lhs.subtractingReportingOverflow(rhs)
        guard !overflow, difference != Int.min else { return nil }
        return difference < 0 ? -difference : difference
    }

    static func positiveMagnitude(_ value: Int?) -> Int? {
        guard let value, value != Int.min else { return nil }
        return positiveIdentifier(value < 0 ? -value : value)
    }

    static func negativeProviderIdentifier(_ value: Int?) -> Int? {
        positiveIdentifier(value).map { -$0 }
    }

    /// Preserves the existing arithmetic for ordinary values. If a synthetic
    /// identity would overflow, a stable non-zero fallback is used instead.
    static func syntheticIdentifier(_ weightedComponents: [(Int, Int)]) -> Int {
        var total = 0
        var overflowed = false
        for (value, multiplier) in weightedComponents {
            let (product, productOverflow) = value.multipliedReportingOverflow(by: multiplier)
            let (next, sumOverflow) = total.addingReportingOverflow(product)
            if productOverflow || sumOverflow {
                overflowed = true
                break
            }
            total = next
        }
        if !overflowed, total != 0 { return total }

        var hash: UInt64 = 14_695_981_039_346_656_037
        for (value, multiplier) in weightedComponents {
            hash ^= UInt64(truncatingIfNeeded: value)
            hash &*= 1_099_511_628_211
            hash ^= UInt64(truncatingIfNeeded: multiplier)
            hash &*= 1_099_511_628_211
        }
        let bounded = hash & UInt64(Int.max)
        return max(1, Int(bounded))
    }

    static func seasonEpisodeCounts(
        _ pairs: [(season: Int, count: Int)]
    ) -> [Int: Int]? {
        var result: [Int: Int] = [:]
        var total = 0
        for pair in pairs {
            guard let season = seasonNumber(pair.season),
                  let count = episodeCount(pair.count),
                  result[season] == nil,
                  count <= maximumTotalEpisodeCount - total else {
                return nil
            }
            result[season] = count
            total += count
        }
        return result
    }
}

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

enum AnimeProviderReadAdmission: Equatable {
    case allowed
    case blocked
    case recoveryProbe
}

enum AnimeProviderOutagePolicy {
    static func readAdmission(unavailableUntil: Date?, now: Date = Date()) -> AnimeProviderReadAdmission {
        guard let unavailableUntil else { return .allowed }
        return unavailableUntil > now ? .blocked : .recoveryProbe
    }
}

enum AniListGraphQLDocumentPolicy {
    static func isReadOnly(_ document: String) -> Bool {
        let normalized = document.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.hasPrefix("query") || normalized.hasPrefix("{")
    }

    static func isReadOnly(_ request: URLRequest) -> Bool {
        guard let body = request.httpBody,
              let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let document = payload["query"] as? String else {
            return false
        }
        return isReadOnly(document)
    }
}

enum AniListReadGateError: Error, LocalizedError {
    case cooldown

    var errorDescription: String? {
        "AniList request skipped while the provider is temporarily unavailable"
    }
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
        aniListReadAdmission() == .blocked
    }

    func aniListReadAdmission(now: Date = Date()) -> AnimeProviderReadAdmission {
        lock.lock()
        defer { lock.unlock() }
        return AnimeProviderOutagePolicy.readAdmission(
            unavailableUntil: anilistUnavailableUntil,
            now: now
        )
    }

    func admitAniListRead(endpoint: URL) async throws {
        switch aniListReadAdmission() {
        case .allowed:
            return
        case .blocked:
            throw AniListReadGateError.cooldown
        case .recoveryProbe:
            try await AniListRecoveryProbeCoordinator.shared.recover(endpoint: endpoint)
        }
    }

    @discardableResult
    func recordAniListFailure(_ error: Error) -> AnimeProviderFailureReason {
        if error is AniListReadGateError {
            return .anilistUnavailable
        }
        let reason = classifyAniListFailure(error)
        switch reason {
        case .offline:
            resetAniListUnavailableFailures()
            Logger.shared.log("AnimeMetadata: AniList failure classified as offline: \(error.localizedDescription)", type: "AniList")
        case .anilistRateLimited:
            resetAniListUnavailableFailures()
            Logger.shared.log("AnimeMetadata: AniList rate limited, fallback allowed: \(error.localizedDescription)", type: "AniList")
        case .anilistUnavailable:
            if isExplicitAniListShutdown(error) || noteAniListUnavailableFailure() {
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

    @discardableResult
    func recordAniListRecoveryProbeFailure(_ error: Error) -> AnimeProviderFailureReason {
        let reason = classifyAniListFailure(error)
        markAniListUnavailable(seconds: 180)
        Logger.shared.log("AnimeMetadata: AniList recovery probe failed, retry deferred: \(error.localizedDescription)", type: "AniList")
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

    func classifyAniListFailure(_ error: Error) -> AnimeProviderFailureReason {

        if error is AniListReadGateError { return .anilistUnavailable }
        if error is AniListRateLimiterError { return .anilistRateLimited }

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
            if nsError.code == 403,
               nsError.localizedDescription.localizedCaseInsensitiveContains("temporarily disabled")
                || nsError.localizedDescription.localizedCaseInsensitiveContains("severe stability issues") {
                return .anilistUnavailable
            }
            if nsError.code >= 500 {
                return currentNetworkReachable() ? .anilistUnavailable : .offline
            }
            if nsError.code == NSURLErrorNotConnectedToInternet { return .offline }
            return .unknown
        }

        return currentNetworkReachable() ? .unknown : .offline
    }

    private func isExplicitAniListShutdown(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == "AniList", nsError.code == 403 else { return false }
        return nsError.localizedDescription.localizedCaseInsensitiveContains("temporarily disabled")
            || nsError.localizedDescription.localizedCaseInsensitiveContains("severe stability issues")
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

private enum AniListRecoveryProbeRequest {
    static func execute(endpoint: URL) async throws {
        try await AniListRateLimiter.shared.waitForSlot(
            deadline: Date().addingTimeInterval(5)
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": "query { Page(perPage: 1) { media(type: ANIME) { id } } }"
        ])
        let (data, response) = try await URLSession.shared.boundedData(
            for: request,
            maximumResponseBytes: RemoteMediaNumericBoundary.maximumMetadataResponseBytes
        )
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "AniList",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "AniList recovery probe returned an invalid response"]
            )
        }
        await AniListRateLimiter.shared.recordResponse(httpResponse)
        let details = responseDetails(from: data)
        guard httpResponse.statusCode == 200 else {
            throw NSError(
                domain: "AniList",
                code: httpResponse.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey: "AniList recovery probe failed (HTTP \(httpResponse.statusCode)): \(details)"
                ]
            )
        }
        guard graphQLErrorMessage(from: data) == nil,
              hasValidPayload(data) else {
            throw NSError(
                domain: "AniList",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "AniList recovery probe returned an invalid GraphQL response: \(details)"]
            )
        }
    }

    private static func graphQLErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = json["errors"] as? [[String: Any]],
              let first = errors.first else {
            return nil
        }
        return first["message"] as? String
    }

    private static func hasValidPayload(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["data"] as? [String: Any],
              let page = payload["Page"] as? [String: Any] else {
            return false
        }
        return page["media"] is [[String: Any]]
    }

    private static func responseDetails(from data: Data) -> String {
        if let message = graphQLErrorMessage(from: data) {
            return message
        }
        let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 response>"
        return String(raw.prefix(500))
    }
}

private actor AniListRecoveryProbeCoordinator {
    static let shared = AniListRecoveryProbeCoordinator()

    private var activeProbe: (id: UInt64, task: Task<Void, Error>)?
    private var nextProbeID: UInt64 = 0

    func recover(endpoint: URL) async throws {
        let probe: (id: UInt64, task: Task<Void, Error>)
        if let activeProbe {
            probe = activeProbe
        } else {
            nextProbeID &+= 1
            let task = Task {
                try await AniListRecoveryProbeRequest.execute(endpoint: endpoint)
            }
            probe = (nextProbeID, task)
            activeProbe = probe
            Logger.shared.log("AnimeMetadata: AniList recovery probe started", type: "AniList")
        }

        do {
            try await probe.task.value
            if activeProbe?.id == probe.id {
                activeProbe = nil
                AnimeProviderHealthCenter.shared.recordAniListSuccess()
                Logger.shared.log("AnimeMetadata: AniList recovery probe succeeded", type: "AniList")
            }
        } catch {
            if activeProbe?.id == probe.id {
                activeProbe = nil
                AnimeProviderHealthCenter.shared.recordAniListRecoveryProbeFailure(error)
            }
            throw error
        }
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
    private var didLoad = false

    private init() {
        let cacheDirectory = FileManager.default.eclipseCachesDirectories[0]
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

struct AnimeEpisodeGraphCacheCandidate: Equatable {
    let key: String
    let storedAt: TimeInterval
    let episodeCost: Int
}

enum AnimeEpisodeGraphCachePolicy {
    static func episodeCost(of value: AniListAnimeWithSeasons) -> Int {
        let representedEpisodeCount = max(
            max(0, value.totalEpisodes),
            RemoteMediaNumericBoundary.saturatingNonnegativeSum(
                value.seasons.map { $0.episodes.count }
            )
        )
        let seasonCost = RemoteMediaNumericBoundary.saturatingNonnegativeProduct(
            value.seasons.count,
            4
        )
        return max(
            1,
            RemoteMediaNumericBoundary.saturatingNonnegativeSum([
                representedEpisodeCount,
                seasonCost
            ])
        )
    }

    static func retainedKeys(
        candidates: [AnimeEpisodeGraphCacheCandidate],
        maximumEntryCount: Int,
        maximumEpisodeCost: Int
    ) -> Set<String> {
        var retained = candidates.sorted { lhs, rhs in
            if lhs.storedAt != rhs.storedAt {
                return lhs.storedAt > rhs.storedAt
            }
            return lhs.key < rhs.key
        }
        func totalEpisodeCost() -> Int {
            RemoteMediaNumericBoundary.saturatingNonnegativeSum(
                retained.map { max(1, $0.episodeCost) }
            )
        }
        var totalCost = totalEpisodeCost()
        let entryLimit = max(1, maximumEntryCount)
        let costLimit = max(1, maximumEpisodeCost)

        while retained.count > 1,
              retained.count > entryLimit || totalCost > costLimit {
            _ = retained.removeLast()
            totalCost = totalEpisodeCost()
        }
        return Set(retained.map(\.key))
    }
}

actor AnimeIdentityCache {
    static let shared = AnimeIdentityCache()

    private struct CachedDetails: Codable {
        let value: AniListAnimeWithSeasons
        let storedAt: TimeInterval
        let languageCode: String?
    }

    private static let detailsKey = "anime.metadata.details.cache.v17"
    private static let supersededDetailsKeys = [
        "anime.metadata.details.cache.v16",
        "anime.metadata.details.cache.v15",
        "anime.metadata.details.cache.v14",
        "anime.metadata.details.cache.v13",
        "anime.metadata.details.cache.v12",
        "anime.metadata.details.cache.v11",
        "anime.metadata.details.cache.v10",
        "anime.metadata.details.cache.v9",
        "anime.metadata.details.cache.v8",
        "anime.metadata.details.cache.v7",
        "anime.metadata.details.cache.v6",
        "anime.metadata.details.cache.v5",
        "anime.metadata.details.cache.v4",
        "anime.metadata.details.cache.v1",
        "anime.metadata.details.cache.v2",
        "anime.metadata.details.cache.v3"
    ]
    private static let maxAge: TimeInterval = 60 * 60 * 24 * 45

    private static let freshMaxAge: TimeInterval = 60 * 60

    private static let maximumEntryCount = 16
    private static let maximumEpisodeCost = 4_000
    private var details: [String: CachedDetails]

    private init() {
        for key in Self.supersededDetailsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        if let data = UserDefaults.standard.data(forKey: Self.detailsKey),
           let decoded = try? JSONDecoder().decode([String: CachedDetails].self, from: data) {
            let compacted = Self.pruned(decoded, now: Date().timeIntervalSince1970)
            details = compacted
            if compacted.count != decoded.count {
                Self.persist(compacted)
            }
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
                  now - cached.storedAt <= Self.maxAge,
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
                  now - cached.storedAt <= Self.freshMaxAge else {
                continue
            }
            Logger.shared.log("AnimeMetadataCache: fresh details cache hit key=\(key)", type: "AniList")
            return cached.value
        }
        return nil
    }

    func revalidationCandidate(
        tmdbShowId: Int,
        title: String,
        languageCode: String,
        seedAniListId: Int?,
        seedMALId: Int? = nil
    ) -> AniListAnimeWithSeasons? {
        let now = Date().timeIntervalSince1970
        for key in detailKeys(tmdbShowId: tmdbShowId, title: title) {
            guard let cached = details[key],
                  cached.languageCode == nil || cached.languageCode == languageCode,
                  cached.value.satisfiesIdentitySeeds(
                      aniListID: seedAniListId,
                      malID: seedMALId
                  ) else {
                continue
            }
            let serveMaxAge: TimeInterval
            switch cached.value.status.uppercased() {
            case "RELEASING":
                serveMaxAge = 7 * 24 * 60 * 60
            case "NOT_YET_RELEASED":
                serveMaxAge = 48 * 60 * 60
            default:
                serveMaxAge = Self.maxAge
            }
            let age = now - cached.storedAt
            guard age > Self.freshMaxAge, age <= serveMaxAge else { continue }
            Logger.shared.log(
                "AnimeMetadataCache: revalidation candidate hit key=\(key) ageSeconds=\(Int(age))",
                type: "AniList"
            )
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
        guard animeMetadataCacheReadsAllowed else { return }
        let cached = CachedDetails(
            value: value,
            storedAt: Date().timeIntervalSince1970,
            languageCode: languageCode
        )

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
        details = Self.pruned(details, now: Date().timeIntervalSince1970)
    }

    private static func pruned(
        _ values: [String: CachedDetails],
        now: TimeInterval
    ) -> [String: CachedDetails] {
        let cutoff = now - maxAge
        let fresh = values.filter { $0.value.storedAt >= cutoff }
        let retainedKeys = AnimeEpisodeGraphCachePolicy.retainedKeys(
            candidates: fresh.map { key, entry in
                AnimeEpisodeGraphCacheCandidate(
                    key: key,
                    storedAt: entry.storedAt,
                    episodeCost: AnimeEpisodeGraphCachePolicy.episodeCost(of: entry.value)
                )
            },
            maximumEntryCount: maximumEntryCount,
            maximumEpisodeCost: maximumEpisodeCost
        )
        return fresh.filter { retainedKeys.contains($0.key) }
    }

    private func persist() {
        Self.persist(details)
    }

    private static func persist(_ values: [String: CachedDetails]) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        UserDefaults.standard.set(data, forKey: detailsKey)
    }
}

private actor AnimeRatingCache {
    static let shared = AnimeRatingCache()

    private struct Entry: Codable {
        let rating: AnimeMetadataRating
        let storedAt: TimeInterval
    }

    private let freshMaxAge: TimeInterval = 24 * 60 * 60
    private let staleMaxAge: TimeInterval = 30 * 24 * 60 * 60
    private let fileURL: URL
    private var entries: [Int: Entry]

    private init() {
        let cacheDirectory = FileManager.default.eclipseCachesDirectories[0]
        fileURL = cacheDirectory.appendingPathComponent("anime-mal-rating-cache-v1.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Int: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    func rating(malId: Int, allowStale: Bool = false) -> AnimeMetadataRating? {
        guard let entry = entries[malId] else { return nil }
        let maxAge = allowStale ? staleMaxAge : freshMaxAge
        guard Date().timeIntervalSince1970 - entry.storedAt <= maxAge else {
            if !allowStale { return nil }
            entries[malId] = nil
            return nil
        }
        return entry.rating
    }

    func store(_ rating: AnimeMetadataRating, malId: Int) {
        guard malId > 0 else { return }
        entries[malId] = Entry(rating: rating, storedAt: Date().timeIntervalSince1970)
        let cutoff = Date().timeIntervalSince1970 - staleMaxAge
        entries = entries.filter { $0.value.storedAt >= cutoff }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Logger.shared.log("AnimeRatingCache: persist failed: \(error.localizedDescription)", type: "AniList")
        }
    }
}

private actor AnimeDetailPreviewCache {
    static let shared = AnimeDetailPreviewCache()

    private struct Entry: Codable {
        let value: AniListAnimeWithSeasons
        let storedAt: TimeInterval
    }

    private let fileURL: URL
    private var entries: [String: Entry]
    private var didLoad = false
    private static let staleMaxAge: TimeInterval = 45 * 24 * 60 * 60
    private static let maximumEntryCount = 12
    private static let maximumEpisodeCost = 4_000

    private init() {
        let cacheDirectory = FileManager.default.eclipseCachesDirectories[0]
        fileURL = cacheDirectory.appendingPathComponent("anime-detail-preview-policy-v19.json")
        for version in ["v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "v16", "v17", "v18"] {
            try? FileManager.default.removeItem(
                at: cacheDirectory.appendingPathComponent("anime-detail-preview-policy-\(version).json")
            )
        }
        entries = [:]
    }

    func value(
        tmdbShowId: Int,
        languageCode: String,
        seedAniListId: Int?,
        seedMALId: Int? = nil,
        allowStale: Bool = false
    ) -> AniListAnimeWithSeasons? {
        loadIfNeeded()
        let key = "\(tmdbShowId)|\(languageCode)"
        guard let entry = entries[key],
              entry.value.satisfiesIdentitySeeds(
                  aniListID: seedAniListId,
                  malID: seedMALId
              ) else {
            return nil
        }
        let freshMaxAge: TimeInterval
        switch entry.value.status.uppercased() {
        case "RELEASING": freshMaxAge = 2 * 60 * 60
        case "NOT_YET_RELEASED": freshMaxAge = 30 * 60
        default: freshMaxAge = 7 * 24 * 60 * 60
        }
        let age = Date().timeIntervalSince1970 - entry.storedAt
        guard age <= (allowStale ? Self.staleMaxAge : freshMaxAge) else { return nil }
        return entry.value
    }

    func revalidationCandidate(
        tmdbShowId: Int,
        languageCode: String,
        seedAniListId: Int?,
        seedMALId: Int? = nil
    ) -> AniListAnimeWithSeasons? {
        loadIfNeeded()
        let key = "\(tmdbShowId)|\(languageCode)"
        guard let entry = entries[key],
              entry.value.satisfiesIdentitySeeds(
                  aniListID: seedAniListId,
                  malID: seedMALId
              ) else {
            return nil
        }
        let freshMaxAge: TimeInterval
        let serveMaxAge: TimeInterval
        switch entry.value.status.uppercased() {
        case "RELEASING":
            freshMaxAge = 2 * 60 * 60
            serveMaxAge = 7 * 24 * 60 * 60
        case "NOT_YET_RELEASED":
            freshMaxAge = 30 * 60
            serveMaxAge = 48 * 60 * 60
        default:
            freshMaxAge = 7 * 24 * 60 * 60
            serveMaxAge = Self.staleMaxAge
        }
        let age = Date().timeIntervalSince1970 - entry.storedAt
        guard age > freshMaxAge, age <= serveMaxAge else { return nil }
        return entry.value
    }

    func store(
        _ value: AniListAnimeWithSeasons,
        tmdbShowId: Int,
        languageCode: String
    ) {
        guard animeMetadataCacheReadsAllowed else { return }
        loadIfNeeded()
        entries["\(tmdbShowId)|\(languageCode)"] = Entry(
            value: value,
            storedAt: Date().timeIntervalSince1970
        )
        prune(now: Date().timeIntervalSince1970)
        persist()
    }

    private func prune(now: TimeInterval) {
        let cutoff = now - Self.staleMaxAge
        let fresh = entries.filter { $0.value.storedAt >= cutoff }
        let retainedKeys = AnimeEpisodeGraphCachePolicy.retainedKeys(
            candidates: fresh.map { key, entry in
                AnimeEpisodeGraphCacheCandidate(
                    key: key,
                    storedAt: entry.storedAt,
                    episodeCost: AnimeEpisodeGraphCachePolicy.episodeCost(of: entry.value)
                )
            },
            maximumEntryCount: Self.maximumEntryCount,
            maximumEpisodeCost: Self.maximumEpisodeCost
        )
        entries = fresh.filter { retainedKeys.contains($0.key) }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Logger.shared.log("AnimeDetailPreviewCache: persist failed: \(error.localizedDescription)", type: "AniList")
        }
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
            prune(now: Date().timeIntervalSince1970)
            if entries.count != decoded.count {
                persist()
            }
        }
    }
}

private actor AnimeSpecialEntriesDiskCache {
    static let shared = AnimeSpecialEntriesDiskCache()

    private struct Entry: Codable {
        let entries: [AniListSpecialSearchEntry]
        let storedAt: TimeInterval
    }

    private let fileURL: URL
    private var values: [String: Entry]
    private var didLoad = false
    private let staleMaxAge: TimeInterval = 45 * 24 * 60 * 60

    private init() {
        let cacheDirectory = FileManager.default.eclipseCachesDirectories[0]
        fileURL = cacheDirectory.appendingPathComponent("anime-special-identities-v2.json")
        values = [:]
    }

    func entries(key: String, allowStale: Bool = false) -> [AniListSpecialSearchEntry]? {
        loadIfNeeded()
        guard let entry = values[key] else { return nil }
        let freshMaxAge: TimeInterval
        if entry.entries.contains(where: { $0.status?.uppercased() == "NOT_YET_RELEASED" }) {
            freshMaxAge = 30 * 60
        } else if entry.entries.contains(where: { $0.status?.uppercased() == "RELEASING" }) {
            freshMaxAge = 2 * 60 * 60
        } else {
            freshMaxAge = 24 * 60 * 60
        }
        let maxAge = allowStale ? staleMaxAge : freshMaxAge
        guard Date().timeIntervalSince1970 - entry.storedAt <= maxAge else { return nil }
        return entry.entries
    }

    func store(_ entries: [AniListSpecialSearchEntry], key: String) {
        loadIfNeeded()
        values[key] = Entry(entries: entries, storedAt: Date().timeIntervalSince1970)
        let cutoff = Date().timeIntervalSince1970 - staleMaxAge
        values = values.filter { $0.value.storedAt >= cutoff }
        if values.count > 40 {
            values = Dictionary(uniqueKeysWithValues: values
                .sorted { $0.value.storedAt > $1.value.storedAt }
                .prefix(40)
                .map { ($0.key, $0.value) })
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(values)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Logger.shared.log("AnimeSpecialEntriesDiskCache: persist failed: \(error.localizedDescription)", type: "AniList")
        }
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            values = decoded
        }
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
        token: String?,
        seedAniListId: Int? = nil,
        seedMALId: Int? = nil,
        hydrationPolicy: AnimeEpisodeHydrationPolicy = .complete,
        knownTMDBShowDetail: TMDBTVShowWithSeasons? = nil
    ) async throws -> AniListAnimeWithSeasons {
        try await aniListService.fetchAnimeDetailsWithEpisodes(
            title: title,
            tmdbShowId: tmdbShowId,
            tmdbService: tmdbService,
            tmdbShowPoster: tmdbShowPoster,
            token: token,
            seedAniListId: seedAniListId,
            seedMALId: seedMALId,
            hydrationPolicy: hydrationPolicy,
            knownTMDBShowDetail: knownTMDBShowDetail
        )
    }

    func fetchSpecialSearchEntries(
        tmdbShowId: Int,
        fallbackPosterURL: String?,
        baseAniListIds: [Int] = [],
        requiredSpecialAniListIds: [Int] = [],
        tmdbService: TMDBService
    ) async -> [AniListSpecialSearchEntry] {
        await aniListService.fetchSpecialSearchEntries(
            tmdbShowId: tmdbShowId,
            fallbackPosterURL: fallbackPosterURL,
            baseAniListIds: baseAniListIds,
            requiredSpecialAniListIds: requiredSpecialAniListIds,
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

enum AniListRateLimiterError: Error, LocalizedError {

    case localBackPressure(slotTime: Date, deadline: Date)

    var errorDescription: String? {
        switch self {
        case let .localBackPressure(slotTime, deadline):
            let overshoot = max(0, slotTime.timeIntervalSince(deadline))
            return String(
                format: "AniList request skipped by the local rate limiter: next slot is %.2fs past the caller deadline",
                overshoot
            )
        }
    }
}

actor AniListRateLimiter {
    static let shared = AniListRateLimiter()

    private let gate: TrackerRequestGate

    init(minInterval: TimeInterval = 2, burstCapacity: Int = 1) {
        gate = TrackerRequestGate(minInterval: minInterval, burstCapacity: burstCapacity)
    }

    static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        guard interval.isFinite, interval > 0 else { return 0 }
        let scaled = (interval * 1_000_000_000).rounded(.up)
        guard scaled.isFinite, scaled > 0 else { return UInt64.max }
        return UInt64(exactly: scaled) ?? UInt64.max
    }

    static func boundedRetryAfter(_ rawValue: String?, fallback: TimeInterval = 5) -> TimeInterval {
        TrackerRateLimitHeaderPolicy.retryDelay(rawValue, fallback: fallback)
    }

    static func boundedRateLimitInterval(_ rawValue: String?) -> TimeInterval? {
        TrackerRateLimitHeaderPolicy.minimumSpacing(rawValue)
    }

    static func boundedResetDelay(_ rawValue: String?, now: Date = Date()) -> TimeInterval? {
        TrackerRateLimitHeaderPolicy.resetDelay(rawValue, now: now)
    }

    func waitForSlot(deadline: Date? = nil, priority: TrackerRequestPriority? = nil) async throws {
        try await gate.waitForSlot(deadline: deadline, priority: priority ?? TrackerRequestContext.priority)
    }

    func recordResponse(_ response: HTTPURLResponse) async {
        let interval = Self.boundedRateLimitInterval(response.value(forHTTPHeaderField: "X-RateLimit-Limit"))
        let delay: TimeInterval?
        if response.statusCode == 429 {
            delay = Self.boundedRetryAfter(response.value(forHTTPHeaderField: "Retry-After"))
        } else if let remainingValue = response.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
                  let remaining = Int(remainingValue), remaining <= 1 {
            delay = Self.boundedResetDelay(response.value(forHTTPHeaderField: "X-RateLimit-Reset"))
        } else {
            delay = nil
        }
        await gate.record(interval: interval, pauseUntil: delay.map { Date().addingTimeInterval($0) })
    }

    func pauseUntilRetryAfter(_ response: HTTPURLResponse) async {
        await pause(for: Self.boundedRetryAfter(response.value(forHTTPHeaderField: "Retry-After")))
    }

    func pause(for interval: TimeInterval) async {
        guard interval.isFinite, interval > 0 else { return }
        await gate.pause(until: Date().addingTimeInterval(interval))
    }
}

struct AniMapMapping: Codable, Sendable {
    let malId: Int?
    let anilistId: Int?
    let kitsuId: Int?
    let tmdbShowId: Int?
    let tmdbMovieId: Int?
    let tmdbSeason: Int?
    let tvdbSeason: Int?
    let tvdbEpisodeOffset: Int?
    let imdbId: String?
    let mediaType: String?
    let tvdbId: Int?

    enum CodingKeys: String, CodingKey {
        case malId = "mal_id"
        case anilistId = "anilist_id"
        case kitsuId = "kitsu_id"
        case tmdbShowId = "tmdb_show_id"
        case tmdbMovieId = "tmdb_movie_id"
        case tmdbSeason = "tmdb_season"
        case tvdbSeason = "tvdb_season"
        case tvdbEpisodeOffset = "tvdb_epoffset"
        case imdbId = "imdb_id"
        case mediaType = "media_type"
        case tvdbId = "tvdb_id"
    }

    init(
        malId: Int?, anilistId: Int?, kitsuId: Int?, tmdbShowId: Int?, tmdbMovieId: Int?,
        tmdbSeason: Int?, tvdbSeason: Int?, tvdbEpisodeOffset: Int?, imdbId: String?, mediaType: String?, tvdbId: Int?
    ) {
        self.malId = malId
        self.anilistId = anilistId
        self.kitsuId = kitsuId
        self.tmdbShowId = tmdbShowId
        self.tmdbMovieId = tmdbMovieId
        self.tmdbSeason = tmdbSeason
        self.tvdbSeason = tvdbSeason
        self.tvdbEpisodeOffset = tvdbEpisodeOffset
        self.imdbId = imdbId
        self.mediaType = mediaType
        self.tvdbId = tvdbId
    }

    func relocated(toTMDBShowId showId: Int, season: Int) -> AniMapMapping {
        AniMapMapping(
            malId: malId, anilistId: anilistId, kitsuId: kitsuId, tmdbShowId: showId, tmdbMovieId: nil,
            tmdbSeason: season, tvdbSeason: tvdbSeason, tvdbEpisodeOffset: tvdbEpisodeOffset,
            imdbId: imdbId, mediaType: mediaType, tvdbId: tvdbId
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        func positiveIdentifier(_ key: CodingKeys) throws -> Int? {
            guard let raw = try container.decodeIfPresent(Int.self, forKey: key) else { return nil }
            guard let value = RemoteMediaNumericBoundary.positiveIdentifier(raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "Provider identifier is outside the supported range."
                )
            }
            return value
        }

        func seasonNumber(_ key: CodingKeys) throws -> Int? {
            guard let raw = try container.decodeIfPresent(Int.self, forKey: key) else { return nil }
            if key == .tvdbSeason, raw == -1 {
                return raw
            }
            guard let value = RemoteMediaNumericBoundary.seasonNumber(raw, allowsZero: true) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "Provider season is outside the supported range."
                )
            }
            return value
        }

        malId = try positiveIdentifier(.malId)
        anilistId = try positiveIdentifier(.anilistId)
        kitsuId = try positiveIdentifier(.kitsuId)
        tmdbShowId = try positiveIdentifier(.tmdbShowId)
        tmdbMovieId = try positiveIdentifier(.tmdbMovieId)
        tmdbSeason = try seasonNumber(.tmdbSeason)
        tvdbSeason = try seasonNumber(.tvdbSeason)
        if let rawOffset = try container.decodeIfPresent(Int.self, forKey: .tvdbEpisodeOffset) {
            guard let offset = RemoteMediaNumericBoundary.signedEpisodeOffset(rawOffset) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .tvdbEpisodeOffset,
                    in: container,
                    debugDescription: "Provider episode offset is outside the supported range."
                )
            }
            tvdbEpisodeOffset = offset
        } else {
            tvdbEpisodeOffset = nil
        }
        imdbId = try container.decodeIfPresent(String.self, forKey: .imdbId)
        mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType)
        tvdbId = try positiveIdentifier(.tvdbId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(malId, forKey: .malId)
        try container.encodeIfPresent(anilistId, forKey: .anilistId)
        try container.encodeIfPresent(kitsuId, forKey: .kitsuId)
        try container.encodeIfPresent(tmdbShowId, forKey: .tmdbShowId)
        try container.encodeIfPresent(tmdbMovieId, forKey: .tmdbMovieId)
        try container.encodeIfPresent(tmdbSeason, forKey: .tmdbSeason)
        try container.encodeIfPresent(tvdbSeason, forKey: .tvdbSeason)
        try container.encodeIfPresent(tvdbEpisodeOffset, forKey: .tvdbEpisodeOffset)
        try container.encodeIfPresent(imdbId, forKey: .imdbId)
        try container.encodeIfPresent(mediaType, forKey: .mediaType)
        try container.encodeIfPresent(tvdbId, forKey: .tvdbId)
    }
}

enum AniMapStructuralRole {
    private static let detachedFormats: Set<String> = [
        "SPECIAL", "OVA", "OAD", "ONA", "MOVIE", "MUSIC"
    ]

    static func isRegularStory(
        _ mapping: AniMapMapping,
        fallbackMediaType: String? = nil,
        tmdbSeasonEpisodeCounts: [Int: Int]? = nil,
        episodeCount: Int? = nil,
        regularStoryEpisodeCounts: [Int: Int]? = nil
    ) -> Bool {
        let type = (mapping.mediaType ?? fallbackMediaType)?.uppercased()
        let isRegular: Bool
        switch type {
        case nil, "TV", "TV_SHORT":
            isRegular = true
        case "ONA":
            isRegular = (mapping.tmdbSeason ?? 0) > 0 || (mapping.tvdbSeason ?? 0) > 0
        case "SPECIAL", "OVA", "OAD", "MOVIE":
            isRegular = (mapping.tmdbSeason ?? 0) > 0
        default:
            return false
        }
        guard isRegular else { return false }
        guard ["SPECIAL", "OVA", "OAD", "MOVIE"].contains(type ?? ""),
              let tmdbSeasonEpisodeCounts else { return true }
        guard let season = mapping.tmdbSeason,
              let available = tmdbSeasonEpisodeCounts[season], available > 0 else { return false }
        guard let occupied = regularStoryEpisodeCounts?[season], occupied > 0, occupied <= available else { return true }
        guard occupied < available else { return false }
        guard let count = RemoteMediaNumericBoundary.episodeCount(episodeCount) else { return true }
        return count <= available - occupied
    }

    static func isDetachedSpecial(
        _ mapping: AniMapMapping,
        fallbackMediaType: String? = nil,
        tmdbSeasonEpisodeCounts: [Int: Int]? = nil,
        episodeCount: Int? = nil,
        regularStoryEpisodeCounts: [Int: Int]? = nil
    ) -> Bool {
        let type = (mapping.mediaType ?? fallbackMediaType)?.uppercased()
        guard type.map(detachedFormats.contains) == true else { return false }
        return !isRegularStory(mapping, fallbackMediaType: fallbackMediaType,
            tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts, episodeCount: episodeCount,
            regularStoryEpisodeCounts: regularStoryEpisodeCounts)
    }

    static func regularStoryMappings(
        _ mappings: [AniMapMapping],
        tmdbShowId: Int,
        tmdbSeasonEpisodeCounts: [Int: Int]?,
        regularStoryEpisodeCounts: [Int: Int],
        mediaType: (AniMapMapping) -> String?,
        episodeCount: (AniMapMapping) -> Int?
    ) -> [AniMapMapping] {
        mappings.filter { mapping in
            mapping.tmdbShowId == tmdbShowId && isRegularStory(mapping,
                fallbackMediaType: mediaType(mapping),
                tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                episodeCount: episodeCount(mapping),
                regularStoryEpisodeCounts: regularStoryEpisodeCounts)
        }
    }

    static func isPotentialDetachedFormat(_ mediaType: String?) -> Bool {
        mediaType.map { detachedFormats.contains($0.uppercased()) } == true
    }

    static func ordinarySeasonEpisodeCounts(
        _ mappings: [AniMapMapping],
        identity: (AniMapMapping) -> Int?,
        mediaType: (AniMapMapping) -> String?,
        episodeCount: (AniMapMapping) -> Int?
    ) -> [Int: Int] {
        let ordinary = mappings.filter {
            ["TV", "TV_SHORT", "ONA"].contains((($0.mediaType ?? mediaType($0)) ?? "").uppercased())
                && ($0.tmdbSeason ?? 0) > 0
        }
        let identitySeasons = Dictionary(grouping: ordinary.compactMap { mapping -> (Int, Int)? in
            guard let id = identity(mapping), let season = mapping.tmdbSeason else { return nil }
            return (id, season)
        }, by: { $0.0 }).mapValues { Set($0.map { $0.1 }) }
        var result: [Int: Int] = [:]
        for (season, group) in Dictionary(grouping: ordinary, by: { $0.tmdbSeason ?? 0 }) {
            var counts: [Int: Int] = [:]
            var complete = true
            for mapping in group {
                guard let id = identity(mapping), id > 0,
                      identitySeasons[id]?.count == 1,
                      let count = episodeCount(mapping),
                      count == 0 || RemoteMediaNumericBoundary.episodeCount(count) != nil else {
                    complete = false
                    break
                }
                counts[id] = count
            }
            if complete, let total = RemoteMediaNumericBoundary.boundedSum(counts.values) {
                result[season] = total
            }
        }
        return result
    }
}

struct AniMapTMDBImportMatch {
    let tmdbResult: TMDBSearchResult
    let tmdbSeason: Int?
}

enum AniListImportMetadata {
    static let fields = """
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

    static func resolve(
        ids: [Int],
        prefetched: [AniListAnime],
        fetch: ([Int]) async -> [Int: AniListAnime]
    ) async throws -> [Int: AniListAnime] {
        try Task.checkCancellation()
        let requested = Set(ids.filter { RemoteMediaNumericBoundary.positiveIdentifier($0) != nil })
        var nodes: [Int: AniListAnime] = [:]
        for anime in prefetched where requested.contains(anime.id) {
            nodes[anime.id] = anime
        }
        let missing = requested.filter { nodes[$0] == nil }.sorted()
        if !missing.isEmpty {
            let fetched = await fetch(missing)
            try Task.checkCancellation()
            for id in missing {
                if let anime = fetched[id], anime.id == id {
                    nodes[id] = anime
                }
            }
        }
        return nodes
    }
}

private struct AniMapLookupResult {
    let mappings: [AniMapMapping]
    let isComplete: Bool
}

enum AniMapResponseBoundary {
    enum Scope {
        case lookup
        case globalIndex
    }

    static let maximumLookupBytes = 1 * 1_024 * 1_024
    static let maximumGlobalIndexBytes = 32 * 1_024 * 1_024
    static let maximumLookupRows = 2_048
    static let maximumGlobalIndexRows = 100_000

    static func validate(_ data: Data, scope: Scope) throws {
        let maximumBytes: Int
        let maximumRows: Int
        let maximumTokens: Int
        switch scope {
        case .lookup:
            maximumBytes = maximumLookupBytes
            maximumRows = maximumLookupRows
            maximumTokens = 50_000
        case .globalIndex:
            maximumBytes = maximumGlobalIndexBytes
            maximumRows = maximumGlobalIndexRows
            maximumTokens = 2_000_000
        }

        guard !data.isEmpty, data.count <= maximumBytes else {
            throw BoundedURLSessionError.responseTooLarge(maximumBytes: maximumBytes)
        }
        try SkyStreamJSONEnvelopeValidator.validate(
            data,
            limits: .init(
                maximumDepth: 8,
                maximumTokens: maximumTokens,
                maximumValuesPerContainer: maximumRows,
                maximumStringBytes: 4 * 1_024,
                maximumScalarTokenBytes: 128
            )
        )
    }
}

enum AniMapLookupTimingPolicy {
    static func timeout(mappingKey: String) -> TimeInterval {
        switch mappingKey {
        case "anilist": return 1.5
        case "tmdb_show": return 3
        default: return 2
        }
    }

    private struct DeadlineExceeded: Error {}

    static func perform<Value: Sendable>(
        timeout: TimeInterval,
        onTimeout: (@Sendable () async -> Void)? = nil,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        guard timeout.isFinite, timeout > 0, timeout <= 15 else { throw URLError(.timedOut) }
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0.1, timeout) * 1_000_000_000))
                throw DeadlineExceeded()
            }
            defer { group.cancelAll() }
            do {
                guard let first = try await group.next() else { throw URLError(.unknown) }
                return first
            } catch is DeadlineExceeded {
                group.cancelAll()
                await onTimeout?()
                throw URLError(.timedOut)
            }
        }
    }
}

private actor AniMapMappingService {
    private static let storedShared = AniMapMappingService()
    static var shared: AniMapMappingService {
#if DEBUG
        if let service = AnimeMappingLoadingValidation.service { return service }
#endif
        return storedShared
    }

    private struct HTTPPayload: @unchecked Sendable {
        let data: Data
        let response: URLResponse
    }

    private struct CacheEntry {
        let result: AniMapLookupResult
        let expiresAt: Date
    }

    private struct PersistedShowEntry: Codable {
        let mappings: [AniMapMapping]
        let storedAt: TimeInterval
    }

    private struct PersistedGlobalIndexMeta: Codable, Sendable {
        let schemaVersion: Int
        let storedAt: TimeInterval
        let blobByteCount: Int
        let rangesByTMDBShowId: [Int: Range<Int>]
        let tmdbShowIDsByAniListId: [Int: [Int]]
    }

    private struct LoadedGlobalIndex: Sendable {
        let meta: PersistedGlobalIndexMeta
        let blob: Data
    }

    private static let baseURL = URL(string: "https://animap.s0n1c.ca")!
    private static let cacheSchemaVersion = 4
    private var cacheByTMDBShowId: [Int: CacheEntry] = [:]
    private var cacheByAniListId: [Int: CacheEntry] = [:]
    private var inFlightByTMDBShowId: [Int: Task<AniMapLookupResult, Never>] = [:]
    private var inFlightByAniListId: [Int: Task<AniMapLookupResult, Never>] = [:]
    private var persistedShows: [Int: PersistedShowEntry]

    private var globalIndexRangesByTMDBShowId: [Int: Range<Int>] = [:]
    private var globalIndexBlob: Data?
    private var globalTMDBShowIDsByAniListId: [Int: [Int]] = [:]
    private var globalIndexStoredAt: TimeInterval?
    private var didLoadGlobalIndexFromDisk = false
    private var globalIndexDiskLoadTask: Task<LoadedGlobalIndex?, Never>?
    private var globalIndexTask: Task<(mappings: [AniMapMapping], isComplete: Bool), Never>?
    private let showCacheURL: URL
    private let globalIndexMetaURL: URL
    private let globalIndexBlobURL: URL
    private let persistsCaches: Bool

    private let populatedTTL: TimeInterval = 24 * 60 * 60
    private let emptyTTL: TimeInterval = 15 * 60
    private let failureTTL: TimeInterval = 30
    private let persistedShowTTL: TimeInterval = 7 * 24 * 60 * 60
    private let globalIndexTTL: TimeInterval = 7 * 24 * 60 * 60

    private static let maximumShowCacheBytes = 8 * 1_024 * 1_024
    private static let maximumGlobalIndexMetaBytes = 16 * 1_024 * 1_024

    private init(persistsCaches: Bool = true) {
        self.persistsCaches = persistsCaches
        let cacheDirectory = FileManager.default.eclipseCachesDirectories[0]
        showCacheURL = cacheDirectory.appendingPathComponent("animap-show-mappings-v3.json")
        globalIndexMetaURL = cacheDirectory.appendingPathComponent("animap-global-index-meta-v4.json")
        globalIndexBlobURL = cacheDirectory.appendingPathComponent("animap-global-index-blob-v4.bin")

        if !persistsCaches {
            persistedShows = [:]
            didLoadGlobalIndexFromDisk = true
            return
        }

        for legacy in ["animap-global-index-v2.json", "animap-show-mappings-v2.json",
                       "animap-global-index-meta-v3.json", "animap-global-index-blob-v3.bin"] {
            try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(legacy))
        }

        if let data = Self.boundedRegularFileData(
            at: showCacheURL,
            maximumBytes: Self.maximumShowCacheBytes
        ),
           Self.cacheEnvelopeIsValid(data),
           let decoded = try? JSONDecoder().decode([Int: PersistedShowEntry].self, from: data),
           decoded.count <= 20_000,
           decoded.values.allSatisfy({ entry in
               entry.storedAt.isFinite
                   && entry.mappings.count <= AniMapResponseBoundary.maximumLookupRows
           }) {
            persistedShows = decoded
        } else {
            persistedShows = [:]
        }

    }

#if DEBUG
    static func validationInstance() -> AniMapMappingService {
        AniMapMappingService(persistsCaches: false)
    }
#endif

    func reduceMemoryFootprint() {
        cacheByTMDBShowId = [:]
        cacheByAniListId = [:]
        globalIndexRangesByTMDBShowId = [:]
        globalTMDBShowIDsByAniListId = [:]
        globalIndexBlob = nil
        globalIndexStoredAt = nil
        globalIndexDiskLoadTask = nil
        didLoadGlobalIndexFromDisk = false
        Logger.shared.log(
            "AniMapMappingService: dropped in-memory caches after memory pressure",
            type: "AniList"
        )
    }

    func prepareGlobalIndexIfNeeded() async {
        await loadGlobalIndexFromDiskIfNeeded()

        let now = Date().timeIntervalSince1970
        if let storedAt = globalIndexStoredAt,
           now - storedAt <= globalIndexTTL,
           !globalIndexRangesByTMDBShowId.isEmpty {
            return
        }
        if let globalIndexTask {
            _ = await globalIndexTask.value
            return
        }

        let task = Task { await Self.fetchAllMappings() }
        globalIndexTask = task
        let result = await task.value
        globalIndexTask = nil
        guard result.isComplete, !result.mappings.isEmpty else { return }

        let relevant = result.mappings.filter { ($0.tmdbShowId ?? 0) > 0 }
        guard !relevant.isEmpty else { return }
        installAndPersistGlobalIndex(relevant, storedAt: Date().timeIntervalSince1970)
    }

    func mappings(forTMDBShowId tmdbShowId: Int) async -> [AniMapMapping] {
        await mappingsResult(forTMDBShowId: tmdbShowId).mappings
    }

    func mappingsResult(forTMDBShowId tmdbShowId: Int) async -> AniMapLookupResult {
        guard tmdbShowId > 0, !Task.isCancelled else {
            return AniMapLookupResult(mappings: [], isComplete: false)
        }
        await loadGlobalIndexFromDiskIfNeeded()

        if let cached = cacheByTMDBShowId[tmdbShowId] {
            if cached.expiresAt > Date() {
                return cached.result
            }
            cacheByTMDBShowId[tmdbShowId] = nil
        }

        let now = Date().timeIntervalSince1970
        if let storedAt = globalIndexStoredAt,
           now - storedAt <= globalIndexTTL,
           let mappings = globalIndexMappings(forTMDBShowId: tmdbShowId) {
            let result = AniMapLookupResult(mappings: mappings, isComplete: true)
            cacheByTMDBShowId[tmdbShowId] = cacheEntry(for: result)
            return result
        }

        if let persisted = persistedShows[tmdbShowId] {
            if now - persisted.storedAt <= persistedShowTTL {
                let result = AniMapLookupResult(mappings: persisted.mappings, isComplete: true)
                cacheByTMDBShowId[tmdbShowId] = cacheEntry(for: result)
                return result
            }
            persistedShows[tmdbShowId] = nil
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
        if result.isComplete, !result.mappings.isEmpty {
            persistedShows[tmdbShowId] = PersistedShowEntry(
                mappings: result.mappings,
                storedAt: Date().timeIntervalSince1970
            )
            Task { self.persistShowCache() }
        }
        return result
    }

    func specialMappings(forTMDBShowId tmdbShowId: Int) async -> [AniMapMapping] {
        await specialMappingsResult(forTMDBShowId: tmdbShowId).mappings
    }

    func specialMappingsResult(forTMDBShowId tmdbShowId: Int, tmdbSeasonEpisodeCounts: [Int: Int]? = nil) async -> AniMapLookupResult {
        let result = await mappingsResult(forTMDBShowId: tmdbShowId)
        let mappings = result.mappings.filter { AniMapStructuralRole.isDetachedSpecial($0, tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts) }
        return AniMapLookupResult(mappings: mappings, isComplete: result.isComplete)
    }

    func cachedMappings(forAniListIds ids: [Int]) -> [Int: [AniMapMapping]] {
        let wanted = Set(ids.filter { $0 > 0 })
        guard !wanted.isEmpty else { return [:] }
        let now = Date()
        var result: [Int: [AniMapMapping]] = [:]

        for id in wanted {
            if let cached = cacheByAniListId[id], cached.expiresAt > now {
                result[id] = cached.result.mappings
                continue
            }
            if let showIDs = globalTMDBShowIDsByAniListId[id] {
                let global = showIDs.flatMap { showID in
                    (globalIndexMappings(forTMDBShowId: showID) ?? []).filter {
                        $0.anilistId == id
                    }
                }
                if !global.isEmpty {
                    result[id] = global
                    continue
                }
            }

            var persisted: [AniMapMapping] = []
            for entry in persistedShows.values where Date().timeIntervalSince1970 - entry.storedAt <= persistedShowTTL {
                persisted.append(contentsOf: entry.mappings.filter { $0.anilistId == id })
            }
            if !persisted.isEmpty {
                result[id] = persisted
            }
        }
        return result
    }

    func mappingsResult(forTVDBId tvdbId: Int) async -> AniMapLookupResult {
        guard RemoteMediaNumericBoundary.positiveIdentifier(tvdbId) != nil, !Task.isCancelled else {
            return AniMapLookupResult(mappings: [], isComplete: false)
        }
        return await Self.fetchMappings(value: tvdbId, mappingKey: "tvdb") { mapping in
            mapping.tvdbId == tvdbId
        }
    }

    func mappings(forAniListId anilistId: Int) async -> [AniMapMapping] {
        await mappingsResult(forAniListId: anilistId).mappings
    }

    func mappingsResult(forAniListId anilistId: Int) async -> AniMapLookupResult {
        guard anilistId > 0, !Task.isCancelled else {
            return AniMapLookupResult(mappings: [], isComplete: false)
        }
        await loadGlobalIndexFromDiskIfNeeded()

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

    private func loadGlobalIndexFromDiskIfNeeded() async {
        guard !didLoadGlobalIndexFromDisk else { return }
        let task: Task<LoadedGlobalIndex?, Never>
        if let globalIndexDiskLoadTask {
            task = globalIndexDiskLoadTask
        } else {
            let metaURL = globalIndexMetaURL
            let blobURL = globalIndexBlobURL
            task = Task.detached(priority: .utility) {
                guard let metaData = Self.boundedRegularFileData(
                          at: metaURL,
                          maximumBytes: Self.maximumGlobalIndexMetaBytes
                      ),
                      Self.cacheEnvelopeIsValid(metaData),
                      let meta = try? JSONDecoder().decode(PersistedGlobalIndexMeta.self, from: metaData),
                      meta.schemaVersion == Self.cacheSchemaVersion,
                      meta.storedAt.isFinite,
                      let blob = Self.boundedRegularFileData(
                          at: blobURL,
                          maximumBytes: AniMapResponseBoundary.maximumGlobalIndexBytes
                      ),
                      blob.count == meta.blobByteCount,
                      meta.rangesByTMDBShowId.count <= AniMapResponseBoundary.maximumGlobalIndexRows,
                      meta.tmdbShowIDsByAniListId.count <= AniMapResponseBoundary.maximumGlobalIndexRows,
                      meta.rangesByTMDBShowId.values.allSatisfy({ range in
                          range.lowerBound >= 0
                              && range.lowerBound <= range.upperBound
                              && range.upperBound <= blob.count
                      }) else {
                    return nil
                }
                return LoadedGlobalIndex(meta: meta, blob: blob)
            }
            globalIndexDiskLoadTask = task
        }
        let loaded = await task.value
        guard !didLoadGlobalIndexFromDisk else { return }
        didLoadGlobalIndexFromDisk = true
        globalIndexDiskLoadTask = nil
        guard let loaded else { return }
        globalIndexStoredAt = loaded.meta.storedAt
        globalIndexRangesByTMDBShowId = loaded.meta.rangesByTMDBShowId
        globalTMDBShowIDsByAniListId = loaded.meta.tmdbShowIDsByAniListId
        globalIndexBlob = loaded.blob
    }

    private func globalIndexMappings(forTMDBShowId tmdbShowId: Int) -> [AniMapMapping]? {
        guard let range = globalIndexRangesByTMDBShowId[tmdbShowId],
              let blob = globalIndexBlob,
              range.lowerBound >= 0,
              range.upperBound <= blob.count else {
            return nil
        }
        let slice = blob.subdata(in: range)
        return try? JSONDecoder().decode([AniMapMapping].self, from: slice)
    }

    private func installAndPersistGlobalIndex(
        _ mappings: [AniMapMapping],
        storedAt: TimeInterval
    ) {
        let grouped = Dictionary(grouping: mappings) { $0.tmdbShowId ?? 0 }
        let encoder = JSONEncoder()
        var blob = Data()
        var ranges: [Int: Range<Int>] = [:]
        ranges.reserveCapacity(grouped.count)
        for (showID, rows) in grouped where showID > 0 {
            guard let encoded = try? encoder.encode(rows) else { continue }
            let start = blob.count
            blob.append(encoded)
            ranges[showID] = start..<blob.count
        }

        var showIDsByAniListID: [Int: Set<Int>] = [:]
        for mapping in mappings {
            guard let aniListID = mapping.anilistId,
                  aniListID > 0,
                  let tmdbShowID = mapping.tmdbShowId,
                  tmdbShowID > 0 else {
                continue
            }
            showIDsByAniListID[aniListID, default: []].insert(tmdbShowID)
        }
        let reverseIndex = showIDsByAniListID.mapValues { $0.sorted() }

        globalIndexStoredAt = storedAt
        globalIndexRangesByTMDBShowId = ranges
        globalTMDBShowIDsByAniListId = reverseIndex

        didLoadGlobalIndexFromDisk = true
        globalIndexDiskLoadTask = nil

        if !persistsCaches {
            globalIndexBlob = blob
            return
        }
        let meta = PersistedGlobalIndexMeta(
            schemaVersion: Self.cacheSchemaVersion,
            storedAt: storedAt,
            blobByteCount: blob.count,
            rangesByTMDBShowId: ranges,
            tmdbShowIDsByAniListId: reverseIndex
        )
        do {
            try FileManager.default.createDirectory(
                at: globalIndexBlobURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try blob.write(to: globalIndexBlobURL, options: .atomic)
            let metaData = try JSONEncoder().encode(meta)
            try metaData.write(to: globalIndexMetaURL, options: .atomic)

            globalIndexBlob = (try? Data(contentsOf: globalIndexBlobURL, options: .mappedIfSafe)) ?? blob
        } catch {

            globalIndexBlob = blob
            Logger.shared.log(
                "AniMapMappingService: global index persist failed: \(error.localizedDescription)",
                type: "AniList"
            )
        }
        Logger.shared.log(
            "AniMapMappingService: installed blob-backed global index mappings=\(mappings.count) shows=\(ranges.count) identities=\(reverseIndex.count) blobBytes=\(blob.count)",
            type: "AniList"
        )
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

            let timeout = AniMapLookupTimingPolicy.timeout(mappingKey: mappingKey)
            var request = URLRequest(url: url, timeoutInterval: timeout)

            request.cachePolicy = .reloadRevalidatingCacheData
            let (data, response) = try await data(
                for: request,
                wallClockTimeout: timeout,
                maximumResponseBytes: AniMapResponseBoundary.maximumLookupBytes
            )
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return AniMapLookupResult(mappings: [], isComplete: false)
            }

            try AniMapResponseBoundary.validate(data, scope: .lookup)
            let decoded = try JSONDecoder().decode(AniMapMappingList.self, from: data)
            guard decoded.mappings.count <= AniMapResponseBoundary.maximumLookupRows else {
                return AniMapLookupResult(mappings: [], isComplete: false)
            }
#if DEBUG
            if AnimeMappingLoadingValidation.ignoreResults {
                await AnimeMetadataLoadingValidation.requestLedger?.recordEvent(
                    provider: "AniMap", stage: "diagnostic-mapping-withheld", operation: "\(mappingKey)-\(value)",
                    startedAtUptime: ProcessInfo.processInfo.systemUptime, durationSeconds: 0
                )
                return AniMapLookupResult(mappings: [], isComplete: false)
            }
#endif
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

    private static func fetchAllMappings() async -> (mappings: [AniMapMapping], isComplete: Bool) {
        let url = baseURL.appendingPathComponent("mappings/all")
        do {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.cachePolicy = .reloadRevalidatingCacheData
            request.setValue("Eclipse/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await data(
                for: request,
                wallClockTimeout: 15,
                maximumResponseBytes: AniMapResponseBoundary.maximumGlobalIndexBytes
            )
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return ([], false)
            }
            try AniMapResponseBoundary.validate(data, scope: .globalIndex)
            let mappings = try JSONDecoder().decode([AniMapMapping].self, from: data)
            guard mappings.count <= AniMapResponseBoundary.maximumGlobalIndexRows else {
                return ([], false)
            }
            return (mappings, true)
        } catch {
            if !(error is CancellationError) {
                Logger.shared.log(
                    "AniMapMappingService: global index refresh failed: \(error.localizedDescription)",
                    type: "AniList"
                )
            }
            return ([], false)
        }
    }

    private static func data(
        for request: URLRequest,
        wallClockTimeout: TimeInterval,
        maximumResponseBytes: Int
    ) async throws -> (Data, URLResponse) {
        var configuredRequest = request
#if DEBUG
        if AnimeMetadataLoadingValidation.session != nil {
            configuredRequest.cachePolicy = .reloadIgnoringLocalCacheData
        }
#endif
        let effectiveRequest = configuredRequest
#if DEBUG
        let requestStart = ProcessInfo.processInfo.systemUptime
        let requestID = UUID().uuidString
        let onTimeout: (@Sendable () async -> Void)? = {
            await AnimeMetadataLoadingValidation.requestLedger?.recordEvent(
                provider: "AniMap", stage: "wall-timeout", operation: effectiveRequest.url?.path ?? "mapping",
                requestID: requestID, startedAtUptime: requestStart,
                durationSeconds: ProcessInfo.processInfo.systemUptime - requestStart,
                errorDomain: NSURLErrorDomain, errorCode: URLError.timedOut.rawValue
            )
        }
#else
        let onTimeout: (@Sendable () async -> Void)? = nil
#endif
        let payload = try await AniMapLookupTimingPolicy.perform(timeout: wallClockTimeout, onTimeout: onTimeout) {
            var session = URLSession.shared
#if DEBUG
            session = AnimeMetadataLoadingValidation.session ?? session
            await AnimeMetadataLoadingValidation.requestLedger?.record(provider: "AniMap")
#endif
            do {
                let (data, response) = try await session.boundedData(
                    for: effectiveRequest,
                    maximumResponseBytes: maximumResponseBytes
                )
#if DEBUG
                let requestElapsed = ProcessInfo.processInfo.systemUptime - requestStart
                await AnimeMetadataLoadingValidation.requestLedger?.recordDuration(
                    provider: "AniMap", seconds: requestElapsed
                )
                await AnimeMetadataLoadingValidation.requestLedger?.recordEvent(
                    provider: "AniMap", stage: "response", operation: effectiveRequest.url?.path ?? "mapping",
                    requestID: requestID, startedAtUptime: requestStart, durationSeconds: requestElapsed,
                    statusCode: (response as? HTTPURLResponse)?.statusCode
                )
#endif
                return HTTPPayload(data: data, response: response)
            } catch {
#if DEBUG
                let requestElapsed = ProcessInfo.processInfo.systemUptime - requestStart
                let failure = error as NSError
                await AnimeMetadataLoadingValidation.requestLedger?.recordDuration(
                    provider: "AniMap", seconds: requestElapsed
                )
                await AnimeMetadataLoadingValidation.requestLedger?.recordEvent(
                    provider: "AniMap", stage: "transport-error", operation: effectiveRequest.url?.path ?? "mapping",
                    requestID: requestID, startedAtUptime: requestStart, durationSeconds: requestElapsed,
                    errorDomain: failure.domain, errorCode: failure.code
                )
#endif
                throw error
            }
        }
        return (payload.data, payload.response)
    }

    nonisolated private static func boundedRegularFileData(
        at url: URL,
        maximumBytes: Int
    ) -> Data? {
        guard maximumBytes > 0,
              let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize >= 0,
              fileSize <= maximumBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count == fileSize else {
            return nil
        }
        return data
    }

    nonisolated private static func cacheEnvelopeIsValid(_ data: Data) -> Bool {
        (try? SkyStreamJSONEnvelopeValidator.validate(
            data,
            limits: .init(
                maximumDepth: 12,
                maximumTokens: 2_000_000,
                maximumValuesPerContainer: AniMapResponseBoundary.maximumGlobalIndexRows,
                maximumStringBytes: 4 * 1_024,
                maximumScalarTokenBytes: 128
            )
        )) != nil
    }

    private func persistShowCache() {
        guard persistsCaches else { return }
        let cutoff = Date().timeIntervalSince1970 - persistedShowTTL
        persistedShows = persistedShows.filter { $0.value.storedAt >= cutoff }
        do {
            try FileManager.default.createDirectory(
                at: showCacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(persistedShows)
            try data.write(to: showCacheURL, options: .atomic)
        } catch {
            Logger.shared.log(
                "AniMapMappingService: show cache persist failed: \(error.localizedDescription)",
                type: "AniList"
            )
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

enum AnimeEpisodeHydrationPolicy: String, Hashable {

    case complete

    case initiallyVisible
}

#if DEBUG
private enum AnimeMappingLoadingValidation {
    @TaskLocal static var service: AniMapMappingService?
    @TaskLocal static var ignoreResults = false
}

actor AnimeMetadataRequestLedger {
    struct Event: Codable, Sendable {
        let provider: String
        let stage: String
        let operation: String
        let requestID: String?
        let startedAtSeconds: Double
        let durationSeconds: Double
        let attempt: Int?
        let statusCode: Int?
        let errorDomain: String?
        let errorCode: Int?
        let retryDelaySeconds: Double?
    }

    private var counts: [String: Int] = [:]
    private var durations: [String: [Double]] = [:]
    private let startedAtUptime = ProcessInfo.processInfo.systemUptime
    private var events: [Event] = []
    private var droppedEvents = 0
    private let maximumEvents = 512

    func record(provider: String) {
        counts[provider, default: 0] += 1
    }

    func snapshot() -> [String: Int] { counts }

    func recordDuration(provider: String, seconds: Double) {
        durations[provider, default: []].append(seconds)
    }

    func timingSnapshot() -> [String: [Double]] { durations }

    func recordEvent(
        provider: String,
        stage: String,
        operation: String,
        requestID: String? = nil,
        startedAtUptime: Double,
        durationSeconds: Double,
        attempt: Int? = nil,
        statusCode: Int? = nil,
        errorDomain: String? = nil,
        errorCode: Int? = nil,
        retryDelaySeconds: Double? = nil
    ) {
        guard events.count < maximumEvents else {
            if droppedEvents < Int.max { droppedEvents += 1 }
            return
        }
        guard startedAtUptime.isFinite, durationSeconds.isFinite, durationSeconds >= 0 else { return }
        events.append(Event(
            provider: String(provider.prefix(32)), stage: String(stage.prefix(64)),
            operation: String(operation.prefix(160)), requestID: requestID.map { String($0.prefix(64)) },
            startedAtSeconds: max(0, startedAtUptime - self.startedAtUptime),
            durationSeconds: durationSeconds, attempt: attempt, statusCode: statusCode,
            errorDomain: errorDomain.map { String($0.prefix(128)) }, errorCode: errorCode,
            retryDelaySeconds: retryDelaySeconds
        ))
    }

    func eventSnapshot() -> [Event] { events }

    func droppedEventCount() -> Int { droppedEvents }
}

enum AnimeMetadataLoadingValidation {
    @TaskLocal static var bypassesGraphCaches = false
    @TaskLocal static var tmdbCache: TMDBDetailCache?
    @TaskLocal static var requestNamespace: String?
    @TaskLocal static var session: URLSession?
    @TaskLocal static var requestLedger: AnimeMetadataRequestLedger?
}
#endif

private var animeMetadataCacheReadsAllowed: Bool {
#if DEBUG
    return !AnimeMetadataLoadingValidation.bypassesGraphCaches
#else
    return true
#endif
}

private enum AniListRequestContext {

    @TaskLocal static var isDetailReadyPath = false
}

private struct AnimeDetailRequestKey: Hashable {
    let tmdbShowId: Int
    let languageCode: String
    let seedAniListId: Int?
    let seedMALId: Int?
    let hydrationPolicy: AnimeEpisodeHydrationPolicy
}

private actor AnimeDetailRequestCoordinator {
    static let shared = AnimeDetailRequestCoordinator()

    private var inFlight: [AnimeDetailRequestKey: Task<AniListAnimeWithSeasons, Error>] = [:]

    func value(
        for key: AnimeDetailRequestKey,
        operation: @escaping () async throws -> AniListAnimeWithSeasons
    ) async throws -> AniListAnimeWithSeasons {
        try Task.checkCancellation()

#if DEBUG
        if AnimeMetadataLoadingValidation.bypassesGraphCaches {
            return try await operation()
        }
#endif

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

struct AnimeStructureOrderingCandidate: Equatable {
    let anilistId: Int
    let mappedTMDBSeason: Int?
    let episodeOffset: Int?
    let startYear: Int?
    let startMonth: Int?
    let startDay: Int?
    let seasonYear: Int?
    let seasonOrdinal: Int
}

struct AnimeStructureCoverageSegment: Equatable {
    let mappedTMDBSeason: Int?
    let episodeCount: Int?
}

struct AnimeStructureCourPlacementCandidate {
    let id: Int
    let mappedTMDBSeason: Int?
    let episodeCount: Int?
    let format: String?
    let status: String?
    let startDate: String?
    let endDate: String?
    let titles: [String]
    let hasTrustedIdentity: Bool
    var nextIDs: Set<Int> = []
    var previousIDs: Set<Int> = []
    var hasTrustedMappedIdentity: Bool = false
}

struct AnimeStructureMappedOrderSegment: Equatable {
    let mappedTMDBSeason: Int?
    let mappedTVDBSeason: Int?
    let tvdbEpisodeOffset: Int?
    let episodeCount: Int?
}

struct AnimeStructureRelationConstraint: Equatable {
    let beforeID: Int
    let afterID: Int
}

struct AnimeStructureTMDBCoordinate: Equatable {
    let seasonNumber: Int
    let episodeNumber: Int
}

enum AnimeSeasonEpisodeHydrationPolicy {
    static func exactMappedSeasonStart(
        index: Int,
        segments: [AnimeStructureCoverageSegment],
        tmdbSeasonEpisodeCounts: [Int: Int]
    ) -> Int? {
        guard segments.indices.contains(index),
              tmdbSeasonEpisodeCounts.allSatisfy({
                  RemoteMediaNumericBoundary.seasonNumber($0.key) != nil
                      && RemoteMediaNumericBoundary.episodeCount($0.value) != nil
              }),
              let season = segments[index].mappedTMDBSeason,
              season > 0,
              let target = tmdbSeasonEpisodeCounts[season] else { return nil }
        let group = segments.indices.filter { segments[$0].mappedTMDBSeason == season }
        guard let first = group.first, let last = group.last,
              group.count == last - first + 1,
              group.allSatisfy({ RemoteMediaNumericBoundary.episodeCount(segments[$0].episodeCount) != nil }),
              let total = RemoteMediaNumericBoundary.boundedSum(group.compactMap { segments[$0].episodeCount }),
              total == target,
              let groupPrefix = RemoteMediaNumericBoundary.boundedSum(
                group.filter { $0 < index }.compactMap { segments[$0].episodeCount }
              ),
              let precedingCount = RemoteMediaNumericBoundary.boundedSum(
                tmdbSeasonEpisodeCounts.filter { $0.key > 0 && $0.key < season }.values
              ), let start = RemoteMediaNumericBoundary.adding(precedingCount, groupPrefix) else { return nil }
        return RemoteMediaNumericBoundary.adding(start, 1)
    }

    static func displayEpisodeCount(
        declaredCount: Int?,
        remainingTMDBCount: Int,
        allowsOpenEndedRemainder: Bool,
        status: String? = nil
    ) -> Int {
        if ["NOT_YET_RELEASED", "NOT_YET_AIRED"].contains(status?.uppercased() ?? "") { return 0 }
        if let count = RemoteMediaNumericBoundary.episodeCount(declaredCount) { return count }
        guard allowsOpenEndedRemainder,
              let remaining = RemoteMediaNumericBoundary.episodeCount(remainingTMDBCount) else { return 0 }
        return remaining
    }

    static func hydrateTMDBInventory(
        seasons: [TMDBSeason],
        fetchedEpisodesBySeason: [Int: [TMDBEpisode]],
        allowsSummaryCoordinates: Bool,
        absoluteEpisodeLimit: Int? = nil
    ) -> (episodes: [Int: TMDBEpisode], coordinates: [Int: AnimeStructureTMDBCoordinate]) {
        var episodesByAbsolute: [Int: TMDBEpisode] = [:]
        var coordinatesByAbsolute: [Int: AnimeStructureTMDBCoordinate] = [:]
        guard RemoteMediaNumericBoundary.seasonEpisodeCounts(
            seasons.map { ($0.seasonNumber, $0.episodeCount) }
        ) != nil else { return (episodesByAbsolute, coordinatesByAbsolute) }
        var absoluteStart = 1
        for season in seasons.sorted(by: { $0.seasonNumber < $1.seasonNumber }) {
            let source = fetchedEpisodesBySeason[season.seasonNumber]
            let usableSource = source.flatMap { rows in
                allowsSummaryCoordinates || rows.count == season.episodeCount ? rows : nil
            }
            guard let rows = usableSource else {
                if allowsSummaryCoordinates {
                    for offset in 0..<season.episodeCount {
                        guard let absolute = RemoteMediaNumericBoundary.adding(absoluteStart, offset) else {
                            return (episodesByAbsolute, coordinatesByAbsolute)
                        }
                        coordinatesByAbsolute[absolute] = .init(seasonNumber: season.seasonNumber, episodeNumber: offset + 1)
                    }
                }
                guard let next = RemoteMediaNumericBoundary.adding(absoluteStart, season.episodeCount) else {
                    return (episodesByAbsolute, coordinatesByAbsolute)
                }
                absoluteStart = next
                continue
            }
            guard rows.count <= RemoteMediaNumericBoundary.maximumEpisodeCount else {
                return (episodesByAbsolute, coordinatesByAbsolute)
            }
            for (offset, episode) in rows.sorted(by: { $0.episodeNumber < $1.episodeNumber }).enumerated() {
                guard let absolute = RemoteMediaNumericBoundary.adding(absoluteStart, offset) else {
                    return (episodesByAbsolute, coordinatesByAbsolute)
                }
                coordinatesByAbsolute[absolute] = .init(seasonNumber: episode.seasonNumber, episodeNumber: episode.episodeNumber)
                if absoluteEpisodeLimit.map({ absolute <= $0 }) ?? true {
                    episodesByAbsolute[absolute] = episode
                }
            }
            guard let next = RemoteMediaNumericBoundary.adding(absoluteStart, rows.count) else {
                return (episodesByAbsolute, coordinatesByAbsolute)
            }
            absoluteStart = next
        }
        return (episodesByAbsolute, coordinatesByAbsolute)
    }

    static func episodes(
        count: Int,
        displaySeasonNumber: Int,
        startingAt absoluteStart: Int,
        tmdbEpisodes: [Int: TMDBEpisode],
        tmdbCoordinates: [Int: AnimeStructureTMDBCoordinate],
        allowsTMDBCoordinates: Bool
    ) -> [AniListEpisode] {
        guard count == 0 || RemoteMediaNumericBoundary.episodeCount(count) != nil,
              RemoteMediaNumericBoundary.seasonNumber(displaySeasonNumber) != nil,
              absoluteStart > 0 else { return [] }
        return (0..<count).map { offset in
            let absolute = RemoteMediaNumericBoundary.adding(absoluteStart, offset)
            let metadata = allowsTMDBCoordinates ? absolute.flatMap { tmdbEpisodes[$0] } : nil
            let coordinate = allowsTMDBCoordinates ? absolute.flatMap { tmdbCoordinates[$0] } : nil
            return AniListEpisode(
                number: offset + 1, title: metadata?.name ?? "Episode \(offset + 1)",
                description: metadata?.overview, seasonNumber: displaySeasonNumber,
                stillPath: metadata?.stillPath, airDate: metadata?.airDate, runtime: metadata?.runtime,
                tmdbSeasonNumber: metadata?.seasonNumber ?? coordinate?.seasonNumber,
                tmdbEpisodeNumber: metadata?.episodeNumber ?? coordinate?.episodeNumber
            )
        }
    }
}

enum AnimeRelationRolePolicy {
    static func firstAdmittedSupplementalEntry(
        candidates: [AniListAnime],
        regularMappedIDs: Set<Int>,
        existingEntries: [AniListAnime],
        prefetched: [Int: AniListAnime],
        fetch: (Int) async -> AniListAnime?
    ) async -> AniListAnime? {
        let existingIDs = Set(existingEntries.map(\.id))
        var seenIDs = existingIDs
        let ranked = candidates.prefix(20).compactMap { candidate -> AniListAnime? in
            guard seenIDs.insert(candidate.id).inserted else { return nil }
            if let cached = prefetched[candidate.id], cached.id == candidate.id { return cached }
            return candidate
        }
        func isAdmitted(_ entry: AniListAnime) -> Bool {
            let outgoing = (entry.relations?.edges ?? [])
                .filter { existingIDs.contains($0.node.id) }.map(\.relationType)
            let incoming = existingEntries.flatMap { existing in
                (existing.relations?.edges ?? []).filter { $0.node.id == entry.id }.map(\.relationType)
            }
            return admitsSupplementalRegularEntry(
                isMappedRegular: regularMappedIDs.contains(entry.id),
                relationTypesToExistingEntries: outgoing + incoming,
                mediaFormat: entry.format
            )
        }
        if let known = ranked.first(where: isAdmitted) { return known }
        for candidate in ranked.filter({ $0.relations == nil }).prefix(3) {
            guard !Task.isCancelled else { return nil }
            guard let fetched = await fetch(candidate.id), fetched.id == candidate.id else { continue }
            if isAdmitted(fetched) { return fetched }
        }
        return nil
    }

    static func admitsSupplementalRegularEntry(
        isMappedRegular: Bool,
        relationTypesToExistingEntries: [String],
        mediaFormat: String?
    ) -> Bool {
        isMappedRegular || relationTypesToExistingEntries.contains {
            isRegularContinuationCandidate(relationType: $0, mediaFormat: mediaFormat)
        }
    }

    static func fitsRegularTMDBInventory(
        isMappedRegular: Bool,
        episodeCount: Int?,
        status: String? = nil,
        tmdbEpisodeCount: Int?
    ) -> Bool {
        if isMappedRegular { return true }
        let hasOpenEndedInventory = ["NOT_YET_RELEASED", "NOT_YET_AIRED", "RELEASING", "CURRENTLY_AIRING"]
            .contains(status?.uppercased() ?? "")
        if !hasOpenEndedInventory,
           let count = RemoteMediaNumericBoundary.episodeCount(episodeCount),
           let target = RemoteMediaNumericBoundary.episodeCount(tmdbEpisodeCount),
           count > target {
            return false
        }
        return true
    }

    static func admitsHydratedRegularNode(
        relationType: String,
        mediaFormat: String?,
        isMappedRegular: Bool,
        episodeCount: Int?,
        status: String?,
        tmdbEpisodeCount: Int?
    ) -> Bool {
        guard ["SEQUEL", "PREQUEL", "SEASON"].contains(relationType.uppercased()),
              fitsRegularTMDBInventory(isMappedRegular: isMappedRegular, episodeCount: episodeCount,
                  status: status, tmdbEpisodeCount: tmdbEpisodeCount) else { return false }
        return isMappedRegular || isRegularContinuationCandidate(relationType: relationType, mediaFormat: mediaFormat)
    }

    static func regularContinuationFormat(mediaFormat: String?, mapping: AniMapMapping?, tmdbShowId: Int) -> String? {
        if let mediaFormat { return mediaFormat }
        guard let mapping, mapping.tmdbShowId == tmdbShowId,
              mapping.tmdbSeason != 0, mapping.tvdbSeason != 0,
              let type = mapping.mediaType?.uppercased(), ["TV", "TV_SHORT", "ONA"].contains(type) else { return nil }
        return type
    }

    static func retainsUpcomingIdentity(relationType: String, mediaFormat: String?, status: String?) -> Bool {
        status?.uppercased() == "NOT_YET_RELEASED"
            && ["SEQUEL", "SEASON"].contains(relationType.uppercased())
            && isRegularContinuationCandidate(relationType: relationType, mediaFormat: mediaFormat)
    }

    static func isRegularContinuationCandidate(
        relationType: String,
        mediaFormat: String?
    ) -> Bool {
        let regularRelationTypes: Set<String> = ["SEQUEL", "PREQUEL", "SEASON"]
        let regularFormats: Set<String> = ["TV", "TV_SHORT", "ONA"]
        return regularRelationTypes.contains(relationType.uppercased())
            && mediaFormat.map { regularFormats.contains($0.uppercased()) } == true
    }

    static func isDetachedSpecialCandidate(
        relationType: String,
        mediaFormat: String?,
        titleCandidates: [String]
    ) -> Bool {
        let relationType = relationType.uppercased()
        let format = mediaFormat?.uppercased()

        if isRegularContinuationCandidate(
            relationType: relationType,
            mediaFormat: format
        ) {
            return false
        }

        if let format, ["SPECIAL", "OVA", "ONA", "MOVIE"].contains(format) {
            return true
        }

        let detachedRelationTypes: Set<String> = ["SIDE_STORY", "SPIN_OFF", "OTHER"]
        guard detachedRelationTypes.contains(relationType) else { return false }

        let titleText = titleCandidates.joined(separator: " ").lowercased()
        return ["special", "ova", "oad", "ona", "extra", "another world"].contains {
            titleText.contains($0)
        }
    }

    static func isExactSelectedRegularEntry(
        mediaID: Int,
        selectedMediaID: Int?,
        mediaFormat: String?
    ) -> Bool {
        guard mediaID > 0, mediaID == selectedMediaID else { return false }
        return isRegularContinuationCandidate(
            relationType: "SEQUEL",
            mediaFormat: mediaFormat
        )
    }
}

enum AnimeExternalFeatureOwnershipPolicy {
    static func featurePrequelCandidateID(
        root: AniListAnime, selectedAniListID: Int?, knownRegularOwnerIDs: Set<Int>
    ) -> Int? {
        guard root.format?.uppercased() == "TV", root.status?.uppercased() == "RELEASING",
              RemoteMediaNumericBoundary.positiveIdentifier(root.id) != nil,
              root.episodes == nil, knownRegularOwnerIDs.isSubset(of: [root.id]),
              let relations = root.relations else { return nil }
        let ordinaryEdges = relations.edges.filter { edge in
            ["PREQUEL", "SEQUEL", "SEASON"].contains(edge.relationType.uppercased())
                && (edge.node.type == nil || edge.node.type == "ANIME")
                && (edge.node.format == nil || !["SPECIAL", "TV_SPECIAL", "OVA", "OAD", "MOVIE", "MUSIC"].contains(edge.node.format?.uppercased() ?? "")
                    || knownRegularOwnerIDs.contains(edge.node.id))
        }
        guard ordinaryEdges.count == 1, let edge = ordinaryEdges.first,
              edge.relationType.uppercased() == "PREQUEL", edge.node.type == "ANIME",
              RemoteMediaNumericBoundary.positiveIdentifier(edge.node.id) != nil,
              edge.node.id != root.id, edge.node.id != selectedAniListID,
              !knownRegularOwnerIDs.contains(edge.node.id),
              edge.node.format?.uppercased() == "ONA", edge.node.episodes == 1,
              edge.node.status?.uppercased() == "FINISHED",
              let date = edge.node.startDate?.exactDateString, edge.node.endDate?.exactDateString == date else { return nil }
        return edge.node.id
    }

    static func featurePrequelCandidate(
        root: AniListAnime, selectedAniListID: Int?, knownRegularOwnerIDs: Set<Int>,
        hydratedCandidate: AniListAnime? = nil
    ) -> AniListAnime? {
        guard let id = featurePrequelCandidateID(root: root, selectedAniListID: selectedAniListID,
            knownRegularOwnerIDs: knownRegularOwnerIDs),
              let candidate = hydratedCandidate,
              candidate.id == id, candidate.type == "ANIME", candidate.format?.uppercased() == "ONA",
              candidate.episodes == 1, candidate.status?.uppercased() == "FINISHED",
              let date = candidate.startDate?.exactDateString, candidate.endDate?.exactDateString == date,
              let candidateRelations = candidate.relations else { return nil }
        let candidateEdges = candidateRelations.edges.filter { related in
            ["PREQUEL", "SEQUEL", "SEASON"].contains(related.relationType.uppercased())
                && (related.node.type == nil || related.node.type == "ANIME")
                && (related.node.format == nil || !["SPECIAL", "TV_SPECIAL", "OVA", "OAD", "MOVIE", "MUSIC"].contains(related.node.format?.uppercased() ?? "")
                    || knownRegularOwnerIDs.contains(related.node.id))
        }
        guard candidateEdges.count == 1, let successor = candidateEdges.first,
              successor.relationType.uppercased() == "SEQUEL", successor.node.id == root.id,
              successor.node.type == "ANIME", successor.node.format?.uppercased() == "TV" else { return nil }
        return candidate
    }

    static func uniqueMovieID(candidate: AniListAnime, movies: [TMDBMovie]) -> Int? {
        guard candidate.format?.uppercased() == "ONA", candidate.episodes == 1,
              candidate.status?.uppercased() == "FINISHED",
              let date = candidate.startDate?.exactDateString, movies.count < 20 else { return nil }
        let titles = Set(AniListTitlePicker.titleCandidates(from: candidate.title).map(normalized).filter { !$0.isEmpty })
        let ids = Set(movies.filter {
            $0.releaseDate?.prefix(4) == date.prefix(4)
                && (titles.contains(normalized($0.title)) || (movies.count == 1 && $0.originalLanguage == "ja"))
        }.compactMap { RemoteMediaNumericBoundary.positiveIdentifier($0.id) })
        return ids.count == 1 ? ids.first : nil
    }

    static func validatedOpenEndedInventory(
        hasExactRootIdentity: Bool, root: AniListAnime, tmdbSeasonEpisodeCounts: [Int: Int],
        sourceEpisodes: [TMDBEpisode]
    ) -> [TMDBEpisode]? {
        guard hasExactRootIdentity, root.format?.uppercased() == "TV",
              root.status?.uppercased() == "RELEASING", root.episodes == nil, root.relations != nil,
              let firstDate = root.startDate?.exactDateString,
              (1...64).contains(tmdbSeasonEpisodeCounts.count),
              tmdbSeasonEpisodeCounts.allSatisfy({ RemoteMediaNumericBoundary.seasonNumber($0.key) != nil
                && RemoteMediaNumericBoundary.episodeCount($0.value) != nil }),
              let total = RemoteMediaNumericBoundary.boundedSum(tmdbSeasonEpisodeCounts.values),
              sourceEpisodes.count == total, Set(sourceEpisodes.map(\.id)).count == total,
              Set(sourceEpisodes.map { "\($0.seasonNumber):\($0.episodeNumber)" }).count == total,
              sourceEpisodes.allSatisfy({ RemoteMediaNumericBoundary.positiveIdentifier($0.id) != nil
                && RemoteMediaNumericBoundary.episodeNumber($0.episodeNumber) != nil
                && tmdbSeasonEpisodeCounts[$0.seasonNumber] != nil && validDate($0.airDate) != nil }) else { return nil }
        for (season, count) in tmdbSeasonEpisodeCounts {
            guard sourceEpisodes.filter({ $0.seasonNumber == season }).count == count else { return nil }
        }
        let rows = sourceEpisodes.sorted {
            $0.seasonNumber == $1.seasonNumber ? $0.episodeNumber < $1.episodeNumber : $0.seasonNumber < $1.seasonNumber
        }
        guard rows.first?.airDate == firstDate,
              zip(rows, rows.dropFirst()).allSatisfy({ ($0.0.airDate ?? "") <= ($0.1.airDate ?? "") }) else { return nil }
        return rows
    }

    static func isDetachedFeaturePrequel(
        candidate: AniListAnime, root: AniListAnime, movie: TMDBMovieDetail, selectedAniListID: Int?,
        hasSameShowPlacement: Bool, tmdbSeasonEpisodeCounts: [Int: Int], sourceEpisodes: [TMDBEpisode],
        exclusiveMovieID: Int? = nil, independentlyDistinctEpisodeIMDbIDs: [Int: String] = [:]
    ) -> Bool {
        guard selectedAniListID != candidate.id, !hasSameShowPlacement,
              candidate.format?.uppercased() == "ONA", candidate.episodes == 1,
              candidate.status?.uppercased() == "FINISHED",
              let date = candidate.startDate?.exactDateString, candidate.endDate?.exactDateString == date,
              let rootDate = root.startDate?.exactDateString,
              date > rootDate, RemoteMediaNumericBoundary.positiveIdentifier(movie.id) != nil,
              movie.originalLanguage == "ja", movie.genres.contains(where: { $0.id == 16 }),
              let runtime = movie.runtime, (1...300).contains(runtime),
              movie.releaseDate?.prefix(4) == date.prefix(4),
              let digitalDates = recordedDigitalReleaseDates(movie), digitalDates.contains(date),
              let movieIMDbID = TMDBService.EpisodeExternalIdentity.validatedIMDbID(movie.imdbId),
              exclusiveMovieID == movie.id,
              tmdbSeasonEpisodeCounts.values.allSatisfy({ $0 > 1 }),
              let source = validatedOpenEndedInventory(hasExactRootIdentity: true, root: root,
                tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts, sourceEpisodes: sourceEpisodes) else { return false }
        let titles = Set(AniListTitlePicker.titleCandidates(from: candidate.title).map(normalized).filter { !$0.isEmpty })
        let movieTitles = Set([movie.title, movie.originalTitle].compactMap { $0 }.map(normalized).filter { !$0.isEmpty })
        let rootTitles = Set(AniListTitlePicker.titleCandidates(from: root.title).map(normalized).filter { !$0.isEmpty })
        guard !titles.isDisjoint(with: movieTitles), rootTitles.isDisjoint(with: movieTitles) else { return false }
        guard let coincidentRows = coincidentEpisodeIdentityCandidates(candidate: candidate, movie: movie, sourceEpisodes: source) else { return false }
        return coincidentRows.allSatisfy { episode in
            guard let imdbID = TMDBService.EpisodeExternalIdentity.validatedIMDbID(independentlyDistinctEpisodeIMDbIDs[episode.id]) else { return false }
            return imdbID != movieIMDbID
        }
    }

    static func coincidentEpisodeIdentityCandidates(
        candidate: AniListAnime, movie: TMDBMovieDetail, sourceEpisodes: [TMDBEpisode]
    ) -> [TMDBEpisode]? {
        guard let candidateDate = candidate.startDate?.exactDateString,
              let digitalDates = recordedDigitalReleaseDates(movie), digitalDates.contains(candidateDate),
              sourceEpisodes.count <= RemoteMediaNumericBoundary.maximumTotalEpisodeCount else { return nil }
        let titles = Set(AniListTitlePicker.titleCandidates(from: candidate.title).map(normalized).filter { !$0.isEmpty })
            .union([movie.title, movie.originalTitle].compactMap { $0 }.map(normalized).filter { !$0.isEmpty })
        guard !sourceEpisodes.contains(where: { titles.contains(normalized($0.name)) }) else { return nil }
        let dates = digitalDates.union([validDate(movie.releaseDate)].compactMap { $0 })
        let coincident = sourceEpisodes.filter { dates.contains($0.airDate ?? "") }
        guard coincident.count <= 4, Set(coincident.map(\.id)).count == coincident.count,
              coincident.allSatisfy({ episode in
                  let title = normalized(episode.name)
                  return RemoteMediaNumericBoundary.positiveIdentifier(episode.id) != nil && !title.isEmpty
                      && title != "episode\(episode.episodeNumber)"
                      && !["tba", "tbd", "tobeannounced", "unknown", "untitled"].contains(title)
              }) else { return nil }
        return coincident
    }

    private static func recordedDigitalReleaseDates(_ movie: TMDBMovieDetail) -> Set<String>? {
        guard let regions = movie.releaseDates?.results, regions.count <= 128,
              regions.allSatisfy({ $0.releaseDates.count <= 128 }) else { return nil }
        let records = regions.flatMap(\.releaseDates).filter { $0.type == 4 }
        guard records.count <= 512 else { return nil }
        let dates = records.compactMap { digitalReleaseDate($0.releaseDate) }
        guard dates.count == records.count, !dates.isEmpty else { return nil }
        return Set(dates)
    }

    private static func normalized(_ value: String) -> String {
        String(value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func digitalReleaseDate(_ value: String) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: value) == nil {
            formatter.formatOptions = [.withInternetDateTime]
            guard formatter.date(from: value) != nil else { return nil }
        }
        return validDate(String(value.prefix(10)))
    }

    private static func validDate(_ value: String?) -> String? {
        guard let value, value.count == 10 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return value
    }
}

enum AnimeMALFallbackRelationPolicy {
    struct BridgeEntry {
        let id: Int
        let format: String?
        let status: String?
        let episodeCount: Int?
        let startDate: String?
        let endDate: String?
        let prequelIDs: [Int]
        let sequelIDs: [Int]
        let hasForeignMapping: Bool
    }

    static func specialBridgeOppositeID(_ bridge: BridgeEntry, current: BridgeEntry) -> Int? {
        guard isEligibleBridge(bridge), isEligibleOrdinary(current), current.id != bridge.id else { return nil }
        if bridge.prequelIDs == [current.id], current.sequelIDs.contains(bridge.id) { return bridge.sequelIDs.first }
        if bridge.sequelIDs == [current.id], current.prequelIDs.contains(bridge.id) { return bridge.prequelIDs.first }
        return nil
    }

    static func verifiedSpecialBridge(_ bridge: BridgeEntry, prequel: BridgeEntry, sequel: BridgeEntry) -> AnimeStructureRelationConstraint? {
        guard isEligibleBridge(bridge), isEligibleOrdinary(prequel), isEligibleOrdinary(sequel),
              Set([bridge.id, prequel.id, sequel.id]).count == 3,
              bridge.prequelIDs == [prequel.id], bridge.sequelIDs == [sequel.id],
              prequel.sequelIDs.filter({ $0 == bridge.id }).count == 1,
              sequel.prequelIDs.filter({ $0 == bridge.id }).count == 1,
              let priorEnd = validDate(prequel.endDate), let nextStart = validDate(sequel.startDate),
              let start = validDate(bridge.startDate), let end = validDate(bridge.endDate),
              priorEnd <= start, end <= nextStart else { return nil }
        return .init(beforeID: prequel.id, afterID: sequel.id)
    }

    static func allowsVerifiedBridgeLinearInventory(
        hasExactRootIdentity: Bool, graphIsComplete: Bool, hasClosedReciprocalChain: Bool,
        providerStartDate: String?, providerStartDates: [String?], episodeCounts: [Int?], statuses: [String?], mediaFormats: [String?],
        tmdbSeasonEpisodeCounts: [Int: Int], sourceEpisodes: [TMDBEpisode]
    ) -> Bool {
        guard hasExactRootIdentity, graphIsComplete, hasClosedReciprocalChain,
              !episodeCounts.isEmpty, episodeCounts.count == statuses.count, mediaFormats.count == episodeCounts.count,
              providerStartDates.count == episodeCounts.count,
              let target = RemoteMediaNumericBoundary.boundedSum(tmdbSeasonEpisodeCounts.values), target > 0,
              sourceEpisodes.count == target,
              sourceEpisodes.count <= RemoteMediaNumericBoundary.maximumTotalEpisodeCount,
              Set(sourceEpisodes.map(\.id)).count == target,
              Set(sourceEpisodes.map { "\($0.seasonNumber):\($0.episodeNumber)" }).count == target else { return false }
        let upcoming = statuses.map { ["NOT_YET_RELEASED", "NOT_YET_AIRED"].contains($0?.uppercased() ?? "") }
        let activeEnd = upcoming.firstIndex(of: true) ?? episodeCounts.count
        let starts = providerStartDates.prefix(activeEnd).compactMap { validDate($0) }
        guard activeEnd > 0, upcoming[activeEnd...].allSatisfy({ $0 }),
              mediaFormats.allSatisfy({ $0?.uppercased() == "TV" }),
              starts.count == activeEnd, starts.first == validDate(providerStartDate),
              zip(starts, starts.dropFirst()).allSatisfy({ $0.0 <= $0.1 }),
              statuses.prefix(activeEnd).allSatisfy({ ["FINISHED", "FINISHED_AIRING"].contains($0?.uppercased() ?? "") }),
              episodeCounts.prefix(activeEnd).allSatisfy({ RemoteMediaNumericBoundary.episodeCount($0) != nil }),
              RemoteMediaNumericBoundary.boundedSum(episodeCounts.prefix(activeEnd).compactMap { $0 }) == target else { return false }
        let rows = sourceEpisodes.sorted {
            $0.seasonNumber == $1.seasonNumber ? $0.episodeNumber < $1.episodeNumber : $0.seasonNumber < $1.seasonNumber
        }
        guard validDate(providerStartDate) == validDate(rows.first?.airDate), validDate(providerStartDate) != nil,
              rows.allSatisfy({ RemoteMediaNumericBoundary.positiveIdentifier($0.id) != nil && validDate($0.airDate) != nil }),
              zip(rows, rows.dropFirst()).allSatisfy({ ($0.0.airDate ?? "") <= ($0.1.airDate ?? "") }) else { return false }
        for (season, count) in tmdbSeasonEpisodeCounts {
            guard RemoteMediaNumericBoundary.seasonNumber(season) != nil,
                  RemoteMediaNumericBoundary.episodeCount(count) != nil else { return false }
            let episodes = rows.filter { $0.seasonNumber == season }
            guard episodes.count == count, episodes.enumerated().allSatisfy({ $0.element.episodeNumber == $0.offset + 1 }) else { return false }
        }
        return true
    }

    static func verifiedUnmappedOngoingEpisodeCounts(
        hasExactRootIdentity: Bool, graphIsComplete: Bool, hasCompetingOwner: Bool,
        entries: [BridgeEntry], tmdbSeasonEpisodeCounts: [Int: Int],
        sourceEpisodes: [TMDBEpisode], today: String
    ) -> [Int]? {
        guard hasExactRootIdentity, graphIsComplete, !hasCompetingOwner,
              (2...64).contains(entries.count), tmdbSeasonEpisodeCounts.count == 1,
              let inventory = tmdbSeasonEpisodeCounts.first,
              RemoteMediaNumericBoundary.seasonNumber(inventory.key) != nil,
              let target = RemoteMediaNumericBoundary.episodeCount(inventory.value),
              sourceEpisodes.count == target,
              Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({ entry in
                  RemoteMediaNumericBoundary.positiveIdentifier(entry.id) != nil && !entry.hasForeignMapping
                      && entry.format?.uppercased() == "TV"
                      && RemoteMediaNumericBoundary.episodeCount(entry.episodeCount) != nil
                      && validDate(entry.startDate) != nil
              }), entries.dropLast().allSatisfy({
                  ["FINISHED", "FINISHED_AIRING"].contains($0.status?.uppercased() ?? "")
              }), ["RELEASING", "CURRENTLY_AIRING"].contains(entries.last?.status?.uppercased() ?? ""),
              let completedCount = RemoteMediaNumericBoundary.boundedSum(entries.dropLast().compactMap(\.episodeCount)),
              completedCount < target,
              let total = RemoteMediaNumericBoundary.boundedSum(entries.compactMap(\.episodeCount)), total >= target,
              let day = validDate(today) else { return nil }
        for (index, entry) in entries.enumerated() {
            let previousIDs = index == 0 ? [] : [entries[index - 1].id]
            let nextIDs = index + 1 == entries.count ? [] : [entries[index + 1].id]
            guard entry.prequelIDs == previousIDs, entry.sequelIDs == nextIDs else { return nil }
        }
        let source = sourceEpisodes.sorted { $0.episodeNumber < $1.episodeNumber }
        let dates = source.compactMap { validDate($0.airDate) }
        guard dates.count == target, Set(source.map(\.id)).count == target,
              source.enumerated().allSatisfy({ index, episode in
                  RemoteMediaNumericBoundary.positiveIdentifier(episode.id) != nil
                      && episode.seasonNumber == inventory.key && episode.episodeNumber == index + 1
              }), zip(dates, dates.dropFirst()).allSatisfy({ $0.0 <= $0.1 }),
              dates[completedCount - 1] <= day, dates[completedCount] <= day else { return nil }
        var boundary = 0
        for (index, entry) in entries.enumerated() {
            guard source.indices.contains(boundary), let count = entry.episodeCount,
                  validDate(entry.startDate) == dates[boundary] else { return nil }
            if index + 1 < entries.count {
                guard count <= target - boundary,
                      validDate(entry.endDate) == dates[boundary + count - 1] else { return nil }
            }
            boundary += count
        }
        return AnimeStructurePolicy.verifiedOngoingEpisodeCounts(
            hasExactRootIdentity: true, hasTrustedOrdinaryCourRoster: true,
            hasOrdinaryContinuationAmbiguity: false, mediaFormats: entries.map(\.format),
            statuses: entries.map(\.status), episodeCounts: entries.map(\.episodeCount),
            providerStartDates: entries.map(\.startDate), tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
            sourceEpisodes: source, today: today
        )
    }

    private static func isEligibleBridge(_ entry: BridgeEntry) -> Bool {
        guard RemoteMediaNumericBoundary.positiveIdentifier(entry.id) != nil, !entry.hasForeignMapping,
              ["SPECIAL", "OVA", "OAD"].contains(entry.format?.uppercased() ?? ""),
              ["FINISHED", "FINISHED_AIRING"].contains(entry.status?.uppercased() ?? ""), entry.episodeCount == 1,
              let start = validDate(entry.startDate), let end = validDate(entry.endDate), start <= end,
              entry.prequelIDs.count == 1, entry.sequelIDs.count == 1,
              Set(entry.prequelIDs + entry.sequelIDs + [entry.id]).count == 3,
              (entry.prequelIDs + entry.sequelIDs).allSatisfy({ RemoteMediaNumericBoundary.positiveIdentifier($0) != nil }) else { return false }
        return true
    }

    private static func isEligibleOrdinary(_ entry: BridgeEntry) -> Bool {
        RemoteMediaNumericBoundary.positiveIdentifier(entry.id) != nil && !entry.hasForeignMapping
            && ["TV", "TV_SHORT", "ONA"].contains(entry.format?.uppercased() ?? "")
            && RemoteMediaNumericBoundary.episodeCount(entry.episodeCount) != nil
    }

    private static func validDate(_ value: String?) -> String? {
        guard let value, value.count == 10 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return value
    }

    static func regularGraphEntryLimit(
        tmdbSeasonEpisodeCounts: [Int: Int]?, mappedRegularEntryCount: Int
    ) -> Int {
        guard let counts = tmdbSeasonEpisodeCounts,
              !counts.isEmpty,
              counts.allSatisfy({ season, count in
                  RemoteMediaNumericBoundary.seasonNumber(season) != nil
                      && RemoteMediaNumericBoundary.episodeCount(count) != nil
              }), mappedRegularEntryCount >= 0 else { return 12 }
        return min(64, max(12, min(64, counts.count) + min(64, mappedRegularEntryCount) + 1))
    }

    static func traversesRegular(
        relationType: String,
        isMappedRegular: Bool
    ) -> Bool {
        if isMappedRegular { return true }
        return ["sequel", "prequel", "parent_story", "main_story", "full_story"]
            .contains(relationType.lowercased())
    }

    static func discoversDetachedSpecial(
        relationType: String,
        isMappedDetachedSpecial: Bool
    ) -> Bool {
        if isMappedDetachedSpecial { return true }
        return ["side_story", "spin_off", "other", "summary", "alternative_version"]
            .contains(relationType.lowercased())
    }
}

enum AnimeVerifiedEpisodeZeroMappingPolicy {
    static let provenanceURLs = [
        "https://www.ntv.co.jp/kiminitodoke/static/story.html",
        "https://www.production-ig.co.jp/works/kimini-todoke-second/episodes/index.html"
    ]

    static func requiresEpisodeZero(
        tmdbShowId: Int, aniListID: Int?, malID: Int?, episodeCount: Int?,
        format: String?, status: String?, startDate: String?, endDate: String?,
        tmdbSeasonEpisodeCounts: [Int: Int]
    ) -> Bool {
        tmdbShowId == 68854 && aniListID == 9656 && (malID == nil || malID == 9656)
            && episodeCount == 13 && format?.uppercased() == "TV" && status?.uppercased() == "FINISHED"
            && startDate == "2011-01-12" && endDate == "2011-03-30"
            && tmdbSeasonEpisodeCounts[2] == 12
    }

    static func prologueEpisode(
        tmdbShowId: Int, aniListID: Int?, malID: Int?, episodeCount: Int?,
        format: String?, status: String?, startDate: String?, endDate: String?,
        regularEpisodes: [TMDBEpisode], specialEpisodes: [TMDBEpisode]
    ) -> TMDBEpisode? {
        guard regularEpisodes.count <= RemoteMediaNumericBoundary.maximumTotalEpisodeCount,
              specialEpisodes.count <= RemoteMediaNumericBoundary.maximumTotalEpisodeCount - regularEpisodes.count else { return nil }
        let regular = regularEpisodes.filter { $0.seasonNumber == 2 }
            .sorted { $0.episodeNumber < $1.episodeNumber }
        guard requiresEpisodeZero(
            tmdbShowId: tmdbShowId, aniListID: aniListID, malID: malID,
            episodeCount: episodeCount, format: format, status: status, startDate: startDate,
            endDate: endDate, tmdbSeasonEpisodeCounts: [2: regular.count]
        ), regular.count == 12,
        regular.enumerated().allSatisfy({ index, episode in
            episode.episodeNumber == index + 1 && validDay(episode.airDate)
                && (episode.airDate ?? "") >= "2011-01-12"
                && (episode.airDate ?? "") <= "2011-03-30"
        }), regular.first?.id == 1344631, regular.last?.id == 1344642,
        regular.first?.airDate == "2011-01-12",
        regular.last?.airDate == "2011-03-30",
        zip(regular, regular.dropFirst()).allSatisfy({ ($0.airDate ?? "") <= ($1.airDate ?? "") }),
        specialEpisodes.allSatisfy({ $0.seasonNumber == 0 && $0.episodeNumber > 0 }) else { return nil }
        let allEpisodes = regularEpisodes + specialEpisodes
        guard allEpisodes.allSatisfy({
            RemoteMediaNumericBoundary.positiveIdentifier($0.id) != nil
                && RemoteMediaNumericBoundary.seasonNumber($0.seasonNumber, allowsZero: true) != nil
                && RemoteMediaNumericBoundary.episodeCount($0.episodeNumber) != nil
        }),
              Set(allEpisodes.map(\.id)).count == allEpisodes.count,
              Set(allEpisodes.map { "\($0.seasonNumber):\($0.episodeNumber)" }).count == allEpisodes.count else { return nil }
        let candidates = specialEpisodes.filter { $0.episodeNumber == 1 }
        guard candidates.count == 1, let episode = candidates.first,
              episode.id == 1699406, episode.airDate == "2011-01-05" else { return nil }
        return episode
    }

    private static func validDay(_ value: String?) -> Bool {
        guard let value, value.count == 10 else { return false }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        if let zone = TimeZone(secondsFromGMT: 0) { calendar.timeZone = zone }
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return false }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        return actual.year == year && actual.month == month && actual.day == day
    }
}

enum AnimeSpecialEpisodeHydrationPolicy {
    struct ContinuationParent {
        let mapping: AniMapMapping
        let relationType: String
        let episodeCount: Int?
        let status: String?
        let format: String?
        let startDate: String?
        let endDate: String?
    }

    static func continuationEpisodes(
        tmdbShowId: Int,
        episodeCount: Int?,
        format: String?,
        status: String?,
        exactReleaseDate: String?,
        exactEndDate: String?,
        parents: [ContinuationParent],
        seasonDetailsByNumber: [Int: TMDBSeasonDetail]
    ) -> [TMDBEpisode] {
        guard RemoteMediaNumericBoundary.positiveIdentifier(tmdbShowId) != nil,
              let episodeCount = RemoteMediaNumericBoundary.episodeCount(episodeCount),
              format?.uppercased() == "SPECIAL",
              isFinished(status),
              let releaseDate = exactReleaseDate,
              releaseDate == exactEndDate,
              let releaseDay = exactDay(releaseDate),
              parents.count == 1 else { return [] }

        let windows = parents.compactMap { parent -> [TMDBEpisode]? in
            guard parent.relationType.uppercased() == "SEQUEL",
                  parent.mapping.tmdbShowId == tmdbShowId,
                  parent.mapping.tvdbEpisodeOffset == 0,
                  let seasonNumber = RemoteMediaNumericBoundary.seasonNumber(parent.mapping.tmdbSeason),
                  ["TV", "TV_SHORT", "ONA"].contains(parent.format?.uppercased() ?? ""),
                  AniMapStructuralRole.isRegularStory(parent.mapping, fallbackMediaType: parent.format),
                  isFinished(parent.status),
                  let parentCount = RemoteMediaNumericBoundary.episodeCount(parent.episodeCount),
                  parentCount <= RemoteMediaNumericBoundary.maximumEpisodeCount - episodeCount,
                  let firstDay = exactDay(parent.startDate),
                  let lastDay = exactDay(parent.endDate), firstDay <= lastDay,
                  let detail = seasonDetailsByNumber[seasonNumber],
                  detail.seasonNumber == seasonNumber,
                  detail.episodes.count == parentCount + episodeCount else { return nil }
            let episodes = detail.episodes.sorted { $0.episodeNumber < $1.episodeNumber }
            guard episodes.allSatisfy({ RemoteMediaNumericBoundary.positiveIdentifier($0.id) != nil }),
                  Set(episodes.map(\.id)).count == episodes.count,
                  episodes.enumerated().allSatisfy({ index, episode in
                episode.seasonNumber == seasonNumber && episode.episodeNumber == index + 1
            }) else { return nil }
            let ordinary = Array(episodes.prefix(parentCount))
            let ordinaryDays = ordinary.compactMap { exactDay($0.airDate) }
            guard ordinaryDays.count == parentCount,
                  let sourceFirst = ordinaryDays.first,
                  let sourceLast = ordinaryDays.last,
                  zip(ordinaryDays, ordinaryDays.dropFirst()).allSatisfy({ $0.0 <= $0.1 }),
                  let firstOffset = dayOffset(from: firstDay, to: sourceFirst),
                  let lastOffset = dayOffset(from: lastDay, to: sourceLast),
                  (-1...1).contains(firstOffset), firstOffset == lastOffset,
                  sourceLast < releaseDay else { return nil }
            let tail = Array(episodes.suffix(episodeCount))
            guard tail.allSatisfy({ $0.airDate == releaseDate }) else { return nil }
            return tail
        }
        return windows.count == 1 ? windows[0] : []
    }

    static func uniquelyOwnedContinuationEpisodes(_ candidates: [Int: [TMDBEpisode]]) -> [Int: [TMDBEpisode]] {
        var owners: [String: Set<Int>] = [:]
        for (id, episodes) in candidates where !episodes.isEmpty {
            for episode in episodes {
                owners["\(episode.seasonNumber):\(episode.episodeNumber)", default: []].insert(id)
            }
        }
        let competingIDs = owners.values.filter { $0.count > 1 }.reduce(into: Set<Int>()) { $0.formUnion($1) }
        return candidates.filter { !$0.value.isEmpty && !competingIDs.contains($0.key) }
    }

    private static func isFinished(_ status: String?) -> Bool {
        ["FINISHED", "FINISHED_AIRING"].contains(status?.uppercased() ?? "")
    }

    private static func exactDay(_ rawValue: String?) -> Date? {
        guard let rawValue, rawValue.count == 10 else { return nil }
        let parts = rawValue.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), RemoteMediaNumericBoundary.year(year) != nil,
              let month = Int(parts[1]), (1...12).contains(month),
              let day = Int(parts[2]), (1...31).contains(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        if let timeZone = TimeZone(secondsFromGMT: 0) { calendar.timeZone = timeZone }
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return nil }
        let verified = calendar.dateComponents([.year, .month, .day], from: date)
        guard verified.year == year, verified.month == month, verified.day == day else { return nil }
        return date
    }

    private static func dayOffset(from first: Date, to second: Date) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        if let timeZone = TimeZone(secondsFromGMT: 0) { calendar.timeZone = timeZone }
        return calendar.dateComponents([.day], from: first, to: second).day
    }

    static func exactEpisodes(
        episodeCount: Int,
        exactReleaseDate: String?,
        mappedSeasonNumber: Int?,
        seasonDetailsByNumber: [Int: TMDBSeasonDetail],
        exactEndDate: String? = nil
    ) -> [TMDBEpisode] {
        guard let episodeCount = RemoteMediaNumericBoundary.episodeCount(episodeCount) else {
            return []
        }
        let sourceSeasonNumber = mappedSeasonNumber ?? 0
        guard RemoteMediaNumericBoundary.seasonNumber(
            sourceSeasonNumber,
            allowsZero: true
        ) != nil else {
            return []
        }
        let episodes = seasonDetailsByNumber[sourceSeasonNumber]?.episodes.sorted {
            $0.episodeNumber < $1.episodeNumber
        } ?? []
        guard !episodes.isEmpty else { return [] }

        if let exactEndDate {
            guard let exactReleaseDate, let firstDay = exactDay(exactReleaseDate),
                  let lastDay = exactDay(exactEndDate), firstDay <= lastDay,
                  episodes.count <= RemoteMediaNumericBoundary.maximumEpisodeCount,
                  episodes.allSatisfy({ RemoteMediaNumericBoundary.positiveIdentifier($0.id) != nil }),
                  Set(episodes.map(\.id)).count == episodes.count,
                  Set(episodes.map(\.episodeNumber)).count == episodes.count else { return [] }
            let windows = episodes.indices.compactMap { start -> [TMDBEpisode]? in
                guard episodes[start].airDate == exactReleaseDate,
                      start <= episodes.count - episodeCount else { return nil }
                let window = Array(episodes[start..<(start + episodeCount)])
                guard window.last?.airDate == exactEndDate,
                      window.enumerated().allSatisfy({ offset, episode in
                          episode.seasonNumber == sourceSeasonNumber
                            && RemoteMediaNumericBoundary.episodeNumber(episode.episodeNumber) != nil
                            && episode.episodeNumber == window[0].episodeNumber + offset
                            && exactDay(episode.airDate).map { $0 >= firstDay && $0 <= lastDay } == true
                      }),
                      zip(window, window.dropFirst()).allSatisfy({
                          guard let first = $0.0.airDate, let second = $0.1.airDate else { return false }
                          return first <= second
                      }) else { return nil }
                return window
            }
            return windows.count == 1 ? windows[0] : []
        }

        if episodes.count == episodeCount {
            return episodes
        }

        guard let exactReleaseDate,
              !exactReleaseDate.isEmpty else {
            return []
        }
        let matchingStartIndices = episodes.indices.filter {
            episodes[$0].airDate == exactReleaseDate
        }
        guard matchingStartIndices.count == 1,
              let startIndex = matchingStartIndices.first else {
            return []
        }
        let endIndex = startIndex + episodeCount
        guard endIndex <= episodes.endIndex else { return [] }

        let window = Array(episodes[startIndex..<endIndex])
        guard window.enumerated().allSatisfy({ offset, episode in
            episode.episodeNumber == window[0].episodeNumber + offset
                && episode.airDate.map { $0 >= exactReleaseDate } == true
        }) else {
            return []
        }
        return window
    }
}

enum AnimeTerminalSeasonProjectionPolicy {
    struct Entry {
        let providerID: Int
        let mapping: AniMapMapping?
        let episodeCount: Int?
        let status: String?
        let format: String?
        let startDate: String?
        let followsPrevious: Bool
    }

    static func candidateSeasonNumber(
        tmdbShowId: Int,
        entries: [Entry],
        tmdbSeasonEpisodeCounts: [Int: Int],
        hasCompetingOrdinaryOwner: Bool
    ) -> Int? {
        let seasons = tmdbSeasonEpisodeCounts.keys.sorted()
        guard !hasCompetingOrdinaryOwner,
              RemoteMediaNumericBoundary.positiveIdentifier(tmdbShowId) != nil,
              entries.count > 1, entries.count <= 64, entries.count == seasons.count,
              Set(entries.map(\.providerID)).count == entries.count,
              entries.allSatisfy({ RemoteMediaNumericBoundary.positiveIdentifier($0.providerID) != nil }),
              tmdbSeasonEpisodeCounts.allSatisfy({
                  RemoteMediaNumericBoundary.seasonNumber($0.key) != nil
                    && RemoteMediaNumericBoundary.episodeCount($0.value) != nil
              }),
              let terminal = entries.last, let terminalSeason = seasons.last,
              ["RELEASING", "CURRENTLY_AIRING"].contains(terminal.status?.uppercased() ?? ""),
              terminal.episodeCount == nil, terminal.followsPrevious,
              ["TV", "TV_SHORT", "ONA"].contains(terminal.format?.uppercased() ?? ""),
              terminal.startDate != nil else { return nil }
        if let mapping = terminal.mapping {
            guard mapping.tmdbShowId == tmdbShowId, mapping.tmdbSeason == terminalSeason,
                  AniMapStructuralRole.isRegularStory(mapping, fallbackMediaType: terminal.format) else { return nil }
        }
        for (index, entry) in entries.dropLast().enumerated() {
            guard ["FINISHED", "FINISHED_AIRING"].contains(entry.status?.uppercased() ?? ""),
                  ["TV", "TV_SHORT", "ONA"].contains(entry.format?.uppercased() ?? ""),
                  let mapping = entry.mapping, mapping.tmdbShowId == tmdbShowId,
                  mapping.tmdbSeason == seasons[index],
                  AniMapStructuralRole.isRegularStory(mapping, fallbackMediaType: entry.format),
                  let count = RemoteMediaNumericBoundary.episodeCount(entry.episodeCount),
                  count == tmdbSeasonEpisodeCounts[seasons[index]] else { return nil }
        }
        return terminalSeason
    }

    static func verifiedEpisodes(
        tmdbShowId: Int,
        entries: [Entry],
        tmdbSeasonEpisodeCounts: [Int: Int],
        hasCompetingOrdinaryOwner: Bool,
        sourceSeason: TMDBSeasonDetail,
        today: String
    ) -> [Int: [TMDBEpisode]] {
        guard let season = candidateSeasonNumber(tmdbShowId: tmdbShowId, entries: entries,
            tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts, hasCompetingOrdinaryOwner: hasCompetingOrdinaryOwner),
              sourceSeason.seasonNumber == season,
              let terminal = entries.last, let startDate = terminal.startDate,
              let count = tmdbSeasonEpisodeCounts[season], sourceSeason.episodes.count == count,
              isExactDate(startDate), isExactDate(today), startDate <= today else { return [:] }
        let episodes = sourceSeason.episodes.sorted { $0.episodeNumber < $1.episodeNumber }
        guard Set(episodes.map(\.id)).count == count,
              episodes.first?.airDate == startDate,
              episodes.enumerated().allSatisfy({ index, episode in
                  RemoteMediaNumericBoundary.positiveIdentifier(episode.id) != nil
                    && episode.seasonNumber == season && episode.episodeNumber == index + 1
                    && episode.airDate.map { isExactDate($0) && $0 >= startDate } == true
              }),
              zip(episodes, episodes.dropFirst()).allSatisfy({
                  guard let first = $0.0.airDate, let second = $0.1.airDate else { return false }
                  return first <= second
              }) else { return [:] }
        return [terminal.providerID: episodes]
    }

    private static func isExactDate(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }
}

enum AnimeStructurePolicy {
    static func shouldPrefetchRelatedNodeLookup(
        rosterIsClosed: Bool,
        startsVerifiedInventoryEarly: Bool,
        lookupIsComplete: Bool,
        hasUnresolvedIdentity: Bool,
        mappedRosterCount: Int,
        mappedSeasonNumbers: Set<Int>,
        hasExactRootIdentity: Bool,
        rootEpisodeCount: Int?,
        rootFormat: String?,
        rootStatus: String?,
        tmdbSeasonEpisodeCounts: [Int: Int]
    ) -> Bool {
        guard !rosterIsClosed, !startsVerifiedInventoryEarly, hasExactRootIdentity,
              !tmdbSeasonEpisodeCounts.isEmpty,
              tmdbSeasonEpisodeCounts.count <= RemoteMediaNumericBoundary.maximumSeasonNumber,
              tmdbSeasonEpisodeCounts.allSatisfy({
                  RemoteMediaNumericBoundary.seasonNumber($0.key) != nil
                    && RemoteMediaNumericBoundary.episodeCount($0.value) != nil
              }),
              let total = RemoteMediaNumericBoundary.boundedSum(tmdbSeasonEpisodeCounts.values) else { return false }
        if lookupIsComplete {
            return !hasUnresolvedIdentity && mappedRosterCount >= 3
                && Set(tmdbSeasonEpisodeCounts.keys).subtracting(mappedSeasonNumbers).count >= 4
        }
        guard tmdbSeasonEpisodeCounts.count >= 4,
              ["TV", "TV_SHORT", "ONA"].contains(rootFormat?.uppercased() ?? ""),
              ["FINISHED", "RELEASING"].contains(rootStatus?.uppercased() ?? ""),
              let count = RemoteMediaNumericBoundary.episodeCount(rootEpisodeCount) else { return false }
        return count < total
    }

    static func hasKnownEpisodeDeficit(
        tmdbTotalEpisodeCount: Int?,
        segments: [AnimeStructureCoverageSegment]
    ) -> Bool {
        guard let tmdbTotalEpisodeCount,
              !segments.isEmpty,
              segments.allSatisfy({ RemoteMediaNumericBoundary.episodeCount($0.episodeCount) != nil }),
              let minimumExpected = RemoteMediaNumericBoundary.scaledEpisodeCount(
                tmdbTotalEpisodeCount, numerator: 3, denominator: 4
              ),
              let total = RemoteMediaNumericBoundary.boundedSum(segments.compactMap(\.episodeCount)) else { return false }
        return total < minimumExpected
    }

    static func acceptsMappedCoverage(
        lookupIsComplete: Bool,
        hasUnresolvedIdentity: Bool,
        hasExactCoverage: Bool,
        allowsSingleOpenEndedSeries: Bool
    ) -> Bool {
        guard lookupIsComplete else { return false }
        if hasExactCoverage { return true }

        return !hasUnresolvedIdentity && allowsSingleOpenEndedSeries
    }

    static func orderedIDs(_ candidates: [AnimeStructureOrderingCandidate]) -> [Int] {
        var seen = Set<Int>()
        return candidates
            .filter { RemoteMediaNumericBoundary.positiveIdentifier($0.anilistId) != nil }
            .sorted(by: isOrderedBefore)
            .compactMap { candidate in
                seen.insert(candidate.anilistId).inserted ? candidate.anilistId : nil
            }
    }

    static func relationOrderedIDs(
        _ candidates: [AnimeStructureOrderingCandidate],
        constraints: [AnimeStructureRelationConstraint]
    ) -> [Int] {
        let chronology = orderedIDs(candidates)
        let ids = Set(chronology)
        let rank = Dictionary(uniqueKeysWithValues: chronology.enumerated().map { ($0.element, $0.offset) })
        var outgoing: [Int: Set<Int>] = [:]
        var indegree = Dictionary(uniqueKeysWithValues: chronology.map { ($0, 0) })
        for constraint in constraints {
            let before = constraint.beforeID
            let after = constraint.afterID
            guard before != after, ids.contains(before), ids.contains(after) else { continue }
            if outgoing[before, default: []].insert(after).inserted {
                indegree[after, default: 0] += 1
            }
        }
        func sorted(_ values: [Int]) -> [Int] {
            values.sorted { (rank[$0] ?? Int.max) < (rank[$1] ?? Int.max) }
        }
        var ready = chronology.filter { indegree[$0] == 0 }
        var result: [Int] = []
        while let next = ready.first {
            ready.removeFirst()
            result.append(next)
            for destination in sorted(Array(outgoing[next] ?? [])) {
                indegree[destination, default: 0] -= 1
                if indegree[destination] == 0 {
                    ready.append(destination)
                    ready = sorted(ready)
                }
            }
        }
        if result.count < chronology.count {
            let emitted = Set(result)
            result.append(contentsOf: chronology.filter { !emitted.contains($0) })
        }
        return result
    }

    static func budgetedIndices(
        episodeCounts: [Int?],
        rootIndex: Int,
        episodeBudget: Int,
        retainedIdentityIndices: Set<Int>
    ) -> [Int] {
        guard episodeCounts.indices.contains(rootIndex),
              episodeBudget >= 0 else { return Array(episodeCounts.indices) }
        var keepStart = rootIndex
        var keepEnd = rootIndex
        var total = episodeCounts[rootIndex] ?? 0
        var canExpandLeft = true
        var canExpandRight = true
        while canExpandLeft || canExpandRight {
            if canExpandLeft && keepStart > 0 {
                let count = episodeCounts[keepStart - 1] ?? 0
                if let expanded = RemoteMediaNumericBoundary.adding(total, count), expanded <= episodeBudget {
                    keepStart -= 1
                    total = expanded
                } else { canExpandLeft = false }
            } else { canExpandLeft = false }
            if canExpandRight && keepEnd < episodeCounts.count - 1 {
                let count = episodeCounts[keepEnd + 1] ?? 0
                if let expanded = RemoteMediaNumericBoundary.adding(total, count), expanded <= episodeBudget {
                    keepEnd += 1
                    total = expanded
                } else { canExpandRight = false }
            } else { canExpandRight = false }
        }
        return episodeCounts.indices.filter {
            (keepStart...keepEnd).contains($0) || retainedIdentityIndices.contains($0)
        }
    }

    static func hasExactCoverage(
        tmdbSeasonEpisodeCounts: [Int: Int],
        segments: [AnimeStructureCoverageSegment]
    ) -> Bool {
        guard tmdbSeasonEpisodeCounts.allSatisfy({ season, count in
            RemoteMediaNumericBoundary.seasonNumber(season, allowsZero: true) != nil
                && RemoteMediaNumericBoundary.episodeCount(count) != nil
        }) else { return false }
        let expected = tmdbSeasonEpisodeCounts.filter { $0.key > 0 }
        guard !expected.isEmpty, !segments.isEmpty else { return false }

        let knownSegments = segments.compactMap { segment -> (Int?, Int)? in
            guard let count = RemoteMediaNumericBoundary.episodeCount(segment.episodeCount),
                  segment.mappedTMDBSeason.map({
                      RemoteMediaNumericBoundary.seasonNumber($0) != nil
                  }) ?? true else { return nil }
            return (segment.mappedTMDBSeason, count)
        }
        guard knownSegments.count == segments.count else { return false }
        guard let actualTotal = RemoteMediaNumericBoundary.boundedSum(knownSegments.map(\.1)),
              let expectedTotal = RemoteMediaNumericBoundary.boundedSum(expected.values) else {
            return false
        }
        let totalMatches = actualTotal == expectedTotal
        if expected.count == 1, totalMatches {

            return knownSegments.allSatisfy { mappedSeason, _ in
                guard let mappedSeason else { return true }
                return expected[mappedSeason] != nil
            }
        }

        let explicitlyMapped = knownSegments.filter { $0.0 != nil }
        if explicitlyMapped.count == knownSegments.count {
            var mappedCounts: [Int: Int] = [:]
            for element in explicitlyMapped {
                let (season, count) = element
                guard let season, season > 0, expected[season] != nil else { return false }
                guard let updated = RemoteMediaNumericBoundary.adding(
                    mappedCounts[season, default: 0],
                    count
                ), updated <= RemoteMediaNumericBoundary.maximumTotalEpisodeCount else {
                    return false
                }
                mappedCounts[season] = updated
            }

            return mappedCounts == expected
        }

        guard knownSegments.allSatisfy({ $0.0 == nil }) else { return false }
        return expected.count == 1 && totalMatches
    }

    static func hasSafePreviewCoverage(
        lookupIsComplete: Bool,
        hasUnresolvedIdentity: Bool,
        tmdbSeasonEpisodeCounts: [Int: Int],
        activeSegments: [AnimeStructureCoverageSegment],
        futureOnlyMappedTMDBSeasons: Set<Int>
    ) -> Bool {
        guard lookupIsComplete,
              !hasUnresolvedIdentity,
              !activeSegments.isEmpty else {
            return false
        }

        guard tmdbSeasonEpisodeCounts.allSatisfy({ season, count in
            RemoteMediaNumericBoundary.seasonNumber(season, allowsZero: true) != nil
                && RemoteMediaNumericBoundary.episodeCount(count) != nil
        }), futureOnlyMappedTMDBSeasons.allSatisfy({
            RemoteMediaNumericBoundary.seasonNumber($0) != nil
        }) else { return false }
        let expected = tmdbSeasonEpisodeCounts.filter {
            $0.key > 0 && !futureOnlyMappedTMDBSeasons.contains($0.key)
        }
        guard !expected.isEmpty else { return false }

        let knownSegments = activeSegments.compactMap { segment -> (Int?, Int)? in
            guard let count = RemoteMediaNumericBoundary.episodeCount(segment.episodeCount),
                  segment.mappedTMDBSeason.map({
                      RemoteMediaNumericBoundary.seasonNumber($0) != nil
                  }) ?? true else { return nil }
            return (segment.mappedTMDBSeason, count)
        }
        guard knownSegments.count == activeSegments.count else { return false }

        if expected.count == 1 {
            guard knownSegments.allSatisfy({ season, _ in
                season.map { expected[$0] != nil } ?? true
            }) else {
                return false
            }
            guard let actual = RemoteMediaNumericBoundary.boundedSum(knownSegments.map(\.1)),
                  let target = RemoteMediaNumericBoundary.boundedSum(expected.values),
                  let difference = RemoteMediaNumericBoundary.absoluteDifference(actual, target) else {
                return false
            }
            return difference <= max(1, knownSegments.count)
        }

        guard knownSegments.allSatisfy({ $0.0 != nil }) else { return false }
        var actualBySeason: [Int: Int] = [:]
        var segmentCountBySeason: [Int: Int] = [:]
        for (season, count) in knownSegments {
            guard let season, expected[season] != nil else { return false }
            guard let updatedCount = RemoteMediaNumericBoundary.adding(
                actualBySeason[season, default: 0],
                count
            ), updatedCount <= RemoteMediaNumericBoundary.maximumTotalEpisodeCount else {
                return false
            }
            actualBySeason[season] = updatedCount
            segmentCountBySeason[season, default: 0] += 1
        }
        guard Set(actualBySeason.keys) == Set(expected.keys) else { return false }

        for (season, target) in expected {
            guard let actual = actualBySeason[season],
                  let difference = RemoteMediaNumericBoundary.absoluteDifference(actual, target) else {
                return false
            }
            let allowedDrift = max(1, segmentCountBySeason[season] ?? 1)
            guard difference <= allowedDrift else { return false }
        }
        return true
    }

    static func allowsLinearTMDBCoordinates(
        hydrationPolicy: AnimeEpisodeHydrationPolicy,
        hasExactCoverage: Bool,
        hasMatchingEpisodeTotals: Bool = false
    ) -> Bool {
        hasExactCoverage || hasMatchingEpisodeTotals
    }

    static func hasCompleteMappedIdentityInventory(
        lookupIsComplete: Bool, hasUnresolvedIdentity: Bool,
        episodeCounts: [Int?], statuses: [String?], tmdbSeasonEpisodeCounts: [Int: Int]
    ) -> Bool {
        guard lookupIsComplete, !hasUnresolvedIdentity, !episodeCounts.isEmpty,
              episodeCounts.count == statuses.count, !tmdbSeasonEpisodeCounts.isEmpty else { return false }
        let counts = episodeCounts.enumerated().compactMap { index, count -> Int? in
            if ["NOT_YET_RELEASED", "NOT_YET_AIRED"].contains(statuses[index]?.uppercased() ?? "") { return 0 }
            return RemoteMediaNumericBoundary.episodeCount(count)
        }
        guard counts.count == episodeCounts.count,
              let total = RemoteMediaNumericBoundary.boundedSum(counts),
              let target = RemoteMediaNumericBoundary.boundedSum(tmdbSeasonEpisodeCounts.values) else { return false }
        return total == target
    }

    static func hasMappedTVBroadcastDateOffsetProof(
        lookupIsComplete: Bool, graphIsComplete: Bool, tmdbShowId: Int,
        mappedShowIDs: [Int?], mediaFormats: [String?], statuses: [String?], episodeCounts: [Int?],
        hasReciprocalTerminalRelation: Bool, hasCompetingOrdinaryOwner: Bool
    ) -> Bool {
        guard lookupIsComplete, graphIsComplete, hasReciprocalTerminalRelation, !hasCompetingOrdinaryOwner,
              RemoteMediaNumericBoundary.positiveIdentifier(tmdbShowId) != nil,
              episodeCounts.count > 1, mappedShowIDs.count == episodeCounts.count,
              mediaFormats.count == episodeCounts.count, statuses.count == episodeCounts.count,
              mappedShowIDs.allSatisfy({ $0 == tmdbShowId }), mediaFormats.allSatisfy({ $0?.uppercased() == "TV" }),
              statuses.dropLast().allSatisfy({ ["FINISHED", "FINISHED_AIRING"].contains($0?.uppercased() ?? "") }),
              episodeCounts.dropLast().allSatisfy({ RemoteMediaNumericBoundary.episodeCount($0) != nil }),
              ["RELEASING", "CURRENTLY_AIRING"].contains(statuses.last.flatMap { $0 }?.uppercased() ?? "") else { return false }
        return true
    }

    static func allowsSingleOngoingPrefix(
        hasExactRootIdentity: Bool,
        hasOnlyRoot: Bool,
        hasOrdinaryContinuationAmbiguity: Bool,
        mediaFormat: String?,
        status: String?,
        episodeCount: Int?,
        mappedTMDBSeason: Int?,
        providerStartDate: String?,
        tmdbSeasonEpisodeCounts: [Int: Int],
        sourceEpisodes: [TMDBEpisode],
        today: String
    ) -> Bool {
        guard hasOnlyRoot, let count = RemoteMediaNumericBoundary.episodeCount(episodeCount),
              let inventory = tmdbSeasonEpisodeCounts.first, count < inventory.value,
              mappedTMDBSeason.map({ $0 == inventory.key }) ?? true else { return false }
        return verifiedOngoingEpisodeCounts(
            hasExactRootIdentity: hasExactRootIdentity, hasTrustedOrdinaryCourRoster: true,
            hasOrdinaryContinuationAmbiguity: hasOrdinaryContinuationAmbiguity,
            mediaFormats: [mediaFormat], statuses: [status], episodeCounts: [episodeCount],
            providerStartDates: [providerStartDate], tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
            sourceEpisodes: sourceEpisodes, today: today
        ) != nil
    }

    static func verifiedOngoingEpisodeCounts(
        hasExactRootIdentity: Bool,
        hasTrustedOrdinaryCourRoster: Bool,
        hasOrdinaryContinuationAmbiguity: Bool,
        mediaFormats: [String?],
        statuses: [String?],
        episodeCounts: [Int?],
        providerStartDates: [String?],
        tmdbSeasonEpisodeCounts: [Int: Int],
        sourceEpisodes: [TMDBEpisode],
        today: String,
        allowsMappedTVBroadcastDateOffsets: Bool = false
    ) -> [Int]? {
        guard hasExactRootIdentity, hasTrustedOrdinaryCourRoster, !hasOrdinaryContinuationAmbiguity,
              !episodeCounts.isEmpty, mediaFormats.count == episodeCounts.count,
              statuses.count == episodeCounts.count, providerStartDates.count == episodeCounts.count,
              mediaFormats.allSatisfy({ ["TV", "TV_SHORT", "ONA"].contains($0?.uppercased() ?? "") }),
              statuses.dropLast().allSatisfy({ ["FINISHED", "FINISHED_AIRING"].contains($0?.uppercased() ?? "") }),
              ["RELEASING", "CURRENTLY_AIRING"].contains(statuses.last.flatMap { $0 }?.uppercased() ?? ""),
              tmdbSeasonEpisodeCounts.count == 1, let inventory = tmdbSeasonEpisodeCounts.first,
              RemoteMediaNumericBoundary.seasonNumber(inventory.key) != nil,
              let target = RemoteMediaNumericBoundary.episodeCount(inventory.value),
              sourceEpisodes.count == target, validatedAirDateString(today) != nil else { return nil }
        let prefix = episodeCounts.dropLast().compactMap(RemoteMediaNumericBoundary.episodeCount)
        guard prefix.count == episodeCounts.count - 1,
              let prefixCount = RemoteMediaNumericBoundary.boundedSum(prefix), prefixCount < target else { return nil }
        let declaredTail = episodeCounts.last.flatMap { $0 }
        guard declaredTail == nil || RemoteMediaNumericBoundary.episodeCount(declaredTail) != nil else { return nil }
        let counts = prefix + [declaredTail ?? target - prefixCount]
        guard let total = RemoteMediaNumericBoundary.boundedSum(counts) else { return nil }
        guard counts.count > 1 || total <= target else { return nil }
        let ordered = sourceEpisodes.sorted { $0.episodeNumber < $1.episodeNumber }
        let permitsCourseDateOffsets = allowsMappedTVBroadcastDateOffsets
            && mediaFormats.allSatisfy({ $0?.uppercased() == "TV" })
            && ordered.allSatisfy({ validatedAirDateString($0.airDate) != nil })
            && zip(ordered, ordered.dropFirst()).allSatisfy({ ($0.0.airDate ?? "") <= ($0.1.airDate ?? "") })
        guard Set(ordered.map(\.id)).count == target,
              ordered.enumerated().allSatisfy({ index, episode in
                  RemoteMediaNumericBoundary.positiveIdentifier(episode.id) != nil
                      && episode.seasonNumber == inventory.key
                      && episode.episodeNumber == index + 1
              }), let offset = airDateOffset(providerStartDates.first.flatMap { $0 }, ordered.first?.airDate),
              offset == 0 || (permitsCourseDateOffsets && (-1...1).contains(offset)) || (offset == 7 && counts.count > 1
                && mediaFormats.allSatisfy({ $0?.uppercased() == "ONA" })) else { return nil }
        var boundary = 0
        for index in counts.indices {
            guard ordered.indices.contains(boundary),
                  let courseOffset = airDateOffset(providerStartDates[index], ordered[boundary].airDate),
                  courseOffset == offset || (permitsCourseDateOffsets && (-1...1).contains(courseOffset)) else { return nil }
            boundary += counts[index]
        }
        guard ordered.dropFirst(total).allSatisfy({ episode in
            guard let date = validatedAirDateString(episode.airDate) else { return false }
            return date > today
        }) else { return nil }
        return counts
    }

    static func currentAirDateString() -> String {
        let formatter = AppCalendar.dateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    static func verifiedContainedCourEpisodes(
        episodeCount: Int?,
        mediaFormat: String?,
        status: String?,
        providerStartDate: String?,
        providerEndDate: String?,
        hasTrustedIdentity: Bool,
        permitsMeasuredOneDayOffset: Bool,
        hasExplicitSpecialContinuation: Bool,
        sourceEpisodeCount: Int,
        sourceEpisodes: [TMDBEpisode],
        allowsMappedFinishedTVPrefix: Bool = false
    ) -> [TMDBEpisode]? {
        guard hasTrustedIdentity,
              ["TV", "TV_SHORT", "ONA"].contains(mediaFormat?.uppercased() ?? ""),
              ["FINISHED", "FINISHED_AIRING"].contains(status?.uppercased() ?? ""),
              let count = RemoteMediaNumericBoundary.episodeCount(episodeCount),
              let target = RemoteMediaNumericBoundary.episodeCount(sourceEpisodeCount),
              !(mediaFormat?.uppercased() == "ONA" && count == 1 && target > 1),
              count <= target, sourceEpisodes.count == target,
              let firstDate = validatedAirDateString(providerStartDate),
              let lastDate = validatedAirDateString(providerEndDate), firstDate <= lastDate else { return nil }
        let source = sourceEpisodes.sorted { $0.episodeNumber < $1.episodeNumber }
        guard Set(source.map(\.id)).count == target, let season = source.first?.seasonNumber,
              RemoteMediaNumericBoundary.seasonNumber(season) != nil,
              source.enumerated().allSatisfy({ index, episode in
                  episode.seasonNumber == season && episode.episodeNumber == index + 1
                      && RemoteMediaNumericBoundary.positiveIdentifier(episode.id) != nil
              }) else { return nil }
        let windows = source.indices.compactMap { start -> [TMDBEpisode]? in
            guard start <= source.count - count,
                  let offset = airDateOffset(firstDate, source[start].airDate),
                  offset == 0 || (permitsMeasuredOneDayOffset && (-1...1).contains(offset)) else { return nil }
            let rows = Array(source[start..<(start + count)])
            let dates = rows.compactMap { validatedAirDateString($0.airDate) }
            let leadsMappedSeason = allowsMappedFinishedTVPrefix && mediaFormat?.uppercased() == "TV"
                && count >= 2 && start == 0 && offset == 0
            guard dates.count == count,
                  zip(dates, dates.dropFirst()).allSatisfy({ $0.0 <= $0.1 }),
                  let lastOffset = airDateOffset(lastDate, rows.last?.airDate),
                  lastOffset == offset || (leadsMappedSeason && lastOffset == 1) else { return nil }
            let before = source.prefix(start)
            let after = source.dropFirst(start + count)
            guard before.allSatisfy({ episode in
                validatedAirDateString(episode.airDate).map { $0 < dates[0] } == true
            }), after.allSatisfy({ episode in
                if let date = validatedAirDateString(episode.airDate) { return date > dates[count - 1] }
                return episode.airDate == nil && !hasExplicitSpecialContinuation
            }) else { return nil }
            let provesMappedTVPrefix = leadsMappedSeason
                && after.allSatisfy({ validatedAirDateString($0.airDate).map { $0 > dates[count - 1] } == true })
            if count < target, !hasExplicitSpecialContinuation, !provesMappedTVPrefix,
               !after.allSatisfy({ $0.airDate == nil }) { return nil }
            return rows
        }
        return windows.count == 1 ? windows[0] : nil
    }

    static func normalizedCourTitle(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    static func verifiedMappedArcContinuation(
        episodeCount: Int?, mediaFormat: String?, status: String?,
        providerStartDate: String?, providerEndDate: String?,
        sourceSeason: TMDBSeasonDetail, sourceEpisodeCount: Int,
        specialEpisodes: [TMDBEpisode]
    ) -> [TMDBEpisode]? {
        guard ["TV", "TV_SHORT", "ONA"].contains(mediaFormat?.uppercased() ?? ""),
              ["FINISHED", "FINISHED_AIRING"].contains(status?.uppercased() ?? ""),
              let count = RemoteMediaNumericBoundary.episodeCount(episodeCount),
              let sourceCount = RemoteMediaNumericBoundary.episodeCount(sourceEpisodeCount),
              count > sourceCount, count - sourceCount <= 8,
              sourceSeason.seasonNumber > 0, sourceSeason.episodes.count == sourceCount,
              let startDate = validatedAirDateString(providerStartDate),
              let endDate = validatedAirDateString(providerEndDate) else { return nil }
        let regular = sourceSeason.episodes.sorted { $0.episodeNumber < $1.episodeNumber }
        guard Set(regular.map(\.id)).count == sourceCount,
              regular.enumerated().allSatisfy({ index, episode in
                  episode.seasonNumber == sourceSeason.seasonNumber && episode.episodeNumber == index + 1
                      && RemoteMediaNumericBoundary.positiveIdentifier(episode.id) != nil
                      && validatedAirDateString(episode.airDate) != nil
              }), zip(regular, regular.dropFirst()).allSatisfy({ ($0.0.airDate ?? "") <= ($0.1.airDate ?? "") }),
              airDateOffset(startDate, regular.first?.airDate) == 0,
              let last = regular.last, let lastDate = validatedAirDateString(last.airDate),
              let arc = numberedEpisodeArc(last.name) else { return nil }
        let candidates = specialEpisodes.filter { episode in
            guard episode.seasonNumber == 0, let date = validatedAirDateString(episode.airDate),
                  date > lastDate, date <= endDate,
                  let next = numberedEpisodeArc(episode.name) else { return false }
            return next.title == arc.title && next.part > arc.part && next.part <= arc.part + count - sourceCount
        }.sorted { ($0.airDate ?? "") < ($1.airDate ?? "") }
        guard candidates.count == count - sourceCount,
              candidates.enumerated().allSatisfy({ index, episode in
                  numberedEpisodeArc(episode.name)?.part == arc.part + index + 1
                      && RemoteMediaNumericBoundary.positiveIdentifier(episode.id) != nil
                      && RemoteMediaNumericBoundary.episodeNumber(episode.episodeNumber) != nil
              }), candidates.last?.airDate == endDate,
              Set((regular + candidates).map(\.id)).count == count else { return nil }
        return regular + candidates
    }

    private static func numberedEpisodeArc(_ value: String) -> (title: String, part: Int)? {
        let pattern = #"^(.*?)\s*(?:\(([0-9]{1,2})\)|\bpart\s+([0-9]{1,2}))\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let titleRange = Range(match.range(at: 1), in: value) else { return nil }
        let title = normalizedCourTitle(String(value[titleRange]))
        let number = [2, 3].compactMap { index -> Int? in
            Range(match.range(at: index), in: value).flatMap { Int(value[$0]) }
        }.first
        guard title.count >= 4, let number, number > 0 else { return nil }
        return (title, number)
    }

    static func verifiedMappedEpisodeList(
        episodeCount: Int?, mediaFormat: String?, status: String?,
        providerStartDate: String?, providerEndDate: String?,
        sourceSeason: TMDBSeasonDetail, sourceEpisodeCount: Int,
        specialEpisodes: [TMDBEpisode], streamingEpisodeTitles: [String]
    ) -> [TMDBEpisode]? {
        guard ["TV", "TV_SHORT", "ONA"].contains(mediaFormat?.uppercased() ?? ""),
              ["FINISHED", "FINISHED_AIRING"].contains(status?.uppercased() ?? ""),
              let count = RemoteMediaNumericBoundary.episodeCount(episodeCount),
              count > sourceEpisodeCount, count - sourceEpisodeCount <= 8,
              streamingEpisodeTitles.count == count, sourceSeason.seasonNumber > 0,
              sourceSeason.episodes.count == sourceEpisodeCount,
              let start = validatedAirDateString(providerStartDate),
              let end = validatedAirDateString(providerEndDate), start <= end,
              let regex = try? NSRegularExpression(pattern: #"^Episode\s+([0-9]+)\s*[-–:]\s*(.+)$"#,
                options: [.caseInsensitive]) else { return nil }
        let titles = streamingEpisodeTitles.compactMap { title -> (Int, String)? in
            guard let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
                  let ordinalRange = Range(match.range(at: 1), in: title),
                  let nameRange = Range(match.range(at: 2), in: title),
                  let ordinal = Int(title[ordinalRange]), ordinal > 0 else { return nil }
            return (ordinal, normalizedEpisodeListTitle(String(title[nameRange])))
        }.sorted { $0.0 < $1.0 }
        guard titles.count == count, titles.enumerated().allSatisfy({ $0.element.0 == $0.offset + 1 }),
              Set(titles.map(\.1)).count == count else { return nil }
        let regular = sourceSeason.episodes.sorted { $0.episodeNumber < $1.episodeNumber }
        guard regular.enumerated().allSatisfy({ index, episode in
            episode.seasonNumber == sourceSeason.seasonNumber && episode.episodeNumber == index + 1
                && validatedAirDateString(episode.airDate) != nil
        }), regular.first?.airDate == start, regular.last?.airDate == end else { return nil }
        let supplemental = specialEpisodes.filter { episode in
            guard episode.seasonNumber == 0, let date = validatedAirDateString(episode.airDate) else { return false }
            return date >= start && date <= end
        }
        let rows = (regular + supplemental).sorted {
            if $0.airDate != $1.airDate { return ($0.airDate ?? "") < ($1.airDate ?? "") }
            if $0.seasonNumber != $1.seasonNumber { return $0.seasonNumber > $1.seasonNumber }
            return $0.episodeNumber < $1.episodeNumber
        }
        guard rows.count == count, Set(rows.map(\.id)).count == count,
              rows.allSatisfy({ RemoteMediaNumericBoundary.positiveIdentifier($0.id) != nil
                  && RemoteMediaNumericBoundary.episodeNumber($0.episodeNumber) != nil }),
              zip(rows, titles).allSatisfy({ normalizedEpisodeListTitle($0.0.name) == $0.1.1 }) else { return nil }
        return rows
    }

    private static func normalizedEpisodeListTitle(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
        var tokens = folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let numbers = ["one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
            "seven": "7", "eight": "8", "nine": "9", "ten": "10", "i": "1", "ii": "2", "iii": "3",
            "iv": "4", "v": "5", "vi": "6", "vii": "7", "viii": "8", "ix": "9", "x": "10"]
        if let last = tokens.last, let number = numbers[last] { tokens[tokens.count - 1] = number }
        if tokens.count > 1, tokens[tokens.count - 2] == "part", Int(tokens.last ?? "") != nil {
            tokens.remove(at: tokens.count - 2)
        }
        return tokens.joined()
    }

    static func hasExactCourTitle(_ candidate: AnimeStructureCourPlacementCandidate, sourceTitle: String) -> Bool {
        let target = normalizedCourTitle(sourceTitle)
        return !target.isEmpty && candidate.titles.contains { normalizedCourTitle($0) == target }
    }

    static func contradictedMappedSpecialIDs(
        candidates: [AnimeStructureCourPlacementCandidate], mappingsByID: [Int: AniMapMapping],
        tmdbShow: TMDBTVShowWithSeasons?
    ) -> Set<Int> {
        guard let tmdbShow else { return [] }
        return Set(candidates.compactMap { candidate -> Int? in
            guard let mapping = mappingsByID[candidate.id], mapping.tmdbShowId == tmdbShow.id,
                  ["SPECIAL", "OVA", "OAD", "MOVIE"].contains(mapping.mediaType?.uppercased() ?? ""),
                  let number = mapping.tmdbSeason, number > 0,
                  let season = tmdbShow.seasons.first(where: { $0.seasonNumber == number }),
                  let start = validatedAirDateString(season.airDate),
                  let end = validatedAirDateString(candidate.endDate), end < start,
                  let count = RemoteMediaNumericBoundary.episodeCount(candidate.episodeCount) else { return nil }
            let owners = candidates.filter { other in
                other.id != candidate.id && other.hasTrustedIdentity && other.startDate == start
                    && ["TV", "TV_SHORT", "ONA"].contains(other.format?.uppercased() ?? "")
                    && mappingsByID[other.id]?.tmdbShowId == tmdbShow.id
                    && hasExactCourTitle(other, sourceTitle: season.name)
                    && other.episodeCount.map { $0 > max(0, season.episodeCount - count) } == true
            }
            return owners.count == 1 ? candidate.id : nil
        })
    }

    static func ordinaryConnectedIDs(
        rootID: Int, candidateIDs: Set<Int>, constraints: [AnimeStructureRelationConstraint]
    ) -> Set<Int> {
        guard candidateIDs.contains(rootID) else { return [] }
        var retained: Set<Int> = [rootID]
        for _ in candidateIDs {
            let previous = retained
            for edge in constraints where candidateIDs.contains(edge.beforeID) && candidateIDs.contains(edge.afterID) {
                if retained.contains(edge.beforeID) { retained.insert(edge.afterID) }
                if retained.contains(edge.afterID) { retained.insert(edge.beforeID) }
            }
            if previous == retained { break }
        }
        return retained
    }

    static func verifiedContainedEpisodePlacements(
        candidates: [AnimeStructureCourPlacementCandidate],
        sourceSeasonEpisodeCounts: [Int: Int],
        sourceSeasonDetails: [Int: TMDBSeasonDetail],
        specialContinuationParentIDs: Set<Int>
    ) -> [Int: [TMDBEpisode]] {
        var result: [Int: [TMDBEpisode]] = [:]
        for candidate in candidates {
            let matches = sourceSeasonDetails.compactMap { season, detail -> [TMDBEpisode]? in
                guard let count = sourceSeasonEpisodeCounts[season],
                      detail.seasonNumber == season,
                      candidate.mappedTMDBSeason == season || hasExactCourTitle(candidate, sourceTitle: detail.name) else { return nil }
                let hasSpecial = specialContinuationParentIDs.contains(candidate.id)
                return verifiedContainedCourEpisodes(
                    episodeCount: candidate.episodeCount, mediaFormat: candidate.format, status: candidate.status,
                    providerStartDate: candidate.startDate, providerEndDate: candidate.endDate,
                    hasTrustedIdentity: candidate.hasTrustedIdentity,
                    permitsMeasuredOneDayOffset: hasSpecial || (hasExactCourTitle(candidate, sourceTitle: detail.name)
                        && candidate.episodeCount == count),
                    hasExplicitSpecialContinuation: hasSpecial,
                    sourceEpisodeCount: count, sourceEpisodes: detail.episodes,
                    allowsMappedFinishedTVPrefix: candidate.hasTrustedMappedIdentity && candidate.mappedTMDBSeason == season
                )
            }
            if matches.count == 1 { result[candidate.id] = matches[0] }
        }
        for candidate in candidates where result[candidate.id] == nil {
            let matches = sourceSeasonDetails.compactMap { season, source -> [TMDBEpisode]? in
                guard let target = sourceSeasonEpisodeCounts[season], candidate.episodeCount == target,
                      candidate.hasTrustedIdentity, hasExactCourTitle(candidate, sourceTitle: source.name),
                      ["FINISHED", "FINISHED_AIRING"].contains(candidate.status?.uppercased() ?? ""),
                      let nextSeason = sourceSeasonEpisodeCounts.keys.filter({ $0 > season }).min(),
                      let nextSource = sourceSeasonDetails[nextSeason],
                      let nextTarget = sourceSeasonEpisodeCounts[nextSeason] else { return nil }
                let successors = candidates.filter { next in
                    candidate.nextIDs.contains(next.id) && next.previousIDs.contains(candidate.id)
                        && next.hasTrustedIdentity && next.episodeCount == nextTarget
                        && ["FINISHED", "FINISHED_AIRING"].contains(next.status?.uppercased() ?? "")
                        && hasExactCourTitle(next, sourceTitle: nextSource.name)
                }
                guard successors.count == 1, let next = successors.first else { return nil }
                guard let start = validatedAirDateString(candidate.startDate),
                      let boundary = validatedAirDateString(next.startDate),
                      !candidates.contains(where: { other in
                          guard other.id != candidate.id, other.hasTrustedIdentity,
                                other.format == nil || ["TV", "TV_SHORT", "ONA"].contains(other.format?.uppercased() ?? ""),
                                let otherDate = validatedAirDateString(other.startDate),
                                otherDate >= start, otherDate < boundary else { return false }
                          return other.mappedTMDBSeason == season || hasExactCourTitle(other, sourceTitle: source.name)
                      }) else { return nil }
                return verifiedWholeCourWithSuccessor(candidate: candidate, successor: next,
                    sourceSeason: source, sourceEpisodeCount: target,
                    successorSourceSeason: nextSource, successorSourceEpisodeCount: nextTarget)
            }
            if matches.count == 1 { result[candidate.id] = matches[0] }
        }
        for (season, detail) in sourceSeasonDetails {
            guard let target = sourceSeasonEpisodeCounts[season] else { continue }
            let title = normalizedCourTitle(detail.name)
            let matching = candidates.filter { candidate in
                guard candidate.hasTrustedIdentity,
                      ["FINISHED", "FINISHED_AIRING"].contains(candidate.status?.uppercased() ?? ""),
                      let start = validatedAirDateString(candidate.startDate),
                      let end = validatedAirDateString(candidate.endDate),
                      let first = detail.episodes.compactMap({ validatedAirDateString($0.airDate) }).min(),
                      let last = detail.episodes.compactMap({ validatedAirDateString($0.airDate) }).max(),
                      start >= first, end <= last, title.count >= 8 else { return false }
                return candidate.titles.contains { normalizedCourTitle($0).hasPrefix(title) }
            }.sorted { ($0.startDate ?? "") < ($1.startDate ?? "") }
            guard matching.count > 1,
                  let total = RemoteMediaNumericBoundary.boundedSum(matching.compactMap(\.episodeCount)),
                  total == target, detail.episodes.count == target else { continue }
            guard zip(matching, matching.dropFirst()).allSatisfy({
                $0.0.nextIDs.contains($0.1.id) && $0.1.previousIDs.contains($0.0.id)
            }) else { continue }
            let rows = detail.episodes.sorted { $0.episodeNumber < $1.episodeNumber }
            guard Set(rows.map(\.id)).count == target,
                  rows.enumerated().allSatisfy({ index, episode in
                      episode.seasonNumber == season && episode.episodeNumber == index + 1
                          && RemoteMediaNumericBoundary.positiveIdentifier(episode.id) != nil
                          && validatedAirDateString(episode.airDate) != nil
                  }), zip(rows, rows.dropFirst()).allSatisfy({
                      ($0.0.airDate ?? "") <= ($0.1.airDate ?? "")
                  }) else { continue }
            var offset = 0
            var grouped: [Int: [TMDBEpisode]] = [:]
            for candidate in matching {
                guard ["TV", "TV_SHORT", "ONA"].contains(candidate.format?.uppercased() ?? ""),
                      let count = RemoteMediaNumericBoundary.episodeCount(candidate.episodeCount),
                      offset <= rows.count - count else { grouped.removeAll(); break }
                let episodes = Array(rows[offset..<(offset + count)])
                guard airDateOffset(candidate.startDate, episodes.first?.airDate) == 0 else { grouped.removeAll(); break }
                grouped[candidate.id] = episodes
                offset += count
            }
            if grouped.count == matching.count && offset == target {
                result.merge(grouped, uniquingKeysWith: { first, _ in first })
            }
        }
        var owners: [Int: Set<Int>] = [:]
        for (id, rows) in result {
            for episode in rows { owners[episode.id, default: []].insert(id) }
        }
        let conflicting = Set(owners.values.filter { $0.count > 1 }.flatMap { $0 })
        return result.filter { !conflicting.contains($0.key) }
    }

    static func verifiedWholeCourWithSuccessor(
        candidate: AnimeStructureCourPlacementCandidate, successor: AnimeStructureCourPlacementCandidate,
        sourceSeason: TMDBSeasonDetail, sourceEpisodeCount: Int,
        successorSourceSeason: TMDBSeasonDetail, successorSourceEpisodeCount: Int
    ) -> [TMDBEpisode]? {
        guard candidate.hasTrustedIdentity, successor.hasTrustedIdentity,
              candidate.nextIDs.contains(successor.id), successor.previousIDs.contains(candidate.id),
              sourceSeason.seasonNumber > 0, successorSourceSeason.seasonNumber > sourceSeason.seasonNumber,
              hasExactCourTitle(candidate, sourceTitle: sourceSeason.name),
              hasExactCourTitle(successor, sourceTitle: successorSourceSeason.name),
              [candidate, successor].allSatisfy({ ["TV", "TV_SHORT", "ONA"].contains($0.format?.uppercased() ?? "")
                  && ["FINISHED", "FINISHED_AIRING"].contains($0.status?.uppercased() ?? "") }),
              candidate.episodeCount == sourceEpisodeCount, successor.episodeCount == successorSourceEpisodeCount,
              let first = validatedAirDateString(candidate.startDate),
              let next = validatedAirDateString(successor.startDate), first < next else { return nil }
        func verifiedRows(_ source: TMDBSeasonDetail, count: Int, start: String) -> [TMDBEpisode]? {
            guard RemoteMediaNumericBoundary.episodeCount(count) != nil, source.episodes.count == count else { return nil }
            let rows = source.episodes.sorted { $0.episodeNumber < $1.episodeNumber }
            guard rows.first?.airDate == start, Set(rows.map(\.id)).count == count,
                  rows.enumerated().allSatisfy({ index, episode in
                      episode.seasonNumber == source.seasonNumber && episode.episodeNumber == index + 1
                          && RemoteMediaNumericBoundary.positiveIdentifier(episode.id) != nil
                          && validatedAirDateString(episode.airDate).map { $0 >= start } == true
                  }), zip(rows, rows.dropFirst()).allSatisfy({ ($0.0.airDate ?? "") <= ($0.1.airDate ?? "") }) else { return nil }
            return rows
        }
        guard let rows = verifiedRows(sourceSeason, count: sourceEpisodeCount, start: first),
              let following = verifiedRows(successorSourceSeason, count: successorSourceEpisodeCount, start: next),
              rows.allSatisfy({ ($0.airDate ?? "") < next }),
              Set((rows + following).map(\.id)).count == rows.count + following.count else { return nil }
        return rows
    }

    static func fetchCourSeasonDetails(
        candidates: [AnimeStructureCourPlacementCandidate],
        tmdbShow: TMDBTVShowWithSeasons?,
        tmdbService: TMDBService
    ) async -> [Int: TMDBSeasonDetail] {
        guard let tmdbShow else { return [:] }
        let seasons = tmdbShow.seasons.filter { season in
            season.seasonNumber > 0 && season.episodeCount > 0 && candidates.contains { candidate in
                candidate.hasTrustedIdentity && candidate.startDate != nil && candidate.endDate != nil
                    && ["FINISHED", "FINISHED_AIRING"].contains(candidate.status?.uppercased() ?? "")
                    && candidate.episodeCount.map { $0 > 0 && $0 <= season.episodeCount } == true
                    && (candidate.mappedTMDBSeason == season.seasonNumber
                        || hasExactCourTitle(candidate, sourceTitle: season.name)
                        || (normalizedCourTitle(season.name).count >= 8 && candidate.titles.contains {
                            normalizedCourTitle($0).hasPrefix(normalizedCourTitle(season.name))
                        }))
            }
        }
        return await withTaskGroup(of: (Int, TMDBSeasonDetail?).self) { group in
            for season in seasons {
                group.addTask {
                    guard !Task.isCancelled else { return (season.seasonNumber, nil) }
                    return (season.seasonNumber, try? await tmdbService.getSeasonDetails(
                        tvShowId: tmdbShow.id, seasonNumber: season.seasonNumber))
                }
            }
            var result: [Int: TMDBSeasonDetail] = [:]
            for await (season, detail) in group {
                if Task.isCancelled { group.cancelAll(); break }
                if let detail { result[season] = detail }
            }
            return result
        }
    }

    static func nonConflictingEpisodePlacements(_ placements: [Int: [TMDBEpisode]]) -> [Int: [TMDBEpisode]] {
        var invalid = Set<Int>()
        var identityOwners: [Int: Set<Int>] = [:]
        var coordinateOwners: [String: Set<Int>] = [:]
        for (owner, rows) in placements {
            var identities = Set<Int>()
            var coordinates = Set<String>()
            for row in rows {
                let coordinate = "\(row.seasonNumber):\(row.episodeNumber)"
                guard RemoteMediaNumericBoundary.positiveIdentifier(row.id) != nil,
                      RemoteMediaNumericBoundary.seasonNumber(row.seasonNumber, allowsZero: true) != nil,
                      RemoteMediaNumericBoundary.episodeNumber(row.episodeNumber) != nil,
                      identities.insert(row.id).inserted, coordinates.insert(coordinate).inserted else {
                    invalid.insert(owner)
                    continue
                }
                identityOwners[row.id, default: []].insert(owner)
                coordinateOwners[coordinate, default: []].insert(owner)
            }
        }
        for owners in Array(identityOwners.values) + Array(coordinateOwners.values) where owners.count > 1 {
            invalid.formUnion(owners)
        }
        return placements.filter { !invalid.contains($0.key) }
    }

    static func validatedAirDateString(_ value: String?) -> String? {
        guard let value, value.count == 10 else { return nil }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              RemoteMediaNumericBoundary.year(year) != nil else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let normalized = calendar.dateComponents([.year, .month, .day], from: date)
        guard normalized.year == year, normalized.month == month, normalized.day == day else { return nil }
        return value
    }

    private static func airDateOffset(_ provider: String?, _ source: String?) -> Int? {
        guard let provider = validatedAirDateString(provider), let source = validatedAirDateString(source) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        func date(_ value: String) -> Date? {
            let parts = value.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
        guard let start = date(provider), let end = date(source) else { return nil }
        return calendar.dateComponents([.day], from: start, to: end).day
    }

    static func mappedPrologueCandidateIndex(
        tmdbSeasonEpisodeCounts: [Int: Int],
        segments: [AnimeStructureCoverageSegment],
        statuses: [String?],
        providerStartDates: [String?],
        sourceEpisodes: [TMDBEpisode]
    ) -> Int? {
        guard !segments.isEmpty, statuses.count == segments.count, providerStartDates.count == segments.count,
              statuses.allSatisfy({ ["FINISHED", "FINISHED_AIRING"].contains($0?.uppercased() ?? "") }),
              segments.allSatisfy({ $0.mappedTMDBSeason.flatMap { tmdbSeasonEpisodeCounts[$0] } != nil
                && RemoteMediaNumericBoundary.episodeCount($0.episodeCount) != nil }),
              let declared = RemoteMediaNumericBoundary.boundedSum(segments.compactMap(\.episodeCount)),
              let actual = RemoteMediaNumericBoundary.boundedSum(tmdbSeasonEpisodeCounts.values),
              declared == actual + 1, sourceEpisodes.count == actual else { return nil }
        let source = Dictionary(grouping: sourceEpisodes, by: \.seasonNumber)
        guard Set(source.keys) == Set(tmdbSeasonEpisodeCounts.keys),
              source.allSatisfy({ season, rows in
                  rows.count == tmdbSeasonEpisodeCounts[season]
                      && Set(rows.map(\.id)).count == rows.count
                      && rows.sorted(by: { $0.episodeNumber < $1.episodeNumber }).enumerated().allSatisfy {
                          $0.element.episodeNumber == $0.offset + 1
                              && RemoteMediaNumericBoundary.positiveIdentifier($0.element.id) != nil
                      }
              }) else { return nil }
        var differences: [Int: Int] = [:]
        for (season, target) in tmdbSeasonEpisodeCounts {
            let counts = segments.filter { $0.mappedTMDBSeason == season }.compactMap(\.episodeCount)
            guard let count = RemoteMediaNumericBoundary.boundedSum(counts) else { return nil }
            differences[season] = count - target
        }
        let missing = differences.filter { $0.value != 0 }
        guard missing.count == 1, let deficit = missing.first, deficit.value == 1,
              let rows = source[deficit.key]?.sorted(by: { $0.episodeNumber < $1.episodeNumber }) else { return nil }
        let group = segments.indices.filter { segments[$0].mappedTMDBSeason == deficit.key }
        guard let first = group.first, let last = group.last, group.count == last - first + 1,
              let date = validatedAirDateString(providerStartDates[first]),
              let sourceDate = validatedAirDateString(rows.first?.airDate),
              let offset = airDateOffset(date, sourceDate), (1...14).contains(offset) else { return nil }
        var position = 0
        for index in group {
            if index != first {
                guard rows.indices.contains(position - 1),
                      validatedAirDateString(rows[position - 1].airDate)
                        == validatedAirDateString(providerStartDates[index]),
                      validatedAirDateString(providerStartDates[index]) != nil else { return nil }
            }
            position += segments[index].episodeCount ?? 0
        }
        return first
    }

    static func inventoryByAddingMappedPrologue(
        tmdbSeasonEpisodeCounts: [Int: Int],
        segments: [AnimeStructureCoverageSegment],
        statuses: [String?],
        providerStartDates: [String?],
        sourceEpisodes: [TMDBEpisode],
        specialEpisodes: [TMDBEpisode]
    ) -> (episodes: [Int: TMDBEpisode], coordinates: [Int: AnimeStructureTMDBCoordinate], seasonCounts: [Int: Int])? {
        guard let index = mappedPrologueCandidateIndex(
            tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts, segments: segments,
            statuses: statuses, providerStartDates: providerStartDates, sourceEpisodes: sourceEpisodes
        ), let season = segments[index].mappedTMDBSeason,
           let date = validatedAirDateString(providerStartDates[index]) else { return nil }
        let matches = specialEpisodes.filter {
            $0.seasonNumber == 0 && validatedAirDateString($0.airDate) == date
        }
        guard matches.count == 1, let prologue = matches.first,
              RemoteMediaNumericBoundary.positiveIdentifier(prologue.id) != nil,
              RemoteMediaNumericBoundary.episodeNumber(prologue.episodeNumber) != nil,
              !sourceEpisodes.contains(where: { $0.id == prologue.id }) else { return nil }
        return inventoryByInsertingEpisode(prologue, beforeSeason: season,
            tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts, sourceEpisodes: sourceEpisodes)
    }

    static func inventoryByInsertingEpisode(
        _ prologue: TMDBEpisode,
        beforeSeason season: Int,
        tmdbSeasonEpisodeCounts: [Int: Int],
        sourceEpisodes: [TMDBEpisode]
    ) -> (episodes: [Int: TMDBEpisode], coordinates: [Int: AnimeStructureTMDBCoordinate], seasonCounts: [Int: Int])? {
        guard tmdbSeasonEpisodeCounts[season] != nil, prologue.seasonNumber == 0,
              RemoteMediaNumericBoundary.positiveIdentifier(prologue.id) != nil,
              !sourceEpisodes.contains(where: { $0.id == prologue.id }),
              let total = RemoteMediaNumericBoundary.boundedSum(tmdbSeasonEpisodeCounts.values),
              sourceEpisodes.count == total, Set(sourceEpisodes.map(\.id)).count == total else { return nil }
        let source = Dictionary(grouping: sourceEpisodes, by: \.seasonNumber)
        guard Set(source.keys) == Set(tmdbSeasonEpisodeCounts.keys), source.allSatisfy({ key, rows in
            rows.count == tmdbSeasonEpisodeCounts[key]
                && rows.sorted(by: { $0.episodeNumber < $1.episodeNumber }).enumerated().allSatisfy {
                    $0.element.episodeNumber == $0.offset + 1
                        && RemoteMediaNumericBoundary.positiveIdentifier($0.element.id) != nil
                }
        }) else { return nil }
        var episodes: [Int: TMDBEpisode] = [:]
        var coordinates: [Int: AnimeStructureTMDBCoordinate] = [:]
        var counts = tmdbSeasonEpisodeCounts
        counts[season, default: 0] += 1
        var absolute = 1
        for key in tmdbSeasonEpisodeCounts.keys.sorted() {
            let ordered = (source[key] ?? []).sorted { $0.episodeNumber < $1.episodeNumber }
            for episode in (key == season ? [prologue] + ordered : ordered) {
                episodes[absolute] = episode
                coordinates[absolute] = .init(seasonNumber: episode.seasonNumber, episodeNumber: episode.episodeNumber)
                absolute += 1
            }
        }
        return (episodes, coordinates, counts)
    }

    static func requiresVerifiedAbsoluteOrderInventory(tvdbSeasons: [Int?], tmdbSeasonCount: Int) -> Bool {
        tmdbSeasonCount > 1 && tvdbSeasons.contains(-1)
    }

    static func requiresVerifiedOpenEndedInventory(
        mediaFormat: String?, status: String?, episodeCount: Int?, entryCount: Int, tmdbSeasonCount: Int
    ) -> Bool {
        entryCount == 1 && tmdbSeasonCount > 1 && episodeCount == nil
            && mediaFormat?.uppercased() == "TV"
            && ["RELEASING", "CURRENTLY_AIRING"].contains(status?.uppercased() ?? "")
    }

    static func verifiedOpenEndedTMDBInventory(
        hasExclusiveOrdinaryOwner: Bool, providerStartDate: String?,
        tmdbSeasonEpisodeCounts: [Int: Int], sourceEpisodes: [TMDBEpisode]
    ) -> [TMDBEpisode]? {
        guard hasExclusiveOrdinaryOwner, let start = validatedAirDateString(providerStartDate),
              (2...64).contains(tmdbSeasonEpisodeCounts.count),
              tmdbSeasonEpisodeCounts.allSatisfy({ RemoteMediaNumericBoundary.seasonNumber($0.key) != nil
                && RemoteMediaNumericBoundary.episodeCount($0.value) != nil }),
              let total = RemoteMediaNumericBoundary.boundedSum(tmdbSeasonEpisodeCounts.values),
              sourceEpisodes.count == total, Set(sourceEpisodes.map(\.id)).count == total,
              Set(sourceEpisodes.map { "\($0.seasonNumber):\($0.episodeNumber)" }).count == total,
              sourceEpisodes.allSatisfy({ RemoteMediaNumericBoundary.positiveIdentifier($0.id) != nil
                && RemoteMediaNumericBoundary.episodeNumber($0.episodeNumber) != nil
                && tmdbSeasonEpisodeCounts[$0.seasonNumber] != nil && validatedAirDateString($0.airDate) != nil }) else { return nil }
        for (season, count) in tmdbSeasonEpisodeCounts {
            guard sourceEpisodes.filter({ $0.seasonNumber == season }).count == count else { return nil }
        }
        let rows = sourceEpisodes.sorted {
            $0.seasonNumber == $1.seasonNumber ? $0.episodeNumber < $1.episodeNumber : $0.seasonNumber < $1.seasonNumber
        }
        guard rows.first?.airDate == start,
              zip(rows, rows.dropFirst()).allSatisfy({ ($0.0.airDate ?? "") <= ($0.1.airDate ?? "") }) else { return nil }
        return rows
    }

    static func allowsLinearTMDBCoordinates(
        hydrationPolicy: AnimeEpisodeHydrationPolicy,
        tmdbSeasonEpisodeCounts: [Int: Int],
        segments: [AnimeStructureCoverageSegment],
        statuses: [String?]
    ) -> Bool {
        guard !segments.isEmpty, segments.count == statuses.count else { return false }
        let upcoming = statuses.map {
            ["NOT_YET_RELEASED", "NOT_YET_AIRED"].contains($0?.uppercased() ?? "")
        }
        let activeEnd = upcoming.firstIndex(of: true) ?? segments.endIndex
        guard activeEnd > 0, upcoming[activeEnd...].allSatisfy({ $0 }) else { return false }
        let activeSegments = Array(segments.prefix(activeEnd))
        return [segments, activeSegments].contains { candidate in
            candidate.allSatisfy { RemoteMediaNumericBoundary.episodeCount($0.episodeCount) != nil }
                && allowsLinearTMDBCoordinates(
                    hydrationPolicy: hydrationPolicy,
                    hasExactCoverage: hasExactCoverage(
                        tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                        segments: candidate
                    ),
                    hasMatchingEpisodeTotals: hasMatchingEpisodeTotals(
                        tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                        segments: candidate
                    )
                )
        }
    }

    static func hasMatchingEpisodeTotals(
        tmdbSeasonEpisodeCounts: [Int: Int],
        segments: [AnimeStructureCoverageSegment]
    ) -> Bool {
        guard tmdbSeasonEpisodeCounts.allSatisfy({ season, count in
            RemoteMediaNumericBoundary.seasonNumber(season, allowsZero: true) != nil
                && RemoteMediaNumericBoundary.episodeCount(count) != nil
        }) else { return false }
        guard let expectedTotal = RemoteMediaNumericBoundary.boundedSum(
            tmdbSeasonEpisodeCounts
                .filter { $0.key > 0 }
                .values
        ) else { return false }
        guard expectedTotal > 0, !segments.isEmpty else { return false }

        guard segments.allSatisfy({
            RemoteMediaNumericBoundary.episodeCount($0.episodeCount) != nil
        }), let structureTotal = RemoteMediaNumericBoundary.boundedSum(
            segments.compactMap(\.episodeCount)
        ) else { return false }
        return structureTotal == expectedTotal
    }

    static func resolvingSingleUnknownMappedSeasonCounts(
        tmdbSeasonEpisodeCounts: [Int: Int],
        segments: [AnimeStructureCoverageSegment]
    ) -> [AnimeStructureCoverageSegment] {
        let expected = tmdbSeasonEpisodeCounts.filter { $0.key > 0 }
        guard !expected.isEmpty,
              expected.allSatisfy({ season, count in
                  RemoteMediaNumericBoundary.seasonNumber(season) != nil
                      && RemoteMediaNumericBoundary.episodeCount(count) != nil
              }),
              !segments.isEmpty,
              segments.allSatisfy({ segment in
                  guard let season = segment.mappedTMDBSeason else { return false }
                  return expected[season] != nil
                      && (segment.episodeCount.map({
                          RemoteMediaNumericBoundary.episodeCount($0) != nil
                      }) ?? true)
              }) else {
            return segments
        }

        var resolved = segments
        for (season, target) in expected {
            let indices = resolved.indices.filter {
                resolved[$0].mappedTMDBSeason == season
            }
            guard !indices.isEmpty else { continue }
            let unknownIndices = indices.filter {
                resolved[$0].episodeCount == nil
            }
            guard unknownIndices.count == 1,
                  let unknownIndex = unknownIndices.first,
                  let knownTotal = RemoteMediaNumericBoundary.boundedSum(
                      indices.compactMap { resolved[$0].episodeCount }
                  ),
                  let remainder = RemoteMediaNumericBoundary.adding(target, -knownTotal),
                  let episodeCount = RemoteMediaNumericBoundary.episodeCount(remainder) else {
                continue
            }
            resolved[unknownIndex] = AnimeStructureCoverageSegment(
                mappedTMDBSeason: season,
                episodeCount: episodeCount
            )
        }
        return resolved
    }

    static func reconcilingReleasingTailCount(
        tmdbSeasonEpisodeCounts: [Int: Int],
        segments: [AnimeStructureCoverageSegment],
        terminalStatus: String?
    ) -> [AnimeStructureCoverageSegment] {
        guard let normalizedStatus = terminalStatus?.uppercased(),
              ["RELEASING", "NOT_YET_RELEASED"].contains(normalizedStatus),
              segments.count > 1,
              let terminalIndex = segments.indices.last,
              let terminalCount = RemoteMediaNumericBoundary.episodeCount(
                segments[terminalIndex].episodeCount
              ) else {
            return segments
        }

        let expected = tmdbSeasonEpisodeCounts.filter { $0.key > 0 }
        let orderedExpectedSeasons = expected.keys.sorted()
        guard orderedExpectedSeasons.count > 1,
              expected.allSatisfy({ season, count in
                  RemoteMediaNumericBoundary.seasonNumber(season) != nil
                      && RemoteMediaNumericBoundary.episodeCount(count) != nil
              }),
              let terminalSeason = orderedExpectedSeasons.last,
              let expectedTerminalCount = expected[terminalSeason],
              terminalCount > expectedTerminalCount,
              segments[terminalIndex].mappedTMDBSeason.map({ $0 == terminalSeason }) ?? true else {
            return segments
        }

        var prefixCounts: [Int: Int] = [:]
        for segment in segments.dropLast() {
            guard let season = segment.mappedTMDBSeason,
                  let count = RemoteMediaNumericBoundary.episodeCount(segment.episodeCount),
                  expected[season] != nil,
                  let updated = RemoteMediaNumericBoundary.adding(
                    prefixCounts[season, default: 0],
                    count
                  ) else {
                return segments
            }
            prefixCounts[season] = updated
        }

        let expectedPrefixSeasons = Array(orderedExpectedSeasons.dropLast())
        guard prefixCounts.keys.sorted() == expectedPrefixSeasons,
              expectedPrefixSeasons.allSatisfy({ prefixCounts[$0] == expected[$0] }) else {
            return segments
        }

        var reconciled = segments
        reconciled[terminalIndex] = AnimeStructureCoverageSegment(
            mappedTMDBSeason: segments[terminalIndex].mappedTMDBSeason,
            episodeCount: expectedTerminalCount
        )
        return reconciled
    }

    static func admitsUpcomingContinuation(
        relationType: String,
        mediaFormat: String?,
        status: String?,
        tmdbSeasonEpisodeCounts: [Int: Int],
        currentSegments: [AnimeStructureCoverageSegment],
        continuationSegment: AnimeStructureCoverageSegment
    ) -> Bool {
        let normalizedRelationType = relationType.uppercased()
        guard status?.uppercased() == "NOT_YET_RELEASED",
              ["SEQUEL", "SEASON"].contains(normalizedRelationType),
              AnimeRelationRolePolicy.isRegularContinuationCandidate(
                relationType: normalizedRelationType,
                mediaFormat: mediaFormat
              ) else {
            return false
        }

        let expected = tmdbSeasonEpisodeCounts.filter { $0.key > 0 }
        let orderedExpectedSeasons = expected.keys.sorted()
        guard orderedExpectedSeasons.count > 1,
              expected.allSatisfy({ season, count in
                  RemoteMediaNumericBoundary.seasonNumber(season) != nil
                      && RemoteMediaNumericBoundary.episodeCount(count) != nil
              }),
              let terminalSeason = orderedExpectedSeasons.last,
              let expectedTerminalCount = expected[terminalSeason],
              continuationSegment.mappedTMDBSeason.map({ $0 == terminalSeason }) ?? true,
              let continuationCount = RemoteMediaNumericBoundary.episodeCount(
                continuationSegment.episodeCount
              ) else {
            return false
        }

        var currentCounts: [Int: Int] = [:]
        for segment in currentSegments {
            guard let season = segment.mappedTMDBSeason,
                  expected[season] != nil,
                  let count = RemoteMediaNumericBoundary.episodeCount(segment.episodeCount),
                  let updated = RemoteMediaNumericBoundary.adding(
                    currentCounts[season, default: 0],
                    count
                  ) else {
                return false
            }
            currentCounts[season] = updated
        }

        guard currentCounts.keys.sorted() == orderedExpectedSeasons,
              orderedExpectedSeasons.dropLast().allSatisfy({
                  currentCounts[$0] == expected[$0]
              }),
              let currentTerminalCount = currentCounts[terminalSeason],
              currentTerminalCount > 0,
              currentTerminalCount < expectedTerminalCount,
              let completedTerminalCount = RemoteMediaNumericBoundary.adding(
                currentTerminalCount,
                continuationCount
              ) else {
            return false
        }
        return completedTerminalCount == expectedTerminalCount
    }

    static func canUseShallowTerminalContinuation(
        hydrationPolicy: AnimeEpisodeHydrationPolicy,
        relationType: String,
        mediaFormat: String?,
        tmdbSeasonEpisodeCounts: [Int: Int],
        currentSegments: [AnimeStructureCoverageSegment],
        continuationSegment: AnimeStructureCoverageSegment,
        continuationStatus: String?
    ) -> Bool {
        guard hydrationPolicy == .initiallyVisible else { return false }
        if continuationStatus?.uppercased() == "NOT_YET_RELEASED" {
            return admitsUpcomingContinuation(
                relationType: relationType,
                mediaFormat: mediaFormat,
                status: continuationStatus,
                tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                currentSegments: currentSegments,
                continuationSegment: continuationSegment
            )
        }
        let prospective = currentSegments + [continuationSegment]
        let reconciled = reconcilingReleasingTailCount(
            tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
            segments: prospective,
            terminalStatus: continuationStatus
        )
        return reconciled != prospective && hasMatchingEpisodeTotals(
            tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
            segments: reconciled
        )
    }

    static func hasCompatibleMappedOrder(
        _ segments: [AnimeStructureMappedOrderSegment],
        expectedTMDBSeasonCount: Int
    ) -> Bool {
        guard (0...RemoteMediaNumericBoundary.maximumSeasonNumber)
            .contains(expectedTMDBSeasonCount),
              segments.count <= RemoteMediaNumericBoundary.maximumRelationCount else {
            return false
        }
        guard segments.count > 1 else { return true }
        guard segments.allSatisfy({ segment in
            (segment.mappedTMDBSeason.map({
                RemoteMediaNumericBoundary.seasonNumber($0) != nil
            }) ?? true)
                && (segment.mappedTVDBSeason.map({
                    $0 == -1 || RemoteMediaNumericBoundary.seasonNumber($0) != nil
                }) ?? true)
                && (segment.tvdbEpisodeOffset.map({
                    RemoteMediaNumericBoundary.signedEpisodeOffset($0) != nil
                }) ?? true)
                && (segment.episodeCount.map({
                    RemoteMediaNumericBoundary.episodeCount($0) != nil
                }) ?? true)
        }) else { return false }
        if expectedTMDBSeasonCount > 1 {
            let tmdbSeasons = segments.compactMap { segment in
                segment.mappedTMDBSeason.flatMap { $0 > 0 ? $0 : nil }
            }
            guard tmdbSeasons.count == segments.count else { return false }
            for index in 1..<tmdbSeasons.count where tmdbSeasons[index] < tmdbSeasons[index - 1] {
                return false
            }
        }

        let groupedIndexes = Dictionary(grouping: segments.indices) { index in
            expectedTMDBSeasonCount > 1 ? (segments[index].mappedTMDBSeason ?? Int.min) : 1
        }
        for indexes in groupedIndexes.values where indexes.count > 1 {
            let orderedIndexes = indexes.sorted()

            guard let firstOffset = segments[orderedIndexes[0]].tvdbEpisodeOffset,
                  firstOffset <= 0 else {
                return false
            }
            let tvdbSeasons = orderedIndexes.compactMap { index in
                segments[index].mappedTVDBSeason.flatMap { $0 > 0 ? $0 : nil }
            }
            guard tvdbSeasons.count == orderedIndexes.count else { return false }
            for offset in 1..<orderedIndexes.count {
                let previousIndex = orderedIndexes[offset - 1]
                let currentIndex = orderedIndexes[offset]
                let previousSeason = tvdbSeasons[offset - 1]
                let currentSeason = tvdbSeasons[offset]
                guard currentSeason >= previousSeason else { return false }
                if currentSeason == previousSeason {
                    guard let previousOffset = segments[previousIndex].tvdbEpisodeOffset,
                          let currentOffset = segments[currentIndex].tvdbEpisodeOffset,
                          let previousCount = RemoteMediaNumericBoundary.episodeCount(
                            segments[previousIndex].episodeCount
                          ),
                          let expectedOffset = RemoteMediaNumericBoundary.adding(
                            previousOffset,
                            previousCount
                          ),
                          currentOffset == expectedOffset else {
                        return false
                    }
                }
            }
        }
        return true
    }

    static func allowsSingleOpenEndedSeries(
        status: String?,
        episodeCount: Int?,
        mappedTMDBSeason: Int?,
        tmdbSeasonEpisodeCounts: [Int: Int]
    ) -> Bool {
        guard tmdbSeasonEpisodeCounts.allSatisfy({ season, count in
            RemoteMediaNumericBoundary.seasonNumber(season, allowsZero: true) != nil
                && RemoteMediaNumericBoundary.episodeCount(count) != nil
        }) else { return false }
        return status?.uppercased() == "RELEASING"
            && episodeCount == nil
            && mappedTMDBSeason == nil
            && tmdbSeasonEpisodeCounts.contains { $0.key > 0 && $0.value > 0 }
    }

    private static func isOrderedBefore(
        _ lhs: AnimeStructureOrderingCandidate,
        _ rhs: AnimeStructureOrderingCandidate
    ) -> Bool {

        let lhsYear = lhs.startYear ?? lhs.seasonYear ?? Int.max
        let rhsYear = rhs.startYear ?? rhs.seasonYear ?? Int.max
        if lhsYear != rhsYear { return lhsYear < rhsYear }
        let lhsMonth = lhs.startMonth ?? ((0...3).contains(lhs.seasonOrdinal) ? lhs.seasonOrdinal * 3 + 1 : 13)
        let rhsMonth = rhs.startMonth ?? ((0...3).contains(rhs.seasonOrdinal) ? rhs.seasonOrdinal * 3 + 1 : 13)
        if lhsMonth != rhsMonth { return lhsMonth < rhsMonth }
        let lhsDay = lhs.startDay ?? 32
        let rhsDay = rhs.startDay ?? 32
        if lhsDay != rhsDay { return lhsDay < rhsDay }
        return lhs.anilistId < rhs.anilistId
    }
}

enum AnimeFallbackStatusPolicy {
    static func aggregateStatus(
        statuses: [String?],
        rootStatus: String?
    ) -> String {
        let normalized = statuses.compactMap { status -> String? in
            let value = status?.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            return value.isEmpty ? nil : value
        }
        if normalized.contains("currently_airing") || normalized.contains("releasing") {
            return "RELEASING"
        }
        if normalized.contains("not_yet_aired") || normalized.contains("not_yet_released") {
            return "NOT_YET_RELEASED"
        }

        switch rootStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "currently_airing", "releasing": return "RELEASING"
        case "not_yet_aired", "not_yet_released": return "NOT_YET_RELEASED"
        case "finished_airing", "finished": return "FINISHED"
        case let value?: return value.uppercased()
        case nil: return "UNKNOWN"
        }
    }
}

private actor AniListShallowSnapshotCache {
    static let shared = AniListShallowSnapshotCache()

    private struct Entry {
        let node: AniListAnime
        let expiresAt: Date
    }

    private var entries: [Int: Entry] = [:]

    func nodes(for ids: [Int]) -> [Int: AniListAnime] {
        guard animeMetadataCacheReadsAllowed else { return [:] }
        let now = Date()
        var result: [Int: AniListAnime] = [:]
        for id in ids {
            guard let entry = entries[id] else { continue }
            guard entry.expiresAt > now else {
                entries[id] = nil
                continue
            }
            result[id] = entry.node
        }
        return result
    }

    func store(_ nodes: [Int: AniListAnime]) {
        guard animeMetadataCacheReadsAllowed else { return }
        let now = Date()
        for (id, node) in nodes {
            let ttl: TimeInterval
            switch node.status?.uppercased() {
            case "NOT_YET_RELEASED": ttl = 30 * 60
            case "RELEASING": ttl = 2 * 60 * 60
            default: ttl = 6 * 60 * 60
            }
            entries[id] = Entry(node: node, expiresAt: now.addingTimeInterval(ttl))
        }
        if entries.count > 256 {
            entries = entries.filter { $0.value.expiresAt > now }
            if entries.count > 256 {
                let overflow = entries.count - 256
                let oldestKeys = entries
                    .sorted { $0.value.expiresAt < $1.value.expiresAt }
                    .prefix(overflow)
                    .map(\.key)
                for key in oldestKeys {
                    entries[key] = nil
                }
            }
        }
    }
}

final class AniListService {
    static let shared = AniListService()

    private let graphQLEndpoint = URL(string: "https://graphql.anilist.co")!
    private var preferredLanguageCode: String {
        let raw = ProfileSettingsStore.active.string(forKey: "tmdbLanguage") ?? "en-US"
        return raw.split(separator: "-").first.map(String.init) ?? "en"
    }
    private var tmdbMatchCacheLanguage: String {
        ProfileSettingsStore.active.string(forKey: "tmdbLanguage") ?? "en-US"
    }

    private let animeDetailsCache = NSCache<NSString, AniListAnimeWithSeasonsWrapper>()
    private let shallowSnapshotCache = AniListShallowSnapshotCache.shared
    private let animeCacheTTL: TimeInterval = 300

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

    private init() {

        animeDetailsCache.countLimit = 8
        animeDetailsCache.totalCostLimit = 4_000
        specialEntriesCache.countLimit = 16
        specialEntriesCache.totalCostLimit = 1_000

#if canImport(UIKit) && !os(watchOS)

        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task(priority: .utility) {
                await AniMapMappingService.shared.reduceMemoryFootprint()
            }
        }
#endif
    }

    private func cacheAnimeDetails(
        _ value: AniListAnimeWithSeasons,
        forKey key: NSString
    ) {
        guard animeMetadataCacheReadsAllowed else { return }
        let cost = AnimeEpisodeGraphCachePolicy.episodeCost(of: value)
        animeDetailsCache.setObject(
            AniListAnimeWithSeasonsWrapper(value),
            forKey: key,
            cost: cost
        )
    }

    private func cacheSpecialEntries(
        _ entries: [AniListSpecialSearchEntry],
        forKey key: NSString
    ) {
        guard animeMetadataCacheReadsAllowed else { return }
        let episodeCost = RemoteMediaNumericBoundary.saturatingNonnegativeSum(
            entries.map { max($0.episodeCount, $0.episodes.count) }
        )
        let entryCost = RemoteMediaNumericBoundary.saturatingNonnegativeProduct(
            entries.count,
            4
        )
        let cost = max(
            1,
            RemoteMediaNumericBoundary.saturatingNonnegativeSum([episodeCost, entryCost])
        )
        specialEntriesCache.setObject(
            SpecialEntriesCacheWrapper(entries: entries),
            forKey: key,
            cost: cost
        )
    }

    enum AniListCatalogKind: CaseIterable, Hashable {
        case trending
        case popular
        case topRated
        case airing

        fileprivate var queryAlias: String {
            switch self {
            case .trending: return "trending"
            case .popular: return "popular"
            case .topRated: return "topRated"
            case .airing: return "airing"
            }
        }

        fileprivate var querySort: String {
            switch self {
            case .trending: return "TRENDING_DESC"
            case .popular, .airing: return "POPULARITY_DESC"
            case .topRated: return "SCORE_DESC"
            }
        }

        fileprivate var queryStatus: String? {
            switch self {
            case .airing: return "RELEASING"
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
                            idMal
                            externalLinks { site siteId url }
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

    func fetchAnimeCatalogs(
        kinds: Set<AniListCatalogKind>,
        limit: Int = 20,
        tmdbService: TMDBService
    ) async throws -> [AniListCatalogKind: [TMDBSearchResult]] {
        guard !kinds.isEmpty else { return [:] }

        Task(priority: .utility) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await AniMapMappingService.shared.prepareGlobalIndexIfNeeded()
        }

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
        }

        let statusClause = status.map { ", status: \($0)" } ?? ""

        let query = """
        query {
            Page(\(pageRequest.graphQLArguments)) {
                media(type: ANIME, sort: [\(sort)]\(statusClause)) {
                    id
                    idMal
                    externalLinks { site siteId url }
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

    func fetchAiringSchedule(daysAhead: Int = 7, perPage: Int = 50) async throws -> [AniListAiringScheduleEntry] {
        try await fetchAiringScheduleResult(daysAhead: daysAhead, perPage: perPage).entries
    }

    func fetchAiringScheduleResult(
        daysAhead: Int = 7,
        perPage: Int = 50
    ) async throws -> AnimeAiringScheduleResult {
        return try await AnimeScheduleFallback.load(aniList: {
            let result = try await self.fetchAiringScheduleFromAniList(daysAhead: daysAhead, perPage: perPage)
            AnimeProviderHealthCenter.shared.recordAniListSuccess()
            return result
        }, animeSchedule: {
            let result = try await AnimeScheduleService.shared.fetchSchedule(
                daysAhead: daysAhead,
                preferredLanguageCode: self.preferredLanguageCode
            )
            Logger.shared.log("AnimeSchedule: fallback loaded entries=\(result.entries.count)", type: "Schedule")
            return result
        }, mal: {
            AnimeProviderHealthCenter.shared.notifyMALFallbackIfNeeded(reason: "schedule")
            do {
                let fallback = try await MALMetadataService.shared.fetchAiringSchedule(daysAhead: daysAhead, perPage: perPage)
                return AnimeAiringScheduleResult(entries: fallback, isAuthoritativeForNotifications: false, notice: "MAL fallback · Estimated broadcast dates.")
            } catch {
                try AnimeScheduleService.rethrowCancellation(error)
                AnimeProviderHealthCenter.shared.recordMALFailure(error)
                throw error
            }
        }, permitsFallback: { error in
            let reason = AnimeProviderHealthCenter.shared.recordAniListFailure(error)
            return AnimeProviderHealthCenter.shared.shouldUseMALFallback(for: reason)
        })
    }

    private func fetchAiringScheduleFromAniList(
        daysAhead: Int = 7,
        perPage: Int = 50
    ) async throws -> AnimeAiringScheduleResult {
        let window = ScheduleDateWindow.envelope(dayCount: daysAhead)
        let lowerBound = Int(window.start.timeIntervalSince1970)
        let upperBound = Int(window.end.timeIntervalSince1970)

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
                            idMal
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

            if hasNextPage && currentPage <= maxPages {
                try await Task.sleep(nanoseconds: 400_000_000)
            }
        }

        let start = window.start
        let end = window.end

        let entries = allSchedules
            .filter { $0.media.isAdult != true }
            .map { schedule in
                let title = AniListTitlePicker.title(from: schedule.media.title, preferredLanguageCode: preferredLanguageCode)
                let cover = schedule.media.coverImage?.preferredURL()
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
                    hasKnownAiringTime: true,
                    malID: schedule.media.idMal
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

    func fetchAnimeSeasonIdentity(
        anilistId: Int,
        tmdbShowId: Int? = nil,
        title: String? = nil
    ) async -> AniListSeasonIdentity? {
        guard anilistId > 0 else { return nil }
        let languageCode = preferredLanguageCode
        let cacheLanguageCode = tmdbMatchCacheLanguage

        if let tmdbShowId,
           let cached = animeDetailsCache.object(forKey: animeDetailsCacheKey(tmdbShowId: tmdbShowId))?.value,
           let identity = seasonIdentity(anilistId: anilistId, from: cached) {
            return identity
        }

        if let tmdbShowId, let title,
           let cached = await AnimeIdentityCache.shared.cachedFreshDetails(
               tmdbShowId: tmdbShowId,
               title: title,
               languageCode: cacheLanguageCode
           ),
           let identity = seasonIdentity(anilistId: anilistId, from: cached) {
            cacheAnimeDetails(
                cached,
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
            malId: season.malId,
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
        guard !keys.isEmpty,
              !Task.isCancelled,
              !AnimeProviderHealthCenter.shared.isAniListTemporarilyUnavailable else {
            return [:]
        }
        let uniqueIDs = Array(Set(keys.map(\.anilistId))).sorted()
        let fragment = """
            id
            idMal
            externalLinks { site siteId url }
            title { romaji english native }
            episodes
            coverImage { large medium }
        """

        do {
            var animeByID: [Int: AniListAnime] = [:]

            let chunkSize = 50
            let maxPages = 4
            var start = 0
            while start < uniqueIDs.count {
                let chunk = Array(uniqueIDs[start..<min(start + chunkSize, uniqueIDs.count)])
                let idList = chunk.map(String.init).joined(separator: ", ")
                var pageNumber = 1
                var hasNextPage = true
                while hasNextPage, pageNumber <= maxPages {
                    let query = """
                    query {
                        Page(page: \(pageNumber), perPage: \(chunkSize)) {
                            pageInfo { hasNextPage }
                            media(id_in: [\(idList)], type: ANIME, sort: ID) {
                                \(fragment)
                            }
                        }
                    }
                    """
                    let data = try await executeGraphQLQuery(query, token: nil)
                    guard !Task.isCancelled,
                          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let dataDictionary = json["data"] as? [String: Any],
                          let pageDictionary = dataDictionary["Page"] as? [String: Any],
                          let mediaArray = pageDictionary["media"] as? [Any] else {
                        return [:]
                    }

                    for element in mediaArray {
                        guard !(element is NSNull),
                              let mediaData = try? JSONSerialization.data(withJSONObject: element),
                              let anime = try? JSONDecoder().decode(AniListAnime.self, from: mediaData) else {
                            continue
                        }
                        animeByID[anime.id] = anime
                    }

                    hasNextPage = (pageDictionary["pageInfo"] as? [String: Any])?["hasNextPage"] as? Bool ?? false
                    pageNumber += 1
                }
                start += chunk.count
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
                    posterURL: anime.coverImage?.preferredURL()
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

    func prefetchAnimeDetailSnapshot(
        tmdbShowId: Int,
        seedAniListId: Int?,
        seedMALId: Int? = nil,
        allowStaleSnapshot: Bool = false,
        knownTMDBShowDetail: TMDBTVShowWithSeasons? = nil
    ) async -> Bool {
        guard tmdbShowId > 0, !Task.isCancelled else { return false }

        func seedIsRegular(in value: AniListAnimeWithSeasons) -> Bool {
            guard let seedAniListId, seedAniListId > 0 else { return false }
            return value.seasons.contains { $0.anilistId == seedAniListId }
        }

        let memoryKeys = [
            animeDetailsCacheKey(tmdbShowId: tmdbShowId),
            animeDetailsCacheKey(tmdbShowId: tmdbShowId, hydrationPolicy: .initiallyVisible)
        ]
        for key in memoryKeys {
            if let cached = animeDetailsCache.object(forKey: key),
               Date().timeIntervalSince(cached.timestamp) < animeCacheTTL,
               cached.value.satisfiesIdentitySeeds(
                   aniListID: seedAniListId,
                   malID: seedMALId
               ) {
                return seedIsRegular(in: cached.value)
            }
        }
        if let cached = await AnimeIdentityCache.shared.cachedFreshDetails(
            tmdbShowId: tmdbShowId,
            title: "",
            languageCode: tmdbMatchCacheLanguage
        ), cached.satisfiesIdentitySeeds(aniListID: seedAniListId, malID: seedMALId) {
            return seedIsRegular(in: cached)
        }
        if let cached = await AnimeDetailPreviewCache.shared.value(
            tmdbShowId: tmdbShowId,
            languageCode: tmdbMatchCacheLanguage,
            seedAniListId: seedAniListId,
            seedMALId: seedMALId
        ) {
            return seedIsRegular(in: cached)
        }

        if allowStaleSnapshot {
            if let candidate = await AnimeDetailPreviewCache.shared.revalidationCandidate(
                tmdbShowId: tmdbShowId,
                languageCode: tmdbMatchCacheLanguage,
                seedAniListId: seedAniListId,
                seedMALId: seedMALId
            ) {
                return seedIsRegular(in: candidate)
            }
            if let candidate = await AnimeIdentityCache.shared.revalidationCandidate(
                tmdbShowId: tmdbShowId,
                title: "",
                languageCode: tmdbMatchCacheLanguage,
                seedAniListId: seedAniListId,
                seedMALId: seedMALId
            ) {
                return seedIsRegular(in: candidate)
            }
        }

        guard !AnimeProviderHealthCenter.shared.isAniListTemporarilyUnavailable else {
            return false
        }
        guard seedAniListId.map({ $0 < 0 }) != true else { return false }

        return await AniListRequestContext.$isDetailReadyPath.withValue(true) { [self] in
            async let mappingLookup = AniMapMappingService.shared.mappingsResult(forTMDBShowId: tmdbShowId)
            let show: TMDBTVShowWithSeasons?
            if let knownTMDBShowDetail, knownTMDBShowDetail.id == tmdbShowId {
                show = knownTMDBShowDetail
            } else {
                show = try? await TMDBService.shared.getTVShowWithSeasons(id: tmdbShowId)
            }
            let counts = regularTMDBSeasonCounts(show)
            let plan = await aniMapSeasonSeedPlan(
                forTMDBShowId: tmdbShowId, tmdbSeasonEpisodeCounts: counts,
                knownLookup: await mappingLookup
            )
            var ids = plan.snapshotIDs
            if let seedAniListId, seedAniListId > 0, !ids.contains(seedAniListId) {
                ids.append(seedAniListId)
            }
            guard !ids.isEmpty, !Task.isCancelled else { return seedAniListId.map(plan.ids.contains) ?? false }
            let nodes = await batchFetchAniListStructureNodesResult(ids: ids)
            let ordinaryCounts = ordinaryMappedSeasonCounts(plan.mappingInventory, nodesByID: nodes.nodes)
            let refined = refinedSeasonSeedPlan(plan, tmdbShowId: tmdbShowId, nodesByID: nodes.nodes, tmdbSeasonEpisodeCounts: counts, ordinarySeasonCounts: ordinaryCounts)
            guard let seedAniListId else { return false }
            if refined.ids.contains(seedAniListId) { return true }
            guard !plan.mappingInventory.contains(where: { $0.anilistId == seedAniListId }),
                  let node = nodes.nodes[seedAniListId],
                  AnimeRelationRolePolicy.isExactSelectedRegularEntry(
                    mediaID: node.id, selectedMediaID: seedAniListId, mediaFormat: node.format
                  ) else { return false }
            return matchesTMDBRootIdentity(node, detail: show)
        }
    }

    func cachedAnimeDetailsForImmediateReveal(
        title: String,
        tmdbShowId: Int,
        seedAniListId: Int? = nil,
        seedMALId: Int? = nil
    ) async -> AniListAnimeWithSeasons? {
        let effectiveSeedMALId = RemoteMediaNumericBoundary.positiveIdentifier(seedMALId)
            ?? seedAniListId.flatMap { value in
                value < 0 ? RemoteMediaNumericBoundary.positiveMagnitude(value) : nil
            }
        let memoryKeys = [
            animeDetailsCacheKey(tmdbShowId: tmdbShowId),
            animeDetailsCacheKey(tmdbShowId: tmdbShowId, hydrationPolicy: .initiallyVisible)
        ]
        for key in memoryKeys {
            if let cached = animeDetailsCache.object(forKey: key),
               Date().timeIntervalSince(cached.timestamp) < animeCacheTTL,
               cached.value.satisfiesIdentitySeeds(aniListID: seedAniListId, malID: effectiveSeedMALId) {
                return cached.value
            }
        }
        if let cached = await AnimeIdentityCache.shared.cachedFreshDetails(
            tmdbShowId: tmdbShowId,
            title: title,
            languageCode: tmdbMatchCacheLanguage
        ), cached.satisfiesIdentitySeeds(aniListID: seedAniListId, malID: effectiveSeedMALId) {
            cacheAnimeDetails(
                cached,
                forKey: animeDetailsCacheKey(tmdbShowId: tmdbShowId)
            )
            return cached
        }
        if let cached = await AnimeDetailPreviewCache.shared.value(
            tmdbShowId: tmdbShowId,
            languageCode: tmdbMatchCacheLanguage,
            seedAniListId: seedAniListId,
            seedMALId: effectiveSeedMALId
        ) {
            cacheAnimeDetails(
                cached,
                forKey: animeDetailsCacheKey(
                    tmdbShowId: tmdbShowId,
                    hydrationPolicy: .initiallyVisible
                )
            )
            return cached
        }
        return nil
    }

    func staleAnimeDetailsForRevalidation(
        title: String,
        tmdbShowId: Int,
        seedAniListId: Int? = nil,
        seedMALId: Int? = nil
    ) async -> AniListAnimeWithSeasons? {
        let effectiveSeedMALId = RemoteMediaNumericBoundary.positiveIdentifier(seedMALId)
            ?? seedAniListId.flatMap { value in
                value < 0 ? RemoteMediaNumericBoundary.positiveMagnitude(value) : nil
            }
        if let candidate = await AnimeDetailPreviewCache.shared.revalidationCandidate(
            tmdbShowId: tmdbShowId,
            languageCode: tmdbMatchCacheLanguage,
            seedAniListId: seedAniListId,
            seedMALId: effectiveSeedMALId
        ) {
            return candidate
        }
        return await AnimeIdentityCache.shared.revalidationCandidate(
            tmdbShowId: tmdbShowId,
            title: title,
            languageCode: tmdbMatchCacheLanguage,
            seedAniListId: seedAniListId,
            seedMALId: effectiveSeedMALId
        )
    }

    func fetchAnimeDetailsWithEpisodes(
        title: String,
        tmdbShowId: Int,
        tmdbService: TMDBService,
        tmdbShowPoster: String?,
        token: String?,
        seedAniListId: Int? = nil,
        seedMALId: Int? = nil,
        hydrationPolicy: AnimeEpisodeHydrationPolicy = .complete,
        knownTMDBShowDetail: TMDBTVShowWithSeasons? = nil
    ) async throws -> AniListAnimeWithSeasons {

#if DEBUG
        let publicTimingStart = ProcessInfo.processInfo.systemUptime
        let publicTimingOperation = "show-\(tmdbShowId)-\(hydrationPolicy)"
#endif
        let effectiveSeedMALId = RemoteMediaNumericBoundary.positiveIdentifier(seedMALId)
            ?? seedAniListId.flatMap { value in
                value < 0 ? RemoteMediaNumericBoundary.positiveMagnitude(value) : nil
            }
        let memoryCacheKey = animeDetailsCacheKey(
            tmdbShowId: tmdbShowId,
            hydrationPolicy: hydrationPolicy
        )
        if animeMetadataCacheReadsAllowed, hydrationPolicy == .initiallyVisible,
           let cached = animeDetailsCache.object(forKey: animeDetailsCacheKey(tmdbShowId: tmdbShowId)),
           Date().timeIntervalSince(cached.timestamp) < animeCacheTTL,
           cached.value.satisfiesIdentitySeeds(aniListID: seedAniListId, malID: effectiveSeedMALId) {
            return cached.value
        }
        if animeMetadataCacheReadsAllowed, let cached = animeDetailsCache.object(forKey: memoryCacheKey),
           Date().timeIntervalSince(cached.timestamp) < animeCacheTTL,
           cached.value.satisfiesIdentitySeeds(aniListID: seedAniListId, malID: effectiveSeedMALId) {
            return cached.value
        }
        let key = AnimeDetailRequestKey(
            tmdbShowId: tmdbShowId,
            languageCode: tmdbMatchCacheLanguage,
            seedAniListId: seedAniListId.flatMap { $0 > 0 ? $0 : nil },
            seedMALId: effectiveSeedMALId,
            hydrationPolicy: hydrationPolicy
        )
        do {
            let value = try await AnimeDetailRequestCoordinator.shared.value(for: key) { [self] in
                try await fetchAnimeDetailsWithEpisodesUncoalesced(
                    title: title,
                    tmdbShowId: tmdbShowId,
                    tmdbService: tmdbService,
                    tmdbShowPoster: tmdbShowPoster,
                    token: token,
                    seedAniListId: seedAniListId,
                    seedMALId: effectiveSeedMALId,
                    hydrationPolicy: hydrationPolicy,
                    knownTMDBShowDetail: knownTMDBShowDetail
                )
            }
#if DEBUG
            await AnimeMetadataLoadingValidation.requestLedger?.recordEvent(
                provider: "Public", stage: "ready", operation: publicTimingOperation,
                startedAtUptime: publicTimingStart,
                durationSeconds: ProcessInfo.processInfo.systemUptime - publicTimingStart
            )
#endif
            return value
        } catch {
#if DEBUG
            let failure = error as NSError
            await AnimeMetadataLoadingValidation.requestLedger?.recordEvent(
                provider: "Public", stage: "error", operation: publicTimingOperation,
                startedAtUptime: publicTimingStart,
                durationSeconds: ProcessInfo.processInfo.systemUptime - publicTimingStart,
                errorDomain: failure.domain, errorCode: failure.code
            )
#endif
            throw error
        }
    }

    private func fetchAnimeDetailsWithEpisodesUncoalesced(
        title: String,
        tmdbShowId: Int,
        tmdbService: TMDBService,
        tmdbShowPoster: String?,
        token: String?,
        seedAniListId: Int?,
        seedMALId: Int?,
        hydrationPolicy: AnimeEpisodeHydrationPolicy,
        knownTMDBShowDetail: TMDBTVShowWithSeasons?
    ) async throws -> AniListAnimeWithSeasons {

        if animeMetadataCacheReadsAllowed, let cached = await AnimeIdentityCache.shared.cachedFreshDetails(
            tmdbShowId: tmdbShowId,
            title: title,
            languageCode: tmdbMatchCacheLanguage
        ), cached.satisfiesIdentitySeeds(aniListID: seedAniListId, malID: seedMALId) {
            cacheAnimeDetails(
                cached,
                forKey: animeDetailsCacheKey(tmdbShowId: tmdbShowId)
            )
            return cached
        }

        return try await fetchAnimeDetailsWithoutFreshIdentityCache(
            title: title,
            tmdbShowId: tmdbShowId,
            tmdbService: tmdbService,
            tmdbShowPoster: tmdbShowPoster,
            token: token,
            seedAniListId: seedAniListId,
            seedMALId: seedMALId,
            hydrationPolicy: hydrationPolicy,
            knownTMDBShowDetail: knownTMDBShowDetail
        )
    }

    private func fetchAnimeDetailsWithoutFreshIdentityCache(
        title: String,
        tmdbShowId: Int,
        tmdbService: TMDBService,
        tmdbShowPoster: String?,
        token: String?,
        seedAniListId: Int?,
        seedMALId: Int?,
        hydrationPolicy: AnimeEpisodeHydrationPolicy,
        knownTMDBShowDetail: TMDBTVShowWithSeasons?
    ) async throws -> AniListAnimeWithSeasons {

        if animeMetadataCacheReadsAllowed, hydrationPolicy == .initiallyVisible,
           let cached = await AnimeDetailPreviewCache.shared.value(
               tmdbShowId: tmdbShowId,
               languageCode: tmdbMatchCacheLanguage,
               seedAniListId: seedAniListId,
               seedMALId: seedMALId
           ) {
            cacheAnimeDetails(
                cached,
                forKey: animeDetailsCacheKey(
                    tmdbShowId: tmdbShowId,
                    hydrationPolicy: .initiallyVisible
                )
            )
            return cached
        }

        if seedAniListId.map({ $0 < 0 }) == true,
           let seedMALId,
           seedMALId > 0 {
            do {
                let result = try await fetchMALFallbackDetails(
                    title: title,
                    tmdbShowId: tmdbShowId,
                    tmdbService: tmdbService,
                    tmdbShowPoster: tmdbShowPoster,
                    seedMALId: seedMALId,
                    hydrationPolicy: hydrationPolicy,
                    knownTMDBShowDetail: knownTMDBShowDetail
                )
                cacheAnimeDetails(
                    result,
                    forKey: animeDetailsCacheKey(
                        tmdbShowId: tmdbShowId,
                        hydrationPolicy: hydrationPolicy
                    )
                )
                if animeMetadataCacheReadsAllowed, hydrationPolicy == .initiallyVisible {
                    await AnimeDetailPreviewCache.shared.store(
                        result,
                        tmdbShowId: tmdbShowId,
                        languageCode: tmdbMatchCacheLanguage
                    )
                } else if animeMetadataCacheReadsAllowed {
                    await AnimeIdentityCache.shared.storeAniListDetails(
                        result,
                        tmdbShowId: tmdbShowId,
                        title: title,
                        languageCode: tmdbMatchCacheLanguage
                    )
                }
                return result
            } catch {
                throw error
            }
        }

        if AnimeProviderHealthCenter.shared.isAniListTemporarilyUnavailable {
            AnimeProviderHealthCenter.shared.notifyMALFallbackIfNeeded(
                reason: "details-known-outage"
            )
            return try await fetchMALFallbackDetails(
                title: title,
                tmdbShowId: tmdbShowId,
                tmdbService: tmdbService,
                tmdbShowPoster: tmdbShowPoster,
                seedMALId: seedMALId,
                hydrationPolicy: hydrationPolicy,
                knownTMDBShowDetail: knownTMDBShowDetail
            )
        }

        do {
            let result = try await AniListRequestContext.$isDetailReadyPath.withValue(
                hydrationPolicy == .initiallyVisible
            ) {
                try await fetchAnimeDetailsWithEpisodesFromAniList(
                    title: title,
                    tmdbShowId: tmdbShowId,
                    tmdbService: tmdbService,
                    tmdbShowPoster: tmdbShowPoster,
                    token: token,
                    seedAniListId: seedAniListId,
                    seedMALId: seedMALId,
                    hydrationPolicy: hydrationPolicy,
                    knownTMDBShowDetail: knownTMDBShowDetail
                )
            }
            AnimeProviderHealthCenter.shared.recordAniListSuccess()
            if animeMetadataCacheReadsAllowed, hydrationPolicy == .complete,
               result.satisfiesIdentitySeeds(aniListID: seedAniListId, malID: seedMALId) {
                await AnimeIdentityCache.shared.storeAniListDetails(
                    result,
                    tmdbShowId: tmdbShowId,
                    title: title,
                    languageCode: tmdbMatchCacheLanguage
                )
            } else if animeMetadataCacheReadsAllowed, hydrationPolicy == .initiallyVisible,
                      result.satisfiesIdentitySeeds(aniListID: seedAniListId, malID: seedMALId) {
                let cacheLanguage = tmdbMatchCacheLanguage
                Task(priority: .utility) {
                    await AnimeDetailPreviewCache.shared.store(
                        result,
                        tmdbShowId: tmdbShowId,
                        languageCode: cacheLanguage
                    )
                }
            }
            return result
        } catch {
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            let reason = AnimeProviderHealthCenter.shared.recordAniListFailure(error)
            if animeMetadataCacheReadsAllowed, hydrationPolicy == .initiallyVisible,
               let cached = await AnimeDetailPreviewCache.shared.value(
                   tmdbShowId: tmdbShowId,
                   languageCode: tmdbMatchCacheLanguage,
                   seedAniListId: seedAniListId,
                   seedMALId: seedMALId,
                   allowStale: true
               ) {
                return cached
            }
            if animeMetadataCacheReadsAllowed, let cached = await AnimeIdentityCache.shared.cachedDetails(
                tmdbShowId: tmdbShowId,
                title: title,
                languageCode: tmdbMatchCacheLanguage
            ), cached.satisfiesIdentitySeeds(aniListID: seedAniListId, malID: seedMALId) {
                if AnimeProviderHealthCenter.shared.shouldUseMALFallback(for: reason) {
                    AnimeProviderHealthCenter.shared.notifyMALFallbackIfNeeded(reason: "details-cache-\(reason.rawValue)")
                }
                return cached
            }
            guard AnimeProviderHealthCenter.shared.shouldUseMALFallback(for: reason) else { throw error }
            AnimeProviderHealthCenter.shared.notifyMALFallbackIfNeeded(reason: "details-\(reason.rawValue)")
            return try await fetchMALFallbackDetails(
                title: title,
                tmdbShowId: tmdbShowId,
                tmdbService: tmdbService,
                tmdbShowPoster: tmdbShowPoster,
                seedMALId: seedMALId,
                hydrationPolicy: hydrationPolicy,
                knownTMDBShowDetail: knownTMDBShowDetail
            )
        }
    }

    private func fetchMALFallbackDetails(
        title: String,
        tmdbShowId: Int,
        tmdbService: TMDBService,
        tmdbShowPoster: String?,
        seedMALId: Int?,
        hydrationPolicy: AnimeEpisodeHydrationPolicy,
        knownTMDBShowDetail: TMDBTVShowWithSeasons?
    ) async throws -> AniListAnimeWithSeasons {
        do {
            return try await AniListRequestContext.$isDetailReadyPath.withValue(
                hydrationPolicy == .initiallyVisible
            ) {
                try await MALMetadataService.shared.fetchAnimeDetailsWithEpisodes(
                    title: title,
                    tmdbShowId: tmdbShowId,
                    tmdbService: tmdbService,
                    tmdbShowPoster: tmdbShowPoster,
                    rootMALId: seedMALId,
                    hydrationPolicy: hydrationPolicy,
                    knownTMDBShowDetail: knownTMDBShowDetail
                )
            }
        } catch {
            AnimeProviderHealthCenter.shared.recordMALFailure(error)
            throw error
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

    func detailReadyAnimeRating(
        tmdbShowDetail: TMDBTVShowWithSeasons,
        animeData: AniListAnimeWithSeasons?
    ) async -> AnimeMetadataRating? {
        if let rating = animeData?.rating, rating.source == .myAnimeList {
            return rating
        }

        if let malId = animeData?.malId, malId > 0 {
            if let cached = await AnimeRatingCache.shared.rating(malId: malId) {
                return cached
            }
            if let stale = await AnimeRatingCache.shared.rating(malId: malId, allowStale: true) {
                return stale
            }

            Task(priority: .utility) {
                if let fetched = try? await MALMetadataService.shared.fetchAnimeRating(id: malId) {
                    await AnimeRatingCache.shared.store(fetched, malId: malId)
                }
            }
        }

        if let rating = animeData?.rating, rating.source == .aniList {
            return rating
        }
        guard tmdbShowDetail.voteAverage > 0 else { return nil }
        return AnimeMetadataRating(value: tmdbShowDetail.voteAverage, source: .tmdb)
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

    private struct TMDBEpisodeCoordinate {
        let seasonNumber: Int
        let episodeNumber: Int
    }

    private struct TMDBAbsoluteEpisodeHydration {
        var episodes: [Int: TMDBEpisode] = [:]
        var coordinates: [Int: TMDBEpisodeCoordinate] = [:]
    }

    private func tmdbEpisodeCoordinates(
        tvShowDetail: TMDBTVShowWithSeasons?
    ) -> [Int: TMDBEpisodeCoordinate] {
        guard let tvShowDetail else { return [:] }
        let regularSeasons = tvShowDetail.seasons.filter {
            $0.seasonNumber > 0 && $0.episodeCount > 0
        }
        guard let countsBySeason = RemoteMediaNumericBoundary.seasonEpisodeCounts(
            regularSeasons.map { ($0.seasonNumber, $0.episodeCount) }
        ) else { return [:] }
        var result: [Int: TMDBEpisodeCoordinate] = [:]
        var absoluteEpisode = 1
        for seasonNumber in countsBySeason.keys.sorted() {
            guard let episodeCount = countsBySeason[seasonNumber] else { continue }
            for episodeNumber in 1...episodeCount {
                result[absoluteEpisode] = TMDBEpisodeCoordinate(
                    seasonNumber: seasonNumber,
                    episodeNumber: episodeNumber
                )
                guard let next = RemoteMediaNumericBoundary.adding(absoluteEpisode, 1) else {
                    return [:]
                }
                absoluteEpisode = next
            }
        }
        return result
    }

    private func fetchTMDBEpisodesByAbsolute(
        tmdbShowId: Int,
        tvShowDetail: TMDBTVShowWithSeasons?,
        tmdbService: TMDBService,
        requiredAbsoluteRange: ClosedRange<Int>? = nil,
        allowsSummaryCoordinateFallback: Bool = true
    ) async -> TMDBAbsoluteEpisodeHydration {
        var hydration = TMDBAbsoluteEpisodeHydration()

        if let tvShowDetail {
            let realSeasons = tvShowDetail.seasons
                .filter { $0.seasonNumber > 0 && $0.episodeCount > 0 }
                .sorted { $0.seasonNumber < $1.seasonNumber }
            guard RemoteMediaNumericBoundary.seasonEpisodeCounts(
                realSeasons.map { ($0.seasonNumber, $0.episodeCount) }
            ) != nil else { return hydration }
            var absoluteRangeBySeason: [Int: ClosedRange<Int>] = [:]
            var nextAbsoluteEpisode = 1
            for season in realSeasons {
                guard let countMinusOne = RemoteMediaNumericBoundary.adding(
                    season.episodeCount,
                    -1
                ), let upperBound = RemoteMediaNumericBoundary.adding(
                    nextAbsoluteEpisode,
                    countMinusOne
                ), let next = RemoteMediaNumericBoundary.adding(upperBound, 1) else {
                    return hydration
                }
                absoluteRangeBySeason[season.seasonNumber] = nextAbsoluteEpisode...upperBound
                nextAbsoluteEpisode = next
            }
            let seasonsToFetch = realSeasons.filter { season in
                guard let requiredAbsoluteRange,
                      let seasonRange = absoluteRangeBySeason[season.seasonNumber] else {
                    return true
                }
                return seasonRange.overlaps(requiredAbsoluteRange)
            }
            var seasonResults: [(seasonNumber: Int, episodes: [TMDBEpisode])] = []

            await withTaskGroup(of: (Int, [TMDBEpisode]?).self) { group in
                for season in seasonsToFetch {
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

            let fetchedEpisodesBySeason = Dictionary(
                seasonResults.map { ($0.seasonNumber, $0.episodes) },
                uniquingKeysWith: { first, _ in first }
            )
            let projected = AnimeSeasonEpisodeHydrationPolicy.hydrateTMDBInventory(
                seasons: realSeasons,
                fetchedEpisodesBySeason: fetchedEpisodesBySeason,
                allowsSummaryCoordinates: allowsSummaryCoordinateFallback
            )
            hydration.episodes = projected.episodes
            hydration.coordinates = projected.coordinates.mapValues {
                TMDBEpisodeCoordinate(seasonNumber: $0.seasonNumber, episodeNumber: $0.episodeNumber)
            }
        }

        guard hydration.episodes.isEmpty, !Task.isCancelled else {
            return hydration
        }

        guard requiredAbsoluteRange == nil, allowsSummaryCoordinateFallback else { return hydration }

        Logger.shared.log(
            "AniListService: No TMDB episodes loaded; attempting direct season fetch",
            type: "AniList"
        )
        var absoluteIndex = 1
        var seasonNumber = 1
        while !Task.isCancelled,
              seasonNumber <= RemoteMediaNumericBoundary.maximumSeasonNumber,
              absoluteIndex <= RemoteMediaNumericBoundary.maximumTotalEpisodeCount {
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
                guard seasonDetail.episodes.count <= RemoteMediaNumericBoundary.maximumEpisodeCount else {
                    return hydration
                }
                for episode in seasonDetail.episodes.sorted(by: { $0.episodeNumber < $1.episodeNumber }) {
                    guard absoluteIndex <= RemoteMediaNumericBoundary.maximumTotalEpisodeCount else {
                        return hydration
                    }
                    hydration.episodes[absoluteIndex] = episode
                    hydration.coordinates[absoluteIndex] = TMDBEpisodeCoordinate(
                        seasonNumber: episode.seasonNumber,
                        episodeNumber: episode.episodeNumber
                    )
                    guard let next = RemoteMediaNumericBoundary.adding(absoluteIndex, 1) else {
                        return hydration
                    }
                    absoluteIndex = next
                }
                Logger.shared.log(
                    "AniListService: Fallback fetched season \(seasonNumber): \(seasonDetail.episodes.count) episodes",
                    type: "AniList"
                )
                guard let nextSeason = RemoteMediaNumericBoundary.adding(seasonNumber, 1) else {
                    return hydration
                }
                seasonNumber = nextSeason
            } catch {
                Logger.shared.log(
                    "AniListService: Fallback stopped at season \(seasonNumber) (no more seasons found)",
                    type: "AniList"
                )
                break
            }
        }
        return hydration
    }

    func hydrateAnimeSeasonDetail(
        tmdbShowId: Int,
        season: TMDBSeason,
        episodes: [AniListEpisode],
        tmdbService: TMDBService
    ) async throws -> TMDBSeasonDetail {
        let sourceSeasonNumbers = Set(episodes.compactMap { episode in
            RemoteMediaNumericBoundary.seasonNumber(episode.tmdbSeasonNumber, allowsZero: true)
        })

        var sourceEpisodes: [String: TMDBEpisode] = [:]
        if !sourceSeasonNumbers.isEmpty {
            try await withThrowingTaskGroup(of: TMDBSeasonDetail.self) { group in
                for sourceSeasonNumber in sourceSeasonNumbers {
                    group.addTask {
                        try await tmdbService.getSeasonDetails(
                            tvShowId: tmdbShowId,
                            seasonNumber: sourceSeasonNumber
                        )
                    }
                }
                for try await detail in group {
                    for episode in detail.episodes {
                        sourceEpisodes["\(episode.seasonNumber):\(episode.episodeNumber)"] = episode
                    }
                }
            }
        }

        let hydratedEpisodes = episodes.sorted { $0.number < $1.number }.map { episode in
            let source = episode.tmdbSeasonNumber.flatMap { sourceSeasonNumber in
                episode.tmdbEpisodeNumber.flatMap { sourceEpisodeNumber in
                    sourceEpisodes["\(sourceSeasonNumber):\(sourceEpisodeNumber)"]
                }
            }
            return TMDBEpisode(
                id: RemoteMediaNumericBoundary.syntheticIdentifier([
                    (tmdbShowId, 1_000_000),
                    (season.seasonNumber, 10_000),
                    (episode.number, 1)
                ]),
                name: source?.name ?? episode.title,
                overview: source?.overview ?? episode.description,
                stillPath: source?.stillPath ?? episode.stillPath,
                episodeNumber: episode.number,
                seasonNumber: season.seasonNumber,
                airDate: source?.airDate ?? episode.airDate,
                runtime: source?.runtime ?? episode.runtime,
                voteAverage: source?.voteAverage ?? 0,
                voteCount: source?.voteCount ?? 0
            )
        }

        return TMDBSeasonDetail(
            id: season.id,
            name: season.name,
            overview: season.overview ?? "",
            posterPath: season.posterPath,
            seasonNumber: season.seasonNumber,
            airDate: season.airDate,
            episodes: hydratedEpisodes
        )
    }

    private struct AniMapSeasonSeedPlan {
        let mappings: [AniMapMapping]
        let mappingInventory: [AniMapMapping]
        let snapshotIDs: [Int]
        let isComplete: Bool
        let hasUnresolvedIdentity: Bool

        var ids: [Int] {
            mappings.compactMap(\.anilistId)
        }

        func mapping(for anilistId: Int) -> AniMapMapping? {
            mappings.first { $0.anilistId == anilistId }
        }
    }

    private func regularTMDBSeasonCounts(_ detail: TMDBTVShowWithSeasons?) -> [Int: Int]? {
        guard let detail else { return nil }
        return RemoteMediaNumericBoundary.seasonEpisodeCounts(detail.seasons.compactMap { season in
            guard season.seasonNumber > 0, season.episodeCount > 0 else { return nil }
            return (season.seasonNumber, season.episodeCount)
        })
    }

    private func ordinaryMappedSeasonCounts(_ mappings: [AniMapMapping], nodesByID: [Int: AniListAnime]) -> [Int: Int] {
        AniMapStructuralRole.ordinarySeasonEpisodeCounts(mappings,
            identity: { $0.anilistId },
            mediaType: { $0.anilistId.flatMap { nodesByID[$0]?.format } },
            episodeCount: { mapping in
                guard let id = mapping.anilistId, let node = nodesByID[id] else { return nil }
                return node.status?.uppercased() == "NOT_YET_RELEASED" ? 0 : node.episodes
            })
    }

    private func refinedSeasonSeedPlan(_ plan: AniMapSeasonSeedPlan, tmdbShowId: Int, nodesByID: [Int: AniListAnime],
        tmdbSeasonEpisodeCounts: [Int: Int]?, ordinarySeasonCounts: [Int: Int]) -> AniMapSeasonSeedPlan {
        let refined = seasonSeedPlan(from: plan.mappingInventory, forTMDBShowId: tmdbShowId,
            isComplete: plan.isComplete, tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
            nodesByID: nodesByID, ordinarySeasonCounts: ordinarySeasonCounts)
        return AniMapSeasonSeedPlan(mappings: refined.mappings, mappingInventory: plan.mappingInventory, snapshotIDs: plan.snapshotIDs,
            isComplete: plan.isComplete, hasUnresolvedIdentity: plan.hasUnresolvedIdentity || refined.hasUnresolvedIdentity)
    }

    private func aniMapSeasonSeedPlan(
        forTMDBShowId tmdbShowId: Int,
        tmdbSeasonEpisodeCounts: [Int: Int]?,
        knownLookup: AniMapLookupResult? = nil
    ) async -> AniMapSeasonSeedPlan {
        let lookup: AniMapLookupResult
        if let knownLookup {
            lookup = knownLookup
        } else {
            lookup = await AniMapMappingService.shared.mappingsResult(forTMDBShowId: tmdbShowId)
        }
        return seasonSeedPlan(
            from: lookup.mappings,
            forTMDBShowId: tmdbShowId,
            isComplete: lookup.isComplete,
            tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts
        )
    }

    private func seasonSeedPlan(
        from allMappings: [AniMapMapping],
        forTMDBShowId tmdbShowId: Int,
        isComplete: Bool,
        tmdbSeasonEpisodeCounts: [Int: Int]?,
        nodesByID: [Int: AniListAnime] = [:],
        ordinarySeasonCounts: [Int: Int] = [:]
    ) -> AniMapSeasonSeedPlan {
        guard !allMappings.isEmpty else {
            return AniMapSeasonSeedPlan(
                mappings: [],
                mappingInventory: allMappings,
                snapshotIDs: [],
                isComplete: isComplete,
                hasUnresolvedIdentity: false
            )
        }

        let snapshotIDs = Array(Set(allMappings.compactMap { mapping -> Int? in
            guard mapping.tmdbShowId == tmdbShowId,
                  let id = mapping.anilistId,
                  id > 0 else { return nil }
            return id
        })).sorted()
        let relevantMappings = AniMapStructuralRole.regularStoryMappings(allMappings,
            tmdbShowId: tmdbShowId, tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
            regularStoryEpisodeCounts: ordinarySeasonCounts,
            mediaType: { $0.anilistId.flatMap { nodesByID[$0]?.format } },
            episodeCount: { $0.anilistId.flatMap { nodesByID[$0]?.episodes } })
        let hasUnresolvedIdentity = relevantMappings.contains { $0.anilistId == nil }
        var seen = Set<Int>()
        let mappings = relevantMappings
            .sorted { lhs, rhs in
                let lhsScore = aniMapCandidateScore(lhs)
                let rhsScore = aniMapCandidateScore(rhs)
                if lhsScore != rhsScore {
                    return lhsScore < rhsScore
                }
                let lhsOffset = lhs.tvdbEpisodeOffset ?? 0
                let rhsOffset = rhs.tvdbEpisodeOffset ?? 0
                if lhsOffset != rhsOffset {
                    return lhsOffset < rhsOffset
                }
                return (lhs.anilistId ?? Int.max) < (rhs.anilistId ?? Int.max)
            }
            .compactMap { mapping -> AniMapMapping? in
                guard let id = mapping.anilistId, id > 0, seen.insert(id).inserted else {
                    return nil
                }
                return mapping
            }

        return AniMapSeasonSeedPlan(
            mappings: mappings,
            mappingInventory: allMappings,
            snapshotIDs: snapshotIDs,
            isComplete: isComplete,
            hasUnresolvedIdentity: hasUnresolvedIdentity
        )
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

    private func matchesTMDBRootIdentity(_ anime: AniListAnime, detail: TMDBTVShowWithSeasons?) -> Bool {
        guard let detail,
              let tmdbYear = detail.firstAirDate.flatMap({ Int($0.prefix(4)) }),
              let animeYear = anime.startDate?.year ?? anime.seasonYear,
              animeYear == tmdbYear else { return false }
        let targetTitles = Set([detail.name, detail.originalName].compactMap { $0 }
            .map(normalizedAnimeTitle).filter { !$0.isEmpty })
        return AniListTitlePicker.titleCandidates(from: anime.title)
            .map(normalizedAnimeTitle)
            .contains { targetTitles.contains($0) }
    }

    fileprivate func completeEpisodeTitlesForStructure(
        mediaID: Int, expectedEpisodeCount: Int, token: String?
    ) async -> [String] {
        guard RemoteMediaNumericBoundary.positiveIdentifier(mediaID) != nil,
              RemoteMediaNumericBoundary.episodeCount(expectedEpisodeCount) != nil else { return [] }
        let query = "query { Media(id: \(mediaID), type: ANIME) { id episodes streamingEpisodes { title } } }"
        struct Response: Decodable {
            struct Payload: Decodable {
                struct Media: Decodable {
                    struct Episode: Decodable { let title: String? }
                    let id: Int
                    let episodes: Int?
                    let streamingEpisodes: [Episode]?
                }
                let Media: Media?
            }
            let data: Payload?
        }
        guard let data = try? await executeGraphQLQuery(query, token: token),
              let media = try? JSONDecoder().decode(Response.self, from: data).data?.Media,
              media.id == mediaID, media.episodes == expectedEpisodeCount,
              let episodes = media.streamingEpisodes, episodes.count == expectedEpisodeCount else { return [] }
        let titles = episodes.compactMap(\.title)
        return titles.count == expectedEpisodeCount ? titles : []
    }

    private func supplementalStructureNodeLookup(title: String, token: String?) async -> [Int: AniListAnime] {
        let query = """
        query ($search: String) {
            Page(perPage: 20) {
                media(search: $search, type: ANIME, sort: START_DATE_DESC) {
                    id idMal title { romaji english native } episodes status format
                    startDate { year month day } endDate { year month day }
                    coverImage { large medium }
                    relations { edges { relationType node { id type format title { romaji english native } } } }
                }
            }
        }
        """
        struct Response: Decodable {
            struct Payload: Decodable {
                struct PageData: Decodable { let media: [AniListAnime] }
                let Page: PageData
            }
            let data: Payload?
        }
        guard let data = try? await executeGraphQLQuery(query, token: token, variables: ["search": title]),
              let nodes = try? JSONDecoder().decode(Response.self, from: data).data?.Page.media,
              nodes.count <= 20 else { return [:] }
        return Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    fileprivate func mappedSupplementalEpisodePlacements(
        candidates: [AnimeStructureCourPlacementCandidate],
        aniListIDs: [Int: Int],
        tvShowDetail: TMDBTVShowWithSeasons?,
        tmdbService: TMDBService,
        token: String?
    ) async -> [Int: [TMDBEpisode]] {
        guard let tvShowDetail else { return [:] }
        var sources: [Int: TMDBSeasonDetail] = [:]
        let eligible = candidates.filter { candidate in
            guard candidate.hasTrustedIdentity,
                  ["FINISHED", "FINISHED_AIRING"].contains(candidate.status?.uppercased() ?? ""),
                  ["TV", "TV_SHORT", "ONA"].contains(candidate.format?.uppercased() ?? ""),
                  let seasonNumber = candidate.mappedTMDBSeason,
                  let season = tvShowDetail.seasons.first(where: { $0.seasonNumber == seasonNumber }),
                  let count = candidate.episodeCount,
                  count > season.episodeCount, count - season.episodeCount <= 8,
                  candidate.startDate != nil, candidate.endDate != nil else { return false }
            return true
        }
        for candidate in eligible {
            guard let season = candidate.mappedTMDBSeason, sources[season] == nil else { continue }
            sources[season] = try? await tmdbService.getSeasonDetails(tvShowId: tvShowDetail.id, seasonNumber: season)
        }
        let anchored = eligible.filter { candidate in
            guard let season = candidate.mappedTMDBSeason,
                  let source = sources[season],
                  let target = tvShowDetail.seasons.first(where: { $0.seasonNumber == season })?.episodeCount,
                  source.episodes.count == target else { return false }
            return source.episodes.min(by: { $0.episodeNumber < $1.episodeNumber })?.airDate == candidate.startDate
        }
        guard !anchored.isEmpty, !Task.isCancelled,
              let specials = try? await tmdbService.getSeasonDetails(tvShowId: tvShowDetail.id, seasonNumber: 0) else { return [:] }
        var result: [Int: [TMDBEpisode]] = [:]
        for candidate in anchored {
            guard !Task.isCancelled, let season = candidate.mappedTMDBSeason,
                  let source = sources[season],
                  let target = tvShowDetail.seasons.first(where: { $0.seasonNumber == season })?.episodeCount else { continue }
            if let episodes = AnimeStructurePolicy.verifiedMappedArcContinuation(
                episodeCount: candidate.episodeCount, mediaFormat: candidate.format, status: candidate.status,
                providerStartDate: candidate.startDate, providerEndDate: candidate.endDate,
                sourceSeason: source, sourceEpisodeCount: target, specialEpisodes: specials.episodes) {
                result[candidate.id] = episodes
                continue
            }
            guard let mediaID = aniListIDs[candidate.id], let count = candidate.episodeCount else { continue }
            let titles = await completeEpisodeTitlesForStructure(mediaID: mediaID, expectedEpisodeCount: count, token: token)
            if let episodes = AnimeStructurePolicy.verifiedMappedEpisodeList(
                episodeCount: candidate.episodeCount, mediaFormat: candidate.format, status: candidate.status,
                providerStartDate: candidate.startDate, providerEndDate: candidate.endDate,
                sourceSeason: source, sourceEpisodeCount: target,
                specialEpisodes: specials.episodes, streamingEpisodeTitles: titles) {
                result[candidate.id] = episodes
            }
        }
        return result
    }

    private func isMappedAniListSeasonCandidate(
        _ anime: AniListAnime,
        mapping: AniMapMapping?,
        tmdbSeasonEpisodeCounts: [Int: Int]?,
        ordinarySeasonCounts: [Int: Int]? = nil
    ) -> Bool {
        guard let mapping,
              AniMapStructuralRole.isRegularStory(
                  mapping,
                  fallbackMediaType: anime.format,
                  tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                  episodeCount: anime.episodes,
                  regularStoryEpisodeCounts: ordinarySeasonCounts
              ) else { return false }

        let title = AniListTitlePicker.title(
            from: anime.title,
            preferredLanguageCode: preferredLanguageCode
        ).lowercased()
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

    private func animeStructureOrderingCandidate(
        anime: AniListAnime,
        mapping: AniMapMapping?,
        preferTVDBSeason: Bool = false
    ) -> AnimeStructureOrderingCandidate {
        let ordinal = aniListSeasonOrdinal(anime.season)
        let inferredMonth: Int?
        switch ordinal {
        case 0: inferredMonth = 1
        case 1: inferredMonth = 4
        case 2: inferredMonth = 7
        case 3: inferredMonth = 10
        default: inferredMonth = nil
        }
        let rawMappedSeason = preferTVDBSeason ? mapping?.tvdbSeason : mapping?.tmdbSeason
        let mappedSeason = rawMappedSeason.flatMap { $0 > 0 ? $0 : nil }
        return AnimeStructureOrderingCandidate(
            anilistId: anime.id,
            mappedTMDBSeason: mappedSeason,
            episodeOffset: mapping?.tvdbEpisodeOffset,
            startYear: anime.startDate?.year,
            startMonth: anime.startDate?.month ?? inferredMonth,
            startDay: anime.startDate?.day,
            seasonYear: anime.seasonYear,
            seasonOrdinal: ordinal
        )
    }

    private func validatedAniMapStructure(
        plan: AniMapSeasonSeedPlan,
        nodesByID: [Int: AniListAnime],
        tvShowDetail: TMDBTVShowWithSeasons?,
        allowPreviewCoverage: Bool,
        ordinarySeasonCounts: [Int: Int]
    ) -> [AniListAnime]? {
        guard !plan.mappings.isEmpty, let tvShowDetail else { return nil }
        guard let expectedSeasonCounts = RemoteMediaNumericBoundary.seasonEpisodeCounts(
            tvShowDetail.seasons.compactMap { season in
                guard season.seasonNumber > 0, season.episodeCount > 0 else { return nil }
                return (season.seasonNumber, season.episodeCount)
            }
        ) else { return nil }

        guard plan.mappings.allSatisfy({ mapping in
            mapping.anilistId.flatMap { nodesByID[$0] } != nil
        }) else { return nil }
        let activeMappings = plan.mappings.filter { mapping in
            guard let id = mapping.anilistId, let node = nodesByID[id] else { return false }
            return node.status != "NOT_YET_RELEASED"
        }
        let mappedNodes = activeMappings.compactMap { mapping -> AniListAnime? in
            guard let id = mapping.anilistId,
                  let node = nodesByID[id],
                  isMappedAniListSeasonCandidate(node, mapping: mapping, tmdbSeasonEpisodeCounts: expectedSeasonCounts, ordinarySeasonCounts: ordinarySeasonCounts) else {
                return nil
            }
            return node
        }
        guard !mappedNodes.isEmpty, mappedNodes.count == activeMappings.count else { return nil }

        let segments = activeMappings.compactMap { mapping -> AnimeStructureCoverageSegment? in
            guard let id = mapping.anilistId, let node = nodesByID[id] else { return nil }
            return AnimeStructureCoverageSegment(
                mappedTMDBSeason: mapping.tmdbSeason.flatMap { $0 > 0 ? $0 : nil },
                episodeCount: node.episodes
            )
        }

        let exactCoverage = AnimeStructurePolicy.hasExactCoverage(
            tmdbSeasonEpisodeCounts: expectedSeasonCounts,
            segments: segments
        )
        let singleOpenEndedSeries = mappedNodes.count == 1
            && AnimeStructurePolicy.allowsSingleOpenEndedSeries(
                status: mappedNodes[0].status,
                episodeCount: mappedNodes[0].episodes,
            mappedTMDBSeason: activeMappings[0].tmdbSeason,
            tmdbSeasonEpisodeCounts: expectedSeasonCounts
        )
        let activeMappedTMDBSeasons = Set(activeMappings.compactMap { mapping in
            mapping.tmdbSeason.flatMap { $0 > 0 ? $0 : nil }
        })
        let futureOnlyMappedTMDBSeasons = Set(plan.mappings.compactMap { mapping -> Int? in
            guard let id = mapping.anilistId,
                  nodesByID[id]?.status?.uppercased() == "NOT_YET_RELEASED",
                  let season = mapping.tmdbSeason,
                  season > 0,
                  !activeMappedTMDBSeasons.contains(season) else {
                return nil
            }
            return season
        })
        let acceptsExactCoverage = AnimeStructurePolicy.acceptsMappedCoverage(
            lookupIsComplete: plan.isComplete,
            hasUnresolvedIdentity: plan.hasUnresolvedIdentity,
            hasExactCoverage: exactCoverage,
            allowsSingleOpenEndedSeries: singleOpenEndedSeries
        )
        let acceptsPreviewCoverage = allowPreviewCoverage
            && AnimeStructurePolicy.hasSafePreviewCoverage(
                lookupIsComplete: plan.isComplete,
                hasUnresolvedIdentity: plan.hasUnresolvedIdentity,
                tmdbSeasonEpisodeCounts: expectedSeasonCounts,
                activeSegments: segments,
                futureOnlyMappedTMDBSeasons: futureOnlyMappedTMDBSeasons
            )
        guard acceptsExactCoverage || acceptsPreviewCoverage else {
            Logger.shared.log(
                "AniListService: AniMap structure coverage was incomplete for TMDB \(tvShowDetail.id); retaining relation traversal",
                type: "AniList"
            )
            return nil
        }

        let distinctTMDBSeasons = Set(activeMappings.compactMap { mapping in
            mapping.tmdbSeason.flatMap { $0 > 0 ? $0 : nil }
        })
        let distinctTVDBSeasons = Set(activeMappings.compactMap { mapping in
            mapping.tvdbSeason.flatMap { $0 > 0 ? $0 : nil }
        })
        let preferTVDBSeason = distinctTMDBSeasons.count <= 1 && distinctTVDBSeasons.count > 1
        let candidates = mappedNodes.map { node in
            animeStructureOrderingCandidate(
                anime: node,
                mapping: plan.mapping(for: node.id),
                preferTVDBSeason: preferTVDBSeason
            )
        }
        let orderedIDs = AnimeStructurePolicy.orderedIDs(candidates)
        let ordered = orderedIDs.compactMap { nodesByID[$0] }
        guard ordered.count == mappedNodes.count else { return nil }
        guard hasCompatibleMappedOrder(
            ordered: ordered,
            plan: plan,
            expectedTMDBSeasonCount: expectedSeasonCounts.count
        ) else {
            Logger.shared.log(
                "AniListService: mapped coordinate order conflicted with legacy local order for TMDB \(tvShowDetail.id)",
                type: "AniList"
            )
            return nil
        }

        Logger.shared.log(
            "AniListService: Accepted validated AniMap structure for TMDB \(tvShowDetail.id) with \(ordered.count) entries coverage=\(acceptsExactCoverage ? "exact" : "safe-preview")",
            type: "AniList"
        )
        return ordered
    }

    private func hydratedAniMapIdentityRoster(
        plan: AniMapSeasonSeedPlan,
        nodesByID: [Int: AniListAnime],
        tvShowDetail: TMDBTVShowWithSeasons?,
        ordinarySeasonCounts: [Int: Int]
    ) -> [AniListAnime]? {
        guard plan.isComplete, !plan.ids.isEmpty, let tvShowDetail else { return nil }
        let counts = regularTMDBSeasonCounts(tvShowDetail)
        var nodes = plan.ids.compactMap { nodesByID[$0] }
        guard nodes.count == plan.ids.count,
              nodes.allSatisfy({ node in
                  ["TV", "TV_SHORT", "ONA"].contains(node.format?.uppercased() ?? "")
                      && isMappedAniListSeasonCandidate(node, mapping: plan.mapping(for: node.id),
                        tmdbSeasonEpisodeCounts: counts, ordinarySeasonCounts: ordinarySeasonCounts)
              }) else { return nil }
        let actualSeasons = tvShowDetail.seasons.filter { $0.seasonNumber > 0 && $0.episodeCount > 0 }
        if actualSeasons.count == 1, let actual = actualSeasons.first {
            let roots = nodes.filter {
                matchesTMDBRootIdentity($0, detail: tvShowDetail)
                    && $0.startDate?.exactDateString == actual.airDate && $0.episodes == actual.episodeCount
            }
            if roots.count == 1, let root = roots.first {
                let ids = Set(nodes.map(\.id))
                let constraints = nodes.flatMap { node in
                    (node.relations?.edges ?? []).compactMap { edge -> AnimeStructureRelationConstraint? in
                        guard ["SEQUEL", "PREQUEL", "SEASON"].contains(edge.relationType.uppercased()),
                              ids.contains(edge.node.id), edge.node.type == nil || edge.node.type == "ANIME" else { return nil }
                        return .init(beforeID: node.id, afterID: edge.node.id)
                    }
                }
                let connected = AnimeStructurePolicy.ordinaryConnectedIDs(rootID: root.id, candidateIDs: ids, constraints: constraints)
                nodes = nodes.filter { connected.contains($0.id) }
            }
        }
        let tmdbSeasons = Set(plan.mappings.compactMap { $0.tmdbSeason.flatMap { $0 > 0 ? $0 : nil } })
        let tvdbSeasons = Set(plan.mappings.compactMap { $0.tvdbSeason.flatMap { $0 > 0 ? $0 : nil } })
        let ordered = AnimeStructurePolicy.orderedIDs(nodes.map {
            animeStructureOrderingCandidate(anime: $0, mapping: plan.mapping(for: $0.id),
                preferTVDBSeason: tmdbSeasons.count <= 1 && tvdbSeasons.count > 1)
        }).compactMap { nodesByID[$0] }
        guard ordered.count == nodes.count,
              nodes.allSatisfy({ node in
                  plan.mappingInventory.contains { mapping in
                      mapping.anilistId == node.id && mapping.tmdbShowId == tvShowDetail.id
                          && (mapping.tmdbSeason.map { $0 > 0 } == true || mapping.tvdbSeason == -1)
                  }
              }), hasCompatibleMappedOrder(ordered: ordered, plan: plan,
                expectedTMDBSeasonCount: counts?.count ?? 0) else { return nil }
        return ordered
    }

    private func hasCompatibleMappedOrder(
        ordered: [AniListAnime],
        plan: AniMapSeasonSeedPlan,
        expectedTMDBSeasonCount: Int
    ) -> Bool {
        let segments = ordered.compactMap { anime -> AnimeStructureMappedOrderSegment? in
            guard let mapping = plan.mapping(for: anime.id) else { return nil }
            return AnimeStructureMappedOrderSegment(
                mappedTMDBSeason: mapping.tmdbSeason,
                mappedTVDBSeason: mapping.tvdbSeason,
                tvdbEpisodeOffset: mapping.tvdbEpisodeOffset,
                episodeCount: anime.episodes
            )
        }
        guard segments.count == ordered.count else { return false }
        return AnimeStructurePolicy.hasCompatibleMappedOrder(
            segments,
            expectedTMDBSeasonCount: expectedTMDBSeasonCount
        )
    }

    private func relationOrderedAnimeIDs(_ anime: [AniListAnime]) -> [Int] {
        var constraints: [AnimeStructureRelationConstraint] = []
        for entry in anime {
            for edge in entry.relations?.edges ?? [] {
                switch edge.relationType.uppercased() {
                case "SEQUEL":
                    constraints.append(.init(beforeID: entry.id, afterID: edge.node.id))
                case "PREQUEL":
                    constraints.append(.init(beforeID: edge.node.id, afterID: entry.id))
                default:
                    break
                }
            }
        }
        return AnimeStructurePolicy.relationOrderedIDs(
            anime.map { animeStructureOrderingCandidate(anime: $0, mapping: nil) },
            constraints: constraints
        )
    }

#if DEBUG
    func validateUncachedAnimeLoading(
        title: String,
        tmdbShowId: Int,
        seedAniListId: Int? = nil,
        seedMALId: Int? = nil,
        hydrationPolicy: AnimeEpisodeHydrationPolicy = .initiallyVisible,
        ignoreAniMapResults: Bool = false,
        verification: ((AniListAnimeWithSeasons) async throws -> Void)? = nil
    ) async throws -> AniListAnimeWithSeasons {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return try await AnimeMappingLoadingValidation.$ignoreResults.withValue(ignoreAniMapResults) {
            try await AnimeMappingLoadingValidation.$service.withValue(.validationInstance()) {
                try await AnimeMetadataLoadingValidation.$session.withValue(session) {
                    try await AnimeMetadataLoadingValidation.$requestNamespace.withValue(UUID().uuidString) {
                        try await AnimeMetadataLoadingValidation.$tmdbCache.withValue(TMDBDetailCache()) {
                            try await AnimeMetadataLoadingValidation.$bypassesGraphCaches.withValue(true) {
                                try await MALMetadataService.$isLiveRegressionValidation.withValue(true) {
                                    let details = try await fetchAnimeDetailsWithEpisodes(
                                        title: title, tmdbShowId: tmdbShowId, tmdbService: .shared,
                                        tmdbShowPoster: nil, token: nil, seedAniListId: seedAniListId,
                                        seedMALId: seedMALId, hydrationPolicy: hydrationPolicy
                                    )
                                    if let verification { try await verification(details) }
                                    return details
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func validateFreshAnimeLoading(title: String, tmdbShowId: Int) async throws -> AniListAnimeWithSeasons {
        try await AnimeMetadataLoadingValidation.$requestNamespace.withValue(UUID().uuidString) {
            try await AnimeMetadataLoadingValidation.$tmdbCache.withValue(TMDBDetailCache()) {
                try await AnimeMetadataLoadingValidation.$bypassesGraphCaches.withValue(true) {
                    try await AniListRequestContext.$isDetailReadyPath.withValue(true) {
                        try await fetchAnimeDetailsWithEpisodesFromAniList(
                            title: title, tmdbShowId: tmdbShowId, tmdbService: .shared,
                            tmdbShowPoster: nil, token: nil, seedAniListId: nil, seedMALId: nil,
                            hydrationPolicy: .initiallyVisible, knownTMDBShowDetail: nil
                        )
                    }
                }
            }
        }
    }
#endif

    private func fetchAnimeDetailsWithEpisodesFromAniList(
        title: String,
        tmdbShowId: Int,
        tmdbService: TMDBService,
        tmdbShowPoster: String?,
        token: String?,
        seedAniListId: Int?,
        seedMALId: Int?,
        hydrationPolicy: AnimeEpisodeHydrationPolicy,
        knownTMDBShowDetail: TMDBTVShowWithSeasons?
    ) async throws -> AniListAnimeWithSeasons {
        try Task.checkCancellation()
        let detailTimingStart = ProcessInfo.processInfo.systemUptime
        func logDetailTiming(_ stage: String, fields: String = "") async {
            let elapsed = ProcessInfo.processInfo.systemUptime - detailTimingStart
#if DEBUG
            await AnimeMetadataLoadingValidation.requestLedger?.recordEvent(
                provider: "AniList", stage: "stage-\(stage)",
                operation: "show-\(tmdbShowId)-\(hydrationPolicy)",
                startedAtUptime: detailTimingStart, durationSeconds: elapsed
            )
#endif
            guard hydrationPolicy == .initiallyVisible else { return }
            let elapsedMs = Int(
                (elapsed * 1_000).rounded()
            )
            let suffix = fields.isEmpty ? "" : " \(fields)"
            Logger.shared.log(
                "AnimeDetailTiming: tmdbId=\(tmdbShowId) stage=\(stage) elapsedMs=\(elapsedMs)\(suffix)",
                type: "AniList"
            )
        }

        let cacheKey = animeDetailsCacheKey(
            tmdbShowId: tmdbShowId,
            hydrationPolicy: hydrationPolicy
        )
        var allowsGraphCache = true
#if DEBUG
        allowsGraphCache = !AnimeMetadataLoadingValidation.bypassesGraphCaches
#endif
        if allowsGraphCache, let cached = animeDetailsCache.object(forKey: cacheKey),
           Date().timeIntervalSince(cached.timestamp) < animeCacheTTL,
           cached.value.satisfiesIdentitySeeds(aniListID: seedAniListId, malID: seedMALId) {
            Logger.shared.log("AniListService: Cache HIT for tmdbId=\(tmdbShowId)", type: "AniList")
            return cached.value
        }

        Logger.shared.log("AniListService: fetchAnimeDetailsWithEpisodes START for '\(title)' tmdbId=\(tmdbShowId)", type: "AniList")

        async let mappingLookup = AniMapMappingService.shared.mappingsResult(forTMDBShowId: tmdbShowId)
        let tvShowDetail: TMDBTVShowWithSeasons?
        if let knownTMDBShowDetail {
            tvShowDetail = knownTMDBShowDetail
        } else {
            tvShowDetail = await fetchTMDBShowForAnimeTraversal(
                tmdbShowId: tmdbShowId,
                tmdbService: tmdbService
            )
        }
        let earlyCoordinateCount = tmdbEpisodeCoordinates(tvShowDetail: tvShowDetail).count
        let concurrentHydrationRange: ClosedRange<Int>?
        let hydratesConcurrently: Bool
        switch hydrationPolicy {
        case .complete:
            concurrentHydrationRange = nil
            hydratesConcurrently = true
        case .initiallyVisible:

            concurrentHydrationRange = earlyCoordinateCount > 0
                ? 1...min(100, earlyCoordinateCount)
                : nil
            hydratesConcurrently = earlyCoordinateCount > 0
        }
        async let concurrentHydrationTask: TMDBAbsoluteEpisodeHydration? = {
            guard hydratesConcurrently else { return nil }
            return await fetchTMDBEpisodesByAbsolute(
                tmdbShowId: tmdbShowId,
                tvShowDetail: tvShowDetail,
                tmdbService: tmdbService,
                requiredAbsoluteRange: concurrentHydrationRange
            )
        }()
        var candidates: [AniListAnime] = []
        var aniMapNodesByID: [Int: AniListAnime] = [:]
        let actualSeasonCounts = regularTMDBSeasonCounts(tvShowDetail)
        var aniMapSeedPlan = await aniMapSeasonSeedPlan(
            forTMDBShowId: tmdbShowId, tmdbSeasonEpisodeCounts: actualSeasonCounts,
            knownLookup: await mappingLookup
        )
        let startsVerifiedInventoryEarly = AnimeStructurePolicy.requiresVerifiedAbsoluteOrderInventory(
            tvdbSeasons: aniMapSeedPlan.mappings.map(\.tvdbSeason),
            tmdbSeasonCount: actualSeasonCounts?.count ?? 0
        )
        async let verifiedInventoryTask: TMDBAbsoluteEpisodeHydration? = {
            guard hydrationPolicy == .initiallyVisible, startsVerifiedInventoryEarly else { return nil }
            return await fetchTMDBEpisodesByAbsolute(
                tmdbShowId: tmdbShowId, tvShowDetail: tvShowDetail, tmdbService: tmdbService,
                allowsSummaryCoordinateFallback: false
            )
        }()
        var ordinarySeasonCounts: [Int: Int] = [:]
        var contradictedMappedSpecialIDs = Set<Int>()
        await logDetailTiming(
            "animap-plan",
            fields: "mapped=\(aniMapSeedPlan.ids.count) snapshot=\(aniMapSeedPlan.snapshotIDs.count) complete=\(aniMapSeedPlan.isComplete)"
        )
        var aniMapCandidateIds = aniMapSeedPlan.ids
        if let seedAniListId, seedAniListId > 0, !aniMapCandidateIds.contains(seedAniListId) {
            aniMapCandidateIds.insert(seedAniListId, at: 0)
        }
        try Task.checkCancellation()
        let relocationCandidates = await relocatedTVDBSiblingCandidates(
            tmdbShowId: tmdbShowId, tvShowDetail: tvShowDetail, plan: aniMapSeedPlan, tmdbService: tmdbService
        )
        try Task.checkCancellation()
        let snapshotIDs = Array(Set(aniMapSeedPlan.snapshotIDs + aniMapCandidateIds + relocationCandidates.compactMap(\.anilistId))).sorted()
        if !snapshotIDs.isEmpty {
            let nodeResult = await batchFetchAniListStructureNodesResult(ids: snapshotIDs)
            try Task.checkCancellation()
            let relocatedMappings = await provenRelocatedMappings(
                relocationCandidates, nodesByID: nodeResult.nodes, tmdbShowId: tmdbShowId,
                tvShowDetail: tvShowDetail, plan: aniMapSeedPlan, tmdbService: tmdbService
            )
            try Task.checkCancellation()
            if !relocatedMappings.isEmpty {
                aniMapSeedPlan = AniMapSeasonSeedPlan(
                    mappings: aniMapSeedPlan.mappings,
                    mappingInventory: aniMapSeedPlan.mappingInventory + relocatedMappings,
                    snapshotIDs: aniMapSeedPlan.snapshotIDs + relocatedMappings.compactMap(\.anilistId),
                    isComplete: aniMapSeedPlan.isComplete,
                    hasUnresolvedIdentity: aniMapSeedPlan.hasUnresolvedIdentity
                )
            }
            aniMapNodesByID = nodeResult.nodes
            ordinarySeasonCounts = ordinaryMappedSeasonCounts(aniMapSeedPlan.mappingInventory, nodesByID: nodeResult.nodes)
            aniMapSeedPlan = refinedSeasonSeedPlan(aniMapSeedPlan, tmdbShowId: tmdbShowId, nodesByID: nodeResult.nodes,
                tmdbSeasonEpisodeCounts: actualSeasonCounts, ordinarySeasonCounts: ordinarySeasonCounts)
            let placementCandidates = nodeResult.nodes.values.map { node in
                AnimeStructureCourPlacementCandidate(id: node.id,
                    mappedTMDBSeason: aniMapSeedPlan.mapping(for: node.id)?.tmdbSeason,
                    episodeCount: node.episodes, format: node.format, status: node.status,
                    startDate: node.startDate?.exactDateString, endDate: node.endDate?.exactDateString,
                    titles: AniListTitlePicker.titleCandidates(from: node.title),
                    hasTrustedIdentity: aniMapSeedPlan.mappingInventory.contains { $0.anilistId == node.id && $0.tmdbShowId == tmdbShowId })
            }
            contradictedMappedSpecialIDs = AnimeStructurePolicy.contradictedMappedSpecialIDs(
                candidates: placementCandidates,
                mappingsByID: Dictionary(aniMapSeedPlan.mappingInventory.compactMap { mapping in
                    mapping.anilistId.map { ($0, mapping) }
                }, uniquingKeysWith: { first, _ in first }), tmdbShow: tvShowDetail)
            if !contradictedMappedSpecialIDs.isEmpty {
                aniMapSeedPlan = AniMapSeasonSeedPlan(mappings: aniMapSeedPlan.mappings.filter {
                    $0.anilistId.map { !contradictedMappedSpecialIDs.contains($0) } ?? true
                }, mappingInventory: aniMapSeedPlan.mappingInventory, snapshotIDs: aniMapSeedPlan.snapshotIDs,
                    isComplete: aniMapSeedPlan.isComplete, hasUnresolvedIdentity: aniMapSeedPlan.hasUnresolvedIdentity)
            }
            aniMapCandidateIds = aniMapSeedPlan.ids
            if let seedAniListId, seedAniListId > 0, !aniMapCandidateIds.contains(seedAniListId) {
                aniMapCandidateIds.insert(seedAniListId, at: 0)
            }
            await logDetailTiming(
                "structure-nodes",
                fields: "requested=\(snapshotIDs.count) resolved=\(nodeResult.nodes.count)"
            )
            candidates = aniMapCandidateIds.compactMap { nodeResult.nodes[$0] }
            let hydratedCandidateCount = candidates.count
            let normalSeasonCandidates = candidates.filter { candidate in
                isMappedAniListSeasonCandidate(candidate, mapping: aniMapSeedPlan.mapping(for: candidate.id), tmdbSeasonEpisodeCounts: actualSeasonCounts, ordinarySeasonCounts: ordinarySeasonCounts)
                    || (AnimeRelationRolePolicy.isExactSelectedRegularEntry(
                        mediaID: candidate.id, selectedMediaID: seedAniListId, mediaFormat: candidate.format
                    ) && !aniMapSeedPlan.mappingInventory.contains(where: { $0.anilistId == candidate.id })
                        && matchesTMDBRootIdentity(candidate, detail: tvShowDetail))
            }
            if !candidates.isEmpty, normalSeasonCandidates.isEmpty {
                Logger.shared.log("AniListService: AniMap hydrated \(candidates.count) nodes for tmdbId=\(tmdbShowId), but none looked like normal anime seasons; falling back to title search", type: "AniList")
                candidates = []
            } else if !normalSeasonCandidates.isEmpty {
                candidates = normalSeasonCandidates
            }
            if candidates.isEmpty, hydratedCandidateCount == 0 {
                Logger.shared.log("AniListService: AniMap returned \(aniMapCandidateIds.count) mapped regular AniList IDs for tmdbId=\(tmdbShowId), but none hydrated from AniList", type: "AniList")
            } else if !candidates.isEmpty {
                Logger.shared.log("AniListService: AniMap seeded \(candidates.count)/\(aniMapCandidateIds.count) AniList candidates for tmdbId=\(tmdbShowId)", type: "AniList")
            }
        }

        if candidates.isEmpty {
        let query = """
        query ($search: String) {
            Page(perPage: 6) {
                media(search: $search, type: ANIME, sort: POPULARITY_DESC) {
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
                    startDate { year month day }
                    endDate { year month day }
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
                                startDate { year month day }
                                endDate { year month day }
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
                                            startDate { year month day }
                                            endDate { year month day }
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

        struct Response: Codable {
            let data: DataWrapper
            struct DataWrapper: Codable {
                let Page: PageData
                struct PageData: Codable { let media: [AniListAnime] }
            }
        }

        func searchAniListDetails(_ searchTitle: String) async throws -> [AniListAnime] {
            try Task.checkCancellation()
            Logger.shared.log(
                "AniListService: Sending AniList GraphQL query for '\(searchTitle)'",
                type: "AniList"
            )
            let response = try await executeGraphQLQuery(
                query,
                token: token,
                variables: ["search": searchTitle]
            )
            return try JSONDecoder().decode(Response.self, from: response).data.Page.media
        }

        let directSearchTitles = AniListTitlePicker.detailSearchCandidates(
            primaryTitle: title,
            localizedTitle: tvShowDetail?.name,
            originalTitle: tvShowDetail?.originalName,
            preferredLocaleIdentifier: tmdbMatchCacheLanguage
        )
        var detailSearchResponses: [(searchTitle: String, candidates: [AniListAnime])] = []

        func applyPreferredDetailSearchResponse(
            authoritativeTitles: [String],
            allowsFuzzyFallback: Bool
        ) -> Bool {
            let responseCandidateTitles = detailSearchResponses.map { response in
                response.candidates.map {
                    AniListTitlePicker.titleCandidates(from: $0.title)
                }
            }
            guard let selection = AniListTitlePicker.detailSearchSelection(
                responseCandidateTitles: responseCandidateTitles,
                searchedTitles: detailSearchResponses.map { $0.searchTitle },
                authoritativeTitles: authoritativeTitles
            ), selection.isExact || allowsFuzzyFallback,
               detailSearchResponses.indices.contains(selection.responseIndex) else {
                return false
            }
            let response = detailSearchResponses[selection.responseIndex]
            candidates = selection.candidateIndexes.compactMap { index in
                response.candidates.indices.contains(index) ? response.candidates[index] : nil
            }
            guard !candidates.isEmpty else { return false }
            if selection.isExact {
                if response.searchTitle != title {
                    Logger.shared.log(
                        "AniListService: Exact title fallback matched '\(response.searchTitle)' after '\(title)' returned no exact candidates",
                        type: "AniList"
                    )
                }
            } else {
                Logger.shared.log(
                    "AniListService: Using fuzzy compatibility fallback from '\(response.searchTitle)' after exhausting exact title aliases",
                    type: "AniList"
                )
            }
            return true
        }

        for searchTitle in directSearchTitles {
            let responseCandidates = try await searchAniListDetails(searchTitle)
            detailSearchResponses.append((searchTitle, responseCandidates))
            if applyPreferredDetailSearchResponse(
                authoritativeTitles: directSearchTitles,
                allowsFuzzyFallback: false
            ) {
                break
            }
        }

        if candidates.isEmpty {
            let alternativeTitles = (try? await tmdbService.getTVShowAlternativeTitles(id: tmdbShowId))?
                .results ?? []
            try Task.checkCancellation()
            let fallbackSearchTitles = AniListTitlePicker.detailSearchCandidates(
                primaryTitle: title,
                localizedTitle: tvShowDetail?.name,
                originalTitle: tvShowDetail?.originalName,
                preferredLocaleIdentifier: tmdbMatchCacheLanguage,
                alternativeTitles: alternativeTitles
            )
            if !applyPreferredDetailSearchResponse(
                authoritativeTitles: fallbackSearchTitles,
                allowsFuzzyFallback: false
            ) {
                let searchedTitles = Set(detailSearchResponses.map { $0.searchTitle })
                for searchTitle in fallbackSearchTitles where !searchedTitles.contains(searchTitle) {
                    let responseCandidates = try await searchAniListDetails(searchTitle)
                    detailSearchResponses.append((searchTitle, responseCandidates))
                    if applyPreferredDetailSearchResponse(
                        authoritativeTitles: fallbackSearchTitles,
                        allowsFuzzyFallback: false
                    ) {
                        break
                    }
                }
            }
            if candidates.isEmpty {
                _ = applyPreferredDetailSearchResponse(
                    authoritativeTitles: fallbackSearchTitles,
                    allowsFuzzyFallback: true
                )
            }
        }
        }
        Logger.shared.log("AniListService: AniList returned \(candidates.count) candidates for '\(title)'", type: "AniList")
        guard !candidates.isEmpty else {
            Logger.shared.log("AniListService: NO candidates from AniList for '\(title)' - throwing", type: "Error")
            throw NSError(domain: "AniListService", code: -1, userInfo: [NSLocalizedDescriptionKey: "AniList did not return any matches for \(title)"])
        }

        var anime = seedAniListId.flatMap { seed in candidates.first { $0.id == seed } }
            ?? pickBestAniListMatch(from: candidates, tmdbShow: tvShowDetail)
        let tmdbInventoryEpisodeCount = actualSeasonCounts.flatMap {
            RemoteMediaNumericBoundary.boundedSum($0.values)
        } ?? tvShowDetail?.numberOfEpisodes
        var independentlyDetachedFeatureIDs = Set<Int>()
        var independentlyVerifiedOpenEndedInventory: TMDBAbsoluteEpisodeHydration?
        func fitsRegularInventory(_ entry: AniListAnime) -> Bool {
            if contradictedMappedSpecialIDs.contains(entry.id) || independentlyDetachedFeatureIDs.contains(entry.id) { return false }
            let identityMappings = aniMapSeedPlan.mappingInventory.filter { $0.anilistId == entry.id }
            if identityMappings.contains(where: { $0.tmdbShowId != nil && $0.tmdbShowId != tmdbShowId }),
               !identityMappings.contains(where: { $0.tmdbShowId == tmdbShowId }) { return false }
            let sameShowMappings = identityMappings.filter { $0.tmdbShowId == tmdbShowId }
            if !sameShowMappings.isEmpty,
               sameShowMappings.allSatisfy({ $0.tmdbSeason == 0 || ($0.tmdbSeason == nil && $0.tvdbSeason == 0) }) { return false }
            let isMappedRegular = aniMapSeedPlan.mappingInventory.contains { mapping in
                mapping.anilistId == entry.id && mapping.tmdbShowId == tmdbShowId
                    && AniMapStructuralRole.isRegularStory(mapping, fallbackMediaType: entry.format,
                        tmdbSeasonEpisodeCounts: actualSeasonCounts, episodeCount: entry.episodes,
                        regularStoryEpisodeCounts: ordinarySeasonCounts)
            }
            return AnimeRelationRolePolicy.fitsRegularTMDBInventory(
                isMappedRegular: isMappedRegular, episodeCount: entry.episodes,
                status: entry.status, tmdbEpisodeCount: tmdbInventoryEpisodeCount
            )
        }
        func admitsHydratedRegularNode(_ entry: AniListAnime, relationType: String) -> Bool {
            guard fitsRegularInventory(entry) else { return false }
            let mapped = isMappedAniListSeasonCandidate(entry, mapping: aniMapSeedPlan.mapping(for: entry.id),
                tmdbSeasonEpisodeCounts: actualSeasonCounts, ordinarySeasonCounts: ordinarySeasonCounts)
            return AnimeRelationRolePolicy.admitsHydratedRegularNode(relationType: relationType,
                mediaFormat: entry.format, isMappedRegular: mapped, episodeCount: entry.episodes,
                status: entry.status, tmdbEpisodeCount: tmdbInventoryEpisodeCount)
        }
        let mappingContainsAuthoritativeSeed = seedAniListId.map(aniMapSeedPlan.ids.contains) ?? true
        let validatedMappedStructure = mappingContainsAuthoritativeSeed
            ? validatedAniMapStructure(
                plan: aniMapSeedPlan,
                nodesByID: aniMapNodesByID,
                tvShowDetail: tvShowDetail,
                allowPreviewCoverage: hydrationPolicy == .initiallyVisible,
                ordinarySeasonCounts: ordinarySeasonCounts
            )
            : nil
        let mappedIdentityRoster = mappingContainsAuthoritativeSeed
            ? hydratedAniMapIdentityRoster(plan: aniMapSeedPlan, nodesByID: aniMapNodesByID,
                tvShowDetail: tvShowDetail, ordinarySeasonCounts: ordinarySeasonCounts)
            : nil
        let mappedStoryRoster = validatedMappedStructure ?? mappedIdentityRoster
        let mappedStoryIDs = Set((mappedStoryRoster ?? []).map(\.id))
        let mappedStoryRosterHasCompleteInventory = mappedStoryRoster.map { roster in
            AnimeStructurePolicy.hasCompleteMappedIdentityInventory(
                lookupIsComplete: aniMapSeedPlan.isComplete, hasUnresolvedIdentity: aniMapSeedPlan.hasUnresolvedIdentity,
                episodeCounts: roster.map(\.episodes), statuses: roster.map(\.status),
                tmdbSeasonEpisodeCounts: actualSeasonCounts ?? [:])
        } ?? false
        let mappedStoryRosterIsClosed = mappedStoryRosterHasCompleteInventory || (mappedStoryRoster.map { roster in
            roster.allSatisfy { entry in
                entry.relations.map { relations in
                    !relations.edges.contains { edge in
                        ["SEQUEL", "PREQUEL", "SEASON"].contains(edge.relationType.uppercased())
                            && (edge.node.type == nil || edge.node.type == "ANIME")
                            && !mappedStoryIDs.contains(edge.node.id)
                            && (edge.node.format.map {
                                !["SPECIAL", "OVA", "OAD", "MOVIE", "MUSIC", "MANGA", "NOVEL", "ONE_SHOT"].contains($0.uppercased())
                            } ?? true)
                    }
                } ?? false
            }
        } ?? false)
        let relatedLookupRoot = mappedStoryRoster?.first ?? anime
        let mappedSeasonNumbers = Set(aniMapSeedPlan.mappings.compactMap { mapping in
            mapping.tmdbSeason.flatMap { $0 > 0 ? $0 : nil }
        })
        if AnimeStructurePolicy.shouldPrefetchRelatedNodeLookup(
            rosterIsClosed: mappedStoryRosterIsClosed,
            startsVerifiedInventoryEarly: startsVerifiedInventoryEarly,
            lookupIsComplete: aniMapSeedPlan.isComplete,
            hasUnresolvedIdentity: aniMapSeedPlan.hasUnresolvedIdentity,
            mappedRosterCount: mappedStoryRoster?.count ?? 0,
            mappedSeasonNumbers: mappedSeasonNumbers,
            hasExactRootIdentity: matchesTMDBRootIdentity(relatedLookupRoot, detail: tvShowDetail),
            rootEpisodeCount: relatedLookupRoot.episodes,
            rootFormat: relatedLookupRoot.format,
            rootStatus: relatedLookupRoot.status,
            tmdbSeasonEpisodeCounts: actualSeasonCounts ?? [:]
        ), let tvShowDetail {
            let lookup = await supplementalStructureNodeLookup(title: tvShowDetail.name, token: token)
            try Task.checkCancellation()
            aniMapNodesByID.merge(lookup, uniquingKeysWith: { first, _ in first })
        }
        await logDetailTiming(
            "structure-validation",
            fields: "accepted=\(validatedMappedStructure != nil) candidates=\(candidates.count)"
        )

        if let firstMapped = mappedStoryRoster?.first {

            anime = firstMapped
        }

        if validatedMappedStructure == nil,
           anime.id != seedAniListId,
           !matchesTMDBRootIdentity(anime, detail: tvShowDetail),
           let tmdbEps = tvShowDetail?.numberOfEpisodes, tmdbEps > 12,
           let selectedEps = anime.episodes, selectedEps < tmdbEps / 4 {
            Logger.shared.log("AniListService: Match looks suspicious (\(selectedEps) eps vs TMDB \(tmdbEps)) \u{2014} checking relation edges for main series", type: "AniList")
            let parentRelTypes: Set<String> = ["PARENT", "SOURCE", "PREQUEL"]
            let tvFormats: Set<String> = ["TV", "TV_SHORT", "ONA"]
            if let edges = anime.relations?.edges {
                let betterNode = edges
                    .filter { parentRelTypes.contains($0.relationType) && $0.node.type == "ANIME" }
                    .filter { fitsRegularInventory($0.node.asAnime()) }
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

        if validatedMappedStructure == nil, anime.relations == nil {
            if let enriched = (await batchFetchAniListNodes(ids: [anime.id]))[anime.id] {
                anime = enriched
            }
            try Task.checkCancellation()
        }

        let knownRegularOwnerIDs = Set(aniMapSeedPlan.mappingInventory.compactMap { mapping -> Int? in
            guard mapping.tmdbShowId == tmdbShowId,
                  AniMapStructuralRole.isRegularStory(mapping, tmdbSeasonEpisodeCounts: actualSeasonCounts) else { return nil }
            return mapping.anilistId
        })
        if mappedStoryRoster == nil, matchesTMDBRootIdentity(anime, detail: tvShowDetail),
           anime.startDate?.exactDateString == tvShowDetail?.firstAirDate,
           let counts = actualSeasonCounts, (1...64).contains(counts.count),
           let featureCandidateID = AnimeExternalFeatureOwnershipPolicy.featurePrequelCandidateID(
            root: anime, selectedAniListID: seedAniListId, knownRegularOwnerIDs: knownRegularOwnerIDs
           ) {
            var featureNode = aniMapNodesByID[featureCandidateID]
                ?? candidates.first { $0.id == featureCandidateID }
            if featureNode?.relations == nil {
                featureNode = (await batchFetchAniListNodes(ids: [featureCandidateID]))[featureCandidateID]
            }
            if let featureCandidate = AnimeExternalFeatureOwnershipPolicy.featurePrequelCandidate(
                root: anime, selectedAniListID: seedAniListId, knownRegularOwnerIDs: knownRegularOwnerIDs,
                hydratedCandidate: featureNode
            ), seedMALId.map({ $0 != featureCandidate.idMal }) ?? true,
               let searchTitle = featureCandidate.title.english ?? featureCandidate.title.native ?? featureCandidate.title.romaji {
                async let fullInventory = fetchTMDBEpisodesByAbsolute(
                    tmdbShowId: tmdbShowId, tvShowDetail: tvShowDetail, tmdbService: tmdbService,
                    allowsSummaryCoordinateFallback: false
                )
                if let searchResults = try? await tmdbService.searchMovies(query: searchTitle),
                   let movieID = AnimeExternalFeatureOwnershipPolicy.uniqueMovieID(candidate: featureCandidate, movies: searchResults),
                   let movie = try? await tmdbService.getMovieDetails(id: movieID), movie.id == movieID {
                    let inventory = await fullInventory
                    if let rows = AnimeExternalFeatureOwnershipPolicy.validatedOpenEndedInventory(
                        hasExactRootIdentity: true, root: anime, tmdbSeasonEpisodeCounts: counts,
                        sourceEpisodes: Array(inventory.episodes.values)
                    ), let filmIMDbID = TMDBService.EpisodeExternalIdentity.validatedIMDbID(movie.imdbId),
                       let coincidentRows = AnimeExternalFeatureOwnershipPolicy.coincidentEpisodeIdentityCandidates(
                        candidate: featureCandidate, movie: movie, sourceEpisodes: rows
                       ) {
                        async let exclusiveFilmIdentity = try? tmdbService.hasExclusiveMovieIMDbIdentity(filmIMDbID, expectedMovieID: movie.id)
                        let episodeIdentities = await withTaskGroup(of: (Int, String?).self) { group in
                            for episode in coincidentRows {
                                group.addTask {
                                    guard !Task.isCancelled,
                                          let identity = try? await tmdbService.getEpisodeExternalIdentity(
                                            tvShowId: tmdbShowId, seasonNumber: episode.seasonNumber,
                                            episodeNumber: episode.episodeNumber, expectedEpisodeID: episode.id
                                          ) else { return (episode.id, nil) }
                                    return (episode.id, identity.imdbID)
                                }
                            }
                            var identities: [Int: String] = [:]
                            for await (id, imdbID) in group {
                                if Task.isCancelled { group.cancelAll(); break }
                                if let imdbID { identities[id] = imdbID }
                            }
                            return identities
                        }
                        if await exclusiveFilmIdentity == true,
                           AnimeExternalFeatureOwnershipPolicy.isDetachedFeaturePrequel(
                            candidate: featureCandidate, root: anime, movie: movie, selectedAniListID: seedAniListId,
                            hasSameShowPlacement: knownRegularOwnerIDs.contains(featureCandidate.id),
                            tmdbSeasonEpisodeCounts: counts, sourceEpisodes: rows, exclusiveMovieID: movie.id,
                            independentlyDistinctEpisodeIMDbIDs: episodeIdentities
                           ) {
                            independentlyDetachedFeatureIDs.insert(featureCandidate.id)
                            independentlyVerifiedOpenEndedInventory = TMDBAbsoluteEpisodeHydration(
                                episodes: Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.offset + 1, $0.element) }),
                                coordinates: Dictionary(uniqueKeysWithValues: rows.enumerated().map {
                                    ($0.offset + 1, TMDBEpisodeCoordinate(seasonNumber: $0.element.seasonNumber, episodeNumber: $0.element.episodeNumber))
                                })
                            )
                        }
                    }
                }
                try Task.checkCancellation()
            }
        }

        let title = AniListTitlePicker.title(from: anime.title, preferredLanguageCode: preferredLanguageCode)
        Logger.shared.log("AniListService: Selected AniList match '\(title)' (id: \(anime.id))", type: "AniList")
        let seasonVal = anime.season ?? "UNKNOWN"
        Logger.shared.log(
            "AniListService: Raw response - episodes: \(anime.episodes ?? 0), seasonYear: \(anime.seasonYear ?? 0), season: \(seasonVal)",
            type: "AniList"
        )

        var allAnimeToProcess: [(anime: AniListAnime, seasonOffset: Int, posterUrl: String?)] = []

        func appendAnime(_ entry: AniListAnime) {
            let poster = entry.coverImage?.preferredURL() ?? tmdbShowPoster
            allAnimeToProcess.append((entry, 0, poster))
        }

        if let mappedStoryRoster {
            mappedStoryRoster.forEach(appendAnime)
            let activeIDs = Set(mappedStoryRoster.map(\.id))
            for id in aniMapSeedPlan.ids where !activeIDs.contains(id) {
                guard let upcoming = aniMapNodesByID[id],
                      upcoming.status?.uppercased() == "NOT_YET_RELEASED",
                      let mapping = aniMapSeedPlan.mapping(for: id),
                      AniMapStructuralRole.isRegularStory(mapping, fallbackMediaType: upcoming.format, tmdbSeasonEpisodeCounts: actualSeasonCounts) else { continue }
                appendAnime(upcoming)
            }
        } else {
            appendAnime(anime)
        }

        Logger.shared.log("AniListService: Starting sequel detection for \(AniListTitlePicker.title(from: anime.title, preferredLanguageCode: preferredLanguageCode)) (ID: \(anime.id), episodes: \(anime.episodes ?? 0), relations: \(anime.relations?.edges.count ?? 0))", type: "AniList")

        let allowedRelationTypes: Set<String> = ["SEQUEL", "PREQUEL", "SEASON"]

        var queue: [AniListAnime] = validatedMappedStructure != nil || mappedStoryRosterIsClosed
            ? [] : mappedStoryRoster ?? [anime]
        var seenIds = Set<Int>(allAnimeToProcess.map { $0.anime.id })
        var exactSelectedContinuationIDs = Set<Int>()
        let traversalExpectedSeasonCounts = RemoteMediaNumericBoundary.seasonEpisodeCounts(
            (tvShowDetail?.seasons ?? []).compactMap { season in
                guard season.seasonNumber > 0, season.episodeCount > 0 else { return nil }
                return (season.seasonNumber, season.episodeCount)
            }
        )

        func coverageSegment(for entry: AniListAnime) -> AnimeStructureCoverageSegment {
            AnimeStructureCoverageSegment(
                mappedTMDBSeason: aniMapSeedPlan.mapping(for: entry.id)?
                    .tmdbSeason
                    .flatMap { $0 > 0 ? $0 : nil },
                episodeCount: entry.episodes
            )
        }

        func currentCoverageSegments() -> [AnimeStructureCoverageSegment] {
            allAnimeToProcess.map { coverageSegment(for: $0.anime) }
        }

        if AnimeRelationRolePolicy.isExactSelectedRegularEntry(
            mediaID: anime.id,
            selectedMediaID: seedAniListId,
            mediaFormat: anime.format
        ), anime.relations?.edges.contains(where: {
            $0.relationType.uppercased() == "PREQUEL" && $0.node.type == "ANIME"
        }) == true {
            exactSelectedContinuationIDs.insert(anime.id)
        }

        while !queue.isEmpty {
            try Task.checkCancellation()
            let currentLevel = queue
            queue.removeAll()

            var idsToFetch: [Int] = []
            var shallowNodes: [Int: AniListAnime.AniListRelationNode] = [:]
            var relationTypesByID: [Int: String] = [:]

            for current in currentLevel {
                let currentTitle = AniListTitlePicker.title(from: current.title, preferredLanguageCode: preferredLanguageCode)
                let edges = current.relations?.edges ?? []
                Logger.shared.log("AniListService: Checking relations for '\(currentTitle)': \(edges.count) edges total", type: "AniList")

                for edge in edges {
                    guard allowedRelationTypes.contains(edge.relationType), edge.node.type == "ANIME" else {
                        continue
                    }
                    guard fitsRegularInventory(edge.node.asAnime()) else { continue }
                    let isExactSelectedContinuation = edge.relationType.uppercased() == "SEQUEL"
                        && AnimeRelationRolePolicy.isExactSelectedRegularEntry(
                            mediaID: edge.node.id,
                            selectedMediaID: seedAniListId,
                            mediaFormat: edge.node.format
                        )
                    let continuationSegment = coverageSegment(for: edge.node.asAnime())
                    let continuationFormat = AnimeRelationRolePolicy.regularContinuationFormat(
                        mediaFormat: edge.node.format, mapping: aniMapSeedPlan.mapping(for: edge.node.id), tmdbShowId: tmdbShowId
                    )
                    let retainsUpcomingIdentity = AnimeRelationRolePolicy.retainsUpcomingIdentity(
                        relationType: edge.relationType, mediaFormat: continuationFormat, status: edge.node.status
                    )
                    let admitsUpcomingContinuation = traversalExpectedSeasonCounts.map {
                        AnimeStructurePolicy.admitsUpcomingContinuation(
                            relationType: edge.relationType,
                            mediaFormat: continuationFormat,
                            status: edge.node.status,
                            tmdbSeasonEpisodeCounts: $0,
                            currentSegments: currentCoverageSegments(),
                            continuationSegment: continuationSegment
                        )
                    } ?? false
                    if edge.node.status?.uppercased() == "NOT_YET_RELEASED",
                       !isExactSelectedContinuation,
                       !admitsUpcomingContinuation,
                       !retainsUpcomingIdentity {
                        continue
                    }
                    if let format = edge.node.format,
                       !(format == "TV" || format == "TV_SHORT" || format == "ONA") {
                        let mapping = aniMapSeedPlan.mapping(for: edge.node.id)
                        guard isMappedAniListSeasonCandidate(edge.node.asAnime(), mapping: mapping, tmdbSeasonEpisodeCounts: actualSeasonCounts, ordinarySeasonCounts: ordinarySeasonCounts) else {
                            continue
                        }
                    }
                    if !seenIds.insert(edge.node.id).inserted {
                        continue
                    }
                    if isExactSelectedContinuation {
                        exactSelectedContinuationIDs.insert(edge.node.id)
                    }

                    let edgeTitle = AniListTitlePicker.title(from: edge.node.title, preferredLanguageCode: preferredLanguageCode)
                    Logger.shared.log("    \u{2192} Added sequel: \(edgeTitle)", type: "AniList")

                    if retainsUpcomingIdentity {
                        let upcoming = aniMapNodesByID[edge.node.id] ?? edge.node.asAnime()
                        guard upcoming.id == edge.node.id,
                              admitsHydratedRegularNode(upcoming, relationType: edge.relationType) else { continue }
                        appendAnime(upcoming)
                        if upcoming.status?.uppercased() != "NOT_YET_RELEASED", upcoming.relations != nil {
                            queue.append(upcoming)
                        }
                        continue
                    }

                    let canUseShallowContinuation = traversalExpectedSeasonCounts.map {
                        AnimeStructurePolicy.canUseShallowTerminalContinuation(
                            hydrationPolicy: hydrationPolicy,
                            relationType: edge.relationType,
                            mediaFormat: continuationFormat,
                            tmdbSeasonEpisodeCounts: $0,
                            currentSegments: currentCoverageSegments(),
                            continuationSegment: continuationSegment,
                            continuationStatus: edge.node.status
                        )
                    } ?? false
                    if let seededNode = aniMapNodesByID[edge.node.id],
                       seededNode.relations != nil {
                        guard seededNode.id == edge.node.id,
                              admitsHydratedRegularNode(seededNode, relationType: edge.relationType) else { continue }
                        appendAnime(seededNode)
                        if seededNode.status?.uppercased() != "NOT_YET_RELEASED" { queue.append(seededNode) }
                    } else if edge.node.relations != nil {
                        let fullNode = edge.node.asAnime()
                        guard admitsHydratedRegularNode(fullNode, relationType: edge.relationType) else { continue }
                        appendAnime(fullNode)
                        if fullNode.status?.uppercased() != "NOT_YET_RELEASED" { queue.append(fullNode) }
                    } else if canUseShallowContinuation {
                        let fullNode = edge.node.asAnime()
                        guard admitsHydratedRegularNode(fullNode, relationType: edge.relationType) else { continue }
                        appendAnime(fullNode)
                    } else {
                        idsToFetch.append(edge.node.id)
                        shallowNodes[edge.node.id] = edge.node
                        relationTypesByID[edge.node.id] = edge.relationType
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
                    guard fullNode.id == id,
                          let relationType = relationTypesByID[id],
                          admitsHydratedRegularNode(fullNode, relationType: relationType) else { continue }
                    appendAnime(fullNode)
                    if fullNode.status?.uppercased() != "NOT_YET_RELEASED" { queue.append(fullNode) }
                }
            }
        }
        func orderAnimeEntries() {
            guard validatedMappedStructure == nil else { return }
            let orderedIDs = relationOrderedAnimeIDs(allAnimeToProcess.map(\.anime))
            let rank = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($0.element, $0.offset) })
            allAnimeToProcess.sort {
                (rank[$0.anime.id] ?? Int.max) < (rank[$1.anime.id] ?? Int.max)
            }
        }

        func reconciledCoverageSegments() -> [AnimeStructureCoverageSegment] {
            let segments = currentCoverageSegments()
            let graphSupportsCountInference = aniMapSeedPlan.isComplete
                && !aniMapSeedPlan.hasUnresolvedIdentity
                && Set(aniMapSeedPlan.ids).isSubset(of: Set(allAnimeToProcess.map { $0.anime.id }))
                && allAnimeToProcess.allSatisfy { $0.anime.relations != nil }
            let resolved = graphSupportsCountInference
                ? AnimeStructurePolicy.resolvingSingleUnknownMappedSeasonCounts(
                    tmdbSeasonEpisodeCounts: traversalExpectedSeasonCounts ?? [:],
                    segments: segments
                )
                : segments
            return AnimeStructurePolicy.reconcilingReleasingTailCount(
                tmdbSeasonEpisodeCounts: traversalExpectedSeasonCounts ?? [:],
                segments: resolved,
                terminalStatus: allAnimeToProcess.last?.anime.status
            )
        }

        orderAnimeEntries()
        let supplementalCoverageSegments = reconciledCoverageSegments()
        await logDetailTiming(
            "relation-traversal",
            fields: "used=\(validatedMappedStructure == nil) seasons=\(allAnimeToProcess.count)"
        )

        if validatedMappedStructure == nil,
           !mappedStoryRosterIsClosed,
           independentlyVerifiedOpenEndedInventory == nil,
           let tvShowDetail,
           !allAnimeToProcess.isEmpty,
           let tmdbTotalEps = tvShowDetail.numberOfEpisodes,
           let anilistTotalEps = RemoteMediaNumericBoundary.boundedSum(
            supplementalCoverageSegments.compactMap(\.episodeCount)
           ) {
            if AnimeStructurePolicy.hasKnownEpisodeDeficit(
                tmdbTotalEpisodeCount: tmdbTotalEps, segments: supplementalCoverageSegments
            ) {
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

                    var orphanCandidates: [AniListAnime] = []
                    for candidate in orphanDecoded.data.Page.media {
                        guard !seenIds.contains(candidate.id) else { continue }
                        guard fitsRegularInventory(candidate) else { continue }
                        guard candidate.type == "ANIME" else { continue }
                        if let format = candidate.format, !orphanAllowedFormats.contains(format) { continue }

                        let candidateTitle = AniListTitlePicker.title(from: candidate.title, preferredLanguageCode: preferredLanguageCode).lowercased()
                        let candidateRomaji = candidate.title.romaji?.lowercased() ?? ""
                        guard candidateTitle.contains(rootWords) || candidateRomaji.contains(rootWords) else { continue }

                        let checkTitle = candidateTitle + " " + candidateRomaji
                        if spinoffKeywords.contains(where: { checkTitle.contains($0) }) { continue }

                        orphanCandidates.append(candidate)
                    }

                    let lastKnownYear = allAnimeToProcess.compactMap { $0.anime.seasonYear }.max() ?? 0
                    let sortedOrphans = orphanCandidates
                        .filter { ($0.seasonYear ?? Int.max) >= lastKnownYear }
                        .sorted { ($0.seasonYear ?? Int.max) < ($1.seasonYear ?? Int.max) }
                    let rankedIDs = Set(sortedOrphans.map(\.id))
                    let rankedOrphans = sortedOrphans + orphanCandidates.filter { !rankedIDs.contains($0.id) }
                    let regularMappedIDs = Set(aniMapSeedPlan.mappings.compactMap { mapping -> Int? in
                        guard AniMapStructuralRole.isRegularStory(mapping) else { return nil }
                        return mapping.anilistId
                    })
                    let bestOrphan = await AnimeRelationRolePolicy.firstAdmittedSupplementalEntry(
                        candidates: rankedOrphans, regularMappedIDs: regularMappedIDs,
                        existingEntries: allAnimeToProcess.map(\.anime), prefetched: aniMapNodesByID
                    ) { id in
                        (await batchFetchAniListNodes(ids: [id]))[id]
                    }
                    try Task.checkCancellation()
                    if let bestOrphan, fitsRegularInventory(bestOrphan) {
                        seenIds.insert(bestOrphan.id)
                        appendAnime(bestOrphan)
                        Logger.shared.log("AniListService: Best orphan entry: '\(AniListTitlePicker.title(from: bestOrphan.title, preferredLanguageCode: preferredLanguageCode))' (id: \(bestOrphan.id), episodes: \(bestOrphan.episodes ?? 0))", type: "AniList")
                        var orphanQueue: [AniListAnime] = [bestOrphan]
                        while !orphanQueue.isEmpty {
                            try Task.checkCancellation()
                            let currentOrphanLevel = orphanQueue
                            orphanQueue.removeAll()

                            var orphanIdsToFetch: [Int] = []
                            var orphanShallowNodes: [Int: AniListAnime.AniListRelationNode] = [:]
                            var orphanRelationTypesByID: [Int: String] = [:]

                            for current in currentOrphanLevel {
                                let edges = current.relations?.edges ?? []
                                for edge in edges {
                                    guard allowedRelationTypes.contains(edge.relationType), edge.node.type == "ANIME" else {
                                        continue
                                    }
                                    guard fitsRegularInventory(edge.node.asAnime()) else { continue }
                                    if edge.node.status == "NOT_YET_RELEASED" { continue }
                                    if let format = edge.node.format,
                                       !(format == "TV" || format == "TV_SHORT" || format == "ONA") {
                                        let mapping = aniMapSeedPlan.mapping(for: edge.node.id)
                                        guard isMappedAniListSeasonCandidate(edge.node.asAnime(), mapping: mapping, tmdbSeasonEpisodeCounts: actualSeasonCounts, ordinarySeasonCounts: ordinarySeasonCounts) else {
                                            continue
                                        }
                                    }
                                    if !seenIds.insert(edge.node.id).inserted { continue }

                                    let edgeTitle = AniListTitlePicker.title(from: edge.node.title, preferredLanguageCode: preferredLanguageCode)
                                    Logger.shared.log("    \u{2192} Added orphan sequel: \(edgeTitle)", type: "AniList")

                                    if edge.node.relations != nil {
                                        let fullNode = edge.node.asAnime()
                                        guard admitsHydratedRegularNode(fullNode, relationType: edge.relationType) else { continue }
                                        appendAnime(fullNode)
                                        orphanQueue.append(fullNode)
                                    } else {
                                        orphanIdsToFetch.append(edge.node.id)
                                        orphanShallowNodes[edge.node.id] = edge.node
                                        orphanRelationTypesByID[edge.node.id] = edge.relationType
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
                                    guard fullNode.id == id, fullNode.status?.uppercased() != "NOT_YET_RELEASED",
                                          let relationType = orphanRelationTypesByID[id],
                                          admitsHydratedRegularNode(fullNode, relationType: relationType) else { continue }
                                    appendAnime(fullNode)
                                    orphanQueue.append(fullNode)
                                }
                            }
                        }
                    }
                }
            }
        }

        orderAnimeEntries()

        var effectiveCoverageSegments = reconciledCoverageSegments()

        if let tvShowDetail,
           exactSelectedContinuationIDs.isDisjoint(with: allAnimeToProcess.map { $0.anime.id }),
           let tmdbTotalEps = tvShowDetail.numberOfEpisodes,
           let budget = RemoteMediaNumericBoundary.scaledEpisodeCount(
            tmdbTotalEps,
            numerator: 5,
            denominator: 4
           ),
           let anilistTotalEps = RemoteMediaNumericBoundary.boundedSum(
            effectiveCoverageSegments.map { $0.episodeCount ?? 0 }
           ) {
            if anilistTotalEps > budget {
                let rootIndex = allAnimeToProcess.firstIndex(where: { $0.anime.id == anime.id }) ?? 0
                let retainedIdentities = Set(allAnimeToProcess.indices.filter { index in
                    allAnimeToProcess[index].anime.status?.uppercased() == "NOT_YET_RELEASED"
                        || allAnimeToProcess[index].anime.id == seedAniListId
                        || seedMALId.map { allAnimeToProcess[index].anime.idMal == $0 } == true
                        || aniMapSeedPlan.ids.contains(allAnimeToProcess[index].anime.id)
                })
                let keptIndices = AnimeStructurePolicy.budgetedIndices(
                    episodeCounts: effectiveCoverageSegments.map(\.episodeCount),
                    rootIndex: rootIndex, episodeBudget: budget,
                    retainedIdentityIndices: retainedIdentities
                )
                let pruned = allAnimeToProcess.count - keptIndices.count
                if pruned > 0 {
                    Logger.shared.log("AniListService: Pruned \(pruned) entries that exceed TMDB episode budget (\(anilistTotalEps) AniList eps vs \(tmdbTotalEps) TMDB eps)", type: "AniList")
                    allAnimeToProcess = keptIndices.map { allAnimeToProcess[$0] }
                    effectiveCoverageSegments = reconciledCoverageSegments()
                }
            }
        }

        var traversedSnapshot: [Int: AniListAnime] = [:]
        for item in allAnimeToProcess where item.anime.relations != nil {
            traversedSnapshot[item.anime.id] = item.anime
        }
        await shallowSnapshotCache.store(traversedSnapshot)

        let summaryCoordinatesByAbsolute = tmdbEpisodeCoordinates(tvShowDetail: tvShowDetail)
        guard let expectedTMDBSeasonCounts = RemoteMediaNumericBoundary.seasonEpisodeCounts(
            (tvShowDetail?.seasons ?? []).compactMap { season in
                guard season.seasonNumber > 0, season.episodeCount > 0 else { return nil }
                return (season.seasonNumber, season.episodeCount)
            }
        ) else {
            throw NSError(
                domain: "AniListStructure",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "TMDB season structure exceeded the supported numeric boundary."]
            )
        }
        let coordinateCoverageSegments = effectiveCoverageSegments
        var allowsLinearTMDBCoordinates = AnimeStructurePolicy.allowsLinearTMDBCoordinates(
            hydrationPolicy: hydrationPolicy,
            tmdbSeasonEpisodeCounts: expectedTMDBSeasonCounts,
            segments: coordinateCoverageSegments,
            statuses: allAnimeToProcess.map { $0.anime.status }
        )

        let requiresVerifiedInventory = AnimeStructurePolicy.requiresVerifiedAbsoluteOrderInventory(
            tvdbSeasons: aniMapSeedPlan.mappings.map(\.tvdbSeason),
            tmdbSeasonCount: actualSeasonCounts?.count ?? 0
        ) || independentlyVerifiedOpenEndedInventory != nil
        let concurrentlyHydrated = await concurrentHydrationTask
        let tmdbHydration: TMDBAbsoluteEpisodeHydration
        if let verifiedInventory = independentlyVerifiedOpenEndedInventory {
            tmdbHydration = verifiedInventory
        } else if hydrationPolicy == .initiallyVisible && requiresVerifiedInventory {
            if let verifiedInventory = await verifiedInventoryTask {
                tmdbHydration = verifiedInventory
            } else {
                tmdbHydration = await fetchTMDBEpisodesByAbsolute(
                    tmdbShowId: tmdbShowId, tvShowDetail: tvShowDetail, tmdbService: tmdbService,
                    allowsSummaryCoordinateFallback: false
                )
            }
        } else if var concurrentlyHydrated {
            if requiresVerifiedInventory {
                let projected = AnimeSeasonEpisodeHydrationPolicy.hydrateTMDBInventory(
                    seasons: (tvShowDetail?.seasons ?? []).filter { $0.seasonNumber > 0 && $0.episodeCount > 0 },
                    fetchedEpisodesBySeason: Dictionary(grouping: Array(concurrentlyHydrated.episodes.values), by: \.seasonNumber),
                    allowsSummaryCoordinates: false
                )
                concurrentlyHydrated.episodes = projected.episodes
                concurrentlyHydrated.coordinates = projected.coordinates.mapValues {
                    TMDBEpisodeCoordinate(seasonNumber: $0.seasonNumber, episodeNumber: $0.episodeNumber)
                }
            }
            tmdbHydration = concurrentlyHydrated
        } else {
            let requiredHydrationRange: ClosedRange<Int>?
            switch hydrationPolicy {
            case .complete:
                requiredHydrationRange = nil
            case .initiallyVisible:
                let knownEpisodeCount = max(
                    summaryCoordinatesByAbsolute.count,
                    allAnimeToProcess.first?.anime.episodes ?? 0
                )

                requiredHydrationRange = knownEpisodeCount > 0
                    ? 1...min(100, knownEpisodeCount)
                    : nil
            }
            tmdbHydration = await fetchTMDBEpisodesByAbsolute(
                tmdbShowId: tmdbShowId,
                tvShowDetail: tvShowDetail,
                tmdbService: tmdbService,
                requiredAbsoluteRange: requiredHydrationRange,
                allowsSummaryCoordinateFallback: !requiresVerifiedInventory
            )
        }
        var tmdbEpisodesByAbsolute = tmdbHydration.episodes
        var tmdbCoordinatesByAbsolute = tmdbHydration.coordinates.isEmpty && !requiresVerifiedInventory
            ? summaryCoordinatesByAbsolute
            : tmdbHydration.coordinates
        var coordinateSeasonEpisodeCounts = expectedTMDBSeasonCounts
        let providerStartDates = allAnimeToProcess.map { $0.anime.startDate?.exactDateString }
        let providerStatuses = allAnimeToProcess.map { $0.anime.status }
        let prologueActiveEnd = providerStatuses.firstIndex {
            ["NOT_YET_RELEASED", "NOT_YET_AIRED"].contains($0?.uppercased() ?? "")
        } ?? providerStatuses.endIndex
        let hasContiguousUpcomingTail = providerStatuses[prologueActiveEnd...].allSatisfy {
            ["NOT_YET_RELEASED", "NOT_YET_AIRED"].contains($0?.uppercased() ?? "")
        }
        let prologueSegments = hasContiguousUpcomingTail
            ? Array(coordinateCoverageSegments.prefix(prologueActiveEnd)) : coordinateCoverageSegments
        let prologueStatuses = hasContiguousUpcomingTail ? Array(providerStatuses.prefix(prologueActiveEnd)) : providerStatuses
        let prologueStartDates = hasContiguousUpcomingTail ? Array(providerStartDates.prefix(prologueActiveEnd)) : providerStartDates
        let terminalIdentityIDs = Set(allAnimeToProcess.map { $0.anime.id })
        let terminalEntries = allAnimeToProcess.enumerated().map { index, item in
            let previous = index > 0 ? allAnimeToProcess[index - 1].anime : nil
            let followsPrevious = previous.map { prior in
                (prior.relations?.edges ?? []).contains {
                    ["SEQUEL", "SEASON"].contains($0.relationType.uppercased()) && $0.node.id == item.anime.id
                } || (item.anime.relations?.edges ?? []).contains {
                    ["PREQUEL", "SEASON"].contains($0.relationType.uppercased()) && $0.node.id == prior.id
                }
            } ?? false
            let mapping = aniMapSeedPlan.mappingInventory.first {
                $0.anilistId == item.anime.id && $0.tmdbShowId == tmdbShowId
                    && AniMapStructuralRole.isRegularStory($0, fallbackMediaType: item.anime.format,
                        tmdbSeasonEpisodeCounts: expectedTMDBSeasonCounts,
                        episodeCount: item.anime.episodes, regularStoryEpisodeCounts: ordinarySeasonCounts)
            }
            return AnimeTerminalSeasonProjectionPolicy.Entry(providerID: item.anime.id, mapping: mapping,
                episodeCount: item.anime.episodes, status: item.anime.status, format: item.anime.format,
                startDate: item.anime.startDate?.exactDateString, followsPrevious: followsPrevious)
        }
        let terminalHasCompetingOwner = allAnimeToProcess.contains { item in
            (item.anime.relations?.edges ?? []).contains { edge in
                ["SEQUEL", "SEASON"].contains(edge.relationType.uppercased()) && edge.node.type == "ANIME"
                    && !terminalIdentityIDs.contains(edge.node.id)
                    && (edge.node.format == nil || ["TV", "TV_SHORT", "ONA"].contains(edge.node.format?.uppercased() ?? ""))
                    && (edge.node.episodes == nil || ["RELEASING", "NOT_YET_RELEASED"].contains(edge.node.status?.uppercased() ?? ""))
            }
        }
        var verifiedTerminalEpisodesByID: [Int: [TMDBEpisode]] = [:]
        if let terminalSeason = AnimeTerminalSeasonProjectionPolicy.candidateSeasonNumber(
            tmdbShowId: tmdbShowId, entries: terminalEntries, tmdbSeasonEpisodeCounts: expectedTMDBSeasonCounts,
            hasCompetingOrdinaryOwner: terminalHasCompetingOwner
        ), let source = try? await tmdbService.getSeasonDetails(tvShowId: tmdbShowId, seasonNumber: terminalSeason) {
            verifiedTerminalEpisodesByID = AnimeTerminalSeasonProjectionPolicy.verifiedEpisodes(
                tmdbShowId: tmdbShowId, entries: terminalEntries, tmdbSeasonEpisodeCounts: expectedTMDBSeasonCounts,
                hasCompetingOrdinaryOwner: terminalHasCompetingOwner, sourceSeason: source,
                today: AnimeStructurePolicy.currentAirDateString()
            )
        }
        if AnimeStructurePolicy.mappedPrologueCandidateIndex(
            tmdbSeasonEpisodeCounts: expectedTMDBSeasonCounts, segments: prologueSegments,
            statuses: prologueStatuses, providerStartDates: prologueStartDates,
            sourceEpisodes: Array(tmdbEpisodesByAbsolute.values)
        ) != nil, let specials = try? await tmdbService.getSeasonDetails(tvShowId: tmdbShowId, seasonNumber: 0),
           let augmented = AnimeStructurePolicy.inventoryByAddingMappedPrologue(
            tmdbSeasonEpisodeCounts: expectedTMDBSeasonCounts, segments: prologueSegments,
            statuses: prologueStatuses, providerStartDates: prologueStartDates,
            sourceEpisodes: Array(tmdbEpisodesByAbsolute.values), specialEpisodes: specials.episodes
           ) {
            tmdbEpisodesByAbsolute = augmented.episodes
            tmdbCoordinatesByAbsolute = augmented.coordinates.mapValues {
                TMDBEpisodeCoordinate(seasonNumber: $0.seasonNumber, episodeNumber: $0.episodeNumber)
            }
            coordinateSeasonEpisodeCounts = augmented.seasonCounts
            allowsLinearTMDBCoordinates = AnimeStructurePolicy.allowsLinearTMDBCoordinates(
                hydrationPolicy: hydrationPolicy, tmdbSeasonEpisodeCounts: augmented.seasonCounts,
                segments: coordinateCoverageSegments, statuses: providerStatuses
            )
        }
        try Task.checkCancellation()
        let ordinaryIDs = Set(allAnimeToProcess.map { $0.anime.id })
        let curatedPrologueCandidates = allAnimeToProcess.enumerated().filter { index, item in
            AnimeVerifiedEpisodeZeroMappingPolicy.requiresEpisodeZero(
                tmdbShowId: tmdbShowId, aniListID: item.anime.id, malID: item.anime.idMal,
                episodeCount: item.anime.episodes, format: item.anime.format, status: item.anime.status,
                startDate: item.anime.startDate?.exactDateString, endDate: item.anime.endDate?.exactDateString,
                tmdbSeasonEpisodeCounts: expectedTMDBSeasonCounts)
                && coordinateCoverageSegments[index].mappedTMDBSeason == 2
                && coordinateCoverageSegments.filter { $0.mappedTMDBSeason == 2 }.count == 1
        }
        if curatedPrologueCandidates.count == 1, let item = curatedPrologueCandidates.first?.element,
           coordinateSeasonEpisodeCounts == expectedTMDBSeasonCounts,
           let specials = try? await tmdbService.getSeasonDetails(tvShowId: tmdbShowId, seasonNumber: 0),
           let prologue = AnimeVerifiedEpisodeZeroMappingPolicy.prologueEpisode(
            tmdbShowId: tmdbShowId, aniListID: item.anime.id, malID: item.anime.idMal,
            episodeCount: item.anime.episodes, format: item.anime.format, status: item.anime.status,
            startDate: item.anime.startDate?.exactDateString, endDate: item.anime.endDate?.exactDateString,
            regularEpisodes: Array(tmdbEpisodesByAbsolute.values), specialEpisodes: specials.episodes),
           let augmented = AnimeStructurePolicy.inventoryByInsertingEpisode(prologue, beforeSeason: 2,
            tmdbSeasonEpisodeCounts: expectedTMDBSeasonCounts, sourceEpisodes: Array(tmdbEpisodesByAbsolute.values)) {
            tmdbEpisodesByAbsolute = augmented.episodes
            tmdbCoordinatesByAbsolute = augmented.coordinates.mapValues {
                TMDBEpisodeCoordinate(seasonNumber: $0.seasonNumber, episodeNumber: $0.episodeNumber)
            }
            coordinateSeasonEpisodeCounts = augmented.seasonCounts
            allowsLinearTMDBCoordinates = AnimeStructurePolicy.allowsLinearTMDBCoordinates(
                hydrationPolicy: hydrationPolicy, tmdbSeasonEpisodeCounts: augmented.seasonCounts,
                segments: coordinateCoverageSegments, statuses: providerStatuses)
        }
        try Task.checkCancellation()
        var trustedCourIDs = Set(allAnimeToProcess.compactMap { item -> Int? in
            aniMapSeedPlan.mappingInventory.contains { mapping in
                mapping.anilistId == item.anime.id && mapping.tmdbShowId == tmdbShowId
                    && (mapping.tmdbSeason.map { $0 > 0 } == true || mapping.tvdbSeason == -1)
            } || matchesTMDBRootIdentity(item.anime, detail: tvShowDetail) ? item.anime.id : nil
        })
        for _ in allAnimeToProcess.indices {
            let previous = trustedCourIDs
            for item in allAnimeToProcess {
                for edge in item.anime.relations?.edges ?? [] where
                    ["SEQUEL", "PREQUEL", "SEASON"].contains(edge.relationType.uppercased())
                        && ordinaryIDs.contains(edge.node.id) {
                    if trustedCourIDs.contains(item.anime.id) { trustedCourIDs.insert(edge.node.id) }
                    if trustedCourIDs.contains(edge.node.id) { trustedCourIDs.insert(item.anime.id) }
                }
            }
            if previous == trustedCourIDs { break }
        }
        let exactOwnedSeasons = Set(coordinateCoverageSegments.indices.compactMap { index -> Int? in
            AnimeSeasonEpisodeHydrationPolicy.exactMappedSeasonStart(index: index,
                segments: coordinateCoverageSegments, tmdbSeasonEpisodeCounts: coordinateSeasonEpisodeCounts) != nil
                ? coordinateCoverageSegments[index].mappedTMDBSeason : nil
        })
        let containedCandidates = allAnimeToProcess.enumerated().compactMap { index, item -> AnimeStructureCourPlacementCandidate? in
            guard !allowsLinearTMDBCoordinates,
                  AnimeSeasonEpisodeHydrationPolicy.exactMappedSeasonStart(index: index,
                    segments: coordinateCoverageSegments, tmdbSeasonEpisodeCounts: coordinateSeasonEpisodeCounts) == nil else { return nil }
            return AnimeStructureCourPlacementCandidate(id: item.anime.id,
                mappedTMDBSeason: coordinateCoverageSegments[index].mappedTMDBSeason,
                episodeCount: item.anime.episodes, format: item.anime.format, status: item.anime.status,
                startDate: item.anime.startDate?.exactDateString, endDate: item.anime.endDate?.exactDateString,
                titles: AniListTitlePicker.titleCandidates(from: item.anime.title),
                hasTrustedIdentity: trustedCourIDs.contains(item.anime.id),
                nextIDs: Set((item.anime.relations?.edges ?? []).filter { $0.relationType.uppercased() == "SEQUEL" }.map { $0.node.id }),
                previousIDs: Set((item.anime.relations?.edges ?? []).filter { $0.relationType.uppercased() == "PREQUEL" }.map { $0.node.id }),
                hasTrustedMappedIdentity: aniMapSeedPlan.mappingInventory.contains {
                    $0.anilistId == item.anime.id && $0.tmdbShowId == tmdbShowId && $0.tmdbSeason.map { $0 > 0 } == true
                })
        }
        let containedSourceSeasons = await AnimeStructurePolicy.fetchCourSeasonDetails(
            candidates: containedCandidates, tmdbShow: tvShowDetail, tmdbService: tmdbService)
        var specialContinuationParentIDs = Set<Int>()
        for item in allAnimeToProcess {
            guard let mapping = aniMapSeedPlan.mapping(for: item.anime.id) else { continue }
            for edge in item.anime.relations?.edges ?? [] where edge.relationType.uppercased() == "SEQUEL" {
                let special = edge.node.asAnime()
                if !AnimeSpecialEpisodeHydrationPolicy.continuationEpisodes(
                    tmdbShowId: tmdbShowId, episodeCount: special.episodes, format: special.format,
                    status: special.status, exactReleaseDate: special.startDate?.exactDateString,
                    exactEndDate: special.endDate?.exactDateString,
                    parents: [.init(mapping: mapping, relationType: "SEQUEL", episodeCount: item.anime.episodes,
                        status: item.anime.status, format: item.anime.format,
                        startDate: item.anime.startDate?.exactDateString, endDate: item.anime.endDate?.exactDateString)],
                    seasonDetailsByNumber: containedSourceSeasons).isEmpty {
                    specialContinuationParentIDs.insert(item.anime.id)
                }
            }
        }
        var verifiedContainedEpisodesByID = AnimeStructurePolicy.verifiedContainedEpisodePlacements(
            candidates: containedCandidates, sourceSeasonEpisodeCounts: expectedTMDBSeasonCounts,
            sourceSeasonDetails: containedSourceSeasons, specialContinuationParentIDs: specialContinuationParentIDs
        ).filter { !$0.value.contains { exactOwnedSeasons.contains($0.seasonNumber) } }
        let supplementalPlacements = await mappedSupplementalEpisodePlacements(
            candidates: containedCandidates, aniListIDs: Dictionary(uniqueKeysWithValues: containedCandidates.map { ($0.id, $0.id) }),
            tvShowDetail: tvShowDetail, tmdbService: tmdbService, token: token)
        verifiedContainedEpisodesByID.merge(supplementalPlacements, uniquingKeysWith: { first, _ in first })
        let hasOrdinaryContinuationAmbiguity = allAnimeToProcess.contains { item in
            item.anime.relations.map { relations in
                relations.edges.contains { edge in
                    ["SEQUEL", "PREQUEL", "SEASON", "PARENT", "SOURCE", "ALTERNATIVE"]
                        .contains(edge.relationType.uppercased())
                        && !ordinaryIDs.contains(edge.node.id)
                        && (edge.node.type == nil || edge.node.type == "ANIME")
                        && (edge.node.format.map {
                            !["SPECIAL", "OVA", "OAD", "MOVIE", "MUSIC", "MANGA", "NOVEL", "ONE_SHOT"].contains($0.uppercased())
                        } ?? true)
                }
            } ?? true
        }
        let hasTrustedOrdinaryCourRoster = allAnimeToProcess.count == 1
            || (aniMapSeedPlan.isComplete && !aniMapSeedPlan.hasUnresolvedIdentity
                && ordinaryIDs.count == allAnimeToProcess.count
                && allAnimeToProcess.allSatisfy { item in
                    aniMapSeedPlan.mappingInventory.contains { mapping in
                        mapping.anilistId == item.anime.id && mapping.tmdbShowId == tmdbShowId
                            && AniMapStructuralRole.isRegularStory(mapping, fallbackMediaType: item.anime.format,
                                tmdbSeasonEpisodeCounts: actualSeasonCounts, episodeCount: item.anime.episodes,
                                regularStoryEpisodeCounts: ordinarySeasonCounts)
                    }
                })
        let verifiedOngoingCounts = AnimeStructurePolicy.verifiedOngoingEpisodeCounts(
            hasExactRootIdentity: allAnimeToProcess.first.map { matchesTMDBRootIdentity($0.anime, detail: tvShowDetail) } ?? false,
            hasTrustedOrdinaryCourRoster: hasTrustedOrdinaryCourRoster,
            hasOrdinaryContinuationAmbiguity: hasOrdinaryContinuationAmbiguity,
            mediaFormats: allAnimeToProcess.map { $0.anime.format },
            statuses: allAnimeToProcess.map { $0.anime.status },
            episodeCounts: allAnimeToProcess.map { $0.anime.episodes },
            providerStartDates: allAnimeToProcess.map { $0.anime.startDate?.exactDateString },
            tmdbSeasonEpisodeCounts: expectedTMDBSeasonCounts,
            sourceEpisodes: Array(tmdbEpisodesByAbsolute.values),
            today: AnimeStructurePolicy.currentAirDateString()
        )
        allowsLinearTMDBCoordinates = allowsLinearTMDBCoordinates || verifiedOngoingCounts != nil
        if !allowsLinearTMDBCoordinates {
            Logger.shared.log(
                "AniListService: withheld unverified linear TMDB coordinates tmdbId=\(tmdbShowId)",
                type: "Plugin"
            )
        }
        let hydrationCoordinates = tmdbCoordinatesByAbsolute.mapValues {
            AnimeStructureTMDBCoordinate(seasonNumber: $0.seasonNumber, episodeNumber: $0.episodeNumber)
        }
        let verifiedEpisodePlacementsByID = AnimeStructurePolicy.nonConflictingEpisodePlacements(
            verifiedContainedEpisodesByID.merging(verifiedTerminalEpisodesByID, uniquingKeysWith: { first, _ in first })
                .filter { !$0.value.contains { exactOwnedSeasons.contains($0.seasonNumber) } }
        )
        try Task.checkCancellation()
        await logDetailTiming(
            "episode-hydration",
            fields: "hydrated=\(tmdbEpisodesByAbsolute.count) concurrent=\(hydratesConcurrently)"
        )

        var openEndedWithheldCount: Int?
        if allAnimeToProcess.count == 1, let only = allAnimeToProcess.first?.anime, let tvShowDetail,
           verifiedEpisodePlacementsByID[only.id] == nil {
            let fillsMappedSeason = AnimeSeasonEpisodeHydrationPolicy.exactMappedSeasonStart(
                index: 0, segments: coordinateCoverageSegments, tmdbSeasonEpisodeCounts: coordinateSeasonEpisodeCounts
            ) != nil
            openEndedWithheldCount = await openEndedAiringConflictCount(
                anime: only, tmdbShowId: tmdbShowId, seasons: tvShowDetail.seasons,
                mappedSeason: fillsMappedSeason ? coordinateCoverageSegments.first?.mappedTMDBSeason : nil,
                tmdbService: tmdbService
            )
            try Task.checkCancellation()
        }

        var seasons: [AniListSeasonWithPoster] = []
        var currentAbsoluteEpisode = 1
        var seasonIndex = 1

        for (index, item) in allAnimeToProcess.enumerated() {
            let currentAnime = item.anime
            let posterUrl = item.posterUrl

            let seasonTitle = AniListTitlePicker.title(from: currentAnime.title, preferredLanguageCode: preferredLanguageCode)

            var unitEpisodes: [AniListEpisode]?
            var unitPosterURL: String?
            let uniqueCompilationOwner = AnimeVerifiedEpisodeUnitPolicy.hasNoKnownSaikiOwnerConflict(
                tmdbShowID: tmdbShowId, aniListID: currentAnime.id, malID: currentAnime.idMal,
                mappings: aniMapSeedPlan.mappingInventory, hasOtherProvedOwner: verifiedEpisodePlacementsByID.contains { identity, episodes in
                    identity != currentAnime.id && episodes.contains { $0.seasonNumber == 1 }
                })
            if AnimeVerifiedEpisodeUnitPolicy.requiresSaikiCompilations(
                tmdbShowID: tmdbShowId, aniListID: currentAnime.id, malID: currentAnime.idMal,
                episodeCount: currentAnime.episodes, format: currentAnime.format, status: currentAnime.status,
                startDate: currentAnime.startDate?.exactDateString, endDate: currentAnime.endDate?.exactDateString,
                hasUniqueSourceOwner: uniqueCompilationOwner
            ), let source = try? await tmdbService.getSeasonDetails(tvShowId: tmdbShowId, seasonNumber: 1) {
                unitEpisodes = AnimeVerifiedEpisodeUnitPolicy.saikiCompiledEpisodes(
                    tmdbShowID: tmdbShowId, aniListID: currentAnime.id, malID: currentAnime.idMal,
                    episodeCount: currentAnime.episodes, format: currentAnime.format, status: currentAnime.status,
                    startDate: currentAnime.startDate?.exactDateString, endDate: currentAnime.endDate?.exactDateString,
                    hasUniqueSourceOwner: uniqueCompilationOwner, sourceSeason: source, displaySeasonNumber: seasonIndex)
            } else if AnimeVerifiedEpisodeUnitPolicy.requiresRazbliutoFeature(
                tmdbShowID: tmdbShowId, aniListID: currentAnime.id, malID: currentAnime.idMal,
                episodeCount: currentAnime.episodes, format: currentAnime.format, status: currentAnime.status,
                startDate: currentAnime.startDate?.exactDateString
            ), let movie = try? await tmdbService.getMovieDetails(id: AnimeVerifiedEpisodeUnitPolicy.razbliutoMovieID),
                      let feature = AnimeVerifiedEpisodeUnitPolicy.razbliutoFeatureEpisode(
                        tmdbShowID: tmdbShowId, aniListID: currentAnime.id, malID: currentAnime.idMal,
                        episodeCount: currentAnime.episodes, format: currentAnime.format, status: currentAnime.status,
                        startDate: currentAnime.startDate?.exactDateString, movie: movie, displaySeasonNumber: seasonIndex) {
                unitEpisodes = [feature]
                unitPosterURL = movie.fullPosterURL
            }
            try Task.checkCancellation()

            let anilistEpisodeCount = verifiedTerminalEpisodesByID[currentAnime.id]?.count ?? verifiedOngoingCounts?[index] ?? (effectiveCoverageSegments.indices.contains(index)
                ? effectiveCoverageSegments[index].episodeCount ?? 0
                : currentAnime.episodes ?? 0)

            let inventoryCount = requiresVerifiedInventory ? summaryCoordinatesByAbsolute.count : tmdbCoordinatesByAbsolute.count
            let remainingTMDBCount = max(0, inventoryCount - (currentAbsoluteEpisode - 1))
            let allowsOpenEndedRemainder = allAnimeToProcess.count == 1
                && openEndedWithheldCount == nil
                && AnimeStructurePolicy.allowsSingleOpenEndedSeries(
                    status: currentAnime.status,
                    episodeCount: currentAnime.episodes,
                    mappedTMDBSeason: coordinateCoverageSegments.first?.mappedTMDBSeason,
                    tmdbSeasonEpisodeCounts: expectedTMDBSeasonCounts
                )
            let totalEpisodesInAnime = AnimeSeasonEpisodeHydrationPolicy.displayEpisodeCount(
                declaredCount: unitEpisodes?.count ?? openEndedWithheldCount ?? (anilistEpisodeCount > 0 ? anilistEpisodeCount : nil),
                remainingTMDBCount: remainingTMDBCount,
                allowsOpenEndedRemainder: allowsOpenEndedRemainder,
                status: currentAnime.status
            )
            let exactMappedStart = AnimeSeasonEpisodeHydrationPolicy.exactMappedSeasonStart(
                index: index, segments: coordinateCoverageSegments,
                tmdbSeasonEpisodeCounts: coordinateSeasonEpisodeCounts
            )
            let provedEpisodes = verifiedEpisodePlacementsByID[currentAnime.id]
            let provedEpisodeInventory = provedEpisodes.map { Dictionary(uniqueKeysWithValues: $0.enumerated().map { ($0.offset + 1, $0.element) }) }
            let provedCoordinates = provedEpisodeInventory?.mapValues {
                AnimeStructureTMDBCoordinate(seasonNumber: $0.seasonNumber, episodeNumber: $0.episodeNumber)
            }
            let seasonEpisodes = unitEpisodes ?? AnimeSeasonEpisodeHydrationPolicy.episodes(
                count: totalEpisodesInAnime,
                displaySeasonNumber: seasonIndex,
                startingAt: provedEpisodes != nil ? 1 : exactMappedStart ?? currentAbsoluteEpisode,
                tmdbEpisodes: provedEpisodeInventory ?? tmdbEpisodesByAbsolute,
                tmdbCoordinates: provedCoordinates ?? hydrationCoordinates,
                allowsTMDBCoordinates: openEndedWithheldCount == nil
                    && (provedEpisodes != nil || exactMappedStart != nil || allowsLinearTMDBCoordinates || allowsOpenEndedRemainder)
            )

            seasons.append(AniListSeasonWithPoster(
                seasonNumber: seasonIndex,
                anilistId: currentAnime.id,
                canonicalAniListId: currentAnime.id,
                malId: currentAnime.idMal,
                kitsuId: currentAnime.kitsuId
                    ?? aniMapSeedPlan.mapping(for: currentAnime.id)?.kitsuId,
                title: seasonTitle,
                englishTitle: currentAnime.title.english.map(AniListTitlePicker.cleanedTitle),
                romajiTitle: currentAnime.title.romaji.map(AniListTitlePicker.cleanedTitle),
                nativeTitle: currentAnime.title.native.map(AniListTitlePicker.cleanedTitle),
                episodes: seasonEpisodes,
                posterUrl: unitPosterURL ?? posterUrl,
                canonicalAniListEpisodeCount: unitEpisodes.flatMap { AnimeVerifiedEpisodeUnitPolicy.canonicalAniListCount($0) },
                canonicalMALEpisodeCount: unitEpisodes.flatMap { AnimeVerifiedEpisodeUnitPolicy.canonicalMALCount($0) }
            ))

            guard let nextAbsoluteEpisode = RemoteMediaNumericBoundary.adding(
                currentAbsoluteEpisode,
                totalEpisodesInAnime
            ), let nextSeasonIndex = RemoteMediaNumericBoundary.adding(seasonIndex, 1),
              nextSeasonIndex <= RemoteMediaNumericBoundary.maximumSeasonNumber else {
                throw NSError(
                    domain: "AniListStructure",
                    code: -5,
                    userInfo: [NSLocalizedDescriptionKey: "Anime structure exceeded the supported numeric boundary."]
                )
            }
            currentAbsoluteEpisode = nextAbsoluteEpisode
            seasonIndex = nextSeasonIndex
        }

        guard let totalEpisodes = RemoteMediaNumericBoundary.boundedSum(
            seasons.map { $0.episodes.count }
        ) else {
            throw NSError(
                domain: "AniListStructure",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "Anime structure exceeded the supported episode limit."]
            )
        }
        Logger.shared.log("AniListService: Fetched \(title) with \(totalEpisodes) total episodes grouped into \(seasons.count) seasons", type: "AniList")
        for season in seasons {
            Logger.shared.log("  Season \(season.seasonNumber): \(season.episodes.count) episodes, poster: \(season.posterUrl ?? "none")", type: "AniList")
        }

        let hasUpcomingMappedSeason = aniMapSeedPlan.ids.contains { id in
            aniMapNodesByID[id]?.status?.uppercased() == "NOT_YET_RELEASED"
        }
        let aggregateStatus: String
        if hasUpcomingMappedSeason {

            aggregateStatus = "NOT_YET_RELEASED"
        } else if allAnimeToProcess.contains(where: {
            $0.anime.status?.uppercased() == "RELEASING"
        }) {
            aggregateStatus = "RELEASING"
        } else {
            aggregateStatus = anime.status ?? "UNKNOWN"
        }
        let animeWithSeasons = AniListAnimeWithSeasons(
            id: anime.id,
            malId: anime.idMal ?? aniMapSeedPlan.mapping(for: anime.id)?.malId,
            title: title,
            genres: anime.detailGenreLabels,
            seasons: seasons,
            totalEpisodes: totalEpisodes,
            status: aggregateStatus,
            rating: aniListRating(from: anime.averageScore)
        )
        await logDetailTiming(
            "ready",
            fields: "seasons=\(seasons.count) episodes=\(totalEpisodes)"
        )

        try Task.checkCancellation()
        guard animeWithSeasons.satisfiesIdentitySeeds(aniListID: seedAniListId, malID: seedMALId) else {
            throw NSError(
                domain: "AniListStructure",
                code: -6,
                userInfo: [NSLocalizedDescriptionKey: "The requested anime identity could not be matched safely."]
            )
        }

        cacheAnimeDetails(
            animeWithSeasons,
            forKey: animeDetailsCacheKey(
                tmdbShowId: tmdbShowId,
                hydrationPolicy: hydrationPolicy
            )
        )

        return animeWithSeasons
    }

    private func animeDetailsCacheKey(
        tmdbShowId: Int,
        hydrationPolicy: AnimeEpisodeHydrationPolicy = .complete
    ) -> NSString {
        "\(tmdbShowId)|\(tmdbMatchCacheLanguage)|\(hydrationPolicy.rawValue)|structure-v17" as NSString
    }

    func fetchSpecialSearchEntries(
        tmdbShowId: Int,
        fallbackPosterURL: String?,
        baseAniListIds: [Int] = [],
        requiredSpecialAniListIds: [Int] = [],
        tmdbService: TMDBService
    ) async -> [AniListSpecialSearchEntry] {
        let cacheKey = specialEntriesCacheKey(
            tmdbShowId: tmdbShowId,
            baseAniListIds: baseAniListIds,
            requiredSpecialAniListIds: requiredSpecialAniListIds,
            fallbackPosterURL: fallbackPosterURL
        )
        if animeMetadataCacheReadsAllowed,
           let cached = specialEntriesCache.object(forKey: cacheKey as NSString),
           Date().timeIntervalSince(cached.timestamp) < specialEntriesCacheTTL {
            return cached.entries
        }
        if animeMetadataCacheReadsAllowed,
           let cached = await AnimeSpecialEntriesDiskCache.shared.entries(key: cacheKey) {
            cacheSpecialEntries(
                cached,
                forKey: cacheKey as NSString
            )
            return cached
        }

        if AnimeProviderHealthCenter.shared.isAniListTemporarilyUnavailable {
            AnimeProviderHealthCenter.shared.notifyMALFallbackIfNeeded(reason: "specials")
            let entries = await MALMetadataService.shared.fetchSpecialSearchEntries(
                tmdbShowId: tmdbShowId,
                fallbackPosterURL: fallbackPosterURL,
                tmdbService: tmdbService
            )
            if !entries.isEmpty {
                cacheSpecialEntries(
                    entries,
                    forKey: cacheKey as NSString
                )
            }
            return entries
        }

        let aniListResult = await fetchSpecialSearchEntriesFromAniList(
            tmdbShowId: tmdbShowId,
            fallbackPosterURL: fallbackPosterURL,
            baseAniListIds: baseAniListIds,
            requiredSpecialAniListIds: requiredSpecialAniListIds,
            tmdbService: tmdbService
        )
        let entries = aniListResult.entries

        if entries.isEmpty,
           aniListResult.isComplete,
           !AnimeProviderHealthCenter.shared.isAniListTemporarilyUnavailable {
            cacheSpecialEntries(
                [],
                forKey: cacheKey as NSString
            )
            return []
        }

        guard entries.isEmpty || AnimeProviderHealthCenter.shared.isAniListTemporarilyUnavailable else {
            if aniListResult.isComplete {
                cacheSpecialEntries(
                    entries,
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
        var merged = entries
        for malEntry in malEntries {
            if let malId = malEntry.malId,
               let index = merged.firstIndex(where: { $0.malId == malId }) {
                merged[index] = malEntry
            } else if !merged.contains(where: { $0.id == malEntry.id }) {
                merged.append(malEntry)
            }
        }
        return merged.sorted { $0.isOrderedBeforeSpecialEntry($1) }
    }

    func fetchRequiredSpecialSearchEntries(
        tmdbShowId: Int,
        fallbackPosterURL: String?,
        baseAniListIds: [Int] = [],
        requiredSpecialAniListIds: [Int] = [],
        tmdbService: TMDBService
    ) async throws -> [AniListSpecialSearchEntry] {
        let cacheKey = specialEntriesCacheKey(
            tmdbShowId: tmdbShowId,
            baseAniListIds: baseAniListIds,
            requiredSpecialAniListIds: requiredSpecialAniListIds,
            fallbackPosterURL: fallbackPosterURL
        )
        if animeMetadataCacheReadsAllowed,
           let cached = specialEntriesCache.object(forKey: cacheKey as NSString),
           Date().timeIntervalSince(cached.timestamp) < specialEntriesCacheTTL {
            return cached.entries
        }
        if animeMetadataCacheReadsAllowed,
           let cached = await AnimeSpecialEntriesDiskCache.shared.entries(key: cacheKey) {
            cacheSpecialEntries(
                cached,
                forKey: cacheKey as NSString
            )
            return cached
        }

        let result = await fetchSpecialSearchEntriesFromAniList(
            tmdbShowId: tmdbShowId,
            fallbackPosterURL: fallbackPosterURL,
            baseAniListIds: baseAniListIds,
            requiredSpecialAniListIds: requiredSpecialAniListIds,
            tmdbService: tmdbService
        )
        try Task.checkCancellation()
        if result.isComplete {
            cacheSpecialEntries(
                result.entries,
                forKey: cacheKey as NSString
            )
            if animeMetadataCacheReadsAllowed {
                Task(priority: .utility) {
                    await AnimeSpecialEntriesDiskCache.shared.store(result.entries, key: cacheKey)
                }
            }
            return result.entries
        }

        if animeMetadataCacheReadsAllowed,
           let stale = specialEntriesCache.object(forKey: cacheKey as NSString),
           Date().timeIntervalSince(stale.timestamp) < 24 * 60 * 60 {
            return stale.entries
        }
        if animeMetadataCacheReadsAllowed,
           let stale = await AnimeSpecialEntriesDiskCache.shared.entries(
            key: cacheKey,
            allowStale: true
        ) {
            return stale
        }
        throw NSError(
            domain: "AnimeDetail",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Complete anime specials are temporarily unavailable. Please try again."]
        )
    }

    func fetchRequiredMALSpecialSearchEntries(
        tmdbShowId: Int,
        rootMalId: Int,
        fallbackPosterURL: String?
    ) async throws -> [AniListSpecialSearchEntry] {
        guard let normalizedMALID = RemoteMediaNumericBoundary.positiveMagnitude(rootMalId) else {
            return []
        }
        let cacheKey = "mal-v4|\(tmdbShowId)|\(normalizedMALID)|\(tmdbMatchCacheLanguage)|\(fallbackPosterURL ?? "-")"
        if animeMetadataCacheReadsAllowed,
           let cached = specialEntriesCache.object(forKey: cacheKey as NSString),
           Date().timeIntervalSince(cached.timestamp) < specialEntriesCacheTTL {
            return cached.entries
        }
        if animeMetadataCacheReadsAllowed,
           let cached = await AnimeSpecialEntriesDiskCache.shared.entries(key: cacheKey) {
            cacheSpecialEntries(
                cached,
                forKey: cacheKey as NSString
            )
            return cached
        }

        do {
            let entries = try await AniListRequestContext.$isDetailReadyPath.withValue(true) {
                try await MALMetadataService.shared.fetchSpecialSearchEntries(
                    rootMalId: normalizedMALID,
                    tmdbShowId: tmdbShowId,
                    fallbackPosterURL: fallbackPosterURL
                )
            }
            try Task.checkCancellation()
            cacheSpecialEntries(
                entries,
                forKey: cacheKey as NSString
            )
            if animeMetadataCacheReadsAllowed {
                Task(priority: .utility) {
                    await AnimeSpecialEntriesDiskCache.shared.store(entries, key: cacheKey)
                }
            }
            return entries
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if animeMetadataCacheReadsAllowed,
               let stale = await AnimeSpecialEntriesDiskCache.shared.entries(
                key: cacheKey,
                allowStale: true
            ) {
                return stale
            }
            throw error
        }
    }

    private func specialEntriesCacheKey(
        tmdbShowId: Int,
        baseAniListIds: [Int],
        requiredSpecialAniListIds: [Int] = [],
        fallbackPosterURL: String?
    ) -> String {
        let ids = Set(baseAniListIds.filter { $0 > 0 }).sorted().map(String.init).joined(separator: ",")
        let requiredIDs = Set(requiredSpecialAniListIds.filter { $0 > 0 })
            .sorted()
            .map(String.init)
            .joined(separator: ",")
        return "v5|\(tmdbShowId)|\(tmdbMatchCacheLanguage)|\(ids)|required:\(requiredIDs)|\(fallbackPosterURL ?? "-")"
    }

    private func fetchSpecialSearchEntriesFromAniList(
        tmdbShowId: Int,
        fallbackPosterURL: String?,
        baseAniListIds: [Int] = [],
        requiredSpecialAniListIds: [Int] = [],
        tmdbService: TMDBService
    ) async -> SpecialEntriesFetchResult {
        let show = try? await tmdbService.getTVShowWithSeasons(id: tmdbShowId)
        let tmdbCounts = regularTMDBSeasonCounts(show)
        let mappingResult = await AniMapMappingService.shared.mappingsResult(forTMDBShowId: tmdbShowId)
        let nodeResult = await batchFetchAniListStructureNodesResult(ids: Array(Set(mappingResult.mappings.compactMap(\.anilistId))))
        let mappingsByID = Dictionary(mappingResult.mappings.compactMap { mapping in
            mapping.anilistId.map { ($0, mapping) }
        }, uniquingKeysWith: { first, _ in first })
        let placementCandidates = nodeResult.nodes.values.map { node in
            AnimeStructureCourPlacementCandidate(id: node.id, mappedTMDBSeason: mappingsByID[node.id]?.tmdbSeason,
                episodeCount: node.episodes, format: node.format, status: node.status,
                startDate: node.startDate?.exactDateString, endDate: node.endDate?.exactDateString,
                titles: AniListTitlePicker.titleCandidates(from: node.title),
                hasTrustedIdentity: mappingsByID[node.id]?.tmdbShowId == tmdbShowId)
        }
        let contradictedIDs = AnimeStructurePolicy.contradictedMappedSpecialIDs(
            candidates: placementCandidates, mappingsByID: mappingsByID, tmdbShow: show
        )
        let ordinaryMappings = mappingResult.mappings.filter {
            $0.anilistId.map { !contradictedIDs.contains($0) } ?? true
        }
        let ordinaryCounts = ordinaryMappedSeasonCounts(ordinaryMappings, nodesByID: nodeResult.nodes)
        let regularIDs = Set(AniMapStructuralRole.regularStoryMappings(mappingResult.mappings,
            tmdbShowId: tmdbShowId, tmdbSeasonEpisodeCounts: tmdbCounts,
            regularStoryEpisodeCounts: ordinaryCounts,
            mediaType: { $0.anilistId.flatMap { nodeResult.nodes[$0]?.format } },
            episodeCount: { $0.anilistId.flatMap { nodeResult.nodes[$0]?.episodes } }).compactMap(\.anilistId))
            .subtracting(contradictedIDs)
        let mappings = mappingResult.mappings.filter { mapping in
            guard mapping.tmdbShowId == tmdbShowId,
                  mapping.anilistId.map({ !regularIDs.contains($0) }) ?? true else { return false }
            let node = mapping.anilistId.flatMap { nodeResult.nodes[$0] }
            return mapping.anilistId.map { contradictedIDs.contains($0) } == true
                || AniMapStructuralRole.isDetachedSpecial(mapping, fallbackMediaType: node?.format,
                tmdbSeasonEpisodeCounts: tmdbCounts, episodeCount: node?.episodes, regularStoryEpisodeCounts: ordinaryCounts)
        }
        let uniqueMappings = mappings.reduce(into: [Int: AniMapMapping]()) { result, mapping in
            guard let anilistId = mapping.anilistId, result[anilistId] == nil else { return }
            result[anilistId] = mapping
        }

        async let relationTask = relationSpecialSearchEntries(
            baseAniListIds: baseAniListIds
                + requiredSpecialAniListIds
                + Array(uniqueMappings.keys)
                + Array(regularIDs),
            tmdbShowId: tmdbShowId,
            fallbackPosterURL: fallbackPosterURL,
            tmdbService: tmdbService,
            excluding: [],
            requiredSpecialIDs: Set(requiredSpecialAniListIds.filter { $0 > 0 }),
            ordinaryMappings: ordinaryMappings,
            prefetchedNodes: nodeResult.nodes,
            tmdbSeasonEpisodeCounts: tmdbCounts,
            ordinarySeasonCounts: ordinaryCounts
        )
        let mappedSpecialSeasonNumbers = Set(uniqueMappings.compactMap { id, mapping in
            contradictedIDs.contains(id) ? 0 : mapping.tmdbSeason
        })
        let specialSeasonNumbers = mappedSpecialSeasonNumbers.union([0])
        async let seasonDetailsTask = fetchSpecialTMDBSeasonDetails(
            tmdbShowId: tmdbShowId,
            seasonNumbers: specialSeasonNumbers,
            tmdbService: tmdbService
        )
        let nodesById = nodeResult.nodes
        let seasonDetailsByNumber = await seasonDetailsTask

        var entries = uniqueMappings.compactMap { element -> AniListSpecialSearchEntry? in
            buildSpecialSearchEntry(
                anilistId: element.key,
                node: nodesById[element.key],
                mapping: element.value,
                fallbackPosterURL: fallbackPosterURL,
                seasonDetailsByNumber: seasonDetailsByNumber,
                tmdbSeasonEpisodeCounts: tmdbCounts,
                ordinarySeasonCounts: ordinaryCounts,
                forceSeasonZero: contradictedIDs.contains(element.key)
            )
        }

        let relationResult = await relationTask
        let relationEntries = relationResult.entries
        if !relationEntries.isEmpty {
            for entry in relationEntries {
                if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                    if !entry.episodes.isEmpty,
                       entry.episodes.allSatisfy({ $0.tmdbSeasonNumber != nil && $0.tmdbEpisodeNumber != nil }),
                       entries[index].episodes.contains(where: { $0.tmdbSeasonNumber == nil || $0.tmdbEpisodeNumber == nil }) {
                        entries[index] = entry
                    }
                } else {
                    entries.append(entry)
                }
            }
            Logger.shared.log("AniListService: relation fallback added \(relationEntries.count) special/OVA entries for TMDB \(tmdbShowId)", type: "AniList")
        }

        let hasRelationSeeds = baseAniListIds.contains { $0 > 0 }
        return SpecialEntriesFetchResult(
            entries: entries.sorted { lhs, rhs in
                lhs.isOrderedBeforeSpecialEntry(rhs)
            },

            isComplete: hasRelationSeeds
                && mappingResult.isComplete
                && nodeResult.isComplete
                && relationResult.isComplete
        )
    }

    private func fetchSpecialTMDBSeasonDetails(
        tmdbShowId: Int,
        seasonNumbers: Set<Int>,
        tmdbService: TMDBService
    ) async -> [Int: TMDBSeasonDetail] {
        let valid = seasonNumbers.filter { $0 >= 0 }
        guard !valid.isEmpty else { return [:] }
        return await withTaskGroup(of: (Int, TMDBSeasonDetail?).self) { group in
            for seasonNumber in valid {
                group.addTask {
                    do {
                        let detail = try await tmdbService.getSeasonDetails(
                            tvShowId: tmdbShowId,
                            seasonNumber: seasonNumber
                        )
                        return (seasonNumber, detail)
                    } catch {
                        return (seasonNumber, nil)
                    }
                }
            }
            var values: [Int: TMDBSeasonDetail] = [:]
            for await (seasonNumber, detail) in group {
                if let detail { values[seasonNumber] = detail }
            }
            return values
        }
    }

    private func buildSpecialSearchEntry(
        anilistId: Int,
        node: AniListAnime?,
        mapping: AniMapMapping?,
        fallbackPosterURL: String?,
        seasonDetailsByNumber: [Int: TMDBSeasonDetail],
        tmdbSeasonEpisodeCounts: [Int: Int]?,
        ordinarySeasonCounts: [Int: Int],
        verifiedEpisodes: [TMDBEpisode] = [],
        forceSeasonZero: Bool = false
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

        guard let episodeCount = RemoteMediaNumericBoundary.episodeCount(
            max(1, node?.episodes ?? 1)
        ) else { return nil }
        let mappedSeason = mapping.flatMap { mapping in
            if forceSeasonZero { return 0 }
            return AniMapStructuralRole.isDetachedSpecial(mapping, fallbackMediaType: node?.format,
                tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts, episodeCount: episodeCount,
                regularStoryEpisodeCounts: ordinarySeasonCounts) ? 0 : mapping.tmdbSeason
        }
        let exactTMDBEpisodes = verifiedEpisodes.isEmpty ? AnimeSpecialEpisodeHydrationPolicy.exactEpisodes(
            episodeCount: episodeCount,
            exactReleaseDate: node?.startDate?.exactDateString,
            mappedSeasonNumber: mappedSeason,
            seasonDetailsByNumber: seasonDetailsByNumber,
            exactEndDate: node?.endDate?.exactDateString
        ) : verifiedEpisodes
        let sourceSeason = exactTMDBEpisodes.first?.seasonNumber ?? mappedSeason
        let tmdbSeasonDetail = seasonDetailsByNumber[sourceSeason ?? 0]
        let episodes = (1...episodeCount).map { number in

            let tmdbEpisode = exactTMDBEpisodes.indices.contains(number - 1)
                ? exactTMDBEpisodes[number - 1]
                : nil

            return AniListEpisode(
                number: number,
                title: tmdbEpisode?.name ?? (episodeCount == 1 ? cleanTitle : "Episode \(number)"),
                description: tmdbEpisode?.overview,
                seasonNumber: tmdbEpisode?.seasonNumber ?? mappedSeason ?? 0,
                stillPath: tmdbEpisode?.stillPath,
                airDate: tmdbEpisode?.airDate,
                runtime: tmdbEpisode?.runtime,
                tmdbSeasonNumber: tmdbEpisode?.seasonNumber,
                tmdbEpisodeNumber: tmdbEpisode?.episodeNumber
            )
        }
        let exactEpisodeDate = episodes.compactMap(\.airDate).min()
        let releaseDate = node?.startDate?.exactDateString
            ?? exactEpisodeDate
            ?? node?.startDate?.approximateDateString
            ?? AniListDate.approximateDateString(year: node?.seasonYear, season: node?.season)

        return AniListSpecialSearchEntry(
            id: anilistId,
            canonicalAniListId: anilistId,
            malId: node?.idMal ?? mapping?.malId,
            kitsuId: node?.kitsuId ?? mapping?.kitsuId,
            title: cleanTitle,
            englishTitle: englishTitle,
            romajiTitle: romajiTitle,
            nativeTitle: nativeTitle,
            format: mapping?.mediaType?.uppercased() ?? node?.format,
            episodeCount: episodeCount,
            posterUrl: node?.coverImage?.preferredURL()
                ?? tmdbSeasonDetail?.fullPosterURL
                ?? fallbackPosterURL,
            tmdbSeasonNumber: sourceSeason,
            tvdbSeasonNumber: mapping?.tvdbSeason,
            episodeOffset: mapping?.tvdbEpisodeOffset,
            imdbId: mapping?.imdbId,
            releaseDate: releaseDate,
            status: node?.status,
            episodes: episodes
        )
    }

    private func relationSpecialSearchEntries(
        baseAniListIds: [Int],
        tmdbShowId: Int,
        fallbackPosterURL: String?,
        tmdbService: TMDBService,
        excluding existingIds: Set<Int>,
        requiredSpecialIDs: Set<Int> = [],
        ordinaryMappings: [AniMapMapping],
        prefetchedNodes: [Int: AniListAnime],
        tmdbSeasonEpisodeCounts: [Int: Int]?,
        ordinarySeasonCounts: [Int: Int]
    ) async -> SpecialEntriesFetchResult {
        let baseIds = Array(Set(baseAniListIds)).filter { $0 > 0 }
        guard !baseIds.isEmpty else {
            return SpecialEntriesFetchResult(entries: [], isComplete: true)
        }

        let missingIDs = baseIds.filter { prefetchedNodes[$0] == nil }
        let fetched = await batchFetchAniListRelationSeedNodesResult(ids: missingIDs)
        let baseNodes = prefetchedNodes.filter { baseIds.contains($0.key) }
            .merging(fetched.nodes) { existing, _ in existing }
        let baseNodeResult = AniListNodeBatchResult(
            nodes: baseNodes, isComplete: fetched.isComplete && Set(baseIds).isSubset(of: Set(baseNodes.keys))
        )
        var candidates: [Int: AniListAnime] = [:]
        var continuationParentsByID: [Int: [AnimeSpecialEpisodeHydrationPolicy.ContinuationParent]] = [:]

        for base in baseNodes.values {
            let isRegularContinuation = base.relations?.edges.contains {
                AnimeRelationRolePolicy.isRegularContinuationCandidate(
                    relationType: $0.relationType,
                    mediaFormat: base.format
                )
            } == true
            if requiredSpecialIDs.contains(base.id),
               !existingIds.contains(base.id),
               AniMapStructuralRole.isPotentialDetachedFormat(base.format),
               !isRegularContinuation {
                candidates[base.id] = base
            }
            for edge in base.relations?.edges ?? [] {
                let relationNode = edge.node
                if edge.relationType.uppercased() == "SEQUEL", relationNode.type == "ANIME",
                   relationNode.format?.uppercased() == "SPECIAL" {
                    for mapping in ordinaryMappings where mapping.anilistId == base.id
                        && mapping.tmdbShowId == tmdbShowId && (mapping.tmdbSeason ?? 0) > 0 {
                        continuationParentsByID[relationNode.id, default: []].append(
                            AnimeSpecialEpisodeHydrationPolicy.ContinuationParent(
                                mapping: mapping, relationType: edge.relationType,
                                episodeCount: base.episodes, status: base.status, format: base.format,
                                startDate: base.startDate?.exactDateString, endDate: base.endDate?.exactDateString
                            )
                        )
                    }
                }
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

        let candidateIDs = Array(candidates.keys)
        let cachedMappings = await AniMapMappingService.shared.cachedMappings(forAniListIds: candidateIDs)
        let unresolvedIDs = candidateIDs.filter { cachedMappings[$0] == nil }
        if !unresolvedIDs.isEmpty, !Task.isCancelled {

            Task(priority: .utility) {
                await withTaskGroup(of: Void.self) { group in
                    for id in unresolvedIDs {
                        group.addTask {
                            _ = await AniMapMappingService.shared.mappingsResult(forAniListId: id)
                        }
                    }
                }
            }
        }
        let allMappings = cachedMappings

        var mappingsByID: [Int: AniMapMapping] = [:]
        var regularStoryIDs = Set<Int>()
        for id in candidateIDs {
            let mappings = allMappings[id] ?? []
            if mappings.contains(where: {
                $0.tmdbShowId == tmdbShowId
                    && AniMapStructuralRole.isRegularStory(
                        $0,
                        fallbackMediaType: candidates[id]?.format,
                        tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                        episodeCount: candidates[id]?.episodes,
                        regularStoryEpisodeCounts: ordinarySeasonCounts
                    )
            }) {
                regularStoryIDs.insert(id)
                continue
            }
            mappingsByID[id] = mappings.first { mapping in
                let matchesShow = mapping.tmdbShowId == nil || mapping.tmdbShowId == tmdbShowId
                return matchesShow && AniMapStructuralRole.isDetachedSpecial(
                    mapping,
                    fallbackMediaType: candidates[id]?.format,
                    tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                    episodeCount: candidates[id]?.episodes,
                    regularStoryEpisodeCounts: ordinarySeasonCounts
                )
            }
        }

        let detachedCandidateIDs = candidates.keys.filter {
            !regularStoryIDs.contains($0)
        }
        let mappedSeasonNumbers = Set(mappingsByID.values.compactMap(\.tmdbSeason))
        let parentSeasonNumbers = Set(detachedCandidateIDs.flatMap { id -> [Int] in
            let parents = continuationParentsByID[id] ?? []
            guard parents.count == 1,
                  let candidate = candidates[id], candidate.status?.uppercased() == "FINISHED",
                  RemoteMediaNumericBoundary.episodeCount(candidate.episodes) != nil,
                  let releaseDate = candidate.startDate?.exactDateString,
                  releaseDate == candidate.endDate?.exactDateString else { return [] }
            return parents.compactMap { parent -> Int? in
                guard RemoteMediaNumericBoundary.episodeCount(parent.episodeCount) != nil,
                      parent.status?.uppercased() == "FINISHED",
                      parent.startDate != nil, parent.endDate != nil,
                      parent.mapping.tvdbEpisodeOffset == 0 else { return nil }
                return RemoteMediaNumericBoundary.seasonNumber(parent.mapping.tmdbSeason)
            }
        })
        let boundedParentSeasonNumbers = Set(parentSeasonNumbers.sorted().prefix(8))
        let seasonNumbers = (detachedCandidateIDs.isEmpty ? mappedSeasonNumbers : mappedSeasonNumbers.union([0]))
            .union(boundedParentSeasonNumbers)
        let seasonDetailsByNumber = await fetchSpecialTMDBSeasonDetails(
            tmdbShowId: tmdbShowId,
            seasonNumbers: seasonNumbers,
            tmdbService: tmdbService
        )
        let proposedEpisodes = Dictionary(uniqueKeysWithValues: detachedCandidateIDs.map { id in
            let node = candidates[id]
            return (id, AnimeSpecialEpisodeHydrationPolicy.continuationEpisodes(
                tmdbShowId: tmdbShowId, episodeCount: node?.episodes, format: node?.format,
                status: node?.status, exactReleaseDate: node?.startDate?.exactDateString,
                exactEndDate: node?.endDate?.exactDateString,
                parents: continuationParentsByID[id] ?? [], seasonDetailsByNumber: seasonDetailsByNumber
            ))
        })
        let verifiedEpisodesByID = AnimeSpecialEpisodeHydrationPolicy.uniquelyOwnedContinuationEpisodes(proposedEpisodes)
        return SpecialEntriesFetchResult(
            entries: candidates.compactMap { id, node in
                guard !regularStoryIDs.contains(id) else { return nil }
                return buildSpecialSearchEntry(
                    anilistId: id,
                    node: node,
                    mapping: mappingsByID[id],
                    fallbackPosterURL: fallbackPosterURL,
                    seasonDetailsByNumber: seasonDetailsByNumber,
                    tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                    ordinarySeasonCounts: ordinarySeasonCounts,
                    verifiedEpisodes: verifiedEpisodesByID[id] ?? []
                )
            },

            isComplete: baseNodeResult.isComplete
        )
    }

    private func isSpecialRelationCandidate(_ edge: AniListAnime.AniListRelationEdge) -> Bool {
        AnimeRelationRolePolicy.isDetachedSpecialCandidate(
            relationType: edge.relationType,
            mediaFormat: edge.node.format,
            titleCandidates: AniListTitlePicker.titleCandidates(from: edge.node.title)
        )
    }

    private func pickBestAniListMatch(from candidates: [AniListAnime], tmdbShow: TMDBTVShowWithSeasons?) -> AniListAnime {

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

        let chosen: AniListAnime?
        if let tmdbEpisodes {
            chosen = titleFiltered.min(by: { lhs, rhs in
                let lhsEpisodes = lhs.episodes ?? 0
                let rhsEpisodes = rhs.episodes ?? 0
                let lhsDiff = RemoteMediaNumericBoundary.absoluteDifference(
                    lhsEpisodes,
                    tmdbEpisodes
                ) ?? Int.max
                let rhsDiff = RemoteMediaNumericBoundary.absoluteDifference(
                    rhsEpisodes,
                    tmdbEpisodes
                ) ?? Int.max
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

    private func relocatedTVDBSiblingCandidates(
        tmdbShowId: Int,
        tvShowDetail: TMDBTVShowWithSeasons?,
        plan: AniMapSeasonSeedPlan,
        tmdbService: TMDBService
    ) async -> [AniMapMapping] {
        guard let tvShowDetail else { return [] }
        let claimed = Set(plan.mappingInventory.compactMap { $0.tmdbShowId == tmdbShowId ? $0.tmdbSeason : nil })
        guard tvShowDetail.seasons.contains(where: {
            $0.seasonNumber > 0 && $0.episodeCount > 0 && !claimed.contains($0.seasonNumber)
        }) else { return [] }
        let knownIDs = Set(plan.mappingInventory.compactMap(\.anilistId))
        var candidates: [AniMapMapping] = []
        for tvdbId in Array(Set(plan.mappingInventory.compactMap(\.tvdbId))).sorted().prefix(2) {
            let siblings = await AniMapMappingService.shared.mappingsResult(forTVDBId: tvdbId).mappings
            var checked = Set<Int>()
            for row in siblings where checked.count < 4 {
                guard !Task.isCancelled else { return [] }
                guard let anilistId = row.anilistId, !knownIDs.contains(anilistId),
                      !candidates.contains(where: { $0.anilistId == anilistId }),
                      row.tmdbMovieId == nil, (row.tvdbSeason ?? 0) > 0,
                      row.tmdbShowId != tmdbShowId, checked.insert(anilistId).inserted else { continue }
                if let foreignShowID = row.tmdbShowId {
                    guard await tmdbTVShowIsMissing(foreignShowID, tmdbService: tmdbService) else { continue }
                }
                candidates.append(row)
            }
        }
        return candidates
    }

    private func provenRelocatedMappings(
        _ candidates: [AniMapMapping],
        nodesByID: [Int: AniListAnime],
        tmdbShowId: Int,
        tvShowDetail: TMDBTVShowWithSeasons?,
        plan: AniMapSeasonSeedPlan,
        tmdbService: TMDBService
    ) async -> [AniMapMapping] {
        guard let tvShowDetail, !candidates.isEmpty else { return [] }
        var claimed = Set(plan.mappingInventory.compactMap { $0.tmdbShowId == tmdbShowId ? $0.tmdbSeason : nil })
        var relocated: [AniMapMapping] = []
        for candidate in candidates {
            guard let anilistId = candidate.anilistId, let node = nodesByID[anilistId],
                  let startDate = node.startDate?.exactDateString else { continue }
            let count = RemoteMediaNumericBoundary.episodeCount(node.episodes)
            let names = Set(AniListTitlePicker.titleCandidates(from: node.title).map(normalizedAnimeTitle).filter { !$0.isEmpty })
            let claimedSeasons = claimed
            let eligible = tvShowDetail.seasons.filter { season in
                guard season.seasonNumber > 0, !claimedSeasons.contains(season.seasonNumber) else { return false }
                if let count, count != season.episodeCount { return false }
                return names.contains(normalizedAnimeTitle(season.name)) || season.seasonNumber == candidate.tvdbSeason
            }
            var proven: [Int] = []
            for season in eligible.prefix(3) {
                guard let detail = try? await tmdbService.getSeasonDetails(tvShowId: tmdbShowId, seasonNumber: season.seasonNumber),
                      detail.seasonNumber == season.seasonNumber else { continue }
                let episodes = detail.episodes.sorted { $0.episodeNumber < $1.episodeNumber }
                guard let first = episodes.first, first.airDate == startDate else { continue }
                if let count, count != episodes.count { continue }
                proven.append(season.seasonNumber)
            }
            guard proven.count == 1, let season = proven.first else { continue }
            claimed.insert(season)
            relocated.append(candidate.relocated(toTMDBShowId: tmdbShowId, season: season))
        }
        return relocated
    }

    private func openEndedAiringConflictCount(
        anime: AniListAnime,
        tmdbShowId: Int,
        seasons: [TMDBSeason],
        mappedSeason: Int?,
        tmdbService: TMDBService
    ) async -> Int? {
        guard anime.episodes == nil, anime.status?.uppercased() == "RELEASING",
              let next = anime.nextAiringEpisode?.episode, next > 1,
              let airedOnAniList = RemoteMediaNumericBoundary.episodeCount(next - 1) else { return nil }
        let today = AnimeStructurePolicy.currentAirDateString()
        func hasAired(_ date: String?) -> Bool {
            AnimeStructurePolicy.validatedAirDateString(date).map { $0 <= today } ?? false
        }
        let regular = seasons.filter { season in
            season.seasonNumber > 0 && season.episodeCount > 0 && (mappedSeason == nil || season.seasonNumber == mappedSeason)
        }.sorted { $0.seasonNumber < $1.seasonNumber }
        let latest = regular.last(where: { hasAired($0.airDate) })
        var aired = 0
        var rows: [TMDBEpisode] = []
        var airedInSeason = 0
        if let latest {
            guard let detail = try? await tmdbService.getSeasonDetails(tvShowId: tmdbShowId, seasonNumber: latest.seasonNumber),
                  detail.seasonNumber == latest.seasonNumber else { return nil }
            rows = detail.episodes.sorted { $0.episodeNumber < $1.episodeNumber }
            airedInSeason = rows.filter { hasAired($0.airDate) }.count
            aired = regular.filter { $0.seasonNumber < latest.seasonNumber }.reduce(airedInSeason) { $0 + $1.episodeCount }
        }
        guard abs(aired - airedOnAniList) > 2 else { return nil }
        guard let latestSeason = latest, aired > 0, aired < airedOnAniList, airedInSeason > 0, airedInSeason <= rows.count else {
            return airedOnAniList
        }
        var previousAirDate = airedInSeason > 1 ? rows[airedInSeason - 2].airDate : nil
        if airedInSeason == 1, aired > 1, let earlier = regular.last(where: { $0.seasonNumber < latestSeason.seasonNumber }),
           let prior = try? await tmdbService.getSeasonDetails(tvShowId: tmdbShowId, seasonNumber: earlier.seasonNumber),
           prior.seasonNumber == earlier.seasonNumber {
            previousAirDate = prior.episodes.max(by: { $0.episodeNumber < $1.episodeNumber })?.airDate
        }
        let aligned = await aniListEpisode(
            anime.id, episode: aired, airedOn: rows[airedInSeason - 1].airDate, previousAirDate: previousAirDate
        )
        return aligned ? nil : airedOnAniList
    }

    private func aniListEpisode(_ mediaId: Int, episode: Int, airedOn airDate: String?, previousAirDate: String?) async -> Bool {
        guard let airDate = AnimeStructurePolicy.validatedAirDateString(airDate) else { return false }
        let previous = AnimeStructurePolicy.validatedAirDateString(previousAirDate)
        if episode > 1 {
            guard let previous, previous < airDate else { return false }
        }
        let query = """
        query {
            AiringSchedule(mediaId: \(mediaId), episode: \(episode)) {
                mediaId
                episode
                airingAt
            }
        }
        """
        struct Response: Decodable {
            struct Payload: Decodable {
                struct Schedule: Decodable {
                    let mediaId: Int?
                    let episode: Int?
                    let airingAt: Int?
                }
                let AiringSchedule: Schedule?
            }
            let data: Payload?
        }
        guard let data = try? await executeGraphQLQuery(query, token: nil, maxRetries: 1),
              let schedule = (try? JSONDecoder().decode(Response.self, from: data))?.data?.AiringSchedule,
              schedule.mediaId == mediaId, schedule.episode == episode,
              let airingAt = schedule.airingAt, airingAt > 0 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? TimeZone(secondsFromGMT: 9 * 3600) ?? .current
        func day(_ value: String) -> Date? {
            let parts = value.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
        guard let source = day(airDate),
              let offset = calendar.dateComponents(
                  [.day], from: calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(airingAt))), to: source
              ).day else { return false }
        if offset == 0 { return true }
        guard abs(offset) == 1, let previous, let prior = day(previous),
              let spacing = calendar.dateComponents([.day], from: prior, to: source).day else { return false }
        return spacing >= 3
    }

    private func tmdbTVShowIsMissing(_ id: Int, tmdbService: TMDBService) async -> Bool {
        do {
            _ = try await tmdbService.getTVShowWithSeasons(id: id)
            return false
        } catch {
            var current: Error? = error
            while let value = current, let tmdbError = value as? TMDBError {
                switch tmdbError {
                case .httpError(let statusCode, _, _):
                    return statusCode == 404
                case .networkError(let inner):
                    current = inner
                default:
                    return false
                }
            }
            return false
        }
    }

    private func normalizedAnimeTitle(_ value: String) -> String {
        value
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

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

                        let exactMatches = results.filter { normalized($0.name) == candidateKey }
                        if !exactMatches.isEmpty {

                            let bestExact = exactMatches.min { a, b in
                                let aYear = Int(a.firstAirDate?.prefix(4) ?? "")
                                let bYear = Int(b.firstAirDate?.prefix(4) ?? "")

                                if let expectedYear = expectedYear {
                                    let aDiff = aYear.flatMap {
                                        RemoteMediaNumericBoundary.absoluteDifference($0, expectedYear)
                                    } ?? 10000
                                    let bDiff = bYear.flatMap {
                                        RemoteMediaNumericBoundary.absoluteDifference($0, expectedYear)
                                    } ?? 10000
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

                        let partialMatches = results.filter {
                            let nameKey = normalized($0.name)
                            return nameKey.contains(candidateKey) || candidateKey.contains(nameKey)
                        }
                        if !partialMatches.isEmpty {
                            let best = partialMatches.min { a, b in

                                if let expectedYear = expectedYear {
                                    let aYear = Int(a.firstAirDate?.prefix(4) ?? "")
                                    let bYear = Int(b.firstAirDate?.prefix(4) ?? "")
                                    let aDiff = aYear.flatMap {
                                        RemoteMediaNumericBoundary.absoluteDifference($0, expectedYear)
                                    } ?? 10000
                                    let bDiff = bYear.flatMap {
                                        RemoteMediaNumericBoundary.absoluteDifference($0, expectedYear)
                                    } ?? 10000
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
                            if let best = best {
                                bestMatch = best
                                break
                            }
                        }

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
                    return bestMatch?.asSearchResult.withAnimeIdentitySeed(
                        AnimeMediaIdentitySeed(
                            anilistId: anime.id,
                            malId: anime.idMal,
                            kitsuId: anime.kitsuId,
                            format: anime.format
                        )
                    )
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

    private func batchMapAniListToTMDB(_ animeList: [AniListAnime], tmdbService: TMDBService) async -> [Int: TMDBSearchResult] {
        Task(priority: .utility) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await AniMapMappingService.shared.prepareGlobalIndexIfNeeded()
        }

        @Sendable func normalized(_ value: String) -> String {
            return value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        }

        let langCode = self.preferredLanguageCode
        let cacheLanguage = self.tmdbMatchCacheLanguage

        guard let matches = try? await TrackerImportWork.map(animeList, operation: { anime -> (Int, TMDBSearchResult?, AnimeTMDBMatchCacheRecord?) in
            try Task.checkCancellation()
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
                let seededResult = cached.result?.withAnimeIdentitySeed(
                    AnimeMediaIdentitySeed(
                        anilistId: anime.id,
                        malId: anime.idMal,
                        kitsuId: anime.kitsuId,
                        format: anime.format
                    )
                )
                return (anime.id, seededResult, nil)
            }

            var bestMatch: TMDBTVShow?
            var lookupCompleted = true

            for candidate in titleCandidates where !candidate.isEmpty {
                try Task.checkCancellation()
                let results: [TMDBTVShow]
                do {
                    results = try await tmdbService.searchTVShows(query: candidate)
                } catch {
                    try Task.checkCancellation()
                    lookupCompleted = false
                    continue
                }
                guard !results.isEmpty else { continue }
                let candidateKey = normalized(candidate)

                let exactMatches = results.filter { normalized($0.name) == candidateKey }
                if !exactMatches.isEmpty {
                    let bestExact = exactMatches.min { a, b in
                        if let expectedYear = expectedYear {
                            let aDiff = Int(a.firstAirDate?.prefix(4) ?? "").flatMap {
                                RemoteMediaNumericBoundary.absoluteDifference($0, expectedYear)
                            } ?? 10000
                            let bDiff = Int(b.firstAirDate?.prefix(4) ?? "").flatMap {
                                RemoteMediaNumericBoundary.absoluteDifference($0, expectedYear)
                            } ?? 10000
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
                            let aDiff = Int(a.firstAirDate?.prefix(4) ?? "").flatMap {
                                RemoteMediaNumericBoundary.absoluteDifference($0, expectedYear)
                            } ?? 10000
                            let bDiff = Int(b.firstAirDate?.prefix(4) ?? "").flatMap {
                                RemoteMediaNumericBoundary.absoluteDifference($0, expectedYear)
                            } ?? 10000
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

            try Task.checkCancellation()
            if let bestMatch = bestMatch {
                let aniTitle = AniListTitlePicker.title(from: anime.title, preferredLanguageCode: langCode)
                Logger.shared.log("AniListService: Matched '\(aniTitle)' -> TMDB '\(bestMatch.name)' (ID: \(bestMatch.id))", type: "AniList")
            }
            let result = bestMatch?.asSearchResult.withAnimeIdentitySeed(
                AnimeMediaIdentitySeed(
                    anilistId: anime.id,
                    malId: anime.idMal,
                    kitsuId: anime.kitsuId,
                    format: anime.format
                )
            )
            let cacheRecord = result != nil || lookupCompleted
                ? AnimeTMDBMatchCacheRecord(key: cacheKey, result: result)
                : nil
            return (anime.id, result, cacheRecord)
        }) else { return [:] }

        var dict: [Int: TMDBSearchResult] = [:]
        var cacheRecords: [AnimeTMDBMatchCacheRecord] = []
        for (anilistId, match, cacheRecord) in matches {
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

            let parentEdge = edges
                .filter { parentRelTypes.contains($0.relationType) && $0.node.type == "ANIME" && !visited.contains($0.node.id) }
                .sorted { a, b in
                    let aIsTV = tvFormats.contains(a.node.format ?? "")
                    let bIsTV = tvFormats.contains(b.node.format ?? "")
                    if aIsTV != bIsTV { return aIsTV }

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

    struct AniListImportEntry {
        let tmdbResult: TMDBSearchResult

        let episodesWatched: Int
    }

    struct AniListUserListImport {
        var watching: [AniListImportEntry] = []
        var planning: [AniListImportEntry] = []
        var completed: [AniListImportEntry] = []
        var paused: [AniListImportEntry] = []
        var dropped: [AniListImportEntry] = []
        var repeating: [AniListImportEntry] = []
    }

    private struct AniListListEntry {
        let anime: AniListAnime
        let progress: Int
    }

    func fetchUserAnimeListsForImport(
        token: String,
        userId: Int,
        tmdbService: TMDBService
    ) async throws -> AniListUserListImport {

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

        let allLists = watching + planning + completed + paused + dropped + repeating
        var allAnime: [AniListAnime] = []
        var seenIds = Set<Int>()
        for entry in allLists {
            if seenIds.insert(entry.anime.id).inserted {
                allAnime.append(entry.anime)
            }
        }

        let tmdbMap = await batchMapAniListToTMDB(allAnime, tmdbService: tmdbService)

        var progressMap: [Int: Int] = [:]
        for entry in allLists {
            progressMap[entry.anime.id] = entry.progress
        }

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

    func mapAniListAnimeIdsToTMDBForImport(
        _ ids: [Int],
        prefetched: [AniListAnime] = [],
        tmdbService: TMDBService
    ) async -> [Int: TMDBSearchResult] {
        let uniqueIds = Array(Set(ids))
        guard !uniqueIds.isEmpty else { return [:] }

        guard let nodes = try? await AniListImportMetadata.resolve(
            ids: uniqueIds,
            prefetched: prefetched,
            fetch: { await self.batchFetchAniListImportNodes(ids: $0) }
        ) else { return [:] }
        return await batchMapAniListToTMDB(Array(nodes.values), tmdbService: tmdbService)
    }

    func mapAniListAnimeIdsToTMDBViaAniMapForMALImport(
        _ ids: [Int],
        tmdbService: TMDBService
    ) async -> [Int: AniMapTMDBImportMatch] {
        let uniqueIds = Array(Set(ids))
        guard !uniqueIds.isEmpty else { return [:] }

        guard let matches = try? await TrackerImportWork.map(uniqueIds.sorted(), operation: { anilistId -> (Int, AniMapTMDBImportMatch?) in
            let mappings = await AniMapMappingService.shared.mappings(forAniListId: anilistId)
            try Task.checkCancellation()
            guard let mapping = Self.bestAniMapImportMapping(mappings, anilistId: anilistId),
                  let match = await Self.tmdbImportMatch(from: mapping, tmdbService: tmdbService) else {
                return (anilistId, nil)
            }
            return (anilistId, match)
        }) else { return [:] }

        var result: [Int: AniMapTMDBImportMatch] = [:]
        for (anilistId, match) in matches {
            if let match {
                result[anilistId] = match
            }
        }
        return result
    }

    func resolveLibraryMapping(anilistID: Int, format: String?) async -> TMDBSearchResult? {
        let mappings = await AniMapMappingService.shared.mappings(forAniListId: anilistID)
        guard !Task.isCancelled else { return nil }
        let eligible = mappings.filter { $0.anilistId == nil || $0.anilistId == anilistID }
        let identities = Set(eligible.compactMap { mapping -> String? in
            if mapping.mediaType?.uppercased() == "MOVIE", let id = mapping.tmdbMovieId { return "movie:\(id)" }
            if let id = mapping.tmdbShowId { return "tv:\(id)" }
            if let id = mapping.tmdbMovieId { return "movie:\(id)" }
            return nil
        })
        guard identities.count == 1, let mapping = eligible.first(where: {
            $0.tmdbShowId != nil || $0.tmdbMovieId != nil
        }) else { return nil }
        guard let identity = identities.first,
              let result = await Self.tmdbImportMatch(from: mapping, tmdbService: .shared)?.tmdbResult,
              identity == "\(result.mediaType):\(result.id)",
              format?.uppercased() != "MOVIE" || result.isMovie else { return nil }
        return result
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

    private func executeGraphQLQuery(
        _ query: String,
        token: String?,
        variables: [String: String]? = nil,
        maxRetries: Int = 3
    ) async throws -> Data {
#if DEBUG
        let diagnosticRequestID = UUID().uuidString
        let diagnosticOperation = query.contains("id_in:") ? "graphql-id-page"
            : query.contains("search:") ? "graphql-search"
            : query.contains("Page(") ? "graphql-page" : "graphql-media"
        let admissionStart = ProcessInfo.processInfo.systemUptime
#endif
        if AniListGraphQLDocumentPolicy.isReadOnly(query) {
#if DEBUG
            do {
                try await AnimeProviderHealthCenter.shared.admitAniListRead(endpoint: graphQLEndpoint)
                await AnimeMetadataLoadingValidation.requestLedger?.recordEvent(
                    provider: "AniList", stage: "read-admission", operation: diagnosticOperation,
                    requestID: diagnosticRequestID, startedAtUptime: admissionStart,
                    durationSeconds: ProcessInfo.processInfo.systemUptime - admissionStart
                )
            } catch {
                let failure = error as NSError
                await AnimeMetadataLoadingValidation.requestLedger?.recordEvent(
                    provider: "AniList", stage: "read-admission-error", operation: diagnosticOperation,
                    requestID: diagnosticRequestID, startedAtUptime: admissionStart,
                    durationSeconds: ProcessInfo.processInfo.systemUptime - admissionStart,
                    errorDomain: failure.domain, errorCode: failure.code
                )
                throw error
            }
#else
            try await AnimeProviderHealthCenter.shared.admitAniListRead(
                endpoint: graphQLEndpoint
            )
#endif
        }
        let isDetailReadyPath = AniListRequestContext.isDetailReadyPath
        let rateLimitDeadline = isDetailReadyPath
            ? Date().addingTimeInterval(2.5)
            : nil
        var request = URLRequest(url: graphQLEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = isDetailReadyPath ? 8 : 30
#if DEBUG
        if AnimeMetadataLoadingValidation.session != nil {
            request.cachePolicy = .reloadIgnoringLocalCacheData
        }
#endif

        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var body: [String: Any] = ["query": query]
        if let variables {
            body["variables"] = variables
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var lastError: Error?
        let effectiveMaxRetries = isDetailReadyPath ? 1 : maxRetries
        for attempt in 0..<effectiveMaxRetries {
#if DEBUG
            let gateStart = ProcessInfo.processInfo.systemUptime
            do {
                try await AniListRateLimiter.shared.waitForSlot(deadline: rateLimitDeadline)
                await AnimeMetadataLoadingValidation.requestLedger?.recordEvent(
                    provider: "AniList", stage: "gate-wait", operation: diagnosticOperation,
                    requestID: diagnosticRequestID, startedAtUptime: gateStart,
                    durationSeconds: ProcessInfo.processInfo.systemUptime - gateStart, attempt: attempt + 1
                )
            } catch {
                let failure = error as NSError
                await AnimeMetadataLoadingValidation.requestLedger?.recordEvent(
                    provider: "AniList", stage: "gate-error", operation: diagnosticOperation,
                    requestID: diagnosticRequestID, startedAtUptime: gateStart,
                    durationSeconds: ProcessInfo.processInfo.systemUptime - gateStart, attempt: attempt + 1,
                    errorDomain: failure.domain, errorCode: failure.code
                )
                throw error
            }
#else
            try await AniListRateLimiter.shared.waitForSlot(deadline: rateLimitDeadline)
#endif

            let data: Data
            let response: URLResponse
#if DEBUG
            let requestStart = ProcessInfo.processInfo.systemUptime
#endif
            do {
                var session = URLSession.shared
#if DEBUG
                session = AnimeMetadataLoadingValidation.session ?? session
                await AnimeMetadataLoadingValidation.requestLedger?.record(provider: "AniList")
#endif
                (data, response) = try await session.boundedData(
                    for: request,
                    maximumResponseBytes: RemoteMediaNumericBoundary.maximumMetadataResponseBytes
                )
#if DEBUG
                let requestElapsed = ProcessInfo.processInfo.systemUptime - requestStart
                await AnimeMetadataLoadingValidation.requestLedger?.recordDuration(
                    provider: "AniList", seconds: requestElapsed
                )
                await AnimeMetadataLoadingValidation.requestLedger?.recordEvent(
                    provider: "AniList", stage: "response", operation: diagnosticOperation,
                    requestID: diagnosticRequestID, startedAtUptime: requestStart,
                    durationSeconds: requestElapsed, attempt: attempt + 1,
                    statusCode: (response as? HTTPURLResponse)?.statusCode
                )
#endif
            } catch {
#if DEBUG
                let requestElapsed = ProcessInfo.processInfo.systemUptime - requestStart
                let failure = error as NSError
                await AnimeMetadataLoadingValidation.requestLedger?.recordDuration(
                    provider: "AniList", seconds: requestElapsed
                )
                await AnimeMetadataLoadingValidation.requestLedger?.recordEvent(
                    provider: "AniList", stage: "transport-error", operation: diagnosticOperation,
                    requestID: diagnosticRequestID, startedAtUptime: requestStart,
                    durationSeconds: requestElapsed, attempt: attempt + 1,
                    errorDomain: failure.domain, errorCode: failure.code
                )
#endif
                lastError = error
                if attempt < effectiveMaxRetries - 1, shouldRetryAniListTransportError(error) {
                    let delay = min(Double(attempt + 1) * 1.5, 5)
                    Logger.shared.log("AniList transport error, retry \(attempt + 1)/\(effectiveMaxRetries) after \(delay)s: \(error.localizedDescription)", type: "AniList")
#if DEBUG
                    let retryStart = ProcessInfo.processInfo.systemUptime
                    do {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        await AnimeMetadataLoadingValidation.requestLedger?.recordEvent(
                            provider: "AniList", stage: "retry-sleep", operation: diagnosticOperation,
                            requestID: diagnosticRequestID, startedAtUptime: retryStart,
                            durationSeconds: ProcessInfo.processInfo.systemUptime - retryStart,
                            attempt: attempt + 1, retryDelaySeconds: delay
                        )
                    } catch {
                        let failure = error as NSError
                        await AnimeMetadataLoadingValidation.requestLedger?.recordEvent(
                            provider: "AniList", stage: "retry-sleep-error", operation: diagnosticOperation,
                            requestID: diagnosticRequestID, startedAtUptime: retryStart,
                            durationSeconds: ProcessInfo.processInfo.systemUptime - retryStart, attempt: attempt + 1,
                            errorDomain: failure.domain, errorCode: failure.code, retryDelaySeconds: delay
                        )
                        throw error
                    }
#else
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
#endif
                    continue
                }
                throw error
            }

            if let httpResponse = response as? HTTPURLResponse {
                await AniListRateLimiter.shared.recordResponse(httpResponse)
#if DEBUG
                let resetDelay = httpResponse.statusCode == 429
                    ? AniListRateLimiter.boundedRetryAfter(httpResponse.value(forHTTPHeaderField: "Retry-After"))
                    : httpResponse.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init).flatMap {
                        $0 <= 1 ? AniListRateLimiter.boundedResetDelay(httpResponse.value(forHTTPHeaderField: "X-RateLimit-Reset")) : nil
                    }
                if let resetDelay {
                    await AnimeMetadataLoadingValidation.requestLedger?.recordEvent(
                        provider: "AniList", stage: "server-pause", operation: diagnosticOperation,
                        requestID: diagnosticRequestID, startedAtUptime: ProcessInfo.processInfo.systemUptime,
                        durationSeconds: 0, attempt: attempt + 1, statusCode: httpResponse.statusCode,
                        retryDelaySeconds: resetDelay
                    )
                }
#endif

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

                if httpResponse.statusCode == 429 {
                    lastError = NSError(domain: "AniList", code: 429, userInfo: [NSLocalizedDescriptionKey: "AniList rate limited (HTTP 429)"])
                    if attempt < effectiveMaxRetries - 1 {
                        Logger.shared.log(
                            "AniList rate limited (429); attempt \(attempt + 2)/\(effectiveMaxRetries) will honor the global server retry window",
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

        throw lastError ?? NSError(domain: "AniList", code: 429, userInfo: [NSLocalizedDescriptionKey: "AniList rate limited after \(effectiveMaxRetries) retries"])
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

    private func batchFetchAniListImportNodes(ids: [Int]) async -> [Int: AniListAnime] {
        guard !ids.isEmpty else { return [:] }

        let fragment = AniListImportMetadata.fields

        let uniqueIds = Array(Set(ids)).sorted()
        let chunkSize = 20
        var result: [Int: AniListAnime] = [:]
        var start = 0

        while start < uniqueIds.count {
            guard !Task.isCancelled else { return [:] }
            let chunk = Array(uniqueIds[start..<min(start + chunkSize, uniqueIds.count)])
            let idList = chunk.map(String.init).joined(separator: ", ")

            do {
                var pageNumber = 1
                var hasNextPage = true

                let maxPages = 4
                while hasNextPage, pageNumber <= maxPages {
                    try Task.checkCancellation()
                    let query = """
                    query {
                        Page(page: \(pageNumber), perPage: \(chunkSize)) {
                            pageInfo { hasNextPage }
                            media(id_in: [\(idList)], type: ANIME, sort: ID) {
                                \(fragment)
                            }
                        }
                    }
                    """
                    let data = try await executeGraphQLQuery(query, token: nil)
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let dataDictionary = json["data"] as? [String: Any],
                          let pageDictionary = dataDictionary["Page"] as? [String: Any],
                          let mediaArray = pageDictionary["media"] as? [Any] else {
                        break
                    }

                    for element in mediaArray {
                        guard !(element is NSNull),
                              let mediaData = try? JSONSerialization.data(withJSONObject: element),
                              let anime = try? JSONDecoder().decode(AniListAnime.self, from: mediaData) else {
                            continue
                        }
                        result[anime.id] = anime
                    }

                    hasNextPage = (pageDictionary["pageInfo"] as? [String: Any])?["hasNextPage"] as? Bool ?? false
                    pageNumber += 1
                }
            } catch {
                AnimeProviderHealthCenter.shared.recordAniListFailure(error)
                Logger.shared.log("AniListService: Import batch fetch failed for \(chunk.count) nodes: \(error.localizedDescription)", type: "AniList")
            }

            start += chunk.count
        }

        return result
    }

    private struct AniListNodeBatchResult {
        let nodes: [Int: AniListAnime]
        let isComplete: Bool
    }

    private func batchFetchAniListNodes(ids: [Int]) async -> [Int: AniListAnime] {
        await batchFetchAniListNodesResult(ids: ids).nodes
    }

    private func batchFetchAniListStructureNodesResult(ids: [Int]) async -> AniListNodeBatchResult {
        let uniqueIDs = Array(Set(ids.filter { $0 > 0 })).sorted()
        guard !uniqueIDs.isEmpty else {
            return AniListNodeBatchResult(nodes: [:], isComplete: true)
        }

        var nodes = await shallowSnapshotCache.nodes(for: uniqueIDs)
#if DEBUG
        if AnimeMetadataLoadingValidation.bypassesGraphCaches { nodes = [:] }
#endif
        let missingIDs = uniqueIDs.filter { nodes[$0] == nil }
        guard !missingIDs.isEmpty else {
            return AniListNodeBatchResult(nodes: nodes, isComplete: true)
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
            endDate { year month day }
            seasonYear
            season
            format
            type
            coverImage { large medium }
            nextAiringEpisode { episode airingAt }
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
                        endDate { year month day }
                        seasonYear
                        season
                        format
                        type
                        coverImage { large medium }
                    }
                }
            }
        """

        let chunkSize = 50
        var isComplete = true
        var start = 0
        while start < missingIDs.count {
            let chunk = Array(missingIDs[start..<min(start + chunkSize, missingIDs.count)])
            let idList = chunk.map(String.init).joined(separator: ", ")

            do {
                var pageNumber = 1
                var hasNextPage = true

                let maxPages = 4
                while hasNextPage, pageNumber <= maxPages {
                    let query = """
                    query {
                        Page(page: \(pageNumber), perPage: \(chunkSize)) {
                            pageInfo { hasNextPage }
                            media(id_in: [\(idList)], type: ANIME, sort: ID) {
                                \(fragment)
                            }
                        }
                    }
                    """
                    let data = try await executeGraphQLQuery(query, token: nil)
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let dataDictionary = json["data"] as? [String: Any],
                          let pageDictionary = dataDictionary["Page"] as? [String: Any],
                          let mediaArray = pageDictionary["media"] as? [Any] else {
                        isComplete = false
                        break
                    }

                    for element in mediaArray {
                        guard !(element is NSNull),
                              let mediaData = try? JSONSerialization.data(withJSONObject: element),
                              let anime = try? JSONDecoder().decode(AniListAnime.self, from: mediaData) else {
                            continue
                        }
                        nodes[anime.id] = anime
                    }

                    hasNextPage = (pageDictionary["pageInfo"] as? [String: Any])?["hasNextPage"] as? Bool ?? false
                    pageNumber += 1
                }
            } catch {
                if Task.isCancelled || error is CancellationError {
                    return AniListNodeBatchResult(nodes: [:], isComplete: false)
                }
                isComplete = false
                AnimeProviderHealthCenter.shared.recordAniListFailure(error)
                Logger.shared.log(
                    "AniListService: Lean structure batch failed for \(chunk.count) nodes: \(error.localizedDescription)",
                    type: "AniList"
                )
            }
            start += chunk.count
        }

        await shallowSnapshotCache.store(nodes.filter { missingIDs.contains($0.key) })

        return AniListNodeBatchResult(
            nodes: nodes,
            isComplete: isComplete && Set(uniqueIDs).isSubset(of: Set(nodes.keys))
        )
    }

    private func batchFetchAniListRelationSeedNodesResult(ids: [Int]) async -> AniListNodeBatchResult {
        await batchFetchAniListStructureNodesResult(ids: ids)
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
            endDate { year month day }
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
                        endDate { year month day }
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
                                    endDate { year month day }
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

        let requestedIDs = Set(ids)
        let fetchableIDs = Array(requestedIDs.filter { $0 > 0 }).sorted()
        let chunkSize = 25
        let maxPagesPerChunk = 4
        var result: [Int: AniListAnime] = [:]
        var didFailAnyChunk = false
        var start = 0

        while start < fetchableIDs.count {
            let chunk = Array(fetchableIDs[start..<min(start + chunkSize, fetchableIDs.count)])
            let idList = chunk.map(String.init).joined(separator: ", ")

            do {
                var pageNumber = 1
                var hasNextPage = true
                while hasNextPage, pageNumber <= maxPagesPerChunk {
                    let query = """
                    query {
                        Page(page: \(pageNumber), perPage: \(chunkSize)) {
                            pageInfo { hasNextPage }
                            media(id_in: [\(idList)], type: ANIME, sort: ID) {
                                \(fragment)
                            }
                        }
                    }
                    """
                    let data = try await executeGraphQLQuery(query, token: nil)
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let dataDictionary = json["data"] as? [String: Any],
                          let pageDictionary = dataDictionary["Page"] as? [String: Any],
                          let mediaArray = pageDictionary["media"] as? [Any] else {
                        didFailAnyChunk = true
                        break
                    }

                    for element in mediaArray {
                        guard !(element is NSNull),
                              let mediaData = try? JSONSerialization.data(withJSONObject: element),
                              let anime = try? JSONDecoder().decode(AniListAnime.self, from: mediaData) else {
                            continue
                        }
                        result[anime.id] = anime
                    }

                    hasNextPage = (pageDictionary["pageInfo"] as? [String: Any])?["hasNextPage"] as? Bool ?? false
                    pageNumber += 1
                }
            } catch {
                if Task.isCancelled || error is CancellationError {
                    return AniListNodeBatchResult(nodes: [:], isComplete: false)
                }
                didFailAnyChunk = true
                AnimeProviderHealthCenter.shared.recordAniListFailure(error)
                Logger.shared.log("AniListService: Batch fetch failed for \(chunk.count) nodes: \(error.localizedDescription)", type: "AniList")
            }

            start += chunk.count
        }

        if !result.isEmpty {
            await shallowSnapshotCache.store(result)
        }

        return AniListNodeBatchResult(
            nodes: result,
            isComplete: !didFailAnyChunk && requestedIDs.isSubset(of: Set(result.keys))
        )
    }

    func fetchNotificationSeasons(
        startingMediaIDs: [Int],
        tmdbShowId: Int? = nil,
        limit: Int = 32
    ) async -> AniListNotificationSeasonGraph {
        var visited = Set<Int>()
        var pending = startingMediaIDs.filter { $0 > 0 }
        var results: [Int: AniListNotificationSeason] = [:]
        var isComplete = true
        let regularRelationTypes: Set<String> = ["SEQUEL", "PREQUEL", "SEASON"]
        let mappingsByID: [Int: [AniMapMapping]]
        if let tmdbShowId, tmdbShowId > 0 {
            let mappingResult = await AniMapMappingService.shared.mappingsResult(
                forTMDBShowId: tmdbShowId
            )
            isComplete = isComplete && mappingResult.isComplete
            mappingsByID = Dictionary(
                grouping: mappingResult.mappings.filter { $0.tmdbShowId == tmdbShowId },
                by: { $0.anilistId ?? -1 }
            )
        } else {
            mappingsByID = [:]
        }

        while !pending.isEmpty, visited.count < limit, !Task.isCancelled {
            let takeCount = min(12, limit - visited.count, pending.count)
            let batch = Array(pending.prefix(takeCount))
                .filter { visited.insert($0).inserted }
            pending.removeFirst(takeCount)
            guard !batch.isEmpty else { continue }

            let nodeResult = await batchFetchAniListNodesResult(ids: batch)
            isComplete = isComplete && nodeResult.isComplete
            for node in nodeResult.nodes.values {
                if let isDetachedSpecial = notificationStructuralRole(
                    node,
                    mappings: mappingsByID[node.id] ?? []
                ) {
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
                        premiereDate: notificationPremiereDate(node.startDate),
                        isDetachedSpecial: isDetachedSpecial
                    )
                }

                for edge in node.relations?.edges ?? [] {
                    guard edge.node.type == "ANIME",
                          edge.node.isAdult != true else {
                        continue
                    }
                    let related = edge.node.asAnime()
                    let relatedMappings = mappingsByID[related.id] ?? []
                    guard var isDetachedSpecial = notificationStructuralRole(
                        related,
                        mappings: relatedMappings
                    ) else { continue }
                    if relatedMappings.isEmpty, isDetachedSpecialRelation(edge) {
                        isDetachedSpecial = true
                    }
                    let followsRegularGraph = regularRelationTypes.contains(edge.relationType)
                        && !isDetachedSpecial
                    guard followsRegularGraph || isDetachedSpecial else { continue }
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
                            premiereDate: notificationPremiereDate(related.startDate),
                            isDetachedSpecial: isDetachedSpecial
                        )
                    }
                    if followsRegularGraph,
                       !visited.contains(related.id),
                       !pending.contains(related.id) {
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

    private func notificationStructuralRole(
        _ anime: AniListAnime,
        mappings: [AniMapMapping]
    ) -> Bool? {
        guard anime.isAdult != true else { return nil }
        let title = AniListTitlePicker.title(
            from: anime.title,
            preferredLanguageCode: preferredLanguageCode
        ).lowercased()
        guard !["recap", "summary", "music", "trailer", " pv", " cm"].contains(where: {
            title.contains($0)
        }) else { return nil }

        if mappings.contains(where: {
            AniMapStructuralRole.isRegularStory($0, fallbackMediaType: anime.format)
        }) {
            return false
        }
        if mappings.contains(where: {
            AniMapStructuralRole.isDetachedSpecial($0, fallbackMediaType: anime.format)
        }) {
            return true
        }
        let format = anime.format?.uppercased()
        if let format, ["TV", "TV_SHORT", "ONA"].contains(format) {
            return false
        }
        if AniMapStructuralRole.isPotentialDetachedFormat(format) {
            return true
        }
        return nil
    }

    private func isDetachedSpecialRelation(_ edge: AniListAnime.AniListRelationEdge) -> Bool {
        let relationType = edge.relationType.uppercased()
        return ["SIDE_STORY", "SPIN_OFF", "OTHER", "SUMMARY", "ALTERNATIVE_VERSION"]
            .contains(relationType)
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

enum AnimeEpisodeClassification: String, Codable, Sendable {
    case filler
    case mixed
    case animeCanon
    case mangaCanon
    case unknown
}

struct AnimeEpisodeClassifications: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case values
    }

    private let values: [Int: AnimeEpisodeClassification]

    init(_ values: [Int: AnimeEpisodeClassification] = [:]) {
        let valid = values.filter {
            RemoteMediaNumericBoundary.episodeNumber($0.key) != nil && $0.value != .unknown
        }
        if valid.count <= RemoteMediaNumericBoundary.maximumEpisodeCount {
            self.values = valid
        } else {
            self.values = Dictionary(
                uniqueKeysWithValues: valid
                    .sorted { $0.key < $1.key }
                    .prefix(RemoteMediaNumericBoundary.maximumEpisodeCount)
                    .map { ($0.key, $0.value) }
            )
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decode(
            [Int: AnimeEpisodeClassification].self,
            forKey: .values
        )
        self.init(decoded)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(values, forKey: .values)
    }

    func classification(for episodeNumber: Int) -> AnimeEpisodeClassification {
        values[episodeNumber] ?? .unknown
    }

    func shouldSkip(episodeNumber: Int) -> Bool {
        classification(for: episodeNumber) == .filler
    }

    var explicitFillerCount: Int {
        values.values.lazy.filter { $0 == .filler }.count
    }
}

enum AnimeFillerCacheFreshness: Equatable {
    case fresh
    case stale
    case expired
}

enum AnimeFillerCachePolicy {
    static let freshMaxAge: TimeInterval = 24 * 60 * 60
    static let staleMaxAge: TimeInterval = 7 * 24 * 60 * 60
    static let maximumFutureClockSkew: TimeInterval = 5 * 60
    static let maximumEntryCount = 512
    static let maximumFileBytes = 2 * 1_024 * 1_024

    static func freshness(
        storedAt: TimeInterval,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> AnimeFillerCacheFreshness {
        guard storedAt.isFinite,
              now.isFinite,
              storedAt <= now + maximumFutureClockSkew else {
            return .expired
        }
        let age = max(0, now - storedAt)
        if age <= freshMaxAge {
            return .fresh
        }
        if age <= staleMaxAge {
            return .stale
        }
        return .expired
    }
}

enum AnimeFillerRequestPolicy {
    static let maximumAttempts = 2
    static let maximumPageCount = 256
    static let maximumRowsPerPage = 1_000
    static let requestTimeout: TimeInterval = 10
    static let interPageDelay: TimeInterval = 0.4
    static let maximumRetryDelay: TimeInterval = 3

    static func shouldRetry(statusCode: Int) -> Bool {
        statusCode == 408
            || statusCode == 425
            || statusCode == 429
            || (500...599).contains(statusCode)
    }

    static func shouldRetry(error: Error) -> Bool {
        if let urlError = error as? URLError {
            return [
                .timedOut,
                .cannotFindHost,
                .cannotConnectToHost,
                .dnsLookupFailed,
                .networkConnectionLost
            ].contains(urlError.code)
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

    static func retryDelay(
        retryAfterValue: String?,
        attempt: Int,
        now: Date = Date()
    ) -> TimeInterval {
        if let retryAfterValue,
           let serverDelay = parsedRetryAfter(retryAfterValue, now: now),
           serverDelay > 0 {
            return min(serverDelay, maximumRetryDelay)
        }
        let exponent = min(max(attempt, 0), 8)
        let delay = 0.6 * pow(2, Double(exponent))
        return min(delay, maximumRetryDelay)
    }

    static func nanoseconds(for seconds: TimeInterval) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let scaled = (seconds * 1_000_000_000).rounded(.up)
        guard scaled.isFinite, scaled > 0 else { return UInt64.max }
        return UInt64(exactly: scaled) ?? UInt64.max
    }

    private static func parsedRetryAfter(_ rawValue: String, now: Date) -> TimeInterval? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(trimmed), seconds.isFinite, seconds >= 0 {
            return seconds
        }

        let formatter = AppCalendar.dateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in [
            "EEE',' dd MMM yyyy HH':'mm':'ss z",
            "EEEE',' dd-MMM-yy HH':'mm':'ss z",
            "EEE MMM d HH':'mm':'ss yyyy"
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                let delay = date.timeIntervalSince(now)
                return delay.isFinite ? max(0, delay) : nil
            }
        }
        return nil
    }
}

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

    private struct CacheEntry: Codable {
        let classifications: AnimeEpisodeClassifications
        let storedAt: TimeInterval
    }

    private enum MetadataSource: String {
        case jikan
        case tenrai

        var baseURL: String {
            switch self {
            case .jikan:
                return "https://api.jikan.moe/v4"
            case .tenrai:
                return "https://api.tenrai.org/v1"
            }
        }
    }

    private enum ServiceError: LocalizedError {
        case invalidURL
        case invalidResponse
        case httpStatus(Int)
        case allSourcesFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "The filler metadata URL is invalid."
            case .invalidResponse:
                return "The filler metadata response was invalid."
            case .httpStatus(let status):
                return "The filler metadata request returned HTTP \(status)."
            case .allSourcesFailed(let primary, let fallback):
                return "Both filler metadata services failed. Jikan: \(primary) Tenrai: \(fallback)"
            }
        }
    }

    private let session: URLSession
    private let cacheFileURL: URL?
    private var cachedEntries: [Int: CacheEntry]
    private var inFlightRequests: [Int: Task<AnimeEpisodeClassifications, Error>] = [:]

    init(session: URLSession = .shared, cacheFileURL: URL? = nil) {
        self.session = session
        let resolvedCacheFileURL = cacheFileURL ?? FileManager.default
            .eclipseCachesDirectories
            .first?
            .appendingPathComponent("anime-filler-cache-v2.json")
        self.cacheFileURL = resolvedCacheFileURL
        self.cachedEntries = resolvedCacheFileURL.map(Self.loadCache) ?? [:]
    }

    func episodeClassifications(malId: Int) async throws -> AnimeEpisodeClassifications {
        try Task.checkCancellation()
        guard let normalizedId = RemoteMediaNumericBoundary.positiveMagnitude(malId) else {
            return AnimeEpisodeClassifications()
        }

        if let cached = cachedClassifications(malId: normalizedId, allowsStale: false) {
            return cached
        }
        let stale = cachedClassifications(malId: normalizedId, allowsStale: true)

        if let inFlight = inFlightRequests[normalizedId] {
            do {
                let classifications = try await inFlight.value
                try Task.checkCancellation()
                return classifications
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if let stale { return stale }
                throw error
            }
        }

        let session = session
        let task = Task {
            try await Self.fetchEpisodeClassifications(
                malId: normalizedId,
                session: session
            )
        }
        inFlightRequests[normalizedId] = task

        do {
            let classifications = try await task.value
            cachedEntries[normalizedId] = CacheEntry(
                classifications: classifications,
                storedAt: Date().timeIntervalSince1970
            )
            pruneCache()
            persistCache()
            inFlightRequests[normalizedId] = nil
            try Task.checkCancellation()
            return classifications
        } catch is CancellationError {
            inFlightRequests[normalizedId] = nil
            throw CancellationError()
        } catch {
            inFlightRequests[normalizedId] = nil
            if let stale { return stale }
            throw error
        }
    }

    private func cachedClassifications(
        malId: Int,
        allowsStale: Bool
    ) -> AnimeEpisodeClassifications? {
        guard let entry = cachedEntries[malId] else { return nil }
        switch AnimeFillerCachePolicy.freshness(storedAt: entry.storedAt) {
        case .fresh:
            return entry.classifications
        case .stale:
            return allowsStale ? entry.classifications : nil
        case .expired:
            cachedEntries[malId] = nil
            return nil
        }
    }

    private func pruneCache() {
        cachedEntries = cachedEntries.filter {
            AnimeFillerCachePolicy.freshness(storedAt: $0.value.storedAt) != .expired
        }
        guard cachedEntries.count > AnimeFillerCachePolicy.maximumEntryCount else { return }
        cachedEntries = Dictionary(
            uniqueKeysWithValues: cachedEntries
                .sorted { $0.value.storedAt > $1.value.storedAt }
                .prefix(AnimeFillerCachePolicy.maximumEntryCount)
                .map { ($0.key, $0.value) }
        )
    }

    private func persistCache() {
        guard let cacheFileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: cacheFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(cachedEntries)
            guard data.count <= AnimeFillerCachePolicy.maximumFileBytes else {
                throw ServiceError.invalidResponse
            }
            try data.write(to: cacheFileURL, options: .atomic)
        } catch {
            Logger.shared.log(
                "AnimeFiller: cache persist failed error=\(error.localizedDescription)",
                type: "AniList"
            )
        }
    }

    private static func loadCache(from fileURL: URL) -> [Int: CacheEntry] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue <= AnimeFillerCachePolicy.maximumFileBytes,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Int: CacheEntry].self, from: data) else {
            return [:]
        }
        let retained = decoded.filter {
            RemoteMediaNumericBoundary.positiveIdentifier($0.key) != nil
                && AnimeFillerCachePolicy.freshness(storedAt: $0.value.storedAt) != .expired
        }
        guard retained.count > AnimeFillerCachePolicy.maximumEntryCount else {
            return retained
        }
        return Dictionary(
            uniqueKeysWithValues: retained
                .sorted { $0.value.storedAt > $1.value.storedAt }
                .prefix(AnimeFillerCachePolicy.maximumEntryCount)
                .map { ($0.key, $0.value) }
        )
    }

    private static func fetchEpisodeClassifications(
        malId: Int,
        session: URLSession
    ) async throws -> AnimeEpisodeClassifications {
        do {
            return try await fetchEpisodeClassifications(
                malId: malId,
                source: .jikan,
                session: session
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let primaryDescription = error.localizedDescription
            Logger.shared.log(
                "AnimeFiller: Jikan failed malId=\(malId) error=\(primaryDescription); trying Tenrai",
                type: "AniList"
            )
            do {
                return try await fetchEpisodeClassifications(
                    malId: malId,
                    source: .tenrai,
                    session: session
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ServiceError.allSourcesFailed(
                    primaryDescription,
                    error.localizedDescription
                )
            }
        }
    }

    private static func fetchEpisodeClassifications(
        malId: Int,
        source: MetadataSource,
        session: URLSession
    ) async throws -> AnimeEpisodeClassifications {
        var page = 1
        var processedRowCount = 0
        var classifications: [Int: AnimeEpisodeClassification] = [:]

        while true {
            let decoded = try await fetchPage(
                malId: malId,
                page: page,
                source: source,
                session: session
            )
            guard decoded.data.count <= AnimeFillerRequestPolicy.maximumRowsPerPage,
                  processedRowCount <= RemoteMediaNumericBoundary.maximumTotalEpisodeCount - decoded.data.count else {
                throw ServiceError.invalidResponse
            }
            processedRowCount += decoded.data.count

            for episode in decoded.data where episode.filler {
                guard let episodeNumber = RemoteMediaNumericBoundary.episodeNumber(episode.number) else {
                    continue
                }
                classifications[episodeNumber] = .filler
            }

            guard decoded.pagination.hasNextPage else { break }
            guard page < AnimeFillerRequestPolicy.maximumPageCount else {
                throw ServiceError.invalidResponse
            }
            page += 1
            try await Task.sleep(
                nanoseconds: AnimeFillerRequestPolicy.nanoseconds(
                    for: AnimeFillerRequestPolicy.interPageDelay
                )
            )
        }

        return AnimeEpisodeClassifications(classifications)
    }

    private static func fetchPage(
        malId: Int,
        page: Int,
        source: MetadataSource,
        session: URLSession
    ) async throws -> EpisodesResponse {
        guard var components = URLComponents(
            string: "\(source.baseURL)/anime/\(malId)/episodes"
        ) else {
            throw ServiceError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "page", value: String(page))]
        guard let url = components.url else { throw ServiceError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = AnimeFillerRequestPolicy.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var lastError: Error?

        for attempt in 0..<AnimeFillerRequestPolicy.maximumAttempts {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.boundedData(
                    for: request,
                    maximumResponseBytes: RemoteMediaNumericBoundary.maximumMetadataResponseBytes
                )
            } catch {
                lastError = error
                guard attempt + 1 < AnimeFillerRequestPolicy.maximumAttempts,
                      AnimeFillerRequestPolicy.shouldRetry(error: error) else {
                    throw error
                }
                let delay = AnimeFillerRequestPolicy.retryDelay(
                    retryAfterValue: nil,
                    attempt: attempt
                )
                try await Task.sleep(
                    nanoseconds: AnimeFillerRequestPolicy.nanoseconds(for: delay)
                )
                continue
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ServiceError.invalidResponse
            }
            if (200..<300).contains(httpResponse.statusCode) {
                return try JSONDecoder().decode(EpisodesResponse.self, from: data)
            }

            let error = ServiceError.httpStatus(httpResponse.statusCode)
            lastError = error
            guard attempt + 1 < AnimeFillerRequestPolicy.maximumAttempts,
                  AnimeFillerRequestPolicy.shouldRetry(statusCode: httpResponse.statusCode) else {
                throw error
            }
            let delay = AnimeFillerRequestPolicy.retryDelay(
                retryAfterValue: httpResponse.value(forHTTPHeaderField: "Retry-After"),
                attempt: attempt
            )
            try await Task.sleep(
                nanoseconds: AnimeFillerRequestPolicy.nanoseconds(for: delay)
            )
        }

        throw lastError ?? ServiceError.invalidResponse
    }
}

struct AnimeCanonicalEpisodeRange: Codable, Equatable, Sendable {
    let lowerBound: Int
    let upperBound: Int

    var range: ClosedRange<Int>? {
        guard lowerBound > 0, lowerBound <= upperBound,
              upperBound <= RemoteMediaNumericBoundary.maximumEpisodeCount else { return nil }
        return lowerBound...upperBound
    }
}

struct AnimeEpisodeUnitProjection: Codable, Equatable, Sendable {
    enum Edition: String, Codable, Sendable {
        case compilation
        case feature
        case featurePart
        case unverified
    }

    let edition: Edition
    let canonicalAniListEpisodeRange: AnimeCanonicalEpisodeRange?
    let canonicalMALEpisodeRange: AnimeCanonicalEpisodeRange?
    let tmdbMovieID: Int?
    let physicalPartOrdinal: Int?
    let physicalPartCount: Int?

    var featureIMDbID: String? {
        edition == .feature && tmdbMovieID == AnimeVerifiedEpisodeUnitPolicy.razbliutoMovieID ? "tt30827040" : nil
    }

    private enum CodingKeys: String, CodingKey {
        case edition, canonicalAniListEpisodeRange, canonicalMALEpisodeRange
        case tmdbMovieID, physicalPartOrdinal, physicalPartCount
    }

    init(
        edition: Edition,
        canonicalAniListEpisodeRange: AnimeCanonicalEpisodeRange?,
        canonicalMALEpisodeRange: AnimeCanonicalEpisodeRange?,
        tmdbMovieID: Int? = nil,
        physicalPartOrdinal: Int? = nil,
        physicalPartCount: Int? = nil
    ) {
        let validRanges = [canonicalAniListEpisodeRange, canonicalMALEpisodeRange]
            .compactMap { $0 }.allSatisfy { $0.range != nil }
        let hasRange = canonicalAniListEpisodeRange != nil || canonicalMALEpisodeRange != nil
        let validEdition: Bool
        switch edition {
        case .compilation:
            validEdition = tmdbMovieID == nil && physicalPartOrdinal == nil && physicalPartCount == nil
        case .feature:
            validEdition = RemoteMediaNumericBoundary.positiveIdentifier(tmdbMovieID) != nil
                && physicalPartOrdinal == nil && physicalPartCount == nil
        case .featurePart:
            validEdition = tmdbMovieID == nil && physicalPartOrdinal.map { ordinal in
                physicalPartCount.map { count in count >= 2 && count <= 64 && ordinal >= 1 && ordinal <= count } ?? false
            } == true
        case .unverified:
            validEdition = false
        }
        let trusted = validRanges && hasRange && validEdition
        self.edition = trusted ? edition : .unverified
        self.canonicalAniListEpisodeRange = trusted ? canonicalAniListEpisodeRange : nil
        self.canonicalMALEpisodeRange = trusted ? canonicalMALEpisodeRange : nil
        self.tmdbMovieID = trusted ? tmdbMovieID : nil
        self.physicalPartOrdinal = trusted ? physicalPartOrdinal : nil
        self.physicalPartCount = trusted ? physicalPartCount : nil
    }

    init(from decoder: Decoder) throws {
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let rawEdition = try container.decode(String.self, forKey: .edition)
            self.init(
                edition: Edition(rawValue: rawEdition) ?? .unverified,
                canonicalAniListEpisodeRange: try container.decodeIfPresent(AnimeCanonicalEpisodeRange.self, forKey: .canonicalAniListEpisodeRange),
                canonicalMALEpisodeRange: try container.decodeIfPresent(AnimeCanonicalEpisodeRange.self, forKey: .canonicalMALEpisodeRange),
                tmdbMovieID: try container.decodeIfPresent(Int.self, forKey: .tmdbMovieID),
                physicalPartOrdinal: try container.decodeIfPresent(Int.self, forKey: .physicalPartOrdinal),
                physicalPartCount: try container.decodeIfPresent(Int.self, forKey: .physicalPartCount)
            )
        } catch {
            self.init(edition: .unverified, canonicalAniListEpisodeRange: nil, canonicalMALEpisodeRange: nil)
        }
    }
    func forPhysicalEpisodeNumber(_ number: Int) -> AnimeEpisodeUnitProjection {
        let unverified = AnimeEpisodeUnitProjection(edition: .unverified,
            canonicalAniListEpisodeRange: nil, canonicalMALEpisodeRange: nil)
        switch edition {
        case .compilation:
            guard canonicalAniListEpisodeRange == canonicalMALEpisodeRange,
                  let currentRange = canonicalAniListEpisodeRange,
                  AnimeVerifiedEpisodeUnitPolicy.saikiCanonicalGroups.contains(currentRange),
                  (1...AnimeVerifiedEpisodeUnitPolicy.saikiCanonicalGroups.count).contains(number) else { return unverified }
            let canonicalRange = AnimeVerifiedEpisodeUnitPolicy.saikiCanonicalGroups[number - 1]
            return .init(edition: .compilation, canonicalAniListEpisodeRange: canonicalRange,
                canonicalMALEpisodeRange: canonicalRange)
        case .feature:
            guard number == 1, tmdbMovieID == AnimeVerifiedEpisodeUnitPolicy.razbliutoMovieID,
                  canonicalAniListEpisodeRange == .init(lowerBound: 1, upperBound: 1),
                  canonicalMALEpisodeRange == .init(lowerBound: 1, upperBound: 4) else { return unverified }
            return self
        case .featurePart:
            guard physicalPartCount == 4, let ordinal = physicalPartOrdinal, (1...4).contains(ordinal),
                  canonicalAniListEpisodeRange == .init(lowerBound: 1, upperBound: 1),
                  canonicalMALEpisodeRange == .init(lowerBound: ordinal, upperBound: ordinal),
                  (1...AnimeVerifiedEpisodeUnitPolicy.razbliutoCanonicalPartGroups.count).contains(number) else { return unverified }
            return .init(edition: .featurePart, canonicalAniListEpisodeRange: canonicalAniListEpisodeRange,
                canonicalMALEpisodeRange: AnimeVerifiedEpisodeUnitPolicy.razbliutoCanonicalPartGroups[number - 1],
                physicalPartOrdinal: number, physicalPartCount: 4)
        case .unverified:
            return unverified
        }
    }
}

enum AnimeVerifiedEpisodeUnitPolicy {
    static let saikiOfficialCatalogURL = "https://anime10th.saikikusuo.com/list.json"
    static let saikiOfficialStoryURL = "https://www.saikikusuo.com/season1/story/backnumber5.html"
    static let saikiOfficialCatalogSnapshotSHA256 = "909af8a7cd6b76c650271c6b3ae28e591c49cd31f14819a48879360a6cb0e933"
    static let razbliutoFeatureURL = "https://www.crunchyroll.com/series/GJ0H7QG4K/great-pretender-razbliuto"
    static let razbliutoPartsURL = "https://prtimes.jp/main/html/rd/p/000000113.000122725.html"
    static let razbliutoMovieID = 1_220_441
    static let razbliutoCanonicalPartGroups: [AnimeCanonicalEpisodeRange] = [
        .init(lowerBound: 1, upperBound: 1), .init(lowerBound: 2, upperBound: 2),
        .init(lowerBound: 3, upperBound: 3), .init(lowerBound: 4, upperBound: 4)
    ]

    static func hasNoKnownSaikiOwnerConflict(
        tmdbShowID: Int, aniListID: Int?, malID: Int?, mappings: [AniMapMapping], hasOtherProvedOwner: Bool
    ) -> Bool {
        guard tmdbShowID == 67_676, aniListID == 21_804 || (aniListID == nil && malID == 33_255),
              malID == nil || malID == 33_255 else { return false }
        return hasNoKnownOwnerConflict(tmdbShowID: tmdbShowID, aniListID: 21_804, malID: 33_255,
            seasonNumber: 1, mappings: mappings, hasOtherProvedOwner: hasOtherProvedOwner)
    }

    static func hasNoKnownRazbliutoPartOwnerConflict(
        tmdbShowID: Int, malID: Int?, mappings: [AniMapMapping], hasOtherProvedOwner: Bool
    ) -> Bool {
        guard tmdbShowID == 93_816, malID == 57_184 else { return false }
        return hasNoKnownOwnerConflict(tmdbShowID: tmdbShowID, aniListID: 170_935, malID: 57_184,
            seasonNumber: 2, mappings: mappings, hasOtherProvedOwner: hasOtherProvedOwner)
    }

    private static func hasNoKnownOwnerConflict(
        tmdbShowID: Int, aniListID: Int, malID: Int, seasonNumber: Int,
        mappings: [AniMapMapping], hasOtherProvedOwner: Bool
    ) -> Bool {
        guard !hasOtherProvedOwner, mappings.count <= AniMapResponseBoundary.maximumLookupRows else { return false }
        return mappings.allSatisfy { mapping in
            guard mapping.tmdbShowId == tmdbShowID else { return true }
            let sameIdentity = mapping.anilistId == aniListID || mapping.malId == malID
            if sameIdentity, let sourceSeason = mapping.tmdbSeason, sourceSeason > 0, sourceSeason != seasonNumber { return false }
            guard mapping.tmdbSeason == seasonNumber else { return true }
            return sameIdentity && (mapping.anilistId == nil || mapping.anilistId == aniListID)
                && (mapping.malId == nil || mapping.malId == malID)
        }
    }

    static func validatesProjection(
        _ projection: AnimeEpisodeUnitProjection, tmdbShowID: Int,
        aniListID: Int?, malID: Int?, localEpisodeNumber: Int,
        tmdbSeasonNumber: Int?, tmdbEpisodeNumber: Int?
    ) -> Bool {
        switch projection.edition {
        case .compilation:
            guard tmdbShowID == 67_676,
                  projection.tmdbMovieID == nil, projection.physicalPartOrdinal == nil,
                  projection.physicalPartCount == nil,
                  aniListID == 21_804 || (aniListID == nil && malID == 33_255),
                  malID == nil || malID == 33_255, tmdbSeasonNumber == 1,
                  tmdbEpisodeNumber == localEpisodeNumber,
                  (1...saikiCanonicalGroups.count).contains(localEpisodeNumber) else { return false }
            let expected = saikiCanonicalGroups[localEpisodeNumber - 1]
            return projection.canonicalAniListEpisodeRange == expected && projection.canonicalMALEpisodeRange == expected
        case .feature:
            return tmdbShowID == 93_816 && aniListID == 170_935 && (malID == nil || malID == 57_184)
                && projection.physicalPartOrdinal == nil && projection.physicalPartCount == nil
                && localEpisodeNumber == 1 && tmdbSeasonNumber == nil && tmdbEpisodeNumber == nil
                && projection.tmdbMovieID == razbliutoMovieID
                && projection.canonicalAniListEpisodeRange == .init(lowerBound: 1, upperBound: 1)
                && projection.canonicalMALEpisodeRange == .init(lowerBound: 1, upperBound: 4)
        case .featurePart:
            return tmdbShowID == 93_816 && (aniListID == nil || aniListID == 170_935) && malID == 57_184
                && projection.tmdbMovieID == nil
                && (1...4).contains(localEpisodeNumber) && tmdbSeasonNumber == 2 && tmdbEpisodeNumber == localEpisodeNumber
                && projection.physicalPartOrdinal == localEpisodeNumber && projection.physicalPartCount == 4
                && projection.canonicalAniListEpisodeRange == .init(lowerBound: 1, upperBound: 1)
                && projection.canonicalMALEpisodeRange == .init(lowerBound: localEpisodeNumber, upperBound: localEpisodeNumber)
        case .unverified:
            return false
        }
    }

    static func validatesInventory(
        _ episodes: [AniListEpisode], tmdbShowID: Int, aniListID: Int?, malID: Int?
    ) -> Bool {
        guard let first = episodes.first, let edition = first.unitProjection?.edition else { return false }
        let requiredCount: Int
        switch edition {
        case .compilation: requiredCount = saikiCanonicalGroups.count
        case .feature: requiredCount = 1
        case .featurePart: requiredCount = razbliutoCanonicalPartGroups.count
        case .unverified: return false
        }
        guard episodes.count == requiredCount,
              Set(episodes.map(\.number)).count == requiredCount else { return false }
        return episodes.sorted { $0.number < $1.number }.enumerated().allSatisfy { index, episode in
            guard episode.number == index + 1, episode.seasonNumber == first.seasonNumber,
                  let projection = episode.unitProjection, projection.edition == edition else { return false }
            return validatesProjection(projection, tmdbShowID: tmdbShowID, aniListID: aniListID,
                malID: malID, localEpisodeNumber: episode.number,
                tmdbSeasonNumber: episode.tmdbSeasonNumber, tmdbEpisodeNumber: episode.tmdbEpisodeNumber)
        }
    }

    static func requiresVerifiedInventory(tmdbShowID: Int, aniListID: Int?, malID: Int?) -> Bool {
        (tmdbShowID == 67_676 && (aniListID == 21_804 || malID == 33_255))
            || (tmdbShowID == 93_816 && (aniListID == 170_935 || malID == 57_184))
    }

    static func canonicalAniListCount(_ episodes: [AniListEpisode]) -> Int? {
        guard !episodes.isEmpty, episodes.allSatisfy({ $0.unitProjection?.edition != .unverified
            && $0.unitProjection?.canonicalAniListEpisodeRange?.range != nil }) else { return nil }
        return episodes.compactMap { $0.unitProjection?.canonicalAniListEpisodeRange?.upperBound }.max()
    }

    static func canonicalMALCount(_ episodes: [AniListEpisode]) -> Int? {
        guard !episodes.isEmpty, episodes.allSatisfy({ $0.unitProjection?.edition != .unverified
            && $0.unitProjection?.canonicalMALEpisodeRange?.range != nil }) else { return nil }
        return episodes.compactMap { $0.unitProjection?.canonicalMALEpisodeRange?.upperBound }.max()
    }

    static let saikiCanonicalGroups: [AnimeCanonicalEpisodeRange] = [
        .init(lowerBound: 1, upperBound: 5), .init(lowerBound: 6, upperBound: 10),
        .init(lowerBound: 11, upperBound: 15), .init(lowerBound: 16, upperBound: 20),
        .init(lowerBound: 21, upperBound: 25), .init(lowerBound: 26, upperBound: 30),
        .init(lowerBound: 31, upperBound: 35), .init(lowerBound: 36, upperBound: 40),
        .init(lowerBound: 41, upperBound: 45), .init(lowerBound: 46, upperBound: 50),
        .init(lowerBound: 51, upperBound: 55), .init(lowerBound: 56, upperBound: 60),
        .init(lowerBound: 61, upperBound: 65), .init(lowerBound: 66, upperBound: 70),
        .init(lowerBound: 71, upperBound: 75), .init(lowerBound: 76, upperBound: 80),
        .init(lowerBound: 81, upperBound: 85), .init(lowerBound: 86, upperBound: 90),
        .init(lowerBound: 91, upperBound: 95), .init(lowerBound: 96, upperBound: 100),
        .init(lowerBound: 101, upperBound: 105), .init(lowerBound: 106, upperBound: 110),
        .init(lowerBound: 111, upperBound: 115), .init(lowerBound: 116, upperBound: 120)
    ]

    static let saikiSourceEpisodeIDs = [
        1_219_718, 1_243_370, 1_243_374, 1_243_376, 1_243_377, 1_243_378,
        1_243_379, 1_243_380, 1_243_381, 1_243_382, 1_243_383, 1_243_384,
        1_243_385, 1_243_386, 1_243_387, 1_243_388, 1_243_389, 1_243_390,
        1_243_391, 1_243_392, 1_370_413, 1_370_415, 1_370_416, 1_370_417
    ]

    static func requiresSaikiCompilations(
        tmdbShowID: Int, aniListID: Int?, malID: Int?, episodeCount: Int?,
        format: String?, status: String?, startDate: String?, endDate: String?,
        hasUniqueSourceOwner: Bool
    ) -> Bool {
        tmdbShowID == 67_676 && (aniListID == 21_804 || (aniListID == nil && malID == 33_255))
            && (malID == nil || malID == 33_255) && episodeCount == 120 && hasUniqueSourceOwner
            && ["TV", "TV_SHORT"].contains(format?.uppercased() ?? "")
            && ["FINISHED", "FINISHED_AIRING"].contains(status?.uppercased() ?? "")
            && startDate == "2016-07-04" && endDate == "2016-12-26"
    }

    static func saikiCompiledEpisodes(
        tmdbShowID: Int, aniListID: Int?, malID: Int?, episodeCount: Int?,
        format: String?, status: String?, startDate: String?, endDate: String?,
        hasUniqueSourceOwner: Bool, sourceSeason: TMDBSeasonDetail, displaySeasonNumber: Int
    ) -> [AniListEpisode]? {
        guard requiresSaikiCompilations(tmdbShowID: tmdbShowID, aniListID: aniListID, malID: malID,
            episodeCount: episodeCount, format: format, status: status, startDate: startDate,
            endDate: endDate, hasUniqueSourceOwner: hasUniqueSourceOwner),
              sourceSeason.id == 79_808, sourceSeason.seasonNumber == 1,
              RemoteMediaNumericBoundary.seasonNumber(displaySeasonNumber) != nil,
              let ordered = verifiedSourceEpisodes(sourceSeason, count: 24),
              ordered.map(\.id) == saikiSourceEpisodeIDs,
              ordered.first?.airDate == "2016-07-11", ordered.last?.airDate == "2016-12-26",
              ordered.allSatisfy({ $0.runtime.map { (20...30).contains($0) } == true }) else { return nil }
        return zip(ordered, saikiCanonicalGroups).map { source, canonicalRange in
            episode(source: source, displaySeasonNumber: displaySeasonNumber,
                projection: .init(edition: .compilation, canonicalAniListEpisodeRange: canonicalRange,
                    canonicalMALEpisodeRange: canonicalRange))
        }
    }

    static func requiresRazbliutoFeature(
        tmdbShowID: Int, aniListID: Int?, malID: Int?, episodeCount: Int?,
        format: String?, status: String?, startDate: String?
    ) -> Bool {
        tmdbShowID == 93_816 && aniListID == 170_935 && (malID == nil || malID == 57_184)
            && episodeCount == 1 && format?.uppercased() == "ONA"
            && status?.uppercased() == "FINISHED" && startDate == "2024-02-23"
    }

    static func razbliutoFeatureEpisode(
        tmdbShowID: Int, aniListID: Int?, malID: Int?, episodeCount: Int?,
        format: String?, status: String?, startDate: String?,
        movie: TMDBMovieDetail, displaySeasonNumber: Int
    ) -> AniListEpisode? {
        guard requiresRazbliutoFeature(tmdbShowID: tmdbShowID, aniListID: aniListID, malID: malID,
            episodeCount: episodeCount, format: format, status: status, startDate: startDate),
              let episode = razbliutoMovieEpisode(movie: movie, displaySeasonNumber: displaySeasonNumber) else { return nil }
        return episode
    }

    static func razbliutoMovieEpisode(movie: TMDBMovieDetail, displaySeasonNumber: Int) -> AniListEpisode? {
        guard movie.id == razbliutoMovieID, movie.imdbId == "tt30827040",
              RemoteMediaNumericBoundary.seasonNumber(displaySeasonNumber) != nil,
              movie.originalTitle?.lowercased() == "great pretender razbliuto",
              movie.releaseDate == "2024-01-09", movie.runtime.map { (88...90).contains($0) } == true,
              movie.genres.contains(where: { $0.id == 16 }) else { return nil }
        return AniListEpisode(number: 1, title: movie.title, description: movie.overview,
            seasonNumber: displaySeasonNumber, stillPath: movie.backdropPath,
            airDate: movie.releaseDate, runtime: movie.runtime, tmdbSeasonNumber: nil,
            tmdbEpisodeNumber: nil, unitProjection: .init(edition: .feature,
                canonicalAniListEpisodeRange: .init(lowerBound: 1, upperBound: 1),
                canonicalMALEpisodeRange: .init(lowerBound: 1, upperBound: 4), tmdbMovieID: movie.id))
    }

    static func requiresRazbliutoParts(
        tmdbShowID: Int, malID: Int?, episodeCount: Int?, format: String?, status: String?, startDate: String?
    ) -> Bool {
        tmdbShowID == 93_816 && malID == 57_184 && episodeCount == 4 && format?.uppercased() == "ONA"
            && ["FINISHED", "FINISHED_AIRING"].contains(status?.uppercased() ?? "") && startDate == "2024-02-23"
    }

    static func razbliutoPartEpisodes(
        tmdbShowID: Int, malID: Int?, episodeCount: Int?, format: String?, status: String?, startDate: String?,
        sourceSeason: TMDBSeasonDetail, displaySeasonNumber: Int, hasUniqueSourceOwner: Bool = true
    ) -> [AniListEpisode]? {
        guard requiresRazbliutoParts(tmdbShowID: tmdbShowID, malID: malID, episodeCount: episodeCount,
            format: format, status: status, startDate: startDate), sourceSeason.id == 380_779,
              RemoteMediaNumericBoundary.seasonNumber(displaySeasonNumber) != nil,
              hasUniqueSourceOwner, sourceSeason.seasonNumber == 2, let ordered = verifiedSourceEpisodes(sourceSeason, count: 4),
              ordered.map(\.id) == [5_167_933, 5_167_934, 5_167_935, 5_167_936],
              ordered.allSatisfy({ $0.airDate == "2024-02-23" && $0.runtime.map { (20...30).contains($0) } == true }) else { return nil }
        return ordered.map { source in
            episode(source: source, displaySeasonNumber: displaySeasonNumber,
                projection: .init(edition: .featurePart,
                    canonicalAniListEpisodeRange: .init(lowerBound: 1, upperBound: 1),
                    canonicalMALEpisodeRange: .init(lowerBound: source.episodeNumber, upperBound: source.episodeNumber),
                    physicalPartOrdinal: source.episodeNumber, physicalPartCount: 4))
        }
    }

    private static func verifiedSourceEpisodes(_ source: TMDBSeasonDetail, count: Int) -> [TMDBEpisode]? {
        guard source.episodes.count == count,
              Set(source.episodes.map(\.id)).count == count else { return nil }
        let ordered = source.episodes.sorted { $0.episodeNumber < $1.episodeNumber }
        guard ordered.enumerated().allSatisfy({ index, sourceEpisode in
            RemoteMediaNumericBoundary.positiveIdentifier(sourceEpisode.id) != nil
                && sourceEpisode.seasonNumber == source.seasonNumber && sourceEpisode.episodeNumber == index + 1
                && AnimeStructurePolicy.validatedAirDateString(sourceEpisode.airDate) != nil
                && !sourceEpisode.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }), zip(ordered, ordered.dropFirst()).allSatisfy({ ($0.0.airDate ?? "") <= ($0.1.airDate ?? "") }) else { return nil }
        return ordered
    }

    private static func episode(
        source: TMDBEpisode, displaySeasonNumber: Int, projection: AnimeEpisodeUnitProjection
    ) -> AniListEpisode {
        AniListEpisode(number: source.episodeNumber, title: source.name, description: source.overview,
            seasonNumber: displaySeasonNumber, stillPath: source.stillPath, airDate: source.airDate,
            runtime: source.runtime, tmdbSeasonNumber: source.seasonNumber,
            tmdbEpisodeNumber: source.episodeNumber, unitProjection: projection)
    }
}

protocol AniListEpisodeProtocol {
    var number: Int { get }
    var title: String { get }
    var description: String? { get }
    var seasonNumber: Int { get }
}

struct AniListEpisode: AniListEpisodeProtocol, Codable {
    let number: Int
    let title: String
    let description: String?
    let seasonNumber: Int
    let stillPath: String?
    let airDate: String?
    let runtime: Int?
    let tmdbSeasonNumber: Int?
    let tmdbEpisodeNumber: Int?
    var unitProjection: AnimeEpisodeUnitProjection? = nil
}

struct AniListAiringScheduleEntry: Identifiable, Codable, Sendable {
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
    var scheduleProvider: ScheduleProvider? = nil
    var malID: Int? = nil
    var airingTimeWithdrawn: Bool? = nil
}

struct AnimeAiringScheduleResult: Sendable {
    let entries: [AniListAiringScheduleEntry]
    let isAuthoritativeForNotifications: Bool
    var notice: String? = nil
}

struct AniListSeasonWithPoster: Codable {
    let seasonNumber: Int
    let anilistId: Int
    let canonicalAniListId: Int?
    let malId: Int?
    let kitsuId: Int?
    let title: String
    let englishTitle: String?
    let romajiTitle: String?
    let nativeTitle: String?
    let episodes: [AniListEpisode]
    let posterUrl: String?
    var canonicalAniListEpisodeCount: Int? = nil
    var canonicalMALEpisodeCount: Int? = nil
}

struct AniListSpecialSearchEntry: Identifiable, Codable {
    let id: Int
    let canonicalAniListId: Int?
    let malId: Int?
    let kitsuId: Int?
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
    let status: String?
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

    var canonicalAniListTotalEpisodes: Int {
        RemoteMediaNumericBoundary.boundedSum(seasons.map { $0.canonicalAniListEpisodeCount ?? $0.episodes.count }) ?? totalEpisodes
    }

    var canonicalMALTotalEpisodes: Int {
        RemoteMediaNumericBoundary.boundedSum(seasons.map { $0.canonicalMALEpisodeCount ?? $0.episodes.count }) ?? totalEpisodes
    }

    func satisfiesAnimeSeed(_ seedAniListId: Int?) -> Bool {
        guard let seedAniListId, seedAniListId != 0 else { return true }
        if seedAniListId < 0 {
            guard let seedMALID = RemoteMediaNumericBoundary.positiveMagnitude(seedAniListId) else {
                return false
            }
            return id == seedAniListId
                || malId == seedMALID
                || seasons.contains {
                    $0.anilistId == seedAniListId || $0.malId == seedMALID
                }
        }
        return id == seedAniListId || seasons.contains {
            $0.anilistId == seedAniListId
                || $0.canonicalAniListId == seedAniListId
        }
    }

    func satisfiesMALSeed(_ seedMALId: Int?) -> Bool {
        guard let seedMALId else { return true }
        guard let providerID = RemoteMediaNumericBoundary.negativeProviderIdentifier(seedMALId) else {
            return false
        }
        return malId == seedMALId
            || id == providerID
            || seasons.contains {
                $0.anilistId == providerID || $0.malId == seedMALId
            }
    }

    func satisfiesIdentitySeeds(aniListID: Int?, malID: Int?) -> Bool {
        guard satisfiesAnimeSeed(aniListID) else { return false }

        if aniListID.map({ $0 > 0 }) == true { return true }
        return satisfiesMALSeed(malID)
    }
}

struct AniListNotificationSeason: Identifiable, Sendable {
    let id: Int
    let title: String
    let status: String?
    let season: String?
    let seasonYear: Int?
    let premiereDate: Date?
    let isDetachedSpecial: Bool

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

struct AniListDate: Codable {
    let year: Int?
    let month: Int?
    let day: Int?

    private enum CodingKeys: String, CodingKey {
        case year, month, day
    }

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
    var endDate: AniListDate? = nil
    let seasonYear: Int?
    let season: String?
    let coverImage: AniListCoverImage?
    let format: String?
    let type: String?
    let nextAiringEpisode: AniListNextAiringEpisode?
    let relations: AniListRelations?

    private enum CodingKeys: String, CodingKey {
        case id, idMal, externalLinks, averageScore, isAdult, genres, tags, title
        case episodes, status, startDate, endDate, seasonYear, season, coverImage, format, type
        case nextAiringEpisode, relations
    }

    var kitsuId: Int? {
        Self.kitsuId(from: externalLinks)
    }

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

        func preferredURL(dataSaverEnabled: Bool = ImageDataSaverSettings.isEnabled()) -> String? {
            ImageDataSaverSettings.preferredURL(large: large, medium: medium, dataSaverEnabled: dataSaverEnabled)
        }
    }

    struct AniListTag: Codable {
        let name: String
        let rank: Int?
        let isMediaSpoiler: Bool?

        private enum CodingKeys: String, CodingKey {
            case name, rank, isMediaSpoiler
        }
    }

    struct AniListNextAiringEpisode: Codable {
        let episode: Int?
        let airingAt: Int?

        private enum CodingKeys: String, CodingKey {
            case episode, airingAt
        }
    }

    struct AniListRelations: Codable {
        let edges: [AniListRelationEdge]

        private enum CodingKeys: String, CodingKey {
            case edges
        }
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
        var endDate: AniListDate? = nil
        let seasonYear: Int?
        let season: String?
        let format: String?
        let type: String?
        let coverImage: AniListCoverImage?
        let relations: AniListRelations?

        private enum CodingKeys: String, CodingKey {
            case id, idMal, externalLinks, averageScore, isAdult, genres, tags, title
            case episodes, status, startDate, endDate, seasonYear, season, format, type, coverImage
            case relations
        }

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
                endDate: endDate,
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
            if let siteId = RemoteMediaNumericBoundary.positiveIdentifier(link.siteId) {
                return siteId
            }
            if let parsedId = RemoteMediaNumericBoundary.positiveIdentifier(
                link.numericKitsuIdFromURL
            ) {
                return parsedId
            }
        }

        return nil
    }
}

extension AniListDate {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawYear = try container.decodeIfPresent(Int.self, forKey: .year)
        let rawMonth = try container.decodeIfPresent(Int.self, forKey: .month)
        let rawDay = try container.decodeIfPresent(Int.self, forKey: .day)

        if let rawYear, rawYear != 0 {
            guard let year = RemoteMediaNumericBoundary.year(rawYear) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .year,
                    in: container,
                    debugDescription: "AniList year is outside the supported range."
                )
            }
            self.year = year
        } else {
            year = nil
        }
        if let rawMonth, rawMonth != 0 {
            guard (1...12).contains(rawMonth) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .month,
                    in: container,
                    debugDescription: "AniList month is outside the supported range."
                )
            }
            month = rawMonth
        } else {
            month = nil
        }
        if let rawDay, rawDay != 0 {
            guard (1...31).contains(rawDay) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .day,
                    in: container,
                    debugDescription: "AniList day is outside the supported range."
                )
            }
            day = rawDay
        } else {
            day = nil
        }
    }
}

extension AniListAnime.AniListTag {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        if let rawRank = try container.decodeIfPresent(Int.self, forKey: .rank) {
            guard (0...100).contains(rawRank) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .rank,
                    in: container,
                    debugDescription: "AniList tag rank is outside the supported range."
                )
            }
            rank = rawRank
        } else {
            rank = nil
        }
        isMediaSpoiler = try container.decodeIfPresent(Bool.self, forKey: .isMediaSpoiler)
    }
}

extension AniListAnime.AniListNextAiringEpisode {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawEpisode = try container.decodeIfPresent(Int.self, forKey: .episode)
        if let rawEpisode, rawEpisode != 0 {
            guard let episode = RemoteMediaNumericBoundary.episodeNumber(rawEpisode) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .episode,
                    in: container,
                    debugDescription: "AniList airing episode is outside the supported range."
                )
            }
            self.episode = episode
        } else {
            episode = nil
        }

        if let rawAiringAt = try container.decodeIfPresent(Int.self, forKey: .airingAt) {
            guard rawAiringAt > 0, rawAiringAt <= Int(UInt32.max) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .airingAt,
                    in: container,
                    debugDescription: "AniList airing timestamp is outside the supported range."
                )
            }
            airingAt = rawAiringAt
        } else {
            airingAt = nil
        }
    }
}

extension AniListAnime.AniListRelations {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedEdges = try container.decode(
            [AniListAnime.AniListRelationEdge].self,
            forKey: .edges
        )
        guard decodedEdges.count <= RemoteMediaNumericBoundary.maximumRelationCount else {
            throw DecodingError.dataCorruptedError(
                forKey: .edges,
                in: container,
                debugDescription: "AniList relation collection exceeds the supported limit."
            )
        }
        edges = decodedEdges
    }
}

extension AniListAnime {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try container.decode(Int.self, forKey: .id)
        guard let id = RemoteMediaNumericBoundary.positiveIdentifier(rawID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "AniList identifier is outside the supported range."
            )
        }
        self.id = id

        if let rawMALID = try container.decodeIfPresent(Int.self, forKey: .idMal) {
            guard let idMal = RemoteMediaNumericBoundary.positiveIdentifier(rawMALID) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .idMal,
                    in: container,
                    debugDescription: "MAL identifier is outside the supported range."
                )
            }
            self.idMal = idMal
        } else {
            idMal = nil
        }

        let decodedLinks = try container.decodeIfPresent(
            [AniListExternalLink].self,
            forKey: .externalLinks
        )
        guard (decodedLinks?.count ?? 0) <= 64 else {
            throw DecodingError.dataCorruptedError(
                forKey: .externalLinks,
                in: container,
                debugDescription: "AniList external-link collection exceeds the supported limit."
            )
        }
        externalLinks = decodedLinks

        if let rawScore = try container.decodeIfPresent(Int.self, forKey: .averageScore) {
            guard (0...100).contains(rawScore) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .averageScore,
                    in: container,
                    debugDescription: "AniList score is outside the supported range."
                )
            }
            averageScore = rawScore
        } else {
            averageScore = nil
        }
        isAdult = try container.decodeIfPresent(Bool.self, forKey: .isAdult)

        let decodedGenres = try container.decodeIfPresent([String].self, forKey: .genres)
        guard (decodedGenres?.count ?? 0) <= 64 else {
            throw DecodingError.dataCorruptedError(
                forKey: .genres,
                in: container,
                debugDescription: "AniList genre collection exceeds the supported limit."
            )
        }
        genres = decodedGenres

        let decodedTags = try container.decodeIfPresent(
            [AniListAnime.AniListTag].self,
            forKey: .tags
        )
        guard (decodedTags?.count ?? 0) <= 256 else {
            throw DecodingError.dataCorruptedError(
                forKey: .tags,
                in: container,
                debugDescription: "AniList tag collection exceeds the supported limit."
            )
        }
        tags = decodedTags
        title = try container.decode(AniListAnime.AniListTitle.self, forKey: .title)

        let rawEpisodes = try container.decodeIfPresent(Int.self, forKey: .episodes)
        if let rawEpisodes, rawEpisodes != 0 {
            guard let episodes = RemoteMediaNumericBoundary.episodeCount(rawEpisodes) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .episodes,
                    in: container,
                    debugDescription: "AniList episode count is outside the supported range."
                )
            }
            self.episodes = episodes
        } else {
            episodes = nil
        }

        status = try container.decodeIfPresent(String.self, forKey: .status)
        startDate = try container.decodeIfPresent(AniListDate.self, forKey: .startDate)
        endDate = try container.decodeIfPresent(AniListDate.self, forKey: .endDate)
        if let rawSeasonYear = try container.decodeIfPresent(Int.self, forKey: .seasonYear) {
            guard let seasonYear = RemoteMediaNumericBoundary.year(rawSeasonYear) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .seasonYear,
                    in: container,
                    debugDescription: "AniList season year is outside the supported range."
                )
            }
            self.seasonYear = seasonYear
        } else {
            seasonYear = nil
        }
        season = try container.decodeIfPresent(String.self, forKey: .season)
        coverImage = try container.decodeIfPresent(AniListCoverImage.self, forKey: .coverImage)
        format = try container.decodeIfPresent(String.self, forKey: .format)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        nextAiringEpisode = try container.decodeIfPresent(
            AniListNextAiringEpisode.self,
            forKey: .nextAiringEpisode
        )
        relations = try container.decodeIfPresent(AniListRelations.self, forKey: .relations)
    }
}

extension AniListAnime.AniListRelationNode {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try container.decode(Int.self, forKey: .id)
        guard let id = RemoteMediaNumericBoundary.positiveIdentifier(rawID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "AniList relation identifier is outside the supported range."
            )
        }
        self.id = id

        if let rawMALID = try container.decodeIfPresent(Int.self, forKey: .idMal) {
            guard let idMal = RemoteMediaNumericBoundary.positiveIdentifier(rawMALID) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .idMal,
                    in: container,
                    debugDescription: "MAL relation identifier is outside the supported range."
                )
            }
            self.idMal = idMal
        } else {
            idMal = nil
        }

        let decodedLinks = try container.decodeIfPresent(
            [AniListExternalLink].self,
            forKey: .externalLinks
        )
        guard (decodedLinks?.count ?? 0) <= 64 else {
            throw DecodingError.dataCorruptedError(
                forKey: .externalLinks,
                in: container,
                debugDescription: "AniList relation links exceed the supported limit."
            )
        }
        externalLinks = decodedLinks

        if let rawScore = try container.decodeIfPresent(Int.self, forKey: .averageScore) {
            guard (0...100).contains(rawScore) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .averageScore,
                    in: container,
                    debugDescription: "AniList relation score is outside the supported range."
                )
            }
            averageScore = rawScore
        } else {
            averageScore = nil
        }
        isAdult = try container.decodeIfPresent(Bool.self, forKey: .isAdult)

        let decodedGenres = try container.decodeIfPresent([String].self, forKey: .genres)
        guard (decodedGenres?.count ?? 0) <= 64 else {
            throw DecodingError.dataCorruptedError(
                forKey: .genres,
                in: container,
                debugDescription: "AniList relation genres exceed the supported limit."
            )
        }
        genres = decodedGenres

        let decodedTags = try container.decodeIfPresent(
            [AniListAnime.AniListTag].self,
            forKey: .tags
        )
        guard (decodedTags?.count ?? 0) <= 256 else {
            throw DecodingError.dataCorruptedError(
                forKey: .tags,
                in: container,
                debugDescription: "AniList relation tags exceed the supported limit."
            )
        }
        tags = decodedTags
        title = try container.decode(AniListAnime.AniListTitle.self, forKey: .title)

        let rawEpisodes = try container.decodeIfPresent(Int.self, forKey: .episodes)
        if let rawEpisodes, rawEpisodes != 0 {
            guard let episodes = RemoteMediaNumericBoundary.episodeCount(rawEpisodes) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .episodes,
                    in: container,
                    debugDescription: "AniList relation episode count is outside the supported range."
                )
            }
            self.episodes = episodes
        } else {
            episodes = nil
        }

        status = try container.decodeIfPresent(String.self, forKey: .status)
        startDate = try container.decodeIfPresent(AniListDate.self, forKey: .startDate)
        endDate = try container.decodeIfPresent(AniListDate.self, forKey: .endDate)
        if let rawSeasonYear = try container.decodeIfPresent(Int.self, forKey: .seasonYear) {
            guard let seasonYear = RemoteMediaNumericBoundary.year(rawSeasonYear) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .seasonYear,
                    in: container,
                    debugDescription: "AniList relation season year is outside the supported range."
                )
            }
            self.seasonYear = seasonYear
        } else {
            seasonYear = nil
        }
        season = try container.decodeIfPresent(String.self, forKey: .season)
        format = try container.decodeIfPresent(String.self, forKey: .format)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        coverImage = try container.decodeIfPresent(
            AniListAnime.AniListCoverImage.self,
            forKey: .coverImage
        )
        relations = try container.decodeIfPresent(
            AniListAnime.AniListRelations.self,
            forKey: .relations
        )
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

        let rawSiteID: Int?
        if let intSiteId = try? container.decodeIfPresent(Int.self, forKey: .siteId) {
            rawSiteID = intSiteId
        } else if let stringSiteId = try? container.decodeIfPresent(String.self, forKey: .siteId),
                  let parsed = Int(stringSiteId) {
            rawSiteID = parsed
        } else {
            rawSiteID = nil
        }

        if let rawSiteID {
            guard let validatedSiteID = RemoteMediaNumericBoundary.positiveIdentifier(rawSiteID) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .siteId,
                    in: container,
                    debugDescription: "AniList external-link identifier is outside the supported range."
                )
            }
            siteId = validatedSiteID
        } else {
            siteId = nil
        }
    }
}

struct AniListDetailSearchSelection: Equatable {
    let responseIndex: Int
    let candidateIndexes: [Int]
    let isExact: Bool
}

enum AniListTitlePicker {
    private static let maximumDetailSearchTitleCount = 6
    private static let maximumDetailSearchTitleBytes = 1_024

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

    static func detailSearchCandidates(
        primaryTitle: String,
        localizedTitle: String?,
        originalTitle: String?,
        preferredLocaleIdentifier: String? = nil,
        alternativeTitles: [TMDBTVAlternativeTitle] = []
    ) -> [String] {
        let preferredRegion = preferredLocaleIdentifier.flatMap {
            regionCode(fromLocaleIdentifier: $0)
        }
        let rankedAlternativeTitles = alternativeTitles.enumerated().sorted { lhs, rhs in
            let lhsPriority = alternativeTitlePriority(
                lhs.element,
                preferredRegionCode: preferredRegion
            )
            let rhsPriority = alternativeTitlePriority(
                rhs.element,
                preferredRegionCode: preferredRegion
            )
            if lhsPriority.bucket != rhsPriority.bucket {
                return lhsPriority.bucket < rhsPriority.bucket
            }
            if lhsPriority.type != rhsPriority.type {
                return lhsPriority.type < rhsPriority.type
            }
            if lhsPriority.region != rhsPriority.region {
                return lhsPriority.region < rhsPriority.region
            }
            return lhs.offset < rhs.offset
        }.map { $0.element.title }
        let rawCandidates = [primaryTitle, localizedTitle, originalTitle].compactMap { $0 }
            + rankedAlternativeTitles
        var seen = Set<String>()
        var result: [String] = []

        for rawCandidate in rawCandidates {
            let candidate = rawCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty,
                  candidate.lengthOfBytes(using: .utf8) <= maximumDetailSearchTitleBytes,
                  !candidate.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                continue
            }
            let key = candidate
                .folding(
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
            guard seen.insert(key).inserted else { continue }
            result.append(candidate)
            if result.count == maximumDetailSearchTitleCount {
                break
            }
        }
        return result
    }

    static func detailSearchSelection(
        responseCandidateTitles: [[[String]]],
        searchedTitles: [String],
        authoritativeTitles: [String]
    ) -> AniListDetailSearchSelection? {
        guard responseCandidateTitles.count == searchedTitles.count else { return nil }
        let authoritativeKeys = Set(
            authoritativeTitles
                .map(normalizedDetailSearchTitle)
                .filter { !$0.isEmpty }
        )

        for responseIndex in responseCandidateTitles.indices {
            let searchedKey = normalizedDetailSearchTitle(searchedTitles[responseIndex])
            let acceptedKeys = searchedKey.isEmpty
                ? authoritativeKeys
                : authoritativeKeys.union([searchedKey])
            let candidateIndexes = responseCandidateTitles[responseIndex].indices.filter { index in
                responseCandidateTitles[responseIndex][index].contains { candidateTitle in
                    acceptedKeys.contains(normalizedDetailSearchTitle(candidateTitle))
                }
            }
            if !candidateIndexes.isEmpty {
                return AniListDetailSearchSelection(
                    responseIndex: responseIndex,
                    candidateIndexes: candidateIndexes,
                    isExact: true
                )
            }
        }

        guard let responseIndex = responseCandidateTitles.firstIndex(where: { !$0.isEmpty }) else {
            return nil
        }
        return AniListDetailSearchSelection(
            responseIndex: responseIndex,
            candidateIndexes: Array(responseCandidateTitles[responseIndex].indices),
            isExact: false
        )
    }

    private static func regionCode(fromLocaleIdentifier localeIdentifier: String) -> String? {
        let components = localeIdentifier
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
        return components.dropFirst().reversed().compactMap { component in
            let region = String(component).uppercased()
            return region.count == 2 ? region : nil
        }.first
    }

    private static func alternativeTitlePriority(
        _ alternative: TMDBTVAlternativeTitle,
        preferredRegionCode: String?
    ) -> (bucket: Int, type: Int, region: Int) {
        let regionCode = alternative.iso31661.uppercased()
        let normalizedType = (alternative.type ?? "")
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        let typeRank: Int
        if normalizedType.contains("roman") {
            typeRank = 0
        } else if normalizedType.contains("original") {
            typeRank = 1
        } else if normalizedType.contains("english") {
            typeRank = 2
        } else if normalizedType.isEmpty {
            typeRank = 3
        } else if normalizedType.contains("alternate") || normalizedType.contains("alternative") {
            typeRank = 4
        } else {
            typeRank = 5
        }
        let regionRank: Int
        if regionCode == preferredRegionCode {
            regionRank = 0
        } else if regionCode == "US" {
            regionRank = 1
        } else if regionCode == "JP" {
            regionRank = 2
        } else if ["GB", "CA", "AU", "NZ"].contains(regionCode) {
            regionRank = 3
        } else {
            regionRank = 4
        }
        let isProviderSignificantType = typeRank <= 2
        let isPriorityRegion = regionRank <= 2
        let bucket = isProviderSignificantType || isPriorityRegion
            ? 0
            : regionRank == 3 ? 1 : 2
        return (bucket, typeRank, regionRank)
    }

    private static func normalizedDetailSearchTitle(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}

private final class MALMetadataService {
    static let shared = MALMetadataService()

#if DEBUG
    @TaskLocal static var isLiveRegressionValidation = false
#endif

    private struct MALHTTPPayload: @unchecked Sendable {
        let data: Data
        let response: URLResponse
    }

    private struct MALDetailBatchResult {
        let detailsByID: [Int: MALAnimeDetails]
        let failedIDs: Set<Int>
    }

    private struct MALRegularGraphResult {
        let details: [MALAnimeDetails]
        let detachedDetails: [MALAnimeDetails]
        let specialBridgeConstraints: [AnimeStructureRelationConstraint]
        let usedSpecialBridgeTraversal: Bool
        let failedIDs: Set<Int>
        let reachedTraversalLimit: Bool
        let regularStoryEpisodeCounts: [Int: Int]
    }

    private let apiBase = URL(string: "https://api.myanimelist.net/v2")!
    private let detailFields = [
        "id", "title", "main_picture", "alternative_titles", "start_date", "end_date",
        "synopsis", "mean", "rank", "popularity", "num_list_users", "media_type",
        "status", "genres", "num_episodes", "start_season", "broadcast", "source",
        "average_episode_duration", "rating", "related_anime"
    ].joined(separator: ",")

    private init() {}

    private var tmdbMatchCacheLanguage: String {
        ProfileSettingsStore.active.string(forKey: "tmdbLanguage") ?? "en-US"
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

        return [
            .trending: try await trending,
            .popular: try await popular,
            .topRated: try await topRated,
            .airing: try await airing
        ]
    }

    func fetchAiringSchedule(daysAhead: Int, perPage: Int) async throws -> [AniListAiringScheduleEntry] {
        guard (1...366).contains(daysAhead), (1...100).contains(perPage) else {
            throw NSError(domain: "MALMetadata", code: -4, userInfo: [NSLocalizedDescriptionKey: "MAL airing request is outside the supported range."])
        }
        let current = malSeason(for: Date())
        let next = nextSeason(after: current)
        let currentAnime = try await fetchSeasonAnime(year: current.year, season: current.season, limit: perPage)
        let nextAnime = (try? await fetchSeasonAnime(year: next.year, season: next.season, limit: perPage)) ?? []
        let all = Array((currentAnime + nextAnime)
            .filter { !isAdultScheduleAnime($0) }
            .prefix(perPage * 2))

        let window = ScheduleDateWindow.envelope(dayCount: daysAhead)
        let start = window.start
        let end = window.end

        return all.compactMap { detail in
            guard let airingAt = estimatedNextAiringDate(for: detail, start: start, end: end) else { return nil }
            let episode = estimatedNextEpisode(for: detail, airingAt: airingAt)
            return AniListAiringScheduleEntry(
                id: malProviderId(detail.id),
                mediaId: malProviderId(detail.id),
                title: displayTitle(for: detail),
                airingAt: airingAt,
                episode: episode,
                coverImage: detail.mainPicture?.preferredURL(),
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
        tmdbShowPoster: String?,
        rootMALId: Int? = nil,
        hydrationPolicy: AnimeEpisodeHydrationPolicy = .complete,
        knownTMDBShowDetail: TMDBTVShowWithSeasons? = nil
    ) async throws -> AniListAnimeWithSeasons {
        async let structuralMappingsTask = AniMapMappingService.shared.mappingsResult(
            forTMDBShowId: tmdbShowId
        )
        let tvShowDetail: TMDBTVShowWithSeasons?
        if let knownTMDBShowDetail {
            tvShowDetail = knownTMDBShowDetail
        } else {
            tvShowDetail = try? await tmdbService.getTVShowWithSeasons(id: tmdbShowId)
        }
        let structuralMappingResult = await structuralMappingsTask
        let structuralMappings = structuralMappingResult.mappings
        let tmdbSeasonEpisodeCounts = regularTMDBSeasonEpisodeCounts(tvShowDetail)
        let expectedTMDBSeasonCounts = tmdbSeasonEpisodeCounts ?? [:]
        let root: MALAnimeDetails
        if let rootMALId {
            guard let validatedRootID = RemoteMediaNumericBoundary.positiveIdentifier(rootMALId) else {
                throw NSError(domain: "MALMetadata", code: -4, userInfo: [NSLocalizedDescriptionKey: "MAL root identifier is outside the supported range."])
            }
            guard let fetchedRoot = try await fetchAnimeDetailsForFallback(id: validatedRootID) else {
                throw NSError(domain: "MALMetadata", code: 404, userInfo: [NSLocalizedDescriptionKey: "MAL did not return the requested anime root."])
            }
            root = fetchedRoot
        } else if let mappedRootID = preferredMappedRegularRootID(
            mappings: structuralMappings,
            tmdbShowId: tmdbShowId,
            tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts
        ), let fetchedRoot = try await fetchAnimeDetailsForFallback(id: mappedRootID) {
            Logger.shared.log(
                "MALMetadata: using mapped root tmdbId=\(tmdbShowId) malId=\(mappedRootID)",
                type: "AniList"
            )
            root = fetchedRoot
        } else {
            let candidates = try await searchCandidates(
                title: title,
                tmdbShowId: tmdbShowId,
                tmdbShow: tvShowDetail,
                tmdbService: tmdbService
            )
            guard let matched = pickBestMALMatch(from: candidates, tmdbShow: tvShowDetail) else {
                throw NSError(domain: "MALMetadata", code: 404, userInfo: [NSLocalizedDescriptionKey: "MAL did not return a usable anime match for \(title)"])
            }
            root = matched
        }
        let graph = try await collectRegularGraph(
            root,
            structuralMappings: structuralMappings,
            tmdbShowId: tmdbShowId,
            tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts
        )
        let regularStoryEpisodeCounts = graph.regularStoryEpisodeCounts
        let initialPlacementCandidates = graph.details.map { detail in
            AnimeStructureCourPlacementCandidate(id: detail.id,
                mappedTMDBSeason: structuralMappings.first { $0.malId == detail.id }?.tmdbSeason,
                episodeCount: detail.numEpisodes, format: aniListFormat(from: detail.mediaType), status: detail.status,
                startDate: detail.startDate, endDate: detail.endDate, titles: titleCandidates(for: detail),
                hasTrustedIdentity: structuralMappings.contains { $0.malId == detail.id && $0.tmdbShowId == tmdbShowId })
        }
        let placementMappingsByID = Dictionary(structuralMappings.compactMap { mapping in
            mapping.malId.map { ($0, mapping) }
        }, uniquingKeysWith: { first, _ in first })
        let contradictedMappedSpecialIDs = AnimeStructurePolicy.contradictedMappedSpecialIDs(
            candidates: initialPlacementCandidates,
            mappingsByID: placementMappingsByID, tmdbShow: tvShowDetail)
        var collected = relationOrderedMALDetails(graph.details.filter { !contradictedMappedSpecialIDs.contains($0.id) })
        if let tvShowDetail {
            let seasons = tvShowDetail.seasons.filter { $0.seasonNumber > 0 && $0.episodeCount > 0 }
            let targets = Set([tvShowDetail.name, tvShowDetail.originalName].compactMap { $0 }.map(normalized))
            if seasons.count == 1, let season = seasons.first,
               let year = tvShowDetail.firstAirDate.flatMap({ Int($0.prefix(4)) }) {
                let roots = collected.filter { detail in
                    detail.numEpisodes == season.episodeCount && detail.startDate == season.airDate
                        && detail.startDate.flatMap { Int($0.prefix(4)) } == year
                        && titleCandidates(for: detail).map(normalized).contains { targets.contains($0) }
                }
                if roots.count == 1, let root = roots.first {
                    let ids = Set(collected.map(\.id))
                    let constraints = collected.flatMap { detail in
                        (detail.relatedAnime ?? []).compactMap { relation -> AnimeStructureRelationConstraint? in
                            guard ["sequel", "prequel"].contains(relation.relationType.lowercased()),
                                  ids.contains(relation.node.id) else { return nil }
                            return .init(beforeID: detail.id, afterID: relation.node.id)
                        }
                    }
                    let connected = AnimeStructurePolicy.ordinaryConnectedIDs(rootID: root.id, candidateIDs: ids, constraints: constraints)
                    collected = collected.filter { connected.contains($0.id) }
                }
            }
        }
        func coverageSegments(_ details: [MALAnimeDetails]) -> [AnimeStructureCoverageSegment] {
            details.map { detail in
                let mapping = structuralMappings.first { mapping in
                    mapping.malId == detail.id
                        && (mapping.tmdbShowId == nil || mapping.tmdbShowId == tmdbShowId)
                        && AniMapStructuralRole.isRegularStory(
                            mapping,
                            fallbackMediaType: aniListFormat(from: detail.mediaType),
                            tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                            episodeCount: detail.numEpisodes,
                            regularStoryEpisodeCounts: regularStoryEpisodeCounts
                        )
                }
                return AnimeStructureCoverageSegment(
                    mappedTMDBSeason: mapping?.tmdbSeason.flatMap { $0 > 0 ? $0 : nil },
                    episodeCount: detail.numEpisodes
                )
            }
        }
        let graphSupportsCountInference = structuralMappingResult.isComplete
            && graph.failedIDs.isEmpty
            && !graph.reachedTraversalLimit

        var collectedIDs = Set(collected.map(\.id))
        if !graph.failedIDs.isEmpty || graph.reachedTraversalLimit {
            Logger.shared.log(
                "MALMetadata: regular graph incomplete tmdbId=\(tmdbShowId) failed=\(graph.failedIDs.count) traversalLimit=\(graph.reachedTraversalLimit)",
                type: "AniList"
            )
        }

        let supplementalCoverageSegments = graphSupportsCountInference
            ? AnimeStructurePolicy.resolvingSingleUnknownMappedSeasonCounts(
                tmdbSeasonEpisodeCounts: expectedTMDBSeasonCounts,
                segments: coverageSegments(collected)
            )
            : coverageSegments(collected)
        if let tmdbTotal = tvShowDetail?.numberOfEpisodes,
           let upperBudget = RemoteMediaNumericBoundary.scaledEpisodeCount(
            tmdbTotal, numerator: 5, denominator: 4
           ) {
            if AnimeStructurePolicy.hasKnownEpisodeDeficit(
                tmdbTotalEpisodeCount: tmdbTotal, segments: supplementalCoverageSegments
            ) {
                let orphans = try await orphanCandidates(
                    root: root,
                    title: title,
                    tmdbShow: tvShowDetail,
                    structuralMappings: structuralMappings,
                    tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                    regularStoryEpisodeCounts: regularStoryEpisodeCounts
                )
                for orphan in orphans where !collectedIDs.contains(orphan.id) && collected.count < 12 {
                    let isMappedRegular = structuralMappings.contains {
                        $0.malId == orphan.id && ($0.tmdbShowId == nil || $0.tmdbShowId == tmdbShowId)
                            && AniMapStructuralRole.isRegularStory($0,
                                fallbackMediaType: aniListFormat(from: orphan.mediaType),
                                tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                                episodeCount: orphan.numEpisodes,
                                regularStoryEpisodeCounts: regularStoryEpisodeCounts)
                    }
                    let relationsToExisting = (orphan.relatedAnime ?? [])
                        .filter { collectedIDs.contains($0.node.id) }.map(\.relationType)
                    let existingRelationsToOrphan = collected.flatMap { detail in
                        (detail.relatedAnime ?? []).filter { $0.node.id == orphan.id }.map(\.relationType)
                    }
                    guard AnimeRelationRolePolicy.admitsSupplementalRegularEntry(
                        isMappedRegular: isMappedRegular,
                        relationTypesToExistingEntries: relationsToExisting + existingRelationsToOrphan,
                        mediaFormat: aniListFormat(from: orphan.mediaType)
                    ) else { continue }
                    collectedIDs.insert(orphan.id)
                    collected.append(orphan)
                }
            }

            collected = relationOrderedMALDetails(collected)
            if let newTotal = RemoteMediaNumericBoundary.boundedSum(
                collected.map { max($0.numEpisodes ?? 0, 0) }
            ), newTotal > upperBudget,
               let rootIndex = collected.firstIndex(where: { $0.id == root.id }) {
                collected = pruneMALSeasons(
                    collected,
                    rootIndex: rootIndex,
                    tmdbEpisodeBudget: upperBudget,
                    retainedProviderIDs: Set(structuralMappings.filter { $0.tmdbShowId == tmdbShowId }
                        .compactMap(\.malId))
                )
            }
        }
        let hasExactRootIdentity: Bool = {
            guard let tvShowDetail, let first = collected.first,
                  let tmdbYear = tvShowDetail.firstAirDate.flatMap({ Int($0.prefix(4)) }),
                  let rootYear = first.startDate.flatMap({ Int($0.prefix(4)) }) ?? first.startSeason?.year,
                  rootYear == tmdbYear else { return false }
            let targets = Set([tvShowDetail.name, tvShowDetail.originalName].compactMap { $0 }
                .map(normalized).filter { !$0.isEmpty })
            return titleCandidates(for: first).map(normalized).contains { targets.contains($0) }
        }()
        let hydratedMALIDs = Set(collected.map(\.id))
        let requiresOpenEndedActualInventory = AnimeStructurePolicy.requiresVerifiedOpenEndedInventory(
            mediaFormat: collected.first?.mediaType, status: collected.first?.status,
            episodeCount: collected.first?.numEpisodes, entryCount: collected.count,
            tmdbSeasonCount: expectedTMDBSeasonCounts.count)
        let hasExclusiveOpenEndedOwner = requiresOpenEndedActualInventory && hasExactRootIdentity
            && (2...64).contains(expectedTMDBSeasonCounts.count)
            && collected.first?.id == root.id && root.startDate == tvShowDetail?.firstAirDate
            && graph.failedIDs.isEmpty && !graph.reachedTraversalLimit && !graph.usedSpecialBridgeTraversal
            && root.relatedAnime.map { relations in
                !relations.contains { ["prequel", "sequel", "parent_story", "main_story", "full_story"].contains($0.relationType.lowercased()) }
            } == true
            && !structuralMappings.contains { mapping in
                (mapping.tmdbShowId == nil || mapping.tmdbShowId == tmdbShowId) && mapping.malId != root.id
                    && AniMapStructuralRole.isRegularStory(mapping, tmdbSeasonEpisodeCounts: expectedTMDBSeasonCounts)
            }
        let requiresVerifiedAbsoluteInventory = AnimeStructurePolicy.requiresVerifiedAbsoluteOrderInventory(
            tvdbSeasons: structuralMappings.filter { mapping in
                mapping.tmdbShowId == tmdbShowId
                    && mapping.malId.map { hydratedMALIDs.contains($0) } == true
            }.map(\.tvdbSeason),
            tmdbSeasonCount: expectedTMDBSeasonCounts.count
        ) || requiresOpenEndedActualInventory
        let tmdbHydration = await fetchTMDBEpisodesByAbsolute(
            tmdbShowId: tmdbShowId,
            tvShowDetail: tvShowDetail,
            tmdbService: tmdbService,
            absoluteEpisodeLimit: (requiresOpenEndedActualInventory && !hasExclusiveOpenEndedOwner)
                || (hydrationPolicy == .initiallyVisible && !requiresVerifiedAbsoluteInventory) ? 100 : nil,
            allowsSummaryCoordinateFallback: !requiresVerifiedAbsoluteInventory
        )
        var tmdbEpisodesByAbsolute = tmdbHydration.episodes
        var tmdbCoordinatesByAbsolute = tmdbHydration.coordinates
        let verifiedOpenEndedActualInventory = !requiresOpenEndedActualInventory
            || AnimeStructurePolicy.verifiedOpenEndedTMDBInventory(
                hasExclusiveOrdinaryOwner: hasExclusiveOpenEndedOwner, providerStartDate: root.startDate,
                tmdbSeasonEpisodeCounts: expectedTMDBSeasonCounts,
                sourceEpisodes: Array(tmdbEpisodesByAbsolute.values)) != nil
        var coordinateSeasonEpisodeCounts = expectedTMDBSeasonCounts
        let coordinateCoverageSegments = coverageSegments(collected)
        let prologueStatuses = collected.map(\.status)
        let prologueActiveEnd = prologueStatuses.firstIndex {
            ["NOT_YET_RELEASED", "NOT_YET_AIRED"].contains($0?.uppercased() ?? "")
        } ?? prologueStatuses.endIndex
        let hasContiguousUpcomingTail = prologueStatuses[prologueActiveEnd...].allSatisfy {
            ["NOT_YET_RELEASED", "NOT_YET_AIRED"].contains($0?.uppercased() ?? "")
        }
        let prologueSegments = hasContiguousUpcomingTail
            ? Array(coordinateCoverageSegments.prefix(prologueActiveEnd)) : coordinateCoverageSegments
        let activePrologueStatuses = hasContiguousUpcomingTail ? Array(prologueStatuses.prefix(prologueActiveEnd)) : prologueStatuses
        let activePrologueStartDates = hasContiguousUpcomingTail
            ? Array(collected.prefix(prologueActiveEnd).map(\.startDate)) : collected.map(\.startDate)
        let terminalIdentityIDs = Set(collected.map(\.id))
        let terminalDetachedIDs = Set(graph.detachedDetails.map(\.id))
        let terminalEntries = collected.enumerated().map { index, detail in
            let previous = index > 0 ? collected[index - 1] : nil
            let followsPrevious = previous.map { prior in
                (prior.relatedAnime ?? []).contains {
                    $0.relationType.lowercased() == "sequel" && $0.node.id == detail.id
                } || (detail.relatedAnime ?? []).contains {
                    $0.relationType.lowercased() == "prequel" && $0.node.id == prior.id
                }
            } ?? false
            let mapping = structuralMappings.first {
                $0.malId == detail.id && $0.tmdbShowId == tmdbShowId
                    && AniMapStructuralRole.isRegularStory($0, fallbackMediaType: aniListFormat(from: detail.mediaType),
                        tmdbSeasonEpisodeCounts: expectedTMDBSeasonCounts,
                        episodeCount: detail.numEpisodes, regularStoryEpisodeCounts: regularStoryEpisodeCounts)
            }
            return AnimeTerminalSeasonProjectionPolicy.Entry(providerID: detail.id, mapping: mapping,
                episodeCount: detail.numEpisodes, status: detail.status, format: aniListFormat(from: detail.mediaType),
                startDate: detail.startDate, followsPrevious: followsPrevious)
        }
        let terminalHasCompetingOwner = !graph.failedIDs.isEmpty || graph.reachedTraversalLimit || collected.contains { detail in
            (detail.relatedAnime ?? []).contains {
                $0.relationType.lowercased() == "sequel" && !terminalIdentityIDs.contains($0.node.id)
                    && !terminalDetachedIDs.contains($0.node.id)
            }
        }
        var verifiedTerminalEpisodesByID: [Int: [TMDBEpisode]] = [:]
        if let terminalSeason = AnimeTerminalSeasonProjectionPolicy.candidateSeasonNumber(
            tmdbShowId: tmdbShowId, entries: terminalEntries, tmdbSeasonEpisodeCounts: expectedTMDBSeasonCounts,
            hasCompetingOrdinaryOwner: terminalHasCompetingOwner
        ), let source = try? await tmdbService.getSeasonDetails(tvShowId: tmdbShowId, seasonNumber: terminalSeason) {
            verifiedTerminalEpisodesByID = AnimeTerminalSeasonProjectionPolicy.verifiedEpisodes(
                tmdbShowId: tmdbShowId, entries: terminalEntries, tmdbSeasonEpisodeCounts: expectedTMDBSeasonCounts,
                hasCompetingOrdinaryOwner: terminalHasCompetingOwner, sourceSeason: source,
                today: AnimeStructurePolicy.currentAirDateString()
            )
        }
        if AnimeStructurePolicy.mappedPrologueCandidateIndex(
            tmdbSeasonEpisodeCounts: expectedTMDBSeasonCounts, segments: prologueSegments,
            statuses: activePrologueStatuses, providerStartDates: activePrologueStartDates,
            sourceEpisodes: Array(tmdbEpisodesByAbsolute.values)
        ) != nil, let specials = try? await tmdbService.getSeasonDetails(tvShowId: tmdbShowId, seasonNumber: 0),
           let augmented = AnimeStructurePolicy.inventoryByAddingMappedPrologue(
            tmdbSeasonEpisodeCounts: expectedTMDBSeasonCounts, segments: prologueSegments,
            statuses: activePrologueStatuses, providerStartDates: activePrologueStartDates,
            sourceEpisodes: Array(tmdbEpisodesByAbsolute.values), specialEpisodes: specials.episodes
           ) {
            tmdbEpisodesByAbsolute = augmented.episodes
            tmdbCoordinatesByAbsolute = augmented.coordinates.mapValues {
                (season: $0.seasonNumber, episode: $0.episodeNumber)
            }
            coordinateSeasonEpisodeCounts = augmented.seasonCounts
        }
        try Task.checkCancellation()
        let resolvedCoordinateCoverageSegments = graphSupportsCountInference
            ? AnimeStructurePolicy.resolvingSingleUnknownMappedSeasonCounts(
                tmdbSeasonEpisodeCounts: expectedTMDBSeasonCounts,
                segments: coordinateCoverageSegments
            )
            : coordinateCoverageSegments
        var resolvedEpisodeCountsByMALID = Dictionary(uniqueKeysWithValues: zip(
            collected,
            resolvedCoordinateCoverageSegments
        ).compactMap { detail, segment in
            segment.episodeCount.map { (detail.id, $0) }
        })
        var allowsLinearTMDBCoordinates = AnimeStructurePolicy.allowsLinearTMDBCoordinates(
            hydrationPolicy: hydrationPolicy,
            tmdbSeasonEpisodeCounts: coordinateSeasonEpisodeCounts,
            segments: resolvedCoordinateCoverageSegments,
            statuses: collected.map(\.status)
        )
        if graph.usedSpecialBridgeTraversal {
            let active = collected.filter { $0.status?.lowercased() != "not_yet_aired" }
            let hasMappedActiveRoster = structuralMappingResult.isComplete && active.allSatisfy { detail in
                structuralMappings.contains { mapping in
                    mapping.malId == detail.id && mapping.tmdbShowId == tmdbShowId
                        && AniMapStructuralRole.isRegularStory(mapping,
                            fallbackMediaType: aniListFormat(from: detail.mediaType),
                            tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                            episodeCount: detail.numEpisodes, regularStoryEpisodeCounts: regularStoryEpisodeCounts)
                }
            }
            if !hasMappedActiveRoster {
                let ids = Set(collected.map(\.id))
                let verifiedBridgeIDs = Set(graph.detachedDetails.compactMap { bridge -> Int? in
                    let prior = (bridge.relatedAnime ?? []).filter { $0.relationType.lowercased() == "prequel" }.map { $0.node.id }
                    let next = (bridge.relatedAnime ?? []).filter { $0.relationType.lowercased() == "sequel" }.map { $0.node.id }
                    return graph.specialBridgeConstraints.contains { prior == [$0.beforeID] && next == [$0.afterID] } ? bridge.id : nil
                })
                let closed = collected.allSatisfy { detail in
                    (detail.relatedAnime ?? []).allSatisfy { relation in
                        !["prequel", "sequel", "parent_story", "main_story", "full_story", "alternative_version"]
                            .contains(relation.relationType.lowercased())
                            || ids.contains(relation.node.id) || verifiedBridgeIDs.contains(relation.node.id)
                    }
                } && zip(collected, collected.dropFirst()).allSatisfy { prior, next in
                    let direct = prior.relatedAnime?.contains { $0.relationType.lowercased() == "sequel" && $0.node.id == next.id } == true
                        && next.relatedAnime?.contains { $0.relationType.lowercased() == "prequel" && $0.node.id == prior.id } == true
                    return direct || graph.specialBridgeConstraints.contains { $0.beforeID == prior.id && $0.afterID == next.id }
                }
                allowsLinearTMDBCoordinates = allowsLinearTMDBCoordinates
                    && AnimeMALFallbackRelationPolicy.allowsVerifiedBridgeLinearInventory(
                        hasExactRootIdentity: hasExactRootIdentity,
                        graphIsComplete: graph.failedIDs.isEmpty && !graph.reachedTraversalLimit,
                        hasClosedReciprocalChain: closed, providerStartDate: collected.first?.startDate,
                        providerStartDates: collected.map(\.startDate),
                        episodeCounts: collected.map(\.numEpisodes), statuses: collected.map(\.status),
                        mediaFormats: collected.map { $0.mediaType?.lowercased() == "tv" ? "TV" : nil },
                        tmdbSeasonEpisodeCounts: expectedTMDBSeasonCounts,
                        sourceEpisodes: Array(tmdbEpisodesByAbsolute.values))
            }
        }
        let ordinaryIDs = Set(collected.map(\.id))
        var trustedCourIDs = Set(collected.compactMap { detail -> Int? in
            structuralMappings.contains { mapping in
                mapping.malId == detail.id && mapping.tmdbShowId == tmdbShowId
                    && (mapping.tmdbSeason.map { $0 > 0 } == true || mapping.tvdbSeason == -1)
            } || (hasExactRootIdentity && detail.id == collected.first?.id) ? detail.id : nil
        })
        for _ in collected.indices {
            let previous = trustedCourIDs
            for detail in collected {
                for relation in detail.relatedAnime ?? [] where
                    ["sequel", "prequel"].contains(relation.relationType.lowercased())
                        && ordinaryIDs.contains(relation.node.id) {
                    if trustedCourIDs.contains(detail.id) { trustedCourIDs.insert(relation.node.id) }
                    if trustedCourIDs.contains(relation.node.id) { trustedCourIDs.insert(detail.id) }
                }
            }
            if previous == trustedCourIDs { break }
        }
        let exactOwnedSeasons = Set(resolvedCoordinateCoverageSegments.indices.compactMap { index -> Int? in
            AnimeSeasonEpisodeHydrationPolicy.exactMappedSeasonStart(index: index,
                segments: resolvedCoordinateCoverageSegments, tmdbSeasonEpisodeCounts: coordinateSeasonEpisodeCounts) != nil
                ? resolvedCoordinateCoverageSegments[index].mappedTMDBSeason : nil
        })
        let containedCandidates = collected.enumerated().compactMap { index, detail -> AnimeStructureCourPlacementCandidate? in
            guard !allowsLinearTMDBCoordinates,
                  AnimeSeasonEpisodeHydrationPolicy.exactMappedSeasonStart(index: index,
                    segments: resolvedCoordinateCoverageSegments, tmdbSeasonEpisodeCounts: coordinateSeasonEpisodeCounts) == nil else { return nil }
            return AnimeStructureCourPlacementCandidate(id: detail.id,
                mappedTMDBSeason: resolvedCoordinateCoverageSegments[index].mappedTMDBSeason,
                episodeCount: detail.numEpisodes, format: aniListFormat(from: detail.mediaType), status: detail.status,
                startDate: detail.startDate, endDate: detail.endDate, titles: titleCandidates(for: detail),
                hasTrustedIdentity: trustedCourIDs.contains(detail.id),
                nextIDs: Set((detail.relatedAnime ?? []).filter { $0.relationType.lowercased() == "sequel" }.map { $0.node.id }),
                previousIDs: Set((detail.relatedAnime ?? []).filter { $0.relationType.lowercased() == "prequel" }.map { $0.node.id }),
                hasTrustedMappedIdentity: structuralMappings.contains {
                    $0.malId == detail.id && $0.tmdbShowId == tmdbShowId && $0.tmdbSeason.map { $0 > 0 } == true
                })
        }
        let containedSourceSeasons = await AnimeStructurePolicy.fetchCourSeasonDetails(
            candidates: containedCandidates, tmdbShow: tvShowDetail, tmdbService: tmdbService)
        var verifiedContainedEpisodesByID = AnimeStructurePolicy.verifiedContainedEpisodePlacements(
            candidates: containedCandidates, sourceSeasonEpisodeCounts: expectedTMDBSeasonCounts,
            sourceSeasonDetails: containedSourceSeasons, specialContinuationParentIDs: []
        ).filter { !$0.value.contains { exactOwnedSeasons.contains($0.seasonNumber) } }
        let supplementalAniListIDs = Dictionary(containedCandidates.compactMap { candidate -> (Int, Int)? in
            structuralMappings.first { $0.malId == candidate.id && $0.tmdbShowId == tmdbShowId }?
                .anilistId.map { (candidate.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        let supplementalPlacements = await AniListService.shared.mappedSupplementalEpisodePlacements(
            candidates: containedCandidates, aniListIDs: supplementalAniListIDs,
            tvShowDetail: tvShowDetail, tmdbService: tmdbService, token: nil)
        verifiedContainedEpisodesByID.merge(supplementalPlacements, uniquingKeysWith: { first, _ in first })
        let hasOrdinaryContinuationAmbiguity = collected.contains { detail in
            detail.relatedAnime.map { relations in
                relations.contains {
                    ["sequel", "prequel", "parent_story", "main_story", "full_story", "alternative_version"]
                        .contains($0.relationType.lowercased()) && !ordinaryIDs.contains($0.node.id)
                }
            } ?? true
        }
        let hasTrustedOrdinaryCourRoster = collected.count == 1
            || (structuralMappingResult.isComplete && graph.failedIDs.isEmpty && !graph.reachedTraversalLimit
                && ordinaryIDs.count == collected.count && collected.allSatisfy { detail in
                    structuralMappings.contains { mapping in
                        mapping.malId == detail.id && mapping.tmdbShowId == tmdbShowId
                            && AniMapStructuralRole.isRegularStory(mapping,
                                fallbackMediaType: aniListFormat(from: detail.mediaType),
                                tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                                episodeCount: detail.numEpisodes, regularStoryEpisodeCounts: regularStoryEpisodeCounts)
                    }
                })
        let hasReciprocalTerminalRelation: Bool = {
            guard collected.count > 1, let terminal = collected.last else { return false }
            let previous = collected[collected.count - 2]
            return previous.relatedAnime?.contains {
                $0.node.id == terminal.id && $0.relationType.lowercased() == "sequel"
            } == true && terminal.relatedAnime?.contains {
                $0.node.id == previous.id && $0.relationType.lowercased() == "prequel"
            } == true
        }()
        let allowsMappedTVBroadcastDateOffsets = hasTrustedOrdinaryCourRoster
            && AnimeStructurePolicy.hasMappedTVBroadcastDateOffsetProof(
                lookupIsComplete: structuralMappingResult.isComplete,
                graphIsComplete: graph.failedIDs.isEmpty && !graph.reachedTraversalLimit,
                tmdbShowId: tmdbShowId, mappedShowIDs: collected.map { detail in
                    structuralMappings.first { $0.malId == detail.id && $0.tmdbShowId == tmdbShowId }?.tmdbShowId
                }, mediaFormats: collected.map { aniListFormat(from: $0.mediaType) },
                statuses: collected.map(\.status), episodeCounts: collected.map(\.numEpisodes),
                hasReciprocalTerminalRelation: hasReciprocalTerminalRelation,
                hasCompetingOrdinaryOwner: hasOrdinaryContinuationAmbiguity)
        if !allowsLinearTMDBCoordinates, hasExactRootIdentity,
           hasTrustedOrdinaryCourRoster || collected.allSatisfy({ $0.mediaType?.lowercased() == "tv" }),
           graph.failedIDs.isEmpty, !graph.reachedTraversalLimit,
           !hasOrdinaryContinuationAmbiguity,
           expectedTMDBSeasonCounts.count == 1,
           let inventory = expectedTMDBSeasonCounts.first,
           collected.last?.status?.lowercased() == "currently_airing" {
            var sourceEpisodes = Array(tmdbEpisodesByAbsolute.values)
            if sourceEpisodes.count != inventory.value,
               let source = try? await tmdbService.getSeasonDetails(
                tvShowId: tmdbShowId, seasonNumber: inventory.key
               ) {
                sourceEpisodes = source.episodes
            }
            let counts: [Int]?
            if hasTrustedOrdinaryCourRoster {
                counts = AnimeStructurePolicy.verifiedOngoingEpisodeCounts(
                    hasExactRootIdentity: hasExactRootIdentity,
                    hasTrustedOrdinaryCourRoster: true,
                    hasOrdinaryContinuationAmbiguity: hasOrdinaryContinuationAmbiguity,
                    mediaFormats: collected.map { aniListFormat(from: $0.mediaType) },
                    statuses: collected.map(\.status), episodeCounts: collected.map(\.numEpisodes),
                    providerStartDates: collected.map(\.startDate),
                    tmdbSeasonEpisodeCounts: expectedTMDBSeasonCounts, sourceEpisodes: sourceEpisodes,
                    today: AnimeStructurePolicy.currentAirDateString(),
                    allowsMappedTVBroadcastDateOffsets: allowsMappedTVBroadcastDateOffsets
                )
            } else {
                let entries = collected.map { detail in
                    AnimeMALFallbackRelationPolicy.BridgeEntry(id: detail.id,
                        format: detail.mediaType?.lowercased() == "tv" ? "TV" : nil,
                        status: detail.status, episodeCount: detail.numEpisodes,
                        startDate: detail.startDate, endDate: detail.endDate,
                        prequelIDs: (detail.relatedAnime ?? []).filter { $0.relationType.lowercased() == "prequel" }.map { $0.node.id },
                        sequelIDs: (detail.relatedAnime ?? []).filter { $0.relationType.lowercased() == "sequel" }.map { $0.node.id },
                        hasForeignMapping: structuralMappings.contains {
                            $0.malId == detail.id && ($0.tmdbShowId.map { $0 != tmdbShowId } == true || $0.tmdbMovieId != nil)
                        })
                }
                let hasNonOrdinaryOwnershipRelation = collected.contains { detail in
                    detail.relatedAnime?.contains {
                        ["parent_story", "main_story", "full_story", "alternative_version"].contains($0.relationType.lowercased())
                    } == true
                }
                counts = AnimeMALFallbackRelationPolicy.verifiedUnmappedOngoingEpisodeCounts(
                    hasExactRootIdentity: hasExactRootIdentity,
                    graphIsComplete: graph.failedIDs.isEmpty && !graph.reachedTraversalLimit
                        && collected.allSatisfy { $0.relatedAnime != nil },
                    hasCompetingOwner: hasOrdinaryContinuationAmbiguity || hasNonOrdinaryOwnershipRelation,
                    entries: entries, tmdbSeasonEpisodeCounts: expectedTMDBSeasonCounts,
                    sourceEpisodes: sourceEpisodes, today: AnimeStructurePolicy.currentAirDateString()
                )
            }
            if let counts {
                allowsLinearTMDBCoordinates = true
                for (detail, count) in zip(collected, counts) {
                    resolvedEpisodeCountsByMALID[detail.id] = count
                }
            }
        }
        if !allowsLinearTMDBCoordinates {
            Logger.shared.log(
                "MALMetadata: withheld unverified linear TMDB coordinates tmdbId=\(tmdbShowId)",
                type: "Plugin"
            )
        }
        let hydrationCoordinates = tmdbCoordinatesByAbsolute.mapValues {
            AnimeStructureTMDBCoordinate(seasonNumber: $0.season, episodeNumber: $0.episode)
        }
        let verifiedEpisodePlacementsByID = AnimeStructurePolicy.nonConflictingEpisodePlacements(
            verifiedContainedEpisodesByID.merging(verifiedTerminalEpisodesByID, uniquingKeysWith: { first, _ in first })
                .filter { !$0.value.contains { exactOwnedSeasons.contains($0.seasonNumber) } }
        )
        var currentAbsoluteEpisode = 1
        var seasonNumber = 1
        var seasons: [AniListSeasonWithPoster] = []

        for (index, detail) in collected.enumerated() {
            let structuralMapping = structuralMappings.first { mapping in
                mapping.malId == detail.id
                    && (mapping.tmdbShowId == nil || mapping.tmdbShowId == tmdbShowId)
                    && AniMapStructuralRole.isRegularStory(
                        mapping,
                        fallbackMediaType: aniListFormat(from: detail.mediaType),
                        tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                        episodeCount: detail.numEpisodes,
                        regularStoryEpisodeCounts: regularStoryEpisodeCounts
                    )
            }
            var unitEpisodes: [AniListEpisode]?
            let unitFormat = detail.mediaType.flatMap { type in
                ["tv", "ona"].contains(type.lowercased()) ? type.uppercased() : nil
            }
            let uniqueCompilationOwner = AnimeVerifiedEpisodeUnitPolicy.hasNoKnownSaikiOwnerConflict(
                tmdbShowID: tmdbShowId, aniListID: structuralMapping?.anilistId, malID: detail.id,
                mappings: structuralMappings, hasOtherProvedOwner: verifiedEpisodePlacementsByID.contains { identity, episodes in
                    identity != detail.id && episodes.contains { $0.seasonNumber == 1 }
                })
            if AnimeVerifiedEpisodeUnitPolicy.requiresSaikiCompilations(
                tmdbShowID: tmdbShowId, aniListID: structuralMapping?.anilistId, malID: detail.id,
                episodeCount: detail.numEpisodes, format: unitFormat, status: detail.status,
                startDate: detail.startDate, endDate: detail.endDate, hasUniqueSourceOwner: uniqueCompilationOwner
            ), let source = try? await tmdbService.getSeasonDetails(tvShowId: tmdbShowId, seasonNumber: 1) {
                unitEpisodes = AnimeVerifiedEpisodeUnitPolicy.saikiCompiledEpisodes(
                    tmdbShowID: tmdbShowId, aniListID: structuralMapping?.anilistId, malID: detail.id,
                    episodeCount: detail.numEpisodes, format: unitFormat, status: detail.status,
                    startDate: detail.startDate, endDate: detail.endDate, hasUniqueSourceOwner: uniqueCompilationOwner,
                    sourceSeason: source, displaySeasonNumber: seasonNumber)
            } else if AnimeVerifiedEpisodeUnitPolicy.requiresRazbliutoParts(
                tmdbShowID: tmdbShowId, malID: detail.id, episodeCount: detail.numEpisodes,
                format: unitFormat, status: detail.status, startDate: detail.startDate
            ), AnimeVerifiedEpisodeUnitPolicy.hasNoKnownRazbliutoPartOwnerConflict(
                tmdbShowID: tmdbShowId, malID: detail.id, mappings: structuralMappings,
                hasOtherProvedOwner: verifiedEpisodePlacementsByID.contains { identity, episodes in
                    identity != detail.id && episodes.contains { $0.seasonNumber == 2 }
                }), let source = try? await tmdbService.getSeasonDetails(tvShowId: tmdbShowId, seasonNumber: 2) {
                unitEpisodes = AnimeVerifiedEpisodeUnitPolicy.razbliutoPartEpisodes(
                    tmdbShowID: tmdbShowId, malID: detail.id, episodeCount: detail.numEpisodes,
                    format: unitFormat, status: detail.status, startDate: detail.startDate,
                    sourceSeason: source, displaySeasonNumber: seasonNumber)
            }
            try Task.checkCancellation()
            let knownEpisodeCount = requiresVerifiedAbsoluteInventory
                ? RemoteMediaNumericBoundary.boundedSum(expectedTMDBSeasonCounts.values) ?? 0
                : max(tmdbEpisodesByAbsolute.count, tmdbCoordinatesByAbsolute.count)
            let remainingTMDBCount = max(0, knownEpisodeCount - (currentAbsoluteEpisode - 1))
            let allowsOpenEndedRemainder = collected.count == 1
                && verifiedOpenEndedActualInventory
                && AnimeStructurePolicy.allowsSingleOpenEndedSeries(
                    status: detail.status?.lowercased() == "currently_airing" ? "RELEASING" : detail.status,
                    episodeCount: detail.numEpisodes,
                    mappedTMDBSeason: resolvedCoordinateCoverageSegments.first?.mappedTMDBSeason,
                    tmdbSeasonEpisodeCounts: expectedTMDBSeasonCounts
                )
            let episodeCount = AnimeSeasonEpisodeHydrationPolicy.displayEpisodeCount(
                declaredCount: unitEpisodes?.count ?? verifiedTerminalEpisodesByID[detail.id]?.count ?? resolvedEpisodeCountsByMALID[detail.id] ?? detail.numEpisodes,
                remainingTMDBCount: remainingTMDBCount,
                allowsOpenEndedRemainder: allowsOpenEndedRemainder,
                status: detail.status
            )
            let seasonTitle = displayTitle(for: detail)
            let exactMappedStart = AnimeSeasonEpisodeHydrationPolicy.exactMappedSeasonStart(
                index: index, segments: resolvedCoordinateCoverageSegments,
                tmdbSeasonEpisodeCounts: coordinateSeasonEpisodeCounts
            )
            let provedEpisodes = verifiedEpisodePlacementsByID[detail.id]
            let provedEpisodeInventory = provedEpisodes.map { Dictionary(uniqueKeysWithValues: $0.enumerated().map { ($0.offset + 1, $0.element) }) }
            let provedCoordinates = provedEpisodeInventory?.mapValues {
                AnimeStructureTMDBCoordinate(seasonNumber: $0.seasonNumber, episodeNumber: $0.episodeNumber)
            }
            let episodes = unitEpisodes ?? AnimeSeasonEpisodeHydrationPolicy.episodes(
                count: episodeCount,
                displaySeasonNumber: seasonNumber,
                startingAt: provedEpisodes != nil ? 1 : exactMappedStart ?? currentAbsoluteEpisode,
                tmdbEpisodes: provedEpisodeInventory ?? tmdbEpisodesByAbsolute,
                tmdbCoordinates: provedCoordinates ?? hydrationCoordinates,
                allowsTMDBCoordinates: provedEpisodes != nil || exactMappedStart != nil || allowsLinearTMDBCoordinates || allowsOpenEndedRemainder
            )

            seasons.append(AniListSeasonWithPoster(
                seasonNumber: seasonNumber,
                anilistId: malProviderId(detail.id),
                canonicalAniListId: structuralMapping?.anilistId
                    ?? (unitEpisodes?.first?.unitProjection?.edition == .featurePart ? 170_935
                        : unitEpisodes?.first?.unitProjection?.edition == .compilation ? 21_804 : nil),
                malId: detail.id,
                kitsuId: structuralMapping?.kitsuId,
                title: seasonTitle,
                englishTitle: detail.alternativeTitles?.en,
                romajiTitle: detail.title,
                nativeTitle: detail.alternativeTitles?.ja,
                episodes: episodes,
                posterUrl: detail.mainPicture?.preferredURL() ?? tmdbShowPoster,
                canonicalAniListEpisodeCount: unitEpisodes.flatMap { AnimeVerifiedEpisodeUnitPolicy.canonicalAniListCount($0) },
                canonicalMALEpisodeCount: unitEpisodes.flatMap { AnimeVerifiedEpisodeUnitPolicy.canonicalMALCount($0) }
            ))

            guard let nextAbsoluteEpisode = RemoteMediaNumericBoundary.adding(
                currentAbsoluteEpisode,
                episodeCount
            ), let nextSeasonNumber = RemoteMediaNumericBoundary.adding(seasonNumber, 1),
              nextSeasonNumber <= RemoteMediaNumericBoundary.maximumSeasonNumber else {
                throw NSError(
                    domain: "MALMetadata",
                    code: -5,
                    userInfo: [NSLocalizedDescriptionKey: "MAL structure exceeded the supported numeric boundary."]
                )
            }
            currentAbsoluteEpisode = nextAbsoluteEpisode
            seasonNumber = nextSeasonNumber
        }

        guard let totalEpisodes = RemoteMediaNumericBoundary.boundedSum(
            seasons.map { $0.episodes.count }
        ) else {
            throw NSError(
                domain: "MALMetadata",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "MAL structure exceeded the supported episode limit."]
            )
        }
        let metadataRoot = collected.first(where: { $0.id == root.id }) ?? collected.first ?? root
        Logger.shared.log("MALMetadata: built fallback structure title='\(displayTitle(for: metadataRoot))' seasons=\(seasons.count) episodes=\(totalEpisodes)", type: "AniList")
        return AniListAnimeWithSeasons(
            id: malProviderId(metadataRoot.id),
            malId: metadataRoot.id,
            title: displayTitle(for: metadataRoot),
            genres: metadataRoot.genres?.compactMap(\.name),
            seasons: seasons,
            totalEpisodes: totalEpisodes,
            status: AnimeFallbackStatusPolicy.aggregateStatus(
                statuses: collected.map(\.status),
                rootStatus: metadataRoot.status
            ),
            rating: rating(from: metadataRoot)
        )
    }

    func fetchAnimeRating(id: Int) async throws -> AnimeMetadataRating? {
        struct RatingResponse: Decodable {
            let id: Int
            let title: String
            let mean: Double?
        }
        guard let exactID = RemoteMediaNumericBoundary.positiveMagnitude(id),
              var components = URLComponents(
                  url: apiBase.appendingPathComponent("anime/\(exactID)"),
                  resolvingAgainstBaseURL: false
              ) else { return nil }
        components.queryItems = [URLQueryItem(name: "fields", value: "id,title,mean")]
        guard let ratingURL = components.url else { return nil }
        let response: RatingResponse = try await fetch(ratingURL)
        guard let mean = response.mean, mean > 0 else { return nil }
        return AnimeMetadataRating(
            value: min(max(mean, 0), 10),
            source: .myAnimeList
        )
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
        async let structuralMappingsTask = AniMapMappingService.shared.mappingsResult(
            forTMDBShowId: tmdbShowId
        )
        guard let show = try? await tmdbService.getTVShowWithSeasons(id: tmdbShowId) else {
            return []
        }
        let structuralMappingResult = await structuralMappingsTask
        let tmdbSeasonEpisodeCounts = regularTMDBSeasonEpisodeCounts(show)
        let mappedRoot: MALAnimeDetails?
        if let mappedRootID = preferredMappedRegularRootID(
            mappings: structuralMappingResult.mappings,
            tmdbShowId: tmdbShowId,
            tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts
        ) {
            mappedRoot = try? await fetchAnimeDetailsForFallback(id: mappedRootID)
        } else {
            mappedRoot = nil
        }
        let root: MALAnimeDetails
        if let mappedRoot {
            root = mappedRoot
        } else {
            guard let candidates = try? await searchCandidates(
                title: show.name,
                tmdbShowId: tmdbShowId,
                tmdbShow: show,
                tmdbService: tmdbService
            ), let matched = pickBestMALMatch(from: candidates, tmdbShow: show) else {
                return []
            }
            root = matched
        }
        return (try? await buildSpecialSearchEntries(
            root: root,
            structuralMappings: structuralMappingResult.mappings,
            mappingsAreComplete: structuralMappingResult.isComplete,
            tmdbShowId: tmdbShowId,
            fallbackPosterURL: fallbackPosterURL,
            requiresCompleteGraph: false,
            tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts
        )) ?? []
    }

    func fetchSpecialSearchEntries(
        rootMalId: Int,
        tmdbShowId: Int,
        fallbackPosterURL: String?
    ) async throws -> [AniListSpecialSearchEntry] {
        try Task.checkCancellation()
        guard let normalizedRootID = RemoteMediaNumericBoundary.positiveMagnitude(rootMalId) else {
            return []
        }
        async let rootTask = fetchAnimeDetailsForFallback(id: normalizedRootID)
        async let structuralMappingsTask = AniMapMappingService.shared.mappingsResult(
            forTMDBShowId: tmdbShowId
        )
        async let showTask = try? TMDBService.shared.getTVShowWithSeasons(id: tmdbShowId)
        guard let root = try await rootTask else {
            throw NSError(domain: "MALMetadata", code: 404, userInfo: [NSLocalizedDescriptionKey: "MAL did not return the requested anime root."])
        }
        let structuralMappingResult = await structuralMappingsTask
        let tmdbSeasonEpisodeCounts = regularTMDBSeasonEpisodeCounts(await showTask)
        try Task.checkCancellation()
        return try await buildSpecialSearchEntries(
            root: root,
            structuralMappings: structuralMappingResult.mappings,
            mappingsAreComplete: structuralMappingResult.isComplete,
            tmdbShowId: tmdbShowId,
            fallbackPosterURL: fallbackPosterURL,
            requiresCompleteGraph: true,
            tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts
        )
    }

    private func buildSpecialSearchEntries(
        root: MALAnimeDetails,
        structuralMappings: [AniMapMapping],
        mappingsAreComplete: Bool,
        tmdbShowId: Int,
        fallbackPosterURL: String?,
        requiresCompleteGraph: Bool,
        tmdbSeasonEpisodeCounts: [Int: Int]?
    ) async throws -> [AniListSpecialSearchEntry] {
        let graph = try await collectRegularGraph(
            root,
            structuralMappings: structuralMappings,
            tmdbShowId: tmdbShowId,
            tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts
        )
        let regularStoryEpisodeCounts = graph.regularStoryEpisodeCounts
        var relationSources = graph.details + graph.detachedDetails
        if !relationSources.contains(where: { $0.id == root.id }) {
            relationSources.append(root)
        }
        let show = try? await TMDBService.shared.getTVShowWithSeasons(id: tmdbShowId)
        let sourceMappingsByID = Dictionary(structuralMappings.compactMap { mapping in
            mapping.malId.map { ($0, mapping) }
        }, uniquingKeysWith: { first, _ in first })
        let placementCandidates = relationSources.map { detail in
            AnimeStructureCourPlacementCandidate(id: detail.id, mappedTMDBSeason: sourceMappingsByID[detail.id]?.tmdbSeason,
                episodeCount: detail.numEpisodes, format: aniListFormat(from: detail.mediaType), status: detail.status,
                startDate: detail.startDate, endDate: detail.endDate, titles: titleCandidates(for: detail),
                hasTrustedIdentity: sourceMappingsByID[detail.id]?.tmdbShowId == tmdbShowId)
        }
        let contradictedIDs = AnimeStructurePolicy.contradictedMappedSpecialIDs(
            candidates: placementCandidates, mappingsByID: sourceMappingsByID, tmdbShow: show
        )
        let regularIDs = Set(graph.details.map(\.id)).subtracting(contradictedIDs)
        let detachedIDs = Set(graph.detachedDetails.map(\.id))
        let hydratedDetailsByID = Dictionary(uniqueKeysWithValues: relationSources.map { ($0.id, $0) })
        var candidateIDs = detachedIDs.union(contradictedIDs).sorted()
        var seenCandidateIDs = Set(candidateIDs)

        func mappingIsDetached(_ id: Int) -> Bool {
            if contradictedIDs.contains(id) { return true }
            return structuralMappings.contains { mapping in
                mapping.malId == id
                    && (mapping.tmdbShowId == nil || mapping.tmdbShowId == tmdbShowId)
                    && AniMapStructuralRole.isDetachedSpecial(mapping,
                        tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                        episodeCount: hydratedDetailsByID[id]?.numEpisodes,
                        regularStoryEpisodeCounts: regularStoryEpisodeCounts)
            }
        }

        let mappedSpecialIDs = structuralMappings
            .filter { mapping in
                mapping.malId != nil
                    && (mapping.tmdbShowId == nil || mapping.tmdbShowId == tmdbShowId)
                    && AniMapStructuralRole.isDetachedSpecial(mapping,
                        tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                        episodeCount: mapping.malId.flatMap { hydratedDetailsByID[$0]?.numEpisodes },
                        regularStoryEpisodeCounts: regularStoryEpisodeCounts)
            }
            .sorted { lhs, rhs in
                let lhsKey = (
                    lhs.tmdbSeason ?? Int.max,
                    lhs.tvdbEpisodeOffset ?? Int.max,
                    lhs.malId ?? Int.max
                )
                let rhsKey = (
                    rhs.tmdbSeason ?? Int.max,
                    rhs.tvdbEpisodeOffset ?? Int.max,
                    rhs.malId ?? Int.max
                )
                return lhsKey < rhsKey
            }
            .compactMap(\.malId)
        for id in mappedSpecialIDs where seenCandidateIDs.insert(id).inserted {
            candidateIDs.append(id)
        }
        for source in relationSources {
            for relation in source.relatedAnime ?? [] {
                let id = relation.node.id
                guard AnimeMALFallbackRelationPolicy.discoversDetachedSpecial(
                    relationType: relation.relationType,
                    isMappedDetachedSpecial: mappingIsDetached(id)
                ) else {
                    continue
                }
                if seenCandidateIDs.insert(id).inserted {
                    candidateIDs.append(id)
                }
            }
        }

        candidateIDs.removeAll { regularIDs.contains($0) }
        let maximumSpecialEntries = 64
        let boundedCandidateIDs = Array(candidateIDs.prefix(maximumSpecialEntries))
        var detailsByID = Dictionary(uniqueKeysWithValues: relationSources.filter {
            contradictedIDs.contains($0.id) || detachedIDs.contains($0.id)
        }.map { ($0.id, $0) })
        if !regularIDs.contains(root.id),
           isDetachedSpecial(root, mappings: structuralMappings,
               tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
               regularStoryEpisodeCounts: regularStoryEpisodeCounts) {
            detailsByID[root.id] = root
        }
        var failedIDs = Set<Int>()
        var start = 0
        while start < boundedCandidateIDs.count {
            try Task.checkCancellation()
            let end = min(start + 6, boundedCandidateIDs.count)
            let batchIDs = Array(boundedCandidateIDs[start..<end]).filter {
                detailsByID[$0] == nil
            }
            let batch = try await fetchMALDetailBatch(ids: batchIDs)
            detailsByID.merge(batch.detailsByID) { existing, _ in existing }
            failedIDs.formUnion(batch.failedIDs)
            start = end
        }

        let graphIsComplete = mappingsAreComplete
            && graph.failedIDs.isEmpty
            && !graph.reachedTraversalLimit
            && failedIDs.isEmpty
            && candidateIDs.count <= maximumSpecialEntries
        if requiresCompleteGraph, !graphIsComplete {
            throw NSError(
                domain: "MALMetadata",
                code: -6,
                userInfo: [NSLocalizedDescriptionKey: "MAL could not completely hydrate the anime special graph."]
            )
        }

        var details = detailsByID.values.filter {
            contradictedIDs.contains($0.id) || isDetachedSpecialCandidate($0, mappings: structuralMappings,
                tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                regularStoryEpisodeCounts: regularStoryEpisodeCounts)
        }
        var seen = Set<Int>()
        details = details.filter { seen.insert($0.id).inserted }
        let mappingByMALID = Dictionary(uniqueKeysWithValues: details.compactMap { detail in
            let mapping = structuralMappings.first { mapping in
                mapping.malId == detail.id
                    && (mapping.tmdbShowId == nil || mapping.tmdbShowId == tmdbShowId)
                    && (contradictedIDs.contains(detail.id) || AniMapStructuralRole.isDetachedSpecial(
                        mapping,
                        fallbackMediaType: aniListFormat(from: detail.mediaType),
                        tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                        episodeCount: detail.numEpisodes,
                        regularStoryEpisodeCounts: regularStoryEpisodeCounts
                    ))
            }
            return mapping.map { (detail.id, $0) }
        })
        let seasonNumbers = Set(details.map { detail in
            contradictedIDs.contains(detail.id) ? 0 : specialTMDBSeasonNumber(
                for: detail,
                mapping: mappingByMALID[detail.id],
                tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                regularStoryEpisodeCounts: regularStoryEpisodeCounts
            ) ?? 0
        })
        let seasonDetails = await fetchSpecialTMDBSeasonDetails(
            tmdbShowId: tmdbShowId,
            seasonNumbers: seasonNumbers
        )

        return details.map { detail in
            buildSpecialSearchEntry(
                detail: detail,
                mapping: mappingByMALID[detail.id],
                fallbackPosterURL: fallbackPosterURL,
                seasonDetailsByNumber: seasonDetails,
                tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                regularStoryEpisodeCounts: regularStoryEpisodeCounts,
                forceSeasonZero: contradictedIDs.contains(detail.id)
            )
        }.sorted { $0.isOrderedBeforeSpecialEntry($1) }
    }

    private func fetchSpecialTMDBSeasonDetails(
        tmdbShowId: Int,
        seasonNumbers: Set<Int>
    ) async -> [Int: TMDBSeasonDetail] {
        await withTaskGroup(of: (Int, TMDBSeasonDetail?).self) { group in
            for seasonNumber in seasonNumbers where seasonNumber >= 0 {
                group.addTask {
                    let detail = try? await TMDBService.shared.getSeasonDetails(
                        tvShowId: tmdbShowId,
                        seasonNumber: seasonNumber
                    )
                    return (seasonNumber, detail)
                }
            }
            var values: [Int: TMDBSeasonDetail] = [:]
            for await (seasonNumber, detail) in group {
                if let detail { values[seasonNumber] = detail }
            }
            return values
        }
    }

    private func regularTMDBSeasonEpisodeCounts(
        _ show: TMDBTVShowWithSeasons?
    ) -> [Int: Int]? {
        guard let show else { return nil }
        return RemoteMediaNumericBoundary.seasonEpisodeCounts(
            show.seasons.compactMap { season in
                guard season.seasonNumber > 0, season.episodeCount > 0 else { return nil }
                return (season.seasonNumber, season.episodeCount)
            }
        )
    }

    private func specialTMDBSeasonNumber(
        for detail: MALAnimeDetails,
        mapping: AniMapMapping?,
        tmdbSeasonEpisodeCounts: [Int: Int]?,
        regularStoryEpisodeCounts: [Int: Int]
    ) -> Int? {
        guard let mapping else { return nil }
        if (mapping.tmdbSeason ?? 0) > 0,
           AniMapStructuralRole.isDetachedSpecial(mapping,
               fallbackMediaType: aniListFormat(from: detail.mediaType),
               tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
               episodeCount: detail.numEpisodes,
               regularStoryEpisodeCounts: regularStoryEpisodeCounts) {
            return 0
        }
        return mapping.tmdbSeason
    }

    private func buildSpecialSearchEntry(
        detail: MALAnimeDetails,
        mapping: AniMapMapping?,
        fallbackPosterURL: String?,
        seasonDetailsByNumber: [Int: TMDBSeasonDetail],
        tmdbSeasonEpisodeCounts: [Int: Int]?,
        regularStoryEpisodeCounts: [Int: Int],
        forceSeasonZero: Bool = false
    ) -> AniListSpecialSearchEntry {
        let episodeCount = RemoteMediaNumericBoundary.episodeCount(
            max(detail.numEpisodes ?? 1, 1)
        ) ?? 1
        let title = displayTitle(for: detail)
        let mappedSeason = forceSeasonZero ? 0 : specialTMDBSeasonNumber(
            for: detail,
            mapping: mapping,
            tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
            regularStoryEpisodeCounts: regularStoryEpisodeCounts
        )
        let tmdbSeasonDetail = seasonDetailsByNumber[mappedSeason ?? 0]
        let exactTMDBEpisodes = AnimeSpecialEpisodeHydrationPolicy.exactEpisodes(
            episodeCount: episodeCount,
            exactReleaseDate: detail.startDate,
            mappedSeasonNumber: mappedSeason,
            seasonDetailsByNumber: seasonDetailsByNumber,
            exactEndDate: detail.endDate?.count == 10 ? detail.endDate : nil
        )
        let episodes = (1...episodeCount).map { number in
            let tmdbEpisode = exactTMDBEpisodes.indices.contains(number - 1)
                ? exactTMDBEpisodes[number - 1]
                : nil
            return AniListEpisode(
                number: number,
                title: tmdbEpisode?.name ?? (episodeCount == 1 ? title : "Episode \(number)"),
                description: tmdbEpisode?.overview,
                seasonNumber: tmdbEpisode?.seasonNumber ?? mappedSeason ?? 0,
                stillPath: tmdbEpisode?.stillPath,
                airDate: tmdbEpisode?.airDate,
                runtime: tmdbEpisode?.runtime,
                tmdbSeasonNumber: tmdbEpisode?.seasonNumber,
                tmdbEpisodeNumber: tmdbEpisode?.episodeNumber
            )
        }
        return AniListSpecialSearchEntry(
            id: malProviderId(detail.id),
            canonicalAniListId: mapping?.anilistId,
            malId: detail.id,
            kitsuId: mapping?.kitsuId,
            title: title,
            englishTitle: detail.alternativeTitles?.en,
            romajiTitle: detail.title,
            nativeTitle: detail.alternativeTitles?.ja,
            format: mapping?.mediaType?.uppercased() ?? aniListFormat(from: detail.mediaType),
            episodeCount: episodeCount,
            posterUrl: detail.mainPicture?.preferredURL()
                ?? tmdbSeasonDetail?.fullPosterURL
                ?? fallbackPosterURL,
            tmdbSeasonNumber: mappedSeason,
            tvdbSeasonNumber: mapping?.tvdbSeason,
            episodeOffset: mapping?.tvdbEpisodeOffset,
            imdbId: mapping?.imdbId,
            releaseDate: detail.startDate ?? episodes.compactMap(\.airDate).min(),
            status: detail.status?.uppercased(),
            episodes: episodes
        )
    }

    func fetchParentTitleCandidates(forMalMediaId mediaId: Int, maxDepth: Int) async -> [(englishTitle: String?, romajiTitle: String?, nativeTitle: String?)] {
        guard let initialID = RemoteMediaNumericBoundary.positiveMagnitude(mediaId),
              (1...32).contains(maxDepth) else {
            return []
        }
        var currentId = initialID
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

        let maximumCandidateIDs = 18
        let detailBatchSize = 6
        var seenQueries = Set<String>()
        var seenIds = Set<Int>()
        var candidateIDs: [Int] = []
        searchLoop: for candidate in candidates.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }) where !candidate.isEmpty {
            let key = normalized(candidate)
            guard seenQueries.insert(key).inserted else { continue }
            let nodes = (try? await searchAnime(query: candidate, limit: 8)) ?? []
            for node in nodes where seenIds.insert(node.id).inserted {
                try Task.checkCancellation()
                candidateIDs.append(node.id)
                if candidateIDs.count >= maximumCandidateIDs {
                    break searchLoop
                }
            }
        }

        var details: [MALAnimeDetails] = []
        var start = 0
        while start < candidateIDs.count, details.count < 12 {
            try Task.checkCancellation()
            let ids = Array(candidateIDs[start..<min(start + detailBatchSize, candidateIDs.count)])
            let batch = try await fetchMALDetailBatch(ids: ids)
            for id in ids {
                if let detail = batch.detailsByID[id] {
                    details.append(detail)
                }
            }
            start += ids.count
        }
        return details
    }

    private func orphanCandidates(
        root: MALAnimeDetails,
        title: String,
        tmdbShow: TMDBTVShowWithSeasons?,
        structuralMappings: [AniMapMapping],
        tmdbSeasonEpisodeCounts: [Int: Int]?,
        regularStoryEpisodeCounts: [Int: Int]
    ) async throws -> [MALAnimeDetails] {
        let rootKey = normalized(displayTitle(for: root))
        let rootPrefix = String(rootKey.prefix(min(rootKey.count, 12)))
        let searchTitles = [title, root.title, root.alternativeTitles?.en].compactMap { $0 }
        let maximumCandidateIDs = 24
        let detailBatchSize = 6
        var seenIds = Set<Int>([root.id])
        var candidateIDs: [Int] = []

        searchLoop: for title in searchTitles {
            try Task.checkCancellation()
            guard let nodes = try? await searchAnime(query: title, limit: 20) else { continue }
            for node in nodes where seenIds.insert(node.id).inserted {
                try Task.checkCancellation()
                candidateIDs.append(node.id)
                if candidateIDs.count >= maximumCandidateIDs {
                    break searchLoop
                }
            }
        }

        var candidates: [MALAnimeDetails] = []
        var start = 0
        while start < candidateIDs.count, candidates.count < 12 {
            try Task.checkCancellation()
            let ids = Array(candidateIDs[start..<min(start + detailBatchSize, candidateIDs.count)])
            let batch = try await fetchMALDetailBatch(ids: ids)
            for id in ids {
                guard let detail = batch.detailsByID[id],
                      isNormalSeasonCandidate(detail, mappings: structuralMappings,
                          tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                          regularStoryEpisodeCounts: regularStoryEpisodeCounts) else { continue }
                guard AnimeRelationRolePolicy.fitsRegularTMDBInventory(
                    isMappedRegular: structuralMappings.contains {
                        $0.malId == detail.id && $0.tmdbShowId == tmdbShow?.id
                            && AniMapStructuralRole.isRegularStory($0,
                                fallbackMediaType: aniListFormat(from: detail.mediaType),
                                tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                                episodeCount: detail.numEpisodes,
                                regularStoryEpisodeCounts: regularStoryEpisodeCounts)
                    },
                    episodeCount: detail.numEpisodes,
                    status: detail.status,
                    tmdbEpisodeCount: tmdbShow?.numberOfEpisodes
                ) else { continue }
                let candidateKey = normalized(displayTitle(for: detail))
                guard candidateKey.hasPrefix(rootPrefix)
                        || rootKey.hasPrefix(String(candidateKey.prefix(min(candidateKey.count, 12)))) else {
                    continue
                }
                candidates.append(detail)
                if candidates.count >= 12 { break }
            }
            start += ids.count
        }

        let lastKnownYear = root.startSeason?.year ?? root.startDate.flatMap { Int(String($0.prefix(4))) } ?? 0
        return candidates
            .filter { ($0.startSeason?.year ?? $0.startDate.flatMap { Int(String($0.prefix(4))) } ?? Int.max) >= lastKnownYear }
            .sorted { (sortableDate(for: $0) ?? "9999") < (sortableDate(for: $1) ?? "9999") }
    }

    private func preferredMappedRegularRootID(
        mappings: [AniMapMapping],
        tmdbShowId: Int,
        tmdbSeasonEpisodeCounts: [Int: Int]? = nil
    ) -> Int? {
        mappings
            .filter { mapping in
                mapping.malId != nil
                    && (mapping.tmdbShowId == nil || mapping.tmdbShowId == tmdbShowId)
                    && AniMapStructuralRole.isRegularStory(mapping,
                        tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts)
            }
            .sorted { lhs, rhs in
                let lhsKey = (
                    lhs.tmdbSeason.flatMap { $0 > 0 ? $0 : nil } ?? Int.max,
                    lhs.tvdbSeason.flatMap { $0 > 0 ? $0 : nil } ?? Int.max,
                    lhs.tvdbEpisodeOffset ?? Int.max,
                    lhs.malId ?? Int.max
                )
                let rhsKey = (
                    rhs.tmdbSeason.flatMap { $0 > 0 ? $0 : nil } ?? Int.max,
                    rhs.tvdbSeason.flatMap { $0 > 0 ? $0 : nil } ?? Int.max,
                    rhs.tvdbEpisodeOffset ?? Int.max,
                    rhs.malId ?? Int.max
                )
                return lhsKey < rhsKey
            }
            .compactMap(\.malId)
            .first
    }

    private func collectRegularGraph(
        _ root: MALAnimeDetails,
        structuralMappings: [AniMapMapping],
        tmdbShowId: Int,
        tmdbSeasonEpisodeCounts: [Int: Int]? = nil
    ) async throws -> MALRegularGraphResult {
        let mappedRegularEntryCount = Set(structuralMappings.compactMap { mapping -> Int? in
            guard mapping.tmdbShowId == tmdbShowId,
                  AniMapStructuralRole.isRegularStory(mapping,
                    tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts) else { return nil }
            return mapping.malId
        }).count
        let maximumRegularEntries = AnimeMALFallbackRelationPolicy.regularGraphEntryLimit(
            tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
            mappedRegularEntryCount: mappedRegularEntryCount
        )
        let maximumFetchedEntries = maximumRegularEntries * 2
        let fetchBatchSize = 6
        var detailsByID: [Int: MALAnimeDetails] = [:]
        var bridgeDetailsByID: [Int: MALAnimeDetails] = [:]
        var scheduledIDs = Set<Int>([root.id])
        var pendingIDs: [Int] = []
        var failedIDs = Set<Int>()
        var fetchedCount = 0

        func mappingIsRegular(_ id: Int) -> Bool {
            structuralMappings.contains { mapping in
                mapping.malId == id
                    && (mapping.tmdbShowId == nil || mapping.tmdbShowId == tmdbShowId)
                    && AniMapStructuralRole.isRegularStory(mapping,
                        tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts)
            }
        }

        func bridgeEntry(_ detail: MALAnimeDetails) -> AnimeMALFallbackRelationPolicy.BridgeEntry {
            let mappings = structuralMappings.filter { $0.malId == detail.id }
            let foreign = mappings.contains { $0.tmdbShowId != nil && $0.tmdbShowId != tmdbShowId }
                && !mappings.contains { $0.tmdbShowId == tmdbShowId }
            let format = detail.mediaType.flatMap { type in
                ["tv", "ova", "ona", "special", "tv_special"].contains(type.lowercased())
                    ? aniListFormat(from: type) : nil
            }
            return .init(id: detail.id, format: format, status: detail.status,
                episodeCount: detail.numEpisodes, startDate: detail.startDate, endDate: detail.endDate,
                prequelIDs: (detail.relatedAnime ?? []).filter { $0.relationType.lowercased() == "prequel" }.map { $0.node.id },
                sequelIDs: (detail.relatedAnime ?? []).filter { $0.relationType.lowercased() == "sequel" }.map { $0.node.id },
                hasForeignMapping: foreign)
        }

        func enqueueRelations(from detail: MALAnimeDetails) {
            if detail.status?.lowercased() == "finished_airing",
               let inventory = tmdbSeasonEpisodeCounts.flatMap({ RemoteMediaNumericBoundary.boundedSum($0.values) }),
               detail.numEpisodes == inventory,
               structuralMappings.contains(where: { $0.malId == detail.id && $0.tmdbShowId == tmdbShowId
                   && AniMapStructuralRole.isRegularStory($0, fallbackMediaType: aniListFormat(from: detail.mediaType)) }) {
                return
            }
            for relation in detail.relatedAnime ?? [] {
                let id = relation.node.id
                let identityMappings = structuralMappings.filter { $0.malId == id }
                if identityMappings.contains(where: { $0.tmdbShowId != nil && $0.tmdbShowId != tmdbShowId }),
                   !identityMappings.contains(where: { $0.tmdbShowId == tmdbShowId }) { continue }
                guard AnimeMALFallbackRelationPolicy.traversesRegular(
                    relationType: relation.relationType,
                    isMappedRegular: mappingIsRegular(id)
                ) else {
                    continue
                }
                if scheduledIDs.insert(id).inserted {
                    pendingIDs.append(id)
                }
            }
        }

        if isNormalSeasonCandidate(root, mappings: structuralMappings,
            tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts) {
            detailsByID[root.id] = root
        }
        enqueueRelations(from: root)

        let mappedRegularIDs = structuralMappings
            .filter { mapping in
                mapping.malId != nil
                    && (mapping.tmdbShowId == nil || mapping.tmdbShowId == tmdbShowId)
                    && AniMapStructuralRole.isRegularStory(mapping,
                        tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts)
            }
            .sorted { lhs, rhs in
                let lhsKey = (
                    lhs.tmdbSeason ?? Int.max,
                    lhs.tvdbSeason ?? Int.max,
                    lhs.tvdbEpisodeOffset ?? Int.max,
                    lhs.malId ?? Int.max
                )
                let rhsKey = (
                    rhs.tmdbSeason ?? Int.max,
                    rhs.tvdbSeason ?? Int.max,
                    rhs.tvdbEpisodeOffset ?? Int.max,
                    rhs.malId ?? Int.max
                )
                return lhsKey < rhsKey
            }
            .compactMap(\.malId)
        for id in mappedRegularIDs where scheduledIDs.insert(id).inserted {
            pendingIDs.append(id)
        }

        while !pendingIDs.isEmpty,
              detailsByID.count < maximumRegularEntries,
              fetchedCount < maximumFetchedEntries {
            try Task.checkCancellation()
            let batchCount = min(
                fetchBatchSize,
                pendingIDs.count,
                maximumFetchedEntries - fetchedCount
            )
            let batchIDs = Array(pendingIDs.prefix(batchCount))
            pendingIDs.removeFirst(batchCount)
            fetchedCount += batchIDs.count
            let batch = try await fetchMALDetailBatch(ids: batchIDs)
            failedIDs.formUnion(batch.failedIDs)

            for id in batchIDs {
                guard let detail = batch.detailsByID[id] else { continue }
                if !isNormalSeasonCandidate(detail, mappings: structuralMappings,
                    tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts) {
                    let bridge = bridgeEntry(detail)
                    let linked = detailsByID.values.compactMap { current in
                        AnimeMALFallbackRelationPolicy.specialBridgeOppositeID(bridge, current: bridgeEntry(current))
                    }
                    guard Set(linked).count == 1, let oppositeID = linked.first else { continue }
                    let oppositeMappings = structuralMappings.filter { $0.malId == oppositeID }
                    if oppositeMappings.contains(where: { $0.tmdbShowId != nil && $0.tmdbShowId != tmdbShowId }),
                       !oppositeMappings.contains(where: { $0.tmdbShowId == tmdbShowId }) { continue }
                    bridgeDetailsByID[id] = detail
                    if scheduledIDs.insert(oppositeID).inserted { pendingIDs.append(oppositeID) }
                    continue
                }
                guard AnimeRelationRolePolicy.fitsRegularTMDBInventory(
                    isMappedRegular: structuralMappings.contains {
                        $0.malId == detail.id && $0.tmdbShowId == tmdbShowId
                            && AniMapStructuralRole.isRegularStory($0,
                                fallbackMediaType: aniListFormat(from: detail.mediaType),
                                tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                                episodeCount: detail.numEpisodes)
                    },
                    episodeCount: detail.numEpisodes,
                    status: detail.status,
                    tmdbEpisodeCount: tmdbSeasonEpisodeCounts.flatMap {
                        RemoteMediaNumericBoundary.boundedSum($0.values)
                    }
                ) else { continue }
                if detailsByID.count < maximumRegularEntries {
                    detailsByID[id] = detail
                    enqueueRelations(from: detail)
                }
            }
        }

        let regularStoryEpisodeCounts = AniMapStructuralRole.ordinarySeasonEpisodeCounts(
            structuralMappings.filter { $0.tmdbShowId == nil || $0.tmdbShowId == tmdbShowId },
            identity: { $0.malId },
            mediaType: { mapping in
                mapping.malId.flatMap { detailsByID[$0]?.mediaType }.map { aniListFormat(from: $0) }
            },
            episodeCount: { mapping in
                guard let id = mapping.malId, let detail = detailsByID[id] else { return nil }
                if detail.status?.lowercased() == "not_yet_aired" { return 0 }
                return detail.numEpisodes
            }
        )
        var details = detailsByID.values.filter {
            isNormalSeasonCandidate($0, mappings: structuralMappings,
                tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                regularStoryEpisodeCounts: regularStoryEpisodeCounts)
        }
        let bridgeConstraints = bridgeDetailsByID.values.compactMap { bridge -> AnimeStructureRelationConstraint? in
            let entry = bridgeEntry(bridge)
            guard let priorID = entry.prequelIDs.first, let nextID = entry.sequelIDs.first,
                  let prior = detailsByID[priorID], let next = detailsByID[nextID] else { return nil }
            return AnimeMALFallbackRelationPolicy.verifiedSpecialBridge(entry, prequel: bridgeEntry(prior), sequel: bridgeEntry(next))
        }
        if !bridgeDetailsByID.isEmpty {
            let ids = Set(details.map(\.id))
            let direct = details.flatMap { detail in
                (detail.relatedAnime ?? []).compactMap { relation -> AnimeStructureRelationConstraint? in
                    guard ["prequel", "sequel"].contains(relation.relationType.lowercased()),
                          ids.contains(relation.node.id) else { return nil }
                    return .init(beforeID: detail.id, afterID: relation.node.id)
                }
            }
            let reachable = AnimeStructurePolicy.ordinaryConnectedIDs(rootID: root.id, candidateIDs: ids,
                constraints: direct + bridgeConstraints)
            details = details.filter { reachable.contains($0.id) || mappedRegularIDs.contains($0.id) }
        }
        let regularIDs = Set(details.map(\.id))
        let detachedDetails = detailsByID.values.filter {
            !regularIDs.contains($0.id) && isDetachedSpecial($0, mappings: structuralMappings,
                tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                regularStoryEpisodeCounts: regularStoryEpisodeCounts)
        }
        return MALRegularGraphResult(
            details: Array(details),
            detachedDetails: Array(detachedDetails) + Array(bridgeDetailsByID.values),
            specialBridgeConstraints: bridgeConstraints,
            usedSpecialBridgeTraversal: !bridgeDetailsByID.isEmpty,
            failedIDs: failedIDs,
            reachedTraversalLimit: !pendingIDs.isEmpty,
            regularStoryEpisodeCounts: regularStoryEpisodeCounts
        )
    }

    private func fetchMALDetailBatch(ids: [Int]) async throws -> MALDetailBatchResult {
        try await withThrowingTaskGroup(of: (Int, MALAnimeDetails?).self) { group in
            for id in ids {
                group.addTask { [self] in
                    (id, try await fetchAnimeDetailsForFallback(id: id))
                }
            }
            var detailsByID: [Int: MALAnimeDetails] = [:]
            var failedIDs = Set<Int>()
            for try await (id, detail) in group {
                if let detail {
                    detailsByID[id] = detail
                } else {
                    failedIDs.insert(id)
                }
            }
            return MALDetailBatchResult(
                detailsByID: detailsByID,
                failedIDs: failedIDs
            )
        }
    }

    private func fetchAnimeDetailsForFallback(id: Int) async throws -> MALAnimeDetails? {
#if DEBUG
        let diagnosticRequestID = UUID().uuidString
        let diagnosticOperation = "anime/\(id)"
#endif
        for attempt in 0..<2 {
            try Task.checkCancellation()
#if DEBUG
            let attemptStart = ProcessInfo.processInfo.systemUptime
#endif
            do {
                let detail = try await fetchAnimeDetails(id: id)
#if DEBUG
                await AnimeMetadataLoadingValidation.requestLedger?.recordEvent(
                    provider: "MAL", stage: "detail-ready", operation: diagnosticOperation,
                    requestID: diagnosticRequestID, startedAtUptime: attemptStart,
                    durationSeconds: ProcessInfo.processInfo.systemUptime - attemptStart, attempt: attempt + 1
                )
#endif
                return detail
            } catch {
#if DEBUG
                let failure = error as NSError
                await AnimeMetadataLoadingValidation.requestLedger?.recordEvent(
                    provider: "MAL", stage: "detail-error", operation: diagnosticOperation,
                    requestID: diagnosticRequestID, startedAtUptime: attemptStart,
                    durationSeconds: ProcessInfo.processInfo.systemUptime - attemptStart, attempt: attempt + 1,
                    errorDomain: failure.domain, errorCode: failure.code
                )
#endif
                if Task.isCancelled
                    || error is CancellationError
                    || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                guard attempt == 0, shouldRetryMALDetailFetch(error) else {
                    Logger.shared.log(
                        "MALMetadata: detail fetch failed id=\(id) error=\(error.localizedDescription)",
                        type: "AniList"
                    )
                    return nil
                }
#if DEBUG
                let retryStart = ProcessInfo.processInfo.systemUptime
                do {
                    try await Task.sleep(nanoseconds: 350_000_000)
                    await AnimeMetadataLoadingValidation.requestLedger?.recordEvent(
                        provider: "MAL", stage: "retry-sleep", operation: diagnosticOperation,
                        requestID: diagnosticRequestID, startedAtUptime: retryStart,
                        durationSeconds: ProcessInfo.processInfo.systemUptime - retryStart,
                        attempt: attempt + 1, retryDelaySeconds: 0.35
                    )
                } catch {
                    let failure = error as NSError
                    await AnimeMetadataLoadingValidation.requestLedger?.recordEvent(
                        provider: "MAL", stage: "retry-sleep-error", operation: diagnosticOperation,
                        requestID: diagnosticRequestID, startedAtUptime: retryStart,
                        durationSeconds: ProcessInfo.processInfo.systemUptime - retryStart, attempt: attempt + 1,
                        errorDomain: failure.domain, errorCode: failure.code, retryDelaySeconds: 0.35
                    )
                    throw error
                }
#else
                try await Task.sleep(nanoseconds: 350_000_000)
#endif
            }
        }
        return nil
    }

    private func shouldRetryMALDetailFetch(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "MALMetadata" {
            return nsError.code == 408
                || nsError.code == 429
                || (500...599).contains(nsError.code)
        }
        let code = (error as? URLError)?.code
            ?? (nsError.domain == NSURLErrorDomain ? URLError.Code(rawValue: nsError.code) : nil)
        switch code {
        case .timedOut, .networkConnectionLost, .cannotFindHost,
             .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    private func fetchRanking(type: String, limit: Int) async throws -> [MALAnimeDetails] {
        guard (1...100).contains(limit) else {
            throw NSError(domain: "MALMetadata", code: -4, userInfo: [NSLocalizedDescriptionKey: "MAL ranking limit is outside the supported range."])
        }
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
        guard RemoteMediaNumericBoundary.year(year) != nil,
              (1...100).contains(limit) else {
            throw NSError(domain: "MALMetadata", code: -4, userInfo: [NSLocalizedDescriptionKey: "MAL season request is outside the supported range."])
        }
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
        guard (1...100).contains(limit) else {
            throw NSError(domain: "MALMetadata", code: -4, userInfo: [NSLocalizedDescriptionKey: "MAL search limit is outside the supported range."])
        }
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
        guard let id = RemoteMediaNumericBoundary.positiveIdentifier(id) else {
            throw NSError(domain: "MALMetadata", code: -4, userInfo: [NSLocalizedDescriptionKey: "MAL anime identifier is outside the supported range."])
        }
        return try await MALAnimeDetailRequestCache.shared.value(for: id) { [self] in
            guard var components = URLComponents(
                url: apiBase.appendingPathComponent("anime/\(id)"),
                resolvingAgainstBaseURL: false
            ) else {
                throw NSError(domain: "MALMetadata", code: -3, userInfo: [NSLocalizedDescriptionKey: "MAL detail URL could not be built for anime \(id)."])
            }
            components.queryItems = [URLQueryItem(name: "fields", value: detailFields)]
            guard let detailURL = components.url else {
                throw NSError(domain: "MALMetadata", code: -3, userInfo: [NSLocalizedDescriptionKey: "MAL detail URL could not be built for anime \(id)."])
            }
            return try await fetch(detailURL)
        }
    }

    private func fetch<T: Decodable>(_ url: URL) async throws -> T {
        guard !clientID.isEmpty else {
            throw NSError(domain: "MALMetadata", code: -2, userInfo: [NSLocalizedDescriptionKey: "MAL_CLIENT_ID is not configured."])
        }
        let wallClockTimeout: TimeInterval = AniListRequestContext.isDetailReadyPath ? 8 : 20
        var request = URLRequest(url: url)
#if DEBUG
        if Self.isLiveRegressionValidation {
            request.cachePolicy = .reloadIgnoringLocalCacheData
        }
#endif
        request.setValue(clientID, forHTTPHeaderField: "X-MAL-CLIENT-ID")
        request.timeoutInterval = wallClockTimeout
        let timeoutNanoseconds = UInt64(wallClockTimeout * 1_000_000_000)
#if DEBUG
        let diagnosticRequestID = UUID().uuidString
        let diagnosticWallClockStart = ProcessInfo.processInfo.systemUptime
#endif
        let payload = try await withThrowingTaskGroup(of: MALHTTPPayload.self) { group in
            group.addTask {
                var session = URLSession.shared
#if DEBUG
                session = AnimeMetadataLoadingValidation.session ?? session
                await AnimeMetadataLoadingValidation.requestLedger?.record(provider: "MAL")
                let requestStart = ProcessInfo.processInfo.systemUptime
#endif
                do {
                    let (data, response) = try await session.boundedData(
                        for: request,
                        maximumResponseBytes: RemoteMediaNumericBoundary.maximumMetadataResponseBytes
                    )
#if DEBUG
                    let requestElapsed = ProcessInfo.processInfo.systemUptime - requestStart
                    await AnimeMetadataLoadingValidation.requestLedger?.recordDuration(provider: "MAL", seconds: requestElapsed)
                    await AnimeMetadataLoadingValidation.requestLedger?.recordEvent(
                        provider: "MAL", stage: "response", operation: url.path,
                        requestID: diagnosticRequestID, startedAtUptime: requestStart,
                        durationSeconds: requestElapsed, statusCode: (response as? HTTPURLResponse)?.statusCode
                    )
#endif
                    return MALHTTPPayload(data: data, response: response)
                } catch {
#if DEBUG
                    let requestElapsed = ProcessInfo.processInfo.systemUptime - requestStart
                    let failure = error as NSError
                    await AnimeMetadataLoadingValidation.requestLedger?.recordDuration(provider: "MAL", seconds: requestElapsed)
                    await AnimeMetadataLoadingValidation.requestLedger?.recordEvent(
                        provider: "MAL", stage: "transport-error", operation: url.path,
                        requestID: diagnosticRequestID, startedAtUptime: requestStart,
                        durationSeconds: requestElapsed, errorDomain: failure.domain, errorCode: failure.code
                    )
#endif
                    throw error
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
#if DEBUG
                await AnimeMetadataLoadingValidation.requestLedger?.recordEvent(
                    provider: "MAL", stage: "wall-timeout", operation: url.path,
                    requestID: diagnosticRequestID, startedAtUptime: diagnosticWallClockStart,
                    durationSeconds: ProcessInfo.processInfo.systemUptime - diagnosticWallClockStart,
                    errorDomain: NSURLErrorDomain, errorCode: URLError.timedOut.rawValue
                )
#endif
                throw URLError(.timedOut)
            }

            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw URLError(.unknown)
            }
            return first
        }
        let data = payload.data
        let response = payload.response
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
                    let identitySeed = AnimeMediaIdentitySeed(
                        anilistId: self.malProviderId(anime.id),
                        malId: anime.id,
                        kitsuId: nil,
                        format: format
                    )

                    if let cached = await AnimeTMDBMatchCache.shared.lookup(cacheKey) {
                        return (
                            anime.id,
                            cached.result?.withAnimeIdentitySeed(identitySeed),
                            nil
                        )
                    }

                    guard !Task.isCancelled else { return (anime.id, nil, nil) }
                    var result: TMDBSearchResult?
                    var lookupCompleted = !candidates.isEmpty
                    for candidate in candidates {
                        guard !Task.isCancelled else { return (anime.id, nil, nil) }
                        if isMovie {
                            do {
                                let movies = try await tmdbService.searchMovies(query: candidate)
                                if let best = self.bestMovieMatch(results: movies, candidate: candidate, expectedYear: expectedYear) {
                                    result = best.asSearchResult
                                    break
                                }
                            } catch {
                                lookupCompleted = false
                            }
                        }
                        do {
                            let shows = try await tmdbService.searchTVShows(query: candidate)
                            if let best = self.bestTVMatch(results: shows, candidate: candidate, expectedYear: expectedYear) {
                                result = best.asSearchResult
                                break
                            }
                        } catch {
                            lookupCompleted = false
                        }
                    }
                    guard !Task.isCancelled else { return (anime.id, nil, nil) }
                    let seededResult = result?.withAnimeIdentitySeed(identitySeed)
                    return (
                        anime.id,
                        seededResult,
                        (seededResult != nil || lookupCompleted)
                            ? AnimeTMDBMatchCacheRecord(key: cacheKey, result: seededResult)
                            : nil
                    )
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
        if let expectedYear, let actualYear = year.flatMap({ Int(String($0.prefix(4))) }),
           let difference = RemoteMediaNumericBoundary.absoluteDifference(actualYear, expectedYear) {
            score += max(0, 15 - Double(difference) * 3)
        }
        score += min(popularity / 100.0, 10)
        return score
    }

    private func pickBestMALMatch(from candidates: [MALAnimeDetails], tmdbShow: TMDBTVShowWithSeasons?) -> MALAnimeDetails? {
        guard let tmdbShow else {
            return candidates
                .filter { isNormalSeasonCandidate($0, mappings: []) }
                .max { ($0.numEpisodes ?? 0) < ($1.numEpisodes ?? 0) } ?? candidates.first
        }

        let tmdbYear = tmdbShow.firstAirDate.flatMap { Int(String($0.prefix(4))) }
        let tmdbEpisodes = tmdbShow.numberOfEpisodes
        let tmdbTitle = normalized(tmdbShow.name)
        let pool = candidates.filter { isNormalSeasonCandidate($0, mappings: []) }
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
        if let tmdbYear,
           let year = anime.startSeason?.year ?? anime.startDate.flatMap({ Int(String($0.prefix(4))) }),
           let difference = RemoteMediaNumericBoundary.absoluteDifference(year, tmdbYear),
           difference <= 4 {
            score += max(0, 18 - difference * 4)
        }
        if let tmdbEpisodes, let episodes = anime.numEpisodes, episodes > 0,
           let difference = RemoteMediaNumericBoundary.absoluteDifference(episodes, tmdbEpisodes) {
            score += max(0, 20 - min(difference, 20))
        }
        if ["TV", "TV_SHORT", "ONA"].contains(aniListFormat(from: anime.mediaType)) {
            score += 10
        }
        return score
    }

    private func relationOrderedMALDetails(_ details: [MALAnimeDetails]) -> [MALAnimeDetails] {
        let orderingCandidates = details.map { detail -> AnimeStructureOrderingCandidate in
            let dateParts = (sortableDate(for: detail) ?? "").split(separator: "-")
            return AnimeStructureOrderingCandidate(
                anilistId: detail.id, mappedTMDBSeason: nil, episodeOffset: nil,
                startYear: dateParts.indices.contains(0) ? Int(dateParts[0]) : nil,
                startMonth: dateParts.indices.contains(1) ? Int(dateParts[1]) : nil,
                startDay: dateParts.indices.contains(2) ? Int(dateParts[2]) : nil,
                seasonYear: detail.startSeason?.year, seasonOrdinal: 4
            )
        }
        let relationConstraints = details.flatMap { detail in
            (detail.relatedAnime ?? []).compactMap { relation -> AnimeStructureRelationConstraint? in
                switch relation.relationType.lowercased() {
                case "sequel": return .init(beforeID: detail.id, afterID: relation.node.id)
                case "prequel": return .init(beforeID: relation.node.id, afterID: detail.id)
                default: return nil
                }
            }
        }
        let orderedIDs = AnimeStructurePolicy.relationOrderedIDs(orderingCandidates, constraints: relationConstraints)
        let rank = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($0.element, $0.offset) })
        return details.sorted { (rank[$0.id] ?? Int.max) < (rank[$1.id] ?? Int.max) }

    }

    private func pruneMALSeasons(_ seasons: [MALAnimeDetails], rootIndex: Int, tmdbEpisodeBudget: Int,
        retainedProviderIDs: Set<Int> = []) -> [MALAnimeDetails] {
        let retainedIdentities = Set(seasons.indices.filter {
            seasons[$0].status?.lowercased() == "not_yet_aired"
                || retainedProviderIDs.contains(seasons[$0].id)
        })
        let indices = AnimeStructurePolicy.budgetedIndices(
            episodeCounts: seasons.map(\.numEpisodes), rootIndex: rootIndex,
            episodeBudget: tmdbEpisodeBudget, retainedIdentityIndices: retainedIdentities
        )
        return indices.map { seasons[$0] }
    }

    private func fetchTMDBEpisodesByAbsolute(
        tmdbShowId: Int,
        tvShowDetail: TMDBTVShowWithSeasons?,
        tmdbService: TMDBService,
        absoluteEpisodeLimit: Int? = nil,
        allowsSummaryCoordinateFallback: Bool = true
    ) async -> (episodes: [Int: TMDBEpisode], coordinates: [Int: (season: Int, episode: Int)]) {
        var episodesByAbsolute: [Int: TMDBEpisode] = [:]
        var coordinatesByAbsolute: [Int: (season: Int, episode: Int)] = [:]
        if let absoluteEpisodeLimit,
           !(1...RemoteMediaNumericBoundary.maximumTotalEpisodeCount).contains(absoluteEpisodeLimit) {
            return (episodesByAbsolute, coordinatesByAbsolute)
        }
        let seasonSummaries = (tvShowDetail?.seasons ?? [])
            .filter { $0.seasonNumber > 0 && $0.episodeCount > 0 }
            .sorted { $0.seasonNumber < $1.seasonNumber }
        if !seasonSummaries.isEmpty {
            guard RemoteMediaNumericBoundary.seasonEpisodeCounts(
                seasonSummaries.map { ($0.seasonNumber, $0.episodeCount) }
            ) != nil else {
                return (episodesByAbsolute, coordinatesByAbsolute)
            }
            var absoluteStart = 1
            var requestedSeasonNumbers: Set<Int> = []
            for summary in seasonSummaries {
                guard let countMinusOne = RemoteMediaNumericBoundary.adding(
                    summary.episodeCount,
                    -1
                ), let upperBound = RemoteMediaNumericBoundary.adding(
                    absoluteStart,
                    countMinusOne
                ), let nextStart = RemoteMediaNumericBoundary.adding(upperBound, 1) else {
                    return (episodesByAbsolute, coordinatesByAbsolute)
                }
                let absoluteRange = absoluteStart...upperBound
                if absoluteEpisodeLimit.map({ absoluteRange.lowerBound <= $0 }) ?? true {
                    requestedSeasonNumbers.insert(summary.seasonNumber)
                }
                absoluteStart = nextStart
            }
            let fetchedEpisodesBySeason = await withTaskGroup(
                of: (seasonNumber: Int, episodes: [TMDBEpisode]).self
            ) { group in
                for summary in seasonSummaries where requestedSeasonNumbers.contains(summary.seasonNumber) {
                    group.addTask {
                        let detail = try? await tmdbService.getSeasonDetails(
                            tvShowId: tmdbShowId,
                            seasonNumber: summary.seasonNumber
                        )
                        return (
                            summary.seasonNumber,
                            detail?.episodes.sorted(by: {
                                $0.episodeNumber < $1.episodeNumber
                            }) ?? []
                        )
                    }
                }
                var values: [Int: [TMDBEpisode]] = [:]
                for await value in group where !value.episodes.isEmpty {
                    values[value.seasonNumber] = value.episodes
                }
                return values
            }
            let projected = AnimeSeasonEpisodeHydrationPolicy.hydrateTMDBInventory(
                seasons: seasonSummaries,
                fetchedEpisodesBySeason: fetchedEpisodesBySeason,
                allowsSummaryCoordinates: allowsSummaryCoordinateFallback,
                absoluteEpisodeLimit: absoluteEpisodeLimit
            )
            episodesByAbsolute = projected.episodes
            coordinatesByAbsolute = projected.coordinates.mapValues { ($0.seasonNumber, $0.episodeNumber) }
            return (episodesByAbsolute, coordinatesByAbsolute)
        }

        var absolute = 1
        for seasonNumber in 1...12 {
            if let absoluteEpisodeLimit, absolute > absoluteEpisodeLimit { break }
            guard let detail = try? await tmdbService.getSeasonDetails(tvShowId: tmdbShowId, seasonNumber: seasonNumber),
                  !detail.episodes.isEmpty else {
                break
            }
            for episode in detail.episodes.sorted(by: { $0.episodeNumber < $1.episodeNumber }) {
                guard absolute <= RemoteMediaNumericBoundary.maximumTotalEpisodeCount else {
                    return (episodesByAbsolute, coordinatesByAbsolute)
                }
                episodesByAbsolute[absolute] = episode
                coordinatesByAbsolute[absolute] = (episode.seasonNumber, episode.episodeNumber)
                guard let next = RemoteMediaNumericBoundary.adding(absolute, 1) else {
                    return (episodesByAbsolute, coordinatesByAbsolute)
                }
                absolute = next
            }
        }
        return (episodesByAbsolute, coordinatesByAbsolute)
    }

    private func isNormalSeasonCandidate(
        _ detail: MALAnimeDetails,
        mappings: [AniMapMapping] = [],
        tmdbSeasonEpisodeCounts: [Int: Int]? = nil,
        regularStoryEpisodeCounts: [Int: Int]? = nil
    ) -> Bool {
        let format = aniListFormat(from: detail.mediaType)
        let matchingMappings = mappings.filter { $0.malId == detail.id }
        if !matchingMappings.isEmpty {
            guard matchingMappings.contains(where: {
                AniMapStructuralRole.isRegularStory(
                    $0,
                    fallbackMediaType: format,
                    tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                    episodeCount: detail.numEpisodes,
                    regularStoryEpisodeCounts: regularStoryEpisodeCounts
                )
            }) else { return false }
        } else {
            guard ["TV", "TV_SHORT", "ONA"].contains(format) else { return false }
        }
        let text = titleCandidates(for: detail).joined(separator: " ").lowercased()
        return !["recap", "summary", "music", "trailer", "pv", "cm"].contains { text.contains($0) }
    }

    private func isSpecialCandidate(_ detail: MALAnimeDetails) -> Bool {
        let format = aniListFormat(from: detail.mediaType)
        if ["SPECIAL", "OVA", "ONA", "MOVIE"].contains(format) { return true }
        let text = titleCandidates(for: detail).joined(separator: " ").lowercased()
        return ["special", "ova", "oad", "ona", "side story", "movie"].contains { text.contains($0) }
    }

    private func isDetachedSpecialCandidate(
        _ detail: MALAnimeDetails,
        mappings: [AniMapMapping],
        tmdbSeasonEpisodeCounts: [Int: Int]? = nil,
        regularStoryEpisodeCounts: [Int: Int]? = nil
    ) -> Bool {
        let format = aniListFormat(from: detail.mediaType)
        let matchingMappings = mappings.filter { $0.malId == detail.id }
        if !matchingMappings.isEmpty {
            let isRegular = matchingMappings.contains {
                AniMapStructuralRole.isRegularStory(
                    $0,
                    fallbackMediaType: format,
                    tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                    episodeCount: detail.numEpisodes,
                    regularStoryEpisodeCounts: regularStoryEpisodeCounts
                )
            }
            return !isRegular && matchingMappings.contains {
                AniMapStructuralRole.isDetachedSpecial(
                    $0,
                    fallbackMediaType: format,
                    tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                    episodeCount: detail.numEpisodes,
                    regularStoryEpisodeCounts: regularStoryEpisodeCounts
                )
            }
        }
        return isSpecialCandidate(detail)
    }

    private func isDetachedSpecial(
        _ detail: MALAnimeDetails,
        mappings: [AniMapMapping],
        tmdbSeasonEpisodeCounts: [Int: Int]? = nil,
        regularStoryEpisodeCounts: [Int: Int]? = nil
    ) -> Bool {
        let format = aniListFormat(from: detail.mediaType)
        let matchingMappings = mappings.filter { $0.malId == detail.id }
        if !matchingMappings.isEmpty {
            let isRegular = matchingMappings.contains {
                AniMapStructuralRole.isRegularStory(
                    $0,
                    fallbackMediaType: format,
                    tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                    episodeCount: detail.numEpisodes,
                    regularStoryEpisodeCounts: regularStoryEpisodeCounts
                )
            }
            return !isRegular && matchingMappings.contains {
                AniMapStructuralRole.isDetachedSpecial(
                    $0,
                    fallbackMediaType: format,
                    tmdbSeasonEpisodeCounts: tmdbSeasonEpisodeCounts,
                    episodeCount: detail.numEpisodes,
                    regularStoryEpisodeCounts: regularStoryEpisodeCounts
                )
            }
        }
        return AniMapStructuralRole.isPotentialDetachedFormat(format)
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
        var calendar = AppCalendar.current
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
        let weeks = max(0, AppCalendar.current.dateComponents([.weekOfYear], from: start, to: airingAt).weekOfYear ?? 0)
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
        let components = AppCalendar.current.dateComponents([.year, .month], from: date)
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
        RemoteMediaNumericBoundary.negativeProviderIdentifier(malId) ?? 0
    }

    private func normalized(_ value: String) -> String {
        value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = AppCalendar.dateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private struct MALSearchResponse: Decodable {
        let data: [Entry]
        struct Entry: Decodable { let node: MALAnimeNode }

        private enum CodingKeys: String, CodingKey { case data }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let decoded = try container.decode([Entry].self, forKey: .data)
            guard decoded.count <= RemoteMediaNumericBoundary.maximumRemoteRows else {
                throw DecodingError.dataCorruptedError(
                    forKey: .data,
                    in: container,
                    debugDescription: "MAL search response exceeds the supported row limit."
                )
            }
            data = decoded
        }
    }

    private struct MALListResponse: Decodable {
        let data: [Entry]
        struct Entry: Decodable { let node: MALAnimeDetails }

        private enum CodingKeys: String, CodingKey { case data }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let decoded = try container.decode([Entry].self, forKey: .data)
            guard decoded.count <= RemoteMediaNumericBoundary.maximumRemoteRows else {
                throw DecodingError.dataCorruptedError(
                    forKey: .data,
                    in: container,
                    debugDescription: "MAL list response exceeds the supported row limit."
                )
            }
            data = decoded
        }
    }

    private struct MALAnimeNode: Decodable {
        let id: Int
        let title: String

        private enum CodingKeys: String, CodingKey { case id, title }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let rawID = try container.decode(Int.self, forKey: .id)
            guard let id = RemoteMediaNumericBoundary.positiveIdentifier(rawID) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .id,
                    in: container,
                    debugDescription: "MAL identifier is outside the supported range."
                )
            }
            self.id = id
            title = try container.decode(String.self, forKey: .title)
        }
    }

    private struct MALAnimeDetails: Decodable {
        let id: Int
        let title: String
        let mainPicture: MALPicture?
        let alternativeTitles: MALAlternativeTitles?
        let mean: Double?
        let startDate: String?
        let endDate: String?
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
            case endDate = "end_date"
            case mediaType = "media_type"
            case numEpisodes = "num_episodes"
            case startSeason = "start_season"
            case relatedAnime = "related_anime"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let rawID = try container.decode(Int.self, forKey: .id)
            guard let id = RemoteMediaNumericBoundary.positiveIdentifier(rawID) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .id,
                    in: container,
                    debugDescription: "MAL identifier is outside the supported range."
                )
            }
            self.id = id
            title = try container.decode(String.self, forKey: .title)
            mainPicture = try container.decodeIfPresent(MALPicture.self, forKey: .mainPicture)
            alternativeTitles = try container.decodeIfPresent(MALAlternativeTitles.self, forKey: .alternativeTitles)
            if let rawMean = try container.decodeIfPresent(Double.self, forKey: .mean) {
                guard rawMean.isFinite, (0...10).contains(rawMean) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .mean,
                        in: container,
                        debugDescription: "MAL score is outside the supported range."
                    )
                }
                mean = rawMean
            } else {
                mean = nil
            }
            startDate = try container.decodeIfPresent(String.self, forKey: .startDate)
            endDate = try container.decodeIfPresent(String.self, forKey: .endDate)
            mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType)
            status = try container.decodeIfPresent(String.self, forKey: .status)
            let rawEpisodeCount = try container.decodeIfPresent(Int.self, forKey: .numEpisodes)
            if let rawEpisodeCount, rawEpisodeCount != 0 {
                guard let count = RemoteMediaNumericBoundary.episodeCount(rawEpisodeCount) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .numEpisodes,
                        in: container,
                        debugDescription: "MAL episode count is outside the supported range."
                    )
                }
                numEpisodes = count
            } else {
                numEpisodes = nil
            }
            startSeason = try container.decodeIfPresent(MALStartSeason.self, forKey: .startSeason)
            broadcast = try container.decodeIfPresent(MALBroadcast.self, forKey: .broadcast)
            rating = try container.decodeIfPresent(String.self, forKey: .rating)
            let decodedGenres = try container.decodeIfPresent([MALGenre].self, forKey: .genres)
            guard (decodedGenres?.count ?? 0) <= 64 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .genres,
                    in: container,
                    debugDescription: "MAL genre collection exceeds the supported limit."
                )
            }
            genres = decodedGenres
            let decodedRelations = try container.decodeIfPresent([MALRelatedAnime].self, forKey: .relatedAnime)
            guard (decodedRelations?.count ?? 0) <= RemoteMediaNumericBoundary.maximumRelationCount else {
                throw DecodingError.dataCorruptedError(
                    forKey: .relatedAnime,
                    in: container,
                    debugDescription: "MAL relation collection exceeds the supported limit."
                )
            }
            relatedAnime = decodedRelations
        }
    }

    private struct MALPicture: Decodable {
        let medium: String?
        let large: String?

        func preferredURL(dataSaverEnabled: Bool = ImageDataSaverSettings.isEnabled()) -> String? {
            ImageDataSaverSettings.preferredURL(large: large, medium: medium, dataSaverEnabled: dataSaverEnabled)
        }
    }

    private struct MALAlternativeTitles: Decodable {
        let synonyms: [String]?
        let en: String?
        let ja: String?
    }

    private struct MALStartSeason: Decodable {
        let year: Int
        let season: String

        private enum CodingKeys: String, CodingKey { case year, season }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let rawYear = try container.decode(Int.self, forKey: .year)
            guard let year = RemoteMediaNumericBoundary.year(rawYear) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .year,
                    in: container,
                    debugDescription: "MAL season year is outside the supported range."
                )
            }
            self.year = year
            season = try container.decode(String.self, forKey: .season)
        }
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

    private actor MALAnimeDetailRequestCache {
        static let shared = MALAnimeDetailRequestCache()

        private struct Entry {
            let value: MALAnimeDetails
            let storedAt: Date
        }

        private var entries: [Int: Entry] = [:]
        private var inFlight: [Int: Task<MALAnimeDetails, Error>] = [:]
        private let ttl: TimeInterval = 30 * 60

        func value(
            for id: Int,
            operation: @escaping () async throws -> MALAnimeDetails
        ) async throws -> MALAnimeDetails {
#if DEBUG
            if MALMetadataService.isLiveRegressionValidation {
                return try await operation()
            }
#endif
            if let entry = entries[id], Date().timeIntervalSince(entry.storedAt) < ttl {
                return entry.value
            }
            entries[id] = nil
            if let existing = inFlight[id] {
                return try await existing.value
            }

            let task = Task { try await operation() }
            inFlight[id] = task
            do {
                let value = try await task.value
                inFlight[id] = nil
                entries[id] = Entry(value: value, storedAt: Date())
                if entries.count > 80 {
                    entries = Dictionary(uniqueKeysWithValues: entries
                        .sorted { $0.value.storedAt > $1.value.storedAt }
                        .prefix(80)
                        .map { ($0.key, $0.value) })
                }
                return value
            } catch {
                inFlight[id] = nil
                throw error
            }
        }
    }
}

#if DEBUG
enum AnimeMALMetadataValidation {
    static func details(
        title: String,
        tmdbShowId: Int,
        hydrationPolicy: AnimeEpisodeHydrationPolicy,
        tmdbShowDetail: TMDBTVShowWithSeasons
    ) async throws -> AniListAnimeWithSeasons {
        try await MALMetadataService.$isLiveRegressionValidation.withValue(true) {
            try await MALMetadataService.shared.fetchAnimeDetailsWithEpisodes(
                title: title,
                tmdbShowId: tmdbShowId,
                tmdbService: .shared,
                tmdbShowPoster: tmdbShowDetail.posterPath,
                hydrationPolicy: hydrationPolicy,
                knownTMDBShowDetail: tmdbShowDetail
            )
        }
    }
}
#endif
