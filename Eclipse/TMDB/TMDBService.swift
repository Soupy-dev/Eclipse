import Foundation
#if canImport(zlib)
import zlib
#endif

class TMDBService: ObservableObject {
    static let shared = TMDBService()
    
    static let tmdbBaseURL = "https://api.themoviedb.org/3"
    static let tmdbImageBaseURL = "https://image.tmdb.org/t/p/original"
    
    private var apiKey: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "TMDBAPIKey") as? String ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("$(") ? "" : trimmed
    }
    private let baseURL = tmdbBaseURL

    // MARK: - Rate Limiting
    private let rateLimiter = TMDBRateLimiter(maxConcurrent: 4, minInterval: 0.05)

    // MARK: - In-Memory Detail Cache (avoids duplicate fetches from ContinueWatchingCards etc.)
    private let detailCache = TMDBDetailCache()
    private var fastAnimeAdultKeywordIDsCache: [Int]?
    private var fastAnimeAdultKeywordIDsTask: Task<[Int], Never>?

    private init() {}
    
    private var currentLanguage: String {
        return UserDefaults.standard.string(forKey: "tmdbLanguage") ?? "en-US"
    }

    /// Throttled URL fetch - limits concurrent TMDB requests to avoid 429s
    private func throttledData(from url: URL) async throws -> (Data, URLResponse) {
        guard !apiKey.isEmpty else {
            throw TMDBError.missingAPIKey
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let result = try await rateLimiter.execute {
            try await URLSession.shared.data(for: request)
        }
        let responseData = Self.normalizedResponseData(result.0, endpoint: url.path)

        if let httpResponse = result.1 as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            let message = Self.errorMessage(from: responseData)
            Logger.shared.log("TMDBService: HTTP \(httpResponse.statusCode) path=\(url.path) message=\(message ?? "nil") bytes=\(responseData.count)", type: "Error")
            throw TMDBError.httpError(statusCode: httpResponse.statusCode, path: url.path, message: message)
        }

        return (responseData, result.1)
    }

    private static func errorMessage(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["status_message"] as? String {
            return message
        }

        guard let body = String(data: data, encoding: .utf8) else { return nil }
        let cleaned = body
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(180))
    }

    private func decodeTMDBListResponse<Response: Decodable>(
        _ type: Response.Type,
        from data: Data,
        endpoint: String
    ) throws -> Response {
        do {
            let response = try JSONDecoder().decode(type, from: data)
            logSkippedListResults(response, endpoint: endpoint)
            return response
        } catch {
            Logger.shared.log(
                "TMDBService: decode failed endpoint=\(endpoint) error=\(Self.decodeErrorDescription(error)) bytes=\(data.count) sample=\(Self.responseBodySample(from: data))",
                type: "Error"
            )
            throw error
        }
    }

    private func logSkippedListResults(_ response: Any, endpoint: String) {
        let skipped: Int
        let decoded: Int
        let total: Int

        switch response {
        case let response as TMDBSearchResponse:
            skipped = response.skippedResultCount
            decoded = response.results.count
            total = response.totalResults
        case let response as TMDBMovieSearchResponse:
            skipped = response.skippedResultCount
            decoded = response.results.count
            total = response.totalResults
        case let response as TMDBTVSearchResponse:
            skipped = response.skippedResultCount
            decoded = response.results.count
            total = response.totalResults
        default:
            return
        }

        guard skipped > 0 else { return }
        Logger.shared.log(
            "TMDBService: skipped malformed list results endpoint=\(endpoint) skipped=\(skipped) decoded=\(decoded) total=\(total)",
            type: "TMDB"
        )
    }

    private static func decodeErrorDescription(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return error.localizedDescription
        }

        switch decodingError {
        case .typeMismatch(let type, let context):
            return "type mismatch \(type) at \(codingPathDescription(context.codingPath)): \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return "value not found \(type) at \(codingPathDescription(context.codingPath)): \(context.debugDescription)"
        case .keyNotFound(let key, let context):
            return "key not found \(key.stringValue) at \(codingPathDescription(context.codingPath)): \(context.debugDescription)"
        case .dataCorrupted(let context):
            return "data corrupted at \(codingPathDescription(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func codingPathDescription(_ path: [CodingKey]) -> String {
        let pathDescription = path.map(\.stringValue).joined(separator: ".")
        return pathDescription.isEmpty ? "<root>" : pathDescription
    }

    private static func responseBodySample(from data: Data) -> String {
        let hex = data.prefix(16)
            .map { String(format: "%02X", $0) }
            .joined(separator: " ")

        let text = String(data: data.prefix(240), encoding: .utf8)?
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedText = text?.isEmpty == false ? text! : "<non-utf8>"
        let encodingHint: String
        if data.starts(with: [0x1f, 0x8b]) {
            encodingHint = "gzip"
        } else if data.starts(with: [0x78, 0x01]) || data.starts(with: [0x78, 0x9c]) || data.starts(with: [0x78, 0xda]) {
            encodingHint = "zlib"
        } else {
            encodingHint = "plain-or-unknown"
        }

        return "encodingHint=\(encodingHint) firstBytes=[\(hex)] textPrefix='\(String(cleanedText.prefix(180)))'"
    }

    private static func normalizedResponseData(_ data: Data, endpoint: String) -> Data {
        if data.starts(with: [0x1f, 0x8b]) {
            if let decompressed = inflateResponseData(data, windowBits: 15 + 16) {
                Logger.shared.log("TMDBService: decompressed gzip response endpoint=\(endpoint) compressedBytes=\(data.count) bytes=\(decompressed.count)", type: "TMDB")
                return decompressed
            }

            Logger.shared.log("TMDBService: gzip response decompression failed endpoint=\(endpoint) bytes=\(data.count)", type: "Error")
            return data
        }

        if data.starts(with: [0x78, 0x01]) || data.starts(with: [0x78, 0x9c]) || data.starts(with: [0x78, 0xda]) {
            if let decompressed = inflateResponseData(data, windowBits: 15) {
                Logger.shared.log("TMDBService: decompressed zlib response endpoint=\(endpoint) compressedBytes=\(data.count) bytes=\(decompressed.count)", type: "TMDB")
                return decompressed
            }

            Logger.shared.log("TMDBService: zlib response decompression failed endpoint=\(endpoint) bytes=\(data.count)", type: "Error")
        }

        return data
    }

    private static func inflateResponseData(_ data: Data, windowBits: Int32) -> Data? {
#if canImport(zlib)
        guard !data.isEmpty else { return data }

        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunkSize = 64 * 1024

        return data.withUnsafeBytes { rawBuffer -> Data? in
            guard let baseAddress = rawBuffer.bindMemory(to: Bytef.self).baseAddress else {
                return nil
            }

            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: baseAddress)
            stream.avail_in = uInt(data.count)

            var status: Int32 = Z_OK
            repeat {
                var chunk = [UInt8](repeating: 0, count: chunkSize)
                chunk.withUnsafeMutableBufferPointer { buffer in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    status = inflate(&stream, Z_NO_FLUSH)

                    if status == Z_OK || status == Z_STREAM_END {
                        let written = chunkSize - Int(stream.avail_out)
                        if let baseAddress = buffer.baseAddress, written > 0 {
                            output.append(baseAddress, count: written)
                        }
                    }
                }
            } while status == Z_OK

            return status == Z_STREAM_END ? output : nil
        }
#else
        return nil
#endif
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
                let response = try decodeTMDBListResponse(TMDBSearchResponse.self, from: data, endpoint: url.path)
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

    func findByIMDbId(_ imdbId: String, preferredMediaType: String? = nil) async throws -> TMDBSearchResult? {
        let trimmedId = imdbId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else { return nil }

        let encodedId = trimmedId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmedId
        let urlString = "\(baseURL)/find/\(encodedId)?api_key=\(apiKey)&language=\(currentLanguage)&external_source=imdb_id"

        guard let url = URL(string: urlString) else {
            throw TMDBError.invalidURL
        }

        do {
            let (data, _) = try await throttledData(from: url)
            let response = try JSONDecoder().decode(TMDBFindResponse.self, from: data)
            let preferred = preferredMediaType?.lowercased()

            if preferred == "movie", let movie = response.movieResults.first {
                return movie.asSearchResult
            }

            if preferred == "tv", let show = response.tvResults.first {
                return show.asSearchResult
            }

            if let movie = response.movieResults.first {
                return movie.asSearchResult
            }

            return response.tvResults.first?.asSearchResult
        } catch {
            throw TMDBError.networkError(error)
        }
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
            let response = try decodeTMDBListResponse(TMDBMovieSearchResponse.self, from: data, endpoint: url.path)
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
            let response = try decodeTMDBListResponse(TMDBTVSearchResponse.self, from: data, endpoint: url.path)
            return response.results
        } catch {
            throw TMDBError.networkError(error)
        }
    }
    
    // MARK: - Get Movie Details
    func getMovieDetails(id: Int) async throws -> TMDBMovieDetail {
        if let cached: TMDBMovieDetail = detailCache.get(key: "movie_\(id)") {
            return cached
        }

        let urlString = "\(baseURL)/movie/\(id)?api_key=\(apiKey)&language=\(currentLanguage)&append_to_response=release_dates"
        
        guard let url = URL(string: urlString) else {
            throw TMDBError.invalidURL
        }
        
        do {
            let (data, response) = try await throttledData(from: url)
            let movieDetail = try JSONDecoder().decode(TMDBMovieDetail.self, from: data)
            detailCache.set(key: "movie_\(id)", value: movieDetail)
            return movieDetail
        } catch {
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
            let response = try decodeTMDBListResponse(TMDBSearchResponse.self, from: data, endpoint: url.path)
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
            let response = try decodeTMDBListResponse(TMDBMovieSearchResponse.self, from: data, endpoint: url.path)
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
            let response = try decodeTMDBListResponse(TMDBMovieSearchResponse.self, from: data, endpoint: url.path)
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
            let response = try decodeTMDBListResponse(TMDBMovieSearchResponse.self, from: data, endpoint: url.path)
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
            let response = try decodeTMDBListResponse(TMDBTVSearchResponse.self, from: data, endpoint: url.path)
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
            let response = try decodeTMDBListResponse(TMDBTVSearchResponse.self, from: data, endpoint: url.path)
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
            let response = try decodeTMDBListResponse(TMDBTVSearchResponse.self, from: data, endpoint: url.path)
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
            let response = try decodeTMDBListResponse(TMDBMovieSearchResponse.self, from: data, endpoint: url.path)
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
            let response = try decodeTMDBListResponse(TMDBTVSearchResponse.self, from: data, endpoint: url.path)
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
            let response = try decodeTMDBListResponse(TMDBTVSearchResponse.self, from: data, endpoint: url.path)
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
            let response = try decodeTMDBListResponse(TMDBTVSearchResponse.self, from: data, endpoint: url.path)
            return response.results
        } catch {
            throw TMDBError.networkError(error)
        }
    }

    enum FastAnimeCatalogKind: String {
        case trending
        case popular
        case topRated
        case airing
        case upcoming
    }

    // MARK: - Fast Anime Catalogs (TMDB-native Performance Mode)
    func getFastAnimeCatalog(kind: FastAnimeCatalogKind, limit: Int = 20) async throws -> [TMDBSearchResult] {
        let adultKeywordIDs = await fastAnimeAdultKeywordIDs()
        let results: [TMDBSearchResult]
        switch kind {
        case .trending:
            results = try await getFastTrendingAnime(limit: limit, adultKeywordIDs: adultKeywordIDs)
        case .popular:
            results = try await getFastAnimeDiscoverCatalog(
                sortBy: "popularity.desc",
                limit: limit,
                adultKeywordIDs: adultKeywordIDs
            )
        case .topRated:
            results = try await getFastAnimeDiscoverCatalog(
                sortBy: "vote_average.desc",
                limit: limit,
                adultKeywordIDs: adultKeywordIDs,
                extraQueryItems: [URLQueryItem(name: "vote_count.gte", value: "100")]
            )
        case .airing:
            let today = fastAnimeDateString(Date())
            let start = fastAnimeDateString(Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date())
            let end = fastAnimeDateString(Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date())
            results = try await getFastAnimeDiscoverCatalog(
                sortBy: "popularity.desc",
                limit: limit,
                adultKeywordIDs: adultKeywordIDs,
                extraQueryItems: [
                    URLQueryItem(name: "air_date.gte", value: start),
                    URLQueryItem(name: "air_date.lte", value: end),
                    URLQueryItem(name: "with_status", value: "0")
                ]
            ).filter { result in
                guard let firstAirDate = fastAnimeDate(from: result.firstAirDate) else { return true }
                guard let todayDate = fastAnimeDate(from: today) else { return true }
                return firstAirDate <= todayDate
            }
        case .upcoming:
            let tomorrow = fastAnimeDateString(Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())
            results = try await getFastAnimeDiscoverCatalog(
                sortBy: "popularity.desc",
                limit: limit * 2,
                adultKeywordIDs: adultKeywordIDs,
                extraQueryItems: [URLQueryItem(name: "first_air_date.gte", value: tomorrow)]
            ).filter { result in
                guard let firstAirDate = fastAnimeDate(from: result.firstAirDate),
                      let tomorrowDate = fastAnimeDate(from: tomorrow) else {
                    return false
                }
                return firstAirDate >= tomorrowDate
            }
        }

        return Array(deduplicatedFastAnimeResults(results).prefix(limit))
    }

    private func getFastTrendingAnime(limit: Int, adultKeywordIDs: [Int]) async throws -> [TMDBSearchResult] {
        let trending = try await getTrending(mediaType: "tv", timeWindow: "week")
            .filter { self.isFastAnimeSearchResult($0) }
        guard trending.count < min(limit, 10) else {
            return Array(deduplicatedFastAnimeResults(trending).prefix(limit))
        }

        let fallback = try await getFastAnimeDiscoverCatalog(
            sortBy: "popularity.desc",
            limit: limit,
            adultKeywordIDs: adultKeywordIDs
        )
        return Array(deduplicatedFastAnimeResults(trending + fallback).prefix(limit))
    }

    private func getFastAnimeDiscoverCatalog(
        sortBy: String,
        limit: Int,
        adultKeywordIDs: [Int],
        extraQueryItems: [URLQueryItem] = []
    ) async throws -> [TMDBSearchResult] {
        var combined: [TMDBSearchResult] = []
        for country in Self.fastAnimeOriginCountries {
            let shows = try await discoverFastAnimeShows(
                originCountry: country,
                originalLanguage: Self.fastAnimeOriginalLanguageByCountry[country],
                sortBy: sortBy,
                page: 1,
                adultKeywordIDs: adultKeywordIDs,
                extraQueryItems: extraQueryItems
            )
            combined.append(contentsOf: shows.filter { self.isFastAnimeTVShow($0) }.map(\.asSearchResult))
        }
        return Array(deduplicatedFastAnimeResults(combined).prefix(limit))
    }

    private func discoverFastAnimeShows(
        originCountry: String,
        originalLanguage: String?,
        sortBy: String,
        page: Int,
        adultKeywordIDs: [Int],
        extraQueryItems: [URLQueryItem]
    ) async throws -> [TMDBTVShow] {
        var queryItems = [
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "with_genres", value: "16"),
            URLQueryItem(name: "with_origin_country", value: originCountry),
            URLQueryItem(name: "sort_by", value: sortBy),
            URLQueryItem(name: "include_adult", value: "false")
        ]
        if !adultKeywordIDs.isEmpty {
            queryItems.append(URLQueryItem(
                name: "without_keywords",
                value: adultKeywordIDs.map { String($0) }.joined(separator: "|")
            ))
        }
        if let originalLanguage {
            queryItems.append(URLQueryItem(name: "with_original_language", value: originalLanguage))
        }
        queryItems.append(contentsOf: extraQueryItems)
        let url = try tmdbURL(path: "/discover/tv", queryItems: queryItems)
        let (data, _) = try await throttledData(from: url)
        let response = try decodeTMDBListResponse(TMDBTVSearchResponse.self, from: data, endpoint: url.path)
        return response.results
    }

    private static let fastAnimeOriginCountries = ["JP", "CN", "KR", "TW"]
    private static let fastAnimeOriginalLanguageByCountry = [
        "JP": "ja",
        "CN": "zh",
        "KR": "ko",
        "TW": "zh"
    ]
    private static let fastAnimeOriginalLanguages: Set<String> = ["ja", "zh", "ko"]
    private static let fastAnimeAdultKeywordNames = [
        "adult animation",
        "adult anime",
        "adult cartoon",
        "adult film",
        "adult video",
        "ecchi",
        "ero anime",
        "eroge",
        "erotica",
        "erotic",
        "erotic animation",
        "erotic anime",
        "explicit sex",
        "explicit sexual",
        "female nudity",
        "hentai",
        "mature anime",
        "mild nudity",
        "nudity",
        "ova hentai",
        "pornographic",
        "pornography",
        "r 18",
        "r18",
        "sex comedy",
        "sexual content",
        "sexually explicit",
        "softcore",
        "uncensored"
    ]

    private func isFastAnimeTVShow(_ show: TMDBTVShow) -> Bool {
        guard show.genreIds?.contains(16) == true else { return false }
        guard Self.allowsFastAnimeOriginalLanguage(show.originalLanguage) else { return false }
        if let originCountry = show.originCountry, !originCountry.isEmpty {
            return originCountry.contains { Self.fastAnimeOriginCountries.contains($0) }
        }
        if let originalLanguage = show.originalLanguage?.lowercased(), !originalLanguage.isEmpty {
            return Self.fastAnimeOriginalLanguages.contains(originalLanguage)
        }
        return true
    }

    private func isFastAnimeSearchResult(_ result: TMDBSearchResult) -> Bool {
        guard result.mediaType == "tv",
              result.genreIds?.contains(16) == true else {
            return false
        }
        guard Self.allowsFastAnimeOriginalLanguage(result.originalLanguage) else { return false }
        if let originCountry = result.originCountry, !originCountry.isEmpty {
            return originCountry.contains { Self.fastAnimeOriginCountries.contains($0) }
        }
        if let originalLanguage = result.originalLanguage?.lowercased(), !originalLanguage.isEmpty {
            return Self.fastAnimeOriginalLanguages.contains(originalLanguage)
        }
        return false
    }

    private static func allowsFastAnimeOriginalLanguage(_ language: String?) -> Bool {
        guard let language = language?.lowercased(), !language.isEmpty else {
            return true
        }
        return fastAnimeOriginalLanguages.contains(language)
    }

    private func deduplicatedFastAnimeResults(_ results: [TMDBSearchResult]) -> [TMDBSearchResult] {
        var seen = Set<Int>()
        return results.filter { result in
            guard !result.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            return seen.insert(result.id).inserted
        }
    }

    private func fastAnimeAdultKeywordIDs() async -> [Int] {
        if let fastAnimeAdultKeywordIDsCache {
            return fastAnimeAdultKeywordIDsCache
        }
        if let fastAnimeAdultKeywordIDsTask {
            return await fastAnimeAdultKeywordIDsTask.value
        }

        let task = Task { [weak self] () -> [Int] in
            guard let self else { return [] }
            return await self.fetchFastAnimeAdultKeywordIDs()
        }
        fastAnimeAdultKeywordIDsTask = task
        let ids = await task.value
        fastAnimeAdultKeywordIDsCache = ids
        fastAnimeAdultKeywordIDsTask = nil
        return ids
    }

    private func fetchFastAnimeAdultKeywordIDs() async -> [Int] {
        await withTaskGroup(of: Int?.self) { group in
            for keyword in Self.fastAnimeAdultKeywordNames {
                group.addTask { [weak self] in
                    await self?.fetchExactKeywordID(named: keyword)
                }
            }

            var ids = Set<Int>()
            for await id in group {
                if let id {
                    ids.insert(id)
                }
            }
            return ids.sorted()
        }
    }

    private func fetchExactKeywordID(named keyword: String) async -> Int? {
        do {
            let url = try tmdbURL(path: "/search/keyword", queryItems: [
                URLQueryItem(name: "query", value: keyword),
                URLQueryItem(name: "page", value: "1")
            ])
            let (data, _) = try await throttledData(from: url)
            let response = try JSONDecoder().decode(TMDBKeywordSearchResponse.self, from: data)
            let normalizedKeyword = Self.normalizedKeyword(keyword)
            return response.results.first { result in
                Self.normalizedKeyword(result.name) == normalizedKeyword
            }?.id
        } catch {
            if case TMDBError.missingAPIKey = error {
                return nil
            }
            Logger.shared.log(
                "TMDBService: fast anime keyword lookup failed for \(keyword): \(error.localizedDescription)",
                type: "TMDB"
            )
            return nil
        }
    }

    private static func normalizedKeyword(_ keyword: String) -> String {
        keyword
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func tmdbURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(string: "\(baseURL)\(path)") else {
            throw TMDBError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "language", value: currentLanguage)
        ] + queryItems
        guard let url = components.url else {
            throw TMDBError.invalidURL
        }
        return url
    }

    private func fastAnimeDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func fastAnimeDate(from value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
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
            let response = try decodeTMDBListResponse(TMDBMovieSearchResponse.self, from: data, endpoint: url.path)
            return response.results.map {
                TMDBSearchResult(id: $0.id, mediaType: "movie", title: $0.title, name: nil, overview: $0.overview, posterPath: $0.posterPath, backdropPath: $0.backdropPath, releaseDate: $0.releaseDate, firstAirDate: nil, voteAverage: $0.voteAverage, popularity: $0.popularity, adult: $0.adult, genreIds: $0.genreIds)
            }
        } else {
            let response = try decodeTMDBListResponse(TMDBTVSearchResponse.self, from: data, endpoint: url.path)
            return response.results.map {
                TMDBSearchResult(id: $0.id, mediaType: "tv", title: nil, name: $0.name, overview: $0.overview, posterPath: $0.posterPath, backdropPath: $0.backdropPath, releaseDate: nil, firstAirDate: $0.firstAirDate, voteAverage: $0.voteAverage, popularity: $0.popularity, adult: $0.adult, genreIds: $0.genreIds)
            }
        }
    }
    
    // MARK: - Discover by Network
    func discoverByNetwork(networkId: Int, page: Int = 1) async throws -> [TMDBSearchResult] {
        let urlString = "\(baseURL)/discover/tv?api_key=\(apiKey)&language=\(currentLanguage)&page=\(page)&with_networks=\(networkId)&sort_by=popularity.desc&include_adult=false"
        guard let url = URL(string: urlString) else { throw TMDBError.invalidURL }
        let (data, _) = try await throttledData(from: url)
        let response = try decodeTMDBListResponse(TMDBTVSearchResponse.self, from: data, endpoint: url.path)
        return response.results.map {
            TMDBSearchResult(id: $0.id, mediaType: "tv", title: nil, name: $0.name, overview: $0.overview, posterPath: $0.posterPath, backdropPath: $0.backdropPath, releaseDate: nil, firstAirDate: $0.firstAirDate, voteAverage: $0.voteAverage, popularity: $0.popularity, adult: $0.adult, genreIds: $0.genreIds)
        }
    }
    
    // MARK: - Discover by Company
    func discoverByCompany(companyId: Int, mediaType: String = "movie", page: Int = 1) async throws -> [TMDBSearchResult] {
        let urlString = "\(baseURL)/discover/\(mediaType)?api_key=\(apiKey)&language=\(currentLanguage)&page=\(page)&with_companies=\(companyId)&sort_by=popularity.desc&include_adult=false"
        guard let url = URL(string: urlString) else { throw TMDBError.invalidURL }
        let (data, _) = try await throttledData(from: url)
        if mediaType == "movie" {
            let response = try decodeTMDBListResponse(TMDBMovieSearchResponse.self, from: data, endpoint: url.path)
            return response.results.map {
                TMDBSearchResult(id: $0.id, mediaType: "movie", title: $0.title, name: nil, overview: $0.overview, posterPath: $0.posterPath, backdropPath: $0.backdropPath, releaseDate: $0.releaseDate, firstAirDate: nil, voteAverage: $0.voteAverage, popularity: $0.popularity, adult: $0.adult, genreIds: $0.genreIds)
            }
        } else {
            let response = try decodeTMDBListResponse(TMDBTVSearchResponse.self, from: data, endpoint: url.path)
            return response.results.map {
                TMDBSearchResult(id: $0.id, mediaType: "tv", title: nil, name: $0.name, overview: $0.overview, posterPath: $0.posterPath, backdropPath: $0.backdropPath, releaseDate: nil, firstAirDate: $0.firstAirDate, voteAverage: $0.voteAverage, popularity: $0.popularity, adult: $0.adult, genreIds: $0.genreIds)
            }
        }
    }
    
    // MARK: - Get Images (Backdrops, Logos, Posters)
    func getMovieImages(id: Int, preferredLanguage: String? = nil) async throws -> TMDBImagesResponse {
        let langCode = (preferredLanguage ?? currentLanguage).components(separatedBy: "-").first ?? "en"
        let cacheKey = "movieImages_\(id)_\(langCode)"
        if let cached: TMDBImagesResponse = detailCache.get(key: cacheKey) {
            return cached
        }

        let urlString = "\(baseURL)/movie/\(id)/images?api_key=\(apiKey)&include_image_language=\(langCode),en,null"
        
        guard let url = URL(string: urlString) else {
            throw TMDBError.invalidURL
        }
        
        do {
            let (data, httpResponse) = try await throttledData(from: url)
            let decodedResponse = try JSONDecoder().decode(TMDBImagesResponse.self, from: data)
            detailCache.set(key: cacheKey, value: decodedResponse)
            return decodedResponse
        } catch {
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

    func getMovieVideos(id: Int) async throws -> [TMDBVideo] {
        let cacheKey = "movieVideos_\(id)_\(currentLanguage)"
        if let cached: [TMDBVideo] = detailCache.get(key: cacheKey) {
            return cached
        }

        let urlString = "\(baseURL)/movie/\(id)/videos?api_key=\(apiKey)&language=\(currentLanguage)"
        guard let url = URL(string: urlString) else { throw TMDBError.invalidURL }
        do {
            let (data, _) = try await throttledData(from: url)
            let response = try JSONDecoder().decode(TMDBVideosResponse.self, from: data)
            let sorted = response.results.sorted { lhs, rhs in
                if (lhs.official ?? false) != (rhs.official ?? false) {
                    return (lhs.official ?? false) && !(rhs.official ?? false)
                }
                if lhs.type.lowercased() != rhs.type.lowercased() {
                    return lhs.type.lowercased() == "trailer"
                }
                return (lhs.publishedAt ?? "") > (rhs.publishedAt ?? "")
            }
            detailCache.set(key: cacheKey, value: sorted)
            return sorted
        } catch {
            throw TMDBError.networkError(error)
        }
    }

    func getTVShowVideos(id: Int) async throws -> [TMDBVideo] {
        let cacheKey = "tvVideos_\(id)_\(currentLanguage)"
        if let cached: [TMDBVideo] = detailCache.get(key: cacheKey) {
            return cached
        }

        let urlString = "\(baseURL)/tv/\(id)/videos?api_key=\(apiKey)&language=\(currentLanguage)"
        guard let url = URL(string: urlString) else { throw TMDBError.invalidURL }
        do {
            let (data, _) = try await throttledData(from: url)
            let response = try JSONDecoder().decode(TMDBVideosResponse.self, from: data)
            let sorted = response.results.sorted { lhs, rhs in
                if (lhs.official ?? false) != (rhs.official ?? false) {
                    return (lhs.official ?? false) && !(rhs.official ?? false)
                }
                if lhs.type.lowercased() != rhs.type.lowercased() {
                    return lhs.type.lowercased() == "trailer"
                }
                return (lhs.publishedAt ?? "") > (rhs.publishedAt ?? "")
            }
            detailCache.set(key: cacheKey, value: sorted)
            return sorted
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
        let cacheKey = "movieCredits_\(id)"
        if let cached: TMDBCreditsResponse = detailCache.get(key: cacheKey) {
            return cached
        }
        let urlString = "\(baseURL)/movie/\(id)/credits?api_key=\(apiKey)&language=\(currentLanguage)"
        guard let url = URL(string: urlString) else { throw TMDBError.invalidURL }
        let (data, response) = try await throttledData(from: url)
        let result = try JSONDecoder().decode(TMDBCreditsResponse.self, from: data)
        detailCache.set(key: cacheKey, value: result)
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
        let cacheKey = "movieRecs_\(id)"
        if let cached: [TMDBMovie] = detailCache.get(key: cacheKey) {
            return cached
        }
        let urlString = "\(baseURL)/movie/\(id)/recommendations?api_key=\(apiKey)&language=\(currentLanguage)&page=1"
        guard let url = URL(string: urlString) else { throw TMDBError.invalidURL }
        let (data, httpResponse) = try await throttledData(from: url)
        let decodedResponse = try decodeTMDBListResponse(TMDBMovieSearchResponse.self, from: data, endpoint: url.path)
        detailCache.set(key: cacheKey, value: decodedResponse.results)
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
        let response = try decodeTMDBListResponse(TMDBTVSearchResponse.self, from: data, endpoint: url.path)
        detailCache.set(key: cacheKey, value: response.results)
        return response.results
    }
}

private struct TMDBKeywordSearchResponse: Decodable {
    let results: [TMDBKeyword]
}

private struct TMDBKeyword: Decodable {
    let id: Int
    let name: String
}

// MARK: - Error Handling
enum TMDBError: Error, LocalizedError {
    case invalidURL
    case networkError(Error)
    case decodingError
    case missingAPIKey
    case httpError(statusCode: Int, path: String, message: String?)
    
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
        case .httpError(let statusCode, let path, let message):
            if let message, !message.isEmpty {
                return "TMDB request failed (\(statusCode)) for \(path): \(message)"
            }
            return "TMDB request failed (\(statusCode)) for \(path)"
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
