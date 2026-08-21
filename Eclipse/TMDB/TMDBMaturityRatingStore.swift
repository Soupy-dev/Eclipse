import Foundation

final class TMDBMaturityRatingStore: ObservableObject {
    static let shared = TMDBMaturityRatingStore()

    @Published private(set) var revision = 0

    private struct Key: Hashable, Codable {
        let isMovie: Bool
        let id: Int
    }

    private struct CachedVerdict: Codable {
        let rating: MaturityRating
        let resolvedAt: Date
        let regionPolicy: String
        let kidsDetailPolicyAllows: Bool?
    }

    private enum Outcome {
        case resolved(MaturityRating, kidsDetailPolicyAllows: Bool)
        case transient
    }

    private enum Lookup {

        case settled

        case inFlight(Task<Outcome, Never>)
    }

    private struct DiskRecord: Codable {
        let key: Key
        let verdict: CachedVerdict
    }

    private struct DiskCache: Codable {
        static let currentVersion = 3
        var version: Int
        var records: [DiskRecord]
    }

    private let lock = NSLock()
    private var verdicts: [Key: CachedVerdict] = [:]

    private var inFlightTasks: [Key: Task<Outcome, Never>] = [:]

    private var lastTransientFailure: [Key: Date] = [:]
    private var pending: [Key] = []
    private var isDraining = false

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static let cacheLifetime: TimeInterval = 60 * 60 * 24 * 30
    private static let maximumEntries = 4_000

    private static let batchSize = 6

    private static let transientRetryInterval: TimeInterval = 60

    private static let regionPolicy = MaturityRating.preferredRegions.joined(separator: ",")

    private static let cacheURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("TMDBMaturityRatings.json")
    }()

    private init() {
        loadFromDisk()
    }

    func rating(isMovie: Bool, id: Int) -> MaturityRating? {
        withLock { verdicts[Key(isMovie: isMovie, id: id)]?.rating }
    }

    func kidsDetailPolicyAllows(isMovie: Bool, id: Int) -> Bool? {
        withLock { verdicts[Key(isMovie: isMovie, id: id)]?.kidsDetailPolicyAllows }
    }

    func isAllowedForKids(isMovie: Bool, id: Int) -> Bool {
        guard id > 0 else { return false }
        guard let rating = rating(isMovie: isMovie, id: id) else {
            enqueue(Key(isMovie: isMovie, id: id))
            return false
        }

        return !rating.isBlockedForKids
    }

    func resolve(_ titles: [(isMovie: Bool, id: Int)]) async {
        var seen = Set<Key>()
        let keys = titles
            .filter { $0.id > 0 }
            .map { Key(isMovie: $0.isMovie, id: $0.id) }
            .filter { seen.insert($0).inserted }
        guard !keys.isEmpty else { return }

        let missing = withLock { keys.filter { Self.needsResolution(verdicts[$0]) } }
        guard !missing.isEmpty else { return }

        var didResolve = false
        for chunk in stride(from: 0, to: missing.count, by: Self.batchSize).map({
            Array(missing[$0..<min($0 + Self.batchSize, missing.count)])
        }) {

            if Task.isCancelled { break }

            let lookups = chunk.map { lookup($0) }
            for entry in lookups {
                guard case .inFlight(let task) = entry else { continue }
                let outcome = await task.value
                if case .resolved = outcome { didResolve = true }
            }
        }

        guard didResolve else { return }
        persistToDisk()
        await MainActor.run { self.revision &+= 1 }
    }

    private static func needsResolution(_ verdict: CachedVerdict?) -> Bool {
        guard let verdict else { return true }
        return verdict.kidsDetailPolicyAllows == nil
    }

    private func enqueue(_ key: Key) {
        let shouldStart = withLock { () -> Bool in
            guard verdicts[key] == nil, inFlightTasks[key] == nil, !pending.contains(key) else {
                return false
            }
            if let failure = lastTransientFailure[key],
               Date().timeIntervalSince(failure) < Self.transientRetryInterval {
                return false
            }
            pending.append(key)

            guard !isDraining else { return false }
            isDraining = true
            return true
        }

        guard shouldStart else { return }
        Task { await drain() }
    }

    private func lookup(_ key: Key) -> Lookup {
        withLock { () -> Lookup in
            if !Self.needsResolution(verdicts[key]) { return .settled }
            if let existing = inFlightTasks[key] { return .inFlight(existing) }
            if let failure = lastTransientFailure[key],
               Date().timeIntervalSince(failure) < Self.transientRetryInterval {
                return .settled
            }
            let task = Task<Outcome, Never> { [weak self] in
                let outcome = await Self.fetchVerdict(key)
                self?.finish(key, outcome: outcome)
                return outcome
            }
            inFlightTasks[key] = task
            return .inFlight(task)
        }
    }

    private func finish(_ key: Key, outcome: Outcome) {
        let now = Date()
        let policy = Self.regionPolicy
        withLock {
            inFlightTasks[key] = nil
            switch outcome {
            case .resolved(let rating, let detailPolicyAllows):
                verdicts[key] = CachedVerdict(
                    rating: rating,
                    resolvedAt: now,
                    regionPolicy: policy,
                    kidsDetailPolicyAllows: detailPolicyAllows
                )
                lastTransientFailure[key] = nil
            case .transient:
                lastTransientFailure = lastTransientFailure.filter {
                    now.timeIntervalSince($0.value) < Self.transientRetryInterval
                }
                lastTransientFailure[key] = now
            }
        }
    }

    private func drain() async {
        while true {
            let nextBatch = withLock { () -> [Key]? in
                guard !pending.isEmpty else {
                    isDraining = false
                    return nil
                }
                let batch = Array(pending.prefix(Self.batchSize))
                pending.removeFirst(batch.count)
                return batch
            }
            guard let batch = nextBatch else { return }

            var didResolve = false
            let lookups = batch.map { lookup($0) }
            for entry in lookups {
                guard case .inFlight(let task) = entry else { continue }
                let outcome = await task.value
                if case .resolved = outcome { didResolve = true }
            }

            guard didResolve else { continue }
            persistToDisk()
            await MainActor.run { self.revision &+= 1 }
        }
    }

    private static func fetchVerdict(_ key: Key) async -> Outcome {
        let service = TMDBService.shared
        do {
            if key.isMovie {
                let detail = try await service.getMovieDetails(id: key.id)

                let detailPolicyAllows = TMDBContentFilter.kidsDetailPolicyAllows(
                    title: "",
                    isAdult: detail.adult,
                    genreIds: detail.genres.map(\.id),
                    overview: detail.overview
                )

                guard let releaseDates = detail.releaseDates else {
                    return .resolved(.unknown, kidsDetailPolicyAllows: detailPolicyAllows)
                }
                var byRegion: [String: [String]] = [:]
                for result in releaseDates.results {
                    let certifications = result.releaseDates
                        .map(\.certification)
                        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    guard !certifications.isEmpty else { continue }
                    byRegion[result.iso31661, default: []].append(contentsOf: certifications)
                }
                return .resolved(
                    MaturityRating.classify(certificationsByRegion: byRegion),
                    kidsDetailPolicyAllows: detailPolicyAllows
                )
            }

            let detail = try await service.getTVShowDetails(id: key.id)
            let detailPolicyAllows = TMDBContentFilter.kidsDetailPolicyAllows(
                title: "",
                isAdult: detail.adult,
                genreIds: detail.genres.map(\.id),
                overview: detail.overview
            )
            guard let contentRatings = detail.contentRatings else {
                return .resolved(.unknown, kidsDetailPolicyAllows: detailPolicyAllows)
            }
            var byRegion: [String: [String]] = [:]
            for result in contentRatings.results
            where !result.rating.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                byRegion[result.iso31661, default: []].append(result.rating)
            }
            return .resolved(
                MaturityRating.classify(certificationsByRegion: byRegion),
                kidsDetailPolicyAllows: detailPolicyAllows
            )
        } catch {

            Logger.shared.log(
                "TMDBMaturityRatingStore: refused to cache unresolved verdict for \(key.isMovie ? "movie" : "tv")/\(key.id): \(error.localizedDescription)",
                type: "TMDB"
            )
            return .transient
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let cache = try? JSONDecoder().decode(DiskCache.self, from: data),
              cache.version == DiskCache.currentVersion else {
            return
        }
        let cutoff = Date().addingTimeInterval(-Self.cacheLifetime)
        let policy = Self.regionPolicy
        withLock {

            for record in cache.records
            where record.verdict.resolvedAt > cutoff && record.verdict.regionPolicy == policy {
                verdicts[record.key] = record.verdict
            }
        }
    }

    private func persistToDisk() {
        let snapshot = withLock { verdicts }

        let records = snapshot
            .sorted { $0.value.resolvedAt < $1.value.resolvedAt }
            .suffix(Self.maximumEntries)
            .map { DiskRecord(key: $0.key, verdict: $0.value) }
        let cache = DiskCache(version: DiskCache.currentVersion, records: records)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: Self.cacheURL, options: .atomic)
    }
}
