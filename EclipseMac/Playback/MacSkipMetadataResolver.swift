#if os(macOS)
import Foundation

@MainActor
enum MacSkipMetadataResolver {
    static func resolve(request: PlaybackRequest, duration: Double, defaults: UserDefaults,
                        isStillCurrent: () -> Bool) async -> [SkipSegment] {
        guard let media = request.mediaInfo, isStillCurrent() else { return [] }
        let id: Int
        let season: Int?
        let episode: Int?
        let title: String?
        let anime: Bool
        let movie: Bool
        switch media {
        case .movie(let movieID, let movieTitle, _, let isAnime):
            id = movieID; season = nil; episode = nil; title = movieTitle; anime = isAnime || request.isAnime; movie = true
        case .episode(let showID, let seasonNumber, let episodeNumber, let showTitle, _, let isAnime):
            id = showID; season = seasonNumber; episode = episodeNumber; title = showTitle; anime = isAnime || request.isAnime; movie = false
        }
        var segments: [SkipSegment] = []
        if (defaults.object(forKey: "aniSkipEnabled") as? Bool ?? true), anime, let episode,
           request.episodePlaybackContext?.supportsCanonicalEpisodeLookup != false {
            segments = await fetchAniSkipSegments(tmdbId: id, seasonNumber: season ?? 1,
                episodeNumber: episode, showTitle: title, duration: duration,
                animeProviderID: request.episodePlaybackContext?.anilistMediaId,
                skipAniListTraversal: PerformanceModeSettings.skipsAniListTraversalForAnimeDetails,
                isStillCurrent: isStillCurrent)
        }
        guard isStillCurrent() else { return [] }
        let tmdbSeason = request.episodePlaybackContext?.resolvedTMDBSeasonNumber ?? request.originalTMDBSeasonNumber ?? season
        let tmdbEpisode = request.episodePlaybackContext?.resolvedTMDBEpisodeNumber ?? request.originalTMDBEpisodeNumber ?? episode
        if segments.isEmpty, defaults.object(forKey: "introDBEnabled") as? Bool ?? true {
            segments = (try? await IntroDBService.shared.fetchSkipTimes(tmdbId: id,
                seasonNumber: tmdbSeason, episodeNumber: tmdbEpisode, episodeDuration: duration)) ?? []
        }
        guard isStillCurrent() else { return [] }
        if segments.isEmpty, defaults.object(forKey: "introDBAppEnabled") as? Bool ?? true {
            var imdb = request.imdbID
            if imdb == nil {
                if movie { imdb = try? await TMDBService.shared.getMovieDetails(id: id).imdbId }
                else { imdb = try? await TMDBService.shared.getTVShowDetails(id: id).externalIds?.imdbId }
            }
            guard isStillCurrent() else { return [] }
            if let imdb {
                let special = request.episodePlaybackContext?.isSpecial == true
                segments = (try? await IntroDBAppService.shared.fetchSkipTimes(imdbId: imdb,
                    seasonNumber: special ? tmdbSeason : season,
                    episodeNumber: special ? tmdbEpisode : episode, episodeDuration: duration)) ?? []
            }
        }
        guard isStillCurrent() else { return [] }
        return segments
    }

    private static func fetchAniSkipSegments(
        tmdbId: Int,
        seasonNumber: Int,
        episodeNumber: Int,
        showTitle: String?,
        duration: Double,
        animeProviderID: Int?,
        skipAniListTraversal: Bool,
        isStillCurrent: () -> Bool
    ) async -> [SkipSegment] {
        guard isStillCurrent() else { return [] }
        var animeProviderId = animeProviderID
        if let id = animeProviderId {
            Logger.shared.log("SkipData: AniSkip step 0 - playback context media ID \(id)", type: "Skip")
        }

        if animeProviderId == nil {
            animeProviderId = TrackerManager.shared.cachedAniListSeasonId(tmdbId: tmdbId, seasonNumber: seasonNumber)
            if let id = animeProviderId {
                Logger.shared.log("SkipData: AniSkip step 1 - cached season ID \(id)", type: "Skip")
            }
        }

        if animeProviderId == nil {
            animeProviderId = TrackerManager.shared.cachedAniListId(for: tmdbId)
            if let id = animeProviderId {
                Logger.shared.log("SkipData: AniSkip step 2 - cached show ID \(id)", type: "Skip")
            }
        }

        if animeProviderId == nil, !skipAniListTraversal, let title = showTitle {
            Logger.shared.log("SkipData: AniSkip step 3 - resolving via AniListService for '\(title)'", type: "Skip")
            do {
                let animeData = try await AniListService.shared.fetchAnimeDetailsWithEpisodes(
                    title: title,
                    tmdbShowId: tmdbId,
                    tmdbService: TMDBService.shared,
                    tmdbShowPoster: nil,
                    token: nil
                )
                guard isStillCurrent() else { return [] }
                let seasonMappings = animeData.seasons.map { (seasonNumber: $0.seasonNumber, anilistId: $0.anilistId) }
                TrackerManager.shared.registerAniListAnimeData(tmdbId: tmdbId, seasons: seasonMappings)
                animeProviderId = animeData.seasons.first(where: { $0.seasonNumber == seasonNumber })?.anilistId
            } catch {
                Logger.shared.log("SkipData: AniSkip step 3 failed: \(error.localizedDescription)", type: "Skip")
            }
        }

        if animeProviderId == nil, !skipAniListTraversal {
            animeProviderId = await TrackerManager.shared.getAniListMediaId(tmdbId: tmdbId)
        }

        guard isStillCurrent() else { return [] }
        guard let finalId = animeProviderId else {
            Logger.shared.log("SkipData: No anime provider ID found for tmdbId=\(tmdbId) - skipping AniSkip", type: "Skip")
            return []
        }

        let malId: Int
        if finalId < 0 {
            guard let exactMALID = RemoteMediaNumericBoundary.positiveMagnitude(finalId) else {
                return []
            }
            malId = exactMALID
            Logger.shared.log("SkipData: AniSkip using MAL fallback mediaId=\(malId)", type: "Skip")
        } else {
            let resolvedMALId: Int?
            if skipAniListTraversal {
                resolvedMALId = TrackerManager.shared.cachedMyAnimeListAnimeId(fromAniListId: finalId)
            } else {
                resolvedMALId = await TrackerManager.shared.resolveMyAnimeListAnimeId(fromAniListId: finalId)
            }
            guard isStillCurrent() else { return [] }
            guard let resolvedMALId else {
                Logger.shared.log("SkipData: AniSkip could not resolve MAL ID for AniList \(finalId)", type: "Skip")
                return []
            }
            malId = resolvedMALId
            Logger.shared.log("SkipData: AniSkip resolved AniList \(finalId) to MAL \(malId)", type: "Skip")
        }

        Logger.shared.log("SkipData: AniSkip using malId=\(malId) for ep=\(episodeNumber)", type: "Skip")

        do {
            return try await AniSkipService.shared.fetchSkipTimes(
                malId: malId,
                episodeNumber: episodeNumber,
                episodeDuration: duration
            )
        } catch {
            Logger.shared.log("SkipData: AniSkip fetch failed: \(error.localizedDescription)", type: "Error")
            return []
        }
    }

}
#endif
