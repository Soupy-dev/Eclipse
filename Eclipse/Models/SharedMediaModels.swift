import Foundation

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
        self.mediaType = mediaType.lowercased()
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.playbackContext = playbackContext
        self.isAnime = isAnime
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = normalizedTitle?.isEmpty == false ? String(normalizedTitle!.prefix(120)) : nil
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
        tmdbID = try container.decode(Int.self, forKey: .tmdbID)
        mediaType = try container.decode(String.self, forKey: .mediaType).lowercased()
        seasonNumber = try container.decodeIfPresent(Int.self, forKey: .seasonNumber)
        episodeNumber = try container.decodeIfPresent(Int.self, forKey: .episodeNumber)
        playbackContext = try container.decodeIfPresent(EpisodePlaybackContext.self, forKey: .playbackContext)
        isAnime = try container.decodeIfPresent(Bool.self, forKey: .isAnime) ?? false
        title = try container.decodeIfPresent(String.self, forKey: .title)
    }

    var stableKey: String? {
        guard tmdbID > 0 else { return nil }
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
