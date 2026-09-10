import Foundation

struct RecommendationCacheOwner: Equatable {
    let profileID: UUID
    let generation: UUID
}

final class RecommendationEngine {
    static let shared = RecommendationEngine()
    static let maximumPersistedCacheBytes = 4 * 1_024 * 1_024
    static let maximumCachedResults = 100
    private convenience init() {
        Self.migrateLegacyCachesIfNeeded()
        self.init(
            profileID: ProfileManager.shared.activeProfileID,
            cacheDirectory: Self.documentsDirectory
        )
    }

    init(profileID: UUID, cacheDirectory: URL) {
        activeProfileID = profileID
        self.cacheDirectory = cacheDirectory
        cacheGenerations[profileID] = UUID()
        let forYou = Self.loadFromDisk(fileURL: fileURL(for: activeProfileID))
        cachedRecommendations = forYou.results
        cacheDate = forYou.date

        let byw = Self.loadBYWFromDisk(fileURL: bywFileURL(for: activeProfileID))
        becauseYouWatchedTitle = byw.title
        becauseYouWatchedResults = byw.results
        becauseYouWatchedCacheDate = byw.date
    }

    private var activeProfileID: UUID
    private let cacheDirectory: URL
    private let stateLock = NSRecursiveLock()
    private var cacheGenerations: [UUID: UUID] = [:]

    private func withStateLock<T>(_ operation: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return operation()
    }

    func captureCacheOwner() -> RecommendationCacheOwner {
        withStateLock {
            let generation = cacheGenerations[activeProfileID] ?? UUID()
            cacheGenerations[activeProfileID] = generation
            return RecommendationCacheOwner(profileID: activeProfileID, generation: generation)
        }
    }

    func switchProfile(to profileID: UUID) {
        withStateLock {
            guard profileID != activeProfileID else { return }
            flushPendingWrites(forProfile: activeProfileID)
            activeProfileID = profileID
            cacheGenerations[profileID] = UUID()

            let forYou = Self.loadFromDisk(fileURL: fileURL(for: profileID))
            cachedRecommendations = forYou.results
            cacheDate = forYou.date

            let byw = Self.loadBYWFromDisk(fileURL: bywFileURL(for: profileID))
            becauseYouWatchedTitle = byw.title
            becauseYouWatchedResults = byw.results
            becauseYouWatchedCacheDate = byw.date
        }
    }

    func flushPendingWrites(forProfile outgoing: UUID) {
        withStateLock {
            guard outgoing == activeProfileID else { return }
            saveToDisk(forProfile: outgoing)
            saveBYWToDisk(forProfile: outgoing)
        }
    }

    func discardStore(forProfile profileID: UUID) {
        discardCaches(forProfile: profileID)
    }

    func discardCaches(forProfile profileID: UUID) {
        withStateLock {
            cacheGenerations.removeValue(forKey: profileID)
            try? FileManager.default.removeItem(at: fileURL(for: profileID))
            try? FileManager.default.removeItem(at: bywFileURL(for: profileID))
            if profileID == activeProfileID {
                invalidateCache()
            }
        }
    }

    private var cachedRecommendations: [TMDBSearchResult] = []
    private var cacheDate: Date?
    private let cacheTTL: TimeInterval = 21600

    private var becauseYouWatchedTitle: String = ""
    private var becauseYouWatchedResults: [TMDBSearchResult] = []
    private var becauseYouWatchedCacheDate: Date?

    private struct ForYouCache: Codable {
        let results: [TMDBSearchResult]
        let date: Date
    }

    private struct BecauseYouWatchedDiskCache: Codable {
        let title: String
        let results: [TMDBSearchResult]
        let date: Date
    }

    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func fileURL(for profileID: UUID) -> URL {
        cacheDirectory.appendingPathComponent(
            ProfileScopedStorage.documentFileName(
                base: "RecommendationCache",
                fileExtension: "json",
                profileID: profileID
            )
        )
    }

    private static func migrateLegacyCachesIfNeeded() {
        ProfileScopedStorage.migrateLegacyStoreIfNeeded(marker: "recommendations") {
            let fileManager = FileManager.default
            for name in ["RecommendationCache.json", "BecauseYouWatchedCache.json"] {
                try? fileManager.removeItem(at: documentsDirectory.appendingPathComponent(name))
            }
        }
    }

    private func bywFileURL(for profileID: UUID) -> URL {
        cacheDirectory.appendingPathComponent(
            ProfileScopedStorage.documentFileName(
                base: "BecauseYouWatchedCache",
                fileExtension: "json",
                profileID: profileID
            )
        )
    }

    func generateRecommendations(
        catalogResults: [String: [TMDBSearchResult]],
        tmdbService: TMDBService
    ) async -> [TMDBSearchResult] {

        let capture = await MainActor.run {
            withStateLock { () -> (owner: RecommendationCacheOwner, cached: [TMDBSearchResult]?, profile: TasteProfile?) in
                let owner = captureCacheOwner()
                if let cacheDate, Date().timeIntervalSince(cacheDate) < cacheTTL, !cachedRecommendations.isEmpty {
                    return (owner, cachedRecommendations, nil)
                }
                return (owner, nil, buildTasteProfile())
            }
        }
        if let cached = capture.cached { return cached }
        guard let profile = capture.profile else { return [] }

        guard !profile.genreWeights.isEmpty || !profile.topWatchedMovieIds.isEmpty || !profile.topWatchedShowIds.isEmpty else { return [] }

        var candidateScores: [String: (result: TMDBSearchResult, score: Double)] = [:]
        let watchedIds = profile.watchedIds
        let bookmarkedIds = profile.bookmarkedIds

        for (_, results) in catalogResults {
            for item in results {

                guard !watchedIds.contains(item.stableIdentity), !bookmarkedIds.contains(item.stableIdentity) else { continue }
                guard candidateScores[item.stableIdentity] == nil else { continue }

                let score = scoreItem(item, profile: profile)
                if score > 0 {
                    candidateScores[item.stableIdentity] = (item, score)
                }
            }
        }

        let tmdbRecs = await fetchTMDBRecommendations(profile: profile, tmdbService: tmdbService)
        for item in tmdbRecs {
            guard !watchedIds.contains(item.stableIdentity), !bookmarkedIds.contains(item.stableIdentity) else { continue }
            if let existing = candidateScores[item.stableIdentity] {

                candidateScores[item.stableIdentity] = (existing.result, existing.score * 1.5)
            } else {
                let score = scoreItem(item, profile: profile)
                candidateScores[item.stableIdentity] = (item, max(score, 0.1))
            }
        }

        let ranked = candidateScores.values
            .sorted { $0.score > $1.score }
            .prefix(20)
            .map { $0.result }

        let results = Array(ranked)
        storeGeneratedRecommendations(results, for: capture.owner)
        return results
    }

    func invalidateCache() {
        withStateLock {
            cacheGenerations[activeProfileID] = UUID()
            cachedRecommendations = []
            cacheDate = nil
            becauseYouWatchedResults = []
            becauseYouWatchedTitle = ""
            becauseYouWatchedCacheDate = nil
            try? FileManager.default.removeItem(at: fileURL(for: activeProfileID))
            try? FileManager.default.removeItem(at: bywFileURL(for: activeProfileID))
        }
    }

    func generateBecauseYouWatched(
        tmdbService: TMDBService
    ) async -> (title: String, results: [TMDBSearchResult]) {

        let capture = await MainActor.run {
            withStateLock { () -> (owner: RecommendationCacheOwner, cached: (String, [TMDBSearchResult])?, progress: ProgressData?) in
                let owner = captureCacheOwner()
                if let cacheDate = becauseYouWatchedCacheDate,
                   Date().timeIntervalSince(cacheDate) < cacheTTL,
                   !becauseYouWatchedResults.isEmpty {
                    return (owner, (becauseYouWatchedTitle, becauseYouWatchedResults), nil)
                }
                return (owner, nil, ProgressManager.shared.getProgressData())
            }
        }
        if let cached = capture.cached { return cached }
        guard let progressData = capture.progress else { return ("", []) }

        let movieCandidates = progressData.movieProgress
            .filter { $0.progress >= 0.3 }
            .sorted { $0.lastUpdated > $1.lastUpdated }

        var showLastWatched: [Int: Date] = [:]
        for ep in progressData.episodeProgress where ep.progress >= 0.3 {
            if let existing = showLastWatched[ep.showId] {
                showLastWatched[ep.showId] = max(existing, ep.lastUpdated)
            } else {
                showLastWatched[ep.showId] = ep.lastUpdated
            }
        }

        struct Candidate {
            let id: Int
            let title: String
            let isMovie: Bool
            let date: Date
        }

        var candidates: [Candidate] = movieCandidates.map {
            Candidate(id: $0.id, title: $0.title, isMovie: true, date: $0.lastUpdated)
        }
        for (showId, date) in showLastWatched {
            let title = progressData.getShowMetadata(showId: showId)?.title ?? ""
            if !title.isEmpty {
                candidates.append(Candidate(id: showId, title: title, isMovie: false, date: date))
            }
        }

        candidates.sort { $0.date > $1.date }
        let topCandidates = Array(candidates.prefix(5))
        guard let pick = topCandidates.randomElement() else { return ("", []) }

        var recs: [TMDBSearchResult] = []
        if pick.isMovie {
            if let movies = try? await tmdbService.getMovieRecommendations(id: pick.id) {
                recs = movies.prefix(15).map { movie in
                    TMDBSearchResult(
                        id: movie.id, mediaType: "movie", title: movie.title, name: nil,
                        overview: movie.overview, posterPath: movie.posterPath,
                        backdropPath: movie.backdropPath, releaseDate: movie.releaseDate,
                        firstAirDate: nil, voteAverage: movie.voteAverage,
                        popularity: movie.popularity, adult: movie.adult, genreIds: movie.genreIds
                    )
                }
            }
        } else {
            if let shows = try? await tmdbService.getTVRecommendations(id: pick.id) {
                recs = shows.prefix(15).map { show in
                    TMDBSearchResult(
                        id: show.id, mediaType: "tv", title: nil, name: show.name,
                        overview: show.overview, posterPath: show.posterPath,
                        backdropPath: show.backdropPath, releaseDate: nil,
                        firstAirDate: show.firstAirDate, voteAverage: show.voteAverage,
                        popularity: show.popularity, adult: show.adult, genreIds: show.genreIds
                    )
                }
            }
        }

        let watchedIds = Set(progressData.movieProgress.map { "movie-\($0.id)" } +
                            showLastWatched.keys.map { "tv-\($0)" })
        recs = recs.filter { !watchedIds.contains($0.stableIdentity) }

        storeGeneratedBecauseYouWatched(title: pick.title, results: recs, for: capture.owner)
        return (pick.title, recs)
    }

    func storeGeneratedRecommendations(_ results: [TMDBSearchResult], for owner: RecommendationCacheOwner) {
        withStateLock {
            guard cacheGenerations[owner.profileID] == owner.generation else { return }
            let cache = ForYouCache(results: Self.sanitizedResults(results), date: Date())
            if owner.profileID == activeProfileID {
                cachedRecommendations = cache.results
                cacheDate = cache.date
            }
            guard !cache.results.isEmpty,
                  let data = try? JSONEncoder().encode(cache),
                  data.count <= Self.maximumPersistedCacheBytes else { return }
            try? data.write(to: fileURL(for: owner.profileID), options: .atomic)
        }
    }

    func storeGeneratedBecauseYouWatched(title: String, results: [TMDBSearchResult], for owner: RecommendationCacheOwner) {
        withStateLock {
            guard cacheGenerations[owner.profileID] == owner.generation else { return }
            let cache = BecauseYouWatchedDiskCache(title: title, results: Self.sanitizedResults(results), date: Date())
            if owner.profileID == activeProfileID {
                becauseYouWatchedTitle = cache.title
                becauseYouWatchedResults = cache.results
                becauseYouWatchedCacheDate = cache.date
            }
            guard !cache.results.isEmpty,
                  let data = try? JSONEncoder().encode(cache),
                  data.count <= Self.maximumPersistedCacheBytes else { return }
            try? data.write(to: bywFileURL(for: owner.profileID), options: .atomic)
        }
    }

    private func saveToDisk(forProfile profileID: UUID) {
        guard !cachedRecommendations.isEmpty, let cacheDate else { return }
        do {
            let cache = ForYouCache(
                results: Self.sanitizedResults(cachedRecommendations),
                date: cacheDate
            )
            let data = try JSONEncoder().encode(cache)
            guard data.count <= Self.maximumPersistedCacheBytes else { return }
            try data.write(to: fileURL(for: profileID), options: .atomic)
        } catch { }
    }

    private static func loadFromDisk(fileURL: URL) -> (results: [TMDBSearchResult], date: Date?) {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? BoundedLocalStoreReader.read(
                from: fileURL,
                maximumBytes: maximumPersistedCacheBytes
              ),
              let cache = try? JSONDecoder().decode(ForYouCache.self, from: data) else {
            return ([], nil)
        }
        return (sanitizedResults(cache.results), cache.date)
    }

    private func saveBYWToDisk(forProfile profileID: UUID) {
        guard !becauseYouWatchedResults.isEmpty, let becauseYouWatchedCacheDate else { return }
        do {
            let cache = BecauseYouWatchedDiskCache(
                title: becauseYouWatchedTitle,
                results: Self.sanitizedResults(becauseYouWatchedResults),
                date: becauseYouWatchedCacheDate
            )
            let data = try JSONEncoder().encode(cache)
            guard data.count <= Self.maximumPersistedCacheBytes else { return }
            try data.write(to: bywFileURL(for: profileID), options: .atomic)
        } catch { }
    }

    private static func loadBYWFromDisk(fileURL bywFileURL: URL) -> (title: String, results: [TMDBSearchResult], date: Date?) {
        guard FileManager.default.fileExists(atPath: bywFileURL.path),
              let data = try? BoundedLocalStoreReader.read(
                from: bywFileURL,
                maximumBytes: maximumPersistedCacheBytes
              ),
              let cache = try? JSONDecoder().decode(BecauseYouWatchedDiskCache.self, from: data) else {
            return ("", [], nil)
        }
        return (cache.title, sanitizedResults(cache.results), cache.date)
    }

    func getRecommendationCache() -> [TMDBSearchResult] {
        withStateLock { Self.sanitizedResults(cachedRecommendations) }
    }

    func restoreRecommendationCache(_ items: [TMDBSearchResult]) {
        withStateLock {
            cacheGenerations[activeProfileID] = UUID()
            cachedRecommendations = Self.sanitizedResults(items)
            cacheDate = Date()
            saveToDisk(forProfile: activeProfileID)
        }
    }

    private static func sanitizedResults(_ results: [TMDBSearchResult]) -> [TMDBSearchResult] {
        Array(results.compactMap(\.sanitizedForPersistence).prefix(maximumCachedResults))
    }

    private struct TasteProfile {
        var genreWeights: [Int: Double]
        var watchedIds: Set<String>
        var bookmarkedIds: Set<String>
        var topWatchedMovieIds: [Int]
        var topWatchedShowIds: [Int]
    }

    private func buildTasteProfile() -> TasteProfile {
        var genreWeights: [Int: Double] = [:]
        var watchedIds = Set<String>()
        var bookmarkedIds = Set<String>()
        var movieEntries: [(id: Int, date: Date)] = []
        var showEntries: [(id: Int, date: Date)] = []

        let progressData = ProgressManager.shared.getProgressData()

        for movie in progressData.movieProgress {
            watchedIds.insert("movie-\(movie.id)")
            if movie.progress >= 0.3 {
                movieEntries.append((movie.id, movie.lastUpdated))
            }
        }

        var showLastWatched: [Int: Date] = [:]
        for episode in progressData.episodeProgress {
            watchedIds.insert("tv-\(episode.showId)")
            if episode.progress >= 0.3 {
                if let existing = showLastWatched[episode.showId] {
                    showLastWatched[episode.showId] = max(existing, episode.lastUpdated)
                } else {
                    showLastWatched[episode.showId] = episode.lastUpdated
                }
            }
        }
        for (showId, date) in showLastWatched {
            showEntries.append((showId, date))
        }

        let collections = LibraryManager.shared.collections
        for collection in collections {
            for item in collection.items {
                bookmarkedIds.insert(item.searchResult.stableIdentity)
                if let genres = item.searchResult.genreIds {
                    for genreId in genres {

                        genreWeights[genreId, default: 0] += 2.0
                    }
                }
            }
        }

        for rating in UserRatingManager.shared.allRatings() {
            guard let isMovie = rating.isMovie else { continue }

            let ratingWeight: Double = (Double(rating.stars) - 5.5) / 2.25
            for collection in collections {
                for item in collection.items where item.searchResult.id == rating.tmdbId && item.searchResult.mediaType == (isMovie ? "movie" : "tv") {
                    if let genres = item.searchResult.genreIds {
                        for genreId in genres {
                            genreWeights[genreId, default: 0] += ratingWeight * 2.0
                        }
                    }
                }
            }
        }

        let recentWatchedIds = Set(
            (movieEntries.sorted { $0.date > $1.date }.prefix(10).map { "movie-\($0.id)" }) +
            (showEntries.sorted { $0.date > $1.date }.prefix(10).map { "tv-\($0.id)" })
        )
        for collection in collections {
            for item in collection.items where recentWatchedIds.contains(item.searchResult.stableIdentity) {
                if let genres = item.searchResult.genreIds {
                    for genreId in genres {
                        genreWeights[genreId, default: 0] += 3.0
                    }
                }
            }
        }

        let topMovies = movieEntries.sorted { $0.date > $1.date }.prefix(3).map { $0.id }
        let topShows = showEntries.sorted { $0.date > $1.date }.prefix(3).map { $0.id }

        return TasteProfile(
            genreWeights: genreWeights,
            watchedIds: watchedIds,
            bookmarkedIds: bookmarkedIds,
            topWatchedMovieIds: Array(topMovies),
            topWatchedShowIds: Array(topShows)
        )
    }

    private func scoreItem(_ item: TMDBSearchResult, profile: TasteProfile) -> Double {
        guard let genres = item.genreIds, !genres.isEmpty else { return 0 }

        var score: Double = 0

        let maxWeight = profile.genreWeights.values.max() ?? 1
        for genreId in genres {
            if let weight = profile.genreWeights[genreId] {
                score += weight / maxWeight
            }
        }

        let popularityBoost = min(item.popularity / 100.0, 0.5)
        score += popularityBoost

        if let rating = item.voteAverage, rating > 6.0 {
            score += (rating - 6.0) / 10.0
        }

        return score
    }

    private func fetchTMDBRecommendations(
        profile: TasteProfile,
        tmdbService: TMDBService
    ) async -> [TMDBSearchResult] {
        var results: [TMDBSearchResult] = []

        let movieIds = Array(profile.topWatchedMovieIds.prefix(2))
        let showIds = Array(profile.topWatchedShowIds.prefix(1))

        for movieId in movieIds {
            if let recs = try? await tmdbService.getMovieRecommendations(id: movieId) {
                let converted = recs.prefix(5).map { movie in
                    TMDBSearchResult(
                        id: movie.id,
                        mediaType: "movie",
                        title: movie.title,
                        name: nil,
                        overview: movie.overview,
                        posterPath: movie.posterPath,
                        backdropPath: movie.backdropPath,
                        releaseDate: movie.releaseDate,
                        firstAirDate: nil,
                        voteAverage: movie.voteAverage,
                        popularity: movie.popularity,
                        adult: movie.adult,
                        genreIds: movie.genreIds
                    )
                }
                results.append(contentsOf: converted)
            }

            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        for showId in showIds {
            if let recs = try? await tmdbService.getTVRecommendations(id: showId) {
                let converted = recs.prefix(5).map { show in
                    TMDBSearchResult(
                        id: show.id,
                        mediaType: "tv",
                        title: nil,
                        name: show.name,
                        overview: show.overview,
                        posterPath: show.posterPath,
                        backdropPath: show.backdropPath,
                        releaseDate: nil,
                        firstAirDate: show.firstAirDate,
                        voteAverage: show.voteAverage,
                        popularity: show.popularity,
                        adult: show.adult,
                        genreIds: show.genreIds
                    )
                }
                results.append(contentsOf: converted)
            }
        }

        return results
    }
}
