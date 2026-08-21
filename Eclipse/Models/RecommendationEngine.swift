import Foundation

final class RecommendationEngine {
    static let shared = RecommendationEngine()
    static let maximumPersistedCacheBytes = 4 * 1_024 * 1_024
    static let maximumCachedResults = 100
    private init() {
        activeProfileID = ProfileManager.shared.activeProfileID
        Self.migrateLegacyCachesIfNeeded()
        let forYou = Self.loadFromDisk(fileURL: Self.fileURL(for: activeProfileID))
        cachedRecommendations = forYou.results
        cacheDate = forYou.date

        let byw = Self.loadBYWFromDisk(fileURL: Self.bywFileURL(for: activeProfileID))
        becauseYouWatchedTitle = byw.title
        becauseYouWatchedResults = byw.results
        becauseYouWatchedCacheDate = byw.date
    }

    private var activeProfileID: UUID

    func switchProfile(to profileID: UUID) {
        guard profileID != activeProfileID else { return }
        flushPendingWrites(forProfile: activeProfileID)
        activeProfileID = profileID

        let forYou = Self.loadFromDisk(fileURL: Self.fileURL(for: profileID))
        cachedRecommendations = forYou.results
        cacheDate = forYou.date

        let byw = Self.loadBYWFromDisk(fileURL: Self.bywFileURL(for: profileID))
        becauseYouWatchedTitle = byw.title
        becauseYouWatchedResults = byw.results
        becauseYouWatchedCacheDate = byw.date
    }

    func flushPendingWrites(forProfile outgoing: UUID) {
        saveToDisk(forProfile: outgoing)
        saveBYWToDisk(forProfile: outgoing)
    }

    func discardStore(forProfile profileID: UUID) {
        discardCaches(forProfile: profileID)
    }

    func discardCaches(forProfile profileID: UUID) {
        try? FileManager.default.removeItem(at: Self.fileURL(for: profileID))
        try? FileManager.default.removeItem(at: Self.bywFileURL(for: profileID))
        if profileID == activeProfileID {
            invalidateCache()
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

    private static func fileURL(for profileID: UUID) -> URL {
        documentsDirectory.appendingPathComponent(
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

    private static func bywFileURL(for profileID: UUID) -> URL {
        documentsDirectory.appendingPathComponent(
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

        if let cacheDate, Date().timeIntervalSince(cacheDate) < cacheTTL, !cachedRecommendations.isEmpty {
            return cachedRecommendations
        }

        let owner = activeProfileID

        let profile = buildTasteProfile()

        guard !profile.genreWeights.isEmpty else { return [] }

        var candidateScores: [Int: (result: TMDBSearchResult, score: Double)] = [:]
        let watchedIds = profile.watchedIds
        let bookmarkedIds = profile.bookmarkedIds

        for (_, results) in catalogResults {
            for item in results {

                guard !watchedIds.contains(item.id), !bookmarkedIds.contains(item.id) else { continue }
                guard candidateScores[item.id] == nil else { continue }

                let score = scoreItem(item, profile: profile)
                if score > 0 {
                    candidateScores[item.id] = (item, score)
                }
            }
        }

        let tmdbRecs = await fetchTMDBRecommendations(profile: profile, tmdbService: tmdbService)
        for item in tmdbRecs {
            guard !watchedIds.contains(item.id), !bookmarkedIds.contains(item.id) else { continue }
            if let existing = candidateScores[item.id] {

                candidateScores[item.id] = (existing.result, existing.score * 1.5)
            } else {
                let score = scoreItem(item, profile: profile)
                candidateScores[item.id] = (item, max(score, 0.1))
            }
        }

        let ranked = candidateScores.values
            .sorted { $0.score > $1.score }
            .prefix(20)
            .map { $0.result }

        let results = Array(ranked)
        guard owner == activeProfileID else { return results }

        cachedRecommendations = results
        cacheDate = Date()
        saveToDisk(forProfile: owner)
        return cachedRecommendations
    }

    func invalidateCache() {
        cachedRecommendations = []
        cacheDate = nil
        becauseYouWatchedResults = []
        becauseYouWatchedTitle = ""
        becauseYouWatchedCacheDate = nil
        try? FileManager.default.removeItem(at: Self.fileURL(for: activeProfileID))
        try? FileManager.default.removeItem(at: Self.bywFileURL(for: activeProfileID))
    }

    func generateBecauseYouWatched(
        tmdbService: TMDBService
    ) async -> (title: String, results: [TMDBSearchResult]) {

        if let cacheDate = becauseYouWatchedCacheDate,
           Date().timeIntervalSince(cacheDate) < cacheTTL,
           !becauseYouWatchedResults.isEmpty {
            return (becauseYouWatchedTitle, becauseYouWatchedResults)
        }

        let owner = activeProfileID
        let progressData = ProgressManager.shared.getProgressData()

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

        let watchedIds = Set(progressData.movieProgress.map { $0.id } +
                            Array(showLastWatched.keys))
        recs = recs.filter { !watchedIds.contains($0.id) }

        guard owner == activeProfileID else { return (pick.title, recs) }

        becauseYouWatchedTitle = pick.title
        becauseYouWatchedResults = recs
        becauseYouWatchedCacheDate = Date()
        saveBYWToDisk(forProfile: owner)
        return (pick.title, recs)
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
            try data.write(to: Self.fileURL(for: profileID), options: .atomic)
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
            try data.write(to: Self.bywFileURL(for: profileID), options: .atomic)
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
        Self.sanitizedResults(cachedRecommendations)
    }

    func restoreRecommendationCache(_ items: [TMDBSearchResult]) {
        cachedRecommendations = Self.sanitizedResults(items)
        cacheDate = Date()
        saveToDisk(forProfile: activeProfileID)
    }

    private static func sanitizedResults(_ results: [TMDBSearchResult]) -> [TMDBSearchResult] {
        Array(results.compactMap(\.sanitizedForPersistence).prefix(maximumCachedResults))
    }

    private struct TasteProfile {
        var genreWeights: [Int: Double]
        var watchedIds: Set<Int>
        var bookmarkedIds: Set<Int>
        var topWatchedMovieIds: [Int]
        var topWatchedShowIds: [Int]
    }

    private func buildTasteProfile() -> TasteProfile {
        var genreWeights: [Int: Double] = [:]
        var watchedIds = Set<Int>()
        var bookmarkedIds = Set<Int>()
        var movieEntries: [(id: Int, date: Date)] = []
        var showEntries: [(id: Int, date: Date)] = []

        let progressData = ProgressManager.shared.getProgressData()

        for movie in progressData.movieProgress {
            watchedIds.insert(movie.id)
            if movie.progress >= 0.3 {
                movieEntries.append((movie.id, movie.lastUpdated))
            }
        }

        var showLastWatched: [Int: Date] = [:]
        for episode in progressData.episodeProgress {
            watchedIds.insert(episode.showId)
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
                bookmarkedIds.insert(item.searchResult.id)
                if let genres = item.searchResult.genreIds {
                    for genreId in genres {

                        genreWeights[genreId, default: 0] += 2.0
                    }
                }
            }
        }

        for rating in UserRatingManager.shared.allRatings() {

            let ratingWeight: Double = (Double(rating.stars) - 5.5) / 2.25
            for collection in collections {
                for item in collection.items where item.searchResult.id == rating.tmdbId {
                    if let genres = item.searchResult.genreIds {
                        for genreId in genres {
                            genreWeights[genreId, default: 0] += ratingWeight * 2.0
                        }
                    }
                }
            }
        }

        let recentWatchedIds = Set(
            (movieEntries.sorted { $0.date > $1.date }.prefix(10).map { $0.id }) +
            (showEntries.sorted { $0.date > $1.date }.prefix(10).map { $0.id })
        )
        for collection in collections {
            for item in collection.items where recentWatchedIds.contains(item.searchResult.id) {
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
