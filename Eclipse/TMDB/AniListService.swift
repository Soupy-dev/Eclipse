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
    private var didLoad = false

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

    private static let detailsKey = "anime.metadata.details.cache.v2"
    private static let legacyDetailsKey = "anime.metadata.details.cache.v1"
    private static let maxAge: TimeInterval = 60 * 60 * 24 * 45

    private static let freshMaxAge: TimeInterval = 60 * 60

    private static let maximumEntryCount = 16
    private static let maximumEpisodeCost = 4_000
    private var details: [String: CachedDetails]

    private init() {
        UserDefaults.standard.removeObject(forKey: Self.legacyDetailsKey)
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
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
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
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        fileURL = cacheDirectory.appendingPathComponent("anime-detail-preview-policy-v4.json")
        let supersededPolicyURL = cacheDirectory.appendingPathComponent("anime-detail-preview-policy-v3.json")
        try? FileManager.default.removeItem(at: supersededPolicyURL)
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
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
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

    static let maximumServerDelay: TimeInterval = 120
    private static let defaultMinInterval: TimeInterval = 0.8
    private static let maximumMinInterval: TimeInterval = 60

    private var minInterval: TimeInterval
    private let burstCapacity: Int
    private var nextAvailableTime: Date = .distantPast
    private var globalPauseUntil: Date = .distantPast

    init(minInterval: TimeInterval = 0.8, burstCapacity: Int = 4) {
        let finiteInterval = minInterval.isFinite ? minInterval : Self.defaultMinInterval
        self.minInterval = min(max(0, finiteInterval), Self.maximumMinInterval)
        self.burstCapacity = max(1, burstCapacity)
    }

    static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        guard interval.isFinite, interval > 0 else { return 0 }
        let scaled = (interval * 1_000_000_000).rounded(.up)
        guard scaled.isFinite, scaled > 0 else { return UInt64.max }
        return UInt64(exactly: scaled) ?? UInt64.max
    }

    static func boundedRetryAfter(_ rawValue: String?, fallback: TimeInterval = 5) -> TimeInterval {
        let finiteFallback = fallback.isFinite ? fallback : 5
        let boundedFallback = min(max(finiteFallback, 1), maximumServerDelay)
        guard let rawValue,
              let parsed = TimeInterval(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsed.isFinite,
              parsed > 0 else {
            return boundedFallback
        }
        return min(parsed, maximumServerDelay)
    }

    static func boundedRateLimitInterval(_ rawValue: String?) -> TimeInterval? {
        guard let rawValue,
              let limit = TimeInterval(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              limit.isFinite,
              limit > 0 else {
            return nil
        }
        let interval = 60 / limit
        guard interval.isFinite else { return nil }
        return min(max(interval, defaultMinInterval), maximumMinInterval)
    }

    static func boundedResetDelay(_ rawValue: String?, now: Date = Date()) -> TimeInterval? {
        guard let rawValue,
              let resetEpoch = TimeInterval(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              resetEpoch.isFinite else {
            return nil
        }
        let delay = resetEpoch - now.timeIntervalSince1970
        guard delay.isFinite, delay > 0 else { return nil }
        return min(delay, maximumServerDelay)
    }

    func waitForSlot(deadline: Date? = nil) async throws {
        while true {
            try Task.checkCancellation()
            let now = Date()

            let burstAllowance = minInterval * TimeInterval(burstCapacity - 1)
            let earliestVirtualSlot = now.addingTimeInterval(-burstAllowance)
            let slotTime = max(max(earliestVirtualSlot, nextAvailableTime), globalPauseUntil)

            if let deadline, max(slotTime, now) > deadline {

                throw AniListRateLimiterError.localBackPressure(
                    slotTime: max(slotTime, now),
                    deadline: deadline
                )
            }
            let reservedNextAvailableTime = slotTime.addingTimeInterval(minInterval)
            nextAvailableTime = reservedNextAvailableTime

            let delay = slotTime.timeIntervalSince(now)
            do {
                if delay > 0.001 {
                    try await Task.sleep(nanoseconds: Self.nanoseconds(for: delay))
                }
                try Task.checkCancellation()
            } catch {

                if nextAvailableTime == reservedNextAvailableTime {
                    nextAvailableTime = max(Date(), slotTime)
                }
                throw error
            }

            if globalPauseUntil > Date() {
                continue
            }
            return
        }
    }

    func recordResponse(_ response: HTTPURLResponse) {
        if let interval = Self.boundedRateLimitInterval(
            response.value(forHTTPHeaderField: "X-RateLimit-Limit")
        ) {
            minInterval = interval
        }

        if response.statusCode == 429 {
            pauseUntilRetryAfter(response)
            return
        }

        guard let remainingValue = response.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
              let remaining = Int(remainingValue),
              remaining <= 1,
              let delay = Self.boundedResetDelay(
                response.value(forHTTPHeaderField: "X-RateLimit-Reset")
              ) else {
            return
        }
        pause(for: delay)
    }

    func pauseUntilRetryAfter(_ response: HTTPURLResponse) {
        pause(for: Self.boundedRetryAfter(response.value(forHTTPHeaderField: "Retry-After")))
    }

    func pause(for interval: TimeInterval) {
        guard interval.isFinite, interval > 0 else { return }
        let boundedInterval = min(interval, Self.maximumServerDelay)
        pause(until: Date().addingTimeInterval(boundedInterval))
    }

    private func pause(until date: Date) {
        let now = Date()
        let delay = date.timeIntervalSince(now)
        guard delay.isFinite, delay > 0 else { return }
        let boundedDate = now.addingTimeInterval(min(delay, Self.maximumServerDelay))
        globalPauseUntil = max(globalPauseUntil, boundedDate)
        nextAvailableTime = max(nextAvailableTime, boundedDate)
    }
}

private struct AniMapMapping: Codable, Sendable {
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
    }
}

private enum AniMapStructuralRole {
    private static let detachedFormats: Set<String> = [
        "SPECIAL", "OVA", "OAD", "ONA", "MOVIE", "MUSIC"
    ]

    static func isRegularStory(
        _ mapping: AniMapMapping,
        fallbackMediaType: String? = nil
    ) -> Bool {
        let type = (mapping.mediaType ?? fallbackMediaType)?.uppercased()
        switch type {
        case nil, "TV", "TV_SHORT":
            return true
        case "ONA":
            return (mapping.tmdbSeason ?? 0) > 0 || (mapping.tvdbSeason ?? 0) > 0
        case "SPECIAL", "OVA", "OAD", "MOVIE":
            return (mapping.tmdbSeason ?? 0) > 0
        default:
            return false
        }
    }

    static func isDetachedSpecial(
        _ mapping: AniMapMapping,
        fallbackMediaType: String? = nil
    ) -> Bool {
        let type = (mapping.mediaType ?? fallbackMediaType)?.uppercased()
        guard type.map(detachedFormats.contains) == true else { return false }
        return !isRegularStory(mapping, fallbackMediaType: fallbackMediaType)
    }

    static func isPotentialDetachedFormat(_ mediaType: String?) -> Bool {
        mediaType.map { detachedFormats.contains($0.uppercased()) } == true
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

private actor AniMapMappingService {
    static let shared = AniMapMappingService()

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
    private static let cacheSchemaVersion = 3
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

    private let populatedTTL: TimeInterval = 24 * 60 * 60
    private let emptyTTL: TimeInterval = 15 * 60
    private let failureTTL: TimeInterval = 30
    private let persistedShowTTL: TimeInterval = 7 * 24 * 60 * 60
    private let globalIndexTTL: TimeInterval = 7 * 24 * 60 * 60

    private static let maximumShowCacheBytes = 8 * 1_024 * 1_024
    private static let maximumGlobalIndexMetaBytes = 16 * 1_024 * 1_024

    private init() {
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        showCacheURL = cacheDirectory.appendingPathComponent("animap-show-mappings-v2.json")
        globalIndexMetaURL = cacheDirectory.appendingPathComponent("animap-global-index-meta-v3.json")
        globalIndexBlobURL = cacheDirectory.appendingPathComponent("animap-global-index-blob-v3.bin")

        let legacyGlobalIndexURL = cacheDirectory.appendingPathComponent("animap-global-index-v2.json")
        try? FileManager.default.removeItem(at: legacyGlobalIndexURL)

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

    func specialMappingsResult(forTMDBShowId tmdbShowId: Int) async -> AniMapLookupResult {
        let result = await mappingsResult(forTMDBShowId: tmdbShowId)
        let mappings = result.mappings.filter { AniMapStructuralRole.isDetachedSpecial($0) }
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

            let timeout: TimeInterval = mappingKey == "anilist" ? 1.5 : 2.0
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
        let timeoutNanoseconds = UInt64(
            max(0.1, wallClockTimeout) * 1_000_000_000
        )
        let payload = try await withThrowingTaskGroup(of: HTTPPayload.self) { group in
            group.addTask {
                let (data, response) = try await URLSession.shared.boundedData(
                    for: request,
                    maximumResponseBytes: maximumResponseBytes
                )
                return HTTPPayload(data: data, response: response)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw URLError(.timedOut)
            }

            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw URLError(.unknown)
            }
            return first
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

struct AnimeStructureMappedOrderSegment: Equatable {
    let mappedTMDBSeason: Int?
    let mappedTVDBSeason: Int?
    let tvdbEpisodeOffset: Int?
    let episodeCount: Int?
}

enum AnimeRelationRolePolicy {
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

enum AnimeSpecialEpisodeHydrationPolicy {
    static func exactEpisodes(
        episodeCount: Int,
        exactReleaseDate: String?,
        mappedSeasonNumber: Int?,
        seasonDetailsByNumber: [Int: TMDBSeasonDetail]
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

enum AnimeStructurePolicy {
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
        hydrationPolicy == .complete || hasExactCoverage || hasMatchingEpisodeTotals
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

        let lhsYear = lhs.seasonYear ?? Int.max
        let rhsYear = rhs.seasonYear ?? Int.max
        if lhsYear != rhsYear { return lhsYear < rhsYear }
        if lhs.seasonOrdinal != rhs.seasonOrdinal {
            return lhs.seasonOrdinal < rhs.seasonOrdinal
        }
        return lhs.anilistId < rhs.anilistId
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

            if hasNextPage && currentPage <= maxPages {
                try await Task.sleep(nanoseconds: 400_000_000)
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
        guard !keys.isEmpty, !Task.isCancelled else { return [:] }
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

    func prefetchAnimeDetailSnapshot(
        tmdbShowId: Int,
        seedAniListId: Int?,
        seedMALId: Int? = nil,
        allowStaleSnapshot: Bool = false
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

        guard seedAniListId.map({ $0 < 0 }) != true else { return false }

        return await AniListRequestContext.$isDetailReadyPath.withValue(true) { [self] in
            let plan = await aniMapSeasonSeedPlan(forTMDBShowId: tmdbShowId)
            let seedHasRegularMapping = seedAniListId.map(plan.ids.contains) ?? false
            var ids = plan.snapshotIDs
            if let seedAniListId, seedAniListId > 0, !ids.contains(seedAniListId) {
                ids.append(seedAniListId)
            }
            guard !ids.isEmpty, !Task.isCancelled else { return seedHasRegularMapping }
            _ = await batchFetchAniListStructureNodesResult(ids: ids)
            return seedHasRegularMapping
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

        let effectiveSeedMALId = RemoteMediaNumericBoundary.positiveIdentifier(seedMALId)
            ?? seedAniListId.flatMap { value in
                value < 0 ? RemoteMediaNumericBoundary.positiveMagnitude(value) : nil
            }
        let memoryCacheKey = animeDetailsCacheKey(
            tmdbShowId: tmdbShowId,
            hydrationPolicy: hydrationPolicy
        )
        if hydrationPolicy == .initiallyVisible,
           let cached = animeDetailsCache.object(forKey: animeDetailsCacheKey(tmdbShowId: tmdbShowId)),
           Date().timeIntervalSince(cached.timestamp) < animeCacheTTL,
           cached.value.satisfiesIdentitySeeds(aniListID: seedAniListId, malID: effectiveSeedMALId) {
            return cached.value
        }
        if let cached = animeDetailsCache.object(forKey: memoryCacheKey),
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
        return try await AnimeDetailRequestCoordinator.shared.value(for: key) { [self] in
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

        if let cached = await AnimeIdentityCache.shared.cachedFreshDetails(
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

        if hydrationPolicy == .initiallyVisible,
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
                let result = try await AniListRequestContext.$isDetailReadyPath.withValue(
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
                cacheAnimeDetails(
                    result,
                    forKey: animeDetailsCacheKey(
                        tmdbShowId: tmdbShowId,
                        hydrationPolicy: hydrationPolicy
                    )
                )
                if hydrationPolicy == .initiallyVisible {
                    await AnimeDetailPreviewCache.shared.store(
                        result,
                        tmdbShowId: tmdbShowId,
                        languageCode: tmdbMatchCacheLanguage
                    )
                } else {
                    await AnimeIdentityCache.shared.storeAniListDetails(
                        result,
                        tmdbShowId: tmdbShowId,
                        title: title,
                        languageCode: tmdbMatchCacheLanguage
                    )
                }
                return result
            } catch {
                AnimeProviderHealthCenter.shared.recordMALFailure(error)
                throw error
            }
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
            if hydrationPolicy == .complete,
               result.satisfiesIdentitySeeds(aniListID: seedAniListId, malID: seedMALId) {
                await AnimeIdentityCache.shared.storeAniListDetails(
                    result,
                    tmdbShowId: tmdbShowId,
                    title: title,
                    languageCode: tmdbMatchCacheLanguage
                )
            } else if hydrationPolicy == .initiallyVisible,
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
            if hydrationPolicy == .initiallyVisible,
               let cached = await AnimeDetailPreviewCache.shared.value(
                   tmdbShowId: tmdbShowId,
                   languageCode: tmdbMatchCacheLanguage,
                   seedAniListId: seedAniListId,
                   seedMALId: seedMALId,
                   allowStale: true
               ) {
                return cached
            }
            if let cached = await AnimeIdentityCache.shared.cachedDetails(
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
        requiredAbsoluteRange: ClosedRange<Int>? = nil
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
            var seasonAbsoluteStart = 1
            for season in realSeasons {
                guard let episodes = fetchedEpisodesBySeason[season.seasonNumber] else {
                    for offset in 0..<season.episodeCount {
                        guard let absolute = RemoteMediaNumericBoundary.adding(
                            seasonAbsoluteStart,
                            offset
                        ) else { return hydration }
                        hydration.coordinates[absolute] = TMDBEpisodeCoordinate(
                            seasonNumber: season.seasonNumber,
                            episodeNumber: offset + 1
                        )
                    }
                    guard let next = RemoteMediaNumericBoundary.adding(
                        seasonAbsoluteStart,
                        season.episodeCount
                    ) else { return hydration }
                    seasonAbsoluteStart = next
                    continue
                }
                guard episodes.count <= RemoteMediaNumericBoundary.maximumEpisodeCount else {
                    return hydration
                }
                let sortedEpisodes = episodes.sorted { $0.episodeNumber < $1.episodeNumber }
                Logger.shared.log(
                    "AniListService: TMDB season \(season.seasonNumber) returned \(sortedEpisodes.count) episodes",
                    type: "AniList"
                )
                for (offset, episode) in sortedEpisodes.enumerated() {
                    guard let absolute = RemoteMediaNumericBoundary.adding(
                        seasonAbsoluteStart,
                        offset
                    ) else { return hydration }
                    hydration.episodes[absolute] = episode
                    hydration.coordinates[absolute] = TMDBEpisodeCoordinate(
                        seasonNumber: episode.seasonNumber,
                        episodeNumber: episode.episodeNumber
                    )
                }
                guard let next = RemoteMediaNumericBoundary.adding(
                    seasonAbsoluteStart,
                    sortedEpisodes.count
                ) else { return hydration }
                seasonAbsoluteStart = next
            }
        }

        guard hydration.episodes.isEmpty, !Task.isCancelled else {
            return hydration
        }

        guard requiredAbsoluteRange == nil else { return hydration }

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
            episode.tmdbSeasonNumber.flatMap { $0 > 0 ? $0 : nil }
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

    private func aniMapSeasonSeedPlan(forTMDBShowId tmdbShowId: Int) async -> AniMapSeasonSeedPlan {
        let lookup = await AniMapMappingService.shared.mappingsResult(forTMDBShowId: tmdbShowId)
        return seasonSeedPlan(
            from: lookup.mappings,
            forTMDBShowId: tmdbShowId,
            isComplete: lookup.isComplete
        )
    }

    private func seasonSeedPlan(
        from allMappings: [AniMapMapping],
        forTMDBShowId tmdbShowId: Int,
        isComplete: Bool
    ) -> AniMapSeasonSeedPlan {
        guard !allMappings.isEmpty else {
            return AniMapSeasonSeedPlan(
                mappings: [],
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
        let relevantMappings = allMappings.filter { mapping in
            mapping.tmdbShowId == tmdbShowId && AniMapStructuralRole.isRegularStory(mapping)
        }
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

    private func isMappedAniListSeasonCandidate(
        _ anime: AniListAnime,
        mapping: AniMapMapping?
    ) -> Bool {
        guard anime.status != "NOT_YET_RELEASED" else { return false }
        guard let mapping,
              AniMapStructuralRole.isRegularStory(
                  mapping,
                  fallbackMediaType: anime.format
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
        allowPreviewCoverage: Bool
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
                  isMappedAniListSeasonCandidate(node, mapping: mapping) else {
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
        let ids = Set(anime.map(\.id))
        guard ids.count > 1 else { return anime.map(\.id) }

        var outgoing: [Int: Set<Int>] = [:]
        var indegree = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0) })
        func addConstraint(before: Int, after: Int) {
            guard before != after, ids.contains(before), ids.contains(after) else { return }
            if outgoing[before, default: []].insert(after).inserted {
                indegree[after, default: 0] += 1
            }
        }

        for entry in anime {
            for edge in entry.relations?.edges ?? [] where ids.contains(edge.node.id) {
                switch edge.relationType {
                case "SEQUEL":
                    addConstraint(before: entry.id, after: edge.node.id)
                case "PREQUEL":
                    addConstraint(before: edge.node.id, after: entry.id)
                default:
                    break
                }
            }
        }

        let chronologicalIDs = AnimeStructurePolicy.orderedIDs(
            anime.map { animeStructureOrderingCandidate(anime: $0, mapping: nil) }
        )
        let chronologicalRank = Dictionary(
            uniqueKeysWithValues: chronologicalIDs.enumerated().map { ($0.element, $0.offset) }
        )
        func sortedByChronology(_ values: [Int]) -> [Int] {
            values.sorted {
                (chronologicalRank[$0] ?? Int.max) < (chronologicalRank[$1] ?? Int.max)
            }
        }

        var ready = sortedByChronology(indegree.compactMap { $0.value == 0 ? $0.key : nil })
        var result: [Int] = []
        while let next = ready.first {
            ready.removeFirst()
            result.append(next)
            for destination in sortedByChronology(Array(outgoing[next] ?? [])) {
                indegree[destination, default: 0] -= 1
                if indegree[destination] == 0 {
                    ready.append(destination)
                    ready = sortedByChronology(ready)
                }
            }
        }

        if result.count < ids.count {
            let emitted = Set(result)
            result.append(contentsOf: chronologicalIDs.filter { !emitted.contains($0) })
        }
        return result
    }

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
        func logDetailTiming(_ stage: String, fields: String = "") {
            guard hydrationPolicy == .initiallyVisible else { return }
            let elapsedMs = Int(
                ((ProcessInfo.processInfo.systemUptime - detailTimingStart) * 1_000).rounded()
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
        if let cached = animeDetailsCache.object(forKey: cacheKey),
           Date().timeIntervalSince(cached.timestamp) < animeCacheTTL,
           cached.value.satisfiesIdentitySeeds(aniListID: seedAniListId, malID: seedMALId) {
            Logger.shared.log("AniListService: Cache HIT for tmdbId=\(tmdbShowId)", type: "AniList")
            return cached.value
        }

        Logger.shared.log("AniListService: fetchAnimeDetailsWithEpisodes START for '\(title)' tmdbId=\(tmdbShowId)", type: "AniList")

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
        let aniMapSeedPlan = await aniMapSeasonSeedPlan(forTMDBShowId: tmdbShowId)
        logDetailTiming(
            "animap-plan",
            fields: "mapped=\(aniMapSeedPlan.ids.count) snapshot=\(aniMapSeedPlan.snapshotIDs.count) complete=\(aniMapSeedPlan.isComplete)"
        )
        var aniMapCandidateIds = aniMapSeedPlan.ids
        if let seedAniListId, seedAniListId > 0, !aniMapCandidateIds.contains(seedAniListId) {
            aniMapCandidateIds.insert(seedAniListId, at: 0)
        }
        try Task.checkCancellation()
        let snapshotIDs = Array(Set(aniMapSeedPlan.snapshotIDs + aniMapCandidateIds)).sorted()
        if !snapshotIDs.isEmpty {
            let nodeResult = await batchFetchAniListStructureNodesResult(ids: snapshotIDs)
            try Task.checkCancellation()
            aniMapNodesByID = nodeResult.nodes
            logDetailTiming(
                "structure-nodes",
                fields: "requested=\(snapshotIDs.count) resolved=\(nodeResult.nodes.count)"
            )
            candidates = aniMapCandidateIds.compactMap { nodeResult.nodes[$0] }
            let hydratedCandidateCount = candidates.count
            let normalSeasonCandidates = candidates.filter {
                isMappedAniListSeasonCandidate($0, mapping: aniMapSeedPlan.mapping(for: $0.id))
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
                    startDate { year month day }
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

        var anime = pickBestAniListMatch(from: candidates, tmdbShow: tvShowDetail)
        let mappingContainsAuthoritativeSeed = seedAniListId.map(aniMapSeedPlan.ids.contains) ?? true
        let validatedMappedStructure = mappingContainsAuthoritativeSeed
            ? validatedAniMapStructure(
                plan: aniMapSeedPlan,
                nodesByID: aniMapNodesByID,
                tvShowDetail: tvShowDetail,
                allowPreviewCoverage: hydrationPolicy == .initiallyVisible
            )
            : nil
        logDetailTiming(
            "structure-validation",
            fields: "accepted=\(validatedMappedStructure != nil) candidates=\(candidates.count)"
        )

        if let firstMapped = validatedMappedStructure?.first {

            anime = firstMapped
        }

        if validatedMappedStructure == nil,
           let tmdbEps = tvShowDetail?.numberOfEpisodes, tmdbEps > 12,
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

        if validatedMappedStructure == nil, anime.relations == nil {
            if let enriched = (await batchFetchAniListNodes(ids: [anime.id]))[anime.id] {
                anime = enriched
            }
            try Task.checkCancellation()
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
            let poster = entry.coverImage?.large ?? entry.coverImage?.medium ?? tmdbShowPoster
            allAnimeToProcess.append((entry, 0, poster))
        }

        if let validatedMappedStructure {
            validatedMappedStructure.forEach(appendAnime)
        } else {
            appendAnime(anime)
        }

        Logger.shared.log("AniListService: Starting sequel detection for \(AniListTitlePicker.title(from: anime.title, preferredLanguageCode: preferredLanguageCode)) (ID: \(anime.id), episodes: \(anime.episodes ?? 0), relations: \(anime.relations?.edges.count ?? 0))", type: "AniList")

        let allowedRelationTypes: Set<String> = ["SEQUEL", "PREQUEL", "SEASON"]

        var queue: [AniListAnime] = validatedMappedStructure == nil ? [anime] : []
        var seenIds = Set<Int>(allAnimeToProcess.map { $0.anime.id })
        var exactSelectedContinuationIDs = Set<Int>()
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

            for current in currentLevel {
                let currentTitle = AniListTitlePicker.title(from: current.title, preferredLanguageCode: preferredLanguageCode)
                let edges = current.relations?.edges ?? []
                Logger.shared.log("AniListService: Checking relations for '\(currentTitle)': \(edges.count) edges total", type: "AniList")

                for edge in edges {
                    guard allowedRelationTypes.contains(edge.relationType), edge.node.type == "ANIME" else {
                        continue
                    }
                    let isExactSelectedContinuation = edge.relationType.uppercased() == "SEQUEL"
                        && AnimeRelationRolePolicy.isExactSelectedRegularEntry(
                            mediaID: edge.node.id,
                            selectedMediaID: seedAniListId,
                            mediaFormat: edge.node.format
                        )
                    if edge.node.status?.uppercased() == "NOT_YET_RELEASED",
                       !isExactSelectedContinuation {
                        continue
                    }
                    if let format = edge.node.format,
                       !(format == "TV" || format == "TV_SHORT" || format == "ONA") {
                        let mapping = aniMapSeedPlan.mapping(for: edge.node.id)
                        guard isMappedAniListSeasonCandidate(edge.node.asAnime(), mapping: mapping) else {
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
        logDetailTiming(
            "relation-traversal",
            fields: "used=\(validatedMappedStructure == nil) seasons=\(allAnimeToProcess.count)"
        )

        if validatedMappedStructure == nil,
           let tvShowDetail,
           !allAnimeToProcess.isEmpty,
           let tmdbTotalEps = tvShowDetail.numberOfEpisodes,
           let minimumExpected = RemoteMediaNumericBoundary.scaledEpisodeCount(
            tmdbTotalEps,
            numerator: 3,
            denominator: 4
           ),
           let anilistTotalEps = RemoteMediaNumericBoundary.boundedSum(
            allAnimeToProcess.map { $0.anime.episodes ?? 0 }
           ) {
            if anilistTotalEps < minimumExpected {
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
                    if let bestOrphan = sortedOrphans.first ?? orphanCandidates.first {
                        seenIds.insert(bestOrphan.id)
                        appendAnime(bestOrphan)
                        Logger.shared.log("AniListService: Best orphan entry: '\(AniListTitlePicker.title(from: bestOrphan.title, preferredLanguageCode: preferredLanguageCode))' (id: \(bestOrphan.id), episodes: \(bestOrphan.episodes ?? 0))", type: "AniList")

                        let orphanWithRelations: AniListAnime
                        if bestOrphan.relations != nil {
                            orphanWithRelations = bestOrphan
                        } else if let fetched = (await batchFetchAniListNodes(ids: [bestOrphan.id]))[bestOrphan.id] {
                            orphanWithRelations = fetched
                        } else {
                            orphanWithRelations = bestOrphan
                        }

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
                                    if let format = edge.node.format,
                                       !(format == "TV" || format == "TV_SHORT" || format == "ONA") {
                                        let mapping = aniMapSeedPlan.mapping(for: edge.node.id)
                                        guard isMappedAniListSeasonCandidate(edge.node.asAnime(), mapping: mapping) else {
                                            continue
                                        }
                                    }
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

        if validatedMappedStructure == nil {
            let orderedIDs = AnimeStructurePolicy.orderedIDs(
                allAnimeToProcess.map {
                    animeStructureOrderingCandidate(anime: $0.anime, mapping: nil)
                }
            )
            let rank = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($0.element, $0.offset) })
            allAnimeToProcess.sort {
                (rank[$0.anime.id] ?? Int.max) < (rank[$1.anime.id] ?? Int.max)
            }
        }

        if let tvShowDetail,
           exactSelectedContinuationIDs.isDisjoint(with: allAnimeToProcess.map { $0.anime.id }),
           let tmdbTotalEps = tvShowDetail.numberOfEpisodes,
           let budget = RemoteMediaNumericBoundary.scaledEpisodeCount(
            tmdbTotalEps,
            numerator: 5,
            denominator: 4
           ),
           let anilistTotalEps = RemoteMediaNumericBoundary.boundedSum(
            allAnimeToProcess.map { $0.anime.episodes ?? 0 }
           ) {
            if anilistTotalEps > budget {
                let rootIndex = allAnimeToProcess.firstIndex(where: { $0.anime.id == anime.id }) ?? 0
                var keepStart = rootIndex
                var keepEnd = rootIndex
                var total = allAnimeToProcess[rootIndex].anime.episodes ?? 0

                var canExpandLeft = true, canExpandRight = true
                while canExpandLeft || canExpandRight {
                    if canExpandLeft && keepStart > 0 {
                        let eps = allAnimeToProcess[keepStart - 1].anime.episodes ?? 0
                        if let expanded = RemoteMediaNumericBoundary.adding(total, eps),
                           expanded <= budget {
                            keepStart -= 1
                            total = expanded
                        }
                        else { canExpandLeft = false }
                    } else { canExpandLeft = false }

                    if canExpandRight && keepEnd < allAnimeToProcess.count - 1 {
                        let eps = allAnimeToProcess[keepEnd + 1].anime.episodes ?? 0
                        if let expanded = RemoteMediaNumericBoundary.adding(total, eps),
                           expanded <= budget {
                            keepEnd += 1
                            total = expanded
                        }
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
        let coordinateCoverageSegments = allAnimeToProcess.map { item in
            AnimeStructureCoverageSegment(
                mappedTMDBSeason: aniMapSeedPlan.mapping(for: item.anime.id)?
                    .tmdbSeason
                    .flatMap { $0 > 0 ? $0 : nil },
                episodeCount: item.anime.episodes
            )
        }
        let hasExactTMDBCoordinateCoverage = AnimeStructurePolicy.hasExactCoverage(
            tmdbSeasonEpisodeCounts: expectedTMDBSeasonCounts,
            segments: coordinateCoverageSegments
        )
        let hasMatchingTMDBEpisodeTotals = AnimeStructurePolicy.hasMatchingEpisodeTotals(
            tmdbSeasonEpisodeCounts: expectedTMDBSeasonCounts,
            segments: coordinateCoverageSegments
        )
        let allowsLinearTMDBCoordinates = AnimeStructurePolicy.allowsLinearTMDBCoordinates(
            hydrationPolicy: hydrationPolicy,
            hasExactCoverage: hasExactTMDBCoordinateCoverage,
            hasMatchingEpisodeTotals: hasMatchingTMDBEpisodeTotals
        )
        if !allowsLinearTMDBCoordinates {
            Logger.shared.log(
                "AniListService: withheld TMDB coordinates tmdbId=\(tmdbShowId); every provider lookup for this show will be skipped",
                type: "Plugin"
            )
        }

        let tmdbHydration: TMDBAbsoluteEpisodeHydration
        if let concurrentlyHydrated = await concurrentHydrationTask {
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
                requiredAbsoluteRange: requiredHydrationRange
            )
        }
        let tmdbEpisodesByAbsolute = tmdbHydration.episodes
        let tmdbCoordinatesByAbsolute = tmdbHydration.coordinates.isEmpty
            ? summaryCoordinatesByAbsolute
            : tmdbHydration.coordinates
        try Task.checkCancellation()
        logDetailTiming(
            "episode-hydration",
            fields: "hydrated=\(tmdbEpisodesByAbsolute.count) concurrent=\(hydratesConcurrently)"
        )

        var seasons: [AniListSeasonWithPoster] = []
        var currentAbsoluteEpisode = 1
        var seasonIndex = 1

        for (currentAnime, _, posterUrl) in allAnimeToProcess {

            let seasonTitle = AniListTitlePicker.title(from: currentAnime.title, preferredLanguageCode: preferredLanguageCode)

            let anilistEpisodeCount = currentAnime.episodes ?? 0

            let totalEpisodesInAnime: Int
            if anilistEpisodeCount > 0 {
                totalEpisodesInAnime = anilistEpisodeCount
                Logger.shared.log("AniListService: Season \(seasonIndex) '\(seasonTitle)' using AniList count: \(totalEpisodesInAnime) episodes", type: "AniList")
            } else {
                let remainingTmdb = max(0, tmdbCoordinatesByAbsolute.count - (currentAbsoluteEpisode - 1))
                totalEpisodesInAnime = remainingTmdb > 0 ? remainingTmdb : 12
                Logger.shared.log("AniListService: Season \(seasonIndex) '\(seasonTitle)' AniList has no count, falling back to: \(totalEpisodesInAnime) episodes", type: "AniList")
            }

            guard RemoteMediaNumericBoundary.episodeCount(totalEpisodesInAnime) != nil else {
                throw NSError(
                    domain: "AniListStructure",
                    code: -5,
                    userInfo: [NSLocalizedDescriptionKey: "Anime season exceeded the supported episode limit."]
                )
            }
            let seasonEpisodes: [AniListEpisode] = (0..<totalEpisodesInAnime).map { offset in
                let absoluteEp = RemoteMediaNumericBoundary.adding(
                    currentAbsoluteEpisode,
                    offset
                ) ?? currentAbsoluteEpisode
                let localEp = offset + 1
                if let tmdbEp = tmdbEpisodesByAbsolute[absoluteEp] {
                    return AniListEpisode(
                        number: localEp,
                        title: tmdbEp.name,
                        description: tmdbEp.overview,
                        seasonNumber: seasonIndex,
                        stillPath: tmdbEp.stillPath,
                        airDate: tmdbEp.airDate,
                        runtime: tmdbEp.runtime,
                        tmdbSeasonNumber: allowsLinearTMDBCoordinates
                            ? tmdbEp.seasonNumber
                            : nil,
                        tmdbEpisodeNumber: allowsLinearTMDBCoordinates
                            ? tmdbEp.episodeNumber
                            : nil
                    )
                } else {
                    let tmdbCoordinate = tmdbCoordinatesByAbsolute[absoluteEp]
                    return AniListEpisode(
                        number: localEp,
                        title: "Episode \(localEp)",
                        description: nil,
                        seasonNumber: seasonIndex,
                        stillPath: nil,
                        airDate: nil,
                        runtime: nil,
                        tmdbSeasonNumber: allowsLinearTMDBCoordinates
                            ? tmdbCoordinate?.seasonNumber
                            : nil,
                        tmdbEpisodeNumber: allowsLinearTMDBCoordinates
                            ? tmdbCoordinate?.episodeNumber
                            : nil
                    )
                }
            }

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
                posterUrl: posterUrl
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
        logDetailTiming(
            "ready",
            fields: "seasons=\(seasons.count) episodes=\(totalEpisodes)"
        )

        try Task.checkCancellation()

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
        "\(tmdbShowId)|\(tmdbMatchCacheLanguage)|\(hydrationPolicy.rawValue)" as NSString
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
        if let cached = specialEntriesCache.object(forKey: cacheKey as NSString),
           Date().timeIntervalSince(cached.timestamp) < specialEntriesCacheTTL {
            return cached.entries
        }
        if let cached = await AnimeSpecialEntriesDiskCache.shared.entries(key: cacheKey) {
            cacheSpecialEntries(
                cached,
                forKey: cacheKey as NSString
            )
            return cached
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
        let existingIds = Set(entries.map(\.id))
        return (entries + malEntries.filter { !existingIds.contains($0.id) })
            .sorted { $0.isOrderedBeforeSpecialEntry($1) }
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
        if let cached = specialEntriesCache.object(forKey: cacheKey as NSString),
           Date().timeIntervalSince(cached.timestamp) < specialEntriesCacheTTL {
            return cached.entries
        }
        if let cached = await AnimeSpecialEntriesDiskCache.shared.entries(key: cacheKey) {
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
            Task(priority: .utility) {
                await AnimeSpecialEntriesDiskCache.shared.store(result.entries, key: cacheKey)
            }
            return result.entries
        }

        if let stale = specialEntriesCache.object(forKey: cacheKey as NSString),
           Date().timeIntervalSince(stale.timestamp) < 24 * 60 * 60 {
            return stale.entries
        }
        if let stale = await AnimeSpecialEntriesDiskCache.shared.entries(
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
        let cacheKey = "mal|\(tmdbShowId)|\(normalizedMALID)|\(tmdbMatchCacheLanguage)|\(fallbackPosterURL ?? "-")"
        if let cached = specialEntriesCache.object(forKey: cacheKey as NSString),
           Date().timeIntervalSince(cached.timestamp) < specialEntriesCacheTTL {
            return cached.entries
        }
        if let cached = await AnimeSpecialEntriesDiskCache.shared.entries(key: cacheKey) {
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
            Task(priority: .utility) {
                await AnimeSpecialEntriesDiskCache.shared.store(entries, key: cacheKey)
            }
            return entries
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if let stale = await AnimeSpecialEntriesDiskCache.shared.entries(
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
        return "\(tmdbShowId)|\(tmdbMatchCacheLanguage)|\(ids)|required:\(requiredIDs)|\(fallbackPosterURL ?? "-")"
    }

    private func fetchSpecialSearchEntriesFromAniList(
        tmdbShowId: Int,
        fallbackPosterURL: String?,
        baseAniListIds: [Int] = [],
        requiredSpecialAniListIds: [Int] = [],
        tmdbService: TMDBService
    ) async -> SpecialEntriesFetchResult {
        let mappingResult = await AniMapMappingService.shared.specialMappingsResult(forTMDBShowId: tmdbShowId)
        let mappings = mappingResult.mappings
        let uniqueMappings = mappings.reduce(into: [Int: AniMapMapping]()) { result, mapping in
            guard let anilistId = mapping.anilistId, result[anilistId] == nil else { return }
            result[anilistId] = mapping
        }

        async let nodeTask = batchFetchAniListStructureNodesResult(ids: Array(uniqueMappings.keys))
        async let relationTask = relationSpecialSearchEntries(
            baseAniListIds: baseAniListIds
                + requiredSpecialAniListIds
                + Array(uniqueMappings.keys),
            tmdbShowId: tmdbShowId,
            fallbackPosterURL: fallbackPosterURL,
            tmdbService: tmdbService,
            excluding: [],
            requiredSpecialIDs: Set(requiredSpecialAniListIds.filter { $0 > 0 })
        )
        let mappedSpecialSeasonNumbers = Set(uniqueMappings.values.compactMap(\.tmdbSeason))
        let specialSeasonNumbers = uniqueMappings.values.contains {
            ($0.tmdbSeason ?? 0) == 0
        } ? mappedSpecialSeasonNumbers.union([0]) : mappedSpecialSeasonNumbers
        async let seasonDetailsTask = fetchSpecialTMDBSeasonDetails(
            tmdbShowId: tmdbShowId,
            seasonNumbers: specialSeasonNumbers,
            tmdbService: tmdbService
        )
        let nodeResult = await nodeTask
        let nodesById = nodeResult.nodes
        let seasonDetailsByNumber = await seasonDetailsTask

        var entries = uniqueMappings.compactMap { element -> AniListSpecialSearchEntry? in
            buildSpecialSearchEntry(
                anilistId: element.key,
                node: nodesById[element.key],
                mapping: element.value,
                fallbackPosterURL: fallbackPosterURL,
                seasonDetailsByNumber: seasonDetailsByNumber
            )
        }

        let relationResult = await relationTask
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

        guard let episodeCount = RemoteMediaNumericBoundary.episodeCount(
            max(1, node?.episodes ?? 1)
        ) else { return nil }
        let mappedSeason = mapping?.tmdbSeason
        let tmdbSeasonDetail = seasonDetailsByNumber[mappedSeason ?? 0]
        let exactTMDBEpisodes = AnimeSpecialEpisodeHydrationPolicy.exactEpisodes(
            episodeCount: episodeCount,
            exactReleaseDate: node?.startDate?.exactDateString,
            mappedSeasonNumber: mappedSeason,
            seasonDetailsByNumber: seasonDetailsByNumber
        )
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
            posterUrl: node?.coverImage?.large
                ?? node?.coverImage?.medium
                ?? tmdbSeasonDetail?.fullPosterURL
                ?? fallbackPosterURL,
            tmdbSeasonNumber: mapping?.tmdbSeason,
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
        requiredSpecialIDs: Set<Int> = []
    ) async -> SpecialEntriesFetchResult {
        let baseIds = Array(Set(baseAniListIds)).filter { $0 > 0 }
        guard !baseIds.isEmpty else {
            return SpecialEntriesFetchResult(entries: [], isComplete: true)
        }

        let baseNodeResult = await batchFetchAniListRelationSeedNodesResult(ids: baseIds)
        let baseNodes = baseNodeResult.nodes
        var candidates: [Int: AniListAnime] = [:]

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
                        fallbackMediaType: candidates[id]?.format
                    )
            }) {
                regularStoryIDs.insert(id)
                continue
            }
            mappingsByID[id] = mappings.first { mapping in
                let matchesShow = mapping.tmdbShowId == nil || mapping.tmdbShowId == tmdbShowId
                return matchesShow && AniMapStructuralRole.isDetachedSpecial(
                    mapping,
                    fallbackMediaType: candidates[id]?.format
                )
            }
        }

        let detachedCandidateIDs = candidates.keys.filter {
            !regularStoryIDs.contains($0)
        }
        let mappedSeasonNumbers = Set(mappingsByID.values.compactMap(\.tmdbSeason))
        let seasonNumbers = detachedCandidateIDs.contains {
            (mappingsByID[$0]?.tmdbSeason ?? 0) == 0
        } ? mappedSeasonNumbers.union([0]) : mappedSeasonNumbers
        let seasonDetailsByNumber = await fetchSpecialTMDBSeasonDetails(
            tmdbShowId: tmdbShowId,
            seasonNumbers: seasonNumbers,
            tmdbService: tmdbService
        )
        return SpecialEntriesFetchResult(
            entries: candidates.compactMap { id, node in
                guard !regularStoryIDs.contains(id) else { return nil }
                return buildSpecialSearchEntry(
                    anilistId: id,
                    node: node,
                    mapping: mappingsByID[id],
                    fallbackPosterURL: fallbackPosterURL,
                    seasonDetailsByNumber: seasonDetailsByNumber
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

                    for candidate in titleCandidates where !candidate.isEmpty {
                        guard let results = try? await tmdbService.searchTVShows(query: candidate), !results.isEmpty else { continue }
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
        tmdbService: TMDBService
    ) async -> [Int: TMDBSearchResult] {
        let uniqueIds = Array(Set(ids))
        guard !uniqueIds.isEmpty else { return [:] }

        let nodes = await batchFetchAniListImportNodes(ids: uniqueIds)
        return await batchMapAniListToTMDB(Array(nodes.values), tmdbService: tmdbService)
    }

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

    private func executeGraphQLQuery(_ query: String, token: String?, maxRetries: Int = 3) async throws -> Data {
        let isDetailReadyPath = AniListRequestContext.isDetailReadyPath
        let rateLimitDeadline = isDetailReadyPath
            ? Date().addingTimeInterval(2.5)
            : nil
        var request = URLRequest(url: graphQLEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = isDetailReadyPath ? 8 : 30

        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = ["query": query]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var lastError: Error?
        let effectiveMaxRetries = isDetailReadyPath ? 1 : maxRetries
        for attempt in 0..<effectiveMaxRetries {

            try await AniListRateLimiter.shared.waitForSlot(deadline: rateLimitDeadline)

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.boundedData(
                    for: request,
                    maximumResponseBytes: RemoteMediaNumericBoundary.maximumMetadataResponseBytes
                )
            } catch {
                lastError = error
                if attempt < effectiveMaxRetries - 1, shouldRetryAniListTransportError(error) {
                    let delay = min(Double(attempt + 1) * 1.5, 5)
                    Logger.shared.log("AniList transport error, retry \(attempt + 1)/\(effectiveMaxRetries) after \(delay)s: \(error.localizedDescription)", type: "AniList")
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

        let uniqueIds = Array(Set(ids)).sorted()
        let chunkSize = 20
        var result: [Int: AniListAnime] = [:]
        var start = 0

        while start < uniqueIds.count {
            let chunk = Array(uniqueIds[start..<min(start + chunkSize, uniqueIds.count)])
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
        guard let normalizedId = RemoteMediaNumericBoundary.positiveMagnitude(malId) else {
            return []
        }

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
    let number: Int
    let title: String
    let description: String?
    let seasonNumber: Int
    let stillPath: String?
    let airDate: String?
    let runtime: Int?
    let tmdbSeasonNumber: Int?
    let tmdbEpisodeNumber: Int?
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
    let seasonYear: Int?
    let season: String?
    let coverImage: AniListCoverImage?
    let format: String?
    let type: String?
    let nextAiringEpisode: AniListNextAiringEpisode?
    let relations: AniListRelations?

    private enum CodingKeys: String, CodingKey {
        case id, idMal, externalLinks, averageScore, isAdult, genres, tags, title
        case episodes, status, startDate, seasonYear, season, coverImage, format, type
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
        let seasonYear: Int?
        let season: String?
        let format: String?
        let type: String?
        let coverImage: AniListCoverImage?
        let relations: AniListRelations?

        private enum CodingKeys: String, CodingKey {
            case id, idMal, externalLinks, averageScore, isAdult, genres, tags, title
            case episodes, status, startDate, seasonYear, season, format, type, coverImage
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
        tmdbShowPoster: String?,
        rootMALId: Int? = nil,
        hydrationPolicy: AnimeEpisodeHydrationPolicy = .complete,
        knownTMDBShowDetail: TMDBTVShowWithSeasons? = nil
    ) async throws -> AniListAnimeWithSeasons {
        async let structuralMappingsTask = AniMapMappingService.shared.mappings(
            forTMDBShowId: tmdbShowId
        )
        let tvShowDetail: TMDBTVShowWithSeasons?
        if let knownTMDBShowDetail {
            tvShowDetail = knownTMDBShowDetail
        } else {
            tvShowDetail = try? await tmdbService.getTVShowWithSeasons(id: tmdbShowId)
        }
        let root: MALAnimeDetails
        if let rootMALId {
            guard let validatedRootID = RemoteMediaNumericBoundary.positiveIdentifier(rootMALId) else {
                throw NSError(domain: "MALMetadata", code: -4, userInfo: [NSLocalizedDescriptionKey: "MAL root identifier is outside the supported range."])
            }
            root = try await fetchAnimeDetails(id: validatedRootID)
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
        let structuralMappings = await structuralMappingsTask

        var collected: [MALAnimeDetails] = []
        var queue: [MALAnimeDetails] = [root]
        var seen = Set<Int>([root.id])
        let rootIsDetachedSpecial = isDetachedSpecial(
            root,
            mappings: structuralMappings
        )

        func append(_ detail: MALAnimeDetails) {
            collected.append(detail)
        }
        if !rootIsDetachedSpecial {
            append(root)
        }

        while !queue.isEmpty && collected.count < 12 {
            let level = queue
            queue = []
            var relationIDs: [Int] = []
            for current in level {
                for relation in current.relatedAnime ?? [] where
                    isNormalSeasonRelation(relation.relationType)
                    || structuralMappings.contains(where: { mapping in
                        mapping.malId == relation.node.id
                            && AniMapStructuralRole.isRegularStory(mapping)
                    }) {
                    if seen.insert(relation.node.id).inserted {
                        relationIDs.append(relation.node.id)
                    }
                }
            }
            let remaining = max(0, 12 - collected.count)
            let fetchedDetails = await withTaskGroup(of: MALAnimeDetails?.self) { group in
                for id in relationIDs.prefix(remaining) {
                    group.addTask { [self] in
                        try? await fetchAnimeDetails(id: id)
                    }
                }
                var values: [MALAnimeDetails] = []
                for await detail in group {
                    if let detail { values.append(detail) }
                }
                return values
            }
            let details = fetchedDetails
                .filter { isNormalSeasonCandidate($0, mappings: structuralMappings) }
                .sorted {
                    (sortableDate(for: $0) ?? "9999-99-99")
                        < (sortableDate(for: $1) ?? "9999-99-99")
                }
            for detail in details {
                append(detail)
                queue.append(detail)
            }
        }

        if let tmdbTotal = tvShowDetail?.numberOfEpisodes,
           let lowerBudget = RemoteMediaNumericBoundary.scaledEpisodeCount(
            tmdbTotal,
            numerator: 3,
            denominator: 4
           ),
           let upperBudget = RemoteMediaNumericBoundary.scaledEpisodeCount(
            tmdbTotal,
            numerator: 5,
            denominator: 4
           ),
           let total = RemoteMediaNumericBoundary.boundedSum(
            collected.map { max($0.numEpisodes ?? 0, 0) }
           ) {
            if hydrationPolicy == .complete,
               rootMALId == nil,
               total < lowerBudget {
                let orphans = await orphanCandidates(
                    root: root,
                    title: title,
                    tmdbShow: tvShowDetail,
                    structuralMappings: structuralMappings
                )
                for orphan in orphans where !seen.contains(orphan.id) && collected.count < 12 {
                    seen.insert(orphan.id)
                    collected.append(orphan)
                }
            }

            if let newTotal = RemoteMediaNumericBoundary.boundedSum(
                collected.map { max($0.numEpisodes ?? 0, 0) }
            ), newTotal > upperBudget,
               let rootIndex = collected.firstIndex(where: { $0.id == root.id }) {
                collected = pruneMALSeasons(
                    collected,
                    rootIndex: rootIndex,
                    tmdbEpisodeBudget: upperBudget
                )
            }
        }

        collected.sort { lhs, rhs in
            let lhsDate = sortableDate(for: lhs) ?? "9999-99-99"
            let rhsDate = sortableDate(for: rhs) ?? "9999-99-99"
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return lhs.id < rhs.id
        }

        let tmdbHydration = await fetchTMDBEpisodesByAbsolute(
            tmdbShowId: tmdbShowId,
            tvShowDetail: tvShowDetail,
            tmdbService: tmdbService,
            absoluteEpisodeLimit: hydrationPolicy == .initiallyVisible ? 100 : nil
        )
        let tmdbEpisodesByAbsolute = tmdbHydration.episodes
        let tmdbCoordinatesByAbsolute = tmdbHydration.coordinates
        let expectedTMDBSeasonCounts = RemoteMediaNumericBoundary.seasonEpisodeCounts(
            (tvShowDetail?.seasons ?? []).compactMap { season in
                guard season.seasonNumber > 0, season.episodeCount > 0 else { return nil }
                return (season.seasonNumber, season.episodeCount)
            }
        ) ?? [:]
        let coordinateCoverageSegments = collected.map { detail in
            let mapping = structuralMappings.first { mapping in
                mapping.malId == detail.id
                    && (mapping.tmdbShowId == nil || mapping.tmdbShowId == tmdbShowId)
                    && AniMapStructuralRole.isRegularStory(
                        mapping,
                        fallbackMediaType: aniListFormat(from: detail.mediaType)
                    )
            }
            return AnimeStructureCoverageSegment(
                mappedTMDBSeason: mapping?.tmdbSeason.flatMap { $0 > 0 ? $0 : nil },
                episodeCount: detail.numEpisodes
            )
        }
        let hasExactTMDBCoordinateCoverage = AnimeStructurePolicy.hasExactCoverage(
            tmdbSeasonEpisodeCounts: expectedTMDBSeasonCounts,
            segments: coordinateCoverageSegments
        )
        let hasMatchingTMDBEpisodeTotals = AnimeStructurePolicy.hasMatchingEpisodeTotals(
            tmdbSeasonEpisodeCounts: expectedTMDBSeasonCounts,
            segments: coordinateCoverageSegments
        )
        let allowsLinearTMDBCoordinates = AnimeStructurePolicy.allowsLinearTMDBCoordinates(
            hydrationPolicy: hydrationPolicy,
            hasExactCoverage: hasExactTMDBCoordinateCoverage,
            hasMatchingEpisodeTotals: hasMatchingTMDBEpisodeTotals
        )
        if !allowsLinearTMDBCoordinates {
            Logger.shared.log(
                "MALMetadata: withheld TMDB coordinates tmdbId=\(tmdbShowId); every provider lookup for this show will be skipped",
                type: "Plugin"
            )
        }
        var currentAbsoluteEpisode = 1
        var seasonNumber = 1
        var seasons: [AniListSeasonWithPoster] = []

        for detail in collected {
            let structuralMapping = structuralMappings.first { mapping in
                mapping.malId == detail.id
                    && (mapping.tmdbShowId == nil || mapping.tmdbShowId == tmdbShowId)
                    && AniMapStructuralRole.isRegularStory(
                        mapping,
                        fallbackMediaType: aniListFormat(from: detail.mediaType)
                    )
            }
            let episodeCount = resolvedEpisodeCount(
                for: detail,
                currentAbsoluteEpisode: currentAbsoluteEpisode,
                tmdbEpisodesByAbsolute: tmdbEpisodesByAbsolute,
                knownTMDBEpisodeCount: tmdbCoordinatesByAbsolute.count
            )
            guard RemoteMediaNumericBoundary.episodeCount(episodeCount) != nil else {
                throw NSError(
                    domain: "MALMetadata",
                    code: -5,
                    userInfo: [NSLocalizedDescriptionKey: "MAL season exceeded the supported episode limit."]
                )
            }
            let seasonTitle = displayTitle(for: detail)
            let episodes = (0..<episodeCount).map { offset -> AniListEpisode in
                let absolute = RemoteMediaNumericBoundary.adding(
                    currentAbsoluteEpisode,
                    offset
                ) ?? currentAbsoluteEpisode
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
                        tmdbSeasonNumber: allowsLinearTMDBCoordinates
                            ? tmdbEpisode.seasonNumber
                            : nil,
                        tmdbEpisodeNumber: allowsLinearTMDBCoordinates
                            ? tmdbEpisode.episodeNumber
                            : nil
                    )
                }
                let coordinate = tmdbCoordinatesByAbsolute[absolute]
                return AniListEpisode(
                    number: local,
                    title: "Episode \(local)",
                    description: nil,
                    seasonNumber: seasonNumber,
                    stillPath: nil,
                    airDate: nil,
                    runtime: nil,
                    tmdbSeasonNumber: allowsLinearTMDBCoordinates
                        ? coordinate?.season
                        : nil,
                    tmdbEpisodeNumber: allowsLinearTMDBCoordinates
                        ? coordinate?.episode
                        : nil
                )
            }

            seasons.append(AniListSeasonWithPoster(
                seasonNumber: seasonNumber,
                anilistId: malProviderId(detail.id),
                canonicalAniListId: structuralMapping?.anilistId,
                malId: detail.id,
                kitsuId: structuralMapping?.kitsuId,
                title: seasonTitle,
                englishTitle: detail.alternativeTitles?.en,
                romajiTitle: detail.title,
                nativeTitle: detail.alternativeTitles?.ja,
                episodes: episodes,
                posterUrl: detail.mainPicture?.large ?? detail.mainPicture?.medium ?? tmdbShowPoster
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
        guard let show = try? await tmdbService.getTVShowWithSeasons(id: tmdbShowId),
              let candidates = try? await searchCandidates(title: show.name, tmdbShowId: tmdbShowId, tmdbShow: show, tmdbService: tmdbService),
              let root = candidates.first else {
            return []
        }

        let related = root.relatedAnime ?? []
        let seasonDetails = await fetchSpecialTMDBSeasonDetails(
            tmdbShowId: tmdbShowId,
            seasonNumbers: [0]
        )
        var results: [AniListSpecialSearchEntry] = []
        for relation in related where isSpecialRelation(relation.relationType) {
            guard let detail = try? await fetchAnimeDetails(id: relation.node.id), isSpecialCandidate(detail) else { continue }
            results.append(buildSpecialSearchEntry(
                detail: detail,
                mapping: nil,
                fallbackPosterURL: fallbackPosterURL,
                seasonDetailsByNumber: seasonDetails
            ))
        }
        return results.sorted { $0.isOrderedBeforeSpecialEntry($1) }
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
        async let rootTask = fetchAnimeDetails(id: normalizedRootID)
        async let structuralMappingsTask = AniMapMappingService.shared.mappings(
            forTMDBShowId: tmdbShowId
        )
        let root = try await rootTask
        let structuralMappings = await structuralMappingsTask
        try Task.checkCancellation()
        let relationIDs = (root.relatedAnime ?? [])
            .filter { relation in
                isSpecialRelation(relation.relationType)
                    || structuralMappings.contains(where: { mapping in
                        mapping.malId == relation.node.id
                            && AniMapStructuralRole.isDetachedSpecial(mapping)
                    })
            }
            .map(\.node.id)

        var details = try await withThrowingTaskGroup(of: MALAnimeDetails?.self) { group in
            for id in relationIDs {
                group.addTask { [self] in
                    try Task.checkCancellation()
                    let detail = try await fetchAnimeDetails(id: id)
                    try Task.checkCancellation()
                    return detail
                }
            }
            var values: [MALAnimeDetails] = []
            for try await detail in group {
                if let detail { values.append(detail) }
            }
            return values
        }

        details = details.filter {
            isDetachedSpecialCandidate($0, mappings: structuralMappings)
        }
        if isDetachedSpecial(root, mappings: structuralMappings) {
            details.append(root)
        }
        var seen = Set<Int>()
        details = details.filter { seen.insert($0.id).inserted }
        let mappingByMALID = Dictionary(uniqueKeysWithValues: details.compactMap { detail in
            let mapping = structuralMappings.first { mapping in
                mapping.malId == detail.id
                    && (mapping.tmdbShowId == nil || mapping.tmdbShowId == tmdbShowId)
                    && AniMapStructuralRole.isDetachedSpecial(
                        mapping,
                        fallbackMediaType: aniListFormat(from: detail.mediaType)
                    )
            }
            return mapping.map { (detail.id, $0) }
        })
        let mappedSeasonNumbers = Set(mappingByMALID.values.compactMap(\.tmdbSeason))
        let seasonNumbers = details.contains {
            (mappingByMALID[$0.id]?.tmdbSeason ?? 0) == 0
        } ? mappedSeasonNumbers.union([0]) : mappedSeasonNumbers
        let seasonDetails = await fetchSpecialTMDBSeasonDetails(
            tmdbShowId: tmdbShowId,
            seasonNumbers: seasonNumbers
        )

        return details.map { detail in
            buildSpecialSearchEntry(
                detail: detail,
                mapping: mappingByMALID[detail.id],
                fallbackPosterURL: fallbackPosterURL,
                seasonDetailsByNumber: seasonDetails
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

    private func buildSpecialSearchEntry(
        detail: MALAnimeDetails,
        mapping: AniMapMapping?,
        fallbackPosterURL: String?,
        seasonDetailsByNumber: [Int: TMDBSeasonDetail]
    ) -> AniListSpecialSearchEntry {
        let episodeCount = RemoteMediaNumericBoundary.episodeCount(
            max(detail.numEpisodes ?? 1, 1)
        ) ?? 1
        let title = displayTitle(for: detail)
        let mappedSeason = mapping?.tmdbSeason
        let tmdbSeasonDetail = seasonDetailsByNumber[mappedSeason ?? 0]
        let exactTMDBEpisodes = AnimeSpecialEpisodeHydrationPolicy.exactEpisodes(
            episodeCount: episodeCount,
            exactReleaseDate: detail.startDate,
            mappedSeasonNumber: mappedSeason,
            seasonDetailsByNumber: seasonDetailsByNumber
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
            posterUrl: detail.mainPicture?.large
                ?? detail.mainPicture?.medium
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

    private func orphanCandidates(
        root: MALAnimeDetails,
        title: String,
        tmdbShow: TMDBTVShowWithSeasons?,
        structuralMappings: [AniMapMapping]
    ) async -> [MALAnimeDetails] {
        let rootKey = normalized(displayTitle(for: root))
        let rootPrefix = String(rootKey.prefix(min(rootKey.count, 12)))
        let searchTitles = [title, root.title, root.alternativeTitles?.en].compactMap { $0 }
        var seenIds = Set<Int>([root.id])
        var candidates: [MALAnimeDetails] = []

        for title in searchTitles {
            guard let nodes = try? await searchAnime(query: title, limit: 20) else { continue }
            for node in nodes where seenIds.insert(node.id).inserted {
                guard let detail = try? await fetchAnimeDetails(id: node.id),
                      isNormalSeasonCandidate(detail, mappings: structuralMappings) else { continue }
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
        var request = URLRequest(url: url)
        request.setValue(clientID, forHTTPHeaderField: "X-MAL-CLIENT-ID")
        request.timeoutInterval = AniListRequestContext.isDetailReadyPath ? 8 : 20
        let (data, response) = try await URLSession.shared.boundedData(
            for: request,
            maximumResponseBytes: RemoteMediaNumericBoundary.maximumMetadataResponseBytes
        )
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
                    let seededResult = result?.withAnimeIdentitySeed(identitySeed)
                    return (
                        anime.id,
                        seededResult,
                        AnimeTMDBMatchCacheRecord(key: cacheKey, result: seededResult)
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

    private func fetchTMDBEpisodesByAbsolute(
        tmdbShowId: Int,
        tvShowDetail: TMDBTVShowWithSeasons?,
        tmdbService: TMDBService,
        absoluteEpisodeLimit: Int? = nil
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
            var seasonAbsoluteStart = 1
            for summary in seasonSummaries {
                guard let episodes = fetchedEpisodesBySeason[summary.seasonNumber] else {
                    for offset in 0..<summary.episodeCount {
                        guard let absolute = RemoteMediaNumericBoundary.adding(
                            seasonAbsoluteStart,
                            offset
                        ) else { return (episodesByAbsolute, coordinatesByAbsolute) }
                        coordinatesByAbsolute[absolute] = (
                            summary.seasonNumber,
                            offset + 1
                        )
                    }
                    guard let next = RemoteMediaNumericBoundary.adding(
                        seasonAbsoluteStart,
                        summary.episodeCount
                    ) else { return (episodesByAbsolute, coordinatesByAbsolute) }
                    seasonAbsoluteStart = next
                    continue
                }
                guard episodes.count <= RemoteMediaNumericBoundary.maximumEpisodeCount else {
                    return (episodesByAbsolute, coordinatesByAbsolute)
                }
                for (offset, episode) in episodes.enumerated() {
                    guard let absolute = RemoteMediaNumericBoundary.adding(
                        seasonAbsoluteStart,
                        offset
                    ) else { return (episodesByAbsolute, coordinatesByAbsolute) }
                    coordinatesByAbsolute[absolute] = (episode.seasonNumber, episode.episodeNumber)
                    if absoluteEpisodeLimit.map({ absolute <= $0 }) ?? true {
                        episodesByAbsolute[absolute] = episode
                    }
                }
                guard let next = RemoteMediaNumericBoundary.adding(
                    seasonAbsoluteStart,
                    episodes.count
                ) else { return (episodesByAbsolute, coordinatesByAbsolute) }
                seasonAbsoluteStart = next
            }
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

    private func resolvedEpisodeCount(
        for detail: MALAnimeDetails,
        currentAbsoluteEpisode: Int,
        tmdbEpisodesByAbsolute: [Int: TMDBEpisode],
        knownTMDBEpisodeCount: Int
    ) -> Int {
        if let count = detail.numEpisodes, count > 0 { return count }
        let knownCount = max(tmdbEpisodesByAbsolute.count, knownTMDBEpisodeCount)
        guard knownCount <= RemoteMediaNumericBoundary.maximumTotalEpisodeCount,
              currentAbsoluteEpisode > 0,
              let afterCurrent = RemoteMediaNumericBoundary.adding(
                knownCount,
                -currentAbsoluteEpisode
              ), let remaining = RemoteMediaNumericBoundary.adding(afterCurrent, 1) else {
            return 12
        }
        return remaining > 0 ? remaining : 12
    }

    private func isNormalSeasonRelation(_ relationType: String) -> Bool {
        ["sequel", "prequel", "parent_story", "main_story", "full_story"].contains(relationType.lowercased())
    }

    private func isSpecialRelation(_ relationType: String) -> Bool {
        ["side_story", "spin_off", "other", "summary", "alternative_version"].contains(relationType.lowercased())
    }

    private func isNormalSeasonCandidate(
        _ detail: MALAnimeDetails,
        mappings: [AniMapMapping] = []
    ) -> Bool {
        let format = aniListFormat(from: detail.mediaType)
        if let mapping = mappings.first(where: { $0.malId == detail.id }) {
            guard AniMapStructuralRole.isRegularStory(
                mapping,
                fallbackMediaType: format
            ) else { return false }
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
        mappings: [AniMapMapping]
    ) -> Bool {
        let format = aniListFormat(from: detail.mediaType)
        if let mapping = mappings.first(where: { $0.malId == detail.id }) {
            return AniMapStructuralRole.isDetachedSpecial(
                mapping,
                fallbackMediaType: format
            )
        }
        return isSpecialCandidate(detail)
    }

    private func isDetachedSpecial(
        _ detail: MALAnimeDetails,
        mappings: [AniMapMapping]
    ) -> Bool {
        let format = aniListFormat(from: detail.mediaType)
        if let mapping = mappings.first(where: { $0.malId == detail.id }) {
            return AniMapStructuralRole.isDetachedSpecial(
                mapping,
                fallbackMediaType: format
            )
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
        RemoteMediaNumericBoundary.negativeProviderIdentifier(malId) ?? 0
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
