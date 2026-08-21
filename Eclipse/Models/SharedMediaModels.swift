import Foundation
import Darwin

/// Reads user-visible stores without allowing a sparse file, symlink, FIFO, or
/// concurrently replaced file to turn a small JSON decode into an unbounded
/// allocation. Callers deliberately treat every error as "unreadable" and
/// leave the original bytes in place.
enum BoundedLocalStoreReader {
    enum ReadError: LocalizedError, Equatable {
        case invalidLimit
        case unavailable
        case nonRegularFile
        case fileChangedDuringOpen
        case tooLarge(maximumBytes: Int)

        var errorDescription: String? {
            switch self {
            case .invalidLimit:
                return "The local-store byte limit is invalid."
            case .unavailable:
                return "The local store could not be inspected."
            case .nonRegularFile:
                return "The local store is not a regular file."
            case .fileChangedDuringOpen:
                return "The local store changed while it was being opened."
            case .tooLarge(let maximumBytes):
                return "The local store exceeds the \(maximumBytes)-byte limit."
            }
        }
    }

    static func read(from url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0, maximumBytes < Int.max else {
            throw ReadError.invalidLimit
        }
        guard url.isFileURL else { throw ReadError.nonRegularFile }

        var pathMetadata = stat()
        let inspected: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &pathMetadata)
        }
        guard inspected == 0 else { throw ReadError.unavailable }
        guard pathMetadata.st_mode & S_IFMT == S_IFREG else {
            throw ReadError.nonRegularFile
        }
        guard pathMetadata.st_size >= 0,
              UInt64(pathMetadata.st_size) <= UInt64(maximumBytes) else {
            throw ReadError.tooLarge(maximumBytes: maximumBytes)
        }

        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.open(
                path,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw ReadError.fileChangedDuringOpen
        }
        defer { Darwin.close(descriptor) }

        var openedMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0 else {
            throw ReadError.unavailable
        }
        guard openedMetadata.st_mode & S_IFMT == S_IFREG else {
            throw ReadError.nonRegularFile
        }
        guard openedMetadata.st_dev == pathMetadata.st_dev,
              openedMetadata.st_ino == pathMetadata.st_ino else {
            throw ReadError.fileChangedDuringOpen
        }
        guard openedMetadata.st_size >= 0,
              UInt64(openedMetadata.st_size) <= UInt64(maximumBytes) else {
            throw ReadError.tooLarge(maximumBytes: maximumBytes)
        }

        var data = Data()
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            var chunk = [UInt8](repeating: 0, count: min(64 * 1_024, remaining))
            let bytesRead = chunk.withUnsafeMutableBytes { buffer -> Int in
                Darwin.read(descriptor, buffer.baseAddress, buffer.count)
            }
            if bytesRead == 0 { break }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw ReadError.fileChangedDuringOpen
            }
            data.append(contentsOf: chunk.prefix(bytesRead))
        }
        guard data.count <= maximumBytes else {
            throw ReadError.tooLarge(maximumBytes: maximumBytes)
        }

        var finalOpenedMetadata = stat()
        guard fstat(descriptor, &finalOpenedMetadata) == 0,
              finalOpenedMetadata.st_mode & S_IFMT == S_IFREG,
              finalOpenedMetadata.st_dev == openedMetadata.st_dev,
              finalOpenedMetadata.st_ino == openedMetadata.st_ino,
              finalOpenedMetadata.st_size >= 0,
              finalOpenedMetadata.st_size == openedMetadata.st_size,
              UInt64(finalOpenedMetadata.st_size) <= UInt64(maximumBytes),
              UInt64(finalOpenedMetadata.st_size) == UInt64(data.count) else {
            throw ReadError.fileChangedDuringOpen
        }

        var finalPathMetadata = stat()
        let reinspected: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &finalPathMetadata)
        }
        guard reinspected == 0,
              finalPathMetadata.st_mode & S_IFMT == S_IFREG,
              finalPathMetadata.st_dev == openedMetadata.st_dev,
              finalPathMetadata.st_ino == openedMetadata.st_ino else {
            throw ReadError.fileChangedDuringOpen
        }
        return data
    }
}

/// The shared wire/storage policy for search history. This lives in a source
/// file compiled by both app targets because SearchView is shared with tvOS,
/// while BackupManager itself is intentionally iOS-only.
struct BackupSearchHistory: Codable {
    static let maximumEncodedBytes = 64 * 1_024
    static let maximumQueryUTF8Bytes = 256
    static let maximumQueryCount = 10

    var queries: [String] = []
    var wasCaptured: Bool = false

    private enum CodingKeys: String, CodingKey {
        case queries
        case wasCaptured
    }

    init(queries: [String] = [], wasCaptured: Bool = false) {
        self.queries = Self.sanitizedQueries(queries)
        self.wasCaptured = wasCaptured
    }

    init(from decoder: Decoder) throws {
        if let values = try? [String](from: decoder) {
            queries = Self.sanitizedQueries(values)
            wasCaptured = true
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedQueries = try? container.decode([String].self, forKey: .queries)
        let decodedCaptureFlag = try? container.decode(Bool.self, forKey: .wasCaptured)
        queries = Self.sanitizedQueries(decodedQueries ?? [])
        // A flag cannot promote an omitted/null query payload into an
        // authoritative empty history. An explicit [] remains authoritative.
        wasCaptured = decodedQueries != nil && decodedCaptureFlag == true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(queries, forKey: .queries)
        try container.encode(wasCaptured, forKey: .wasCaptured)
    }

    init(jsonValue: Any?) {
        if let values = jsonValue as? [String] {
            self.init(queries: values, wasCaptured: true)
            return
        }

        if let dictionary = jsonValue as? [String: Any],
           let values = dictionary["queries"] as? [String] {
            self.init(queries: values, wasCaptured: dictionary["wasCaptured"] as? Bool ?? false)
            return
        }

        self.init()
    }

    static func decodedQueries(from data: Data) -> [String]? {
        guard data.count <= maximumEncodedBytes,
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return sanitizedQueries(decoded)
    }

    static func sanitizedQueries(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let bounded = utf8SafePrefix(trimmed, maximumBytes: maximumQueryUTF8Bytes)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bounded.isEmpty,
                  !result.contains(where: { $0.caseInsensitiveCompare(bounded) == .orderedSame }) else {
                continue
            }
            result.append(bounded)
            if result.count == maximumQueryCount { break }
        }
        return result
    }

    private static func utf8SafePrefix(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var result = ""
        var byteCount = 0
        for character in value {
            let characterString = String(character)
            let characterBytes = characterString.utf8.count
            guard byteCount + characterBytes <= maximumBytes else { break }
            result.append(character)
            byteCount += characterBytes
        }
        return result
    }
}

enum LocalNotificationMediaSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case anime
    case western

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anime: return "Anime"
        case .western: return "Western"
        }
    }
}

struct WatchTogetherMediaDescriptor: Codable, Equatable, Sendable {
    let tmdbID: Int
    let mediaType: String
    let seasonNumber: Int?
    let episodeNumber: Int?
    let playbackContext: EpisodePlaybackContext?
    let isAnime: Bool
    let title: String?

    init(
        tmdbID: Int,
        mediaType: String,
        seasonNumber: Int?,
        episodeNumber: Int?,
        playbackContext: EpisodePlaybackContext? = nil,
        isAnime: Bool = false,
        title: String? = nil
    ) {
        self.tmdbID = tmdbID
        self.mediaType = mediaType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.playbackContext = playbackContext
        self.isAnime = isAnime
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = normalizedTitle.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) }
    }

    private enum CodingKeys: String, CodingKey {
        case tmdbID
        case mediaType
        case seasonNumber
        case episodeNumber
        case playbackContext
        case isAnime
        case title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let candidate = Self(
            tmdbID: try container.decode(Int.self, forKey: .tmdbID),
            mediaType: try container.decode(String.self, forKey: .mediaType),
            seasonNumber: try container.decodeIfPresent(Int.self, forKey: .seasonNumber),
            episodeNumber: try container.decodeIfPresent(Int.self, forKey: .episodeNumber),
            playbackContext: try container.decodeIfPresent(
                EpisodePlaybackContext.self,
                forKey: .playbackContext
            ),
            isAnime: try container.decodeIfPresent(Bool.self, forKey: .isAnime) ?? false,
            title: try container.decodeIfPresent(String.self, forKey: .title)
        )
        guard let sanitized = candidate.sanitizedForTransport else {
            throw DecodingError.dataCorruptedError(
                forKey: .tmdbID,
                in: container,
                debugDescription: "Watch Together media identity or episode coordinates are invalid."
            )
        }
        self = sanitized
    }

    var sanitizedForTransport: WatchTogetherMediaDescriptor? {
        guard transportFieldsAreValid else { return nil }
        return Self(
            tmdbID: tmdbID,
            mediaType: mediaType,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            playbackContext: playbackContext,
            isAnime: isAnime,
            title: title
        )
    }

    private var transportFieldsAreValid: Bool {
        guard ProgressPersistencePolicy.validPositiveIdentifier(tmdbID) else { return false }
        switch mediaType {
        case "movie":
            return seasonNumber == nil && episodeNumber == nil && playbackContext == nil
        case "tv":
            guard seasonNumber.map({
                (0...ProgressPersistencePolicy.maximumCoordinate).contains($0)
            }) ?? true,
            episodeNumber.map({
                (1...ProgressPersistencePolicy.maximumCoordinate).contains($0)
            }) ?? true,
            playbackContext.map({
                ProgressPersistencePolicy.sanitizedPlaybackContext($0) == $0
            }) ?? true else {
                return false
            }
            let hasAnimeIdentity = playbackContext?.hasAnimeMediaId == true
            if isAnime || hasAnimeIdentity {
                return hasAnimeIdentity
            }
            guard let seasonNumber, let episodeNumber else { return false }
            return seasonNumber > 0 && episodeNumber > 0
        default:
            return false
        }
    }

    var stableKey: String? {
        guard transportFieldsAreValid else { return nil }
        switch mediaType {
        case "movie":
            return "movie:\(tmdbID)"
        case "tv":
            if isAnime || playbackContext?.hasAnimeMediaId == true {
                guard let context = playbackContext, context.hasAnimeMediaId else { return nil }
                let episodeIdentity: String
                if let kitsuID = context.kitsuMediaId {
                    episodeIdentity = "kitsu:\(kitsuID):\(context.localEpisodeNumber)"
                } else if let tmdbSeason = context.resolvedTMDBSeasonNumber,
                          let tmdbEpisode = context.resolvedTMDBEpisodeNumber {
                    episodeIdentity = "tmdb:\(tmdbSeason):\(tmdbEpisode)"
                } else if let providerID = context.positiveAniListMediaId
                    ?? context.anilistMediaId {
                    episodeIdentity = "provider:\(providerID):\(context.localEpisodeNumber)"
                } else {
                    return nil
                }
                return "anime-episode:\(tmdbID):\(episodeIdentity)"
            }
            guard let seasonNumber, let episodeNumber, seasonNumber > 0, episodeNumber > 0 else {
                return nil
            }
            return "episode:\(tmdbID):\(seasonNumber):\(episodeNumber)"
        default:
            return nil
        }
    }

    var localSeasonNumber: Int? {
        playbackContext?.localSeasonNumber ?? seasonNumber
    }

    var localEpisodeNumber: Int? {
        playbackContext?.localEpisodeNumber ?? episodeNumber
    }

    var animeContextFailureReason: String? {
        guard isAnime, mediaType == "tv" else { return nil }
        guard let playbackContext else {
            return "This anime episode has no anime playback context. Watch Together stopped instead of guessing an episode. Reopen it from the anime episode list and try again."
        }
        guard playbackContext.hasAnimeMediaId else {
            return "This anime episode has no AniList or Kitsu identity. Watch Together stopped instead of falling back to TMDB. Enable full anime detail metadata, reopen the episode, and try again."
        }
        return nil
    }

    func isSameLogicalMedia(as other: WatchTogetherMediaDescriptor) -> Bool {
        guard tmdbID == other.tmdbID, mediaType == other.mediaType else { return false }
        if mediaType == "movie" { return true }
        guard mediaType == "tv" else { return false }

        let lhsIsAnime = isAnime || playbackContext?.hasAnimeMediaId == true
        let rhsIsAnime = other.isAnime || other.playbackContext?.hasAnimeMediaId == true
        if lhsIsAnime || rhsIsAnime {
            guard lhsIsAnime,
                  rhsIsAnime,
                  let lhs = playbackContext,
                  let rhs = other.playbackContext else {
                return false
            }
            return AnimeEpisodeIdentityPolicy.isSameEpisode(lhs, rhs)
        }

        return seasonNumber == other.seasonNumber
            && episodeNumber == other.episodeNumber
    }
}
