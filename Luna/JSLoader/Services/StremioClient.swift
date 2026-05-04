//
//  StremioClient.swift
//  Luna
//
//  Created by Soupy on 2026.
//

import Foundation

/// HTTP client for the Stremio addon protocol.
/// SAFETY: Only returns streams with direct HTTP(S) URLs. Torrent-only streams are discarded.
final class StremioClient {
    static let shared = StremioClient()
    static let openSubtitlesV3BaseURL = "https://opensubtitles-v3.strem.io"

    private let session: URLSession
    private let decoder = JSONDecoder()

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)
    }

    // MARK: - Fetch Manifest

    func fetchManifest(from url: String) async throws -> StremioManifest {
        let manifestURL = normalizeManifestURL(url)
        Logger.shared.log("Stremio: Fetching manifest from \(manifestURL)", type: "Stremio")
        guard let requestURL = URL(string: manifestURL) else {
            Logger.shared.log("Stremio: Invalid manifest URL: \(manifestURL)", type: "Stremio")
            throw StremioError.invalidURL
        }

        let (data, response) = try await session.data(from: requestURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            Logger.shared.log("Stremio: Manifest fetch failed HTTP \(code) from \(manifestURL)", type: "Stremio")
            throw StremioError.httpError(code)
        }

        let manifest = try decoder.decode(StremioManifest.self, from: data)
        Logger.shared.log("Stremio: Manifest OK — id=\(manifest.id) name=\(manifest.name) resources=\(manifest.resources?.count ?? 0) idPrefixes=\(manifest.idPrefixes ?? [])", type: "Stremio")
        return manifest
    }

    // MARK: - Fetch Streams

    /// Fetches streams for a given addon and content ID.
    /// **SAFETY**: Only returns streams with direct HTTP(S) URLs. Any torrent-only entry is stripped.
    func fetchStreams(baseURL: String, type: String, id: String) async throws -> [StremioStream] {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL

        // Remove /manifest.json suffix if present
        let cleanBase: String
        if base.hasSuffix("/manifest.json") {
            cleanBase = String(base.dropLast("/manifest.json".count))
        } else {
            cleanBase = base
        }

        let urlString = "\(cleanBase)/stream/\(type)/\(id).json"
        guard let url = URL(string: urlString) else {
            throw StremioError.invalidURL
        }

        Logger.shared.log("Stremio: Fetching streams — type=\(type) id=\(id) url=\(urlString)", type: "Stremio")

        let (data, response) = try await session.data(from: url)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        Logger.shared.log("Stremio: Stream response HTTP \(statusCode) from \(cleanBase)", type: "Stremio")
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            Logger.shared.log("Stremio: Stream fetch FAILED HTTP \(statusCode) — base=\(cleanBase) type=\(type) id=\(id)", type: "Stremio")
            throw StremioError.httpError(statusCode)
        }

        let streamResponse: StremioStreamResponse
        do {
            streamResponse = try decoder.decode(StremioStreamResponse.self, from: data)
        } catch {
            // Log partial body so we can diagnose format mismatches
            let preview = String(data: data.prefix(512), encoding: .utf8) ?? "<binary>"
            Logger.shared.log("Stremio: Decode FAILED for \(cleanBase) — \(error.localizedDescription) body=\(preview)", type: "Stremio")
            throw error
        }
        let allStreams = streamResponse.streams ?? []

        if allStreams.isEmpty, let preview = String(data: data.prefix(512), encoding: .utf8) {
            Logger.shared.log("Stremio: 0 streams decoded from \(cleanBase) — body=\(preview)", type: "Stremio")
        }

        // SAFETY: Filter out any stream that is NOT a direct HTTP(S) link.
        // This ensures NO torrent (infoHash-only) streams ever reach the user.
        let safeStreams = allStreams.filter { $0.isDirectHTTP }

        let dropped = allStreams.count - safeStreams.count
        if dropped > 0 {
            Logger.shared.log("Stremio: Dropped \(dropped) non-HTTP stream(s) (torrent/infoHash only)", type: "Stremio")
        }

        Logger.shared.log("Stremio: Got \(safeStreams.count) safe HTTP stream(s) from \(cleanBase)", type: "Stremio")
        return safeStreams
    }

    // MARK: - Fetch Subtitles

    func fetchSubtitles(baseURL: String, type: String, id: String) async throws -> [StremioSubtitle] {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL

        let cleanBase: String
        if base.hasSuffix("/manifest.json") {
            cleanBase = String(base.dropLast("/manifest.json".count))
        } else {
            cleanBase = base
        }

        guard let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(cleanBase)/subtitles/\(type)/\(encodedId).json") else {
            throw StremioError.invalidURL
        }

        Logger.shared.log("Stremio: Fetching subtitles - type=\(type) id=\(id) url=\(url.absoluteString)", type: "Stremio")

        let (data, response) = try await session.data(from: url)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            Logger.shared.log("Stremio: Subtitle fetch FAILED HTTP \(statusCode) - base=\(cleanBase) type=\(type) id=\(id)", type: "Stremio")
            throw StremioError.httpError(statusCode)
        }

        let subtitleResponse: StremioSubtitleResponse
        do {
            subtitleResponse = try decoder.decode(StremioSubtitleResponse.self, from: data)
        } catch {
            let preview = String(data: data.prefix(512), encoding: .utf8) ?? "<binary>"
            Logger.shared.log("Stremio: Subtitle decode FAILED for \(cleanBase) - \(error.localizedDescription) body=\(preview)", type: "Stremio")
            throw error
        }

        let subtitles = (subtitleResponse.subtitles ?? []).filter { subtitle in
            guard let url = subtitle.url?.lowercased(), !url.isEmpty else { return false }
            return url.hasPrefix("http://") || url.hasPrefix("https://")
        }

        Logger.shared.log("Stremio: Got \(subtitles.count) HTTP subtitle(s) from \(cleanBase)", type: "Stremio")
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
            idPrefixes: manifest.idPrefixes,
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
    /// - Parameters:
    ///   - tmdbId: The TMDB ID
    ///   - imdbId: The IMDB ID (tt-prefixed string), if available
    ///   - type: "movie" or "series"
    ///   - season: Season number (for series only)
    ///   - episode: Episode number (for series only)
    ///   - addon: The addon to build the ID for (checks idPrefixes)
    /// - Returns: The single best content ID to use for this addon
    func buildContentId(tmdbId: Int, imdbId: String?, type: String, season: Int?, episode: Int?, addon: StremioAddon) -> String? {
        return buildContentId(
            tmdbId: tmdbId,
            imdbId: imdbId,
            type: type,
            season: season,
            episode: episode,
            idPrefixes: addon.manifest.idPrefixes,
            addonName: addon.manifest.name
        )
    }

    func buildContentId(tmdbId: Int, imdbId: String?, type: String, season: Int?, episode: Int?, idPrefixes: [String]?, addonName: String) -> String? {
        let prefixes = idPrefixes ?? []
        let supportsTMDB = prefixes.isEmpty || prefixes.contains("tmdb") || prefixes.contains("tmdb:")
        let supportsIMDB = prefixes.isEmpty || prefixes.contains("tt")

        Logger.shared.log("Stremio: buildContentId addon=\(addonName) prefixes=\(prefixes) imdbId=\(imdbId ?? "nil") tmdbId=\(tmdbId) type=\(type) s=\(season?.description ?? "nil") e=\(episode?.description ?? "nil")", type: "Stremio")

        // Prefer IMDB — it is the universal Stremio standard and avoids extra requests
        if supportsIMDB, let imdb = imdbId, !imdb.isEmpty {
            let ttId = imdb.hasPrefix("tt") ? imdb : "tt\(imdb)"
            var result: String
            if type == "series", let s = season, let e = episode {
                result = "\(ttId):\(s):\(e)"
            } else {
                result = ttId
            }
            Logger.shared.log("Stremio: Using IMDB content ID: \(result)", type: "Stremio")
            return result
        }

        // Fall back to tmdb: only when no IMDB ID is available
        if supportsTMDB {
            var result: String
            if type == "series", let s = season, let e = episode {
                result = "tmdb:\(tmdbId):\(s):\(e)"
            } else {
                result = "tmdb:\(tmdbId)"
            }
            Logger.shared.log("Stremio: No IMDB ID, falling back to TMDB content ID: \(result)", type: "Stremio")
            return result
        }

        Logger.shared.log("Stremio: No supported prefix for addon \(addonName)", type: "Stremio")
        return nil
    }

    // MARK: - Helpers

    /// Normalizes a user-provided URL to point to manifest.json
    private func normalizeManifestURL(_ url: String) -> String {
        var cleaned = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasSuffix("/") { cleaned = String(cleaned.dropLast()) }

        if cleaned.hasSuffix("/manifest.json") {
            return cleaned
        }

        return "\(cleaned)/manifest.json"
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
