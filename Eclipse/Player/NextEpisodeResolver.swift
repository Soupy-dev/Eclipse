import Foundation

struct NextEpisodeSeed: Equatable {
    let showID: Int
    let currentSeasonNumber: Int
    let currentEpisodeNumber: Int
    let showTitle: String
    let mediaYear: Int?
    let showPosterURL: String?
    let imdbID: String?
    let isAnime: Bool
    let isAnimation: Bool
    let playbackContext: EpisodePlaybackContext?

    init?(request: PlaybackRequest) {
        guard let mediaInfo = request.mediaInfo else { return nil }
        switch mediaInfo {
        case .movie:
            return nil
        case .episode(
            let showID,
            let seasonNumber,
            let episodeNumber,
            let showTitle,
            let showPosterURL,
            let mediaInfoIsAnime
        ):
            let normalizedTitle = showTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.init(
                showID: showID,
                currentSeasonNumber: seasonNumber,
                currentEpisodeNumber: episodeNumber,
                showTitle: normalizedTitle?.isEmpty == false ? normalizedTitle! : request.title,
                mediaYear: request.mediaYear,
                showPosterURL: showPosterURL ?? request.artworkURL?.absoluteString,
                imdbID: request.imdbID,
                isAnime: request.isAnime || mediaInfoIsAnime || request.episodePlaybackContext?.hasAnimeMediaId == true,
                isAnimation: request.isAnimation,
                playbackContext: request.episodePlaybackContext
            )
        }
    }

    init(
        showID: Int,
        currentSeasonNumber: Int,
        currentEpisodeNumber: Int,
        showTitle: String,
        mediaYear: Int? = nil,
        showPosterURL: String? = nil,
        imdbID: String? = nil,
        isAnime: Bool,
        isAnimation: Bool = false,
        playbackContext: EpisodePlaybackContext? = nil
    ) {
        self.showID = showID
        self.currentSeasonNumber = currentSeasonNumber
        self.currentEpisodeNumber = currentEpisodeNumber
        self.showTitle = showTitle
        self.mediaYear = mediaYear
        self.showPosterURL = showPosterURL
        self.imdbID = imdbID
        self.isAnime = isAnime
        self.isAnimation = isAnimation
        self.playbackContext = playbackContext
    }
}

struct ResolvedNextEpisodeTarget: Identifiable {
    let showID: Int
    let episode: TMDBEpisode
    let playbackContext: EpisodePlaybackContext?
    let mediaTitle: String
    let seasonTitleOverride: String?
    let originalTitle: String?
    let posterURL: String?
    let imdbID: String?
    let isAnime: Bool
    let isAnimation: Bool

    var mediaYear: Int? = nil

    var id: String {
        "next-\(showID)-s\(episode.seasonNumber)-e\(episode.episodeNumber)"
    }

    var originalTMDBSeasonNumber: Int? {
        playbackContext?.resolvedTMDBSeasonNumber
    }

    var originalTMDBEpisodeNumber: Int? {
        playbackContext?.resolvedTMDBEpisodeNumber
    }
}

enum NextEpisodeResolution {
    case available(ResolvedNextEpisodeTarget)
    case noAvailableEpisode
    case unavailable

    var target: ResolvedNextEpisodeTarget? {
        guard case .available(let target) = self else { return nil }
        return target
    }
}

protocol NextEpisodeMetadataProviding {
    func tvShow(showID: Int) async throws -> TMDBTVShowWithSeasons
    func season(showID: Int, seasonNumber: Int) async throws -> TMDBSeasonDetail
    func animeDetails(
        title: String,
        showID: Int,
        posterURL: String?,
        seedAniListID: Int?,
        seedMALID: Int?
    ) async throws -> AniListAnimeWithSeasons
    func specialEntries(
        showID: Int,
        posterURL: String?,
        baseAniListIDs: [Int],
        requiredSpecialAniListIDs: [Int]
    ) async throws -> [AniListSpecialSearchEntry]
}

struct LiveNextEpisodeMetadataProvider: NextEpisodeMetadataProviding {
    func tvShow(showID: Int) async throws -> TMDBTVShowWithSeasons {
        try await TMDBService.shared.getTVShowWithSeasons(id: showID)
    }

    func season(showID: Int, seasonNumber: Int) async throws -> TMDBSeasonDetail {
        try await TMDBService.shared.getSeasonDetails(
            tvShowId: showID,
            seasonNumber: seasonNumber
        )
    }

    func animeDetails(
        title: String,
        showID: Int,
        posterURL: String?,
        seedAniListID: Int?,
        seedMALID: Int?
    ) async throws -> AniListAnimeWithSeasons {
        try await AnimeMetadataService.shared.fetchAnimeDetailsWithEpisodes(
            title: title,
            tmdbShowId: showID,
            tmdbService: .shared,
            tmdbShowPoster: posterURL,
            token: nil,
            seedAniListId: seedAniListID,
            seedMALId: seedMALID
        )
    }

    func specialEntries(
        showID: Int,
        posterURL: String?,
        baseAniListIDs: [Int],
        requiredSpecialAniListIDs: [Int]
    ) async throws -> [AniListSpecialSearchEntry] {
        if let exactMALProviderID = (requiredSpecialAniListIDs + baseAniListIDs)
            .first(where: { $0 < 0 }) {
            guard let rootMALID = RemoteMediaNumericBoundary.positiveMagnitude(
                exactMALProviderID
            ) else { return [] }
            return try await AniListService.shared.fetchRequiredMALSpecialSearchEntries(
                tmdbShowId: showID,
                rootMalId: rootMALID,
                fallbackPosterURL: posterURL
            )
        }
        return await AnimeMetadataService.shared.fetchSpecialSearchEntries(
            tmdbShowId: showID,
            fallbackPosterURL: posterURL,
            baseAniListIds: baseAniListIDs,
            requiredSpecialAniListIds: requiredSpecialAniListIDs,
            tmdbService: .shared
        )
    }
}

struct NextEpisodeResolver {
    private let metadata: any NextEpisodeMetadataProviding

    init(metadata: any NextEpisodeMetadataProviding = LiveNextEpisodeMetadataProvider()) {
        self.metadata = metadata
    }

    func resolve(
        for request: PlaybackRequest,
        now: Date = Date()
    ) async -> NextEpisodeResolution {
        guard let seed = NextEpisodeSeed(request: request) else {
            return .noAvailableEpisode
        }
        return await resolve(seed: seed, now: now)
    }

    func resolve(
        seed: NextEpisodeSeed,
        now: Date = Date()
    ) async -> NextEpisodeResolution {
        let isAnimeTarget = seed.isAnime
            || seed.playbackContext?.hasAnimeMediaId == true
            || seed.playbackContext?.isSpecial == true
        let hasValidSeason = seed.currentSeasonNumber >= 0
            || (isAnimeTarget && AnimeSyntheticSeasonKey.isSynthetic(seed.currentSeasonNumber))
        guard seed.showID > 0,
              hasValidSeason,
              seed.currentEpisodeNumber > 0 else {
            return .unavailable
        }

        if isAnimeTarget {
            return await resolveAnime(seed: seed, now: now)
        }
        return await resolveRegularShow(seed: seed, now: now)
    }

    private func resolveRegularShow(
        seed: NextEpisodeSeed,
        now: Date
    ) async -> NextEpisodeResolution {
        let currentSeason: TMDBSeasonDetail
        do {
            currentSeason = try await metadata.season(
                showID: seed.showID,
                seasonNumber: seed.currentSeasonNumber
            )
        } catch {
            return .unavailable
        }

        let orderedCurrentEpisodes = currentSeason.episodes
            .filter {
                $0.seasonNumber == seed.currentSeasonNumber &&
                $0.episodeNumber > 0
            }
            .sorted { $0.episodeNumber < $1.episodeNumber }
        guard orderedCurrentEpisodes.contains(where: {
            $0.episodeNumber == seed.currentEpisodeNumber
        }) else {
            return .unavailable
        }

        if let next = orderedCurrentEpisodes.first(where: {
            $0.episodeNumber > seed.currentEpisodeNumber
        }) {
            guard Self.hasAired(next.airDate, by: now) else {
                return .noAvailableEpisode
            }
            return .available(makeRegularTarget(
                seed: seed,
                episode: next,
                posterURL: currentSeason.fullPosterURL ?? seed.showPosterURL
            ))
        }

        let show: TMDBTVShowWithSeasons
        do {
            show = try await metadata.tvShow(showID: seed.showID)
        } catch {
            return .unavailable
        }

        guard show.seasons.contains(where: {
            $0.seasonNumber == seed.currentSeasonNumber
        }) else {
            return .unavailable
        }

        let laterSeasons = show.seasons
            .filter {
                $0.seasonNumber > seed.currentSeasonNumber &&
                $0.seasonNumber > 0 &&
                $0.episodeCount > 0
            }
            .sorted { $0.seasonNumber < $1.seasonNumber }

        for summary in laterSeasons {
            let detail: TMDBSeasonDetail
            do {
                detail = try await metadata.season(
                    showID: seed.showID,
                    seasonNumber: summary.seasonNumber
                )
            } catch {
                return .unavailable
            }

            let destinationEpisodes = detail.episodes.filter {
                $0.seasonNumber == summary.seasonNumber &&
                $0.episodeNumber > 0
            }
            guard let first = destinationEpisodes.min(by: {
                $0.episodeNumber < $1.episodeNumber
            }) else {
                return .unavailable
            }
            guard Self.hasAired(first.airDate, by: now) else {
                return .noAvailableEpisode
            }
            return .available(makeRegularTarget(
                seed: seed,
                episode: first,
                posterURL: detail.fullPosterURL ?? summary.fullPosterURL ?? seed.showPosterURL
            ))
        }

        return .noAvailableEpisode
    }

    private func resolveAnime(
        seed: NextEpisodeSeed,
        now: Date
    ) async -> NextEpisodeResolution {
        let anime: AniListAnimeWithSeasons
        do {
            let providerSeed = seed.playbackContext?.anilistMediaId
                ?? seed.playbackContext?.positiveAniListMediaId
            anime = try await metadata.animeDetails(
                title: seed.showTitle,
                showID: seed.showID,
                posterURL: seed.showPosterURL,
                seedAniListID: providerSeed,
                seedMALID: providerSeed.flatMap { value in
                    value < 0 ? RemoteMediaNumericBoundary.positiveMagnitude(value) : nil
                }
            )
        } catch {
            return .unavailable
        }

        func aliases(for season: AniListSeasonWithPoster) -> [Int: Int] {
            var aliases: [Int: Int] = [:]
            if let positiveAniListID = season.canonicalAniListId
                    ?? (season.anilistId > 0 ? season.anilistId : nil),
               positiveAniListID > 0 {
                aliases[season.anilistId] = positiveAniListID
                if let providerID = RemoteMediaNumericBoundary.negativeProviderIdentifier(
                    season.malId
                ) {
                    aliases[providerID] = positiveAniListID
                }
            }
            return aliases
        }

        func resolvedSelection(
            in season: AniListSeasonWithPoster,
            context: EpisodePlaybackContext
        ) -> AniListEpisode? {
            let candidates: [AniListEpisode]
            if let tmdbSeason = context.resolvedTMDBSeasonNumber,
               let tmdbEpisode = context.resolvedTMDBEpisodeNumber {
                candidates = season.episodes.filter {
                    $0.tmdbSeasonNumber == tmdbSeason
                        && $0.tmdbEpisodeNumber == tmdbEpisode
                }
            } else {
                candidates = season.episodes.filter {
                    $0.number == context.localEpisodeNumber
                }
            }
            return candidates.first { episode in
                let candidate = EpisodePlaybackContext(
                    localSeasonNumber: season.seasonNumber,
                    localEpisodeNumber: episode.number,
                    anilistMediaId: season.anilistId,
                    canonicalAniListMediaId: season.canonicalAniListId
                        ?? (season.anilistId > 0 ? season.anilistId : nil),
                    malMediaId: season.malId,
                    kitsuMediaId: season.kitsuId,
                    tmdbSeasonNumber: episode.tmdbSeasonNumber,
                    tmdbEpisodeNumber: episode.tmdbEpisodeNumber,
                    tmdbEpisodeOffset: nil,
                    animeAbsoluteEpisodeNumber: nil,
                    animeSeasonEpisodeCount: season.episodes.count,
                    isSpecial: false,
                    titleOnlySearch: false
                )
                return AnimeEpisodeIdentityPolicy.isSameEpisode(
                    context,
                    candidate,
                    providerAliases: aliases(for: season)
                )
            }
        }

        let currentResolvedSelection = seed.playbackContext.flatMap { context in
            anime.seasons.lazy.compactMap { season in
                resolvedSelection(in: season, context: context).map {
                    (season: season, episode: $0)
                }
            }.first
        }
        if let context = seed.playbackContext {
            let belongsToRegularGraph = currentResolvedSelection != nil
            if !belongsToRegularGraph,
               context.isSpecial || context.hasAnimeMediaId {
                return await resolveSpecial(seed: seed, now: now)
            }
        }

        let orderedSeasons = anime.seasons.sorted {
            if $0.seasonNumber == $1.seasonNumber {
                return $0.anilistId < $1.anilistId
            }
            return $0.seasonNumber < $1.seasonNumber
        }
        guard !orderedSeasons.isEmpty else { return .unavailable }

        let context = seed.playbackContext
        let currentSeasonIndex: Int? = {
            if let selection = currentResolvedSelection,
               let index = orderedSeasons.firstIndex(where: {
                   $0.seasonNumber == selection.season.seasonNumber
                       && $0.anilistId == selection.season.anilistId
               }) {
                return index
            }
            guard context?.hasAnimeMediaId != true else { return nil }
            let localSeason = context?.localSeasonNumber ?? seed.currentSeasonNumber
            return orderedSeasons.firstIndex(where: { $0.seasonNumber == localSeason })
        }()
        guard let currentSeasonIndex else { return .unavailable }

        let currentSeason = orderedSeasons[currentSeasonIndex]
        let currentEpisodeNumber = currentResolvedSelection?.episode.number
            ?? context?.localEpisodeNumber
            ?? seed.currentEpisodeNumber
        let currentEpisodes = currentSeason.episodes.sorted { $0.number < $1.number }
        guard let currentEpisodeIndex = currentEpisodes.firstIndex(where: {
            $0.number == currentEpisodeNumber
        }) else {
            return .unavailable
        }

        let destinationSeason: AniListSeasonWithPoster
        let destinationEpisode: AniListEpisode
        if currentEpisodes.indices.contains(currentEpisodeIndex + 1) {
            destinationSeason = currentSeason
            destinationEpisode = currentEpisodes[currentEpisodeIndex + 1]
        } else {
            guard orderedSeasons.indices.contains(currentSeasonIndex + 1) else {
                return .noAvailableEpisode
            }
            destinationSeason = orderedSeasons[currentSeasonIndex + 1]
            guard let first = destinationSeason.episodes.min(by: { $0.number < $1.number }) else {
                return .unavailable
            }
            destinationEpisode = first
        }

        guard destinationEpisode.number > 0 else { return .unavailable }
        guard Self.hasAired(destinationEpisode.airDate, by: now) else {
            return .noAvailableEpisode
        }

        let absoluteOffset = orderedSeasons
            .prefix { $0.anilistId != destinationSeason.anilistId }
            .map { $0.episodes.count }
        let absoluteEpisodeNumber = RemoteMediaNumericBoundary.adding(
            RemoteMediaNumericBoundary.saturatingNonnegativeSum(absoluteOffset),
            destinationEpisode.number
        )
        let destinationContext = EpisodePlaybackContext(
            localSeasonNumber: destinationSeason.seasonNumber,
            localEpisodeNumber: destinationEpisode.number,
            anilistMediaId: destinationSeason.anilistId,
            canonicalAniListMediaId: destinationSeason.canonicalAniListId
                ?? (destinationSeason.anilistId > 0 ? destinationSeason.anilistId : nil),
            malMediaId: destinationSeason.malId,
            kitsuMediaId: destinationSeason.kitsuId,
            tmdbSeasonNumber: destinationEpisode.tmdbSeasonNumber,
            tmdbEpisodeNumber: destinationEpisode.tmdbEpisodeNumber,
            tmdbEpisodeOffset: nil,
            animeAbsoluteEpisodeNumber: absoluteEpisodeNumber,
            animeSeasonEpisodeCount: destinationSeason.episodes.count,
            isSpecial: false,
            titleOnlySearch: false
        )
        let destinationTitle = Self.nonempty(destinationSeason.title) ?? seed.showTitle
        let episode = TMDBEpisode(
            id: Self.syntheticEpisodeID(
                showID: seed.showID,
                seasonNumber: destinationSeason.seasonNumber,
                episodeNumber: destinationEpisode.number
            ),
            name: destinationEpisode.title,
            overview: destinationEpisode.description,
            stillPath: destinationEpisode.stillPath,
            episodeNumber: destinationEpisode.number,
            seasonNumber: destinationSeason.seasonNumber,
            airDate: destinationEpisode.airDate,
            runtime: destinationEpisode.runtime,
            voteAverage: 0,
            voteCount: 0
        )

        return .available(ResolvedNextEpisodeTarget(
            showID: seed.showID,
            episode: episode,
            playbackContext: destinationContext,
            mediaTitle: destinationTitle,
            seasonTitleOverride: destinationTitle,
            originalTitle: Self.nonempty(destinationSeason.romajiTitle),
            posterURL: destinationSeason.posterUrl ?? seed.showPosterURL,
            imdbID: seed.imdbID,
            isAnime: true,
            isAnimation: seed.isAnimation,
            mediaYear: seed.mediaYear
        ))
    }

    private func resolveSpecial(
        seed: NextEpisodeSeed,
        now: Date
    ) async -> NextEpisodeResolution {

        guard let currentContext = seed.playbackContext else {
            return .unavailable
        }

        let entries: [AniListSpecialSearchEntry]
        do {
            let currentAniListIDs = Set([
                currentContext.anilistMediaId,
                currentContext.positiveAniListMediaId
            ].compactMap { $0 })
            entries = try await metadata.specialEntries(
                showID: seed.showID,
                posterURL: seed.showPosterURL,
                baseAniListIDs: Array(currentAniListIDs),
                requiredSpecialAniListIDs: Array(currentAniListIDs)
            )
        } catch {
            return .unavailable
        }
        guard !entries.isEmpty else { return .unavailable }

        let currentSelection = entries.lazy.compactMap { entry -> (AniListSpecialSearchEntry, AniListEpisode)? in
            guard let localSeasonNumber = Self.specialLocalSeasonNumber(entryID: entry.id) else {
                return nil
            }
            var aliases: [Int: Int] = [:]
            if let canonicalID = entry.canonicalAniListId
                    ?? (entry.id > 0 ? entry.id : nil),
               canonicalID > 0 {
                aliases[entry.id] = canonicalID
                if let providerID = RemoteMediaNumericBoundary.negativeProviderIdentifier(
                    entry.malId
                ) {
                    aliases[providerID] = canonicalID
                }
            }
            let candidates: [AniListEpisode]
            if let tmdbSeason = currentContext.resolvedTMDBSeasonNumber,
               let tmdbEpisode = currentContext.resolvedTMDBEpisodeNumber {
                candidates = entry.episodes.filter {
                    $0.tmdbSeasonNumber == tmdbSeason
                        && $0.tmdbEpisodeNumber == tmdbEpisode
                }
            } else {
                candidates = entry.episodes.filter {
                    $0.number == currentContext.localEpisodeNumber
                }
            }
            return candidates.first(where: { episode in
                let candidate = EpisodePlaybackContext(
                    localSeasonNumber: localSeasonNumber,
                    localEpisodeNumber: episode.number,
                    anilistMediaId: entry.id,
                    canonicalAniListMediaId: entry.canonicalAniListId
                        ?? (entry.id > 0 ? entry.id : nil),
                    malMediaId: entry.malId,
                    kitsuMediaId: entry.kitsuId,
                    tmdbSeasonNumber: episode.tmdbSeasonNumber,
                    tmdbEpisodeNumber: episode.tmdbEpisodeNumber,
                    tmdbEpisodeOffset: nil,
                    animeAbsoluteEpisodeNumber: nil,
                    animeSeasonEpisodeCount: entry.episodeCount,
                    isSpecial: true,
                    titleOnlySearch: entry.episodeCount == 1
                )
                return AnimeEpisodeIdentityPolicy.isSameEpisode(
                    currentContext,
                    candidate,
                    providerAliases: aliases
                )
            }).map { (entry, $0) }
        }.first
        guard let (entry, currentSourceEpisode) = currentSelection else {
            return .unavailable
        }

        let episodeCount = max(1, entry.episodeCount)
        let currentEpisodeNumber = currentSourceEpisode.number
        guard (1...episodeCount).contains(currentEpisodeNumber) else {
            return .unavailable
        }
        let nextEpisodeNumber = currentEpisodeNumber + 1
        guard nextEpisodeNumber <= episodeCount else {
            return .noAvailableEpisode
        }

        let source = entry.episodes.first(where: { $0.number == nextEpisodeNumber })
        let knownReleaseDate = source?.airDate
            ?? ((episodeCount == 1 || entry.status?.uppercased().contains("FINISHED") == true) ? entry.releaseDate : nil)
        guard let knownReleaseDate else {
            return .unavailable
        }
        guard Self.hasAired(knownReleaseDate, by: now) else {
            return .noAvailableEpisode
        }
        let title = Self.nonempty(source?.title)
            ?? (episodeCount == 1 ? entry.preferredTitle : "Episode \(nextEpisodeNumber)")
        guard let localSeasonNumber = Self.specialLocalSeasonNumber(entryID: entry.id) else {
            return .unavailable
        }
        let exactTMDBSeason = source?.tmdbSeasonNumber
        let exactTMDBEpisode = source?.tmdbEpisodeNumber
        let context = EpisodePlaybackContext(
            localSeasonNumber: localSeasonNumber,
            localEpisodeNumber: nextEpisodeNumber,
            anilistMediaId: entry.id,
            canonicalAniListMediaId: entry.canonicalAniListId
                ?? (entry.id > 0 ? entry.id : nil),
            malMediaId: entry.malId,
            kitsuMediaId: entry.kitsuId,
            tmdbSeasonNumber: exactTMDBEpisode == nil ? nil : exactTMDBSeason,
            tmdbEpisodeNumber: exactTMDBEpisode,
            tmdbEpisodeOffset: nil,
            animeAbsoluteEpisodeNumber: nil,
            animeSeasonEpisodeCount: nil,
            isSpecial: true,
            titleOnlySearch: episodeCount == 1
        )
        let episode = TMDBEpisode(
            id: Self.syntheticSpecialEpisodeID(
                showID: seed.showID,
                entryID: entry.id,
                episodeNumber: nextEpisodeNumber
            ),
            name: title,
            overview: source?.description,
            stillPath: source?.stillPath,
            episodeNumber: nextEpisodeNumber,
            seasonNumber: localSeasonNumber,
            airDate: source?.airDate,
            runtime: source?.runtime,
            voteAverage: 0,
            voteCount: 0
        )

        return .available(ResolvedNextEpisodeTarget(
            showID: seed.showID,
            episode: episode,
            playbackContext: context,
            mediaTitle: entry.preferredTitle,
            seasonTitleOverride: entry.preferredTitle,
            originalTitle: entry.alternateSearchTitle,
            posterURL: entry.posterUrl ?? seed.showPosterURL,
            imdbID: entry.imdbId ?? seed.imdbID,
            isAnime: true,
            isAnimation: seed.isAnimation,
            mediaYear: seed.mediaYear
        ))
    }

    private func makeRegularTarget(
        seed: NextEpisodeSeed,
        episode: TMDBEpisode,
        posterURL: String?
    ) -> ResolvedNextEpisodeTarget {
        ResolvedNextEpisodeTarget(
            showID: seed.showID,
            episode: episode,
            playbackContext: nil,
            mediaTitle: seed.showTitle,
            seasonTitleOverride: nil,
            originalTitle: nil,
            posterURL: posterURL,
            imdbID: seed.imdbID,
            isAnime: false,
            isAnimation: seed.isAnimation,
            mediaYear: seed.mediaYear
        )
    }

    static func hasAired(_ rawDate: String?, by now: Date) -> Bool {
        guard let rawDate = nonempty(rawDate) else { return true }
        let components = rawDate.split(separator: "-")
        guard components.count == 3,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let day = Int(components[2]) else {
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let airDate = calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        )) else {
            return false
        }
        return airDate <= calendar.startOfDay(for: now)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func specialLocalSeasonNumber(entryID: Int) -> Int? {
        AnimeSyntheticSeasonKey.make(providerID: entryID)
    }

    private static func syntheticEpisodeID(
        showID: Int,
        seasonNumber: Int,
        episodeNumber: Int
    ) -> Int {
        RemoteMediaNumericBoundary.syntheticIdentifier([
            (showID, 1_000_000),
            (seasonNumber, 10_000),
            (episodeNumber, 1)
        ])
    }

    private static func syntheticSpecialEpisodeID(
        showID: Int,
        entryID: Int,
        episodeNumber: Int
    ) -> Int {
        RemoteMediaNumericBoundary.syntheticIdentifier([
            (showID, 1_000_000),
            (entryID, 100),
            (episodeNumber, 1)
        ])
    }
}
