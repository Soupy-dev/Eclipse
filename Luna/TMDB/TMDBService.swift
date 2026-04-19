//
//  TMDBService.swift
//  Sora
//
//  Created by Francesco on 07/08/25.
//

import Foundation

class TMDBService: ObservableObject {
    static let shared = TMDBService()
    
    static let tmdbBaseURL = "https://api.themoviedb.org/3"
    static let tmdbImageBaseURL = "https://image.tmdb.org/t/p/original"
    
    private let apiKey = "738b4edd0a156cc126dc4a4b8aea4aca"
    private let baseURL = tmdbBaseURL

    // MARK: - Rate Limiting
    private let rateLimiter = TMDBRateLimiter(maxConcurrent: 4, minInterval: 0.05)

    // MARK: - In-Memory Detail Cache (avoids duplicate fetches from ContinueWatchingCards etc.)
    private let detailCache = TMDBDetailCache()

    private init() {}
    
    private var currentLanguage: String {
        return UserDefaults.standard.string(forKey: "tmdbLanguage") ?? "en-US"
    }

    private func probe(_ message: String) {
        Logger.shared.log("TMDBService: \(message)", type: "CrashProbe")
    }

    /// Throttled URL fetch — limits concurrent TMDB requests to avoid 429s
    private func throttledData(from url: URL) async throws -> (Data, URLResponse) {
        let isMoviePath = url.path.contains("/movie/")
        if isMoviePath {
            probe("throttledData start path=\(url.path)")
        }

        let result = try await rateLimiter.execute {
            try await URLSession.shared.data(from: url)
        }

        if isMoviePath {
            let status = (result.1 as? HTTPURLResponse)?.statusCode ?? -1
            probe("throttledData end path=\(url.path) status=\(status) bytes=\(result.0.count)")
        }

        return result
    }
    
    // MARK: - Multi Search (Movies and TV Shows)
    func searchMulti(query: String, maxPages: Int = 2) async throws -> [TMDBSearchResult] {
        guard !query.isEmpty else { return [] }
        
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        var allResults: [TMDBSearchResult] = []
        
        // TMDB returns 20 results per page; fetch up to maxPages to get more results
        for page in 1...maxPages {
            let urlString = "\(baseURL)/search/multi?api_key=\(apiKey)&query=\(encodedQuery)&language=\(currentLanguage)&include_adult=false&page=\(page)"
            
            guard let url = URL(string: urlString) else {
                throw TMDBError.invalidURL
            }
            
            do {
                let (data, _) = try await throttledData(from: url)
                let response = try JSONDecoder().decode(TMDBSearchResponse.self, from: data)
                let filtered = response.results.filter { $0.mediaType == "movie" || $0.mediaType == "tv" }
                allResults.append(contentsOf: filtered)
                
                // Stop if we get fewer results than expected (last page)
                if filtered.count < 20 {
                    break
                }
            } catch {
                throw TMDBError.networkError(error)
            }
        }
        
        return allResults
    }
    
    // MARK: - Search Movies
    func searchMovies(query: String) async throws -> [TMDBMovie] {
        guard !query.isEmpty else { return [] }
        
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "\(baseURL)/search/movie?api_key=\(apiKey)&query=\(encodedQuery)&language=\(currentLanguage)&include_adult=false"
        
        guard let url = URL(string: urlString) else {
            throw TMDBError.invalidURL
        }
        
        do {
            let (data, _) = try await throttledData(from: url)
            let response = try JSONDecoder().decode(TMDBMovieSearchResponse.self, from: data)
            return response.results
        } catch {
            throw TMDBError.networkError(error)
        }
    }
    
    // MARK: - Search TV Shows
    func searchTVShows(query: String) async throws -> [TMDBTVShow] {
        guard !query.isEmpty else { return [] }
        
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "\(baseURL)/search/tv?api_key=\(apiKey)&query=\(encodedQuery)&language=\(currentLanguage)&include_adult=false"
        
        guard let url = URL(string: urlString) else {
            throw TMDBError.invalidURL
        }
        
        do {
            let (data, _) = try await throttledData(from: url)
            let response = try JSONDecoder().decode(TMDBTVSearchResponse.self, from: data)
            return response.results
        } catch {
            throw TMDBError.networkError(error)
        }
    }
    
    // MARK: - Get Movie Details
    func getMovieDetails(id: Int) async throws -> TMDBMovieDetail {
        probe("getMovieDetails start id=\(id)")
        if let cached: TMDBMovieDetail = detailCache.get(key: "movie_\(id)") {
            probe("getMovieDetails cache hit id=\(id)")
            return cached
        }
        probe("getMovieDetails cache miss id=\(id)")

        let urlString = "\(baseURL)/movie/\(id)?api_key=\(apiKey)&language=\(currentLanguage)&append_to_response=release_dates"
        
        guard let url = URL(string: urlString) else {
            probe("getMovieDetails invalid URL id=\(id)")
            throw TMDBError.invalidURL
        }
        
        do {
            probe("getMovieDetails request id=\(id)")
            let (data, response) = try await throttledData(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            probe("getMovieDetails response id=\(id) status=\(status) bytes=\(data.count)")
            probe("getMovieDetails decode start id=\(id)")
            let movieDetail = try JSONDecoder().decode(TMDBMovieDetail.self, from: data)
            probe("getMovieDetails decode done id=\(id) title=\(movieDetail.title)")
            detailCache.set(key: "movie_\(id)", value: movieDetail)
            probe("getMovieDetails cache store id=\(id)")
            return movieDetail
        } catch {
            probe("getMovieDetails error id=\(id) error=\(error.localizedDescription)")
            throw TMDBError.networkError(error)
        }
    }
    
    // MARK: - Get TV Show Details
    func getTVShowDetails(id: Int) async throws -> TMDBTVShowDetail {
        if let cached: TMDBTVShowDetail = detailCache.get(key: "tv_\(id)") {
            return cached
        }

        let urlString = "\(baseURL)/tv/\(id)?api_key=\(apiKey)&language=\(currentLanguage)&append_to_response=content_ratings,external_ids"
        
        guard let url = URL(string: urlString) else {
            throw TMDBError.invalidURL
        }
        
        do {
            let (data, _) = try await throttledData(from: url)
            let tvShowDetail = try JSONDecoder().decode(TMDBTVShowDetail.self, from: data)
            detailCache.set(key: "tv_\(id)", value: tvShowDetail)
            return tvShowDetail
        } catch {
            throw TMDBError.networkError(error)
        }
    }
    
    // MARK: - Get TV Show with Seasons
    func getTVShowWithSeasons(id: Int) async throws -> TMDBTVShowWithSeasons {
        let cacheKey = "tvWithSeasons_\(id)"
        if let cached: TMDBTVShowWithSeasons = detailCache.get(key: cacheKey) {
            return cached
        }

        let urlString = "\(baseURL)/tv/\(id)?api_key=\(apiKey)&language=\(currentLanguage)&append_to_response=content_ratings,external_ids"
        
        guard let url = URL(string: urlString) else {
            throw TMDBError.invalidURL
        }
        
        do {
            let (data, _) = try await throttledData(from: url)
            let tvShowDetail = try JSONDecoder().decode(TMDBTVShowWithSeasons.self, from: data)
            detailCache.set(key: cacheKey, value: tvShowDetail)
            return tvShowDetail
        } catch {
            throw TMDBError.networkError(error)
        }
    }
    
    // MARK: - Get Season Details
    func getSeasonDetails(tvShowId: Int, seasonNumber: Int) async throws -> TMDBSeasonDetail {
        let cacheKey = "season_\(tvShowId)_\(seasonNumber)"
        if let cached: TMDBSeasonDetail = detailCache.get(key: cacheKey) {
            return cached
        }

        let urlString = "\(baseURL)/tv/\(tvShowId)/season/\(seasonNumber)?api_key=\(apiKey)&language=\(currentLanguage)"
        
        guard let url = URL(string: urlString) else {
            throw TMDBError.invalidURL
        }
        
        do {
            let (data, _) = try await throttledData(from: url)
            let seasonDetail = try JSONDecoder().decode(TMDBSeasonDetail.self, from: data)
            detailCache.set(key: cacheKey, value: seasonDetail)
            return seasonDetail
        } catch {
            throw TMDBError.networkError(error)
        }
    }
    
    // MARK: - Get Movie Alternative Titles
    func getMovieAlternativeTitles(id: Int) async throws -> TMDBAlternativeTitles {
        let cacheKey = "movieAltTitles_\(id)"
        if let cached: TMDBAlternativeTitles = detailCache.get(key: cacheKey) {
            return cached
        }

        let urlString = "\(baseURL)/movie/\(id)/alternative_titles?api_key=\(apiKey)"
        
        guard let url = URL(string: urlString) else {
            throw TMDBError.invalidURL
        }
        
        do {
            let (data, _) = try await throttledData(from: url)
            let alternativeTitles = try JSONDecoder().decode(TMDBAlternativeTitles.self, from: data)
            detailCache.set(key: cacheKey, value: alternativeTitles)
            return alternativeTitles
        } catch {
            throw TMDBError.networkError(error)
        }
    }
    
    // MARK: - Get TV Show Alternative Titles
    func getTVShowAlternativeTitles(id: Int) async throws -> TMDBTVAlternativeTitles {
        let cacheKey = "tvAltTitles_\(id)"
        if let cached: TMDBTVAlternativeTitles = detailCache.get(key: cacheKey) {
            return cached
        }

        let urlString = "\(baseURL)/tv/\(id)/alternative_titles?api_key=\(apiKey)"
        
        guard let url = URL(string: urlString) else {
            throw TMDBError.invalidURL
        }
        
        do {
            let (data, _) = try await throttledData(from: url)
            let alternativeTitles = try JSONDecoder().decode(TMDBTVAlternativeTitles.self, from: data)
            detailCache.set(key: cacheKey, value: alternativeTitles)
            return alternativeTitles
        } catch {
            throw TMDBError.networkError(error)
        }
    }
    
    // MARK: - Get Trending Movies and TV Shows
    func getTrending(mediaType: String = "all", timeWindow: String = "week") async throws -> [TMDBSearchResult] {
        let urlString = "\(baseURL)/trending/\(mediaType)/\(timeWindow)?api_key=\(apiKey)&language=\(currentLanguage)&include_adult=false"
        
        guard let url = URL(string: urlString) else {
            throw TMDBError.invalidURL
        }
        
        do {
            let (data, _) = try await throttledData(from: url)
            let response = try JSONDecoder().decode(TMDBSearchResponse.self, from: data)
            return response.results
        } catch {
            throw TMDBError.networkError(error)
        }
    }
    
    // MARK: - Get Popular Movies
    func getPopularMovies(page: Int = 1) async throws -> [TMDBMovie] {
        let urlString = "\(baseURL)/movie/popular?api_key=\(apiKey)&language=\(currentLanguage)&page=\(page)&include_adult=false"
        
        guard let url = URL(string: urlString) else {
            throw TMDBError.invalidURL
        }
        
        do {
            let (data, _) = try await throttledData(from: url)
            let response = try JSONDecoder().decode(TMDBMovieSearchResponse.self, from: data)
            return response.results
        } catch {
            throw TMDBError.networkError(error)
        }
    }
    
    // MARK: - Get Now Playing Movies
    func getNowPlayingMovies(page: Int = 1) async throws -> [TMDBMovie] {
        let urlString = "\(baseURL)/movie/now_playing?api_key=\(apiKey)&language=\(currentLanguage)&page=\(page)&include_adult=false"
        
        guard let url = URL(string: urlString) else {
            throw TMDBError.invalidURL
        }
        
        do {
            let (data, _) = try await throttledData(from: url)
            let response = try JSONDecoder().decode(TMDBMovieSearchResponse.self, from: data)
            return response.results
        } catch {
            throw TMDBError.networkError(error)
        }
    }
    
    // MARK: - Get Upcoming Movies
    func getUpcomingMovies(page: Int = 1) async throws -> [TMDBMovie] {
        let urlString = "\(baseURL)/movie/upcoming?api_key=\(apiKey)&language=\(currentLanguage)&page=\(page)&include_adult=false"
        
        guard let url = URL(string: urlString) else {
            throw TMDBError.invalidURL
        }
        
        do {
            let (data, _) = try await throttledData(from: url)
            let response = try JSONDecoder().decode(TMDBMovieSearchResponse.self, from: data)
            return response.results
        } catch {
            throw TMDBError.networkError(error)
        }
    }
    
    // MARK: - Get Popular TV Shows
    func getPopularTVShows(page: Int = 1) async throws -> [TMDBTVShow] {
        let urlString = "\(baseURL)/tv/popular?api_key=\(apiKey)&language=\(currentLanguage)&page=\(page)&include_adult=false"
        
        guard let url = URL(string: urlString) else {
            throw TMDBError.invalidURL
        }
        
        do {
            let (data, _) = try await throttledData(from: url)
            let response = try JSONDecoder().decode(TMDBTVSearchResponse.self, from: data)
            return response.results
        } catch {
            throw TMDBError.networkError(error)
        }
    }
    
    // MARK: - Get On The Air TV Shows
    func getOnTheAirTVShows(page: Int = 1) async throws -> [TMDBTVShow] {
        let urlString = "\(baseURL)/tv/on_the_air?api_key=\(apiKey)&language=\(currentLanguage)&page=\(page)&include_adult=false"
        
        guard let url = URL(string: urlString) else {
            throw TMDBError.invalidURL
        }
        
        do {
            let (data, _) = try await throttledData(from: url)
            let response = try JSONDecoder().decode(TMDBTVSearchResponse.self, from: data)
            return response.results
        } catch {
            throw TMDBError.networkError(error)
        }
    }
    
    // MARK: - Get Airing Today TV Shows
    func getAiringTodayTVShows(page: Int = 1) async throws -> [TMDBTVShow] {
        let urlString = "\(baseURL)/tv/airing_today?api_key=\(apiKey)&language=\(currentLanguage)&page=\(page)&include_adult=false"
        
        guard let url = URL(string: urlString) else {
            throw TMDBError.invalidURL
        }
        
        do {
            let (data, _) = try await throttledData(from: url)
            let response = try JSONDecoder().decode(TMDBTVSearchResponse.self, from: data)
            return response.results
        } catch {
            throw TMDBError.networkError(error)
        }
    }
    
    // MARK: - Get Top Rated Movies
    func getTopRatedMovies(page: Int = 1) async throws -> [TMDBMovie] {
        let urlString = "\(baseURL)/movie/top_rated?api_key=\(apiKey)&language=\(currentLanguage)&page=\(page)&include_adult=false"
        
        guard let url = URL(string: urlString) else {
            throw TMDBError.invalidURL
        }
        
        do {
            let (data, _) = try await throttledData(from: url)
            let response = try JSONDecoder().decode(TMDBMovieSearchResponse.self, from: data)
            return response.results
        } catch {
            throw TMDBError.networkError(error)
        }
    }
    
    // MARK: - Get Top Rated TV Shows
    func getTopRatedTVShows(page: Int = 1) async throws -> [TMDBTVShow] {
        let urlString = "\(baseURL)/tv/top_rated?api_key=\(apiKey)&language=\(currentLanguage)&page=\(page)&include_adult=false"
        
        guard let url = URL(string: urlString) else {
            throw TMDBError.invalidURL
        }
        
        do {
            let (data, _) = try await throttledData(from: url)
            let response = try JSONDecoder().decode(TMDBTVSearchResponse.self, from: data)
            return response.results
        } catch {
            throw TMDBError.networkError(error)
        }
    }
    
    // MARK: - Get Popular Anime (Animation TV Shows from Japan)
    func getPopularAnime(page: Int = 1) async throws -> [TMDBTVShow] {
        let urlString = "\(baseURL)/discover/tv?api_key=\(apiKey)&language=\(currentLanguage)&page=\(page)&with_genres=16&with_origin_country=JP&sort_by=popularity.desc&include_adult=false"
        
        guard let url = URL(string: urlString) else {
            throw TMDBError.invalidURL
        }
        
        do {
            let (data, _) = try await throttledData(from: url)
            let response = try JSONDecoder().decode(TMDBTVSearchResponse.self, from: data)
            return response.results
        } catch {
            throw TMDBError.networkError(error)
        }
    }
    
    // MARK: - Get Top Rated Anime (Animation TV Shows from Japan)
    func getTopRatedAnime(page: Int = 1) async throws -> [TMDBTVShow] {
        let urlString = "\(baseURL)/discover/tv?api_key=\(apiKey)&language=\(currentLanguage)&page=\(page)&with_genres=16&with_origin_country=JP&sort_by=vote_average.desc&vote_count.gte=100&include_adult=false"
        
        guard let url = URL(string: urlString) else {
            throw TMDBError.invalidURL
        }
        
        do {
            let (data, _) = try await throttledData(from: url)
            let response = try JSONDecoder().decode(TMDBTVSearchResponse.self, from: data)
            return response.results
        } catch {
            throw TMDBError.networkError(error)
        }
    }
    
    // MARK: - Helper function to get romaji title
    func getRomajiTitle(for mediaType: String, id: Int) async -> String? {
        do {
            if mediaType == "movie" {
                let alternativeTitles = try await getMovieAlternativeTitles(id: id)
                return alternativeTitles.titles.first { title in
                    title.iso31661 == "JP" && (title.type?.lowercased().contains("romaji") == true || title.type?.lowercased().contains("romanized") == true)
                }?.title
            } else {
                let alternativeTitles = try await getTVShowAlternativeTitles(id: id)
                return alternativeTitles.results.first { title in
                    title.iso31661 == "JP" && (title.type?.lowercased().contains("romaji") == true || title.type?.lowercased().contains("romanized") == true)
                }?.title
            }
        } catch {
            return nil
        }
    }

    // MARK: - Discover by Genre
    func discoverByGenre(genreId: Int, mediaType: String = "movie", page: Int = 1) async throws -> [TMDBSearchResult] {
        let urlString = "\(baseURL)/discover/\(mediaType)?api_key=\(apiKey)&language=\(currentLanguage)&page=\(page)&with_genres=\(genreId)&sort_by=popularity.desc&include_adult=false"
        guard let url = URL(string: urlString) else { throw TMDBError.invalidURL }
        let (data, _) = try await throttledData(from: url)
        if mediaType == "movie" {
            let response = try JSONDecoder().decode(TMDBMovieSearchResponse.self, from: data)
            return response.results.map {
                TMDBSearchResult(id: $0.id, mediaType: "movie", title: $0.title, name: nil, overview: $0.overview, posterPath: $0.posterPath, backdropPath: $0.backdropPath, releaseDate: $0.releaseDate, firstAirDate: nil, voteAverage: $0.voteAverage, popularity: $0.popularity, adult: $0.adult, genreIds: $0.genreIds)
            }
        } else {
            let response = try JSONDecoder().decode(TMDBTVSearchResponse.self, from: data)
            return response.results.map {
                TMDBSearchResult(id: $0.id, mediaType: "tv", title: nil, name: $0.name, overview: $0.overview, posterPath: $0.posterPath, backdropPath: $0.backdropPath, releaseDate: nil, firstAirDate: $0.firstAirDate, voteAverage: $0.voteAverage, popularity: $0.popularity, adult: nil, genreIds: $0.genreIds)
            }
        }
    }
    
    // MARK: - Discover by Network
    func discoverByNetwork(networkId: Int, page: Int = 1) async throws -> [TMDBSearchResult] {
        let urlString = "\(baseURL)/discover/tv?api_key=\(apiKey)&language=\(currentLanguage)&page=\(page)&with_networks=\(networkId)&sort_by=popularity.desc&include_adult=false"
        guard let url = URL(string: urlString) else { throw TMDBError.invalidURL }
        let (data, _) = try await throttledData(from: url)
        let response = try JSONDecoder().decode(TMDBTVSearchResponse.self, from: data)
        return response.results.map {
            TMDBSearchResult(id: $0.id, mediaType: "tv", title: nil, name: $0.name, overview: $0.overview, posterPath: $0.posterPath, backdropPath: $0.backdropPath, releaseDate: nil, firstAirDate: $0.firstAirDate, voteAverage: $0.voteAverage, popularity: $0.popularity, adult: nil, genreIds: $0.genreIds)
        }
    }
    
    // MARK: - Discover by Company
    func discoverByCompany(companyId: Int, mediaType: String = "movie", page: Int = 1) async throws -> [TMDBSearchResult] {
        let urlString = "\(baseURL)/discover/\(mediaType)?api_key=\(apiKey)&language=\(currentLanguage)&page=\(page)&with_companies=\(companyId)&sort_by=popularity.desc&include_adult=false"
        guard let url = URL(string: urlString) else { throw TMDBError.invalidURL }
        let (data, _) = try await throttledData(from: url)
        if mediaType == "movie" {
            let response = try JSONDecoder().decode(TMDBMovieSearchResponse.self, from: data)
            return response.results.map {
                TMDBSearchResult(id: $0.id, mediaType: "movie", title: $0.title, name: nil, overview: $0.overview, posterPath: $0.posterPath, backdropPath: $0.backdropPath, releaseDate: $0.releaseDate, firstAirDate: nil, voteAverage: $0.voteAverage, popularity: $0.popularity, adult: $0.adult, genreIds: $0.genreIds)
            }
        } else {
            let response = try JSONDecoder().decode(TMDBTVSearchResponse.self, from: data)
            return response.results.map {
                TMDBSearchResult(id: $0.id, mediaType: "tv", title: nil, name: $0.name, overview: $0.overview, posterPath: $0.posterPath, backdropPath: $0.backdropPath, releaseDate: nil, firstAirDate: $0.firstAirDate, voteAverage: $0.voteAverage, popularity: $0.popularity, adult: nil, genreIds: $0.genreIds)
            }
        }
    }
    
    // MARK: - Get Images (Backdrops, Logos, Posters)
    func getMovieImages(id: Int, preferredLanguage: String? = nil) async throws -> TMDBImagesResponse {
        probe("getMovieImages start id=\(id)")
        let langCode = (preferredLanguage ?? currentLanguage).components(separatedBy: "-").first ?? "en"
        let cacheKey = "movieImages_\(id)_\(langCode)"
        if let cached: TMDBImagesResponse = detailCache.get(key: cacheKey) {
            probe("getMovieImages cache hit id=\(id) lang=\(langCode)")
            return cached
        }
        probe("getMovieImages cache miss id=\(id) lang=\(langCode)")

        let urlString = "\(baseURL)/movie/\(id)/images?api_key=\(apiKey)&include_image_language=\(langCode),en,null"
        
        guard let url = URL(string: urlString) else {
            probe("getMovieImages invalid URL id=\(id)")
            throw TMDBError.invalidURL
        }
        
        do {
            probe("getMovieImages request id=\(id)")
            let (data, httpResponse) = try await throttledData(from: url)
            let status = (httpResponse as? HTTPURLResponse)?.statusCode ?? -1
            probe("getMovieImages response id=\(id) status=\(status) bytes=\(data.count)")
            probe("getMovieImages decode start id=\(id)")
            let decodedResponse = try JSONDecoder().decode(TMDBImagesResponse.self, from: data)
            probe("getMovieImages decode done id=\(id) logos=\(decodedResponse.logos?.count ?? 0)")
            detailCache.set(key: cacheKey, value: decodedResponse)
            probe("getMovieImages cache store id=\(id) lang=\(langCode)")
            return decodedResponse
        } catch {
            probe("getMovieImages error id=\(id) error=\(error.localizedDescription)")
            throw TMDBError.networkError(error)
        }
    }
    
    func getTVShowImages(id: Int, preferredLanguage: String? = nil) async throws -> TMDBImagesResponse {
        let langCode = (preferredLanguage ?? currentLanguage).components(separatedBy: "-").first ?? "en"
        let cacheKey = "tvImages_\(id)_\(langCode)"
        if let cached: TMDBImagesResponse = detailCache.get(key: cacheKey) {
            return cached
        }

        let urlString = "\(baseURL)/tv/\(id)/images?api_key=\(apiKey)&include_image_language=\(langCode),en,null"
        
        guard let url = URL(string: urlString) else {
            throw TMDBError.invalidURL
        }
        
        do {
            let (data, _) = try await throttledData(from: url)
            let response = try JSONDecoder().decode(TMDBImagesResponse.self, from: data)
            detailCache.set(key: cacheKey, value: response)
            return response
        } catch {
            throw TMDBError.networkError(error)
        }
    }
    
    func getBestLogo(from images: TMDBImagesResponse, preferredLanguage: String? = nil) -> TMDBImage? {
        guard let logos = images.logos, !logos.isEmpty else { return nil }
        
        let langCode = (preferredLanguage ?? currentLanguage).components(separatedBy: "-").first ?? "en"
        
        if let logo = logos.first(where: { $0.iso6391 == langCode }) {
            return logo
        }
        if let logo = logos.first(where: { $0.iso6391 == "en" }) {
            return logo
        }
        if let logo = logos.first(where: { $0.iso6391 == nil }) {
            return logo
        }
        return logos.first
    }
    
    // MARK: - Get Movie Credits (Cast)
    func getMovieCredits(id: Int) async throws -> TMDBCreditsResponse {
        probe("getMovieCredits start id=\(id)")
        let cacheKey = "movieCredits_\(id)"
        if let cached: TMDBCreditsResponse = detailCache.get(key: cacheKey) {
            probe("getMovieCredits cache hit id=\(id)")
            return cached
        }
        probe("getMovieCredits cache miss id=\(id)")
        let urlString = "\(baseURL)/movie/\(id)/credits?api_key=\(apiKey)&language=\(currentLanguage)"
        guard let url = URL(string: urlString) else { throw TMDBError.invalidURL }
        probe("getMovieCredits request id=\(id)")
        let (data, response) = try await throttledData(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        probe("getMovieCredits response id=\(id) status=\(status) bytes=\(data.count)")
        probe("getMovieCredits decode start id=\(id)")
        let result = try JSONDecoder().decode(TMDBCreditsResponse.self, from: data)
        probe("getMovieCredits decode done id=\(id) cast=\(result.cast.count)")
        detailCache.set(key: cacheKey, value: result)
        probe("getMovieCredits cache store id=\(id)")
        return result
    }
    
    // MARK: - Get TV Show Credits (Cast)
    func getTVCredits(id: Int) async throws -> TMDBCreditsResponse {
        let cacheKey = "tvCredits_\(id)"
        if let cached: TMDBCreditsResponse = detailCache.get(key: cacheKey) {
            return cached
        }
        let urlString = "\(baseURL)/tv/\(id)/credits?api_key=\(apiKey)&language=\(currentLanguage)"
        guard let url = URL(string: urlString) else { throw TMDBError.invalidURL }
        let (data, _) = try await throttledData(from: url)
        let result = try JSONDecoder().decode(TMDBCreditsResponse.self, from: data)
        detailCache.set(key: cacheKey, value: result)
        return result
    }
    
    // MARK: - Get Movie Recommendations
    func getMovieRecommendations(id: Int) async throws -> [TMDBMovie] {
        probe("getMovieRecommendations start id=\(id)")
        let cacheKey = "movieRecs_\(id)"
        if let cached: [TMDBMovie] = detailCache.get(key: cacheKey) {
            probe("getMovieRecommendations cache hit id=\(id) count=\(cached.count)")
            return cached
        }
        probe("getMovieRecommendations cache miss id=\(id)")
        let urlString = "\(baseURL)/movie/\(id)/recommendations?api_key=\(apiKey)&language=\(currentLanguage)&page=1"
        guard let url = URL(string: urlString) else { throw TMDBError.invalidURL }
        probe("getMovieRecommendations request id=\(id)")
        let (data, httpResponse) = try await throttledData(from: url)
        let status = (httpResponse as? HTTPURLResponse)?.statusCode ?? -1
        probe("getMovieRecommendations response id=\(id) status=\(status) bytes=\(data.count)")
        probe("getMovieRecommendations decode start id=\(id)")
        let decodedResponse = try JSONDecoder().decode(TMDBMovieSearchResponse.self, from: data)
        probe("getMovieRecommendations decode done id=\(id) count=\(decodedResponse.results.count)")
        detailCache.set(key: cacheKey, value: decodedResponse.results)
        probe("getMovieRecommendations cache store id=\(id)")
        return decodedResponse.results
    }
    
    // MARK: - Get TV Show Recommendations
    func getTVRecommendations(id: Int) async throws -> [TMDBTVShow] {
        let cacheKey = "tvRecs_\(id)"
        if let cached: [TMDBTVShow] = detailCache.get(key: cacheKey) {
            return cached
        }
        let urlString = "\(baseURL)/tv/\(id)/recommendations?api_key=\(apiKey)&language=\(currentLanguage)&page=1"
        guard let url = URL(string: urlString) else { throw TMDBError.invalidURL }
        let (data, _) = try await throttledData(from: url)
        let response = try JSONDecoder().decode(TMDBTVSearchResponse.self, from: data)
        detailCache.set(key: cacheKey, value: response.results)
        return response.results
    }
}

// MARK: - Error Handling
enum TMDBError: Error, LocalizedError {
    case invalidURL
    case networkError(Error)
    case decodingError
    case missingAPIKey
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError:
            return "Failed to decode response"
        case .missingAPIKey:
            return "API key is missing. Please add your TMDB API key."
        }
    }
}

// MARK: - Rate Limiter

/// Actor-based concurrency limiter for TMDB API calls.
/// Limits concurrent in-flight requests and enforces a minimum interval between requests.
actor TMDBRateLimiter {
    private let maxConcurrent: Int
    private let minInterval: TimeInterval
    private var inFlight: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var lastRequestTime: Date = .distantPast

    init(maxConcurrent: Int, minInterval: TimeInterval) {
        self.maxConcurrent = maxConcurrent
        self.minInterval = minInterval
    }

    func execute<T>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await acquireSlot()
        defer { Task { await releaseSlot() } }
        return try await operation()
    }

    private func acquireSlot() async {
        while inFlight >= maxConcurrent {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        inFlight += 1

        // Enforce minimum interval
        let elapsed = Date().timeIntervalSince(lastRequestTime)
        if elapsed < minInterval {
            let delay = UInt64((minInterval - elapsed) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
        }
        lastRequestTime = Date()
    }

    private func releaseSlot() {
        inFlight -= 1
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}

// MARK: - Detail Cache

/// Thread-safe in-memory cache for TMDB detail responses.
/// Prevents duplicate network calls when multiple views fetch the same item (e.g. ContinueWatchingCards).
final class TMDBDetailCache: @unchecked Sendable {
    private var storage: [String: (value: Any, timestamp: Date)] = [:]
    private let lock = NSLock()
    private let ttl: TimeInterval = 300 // 5 minutes

    func get<T>(key: String) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = storage[key],
              Date().timeIntervalSince(entry.timestamp) < ttl,
              let value = entry.value as? T else {
            return nil
        }
        return value
    }

    func set(key: String, value: Any) {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = (value: value, timestamp: Date())

        // Evict old entries periodically
        if storage.count > 200 {
            let cutoff = Date().addingTimeInterval(-ttl)
            storage = storage.filter { $0.value.timestamp > cutoff }
        }
    }
}
