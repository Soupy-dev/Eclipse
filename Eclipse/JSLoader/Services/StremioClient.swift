import Foundation

/// HTTP client for the Stremio addon protocol.
/// HTTP-only streams. Torrent-only streams are discarded.
final class StremioClient {
    static let shared = StremioClient()
    static let openSubtitlesV3BaseURL = "https://opensubtitles-v3.strem.io"

    private static let maximumStreamFetchAttempts = 2
    private static let maximumPlayableStreamsPerResponse = 300
    private static let maximumManifestResponseBytes = 1_000_000
    private static let maximumStreamResponseBytes = 10_000_000
    private static let maximumCatalogResponseBytes = 10_000_000
    private static let maximumMetaResponseBytes = 5_000_000
    private static let maximumSubtitleResponseBytes = 5_000_000
    private static let retryDelayNanoseconds: UInt64 = 400_000_000
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        session = URLSession(
            configuration: config,
            delegate: FetchDelegate(allowRedirects: true),
            delegateQueue: nil
        )
    }

    // MARK: - Fetch Manifest

    func fetchManifest(from url: String) async throws -> StremioManifest {
        guard let requestURL = Self.endpointURL(
            baseURL: url,
            appendingPercentEncodedPath: "/manifest.json"
        ),
              let scheme = requestURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            Logger.shared.log("Stremio: Invalid manifest URL", type: "Stremio")
            throw StremioError.invalidURL
        }
        let endpoint = Self.redactedEndpointDescription(for: requestURL)
        Logger.shared.log("Stremio: Fetching manifest from \(endpoint)", type: "Stremio")

        let (data, response) = try await boundedData(
            from: requestURL,
            maximumResponseBytes: Self.maximumManifestResponseBytes
        )
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            Logger.shared.log("Stremio: Manifest fetch failed HTTP \(code) from \(endpoint)", type: "Stremio")
            throw StremioError.httpError(code)
        }

        let manifest = try JSONDecoder().decode(StremioManifest.self, from: data)
        Logger.shared.log("Stremio: Manifest OK - id=\(manifest.id) name=\(manifest.name) resources=\(manifest.resources?.count ?? 0) idPrefixes=\(manifest.idPrefixes ?? [])", type: "Stremio")
        return manifest
    }

    // MARK: - Fetch Streams

    /// Fetches streams for a given addon and content ID.
    /// Only direct HTTP(S) streams are returned.
    func fetchStreams(
        baseURL: String,
        type: String,
        id: String,
        retryEmptyResponse: Bool = false
    ) async throws -> [StremioStream] {
        let encodedId = encodePathSegment(id, preservingColon: true)
        guard let url = Self.endpointURL(
            baseURL: baseURL,
            appendingPercentEncodedPath: "/stream/\(type)/\(encodedId).json"
        ) else {
            throw StremioError.invalidURL
        }

        let endpoint = Self.redactedEndpointDescription(for: url)
        let lookupID = String(UUID().uuidString.prefix(8))
        var lastError: Error?

        for attempt in 1...Self.maximumStreamFetchAttempts {
            try Task.checkCancellation()
            let startedAt = Date()
            var request = URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 15
            )
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

            Logger.shared.log(
                "Stremio: Stream lookup[\(lookupID)] attempt \(attempt)/\(Self.maximumStreamFetchAttempts) endpoint=\(endpoint) type=\(type) id=\(id)",
                type: "Stremio"
            )

            do {
                let (data, response) = try await boundedData(
                    for: request,
                    maximumResponseBytes: Self.maximumStreamResponseBytes
                )
                try Task.checkCancellation()

                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                let elapsed = Date().timeIntervalSince(startedAt)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    throw StremioError.httpError(statusCode)
                }
                let streamResponse = try JSONDecoder().decode(StremioStreamResponse.self, from: data)
                let allStreams = streamResponse.streams ?? []

                // Keep torrent-only streams out of playback.
                var safeStreams: [StremioStream] = []
                safeStreams.reserveCapacity(min(allStreams.count, Self.maximumPlayableStreamsPerResponse))
                var directHTTPCount = 0
                for stream in allStreams where stream.isDirectHTTP {
                    directHTTPCount += 1
                    if safeStreams.count < Self.maximumPlayableStreamsPerResponse {
                        safeStreams.append(stream)
                    }
                }
                let dropped = allStreams.count - directHTTPCount
                let truncated = max(directHTTPCount - safeStreams.count, 0)
                Logger.shared.log(
                    "Stremio: Stream lookup[\(lookupID)] HTTP \(statusCode) attempt=\(attempt) bytes=\(data.count) decoded=\(allStreams.count) playable=\(safeStreams.count) dropped=\(dropped) truncated=\(truncated) elapsed=\(String(format: "%.2f", elapsed))s",
                    type: "Stremio"
                )

#if os(tvOS)
                if safeStreams.isEmpty,
                   allStreams.contains(where: { stream in
                       let candidate = stream.url?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                       return stream.infoHash?.isEmpty == false
                           || candidate.hasPrefix("magnet:")
                           || (!candidate.isEmpty && !candidate.hasPrefix("http://") && !candidate.hasPrefix("https://"))
                   }) {
                    throw ServiceCompatibilityError.unsupportedTransport
                }
#endif

                if retryEmptyResponse,
                   Self.shouldRetryNoPlayableResponse(allStreams: allStreams, safeStreams: safeStreams),
                   attempt < Self.maximumStreamFetchAttempts {
                    Logger.shared.log(
                        "Stremio: Stream lookup[\(lookupID)] retrying one empty or diagnostic-only HTTP 200 response",
                        type: "Stremio"
                    )
                    try await Self.waitBeforeStreamRetry()
                    continue
                }

                return safeStreams
            } catch {
                if Task.isCancelled || Self.isCancellation(error) {
                    throw CancellationError()
                }

                lastError = error
                if attempt < Self.maximumStreamFetchAttempts,
                   let retryReason = Self.retryReason(for: error) {
                    Logger.shared.log(
                        "Stremio: Stream lookup[\(lookupID)] retrying after \(retryReason) from \(endpoint)",
                        type: "Stremio"
                    )
                    try await Self.waitBeforeStreamRetry()
                    continue
                }

                Logger.shared.log(
                    "Stremio: Stream lookup[\(lookupID)] failed endpoint=\(endpoint) attempt=\(attempt) error=\(Self.safeErrorDescription(error))",
                    type: "Stremio"
                )
                throw error
            }
        }

        throw lastError ?? StremioError.noStreams
    }

    // MARK: - Fetch Catalogs and Meta

    func fetchCatalogMetas(baseURL: String, catalog: StremioCatalog, searchQuery: String? = nil, skip: Int? = nil) async throws -> [StremioMetaPreview] {
        let encodedType = encodePathSegment(catalog.type, preservingColon: false)
        let encodedCatalogId = encodePathSegment(catalog.id, preservingColon: true)
        var extras: [String] = []
        if let skip {
            extras.append("skip=\(max(skip, 0))")
        }
        if let searchQuery {
            extras.append("search=\(encodeExtraValue(searchQuery))")
        }
        let extraPath = extras.isEmpty ? "" : "/\(extras.joined(separator: "&"))"
        guard let url = Self.endpointURL(
            baseURL: baseURL,
            appendingPercentEncodedPath: "/catalog/\(encodedType)/\(encodedCatalogId)\(extraPath).json"
        ) else {
            throw StremioError.invalidURL
        }
        let endpoint = Self.redactedEndpointDescription(for: url)

        Logger.shared.log("Stremio: Fetching catalog \(catalog.id) query='\(searchQuery ?? "nil")' skip=\(skip?.description ?? "nil") endpoint=\(endpoint)", type: "Stremio")

        let (data, response) = try await boundedData(
            from: url,
            maximumResponseBytes: Self.maximumCatalogResponseBytes
        )
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            Logger.shared.log("Stremio: Catalog fetch failed HTTP \(statusCode) catalog=\(catalog.id) query='\(searchQuery ?? "nil")' skip=\(skip?.description ?? "nil") endpoint=\(endpoint)", type: "Stremio")
            throw StremioError.httpError(statusCode)
        }

        do {
            let response = try JSONDecoder().decode(StremioCatalogResponse.self, from: data)
            Logger.shared.log("Stremio: Catalog \(catalog.id) returned \(response.metas.count) meta candidate(s)", type: "Stremio")
            return response.metas
        } catch {
            Logger.shared.log("Stremio: Catalog decode FAILED for \(catalog.id) endpoint=\(endpoint) bytes=\(data.count) error=\(Self.safeErrorDescription(error))", type: "Stremio")
            throw error
        }
    }

    func fetchMeta(baseURL: String, type: String, id: String) async throws -> StremioMetaPreview? {
        let encodedType = encodePathSegment(type, preservingColon: false)
        let encodedId = encodePathSegment(id, preservingColon: true)
        guard let url = Self.endpointURL(
            baseURL: baseURL,
            appendingPercentEncodedPath: "/meta/\(encodedType)/\(encodedId).json"
        ) else {
            throw StremioError.invalidURL
        }
        let endpoint = Self.redactedEndpointDescription(for: url)

        Logger.shared.log("Stremio: Fetching meta type=\(type) id=\(id) endpoint=\(endpoint)", type: "Stremio")

        let (data, response) = try await boundedData(
            from: url,
            maximumResponseBytes: Self.maximumMetaResponseBytes
        )
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            Logger.shared.log("Stremio: Meta fetch failed HTTP \(statusCode) type=\(type) id=\(id)", type: "Stremio")
            throw StremioError.httpError(statusCode)
        }

        do {
            let response = try JSONDecoder().decode(StremioMetaResponse.self, from: data)
            return response.meta
        } catch {
            Logger.shared.log("Stremio: Meta decode FAILED for id=\(id) endpoint=\(endpoint) bytes=\(data.count) error=\(Self.safeErrorDescription(error))", type: "Stremio")
            throw error
        }
    }

    // MARK: - Fetch Subtitles

    func fetchSubtitles(baseURL: String, type: String, id: String) async throws -> [StremioSubtitle] {
        let encodedType = encodePathSegment(type, preservingColon: false)
        let encodedId = encodePathSegment(id, preservingColon: true)
        guard let url = Self.endpointURL(
            baseURL: baseURL,
            appendingPercentEncodedPath: "/subtitles/\(encodedType)/\(encodedId).json"
        ) else {
            throw StremioError.invalidURL
        }
        let endpoint = Self.redactedEndpointDescription(for: url)

        Logger.shared.log("Stremio: Fetching subtitles - type=\(type) id=\(id) endpoint=\(endpoint)", type: "Stremio")

        let (data, response) = try await boundedData(
            from: url,
            maximumResponseBytes: Self.maximumSubtitleResponseBytes
        )
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            Logger.shared.log("Stremio: Subtitle fetch FAILED HTTP \(statusCode) endpoint=\(endpoint) type=\(type) id=\(id)", type: "Stremio")
            throw StremioError.httpError(statusCode)
        }

        let subtitleResponse: StremioSubtitleResponse
        do {
            subtitleResponse = try JSONDecoder().decode(StremioSubtitleResponse.self, from: data)
        } catch {
            Logger.shared.log("Stremio: Subtitle decode FAILED endpoint=\(endpoint) bytes=\(data.count) error=\(Self.safeErrorDescription(error))", type: "Stremio")
            throw error
        }

        let subtitles = (subtitleResponse.subtitles ?? []).filter { subtitle in
            guard let url = subtitle.url?.lowercased(), !url.isEmpty else { return false }
            return url.hasPrefix("http://") || url.hasPrefix("https://")
        }

        Logger.shared.log("Stremio: Got \(subtitles.count) HTTP subtitle(s) from \(endpoint)", type: "Stremio")
        return subtitles
    }

    func fetchOpenSubtitlesV3(tmdbId: Int, imdbId: String?, type: String, season: Int?, episode: Int?) async throws -> [StremioSubtitle] {
        let manifest = try await fetchManifest(from: Self.openSubtitlesV3BaseURL)
        guard manifest.supportsSubtitles else {
            Logger.shared.log("Stremio: OpenSubtitles v3 manifest does not advertise subtitles", type: "Stremio")
            return []
        }

        guard let contentId = buildContentId(
            tmdbId: tmdbId,
            imdbId: imdbId,
            type: type,
            season: season,
            episode: episode,
            idPrefixes: manifest.subtitleIdPrefixes,
            addonName: manifest.name
        ) else {
            Logger.shared.log("Stremio: OpenSubtitles v3 missing supported content ID", type: "Stremio")
            return []
        }

        return try await fetchSubtitles(
            baseURL: Self.openSubtitlesV3BaseURL,
            type: type,
            id: contentId
        )
    }

    // MARK: - Build Stremio Content ID

    /// Builds the Stremio content ID string for a given item.
    func buildContentId(tmdbId: Int, imdbId: String?, type: String, season: Int?, episode: Int?, addon: StremioAddon) -> String? {
        return buildContentIds(
            tmdbId: tmdbId,
            imdbId: imdbId,
            type: type,
            season: season,
            episode: episode,
            anilistId: nil,
            idPrefixes: addon.manifest.streamIdPrefixes,
            addonName: addon.manifest.name
        ).first
    }

    func buildContentId(tmdbId: Int, imdbId: String?, type: String, season: Int?, episode: Int?, anilistId: Int? = nil, anilistSeason: Int? = nil, anilistEpisode: Int? = nil, kitsuId: Int? = nil, kitsuEpisode: Int? = nil, alternateSeason: Int? = nil, alternateEpisode: Int? = nil, idPrefixes: [String]?, addonName: String) -> String? {
        buildContentIds(
            tmdbId: tmdbId,
            imdbId: imdbId,
            type: type,
            season: season,
            episode: episode,
            anilistId: anilistId,
            anilistSeason: anilistSeason,
            anilistEpisode: anilistEpisode,
            kitsuId: kitsuId,
            kitsuEpisode: kitsuEpisode,
            alternateSeason: alternateSeason,
            alternateEpisode: alternateEpisode,
            idPrefixes: idPrefixes,
            addonName: addonName
        ).first
    }

    func buildContentIds(tmdbId: Int, imdbId: String?, type: String, season: Int?, episode: Int?, anilistId: Int? = nil, anilistSeason: Int? = nil, anilistEpisode: Int? = nil, kitsuId: Int? = nil, kitsuEpisode: Int? = nil, alternateSeason: Int? = nil, alternateEpisode: Int? = nil, addon: StremioAddon) -> [String] {
        buildContentIds(
            tmdbId: tmdbId,
            imdbId: imdbId,
            type: type,
            season: season,
            episode: episode,
            anilistId: anilistId,
            anilistSeason: anilistSeason,
            anilistEpisode: anilistEpisode,
            kitsuId: kitsuId,
            kitsuEpisode: kitsuEpisode,
            alternateSeason: alternateSeason,
            alternateEpisode: alternateEpisode,
            idPrefixes: addon.manifest.streamIdPrefixes,
            addonName: addon.manifest.name
        )
    }

    func buildContentIds(tmdbId: Int, imdbId: String?, type: String, season: Int?, episode: Int?, anilistId: Int? = nil, anilistSeason: Int? = nil, anilistEpisode: Int? = nil, kitsuId: Int? = nil, kitsuEpisode: Int? = nil, alternateSeason: Int? = nil, alternateEpisode: Int? = nil, idPrefixes: [String]?, addonName: String) -> [String] {
        let prefixes = idPrefixes ?? []
        let normalizedPrefixes = prefixes.map { $0.lowercased() }
        let supportsTMDB = normalizedPrefixes.isEmpty || normalizedPrefixes.contains { $0 == "tmdb" || $0.hasPrefix("tmdb:") }
        let supportsIMDB = normalizedPrefixes.isEmpty || normalizedPrefixes.contains { $0 == "tt" || $0.hasPrefix("tt") || $0 == "imdb" || $0 == "imdb:" }
        let supportsIMDBNamespace = normalizedPrefixes.contains { $0 == "imdb:" }
        let supportsAniList = normalizedPrefixes.isEmpty || normalizedPrefixes.contains { $0 == "anilist" || $0 == "anilist:" }
        let supportsKitsu = normalizedPrefixes.isEmpty || normalizedPrefixes.contains { $0 == "kitsu" || $0 == "kitsu:" }

        let normalizedIMDbID = Self.normalizedIMDbID(imdbId)
        Logger.shared.log("Stremio: buildContentId addon=\(addonName) prefixes=\(prefixes) imdbId=\(normalizedIMDbID ?? "nil") tmdbId=\(tmdbId) anilistId=\(anilistId?.description ?? "nil") kitsuId=\(kitsuId?.description ?? "nil") type=\(type) s=\(season?.description ?? "nil") e=\(episode?.description ?? "nil") anilistS=\(anilistSeason?.description ?? "nil") anilistE=\(anilistEpisode?.description ?? "nil") kitsuE=\(kitsuEpisode?.description ?? "nil") altS=\(alternateSeason?.description ?? "nil") altE=\(alternateEpisode?.description ?? "nil")", type: "Stremio")
        var candidates: [String] = []
        let seriesTuples = contentIdSeriesTuples(
            type: type,
            season: season,
            episode: episode,
            alternateSeason: alternateSeason,
            alternateEpisode: alternateEpisode
        )

        // Prefer IMDB because it is the universal Stremio standard, then try TMDB too.
        if supportsIMDB, let ttId = normalizedIMDbID {
            if type == "series", !seriesTuples.isEmpty {
                for tuple in seriesTuples {
                    candidates.append("\(ttId):\(tuple.season):\(tuple.episode)")
                }
            } else {
                candidates.append(ttId)
            }

            if supportsIMDBNamespace {
                if type == "series", !seriesTuples.isEmpty {
                    for tuple in seriesTuples {
                        candidates.append("imdb:\(ttId):\(tuple.season):\(tuple.episode)")
                    }
                } else {
                    candidates.append("imdb:\(ttId)")
                }
            }
        }

        if supportsTMDB {
            if type == "series", !seriesTuples.isEmpty {
                for tuple in seriesTuples {
                    candidates.append("tmdb:\(tmdbId):\(tuple.season):\(tuple.episode)")
                }
            } else {
                candidates.append("tmdb:\(tmdbId)")
            }
        }

        if supportsAniList, let anilistId {
            if type == "series" {
                if let animeSeason = anilistSeason, let animeEpisode = anilistEpisode {
                    candidates.append("anilist:\(anilistId):\(animeSeason):\(animeEpisode)")
                }
                if let s = season, let e = episode {
                    candidates.append("anilist:\(anilistId):\(s):\(e)")
                }
            } else {
                candidates.append("anilist:\(anilistId)")
            }
        }

        if supportsKitsu, let kitsuId, kitsuId > 0 {
            if type == "series" {
                if let kitsuEpisode, kitsuEpisode > 0 {
                    candidates.append("kitsu:\(kitsuId):\(kitsuEpisode)")
                }
            } else {
                candidates.append("kitsu:\(kitsuId)")
            }
        }

        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0).inserted }
        if unique.isEmpty {
            Logger.shared.log("Stremio: No supported prefix for addon \(addonName)", type: "Stremio")
        } else {
            Logger.shared.log("Stremio: Content ID candidates for \(addonName): \(unique.joined(separator: ", "))", type: "Stremio")
        }
        return unique
    }

    private func contentIdSeriesTuples(type: String, season: Int?, episode: Int?, alternateSeason: Int?, alternateEpisode: Int?) -> [(season: Int, episode: Int)] {
        guard type == "series" else { return [] }
        var tuples: [(season: Int, episode: Int)] = []

        if let season, let episode {
            tuples.append((season, episode))
        }

        if let alternateSeason, let alternateEpisode {
            tuples.append((alternateSeason, alternateEpisode))
        }

        var seen = Set<String>()
        return tuples.filter { tuple in
            tuple.season > 0 &&
            tuple.episode > 0 &&
            seen.insert("\(tuple.season):\(tuple.episode)").inserted
        }
    }

    // MARK: - Helpers

    static func normalizedIMDbID(_ rawValue: String?) -> String? {
        guard var value = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !value.isEmpty else {
            return nil
        }

        if value.hasPrefix("imdb:") {
            value.removeFirst("imdb:".count)
        }

        if value.hasPrefix("tt") {
            value.removeFirst(2)
        }

        guard !value.isEmpty,
              value.allSatisfy(\.isNumber) else {
            return nil
        }
        // IMDb's older numeric IDs are seven digits and often have a leading zero.
        // Preserve their canonical form when an addon encoded imdb_id as a JSON number.
        if value.count < 7 {
            value = String(repeating: "0", count: 7 - value.count) + value
        }
        return "tt\(value)"
    }

    static func redactedEndpointDescription(from configuredURL: String) -> String {
        let normalized = normalizedConfiguredURL(from: configuredURL)
        guard let url = URL(string: normalized) else {
            return "<invalid endpoint>"
        }
        return redactedEndpointDescription(for: url)
    }

    private static func redactedEndpointDescription(for url: URL) -> String {
        guard let host = url.host, !host.isEmpty else {
            return "<invalid endpoint>"
        }
        let scheme = url.scheme?.lowercased() ?? "https"
        let portSuffix = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host.lowercased())\(portSuffix)"
    }

    private static func shouldRetryNoPlayableResponse(
        allStreams: [StremioStream],
        safeStreams: [StremioStream]
    ) -> Bool {
        guard safeStreams.isEmpty else { return false }
        if allStreams.isEmpty { return true }

        // Some addons report temporary upstream failures as a 200 response with
        // a display-only stream item (no URL or info hash). Retry that once, but
        // do not retry a legitimate torrent-only response that Eclipse filters.
        return allStreams.allSatisfy { stream in
            let url = stream.url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let infoHash = stream.infoHash?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return url.isEmpty && infoHash.isEmpty
        }
    }

    private func boundedData(
        for request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> (Data, URLResponse) {
        do {
            return try await session.boundedData(
                for: request,
                maximumResponseBytes: maximumResponseBytes
            )
        } catch is BoundedURLSessionError {
            throw ServiceCompatibilityError.responseTooLarge
        }
    }

    private func boundedData(
        from url: URL,
        maximumResponseBytes: Int
    ) async throws -> (Data, URLResponse) {
        try await boundedData(
            for: URLRequest(url: url),
            maximumResponseBytes: maximumResponseBytes
        )
    }

    private static func retryReason(for error: Error) -> String? {
        if let stremioError = error as? StremioError,
           case .httpError(let statusCode) = stremioError,
           [408, 425, 429, 500, 502, 503, 504].contains(statusCode) {
            return "transient HTTP \(statusCode)"
        }

        if error is DecodingError {
            return "an invalid temporary response"
        }

        guard let urlError = error as? URLError else { return nil }
        switch urlError.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .networkConnectionLost,
             .resourceUnavailable,
             .secureConnectionFailed,
             .cannotLoadFromNetwork:
            return "network error \(urlError.code.rawValue)"
        default:
            return nil
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    private static func safeErrorDescription(_ error: Error) -> String {
        if let compatibilityError = error as? ServiceCompatibilityError {
            return compatibilityError.localizedDescription
        }
        if let stremioError = error as? StremioError {
            return stremioError.localizedDescription
        }
        if let urlError = error as? URLError {
            return "network error \(urlError.code.rawValue)"
        }
        if error is DecodingError {
            return "invalid response format"
        }
        if error is CancellationError {
            return "cancelled"
        }
        return String(describing: type(of: error))
    }

    private static func waitBeforeStreamRetry() async throws {
        try await Task<Never, Never>.sleep(nanoseconds: retryDelayNanoseconds)
    }

    static func normalizedConfiguredURL(from url: String) -> String {
        var cleaned = url.trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.lowercased().hasPrefix("stremio://") {
            cleaned = "https://" + String(cleaned.dropFirst("stremio://".count))
        }

        guard var components = URLComponents(string: cleaned) else {
            return cleaned
        }

        var path = components.percentEncodedPath
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        if path == "/" {
            path = ""
        }
        if path.lowercased().hasSuffix("/manifest.json") {
            path.removeLast("/manifest.json".count)
        }
        components.percentEncodedPath = path
        return components.string ?? cleaned
    }

    /// Builds the provider's configuration page without ever exposing the
    /// configured URL to logs or visible diagnostics. URLComponents is used so
    /// a token-bearing query remains a query instead of becoming part of the
    /// appended path.
    static func configurationPageURL(from configuredURL: String) -> URL? {
        let normalized = normalizedConfiguredURL(from: configuredURL)
        guard var components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false else {
            return nil
        }

        var path = components.percentEncodedPath
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        if path == "/" {
            path = ""
        }
        if !path.lowercased().hasSuffix("/configure") {
            path += "/configure"
        }
        components.percentEncodedPath = path
        components.fragment = nil
        return components.url
    }

    private static func endpointURL(
        baseURL: String,
        appendingPercentEncodedPath suffix: String
    ) -> URL? {
        let normalized = normalizedConfiguredURL(from: baseURL)
        guard var components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false else {
            return nil
        }

        var path = components.percentEncodedPath
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        if path == "/" {
            path = ""
        }
        path += suffix.hasPrefix("/") ? suffix : "/\(suffix)"
        components.percentEncodedPath = path
        components.fragment = nil
        return components.url
    }

    private func encodePathSegment(_ value: String, preservingColon: Bool) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: ":/?#[]@!$&'()*+,;=")
        if preservingColon {
            allowed.insert(charactersIn: ":")
        }
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func encodeExtraValue(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)?
            .replacingOccurrences(of: "+", with: "%20") ?? value
    }

    enum StremioError: LocalizedError {
        case invalidURL
        case httpError(Int)
        case noStreams

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid Stremio addon URL"
            case .httpError(let code): return "HTTP error \(code)"
            case .noStreams: return "No streams available"
            }
        }
    }
}
