//
//  TMDBService.swift
//  Sora
//
//  Created by Francesco on 07/08/25.
//

import Foundation
import CoreGraphics
import ImageIO
#if canImport(zlib)
import zlib
#endif

actor TMDBPosterFingerprintCache {
    private var storage: [String: [UInt8]] = [:]
    private var insertionOrder: [String] = []
    private let limit = 512

    func fingerprint(for filePath: String) -> [UInt8]? {
        storage[filePath]
    }

    func store(_ fingerprint: [UInt8], for filePath: String) {
        if storage[filePath] == nil {
            insertionOrder.append(filePath)
        }
        storage[filePath] = fingerprint
        while insertionOrder.count > limit {
            let evicted = insertionOrder.removeFirst()
            storage.removeValue(forKey: evicted)
        }
    }
}

enum TMDBDiscoverFilterPolicy {
    static func hasMorePages(requestedPage: Int, totalPages: Int) -> Bool {
        requestedPage > 0 && requestedPage < totalPages
    }

    static func originCountryQueryValue(_ countryCodes: [String]) -> String? {
        let normalized = Set(countryCodes.compactMap { code -> String? in
            let value = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard value.count == 2, value.unicodeScalars.allSatisfy(CharacterSet.letters.contains) else {
                return nil
            }
            return value
        })
        guard !normalized.isEmpty else { return nil }
        return normalized.sorted().joined(separator: "|")
    }
}

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

    private let rateLimiter = TMDBRateLimiter(maxConcurrent: 4, minInterval: 0.05)

    private let detailCache = TMDBDetailCache()
    private let seasonRequestCoordinator = TMDBSeasonRequestCoordinator()
    private var fastAnimeAdultKeywordIDsCache: [Int]?
    private var fastAnimeAdultKeywordIDsTask: Task<[Int], Never>?

    private struct FastAnimeAdultKeywordCacheRecord: Codable {
        let version: Int
        let language: String
        let keywordNames: [String]
        let ids: [Int]
        let storedAt: TimeInterval
    }

    private struct FastAnimeAdultKeywordLookup: Sendable {
        let id: Int?
        let completed: Bool
    }

    private static let fastAnimeAdultKeywordCacheVersion = 1
    private static let fastAnimeAdultKeywordCacheKey = "tmdbFastAnimeAdultKeywordIDs.v1"
    private static let fastAnimeAdultKeywordCacheTTL: TimeInterval = 30 * 24 * 60 * 60
    private static let maximumJSONResponseBytes = 8 * 1_024 * 1_024

    private init() {}

    private var currentLanguage: String {
        return ProfileSettingsStore.active.string(forKey: "tmdbLanguage") ?? "en-US"
    }

    private func throttledData(from url: URL) async throws -> (Data, URLResponse) {
        guard !apiKey.isEmpty else {
            throw TMDBError.missingAPIKey
        }

        var configuredRequest = URLRequest(url: url)
        configuredRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        configuredRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let request = configuredRequest

        let result = try await rateLimiter.execute {
            try await URLSession.shared.boundedData(
                for: request,
                maximumResponseBytes: Self.maximumJSONResponseBytes
            )
        }
        let responseData = Self.normalizedResponseData(result.0, endpoint: url.path)
        guard responseData.count <= Self.maximumJSONResponseBytes else {
            throw BoundedURLSessionError.responseTooLarge(
                maximumBytes: Self.maximumJSONResponseBytes
            )
        }

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

    func searchMulti(query: String, maxPages: Int = 2) async throws -> [TMDBSearchResult] {
        guard !query.isEmpty else { return [] }

        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        var allResults: [TMDBSearchResult] = []

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

    func getMovieDetails(id: Int) async throws -> TMDBMovieDetail {

        let language = currentLanguage
        if let cached: TMDBMovieDetail = detailCache.get(key: "movie_\(id)_\(language)") {
            return cached
        }

        let urlString = "\(baseURL)/movie/\(id)?api_key=\(apiKey)&language=\(language)&append_to_response=release_dates"

        guard let url = URL(string: urlString) else {
            throw TMDBError.invalidURL
        }

        do {
            let (data, _) = try await throttledData(from: url)
            let movieDetail = try JSONDecoder().decode(TMDBMovieDetail.self, from: data)
            detailCache.set(key: "movie_\(id)_\(language)", value: movieDetail)
            return movieDetail
        } catch {
            throw TMDBError.networkError(error)
        }
    }

    func getTVShowDetails(id: Int) async throws -> TMDBTVShowDetail {
        guard RemoteMediaNumericBoundary.positiveIdentifier(id) != nil else {
            throw TMDBError.invalidURL
        }
        let language = currentLanguage
        let cacheKey = "tv_\(id)_\(language)"
        if let cached: TMDBTVShowDetail = detailCache.get(key: cacheKey),
           cached.isValidRemotePayload {
            return cached
        }

        let urlString = "\(baseURL)/tv/\(id)?api_key=\(apiKey)&language=\(language)&append_to_response=content_ratings,external_ids"

        guard let url = URL(string: urlString) else {
            throw TMDBError.invalidURL
        }

        do {
            let (data, _) = try await throttledData(from: url)
            let tvShowDetail = try JSONDecoder().decode(TMDBTVShowDetail.self, from: data)
            guard tvShowDetail.isValidRemotePayload else {
                throw TMDBError.decodingError
            }
            detailCache.set(key: cacheKey, value: tvShowDetail)
            return tvShowDetail
        } catch {
            throw TMDBError.networkError(error)
        }
    }

    func getTVShowWithSeasons(id: Int) async throws -> TMDBTVShowWithSeasons {
        guard RemoteMediaNumericBoundary.positiveIdentifier(id) != nil else {
            throw TMDBError.invalidURL
        }
        let language = currentLanguage
        let cacheKey = "tvWithSeasons_\(id)_\(language)"
        if let cached: TMDBTVShowWithSeasons = detailCache.get(key: cacheKey),
           cached.isValidRemotePayload {
            return cached
        }

        let urlString = "\(baseURL)/tv/\(id)?api_key=\(apiKey)&language=\(language)&append_to_response=content_ratings,external_ids"

        guard let url = URL(string: urlString) else {
            throw TMDBError.invalidURL
        }

        do {
            let (data, _) = try await throttledData(from: url)
            let tvShowDetail = try JSONDecoder().decode(TMDBTVShowWithSeasons.self, from: data)
            guard tvShowDetail.isValidRemotePayload else {
                throw TMDBError.decodingError
            }
            detailCache.set(key: cacheKey, value: tvShowDetail)
            return tvShowDetail
        } catch {
            throw TMDBError.networkError(error)
        }
    }

    func getSeasonDetails(tvShowId: Int, seasonNumber: Int) async throws -> TMDBSeasonDetail {
        guard RemoteMediaNumericBoundary.positiveIdentifier(tvShowId) != nil,
              RemoteMediaNumericBoundary.seasonNumber(seasonNumber, allowsZero: true) != nil else {
            throw TMDBError.invalidURL
        }
        let language = currentLanguage
        let cacheKey = "season_\(tvShowId)_\(seasonNumber)_\(language)"
        if let cached: TMDBSeasonDetail = detailCache.get(key: cacheKey),
           cached.isValidRemotePayload {
            return cached
        }
        return try await seasonRequestCoordinator.value(for: cacheKey) { [self] in
            if let cached: TMDBSeasonDetail = detailCache.get(key: cacheKey),
               cached.isValidRemotePayload {
                return cached
            }
            let urlString = "\(baseURL)/tv/\(tvShowId)/season/\(seasonNumber)?api_key=\(apiKey)&language=\(language)"
            guard let url = URL(string: urlString) else {
                throw TMDBError.invalidURL
            }

            do {
                let (data, _) = try await throttledData(from: url)
                let seasonDetail = try JSONDecoder().decode(TMDBSeasonDetail.self, from: data)
                guard seasonDetail.isValidRemotePayload,
                      seasonDetail.seasonNumber == seasonNumber else {
                    throw TMDBError.decodingError
                }
                detailCache.set(key: cacheKey, value: seasonDetail)
                return seasonDetail
            } catch {
                throw TMDBError.networkError(error)
            }
        }
    }

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

    func getTrending(mediaType: String = "all", timeWindow: String = "week", page: Int = 1) async throws -> [TMDBSearchResult] {
        let urlString = "\(baseURL)/trending/\(mediaType)/\(timeWindow)?api_key=\(apiKey)&language=\(currentLanguage)&page=\(page)&include_adult=false"

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

    func getUpcomingTVShows(page: Int = 1) async throws -> [TMDBTVShow] {
        let tomorrow = fastAnimeDateString(Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())
        let url = try tmdbURL(path: "/discover/tv", queryItems: [
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "sort_by", value: "popularity.desc"),
            URLQueryItem(name: "first_air_date.gte", value: tomorrow),
            URLQueryItem(name: "include_adult", value: "false")
        ])

        do {
            let (data, _) = try await throttledData(from: url)
            let response = try decodeTMDBListResponse(TMDBTVSearchResponse.self, from: data, endpoint: url.path)
            guard let tomorrowDate = fastAnimeDate(from: tomorrow) else {
                return response.results
            }

            return response.results.filter { show in
                guard let firstAirDate = fastAnimeDate(from: show.firstAirDate) else {
                    return false
                }
                return firstAirDate >= tomorrowDate
            }
        } catch {
            throw TMDBError.networkError(error)
        }
    }

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
        let countryResults = try await withThrowingTaskGroup(
            of: (Int, [TMDBTVShow]).self,
            returning: [(Int, [TMDBTVShow])].self
        ) { group in
            for (index, country) in Self.fastAnimeOriginCountries.enumerated() {
                group.addTask {
                    let shows = try await self.discoverFastAnimeShows(
                        originCountry: country,
                        originalLanguage: Self.fastAnimeOriginalLanguageByCountry[country],
                        sortBy: sortBy,
                        page: 1,
                        adultKeywordIDs: adultKeywordIDs,
                        extraQueryItems: extraQueryItems
                    )
                    return (index, shows)
                }
            }

            var loaded: [(Int, [TMDBTVShow])] = []
            loaded.reserveCapacity(Self.fastAnimeOriginCountries.count)
            do {
                for try await result in group {
                    loaded.append(result)
                }
                return loaded
            } catch {
                group.cancelAll()
                throw error
            }
        }

        let combined = countryResults
            .sorted { $0.0 < $1.0 }
            .flatMap { _, shows in
                shows.filter { self.isFastAnimeTVShow($0) }.map(\.asSearchResult)
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
        if let persisted = persistedFastAnimeAdultKeywordIDs() {
            fastAnimeAdultKeywordIDsCache = persisted
            return persisted
        }
        if let fastAnimeAdultKeywordIDsTask {
            return await fastAnimeAdultKeywordIDsTask.value
        }

        let cacheLanguage = currentLanguage
        let task = Task { [weak self] () -> [Int] in
            guard let self else { return [] }
            let result = await self.fetchFastAnimeAdultKeywordIDs()
            if result.completed, self.currentLanguage == cacheLanguage {
                self.persistFastAnimeAdultKeywordIDs(result.ids, language: cacheLanguage)
            }
            return result.ids
        }
        fastAnimeAdultKeywordIDsTask = task
        let ids = await task.value
        fastAnimeAdultKeywordIDsCache = ids
        fastAnimeAdultKeywordIDsTask = nil
        return ids
    }

    private func fetchFastAnimeAdultKeywordIDs() async -> (ids: [Int], completed: Bool) {
        await withTaskGroup(of: FastAnimeAdultKeywordLookup.self) { group in
            for keyword in Self.fastAnimeAdultKeywordNames {
                group.addTask { [weak self] in
                    guard let self else {
                        return FastAnimeAdultKeywordLookup(id: nil, completed: false)
                    }
                    return await self.fetchExactKeywordID(named: keyword)
                }
            }

            var ids = Set<Int>()
            var completedCount = 0
            for await lookup in group {
                if lookup.completed {
                    completedCount += 1
                }
                if let id = lookup.id {
                    ids.insert(id)
                }
            }
            return (ids.sorted(), completedCount == Self.fastAnimeAdultKeywordNames.count)
        }
    }

    private func fetchExactKeywordID(named keyword: String) async -> FastAnimeAdultKeywordLookup {
        do {
            let url = try tmdbURL(path: "/search/keyword", queryItems: [
                URLQueryItem(name: "query", value: keyword),
                URLQueryItem(name: "page", value: "1")
            ])
            let (data, _) = try await throttledData(from: url)
            let response = try JSONDecoder().decode(TMDBKeywordSearchResponse.self, from: data)
            let normalizedKeyword = Self.normalizedKeyword(keyword)
            let id = response.results.first { result in
                Self.normalizedKeyword(result.name) == normalizedKeyword
            }?.id
            return FastAnimeAdultKeywordLookup(id: id, completed: true)
        } catch {
            if case TMDBError.missingAPIKey = error {
                return FastAnimeAdultKeywordLookup(id: nil, completed: false)
            }
            Logger.shared.log(
                "TMDBService: fast anime keyword lookup failed for \(keyword): \(error.localizedDescription)",
                type: "TMDB"
            )
            return FastAnimeAdultKeywordLookup(id: nil, completed: false)
        }
    }

    private func persistedFastAnimeAdultKeywordIDs() -> [Int]? {
        guard let data = UserDefaults.standard.data(forKey: Self.fastAnimeAdultKeywordCacheKey),
              let record = try? JSONDecoder().decode(FastAnimeAdultKeywordCacheRecord.self, from: data),
              record.version == Self.fastAnimeAdultKeywordCacheVersion,
              record.language == currentLanguage,
              record.keywordNames == Self.fastAnimeAdultKeywordNames else {
            return nil
        }

        let age = Date().timeIntervalSince1970 - record.storedAt
        guard age >= 0, age <= Self.fastAnimeAdultKeywordCacheTTL else {
            return nil
        }
        return Array(Set(record.ids.filter { $0 > 0 })).sorted()
    }

    private func persistFastAnimeAdultKeywordIDs(_ ids: [Int], language: String) {
        let record = FastAnimeAdultKeywordCacheRecord(
            version: Self.fastAnimeAdultKeywordCacheVersion,
            language: language,
            keywordNames: Self.fastAnimeAdultKeywordNames,
            ids: Array(Set(ids.filter { $0 > 0 })).sorted(),
            storedAt: Date().timeIntervalSince1970
        )
        guard let data = try? JSONEncoder().encode(record) else { return }
        UserDefaults.standard.set(data, forKey: Self.fastAnimeAdultKeywordCacheKey)
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

    func keywordIDs(for keywordNames: [String]) async -> [String: Int] {
        let uniqueNames = Array(Set(keywordNames.filter { !$0.isEmpty })).sorted()
        guard !uniqueNames.isEmpty else { return [:] }

        return await withTaskGroup(of: (String, Int?).self) { group in
            for keywordName in uniqueNames {
                group.addTask { [weak self] in
                    guard let self else { return (keywordName, nil) }
                    let lookup = await self.fetchExactKeywordID(named: keywordName)
                    return (keywordName, lookup.id)
                }
            }

            var resolved: [String: Int] = [:]
            for await (keywordName, id) in group {
                if let id {
                    resolved[keywordName] = id
                }
            }
            return resolved
        }
    }

    func discoverMedia(
        mediaType: String,
        genreIds: [Int] = [],
        excludedGenreIds: [Int] = [],
        keywordIds: [Int] = [],
        excludedKeywordIds: [Int] = [],
        year: Int? = nil,
        originCountries: [String] = [],
        originalLanguage: String? = nil,
        sortBy: String = "popularity.desc",
        minimumVoteCount: Int? = nil,
        voteAverageGte: Double? = nil,
        page: Int = 1
    ) async throws -> (results: [TMDBSearchResult], hasMore: Bool) {
        let normalizedMediaType = mediaType == "tv" ? "tv" : "movie"
        var queryItems = [
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "sort_by", value: sortBy),
            URLQueryItem(name: "include_adult", value: "false")
        ]

        if !genreIds.isEmpty {
            let genreValue = genreIds.map(String.init).joined(separator: ",")
            queryItems.append(URLQueryItem(name: "with_genres", value: genreValue))
        }

        if !excludedGenreIds.isEmpty {
            let genreValue = excludedGenreIds.map(String.init).joined(separator: ",")
            queryItems.append(URLQueryItem(name: "without_genres", value: genreValue))
        }

        if !keywordIds.isEmpty {
            let keywordValue = keywordIds.map(String.init).joined(separator: ",")
            queryItems.append(URLQueryItem(name: "with_keywords", value: keywordValue))
        }

        if !excludedKeywordIds.isEmpty {
            let keywordValue = excludedKeywordIds.map(String.init).joined(separator: ",")
            queryItems.append(URLQueryItem(name: "without_keywords", value: keywordValue))
        }

        if let year {
            let yearKey = normalizedMediaType == "tv" ? "first_air_date_year" : "primary_release_year"
            queryItems.append(URLQueryItem(name: yearKey, value: "\(year)"))
        }

        if let originCountryValue = TMDBDiscoverFilterPolicy.originCountryQueryValue(originCountries) {
            queryItems.append(URLQueryItem(name: "with_origin_country", value: originCountryValue))
        }

        if let originalLanguage, !originalLanguage.isEmpty {
            queryItems.append(URLQueryItem(name: "with_original_language", value: originalLanguage))
        }

        if let minimumVoteCount {
            queryItems.append(URLQueryItem(name: "vote_count.gte", value: "\(minimumVoteCount)"))
        }

        if let voteAverageGte, voteAverageGte > 0 {
            queryItems.append(URLQueryItem(name: "vote_average.gte", value: "\(voteAverageGte)"))
        }

        let url = try tmdbURL(path: "/discover/\(normalizedMediaType)", queryItems: queryItems)
        let (data, _) = try await throttledData(from: url)

        if normalizedMediaType == "tv" {
            let response = try decodeTMDBListResponse(TMDBTVSearchResponse.self, from: data, endpoint: url.path)
            return (
                response.results.map(\.asSearchResult),
                TMDBDiscoverFilterPolicy.hasMorePages(requestedPage: page, totalPages: response.totalPages)
            )
        } else {
            let response = try decodeTMDBListResponse(TMDBMovieSearchResponse.self, from: data, endpoint: url.path)
            return (
                response.results.map(\.asSearchResult),
                TMDBDiscoverFilterPolicy.hasMorePages(requestedPage: page, totalPages: response.totalPages)
            )
        }
    }

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

    func discoverForKids(query: KidsDiscoverQuery, page: Int = 1) async throws -> [TMDBSearchResult] {
        guard var components = URLComponents(string: "\(baseURL)/discover/\(query.mediaType)") else {
            throw TMDBError.invalidURL
        }
        var items = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "language", value: currentLanguage),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "sort_by", value: query.sort.rawValue),
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "without_genres", value: KidsDiscoverQuery.excludedGenreIDs
                .map(String.init)
                .joined(separator: ","))
        ]
        if !query.genreIDs.isEmpty {
            items.append(URLQueryItem(
                name: "with_genres",
                value: query.genreIDs.map(String.init).joined(separator: query.genreMatch.rawValue)
            ))
        }
        if let ceiling = query.certificationCeiling, query.mediaType == "movie" {
            items.append(URLQueryItem(name: "certification_country", value: "US"))
            items.append(URLQueryItem(name: "certification.lte", value: ceiling))
        }
        if let minimumVoteCount = query.minimumVoteCount {
            items.append(URLQueryItem(name: "vote_count.gte", value: String(minimumVoteCount)))
        }
        components.queryItems = items

        guard let url = components.url else { throw TMDBError.invalidURL }
        let (data, _) = try await throttledData(from: url)
        if query.mediaType == "movie" {
            let response = try decodeTMDBListResponse(TMDBMovieSearchResponse.self, from: data, endpoint: url.path)
            return response.results.map {
                TMDBSearchResult(id: $0.id, mediaType: "movie", title: $0.title, name: nil, overview: $0.overview, posterPath: $0.posterPath, backdropPath: $0.backdropPath, releaseDate: $0.releaseDate, firstAirDate: nil, voteAverage: $0.voteAverage, popularity: $0.popularity, adult: $0.adult, genreIds: $0.genreIds, originalLanguage: $0.originalLanguage, originCountry: $0.originCountry)
            }
        }
        let response = try decodeTMDBListResponse(TMDBTVSearchResponse.self, from: data, endpoint: url.path)
        return response.results.map {
            TMDBSearchResult(id: $0.id, mediaType: "tv", title: nil, name: $0.name, overview: $0.overview, posterPath: $0.posterPath, backdropPath: $0.backdropPath, releaseDate: nil, firstAirDate: $0.firstAirDate, voteAverage: $0.voteAverage, popularity: $0.popularity, adult: $0.adult, genreIds: $0.genreIds)
        }
    }

    func discoverByNetwork(networkId: Int, page: Int = 1) async throws -> [TMDBSearchResult] {
        let urlString = "\(baseURL)/discover/tv?api_key=\(apiKey)&language=\(currentLanguage)&page=\(page)&with_networks=\(networkId)&sort_by=popularity.desc&include_adult=false"
        guard let url = URL(string: urlString) else { throw TMDBError.invalidURL }
        let (data, _) = try await throttledData(from: url)
        let response = try decodeTMDBListResponse(TMDBTVSearchResponse.self, from: data, endpoint: url.path)
        return response.results.map {
            TMDBSearchResult(id: $0.id, mediaType: "tv", title: nil, name: $0.name, overview: $0.overview, posterPath: $0.posterPath, backdropPath: $0.backdropPath, releaseDate: nil, firstAirDate: $0.firstAirDate, voteAverage: $0.voteAverage, popularity: $0.popularity, adult: $0.adult, genreIds: $0.genreIds)
        }
    }

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
            let (data, _) = try await throttledData(from: url)
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

    static let minimumAlternatePosterScore = 2.0
    static let tmdbThumbnailBaseURL = "https://image.tmdb.org/t/p/w92"
    private static let maximumAlternatePosterTwinDistance = 36.0
    private static let minimumAlternatePosterTwinSeparation = 20.0
    private static let alternatePosterComparisonLimit = 12
    private static let alternatePosterFingerprintWidth = 24
    private static let alternatePosterFingerprintHeight = 36
    private static let alternatePosterComparedRowFraction = 0.55
    private static let maximumAlternatePosterThumbnailBytes = 512 * 1024
    private static let maximumAlternatePosterSourceDimension: Int64 = 4_096
    private static let maximumAlternatePosterSourcePixels: Int64 = 8_000_000
    private static let alternatePosterHTTPClient = SkyStreamPinnedHTTPClient()
    private static let posterFingerprintCache = TMDBPosterFingerprintCache()

    func bestAlternatePoster(
        from images: TMDBImagesResponse,
        excluding posterPaths: [String?],
        matching primaryPosterPath: String?
    ) async -> TMDBImage? {
        let ranked = rankedAlternatePosters(from: images, excluding: posterPaths)
        guard let fallback = ranked.first else { return nil }
        guard let primaryPosterPath, ranked.count > 1 else { return fallback }
        guard let primaryFingerprint = await posterFingerprint(for: primaryPosterPath) else {
            return fallback
        }

        let compared = Array(ranked.prefix(Self.alternatePosterComparisonLimit))
        var distances: [(poster: TMDBImage, distance: Double)] = []
        await withTaskGroup(of: (Int, Double?).self) { group in
            for (index, poster) in compared.enumerated() {
                group.addTask {
                    guard let fingerprint = await self.posterFingerprint(for: poster.filePath) else {
                        return (index, nil)
                    }
                    return (index, Self.fingerprintDistance(primaryFingerprint, fingerprint))
                }
            }
            for await (index, distance) in group {
                guard let distance else { continue }
                distances.append((compared[index], distance))
            }
        }

        let ordered = distances.sorted { lhs, rhs in
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            return lhs.poster.filePath < rhs.poster.filePath
        }
        guard let closest = ordered.first,
              closest.distance <= Self.maximumAlternatePosterTwinDistance else {
            return fallback
        }
        guard ordered.count > 1 else { return closest.poster }
        let separation = ordered[1].distance - closest.distance
        guard separation >= Self.minimumAlternatePosterTwinSeparation else { return fallback }
        return closest.poster
    }

    private func posterFingerprint(for filePath: String) async -> [UInt8]? {
        if let cached = await Self.posterFingerprintCache.fingerprint(for: filePath) {
            return cached
        }
        guard let url = URL(string: "\(Self.tmdbThumbnailBaseURL)\(filePath)") else { return nil }
        guard let fetched = try? await Self.alternatePosterHTTPClient.fetch(
            url.absoluteString,
            purpose: .icon,
            allowsCookies: false,
            maximumRedirects: 4,
            maximumResponseBytes: Self.maximumAlternatePosterThumbnailBytes,
            timeout: 10
        ),
              (200...299).contains(fetched.response.statusCode),
              !fetched.data.isEmpty,
              !fetched.wasTruncated,
              let contentType = fetched.response.value(forHTTPHeaderField: "Content-Type")?
                .lowercased()
                .split(separator: ";", maxSplits: 1)
                .first,
              contentType.hasPrefix("image/"),
              fetched.data.count <= Self.maximumAlternatePosterThumbnailBytes,
              let fingerprint = Self.grayscaleFingerprint(from: fetched.data) else {
            return nil
        }
        await Self.posterFingerprintCache.store(fingerprint, for: filePath)
        return fingerprint
    }

    private static func grayscaleFingerprint(from data: Data) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              (1...4).contains(CGImageSourceGetCount(source)),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as NSDictionary?,
              let sourceWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let sourceHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
              sourceWidth > 0,
              sourceHeight > 0,
              sourceWidth <= maximumAlternatePosterSourceDimension,
              sourceHeight <= maximumAlternatePosterSourceDimension,
              sourceWidth <= maximumAlternatePosterSourcePixels / sourceHeight,
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 256,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary
              ),
              image.width > 0,
              image.height > 0 else {
            return nil
        }

        let croppedHeight = Int((Double(image.height) * alternatePosterComparedRowFraction).rounded())
        guard croppedHeight > 0,
              let cropped = image.cropping(
                  to: CGRect(x: 0, y: 0, width: image.width, height: croppedHeight)
              ) else {
            return nil
        }

        let width = alternatePosterFingerprintWidth
        let height = Int((Double(alternatePosterFingerprintHeight) * alternatePosterComparedRowFraction).rounded())
        guard height > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: width * height)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width,
                      space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? buffer : nil
    }

    private static func fingerprintDistance(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double? {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return nil }
        var total = 0
        for index in lhs.indices {
            total += abs(Int(lhs[index]) - Int(rhs[index]))
        }
        return Double(total) / Double(lhs.count)
    }

    func getBestAlternatePoster(
        from images: TMDBImagesResponse,
        excluding posterPaths: [String?]
    ) -> TMDBImage? {
        rankedAlternatePosters(from: images, excluding: posterPaths).first
    }

    func rankedAlternatePosters(
        from images: TMDBImagesResponse,
        excluding posterPaths: [String?]
    ) -> [TMDBImage] {
        let excludedPaths = Set(posterPaths.compactMap { $0 })
        let candidates = (images.posters ?? []).filter { poster in
            guard !excludedPaths.contains(poster.filePath),
                  poster.iso6391 == nil,
                  poster.width >= 500,
                  poster.height >= 750,
                  (0.6...0.75).contains(poster.aspectRatio) else {
                return false
            }
            return true
        }
        guard !candidates.isEmpty else { return [] }

        let endorsed = candidates.filter { poster in
            (poster.voteCount ?? 0) >= 1
                && (poster.voteAverage ?? 0) >= Self.minimumAlternatePosterScore
        }
        if !endorsed.isEmpty {
            return endorsed.sorted { lhs, rhs in
                let lhsAverage = lhs.voteAverage ?? 0
                let rhsAverage = rhs.voteAverage ?? 0
                if lhsAverage != rhsAverage { return lhsAverage > rhsAverage }
                let lhsVotes = lhs.voteCount ?? 0
                let rhsVotes = rhs.voteCount ?? 0
                if lhsVotes != rhsVotes { return lhsVotes > rhsVotes }
                return lhs.filePath < rhs.filePath
            }
        }

        return candidates.filter { ($0.voteCount ?? 0) == 0 }.sorted { lhs, rhs in
            let lhsPixels = lhs.width * lhs.height
            let rhsPixels = rhs.width * rhs.height
            if lhsPixels != rhsPixels { return lhsPixels > rhsPixels }
            return lhs.filePath < rhs.filePath
        }
    }

    func getMovieCredits(id: Int) async throws -> TMDBCreditsResponse {
        let cacheKey = "movieCredits_\(id)"
        if let cached: TMDBCreditsResponse = detailCache.get(key: cacheKey) {
            return cached
        }
        let urlString = "\(baseURL)/movie/\(id)/credits?api_key=\(apiKey)&language=\(currentLanguage)"
        guard let url = URL(string: urlString) else { throw TMDBError.invalidURL }
        let (data, _) = try await throttledData(from: url)
        let result = try JSONDecoder().decode(TMDBCreditsResponse.self, from: data)
        detailCache.set(key: cacheKey, value: result)
        return result
    }

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

    func getMovieRecommendations(id: Int) async throws -> [TMDBMovie] {
        let cacheKey = "movieRecs_\(id)_\(currentLanguage)"
        if let cached: [TMDBMovie] = detailCache.get(key: cacheKey) {
            return cached
        }
        let urlString = "\(baseURL)/movie/\(id)/recommendations?api_key=\(apiKey)&language=\(currentLanguage)&page=1"
        guard let url = URL(string: urlString) else { throw TMDBError.invalidURL }
        let (data, _) = try await throttledData(from: url)
        let decodedResponse = try decodeTMDBListResponse(TMDBMovieSearchResponse.self, from: data, endpoint: url.path)
        detailCache.set(key: cacheKey, value: decodedResponse.results)
        return decodedResponse.results
    }

    func getTVRecommendations(id: Int) async throws -> [TMDBTVShow] {
        let cacheKey = "tvRecs_\(id)_\(currentLanguage)"
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

actor TMDBRateLimiter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let maxConcurrent: Int
    private let minIntervalNanoseconds: UInt64
    private var inFlight: Int = 0
    private var waiters: [Waiter] = []
    private var nextAllowedStart: UInt64 = 0

    init(maxConcurrent: Int, minInterval: TimeInterval) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.minIntervalNanoseconds = UInt64(max(0, minInterval) * 1_000_000_000)
    }

    func execute<T>(_ operation: @Sendable () async throws -> T) async throws -> T {
        let waiterID = UUID()
        try await acquireSlot(waiterID: waiterID)
        do {
            try Task.checkCancellation()
            try await waitForStartPermission()
            try Task.checkCancellation()
        } catch {
            releaseSlot()
            throw error
        }

        defer { releaseSlot() }
        return try await operation()
    }

    private func acquireSlot(waiterID: UUID) async throws {
        try Task.checkCancellation()
        if inFlight < maxConcurrent {
            inFlight += 1
            return
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    private func waitForStartPermission() async throws {
        while true {
            try Task.checkCancellation()
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= nextAllowedStart {
                let next = now.addingReportingOverflow(minIntervalNanoseconds)
                nextAllowedStart = next.overflow ? UInt64.max : next.partialValue
                return
            }

            try await Task.sleep(nanoseconds: nextAllowedStart - now)
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func resumeNextWaiterIfPossible() {
        guard inFlight < maxConcurrent, !waiters.isEmpty else { return }
        let waiter = waiters.removeFirst()
        inFlight += 1
        waiter.continuation.resume()
    }

    private func releaseSlot() {
        if inFlight > 0 {
            inFlight -= 1
        }
        resumeNextWaiterIfPossible()
    }
}

private actor TMDBSeasonRequestCoordinator {
    private var inFlight: [String: Task<TMDBSeasonDetail, Error>] = [:]

    func value(
        for key: String,
        operation: @escaping () async throws -> TMDBSeasonDetail
    ) async throws -> TMDBSeasonDetail {
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let task = Task { try await operation() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
}

final class TMDBDetailCache: @unchecked Sendable {
    private var storage: [String: (value: Any, timestamp: Date)] = [:]
    private var accessOrder: [String] = []
    private let lock = NSLock()
    private let ttl: TimeInterval = 300
    private let maximumEntryCount = 128

    func get<T>(key: String) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = storage[key] else {
            return nil
        }
        guard Date().timeIntervalSince(entry.timestamp) < ttl else {
            remove(key)
            return nil
        }
        guard let value = entry.value as? T else { return nil }
        touch(key)
        return value
    }

    func set(key: String, value: Any) {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = (value: value, timestamp: Date())
        touch(key)
        evictIfNeeded()
    }

    private func touch(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func remove(_ key: String) {
        storage[key] = nil
        accessOrder.removeAll { $0 == key }
    }

    private func evictIfNeeded() {
        let cutoff = Date().addingTimeInterval(-ttl)
        let expiredKeys = storage.compactMap { entry in
            entry.value.timestamp < cutoff ? entry.key : nil
        }
        for key in expiredKeys {
            storage[key] = nil
        }
        if !expiredKeys.isEmpty {
            let expired = Set(expiredKeys)
            accessOrder.removeAll { expired.contains($0) }
        }

        while storage.count > maximumEntryCount,
              let oldest = accessOrder.first {
            storage[oldest] = nil
            accessOrder.removeFirst()
        }
    }
}
