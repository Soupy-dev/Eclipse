//
//  RecommendationEngine.swift
//  Luna
//
//  Local recommendation engine that builds a genre taste profile
//  from watch history and bookmarks, then scores catalog items.
//

import Foundation

final class RecommendationEngine {
    static let shared = RecommendationEngine()
    private init() {
        let forYou = Self.loadFromDisk()
        cachedRecommendations = forYou.results
        cacheDate = forYou.date

        let byw = Self.loadBYWFromDisk()
        becauseYouWatchedTitle = byw.title
        becauseYouWatchedResults = byw.results
        becauseYouWatchedCacheDate = byw.date
    }

    // Cache to avoid recomputing every time HomeViewModel loads
    private var cachedRecommendations: [TMDBSearchResult] = []
    private var cacheDate: Date?
    private let cacheTTL: TimeInterval = 21600 // 6 hours

    // "Because you watched" cache
    private var becauseYouWatchedTitle: String = ""
    private var becauseYouWatchedResults: [TMDBSearchResult] = []
    private var becauseYouWatchedCacheDate: Date?

    // Codable wrappers for disk persistence (including cache date)
    private struct ForYouCache: Codable {
        let results: [TMDBSearchResult]
        let date: Date
    }

    private struct BecauseYouWatchedDiskCache: Codable {
        let title: String
        let results: [TMDBSearchResult]
        let date: Date
    }

    private static let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("RecommendationCache.json")
    }()

    private static let bywFileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("BecauseYouWatchedCache.json")
    }()

    /// Generate "Just For You" recommendations by scoring items from existing catalogs
    /// against the user's genre taste profile. Optionally fetches TMDB recommendations
    /// for the user's top watched items (throttled to avoid rate limiting).
    func generateRecommendations(
        catalogResults: [String: [TMDBSearchResult]],
        tmdbService: TMDBService
    ) async -> [TMDBSearchResult] {
        // Return cache if fresh
        if let cacheDate, Date().timeIntervalSince(cacheDate) < cacheTTL, !cachedRecommendations.isEmpty {
            return cachedRecommendations
        }

        let profile = buildTasteProfile()

        // No signals = no recommendations
        guard !profile.genreWeights.isEmpty else { return [] }

        // 1. Score every item from existing catalogs
        var candidateScores: [Int: (result: TMDBSearchResult, score: Double)] = [:]
        let watchedIds = profile.watchedIds
        let bookmarkedIds = profile.bookmarkedIds

        for (_, results) in catalogResults {
            for item in results {
                // Skip already-watched and bookmarked items
                guard !watchedIds.contains(item.id), !bookmarkedIds.contains(item.id) else { continue }
                guard candidateScores[item.id] == nil else { continue }

                let score = scoreItem(item, profile: profile)
                if score > 0 {
                    candidateScores[item.id] = (item, score)
                }
            }
        }

        // 2. Fetch TMDB recommendations for top 3 most-watched items (throttled)
        let tmdbRecs = await fetchTMDBRecommendations(profile: profile, tmdbService: tmdbService)
        for item in tmdbRecs {
            guard !watchedIds.contains(item.id), !bookmarkedIds.contains(item.id) else { continue }
            if let existing = candidateScores[item.id] {
                // Boost score for items that also appear in TMDB recs
                candidateScores[item.id] = (existing.result, existing.score * 1.5)
            } else {
                let score = scoreItem(item, profile: profile)
                candidateScores[item.id] = (item, max(score, 0.1))
            }
        }

        // 3. Rank, deduplicate, and take top 20
        let ranked = candidateScores.values
            .sorted { $0.score > $1.score }
            .prefix(20)
            .map { $0.result }

        cachedRecommendations = Array(ranked)
        cacheDate = Date()
        saveToDisk()
        return cachedRecommendations
    }

    func invalidateCache() {
        cachedRecommendations = []
        cacheDate = nil
        becauseYouWatchedResults = []
        becauseYouWatchedTitle = ""
        becauseYouWatchedCacheDate = nil
        try? FileManager.default.removeItem(at: Self.fileURL)
        try? FileManager.default.removeItem(at: Self.bywFileURL)
    }

    // MARK: - Because You Watched

    /// Picks the most-recently-watched item with meaningful progress and fetches
    /// TMDB recommendations for it. Returns (displayTitle, recommendations).
    func generateBecauseYouWatched(
        tmdbService: TMDBService
    ) async -> (title: String, results: [TMDBSearchResult]) {
        // Return cache if fresh
        if let cacheDate = becauseYouWatchedCacheDate,
           Date().timeIntervalSince(cacheDate) < cacheTTL,
           !becauseYouWatchedResults.isEmpty {
            return (becauseYouWatchedTitle, becauseYouWatchedResults)
        }

        let progressData = ProgressManager.shared.getProgressData()

        // Collect recently watched movies (≥30% watched)
        let movieCandidates = progressData.movieProgress
            .filter { $0.progress >= 0.3 }
            .sorted { $0.lastUpdated > $1.lastUpdated }

        // Collect recently watched shows (any episode ≥30% watched)
        var showLastWatched: [Int: Date] = [:]
        for ep in progressData.episodeProgress where ep.progress >= 0.3 {
            if let existing = showLastWatched[ep.showId] {
                showLastWatched[ep.showId] = max(existing, ep.lastUpdated)
            } else {
                showLastWatched[ep.showId] = ep.lastUpdated
            }
        }

        // Build a unified candidate list with title and date
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

        // Sort by most recent and pick randomly from the top 5
        candidates.sort { $0.date > $1.date }
        let topCandidates = Array(candidates.prefix(5))
        guard let pick = topCandidates.randomElement() else { return ("", []) }

        // Fetch TMDB recommendations for this item
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
                        popularity: show.popularity, adult: nil, genreIds: show.genreIds
                    )
                }
            }
        }

        // Filter out already-watched items
        let watchedIds = Set(progressData.movieProgress.map { $0.id } +
                            Array(showLastWatched.keys))
        recs = recs.filter { !watchedIds.contains($0.id) }

        becauseYouWatchedTitle = pick.title
        becauseYouWatchedResults = recs
        becauseYouWatchedCacheDate = Date()
        saveBYWToDisk()
        return (pick.title, recs)
    }

    // MARK: - Persistence

    private func saveToDisk() {
        guard !cachedRecommendations.isEmpty, let cacheDate else { return }
        do {
            let cache = ForYouCache(results: cachedRecommendations, date: cacheDate)
            let data = try JSONEncoder().encode(cache)
            try data.write(to: Self.fileURL, options: .atomic)
        } catch { }
    }

    private static func loadFromDisk() -> (results: [TMDBSearchResult], date: Date?) {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let cache = try? JSONDecoder().decode(ForYouCache.self, from: data) else {
            return ([], nil)
        }
        return (cache.results, cache.date)
    }

    private func saveBYWToDisk() {
        guard !becauseYouWatchedResults.isEmpty, let becauseYouWatchedCacheDate else { return }
        do {
            let cache = BecauseYouWatchedDiskCache(
                title: becauseYouWatchedTitle,
                results: becauseYouWatchedResults,
                date: becauseYouWatchedCacheDate
            )
            let data = try JSONEncoder().encode(cache)
            try data.write(to: Self.bywFileURL, options: .atomic)
        } catch { }
    }

    private static func loadBYWFromDisk() -> (title: String, results: [TMDBSearchResult], date: Date?) {
        guard FileManager.default.fileExists(atPath: bywFileURL.path),
              let data = try? Data(contentsOf: bywFileURL),
              let cache = try? JSONDecoder().decode(BecauseYouWatchedDiskCache.self, from: data) else {
            return ("", [], nil)
        }
        return (cache.title, cache.results, cache.date)
    }

    /// Returns the current recommendation cache for backup
    func getRecommendationCache() -> [TMDBSearchResult] {
        return cachedRecommendations
    }

    /// Restores recommendation cache from backup
    func restoreRecommendationCache(_ items: [TMDBSearchResult]) {
        cachedRecommendations = items
        cacheDate = Date()
        saveToDisk()
    }

    // MARK: - Taste Profile

    private struct TasteProfile {
        var genreWeights: [Int: Double] // genreId -> weight
        var watchedIds: Set<Int>
        var bookmarkedIds: Set<Int>
        var topWatchedMovieIds: [Int] // sorted by recency, for TMDB recs
        var topWatchedShowIds: [Int]
    }

    private func buildTasteProfile() -> TasteProfile {
        var genreWeights: [Int: Double] = [:]
        var watchedIds = Set<Int>()
        var bookmarkedIds = Set<Int>()
        var movieEntries: [(id: Int, date: Date)] = []
        var showEntries: [(id: Int, date: Date)] = []

        // 1. Watch history — strongest signal
        let progressData = ProgressManager.shared.getProgressData()

        for movie in progressData.movieProgress {
            watchedIds.insert(movie.id)
            if movie.progress >= 0.3 { // At least 30% watched = meaningful signal
                movieEntries.append((movie.id, movie.lastUpdated))
            }
        }

        // Group episodes by show
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

        // 2. Bookmarks — secondary signal
        let collections = LibraryManager.shared.collections
        for collection in collections {
            for item in collection.items {
                bookmarkedIds.insert(item.searchResult.id)
                if let genres = item.searchResult.genreIds {
                    for genreId in genres {
                        // Bookmarked = moderate weight
                        genreWeights[genreId, default: 0] += 2.0
                    }
                }
            }
        }

        // 3. User star ratings — direct signal
        for rating in UserRatingManager.shared.allRatings() {
            // Highly-rated items boost their genres; low-rated items dampen them.
            let ratingWeight: Double = (Double(rating.stars) - 5.5) / 2.25 // about -2 to +2
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

        // 4. Derive genre weights from bookmarked items for watched content
        //    (watched movies/shows don't carry genreIds in ProgressManager,
        //     so we use bookmarks + catalog cross-reference)
        //    The actual genre scoring happens at item-score time using the item's own genreIds.

        // Boost genres from recently watched content found in bookmarks
        let recentWatchedIds = Set(
            (movieEntries.sorted { $0.date > $1.date }.prefix(10).map { $0.id }) +
            (showEntries.sorted { $0.date > $1.date }.prefix(10).map { $0.id })
        )
        for collection in collections {
            for item in collection.items where recentWatchedIds.contains(item.searchResult.id) {
                if let genres = item.searchResult.genreIds {
                    for genreId in genres {
                        genreWeights[genreId, default: 0] += 3.0 // Watched + bookmarked = strong signal
                    }
                }
            }
        }

        // Sort by recency for TMDB rec fetching
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

    // MARK: - Scoring

    private func scoreItem(_ item: TMDBSearchResult, profile: TasteProfile) -> Double {
        guard let genres = item.genreIds, !genres.isEmpty else { return 0 }

        var score: Double = 0

        // Genre match scoring
        let maxWeight = profile.genreWeights.values.max() ?? 1
        for genreId in genres {
            if let weight = profile.genreWeights[genreId] {
                score += weight / maxWeight // Normalize to 0-1 per genre
            }
        }

        // Popularity boost (slight preference for popular content)
        let popularityBoost = min(item.popularity / 100.0, 0.5)
        score += popularityBoost

        // Rating boost
        if let rating = item.voteAverage, rating > 6.0 {
            score += (rating - 6.0) / 10.0 // 0 to 0.4 boost
        }

        return score
    }

    // MARK: - TMDB Recommendations (throttled)

    private func fetchTMDBRecommendations(
        profile: TasteProfile,
        tmdbService: TMDBService
    ) async -> [TMDBSearchResult] {
        var results: [TMDBSearchResult] = []

        // Fetch recs for top 2 movies + top 1 show (max 3 API calls)
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
            // Brief delay between calls
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
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
                        adult: nil,
                        genreIds: show.genreIds
                    )
                }
                results.append(contentsOf: converted)
            }
        }

        return results
    }
}
