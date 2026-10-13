import SwiftUI
import Foundation

struct PlayerEpisodeBrowserSeed {
    let showId: Int
    let showTitle: String
    let showPosterURL: String?
    let currentSeasonNumber: Int
    let currentEpisodeNumber: Int
    let isAnime: Bool
    let imdbId: String?
    let currentPlaybackContext: EpisodePlaybackContext?
    var mediaYear: Int? = nil
}

struct PlayerEpisodeBrowserSeason: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let posterURL: String?
    let episodes: [PlayerEpisodeBrowserItem]
}

struct PlayerEpisodeBrowserItem: Identifiable {
    let id: String
    let showId: Int
    let showTitle: String
    let showPosterURL: String?
    let mediaTitle: String
    let seasonTitleOverride: String?
    let animeSeasonTitle: String?
    let originalTitle: String?
    let posterURL: String?
    let originalAudioLanguage: String?
    let imdbId: String?
    let episode: TMDBEpisode
    let isAnime: Bool
    let isSpecial: Bool
    let playbackContext: EpisodePlaybackContext?
    let originalTMDBSeasonNumber: Int?
    let originalTMDBEpisodeNumber: Int?
    var progress: Double
    var isDownloaded: Bool
    #if !os(tvOS)
    var downloadItem: DownloadItem?
    #endif
    let isCurrent: Bool
    var mediaYear: Int? = nil

    var imageURL: String? {
        PlayerEpisodeBrowserViewModel.fullImageURL(from: episode.stillPath)
            ?? posterURL
            ?? showPosterURL
    }

    var artworkURLs: [String] {
        var urls: [String] = []
        var candidates = [
            PlayerEpisodeBrowserViewModel.fullImageURL(from: episode.stillPath),
            posterURL,
            showPosterURL
        ]
        #if !os(tvOS)
        candidates.append(downloadItem?.posterURL)
        #endif
        for candidate in candidates {
            guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  !urls.contains(value) else {
                continue
            }
            urls.append(value)
        }
        return urls
    }

    var displayCode: String {
        if isSpecial {
            return episode.episodeNumber > 1 ? "Special \(episode.episodeNumber)" : "Special"
        }
        if isAnime {
            return "E\(episode.episodeNumber)"
        }
        return "S\(episode.seasonNumber)E\(episode.episodeNumber)"
    }

    var displayTitle: String {
        let name = episode.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Episode \(episode.episodeNumber)" : name
    }
}

#if !os(tvOS)
enum DownloadedAnimeUnitPlaybackPolicy {
    static func mediaInfo(for item: DownloadItem, context suppliedContext: EpisodePlaybackContext?) -> MediaInfo? {
        let context = suppliedContext ?? item.episodePlaybackContext
        if item.episodePlaybackContext?.unitProjection?.edition == .unverified { return nil }
        if item.episodePlaybackContext?.unitProjection != nil, let suppliedContext, suppliedContext.unitProjection == nil { return nil }
        if let context, let projection = context.unitProjection {
            guard context.hasTrustedUnitProjection(showID: item.tmdbId) else { return nil }
            if projection.edition == .feature {
                guard let movieID = projection.tmdbMovieID, item.isMovie, item.tmdbId == movieID else { return nil }
                if let stored = item.episodePlaybackContext, stored.unitProjection != nil,
                   !AnimeEpisodeIdentityPolicy.isSameEpisode(context, stored) { return nil }
                return .movie(id: movieID, title: item.playerTitleBase, posterURL: item.posterURL,
                    isAnime: item.isAnime || context.hasAnimeMediaId)
            }
            guard !item.isMovie, let stored = item.episodePlaybackContext,
                  stored.hasTrustedUnitProjection(showID: item.tmdbId),
                  AnimeEpisodeIdentityPolicy.isSameEpisode(context, stored) else { return nil }
        }
        guard !item.isMovie, let context else { return item.mediaInfo }
        return .episode(showId: item.tmdbId, seasonNumber: context.localSeasonNumber,
            episodeNumber: context.localEpisodeNumber, showTitle: item.playerTitleBase,
            showPosterURL: item.posterURL, isAnime: item.isAnime || context.hasAnimeMediaId)
    }
}
#endif

@MainActor
final class PlayerEpisodeBrowserViewModel: ObservableObject {
    private struct CachedEpisodeBrowserLoad {
        let seasons: [PlayerEpisodeBrowserSeason]
        let currentItemID: String?
        let storedAt: Date
    }

    private static var loadCache: [String: CachedEpisodeBrowserLoad] = [:]
    private static let loadCacheTTL: TimeInterval = 10 * 60

    @Published var seasons: [PlayerEpisodeBrowserSeason] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var currentItemID: String?

    let seed: PlayerEpisodeBrowserSeed
    private var didLoad = false
    private var resolvedMediaYear: Int?
    private var canonicalCurrentPlaybackContext: EpisodePlaybackContext?
    private struct EpisodeCoordinate: Hashable {
        let season: Int
        let episode: Int
    }
    private var progressLookup: ProgressManager.EpisodeLookupSnapshot?
    private var progressEntriesByCoordinate: [EpisodeCoordinate: EpisodeProgressEntry] = [:]
#if os(iOS) || os(macOS)
    private var downloadLookup: EpisodeDownloadLookupSnapshot?
    private var fileAvailability: [String: Bool] = [:]
#endif

    private func refreshEpisodeLookups() {
        if progressLookup.map({ ProgressManager.shared.episodeLookupIsCurrent($0) }) != true {
            let snapshot = ProgressManager.shared.captureEpisodeLookup(showID: seed.showId)
            progressLookup = snapshot
            var values: [EpisodeCoordinate: EpisodeProgressEntry] = [:]
            for entry in snapshot.entries {
                let coordinate = EpisodeCoordinate(season: entry.seasonNumber, episode: entry.episodeNumber)
                if values[coordinate] == nil {
                    values[coordinate] = entry
                }
            }
            progressEntriesByCoordinate = values
        }
#if os(iOS) || os(macOS)
        if downloadLookup.map({ DownloadManager.shared.episodeLookupIsCurrent($0) }) != true {
            downloadLookup = DownloadManager.shared.episodeLookupSnapshot()
            fileAvailability.removeAll(keepingCapacity: true)
        }
#endif
    }

#if os(iOS) || os(macOS)
    private func completedDownload(for episode: TMDBEpisode, context: EpisodePlaybackContext?) -> DownloadItem? {
        downloadLookup?.matchingEpisodeDownloadItem(
            tmdbId: seed.showId,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber,
            playbackContext: context
        ) { candidate in
            guard candidate.status == .completed, let name = candidate.localFileName else { return false }
            if let available = fileAvailability[name] { return available }
            let available = DownloadManager.shared.localFileURL(for: candidate) != nil
            fileAvailability[name] = available
            return available
        }
    }
#endif

    private func refreshedEpisodeState(_ item: PlayerEpisodeBrowserItem) -> PlayerEpisodeBrowserItem {
        refreshEpisodeLookups()
        var result = item
        result.progress = progressForEpisode(item.episode, context: item.playbackContext)
#if os(iOS) || os(macOS)
        result.downloadItem = completedDownload(for: item.episode, context: item.playbackContext)
        result.isDownloaded = result.downloadItem != nil
#endif
        return result
    }

    private func progressForEpisode(_ episode: TMDBEpisode, context: EpisodePlaybackContext?) -> Double {
        if let movieID = context?.unitProjection?.tmdbMovieID,
           context?.hasTrustedUnitProjection(showID: seed.showId) == true {
            return ProgressManager.shared.getMovieProgress(movieId: movieID, title: episode.name)
        }
        guard let entry = progressEntriesByCoordinate[EpisodeCoordinate(season: episode.seasonNumber, episode: episode.episodeNumber)],
              ProgressManager.matchesPlaybackUnit(entry, context: context) else { return 0 }
        return entry.progress
    }

    private func validateLoadAuthority(_ authority: ProgressManager.ProfileMutationAuthority) throws {
        try Task.checkCancellation()
        guard ProgressManager.shared.profileMutationAuthorityIsCurrent(authority) else {
            throw CancellationError()
        }
    }

    init(seed: PlayerEpisodeBrowserSeed) {
        self.seed = seed
        self.resolvedMediaYear = seed.mediaYear
    }

    func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        await load()
    }

    func itemAfterCurrent(skippingKnownFillers: Bool = false) async -> PlayerEpisodeBrowserItem? {
        if !didLoad {
            await load()
        }
        if seed.isAnime,
           seed.currentPlaybackContext?.hasAnimeMediaId == true,
           canonicalCurrentPlaybackContext == nil {
            return nil
        }
        let currentContext = canonicalCurrentPlaybackContext ?? seed.currentPlaybackContext
        let currentIsSpecial = canonicalCurrentPlaybackContext?.isSpecial
            ?? (seed.currentPlaybackContext?.isSpecial == true || seed.currentSeasonNumber == 0)
        let eligibleItems = seasons.flatMap(\.episodes).filter { item in
            guard currentIsSpecial else { return !item.isSpecial }
            guard item.isSpecial,
                  let currentContext,
                  let itemContext = item.playbackContext else {
                return false
            }
            if let currentAniListId = currentContext.positiveAniListMediaId {
                return itemContext.positiveAniListMediaId == currentAniListId
            }
            if let currentProviderID = currentContext.anilistMediaId {
                return itemContext.anilistMediaId == currentProviderID
            }
            if let currentKitsuId = currentContext.kitsuMediaId {
                return itemContext.kitsuMediaId == currentKitsuId
            }
            return itemContext.localSeasonNumber == currentContext.localSeasonNumber
        }
        let allItems = eligibleItems.sorted { lhs, rhs in
            if lhs.episode.seasonNumber == rhs.episode.seasonNumber {
                return lhs.episode.episodeNumber < rhs.episode.episodeNumber
            }
            return lhs.episode.seasonNumber < rhs.episode.seasonNumber
        }
        guard let index = allItems.firstIndex(where: { item in
            isCanonicalCurrentItem(item, currentContext: currentContext)
        }) else { return nil }
        let nextIndex = allItems.index(after: index)
        guard nextIndex < allItems.endIndex else { return nil }

        let immediateNext = allItems[nextIndex]
        guard skippingKnownFillers,
              seed.isAnime,
              immediateNext.playbackContext?.supportsCanonicalEpisodeLookup != false,
              !currentIsSpecial else {
            return immediateNext
        }

        var episodeClassificationsByProviderId: [Int: AnimeEpisodeClassifications] = [:]
        for item in allItems[nextIndex...] {
            guard !Task.isCancelled else { return nil }

            guard item.isAnime,
                  !item.isSpecial,
                  item.playbackContext?.supportsCanonicalEpisodeLookup != false,
                  let providerId = item.playbackContext?.anilistMediaId else {
                return immediateNext
            }

            let classifications: AnimeEpisodeClassifications
            if let cached = episodeClassificationsByProviderId[providerId] {
                classifications = cached
            } else {
                let malId: Int?
                if providerId < 0 {
                    malId = RemoteMediaNumericBoundary.positiveMagnitude(providerId)
                } else if let cached = TrackerManager.shared.cachedMyAnimeListAnimeId(fromAniListId: providerId) {
                    malId = cached
                } else {
                    malId = await TrackerManager.shared.resolveMyAnimeListAnimeId(fromAniListId: providerId)
                }

                guard let malId, malId > 0 else {
                    Logger.shared.log(
                        "NextEpisode: filler metadata unavailable for providerId=\(providerId); using immediate next episode",
                        type: "Player"
                    )
                    return immediateNext
                }

                do {
                    classifications = try await AnimeFillerService.shared.episodeClassifications(malId: malId)
                    episodeClassificationsByProviderId[providerId] = classifications
                } catch is CancellationError {
                    return nil
                } catch {
                    Logger.shared.log(
                        "NextEpisode: filler lookup failed providerId=\(providerId) error=\(error.localizedDescription); using immediate next episode",
                        type: "Error"
                    )
                    return immediateNext
                }
            }

            if classifications.shouldSkip(episodeNumber: item.episode.episodeNumber) {
                Logger.shared.log(
                    "NextEpisode: skipping known filler S\(item.episode.seasonNumber)E\(item.episode.episodeNumber)",
                    type: "Player"
                )
                continue
            }
            return item
        }
        return nil
    }

    private func load() async {
        didLoad = true
        guard let authority = ProgressManager.shared.profileMutationAuthority() else { return }
        progressLookup = nil
#if os(iOS) || os(macOS)
        downloadLookup = nil
        fileAvailability.removeAll(keepingCapacity: true)
#endif
        defer {
            progressLookup = nil
            progressEntriesByCoordinate.removeAll(keepingCapacity: true)
#if os(iOS) || os(macOS)
            downloadLookup = nil
            fileAvailability.removeAll(keepingCapacity: true)
#endif
        }
        let cacheKey = Self.cacheKey(for: seed)
        if let cached = Self.cachedLoad(for: cacheKey) {
            seasons = cached.seasons.map { season in
                PlayerEpisodeBrowserSeason(id: season.id, title: season.title, subtitle: season.subtitle,
                                           posterURL: season.posterURL, episodes: season.episodes.map(refreshedEpisodeState))
            }
            currentItemID = cached.currentItemID
            canonicalCurrentPlaybackContext = cached.seasons
                .flatMap(\.episodes)
                .first(where: { $0.id == cached.currentItemID })?
                .playbackContext
            isLoading = false
            errorMessage = nil
            Logger.shared.log("Player episode browser cache hit key=\(cacheKey) seasons=\(cached.seasons.count)", type: "Player")
            return
        }

        isLoading = true
        errorMessage = nil
        seasons = []
        currentItemID = nil
        canonicalCurrentPlaybackContext = nil

        do {
            let tmdbService = TMDBService.shared
            let tvShow = try await tmdbService.getTVShowWithSeasons(id: seed.showId)
            try validateLoadAuthority(authority)
            let showTitle = tvShow.name.isEmpty ? seed.showTitle : tvShow.name
            let showPosterURL = seed.showPosterURL ?? tvShow.fullPosterURL
            let resolvedImdbId = seed.imdbId ?? tvShow.externalIds?.imdbId
            let fetchedMediaYear = tvShow.firstAirDate.flatMap { Int($0.prefix(4)) }
            resolvedMediaYear = seed.mediaYear
                ?? fetchedMediaYear.flatMap { (1800...3000).contains($0) ? $0 : nil }
            var animeData: AniListAnimeWithSeasons?
            var specialContexts: [SpecialEpisodeListContext] = []

            if seed.isAnime && !PerformanceModeSettings.skipsAniListTraversalForAnimeDetails {
                let providerSeed = seed.currentPlaybackContext?.anilistMediaId
                    ?? seed.currentPlaybackContext?.positiveAniListMediaId
                animeData = try? await AniListService.shared.fetchAnimeDetailsWithEpisodes(
                    title: seed.showTitle,
                    tmdbShowId: seed.showId,
                    tmdbService: tmdbService,
                    tmdbShowPoster: showPosterURL,
                    token: nil,
                    seedAniListId: providerSeed,
                    seedMALId: providerSeed.flatMap { value in
                        value < 0 ? RemoteMediaNumericBoundary.positiveMagnitude(value) : nil
                    }
                )
                try validateLoadAuthority(authority)
                if let animeData {
                    let mappings = animeData.seasons.map {
                        (
                            seasonNumber: $0.seasonNumber,
                            anilistId: $0.canonicalAniListId ?? $0.anilistId
                        )
                    }
                    TrackerManager.shared.registerAniListAnimeData(tmdbId: seed.showId, seasons: mappings)
                }

                let specialEntries: [AniListSpecialSearchEntry]
                if let providerSeed, providerSeed < 0 {
                    if let rootMALID = RemoteMediaNumericBoundary.positiveMagnitude(providerSeed) {
                        specialEntries = (try? await AniListService.shared.fetchRequiredMALSpecialSearchEntries(
                            tmdbShowId: seed.showId,
                            rootMalId: rootMALID,
                            fallbackPosterURL: showPosterURL
                        )) ?? []
                    } else {
                        specialEntries = []
                    }
                } else {
                    specialEntries = await AniListService.shared.fetchSpecialSearchEntries(
                        tmdbShowId: seed.showId,
                        fallbackPosterURL: showPosterURL,
                        baseAniListIds: animeData?.seasons.map(\.anilistId) ?? [],
                        tmdbService: tmdbService
                    )
                }
                specialContexts = specialEntries.compactMap {
                    SpecialEpisodeListContext(entry: $0, tmdbShowId: seed.showId)
                }
            } else if seed.isAnime {
                Logger.shared.log("EpisodeBrowser: skipped AniList traversal because detail traversal performance mode is enabled", type: "AniList")
            }

            try validateLoadAuthority(authority)
            var loaded: [PlayerEpisodeBrowserSeason] = []
            let animeAbsoluteEpisodeOffsets = animeData.map {
                absoluteEpisodeOffsetsBySeason(for: $0.seasons)
            } ?? [:]
            canonicalCurrentPlaybackContext = canonicalPlaybackContext(
                animeData: animeData,
                specialContexts: specialContexts,
                absoluteEpisodeOffsets: animeAbsoluteEpisodeOffsets
            )

            if canonicalCurrentPlaybackContext?.isSpecial == true,
               let currentSpecial = currentSpecialContext(from: specialContexts) {
                loaded.append(buildSpecialSeason(
                    context: currentSpecial,
                    showTitle: showTitle,
                    showPosterURL: showPosterURL,
                    fallbackImdbId: resolvedImdbId,
                    originalAudioLanguage: tvShow.originalLanguage
                ))
                seasons = loaded
            } else if seed.isAnime,
                      let animeSeason = currentRegularSeason(in: animeData) {
                loaded.append(buildAnimeSeason(
                    animeSeason,
                    absoluteEpisodeOffset: animeAbsoluteEpisodeOffsets[animeSeason.seasonNumber] ?? 0,
                    showTitle: showTitle,
                    showPosterURL: showPosterURL,
                    imdbId: resolvedImdbId,
                    originalAudioLanguage: tvShow.originalLanguage
                ))
                seasons = loaded

            } else if !seed.isAnime || animeData == nil,
                      let currentTMDBSeason = tvShow.seasons.first(where: { $0.seasonNumber == seed.currentSeasonNumber }) {
                let detail = try? await tmdbService.getSeasonDetails(tvShowId: seed.showId, seasonNumber: currentTMDBSeason.seasonNumber)
                try validateLoadAuthority(authority)
                if let detail {
                    loaded.append(buildTMDBSeason(
                        summary: currentTMDBSeason,
                        detail: detail,
                        showTitle: showTitle,
                        showPosterURL: showPosterURL,
                        imdbId: resolvedImdbId,
                        isSpecial: currentTMDBSeason.seasonNumber == 0,
                        originalAudioLanguage: tvShow.originalLanguage
                    ))
                    seasons = loaded
                }
            }

            if seed.isAnime, let animeData {
                let currentProviderID = canonicalCurrentPlaybackContext?.positiveAniListMediaId
                    ?? canonicalCurrentPlaybackContext?.anilistMediaId
                let currentKitsuID = canonicalCurrentPlaybackContext?.kitsuMediaId
                for season in animeData.seasons.sorted(by: { $0.seasonNumber < $1.seasonNumber }) where
                    (season.canonicalAniListId ?? season.anilistId) != currentProviderID
                        && (currentKitsuID == nil || season.kitsuId != currentKitsuID) {
                    loaded.append(buildAnimeSeason(
                        season,
                        absoluteEpisodeOffset: animeAbsoluteEpisodeOffsets[season.seasonNumber] ?? 0,
                        showTitle: showTitle,
                        showPosterURL: showPosterURL,
                        imdbId: resolvedImdbId,
                        originalAudioLanguage: tvShow.originalLanguage
                    ))
                    seasons = loaded
                }
            } else {
                let orderedSeasons = tvShow.seasons
                    .filter { $0.episodeCount > 0 }
                    .sorted { lhs, rhs in
                        if lhs.seasonNumber == 0 { return false }
                        if rhs.seasonNumber == 0 { return true }
                        return lhs.seasonNumber < rhs.seasonNumber
                    }
                for season in orderedSeasons where season.seasonNumber != seed.currentSeasonNumber {
                    let detail = try? await tmdbService.getSeasonDetails(tvShowId: seed.showId, seasonNumber: season.seasonNumber)
                    try validateLoadAuthority(authority)
                    guard let detail else { continue }
                    loaded.append(buildTMDBSeason(
                        summary: season,
                        detail: detail,
                        showTitle: showTitle,
                        showPosterURL: showPosterURL,
                        imdbId: resolvedImdbId,
                        isSpecial: season.seasonNumber == 0,
                        originalAudioLanguage: tvShow.originalLanguage
                    ))
                    seasons = loaded
                }
            }

            try validateLoadAuthority(authority)
            for context in specialContexts where !loaded.contains(where: { $0.id == "special-\(context.id)" }) {
                loaded.append(buildSpecialSeason(
                    context: context,
                    showTitle: showTitle,
                    showPosterURL: showPosterURL,
                    fallbackImdbId: resolvedImdbId,
                    originalAudioLanguage: tvShow.originalLanguage
                ))
                seasons = loaded
            }

            if let current = loaded.flatMap(\.episodes).first(where: { $0.isCurrent }) {
                currentItemID = current.id
            }
            seasons = loaded
            Self.storeLoad(seasons: loaded, currentItemID: currentItemID, for: cacheKey)
            isLoading = false
        } catch is CancellationError {
            didLoad = false
            isLoading = false
            seasons = []
            currentItemID = nil
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    private static func cacheKey(for seed: PlayerEpisodeBrowserSeed) -> String {
        let rawProvider = seed.currentPlaybackContext?.anilistMediaId
            .map { String($0) } ?? "nil"
        let canonicalProvider = seed.currentPlaybackContext?.positiveAniListMediaId
            .map { String($0) } ?? "nil"
        let kitsuProvider = seed.currentPlaybackContext?.kitsuMediaId
            .map { String($0) } ?? "nil"
        let role = seed.currentPlaybackContext?.isSpecial == true ? "special" : "regular"
        let contextKey = "\(rawProvider):\(canonicalProvider):\(kitsuProvider):\(role)"
        let modeKey: String
        if PerformanceModeSettings.isEnabled && PerformanceModeSettings.skipsAniListTraversalForAnimeDetails {
            modeKey = "performance+skipTraversal"
        } else if PerformanceModeSettings.isEnabled {
            modeKey = "performance"
        } else if PerformanceModeSettings.skipsAniListTraversalForAnimeDetails {
            modeKey = "skipTraversal"
        } else {
            modeKey = "standard"
        }
        return "\(ProfileManager.shared.activeProfileID.uuidString)|\(seed.showId)|S\(seed.currentSeasonNumber)|E\(seed.currentEpisodeNumber)|anime=\(seed.isAnime)|mode=\(modeKey)|\(contextKey)"
    }

    private static func cachedLoad(for key: String) -> CachedEpisodeBrowserLoad? {
        let now = Date()
        loadCache = loadCache.filter { now.timeIntervalSince($0.value.storedAt) < loadCacheTTL }
        return loadCache[key]
    }

    private static func storeLoad(seasons: [PlayerEpisodeBrowserSeason], currentItemID: String?, for key: String) {
        loadCache[key] = CachedEpisodeBrowserLoad(seasons: seasons, currentItemID: currentItemID, storedAt: Date())
        if loadCache.count > 12 {
            let sortedKeys = loadCache.sorted { $0.value.storedAt < $1.value.storedAt }.map(\.key)
            for key in sortedKeys.prefix(loadCache.count - 12) {
                loadCache[key] = nil
            }
        }
    }

    private func currentSpecialContext(from contexts: [SpecialEpisodeListContext]) -> SpecialEpisodeListContext? {

        guard let current = canonicalCurrentPlaybackContext ?? seed.currentPlaybackContext else { return nil }
        for context in contexts {
            let candidates: [TMDBEpisode]
            if let tmdbSeason = current.resolvedTMDBSeasonNumber,
               let tmdbEpisode = current.resolvedTMDBEpisodeNumber {
                candidates = context.episodes.filter {
                    let candidate = context.playbackContext(for: $0)
                    return candidate.resolvedTMDBSeasonNumber == tmdbSeason
                        && candidate.resolvedTMDBEpisodeNumber == tmdbEpisode
                }
            } else {
                candidates = context.episodes.filter {
                    $0.episodeNumber == current.localEpisodeNumber
                }
            }
            if candidates.contains(where: {
                AnimeEpisodeIdentityPolicy.isSameEpisode(
                    current,
                    context.playbackContext(for: $0)
                )
            }) {
                return context
            }
        }
        return nil
    }

    private func currentRegularSeason(
        in animeData: AniListAnimeWithSeasons?
    ) -> AniListSeasonWithPoster? {
        guard let animeData else { return nil }
        if let context = canonicalCurrentPlaybackContext {
            if let providerID = context.positiveAniListMediaId,
               let season = animeData.seasons.first(where: {
                   ($0.canonicalAniListId ?? ($0.anilistId > 0 ? $0.anilistId : nil)) == providerID
               }) {
                return season
            }
            if let providerID = context.anilistMediaId,
               let season = animeData.seasons.first(where: { $0.anilistId == providerID }) {
                return season
            }
            if let kitsuID = context.kitsuMediaId,
               let season = animeData.seasons.first(where: { $0.kitsuId == kitsuID }) {
                return season
            }
            return nil
        }
        guard seed.currentPlaybackContext?.hasAnimeMediaId != true else { return nil }
        return animeData.seasons.first(where: { $0.seasonNumber == seed.currentSeasonNumber })
    }

    private func canonicalPlaybackContext(
        animeData: AniListAnimeWithSeasons?,
        specialContexts: [SpecialEpisodeListContext],
        absoluteEpisodeOffsets: [Int: Int]
    ) -> EpisodePlaybackContext? {
        guard seed.isAnime else { return nil }
        let persisted = seed.currentPlaybackContext
        let episodeNumber = max(1, persisted?.localEpisodeNumber ?? seed.currentEpisodeNumber)

        var aliases: [Int: Int] = [:]
        if let animeData {
            for season in animeData.seasons {
                if let canonicalID = season.canonicalAniListId
                        ?? (season.anilistId > 0 ? season.anilistId : nil),
                   canonicalID > 0 {
                    aliases[season.anilistId] = canonicalID
                    if let providerID = RemoteMediaNumericBoundary.negativeProviderIdentifier(
                        season.malId
                    ) {
                        aliases[providerID] = canonicalID
                    }
                }
            }
        }
        for special in specialContexts {
            if let canonicalID = special.canonicalAniListId, canonicalID > 0 {
                aliases[special.anilistId] = canonicalID
            }
        }

        if let animeData {
            for season in animeData.seasons {
                let candidates: [AniListEpisode]
                if let tmdbSeason = persisted?.resolvedTMDBSeasonNumber,
                   let tmdbEpisode = persisted?.resolvedTMDBEpisodeNumber {
                    candidates = season.episodes.filter {
                        $0.tmdbSeasonNumber == tmdbSeason
                            && $0.tmdbEpisodeNumber == tmdbEpisode
                    }
                } else {
                    candidates = season.episodes.filter {
                        $0.number == episodeNumber
                            && (persisted?.hasAnimeMediaId == true
                                || season.seasonNumber == seed.currentSeasonNumber)
                    }
                }
                for episode in candidates {
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
                        animeAbsoluteEpisodeNumber: RemoteMediaNumericBoundary.adding(
                            absoluteEpisodeOffsets[season.seasonNumber] ?? 0,
                            episode.number
                        ),
                        animeSeasonEpisodeCount: season.episodes.count,
                        isSpecial: false,
                        titleOnlySearch: episode.unitProjection?.edition == .feature,
                        unitProjection: episode.unitProjection
                    )
                    if let persisted {
                        if AnimeEpisodeIdentityPolicy.isSameEpisode(
                            persisted,
                            candidate,
                            providerAliases: aliases
                        ) {
                            return candidate
                        }
                    } else if candidate.unitProjection == nil, season.seasonNumber == seed.currentSeasonNumber,
                              episode.number == seed.currentEpisodeNumber {
                        return candidate
                    }
                }
            }
        }

        for special in specialContexts {
            let candidates: [TMDBEpisode]
            if let tmdbSeason = persisted?.resolvedTMDBSeasonNumber,
               let tmdbEpisode = persisted?.resolvedTMDBEpisodeNumber {
                candidates = special.episodes.filter {
                    let candidate = special.playbackContext(for: $0)
                    return candidate.resolvedTMDBSeasonNumber == tmdbSeason
                        && candidate.resolvedTMDBEpisodeNumber == tmdbEpisode
                }
            } else {
                candidates = special.episodes.filter {
                    $0.episodeNumber == episodeNumber
                        && (persisted?.hasAnimeMediaId == true
                            || special.localSeasonNumber == seed.currentSeasonNumber)
                }
            }
            for episode in candidates {
                let candidate = special.playbackContext(for: episode)
                if let persisted {
                    if AnimeEpisodeIdentityPolicy.isSameEpisode(
                        persisted,
                        candidate,
                        providerAliases: aliases
                    ) {
                        return candidate
                    }
                } else if special.localSeasonNumber == seed.currentSeasonNumber,
                          episode.episodeNumber == seed.currentEpisodeNumber {
                    return candidate
                }
            }
        }

        return persisted?.hasAnimeMediaId == true ? nil : persisted
    }

    private func isCanonicalCurrentItem(
        _ item: PlayerEpisodeBrowserItem,
        currentContext: EpisodePlaybackContext?
    ) -> Bool {
        isCanonicalCurrentEpisode(
            item.episode,
            isSpecial: item.isSpecial,
            playbackContext: item.playbackContext,
            currentContext: currentContext
        )
    }

    private func isCanonicalCurrentEpisode(
        _ episode: TMDBEpisode,
        isSpecial: Bool,
        playbackContext: EpisodePlaybackContext?,
        currentContext: EpisodePlaybackContext?
    ) -> Bool {
        if seed.isAnime,
           seed.currentPlaybackContext?.hasAnimeMediaId == true,
           canonicalCurrentPlaybackContext == nil {
            return false
        }
        guard let currentContext else {
            return playbackContext?.unitProjection == nil && episode.seasonNumber == seed.currentSeasonNumber
                && episode.episodeNumber == seed.currentEpisodeNumber
        }
        if let playbackContext {
            return isSpecial == currentContext.isSpecial
                && AnimeEpisodeIdentityPolicy.isSameEpisode(
                    currentContext,
                    playbackContext
                )
        }
        return episode.seasonNumber == currentContext.localSeasonNumber
            && episode.episodeNumber == currentContext.localEpisodeNumber
    }

    private func absoluteEpisodeOffsetsBySeason(for seasons: [AniListSeasonWithPoster]) -> [Int: Int] {
        var offsets: [Int: Int] = [:]
        var absoluteOffset = 0

        for season in seasons.sorted(by: { $0.seasonNumber < $1.seasonNumber }) {
            offsets[season.seasonNumber] = absoluteOffset
            absoluteOffset = RemoteMediaNumericBoundary.adding(
                absoluteOffset,
                season.episodes.count
            ) ?? RemoteMediaNumericBoundary.maximumTotalEpisodeCount
        }

        return offsets
    }

    private func buildAnimeSeason(_ season: AniListSeasonWithPoster, absoluteEpisodeOffset: Int, showTitle: String, showPosterURL: String?, imdbId: String?, originalAudioLanguage: String?) -> PlayerEpisodeBrowserSeason {
        let title = season.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Season \(season.seasonNumber)" : season.title
        let items = season.episodes
            .sorted { $0.number < $1.number }
            .map { aniEpisode -> PlayerEpisodeBrowserItem in
                let episode = TMDBEpisode(
                    id: RemoteMediaNumericBoundary.syntheticIdentifier([
                        (seed.showId, 1_000),
                        (season.seasonNumber, 100),
                        (aniEpisode.number, 1)
                    ]),
                    name: aniEpisode.title,
                    overview: aniEpisode.description,
                    stillPath: aniEpisode.stillPath,
                    episodeNumber: aniEpisode.number,
                    seasonNumber: season.seasonNumber,
                    airDate: aniEpisode.airDate,
                    runtime: aniEpisode.runtime,
                    voteAverage: 0,
                    voteCount: 0
                )
                let context = EpisodePlaybackContext(
                    localSeasonNumber: season.seasonNumber,
                    localEpisodeNumber: aniEpisode.number,
                    anilistMediaId: season.anilistId,
                    canonicalAniListMediaId: season.canonicalAniListId
                        ?? (season.anilistId > 0 ? season.anilistId : nil),
                    malMediaId: season.malId,
                    kitsuMediaId: season.kitsuId,
                    tmdbSeasonNumber: aniEpisode.tmdbSeasonNumber,
                    tmdbEpisodeNumber: aniEpisode.tmdbEpisodeNumber,
                    tmdbEpisodeOffset: nil,
                    animeAbsoluteEpisodeNumber: RemoteMediaNumericBoundary.adding(
                        absoluteEpisodeOffset,
                        aniEpisode.number
                    ),
                    animeSeasonEpisodeCount: season.episodes.count,
                    isSpecial: false,
                    titleOnlySearch: aniEpisode.unitProjection?.edition == .feature,
                    unitProjection: aniEpisode.unitProjection
                )
                return buildItem(
                    episode: episode,
                    showTitle: showTitle,
                    showPosterURL: showPosterURL,
                    mediaTitle: title,
                    seasonTitleOverride: title,
                    animeSeasonTitle: title,
                    originalTitle: nil,
                    originalAudioLanguage: originalAudioLanguage,
                    posterURL: season.posterUrl ?? showPosterURL,
                    imdbId: imdbId,
                    isAnime: true,
                    isSpecial: false,
                    playbackContext: context,
                    originalTMDBSeasonNumber: context.resolvedTMDBSeasonNumber,
                    originalTMDBEpisodeNumber: context.resolvedTMDBEpisodeNumber
                )
            }
        return PlayerEpisodeBrowserSeason(
            id: "anime-\(season.seasonNumber)-\(season.anilistId)",
            title: title,
            subtitle: "Season \(season.seasonNumber)",
            posterURL: season.posterUrl ?? showPosterURL,
            episodes: items
        )
    }

    private func buildTMDBSeason(summary: TMDBSeason, detail: TMDBSeasonDetail, showTitle: String, showPosterURL: String?, imdbId: String?, isSpecial: Bool, originalAudioLanguage: String?) -> PlayerEpisodeBrowserSeason {
        let title = isSpecial ? "Specials" : (summary.name.isEmpty ? "Season \(summary.seasonNumber)" : summary.name)
        let posterURL = detail.fullPosterURL ?? summary.fullPosterURL ?? showPosterURL
        let items = detail.episodes
            .sorted { $0.episodeNumber < $1.episodeNumber }
            .map { episode in
                buildItem(
                    episode: episode,
                    showTitle: showTitle,
                    showPosterURL: showPosterURL,
                    mediaTitle: showTitle,
                    seasonTitleOverride: nil,
                    animeSeasonTitle: nil,
                    originalTitle: nil,
                    originalAudioLanguage: originalAudioLanguage,
                    posterURL: posterURL,
                    imdbId: imdbId,
                    isAnime: false,
                    isSpecial: isSpecial,
                    playbackContext: nil,
                    originalTMDBSeasonNumber: nil,
                    originalTMDBEpisodeNumber: nil
                )
            }
        return PlayerEpisodeBrowserSeason(
            id: "tmdb-\(summary.seasonNumber)-\(summary.id)",
            title: title,
            subtitle: isSpecial ? nil : "Season \(summary.seasonNumber)",
            posterURL: posterURL,
            episodes: items
        )
    }

    private func buildSpecialSeason(context: SpecialEpisodeListContext, showTitle: String, showPosterURL: String?, fallbackImdbId: String?, originalAudioLanguage: String?) -> PlayerEpisodeBrowserSeason {
        let posterURL = context.posterUrl ?? showPosterURL
        let items = context.episodes.map { episode -> PlayerEpisodeBrowserItem in
            let playbackContext = context.playbackContext(for: episode)
            return buildItem(
                episode: episode,
                showTitle: showTitle,
                showPosterURL: showPosterURL,
                mediaTitle: context.title,
                seasonTitleOverride: context.title,
                animeSeasonTitle: context.title,
                originalTitle: context.alternateTitle,
                originalAudioLanguage: originalAudioLanguage,
                posterURL: posterURL,
                imdbId: context.imdbId ?? fallbackImdbId,
                isAnime: true,
                isSpecial: true,
                playbackContext: playbackContext,
                originalTMDBSeasonNumber: playbackContext.resolvedTMDBSeasonNumber,
                originalTMDBEpisodeNumber: playbackContext.resolvedTMDBEpisodeNumber
            )
        }
        return PlayerEpisodeBrowserSeason(
            id: "special-\(context.id)",
            title: context.title,
            subtitle: context.formatLabel,
            posterURL: posterURL,
            episodes: items
        )
    }

    private func buildItem(
        episode: TMDBEpisode,
        showTitle: String,
        showPosterURL: String?,
        mediaTitle: String,
        seasonTitleOverride: String?,
        animeSeasonTitle: String?,
        originalTitle: String?,
        originalAudioLanguage: String?,
        posterURL: String?,
        imdbId: String?,
        isAnime: Bool,
        isSpecial: Bool,
        playbackContext: EpisodePlaybackContext?,
        originalTMDBSeasonNumber: Int?,
        originalTMDBEpisodeNumber: Int?
    ) -> PlayerEpisodeBrowserItem {
        refreshEpisodeLookups()
        let progress = progressForEpisode(episode, context: playbackContext)
        #if !os(tvOS)
        let download: DownloadItem?
        #if os(iOS) || os(macOS)
        download = completedDownload(for: episode, context: playbackContext)
        #else
        download = DownloadManager.shared.completedDownloadItem(
            tmdbId: seed.showId,
            isMovie: false,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber
        )
        #endif
        #endif
        let isCurrent = isCanonicalCurrentEpisode(
            episode,
            isSpecial: isSpecial,
            playbackContext: playbackContext,
            currentContext: canonicalCurrentPlaybackContext ?? seed.currentPlaybackContext
        )
        let id = "\(episode.seasonNumber)-\(episode.episodeNumber)-\(episode.id)-\(isSpecial ? "special" : "main")"
        #if os(tvOS)
        return PlayerEpisodeBrowserItem(
            id: id,
            showId: seed.showId,
            showTitle: showTitle,
            showPosterURL: showPosterURL,
            mediaTitle: mediaTitle,
            seasonTitleOverride: seasonTitleOverride,
            animeSeasonTitle: animeSeasonTitle,
            originalTitle: originalTitle,
            posterURL: posterURL,
            originalAudioLanguage: originalAudioLanguage,
            imdbId: imdbId,
            episode: episode,
            isAnime: isAnime,
            isSpecial: isSpecial,
            playbackContext: playbackContext,
            originalTMDBSeasonNumber: originalTMDBSeasonNumber,
            originalTMDBEpisodeNumber: originalTMDBEpisodeNumber,
            progress: progress,
            isDownloaded: false,
            isCurrent: isCurrent,
            mediaYear: resolvedMediaYear
        )
        #else
        return PlayerEpisodeBrowserItem(
            id: id,
            showId: seed.showId,
            showTitle: showTitle,
            showPosterURL: showPosterURL,
            mediaTitle: mediaTitle,
            seasonTitleOverride: seasonTitleOverride,
            animeSeasonTitle: animeSeasonTitle,
            originalTitle: originalTitle,
            posterURL: posterURL,
            originalAudioLanguage: originalAudioLanguage,
            imdbId: imdbId,
            episode: episode,
            isAnime: isAnime,
            isSpecial: isSpecial,
            playbackContext: playbackContext,
            originalTMDBSeasonNumber: originalTMDBSeasonNumber,
            originalTMDBEpisodeNumber: originalTMDBEpisodeNumber,
            progress: progress,
            isDownloaded: download != nil,
            downloadItem: download,
            isCurrent: isCurrent,
            mediaYear: resolvedMediaYear
        )
        #endif
    }

    nonisolated static func fullImageURL(from path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return TMDBImageRequestPolicy.urlString(for: path, kind: .still)
    }
}

struct PlayerEpisodeBrowserDrawer: View {
    @StateObject private var viewModel: PlayerEpisodeBrowserViewModel
    @State private var selectedSeasonID: String?
    @State private var didManuallySelectSeason = false
    let onClose: () -> Void
    let onEpisodeSelected: (PlayerEpisodeBrowserItem) -> Void

    init(
        seed: PlayerEpisodeBrowserSeed,
        onClose: @escaping () -> Void,
        onEpisodeSelected: @escaping (PlayerEpisodeBrowserItem) -> Void
    ) {
        _viewModel = StateObject(wrappedValue: PlayerEpisodeBrowserViewModel(seed: seed))
        self.onClose = onClose
        self.onEpisodeSelected = onEpisodeSelected
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .trailing) {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onClose)

                drawerContent
                    .frame(width: drawerWidth(for: proxy.size.width), height: proxy.size.height)
                    .background(Color.black.opacity(0.86))
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.white.opacity(0.12))
                            .frame(width: 1)
                    }
            }
        }
        .task {
            await viewModel.loadIfNeeded()
        }
    }

    private var drawerContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Episodes")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                    Text(viewModel.seed.showTitle)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.68))
                        .lineLimit(1)
                }

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()
                .background(Color.white.opacity(0.12))

            if viewModel.isLoading && viewModel.seasons.isEmpty {
                Spacer()
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                Spacer()
            } else if let error = viewModel.errorMessage, viewModel.seasons.isEmpty {
                Spacer()
                Text(error)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Spacer()
            } else {
                seasonSelector
                selectedSeasonEpisodes
            }
        }
        .onAppear {
            syncSelectedSeasonIfNeeded()
        }
        .onChange(of: viewModel.seasons.map(\.id)) { _ in
            syncSelectedSeasonIfNeeded()
        }
        .onChange(of: viewModel.currentItemID) { _ in
            syncSelectedSeasonIfNeeded()
        }
    }

    private var selectedSeason: PlayerEpisodeBrowserSeason? {
        if let selectedSeasonID,
           let season = viewModel.seasons.first(where: { $0.id == selectedSeasonID }) {
            return season
        }
        return currentSeason ?? viewModel.seasons.first
    }

    private var currentSeason: PlayerEpisodeBrowserSeason? {
        guard let currentID = viewModel.currentItemID else { return nil }
        return viewModel.seasons.first { season in
            season.episodes.contains(where: { $0.id == currentID })
        }
    }

    private var seasonSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedSeason?.title ?? "Season")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if let subtitle = selectedSeasonSubtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.58))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if viewModel.seasons.count > 1 {
                    Menu {
                        ForEach(viewModel.seasons) { season in
                            Button {
                                selectSeason(season)
                            } label: {
                                Label(
                                    seasonMenuTitle(season),
                                    systemImage: season.id == selectedSeason?.id ? "checkmark" : "tv"
                                )
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("Change")
                                .font(.caption)
                                .fontWeight(.semibold)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Capsule())
                    }
                }
            }

            if viewModel.seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(viewModel.seasons) { season in
                            seasonChip(season)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(height: episodeSeasonPickerHeight)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.22))
    }

    private var selectedSeasonSubtitle: String? {
        guard let season = selectedSeason else { return nil }
        let episodeText = "\(season.episodes.count) episode\(season.episodes.count == 1 ? "" : "s")"
        if let subtitle = season.subtitle, !subtitle.isEmpty {
            return "\(subtitle) - \(episodeText)"
        }
        return episodeText
    }

    private var selectedSeasonEpisodes: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10, pinnedViews: []) {
                    Color.clear
                        .frame(height: 0)
                        .id("selected-season-top")

                    if let season = selectedSeason {
                        ForEach(season.episodes) { item in
                            episodeRow(item)
                                .id(item.id)
                        }
                    } else if viewModel.isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 28)
                    } else {
                        Text("No episodes found.")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.68))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 28)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .onChange(of: selectedSeasonID) { _ in
                scrollToSelectedSeasonStart(proxy: proxy)
            }
            .onChange(of: viewModel.currentItemID) { _ in
                scrollToCurrentIfVisible(proxy: proxy)
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    scrollToCurrentIfVisible(proxy: proxy)
                }
            }
        }
    }

    private func seasonChip(_ season: PlayerEpisodeBrowserSeason) -> some View {
        let selected = season.id == selectedSeason?.id
        return Button {
            selectSeason(season)
        } label: {
            HStack(spacing: 6) {
                if season.episodes.contains(where: { $0.isCurrent }) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                }
                Text(seasonChipTitle(season))
                    .font(.caption)
                    .fontWeight(selected ? .semibold : .medium)
                    .lineLimit(1)
            }
            .foregroundColor(.white.opacity(selected ? 1.0 : 0.72))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selected ? Color.white.opacity(0.18) : Color.white.opacity(0.08))
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(selected ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func selectSeason(_ season: PlayerEpisodeBrowserSeason) {
        didManuallySelectSeason = true
        selectedSeasonID = season.id
    }

    private func syncSelectedSeasonIfNeeded() {
        guard !viewModel.seasons.isEmpty else {
            selectedSeasonID = nil
            didManuallySelectSeason = false
            return
        }

        if let selectedSeasonID,
           viewModel.seasons.contains(where: { $0.id == selectedSeasonID }) {
            return
        }

        if !didManuallySelectSeason, let currentSeason {
            selectedSeasonID = currentSeason.id
        } else {
            selectedSeasonID = viewModel.seasons.first?.id
        }
    }

    private func scrollToSelectedSeasonStart(proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("selected-season-top", anchor: .top)
            }
        }
    }

    private func scrollToCurrentIfVisible(proxy: ScrollViewProxy) {
        guard let id = viewModel.currentItemID,
              selectedSeason?.episodes.contains(where: { $0.id == id }) == true else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private func seasonChipTitle(_ season: PlayerEpisodeBrowserSeason) -> String {
        if season.episodes.first?.isSpecial == true {
            return season.title
        }
        if let subtitle = season.subtitle, !subtitle.isEmpty {
            return subtitle
        }
        return season.title
    }

    private func seasonMenuTitle(_ season: PlayerEpisodeBrowserSeason) -> String {
        let title = seasonChipTitle(season)
        return "\(title) (\(season.episodes.count))"
    }

    private func episodeRow(_ item: PlayerEpisodeBrowserItem) -> some View {
        Button {
            onEpisodeSelected(item)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                episodeImage(item)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(item.displayCode)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.white.opacity(0.72))

                        if item.isCurrent {
                            Text("Now Playing")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.25))
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                        } else if item.isDownloaded {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.caption)
                                .foregroundColor(.green)
                        }

                        Spacer(minLength: 0)
                    }

                    Text(item.displayTitle)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if let overview = item.episode.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.58))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }

                    HStack(spacing: 8) {
                        if let runtime = item.episode.runtime, runtime > 0 {
                            Text("\(runtime)m")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.58))
                        }
                        if item.episode.voteAverage > 0 {
                            Label(String(format: "%.1f", item.episode.voteAverage), systemImage: "star.fill")
                                .font(.caption2)
                                .foregroundColor(.yellow.opacity(0.9))
                        }
                        Spacer(minLength: 0)
                    }

                    if item.progress > 0 && item.progress < 0.95 {
                        ProgressView(value: item.progress)
                            .progressViewStyle(LinearProgressViewStyle(tint: .accentColor))
                            .frame(height: 3)
                    }
                }
            }
            .padding(8)
            .background(item.isCurrent ? Color.white.opacity(0.12) : Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(item.isCurrent ? Color.accentColor.opacity(0.7) : Color.white.opacity(0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(item.isCurrent)
    }

    private func episodeImage(_ item: PlayerEpisodeBrowserItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.1))

            if let imageURL = item.imageURL, let url = URL(string: imageURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        Image(systemName: item.isSpecial ? "sparkles" : "tv")
                            .font(.title3)
                            .foregroundColor(.white.opacity(0.55))
                    }
                }
            } else {
                Image(systemName: item.isSpecial ? "sparkles" : "tv")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.55))
            }
        }
        .frame(width: 92, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var episodeSeasonPickerHeight: CGFloat? {
#if os(macOS)
        38
#else
        UIDevice.current.userInterfaceIdiom == .pad ? 38 : nil
#endif
    }

    private func drawerWidth(for totalWidth: CGFloat) -> CGFloat {
        if totalWidth < 700 {
            return min(totalWidth, max(300, totalWidth * 0.86))
        }
        return min(460, max(360, totalWidth * 0.42))
    }
}

