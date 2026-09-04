//
//  ShowsDetails.swift
//  Sora
//
//  Created by Francesco on 07/08/25.
//

import SwiftUI
import Kingfisher
import AVKit

struct TVShowDetailsSection: View {
    let tvShow: TMDBTVShowWithSeasons?
    let ratingOverride: String?
    var compactHeroMetadata: Bool
    @AppStorage(MediaDetailAgeRatingSettings.enabledKey) private var showsAgeRating = MediaDetailAgeRatingSettings.defaultEnabled

    init(tvShow: TMDBTVShowWithSeasons?, ratingOverride: String? = nil, compactHeroMetadata: Bool = false) {
        self.tvShow = tvShow
        self.ratingOverride = ratingOverride
        self.compactHeroMetadata = compactHeroMetadata
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let tvShow {
                Text("Details")
                    .font(.title2)
                    .fontWeight(.bold)
                    .padding(.horizontal)
                    .padding(.top)
                    .foregroundColor(.white)

                VStack(spacing: 12) {
                    if let numberOfSeasons = tvShow.numberOfSeasons, numberOfSeasons > 0 {
                        DetailRow(title: "Seasons", value: "\(numberOfSeasons)")
                    }

                    if let numberOfEpisodes = tvShow.numberOfEpisodes, numberOfEpisodes > 0 {
                        DetailRow(title: "Episodes", value: "\(numberOfEpisodes)")
                    }

                    if !compactHeroMetadata && !tvShow.genres.isEmpty {
                        DetailRow(title: "Genres", value: tvShow.genres.map { $0.name }.joined(separator: ", "))
                    }

                    if !compactHeroMetadata, let ratingOverride {
                        DetailRow(title: "Rating", value: ratingOverride)
                    } else if !compactHeroMetadata && tvShow.voteAverage > 0 {
                        DetailRow(title: "Rating", value: String(format: "%.1f/10", tvShow.voteAverage))
                    }

                    if showsAgeRating, let ageRating = getAgeRating(from: tvShow.contentRatings) {
                        DetailRow(title: "Age Rating", value: ageRating)
                    }

                    if !compactHeroMetadata, let firstAirDate = tvShow.firstAirDate, !firstAirDate.isEmpty {
                        DetailRow(title: "First aired", value: "\(firstAirDate)")
                    }

                    if !compactHeroMetadata, let lastAirDate = tvShow.lastAirDate, !lastAirDate.isEmpty {
                        DetailRow(title: "Last aired", value: "\(lastAirDate)")
                    }

                    if let status = tvShow.status {
                        DetailRow(title: "Status", value: status)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 16)
                .applyLiquidGlassBackground(cornerRadius: 16)
                .padding(.horizontal)
            }
        }
    }

    private func getAgeRating(from contentRatings: TMDBContentRatings?) -> String? {
        contentRatings?.preferredCertification?.value
    }
}

#if os(iOS)
private struct ShowDetailsWindowSceneReader: UIViewRepresentable {
    let onResolve: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onResolve = onResolve
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.onResolve = onResolve
        uiView.resolveIfAttached()
    }

    final class ProbeView: UIView {
        var onResolve: ((UIWindowScene) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            resolveIfAttached()
        }

        func resolveIfAttached() {
            guard let scene = window?.windowScene else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onResolve?(scene)
            }
        }
    }
}
#endif

struct AnimeEpisodeContextIndex {
    struct Key: Hashable {
        let seasonNumber: Int
        let episodeNumber: Int
    }

    private let episodeByKey: [Key: AniListEpisode]
    private let absoluteNumberByKey: [Key: Int]
    private let episodesBySeason: [Int: [AniListEpisode]]

    init(episodes: [AniListEpisode]) {
        let ordered = episodes.sorted { lhs, rhs in
            if lhs.seasonNumber == rhs.seasonNumber {
                return lhs.number < rhs.number
            }
            return lhs.seasonNumber < rhs.seasonNumber
        }

        var episodeByKey: [Key: AniListEpisode] = [:]
        var absoluteNumberByKey: [Key: Int] = [:]
        var episodesBySeason: [Int: [AniListEpisode]] = [:]
        episodeByKey.reserveCapacity(ordered.count)
        absoluteNumberByKey.reserveCapacity(ordered.count)

        for (index, episode) in ordered.enumerated() {
            let key = Key(seasonNumber: episode.seasonNumber, episodeNumber: episode.number)

            if episodeByKey[key] == nil {
                episodeByKey[key] = episode
                absoluteNumberByKey[key] = index + 1
            }
            episodesBySeason[episode.seasonNumber, default: []].append(episode)
        }

        self.episodeByKey = episodeByKey
        self.absoluteNumberByKey = absoluteNumberByKey
        self.episodesBySeason = episodesBySeason
    }

    func episode(seasonNumber: Int, episodeNumber: Int) -> AniListEpisode? {
        episodeByKey[Key(seasonNumber: seasonNumber, episodeNumber: episodeNumber)]
    }

    func absoluteNumber(seasonNumber: Int, episodeNumber: Int) -> Int? {
        absoluteNumberByKey[Key(seasonNumber: seasonNumber, episodeNumber: episodeNumber)]
    }

    func episodes(seasonNumber: Int) -> [AniListEpisode] {
        episodesBySeason[seasonNumber] ?? []
    }

    func episodeCount(seasonNumber: Int) -> Int? {
        guard let count = episodesBySeason[seasonNumber]?.count, count > 0 else { return nil }
        return count
    }
}

struct TVShowSeasonsSection<InsertedContent: View>: View {
    let tvShow: TMDBTVShowWithSeasons?
    let isAnime: Bool
    @Binding var selectedSeason: TMDBSeason?
    @Binding var seasonDetail: TMDBSeasonDetail?
    @Binding var selectedEpisodeForSearch: TMDBEpisode?
    @Binding var specialEpisodeContext: SpecialEpisodeListContext?
    let seasonSelectorInsertedContent: AnyView
    let hasSpecialEpisodeChoices: Bool
    var animeEpisodes: [AniListEpisode]? = nil
    let animeEpisodeContextIndex: AnimeEpisodeContextIndex
    var animeSeasonTitles: [Int: String]? = nil
    var animeSeasonRomajiTitles: [Int: String] = [:]
    var animeSeasonAniListIds: [Int: Int] = [:]
    var animeSeasonKitsuIds: [Int: Int] = [:]
    var animeProviderAliases: [Int: Int] = [:]
    let nextEpisodeNotificationRoute: UUID
    var showsMetadataDetails: Bool = true
    var showsInsertedContent: Bool = true
    var defersInitialSeasonLoad = false
    let tmdbService: TMDBService
    @ViewBuilder let insertedContent: () -> InsertedContent

    @State private var isLoadingSeason = false
    @State private var showingSearchResults = false
    @State private var selectedEpisodePlaybackContext: EpisodePlaybackContext?
    @StateObject private var autoModeRetrySession = AutoModeRetrySession()
#if !os(tvOS)
    @State private var showingDownloadSheet = false
    @State private var presentationSceneIdentifier: String?
    @State private var downloadEpisode: TMDBEpisode? = nil
    @State private var downloadEpisodePlaybackContext: EpisodePlaybackContext?
    @State private var downloadAllQueue: [TMDBEpisode] = []
    @State private var downloadAllSpecialContext: SpecialEpisodeListContext?
    @State private var isDownloadingAll = false
    @State private var downloadWasEnqueued = false
    @State private var downloadWasSkipped = false
#endif
    @State private var showingNoServicesAlert = false
    @State private var romajiTitle: String?
    @State private var currentSeasonTitle: String?
    @State private var seasonLoadTask: Task<Void, Never>?
    @State private var seasonLoadGeneration = 0
    @State private var selectedEpisodePageStartByKey: [String: Int] = [:]
    @State private var hydratedAnimeEpisodePageKeys = Set<String>()
#if os(iOS)
    @State private var episodeClassificationsBySeason: [Int: AnimeEpisodeClassifications] = [:]
#endif

    @StateObject private var serviceManager = ServiceManager.shared
    @StateObject private var stremioManager = StremioAddonManager.shared
#if os(iOS) && !targetEnvironment(macCatalyst)
    @StateObject private var skyStreamPluginManager = SkyStreamPluginManager.shared
    @StateObject private var nuvioPluginManager = NuvioPluginManager.shared
#endif
    @StateObject private var accentManager = AccentColorManager.shared
#if !os(tvOS)
    private let downloadManager = DownloadManager.shared
#endif
    @AppStorage(MediaDetailPlatformDefaults.horizontalEpisodeListKey) private var horizontalEpisodeList = MediaDetailPlatformDefaults.prefersHorizontalEpisodes
    @AppStorage(MediaDetailEpisodeVisibilitySettings.showUnairedEpisodesKey) private var showUnairedEpisodes = MediaDetailEpisodeVisibilitySettings.defaultShowUnairedEpisodes
#if !os(tvOS)
    @AppStorage("preferDownloadedMedia") private var preferDownloadedMedia: Bool = false
#endif
    private var isGroupedBySeasons: Bool {
        return tvShow?.seasons.filter { $0.seasonNumber > 0 }.count ?? 0 > 1
    }

    private var useSeasonMenu: Bool {
        MediaDetailPlatformDefaults.usesCompactSeasonMenu()
    }

    private func shouldShowSeasonSwitcher(for seasons: [TMDBSeason]) -> Bool {
        seasons.count > 1 || (isAnime && !seasons.isEmpty && (hasSpecialEpisodeChoices || specialEpisodeContext != nil))
    }

    private var hasActiveSources: Bool {
        !serviceManager.activeServices.isEmpty ||
        !stremioManager.activeAddons.isEmpty ||
        hasActiveSkyStreamSources ||
        hasActiveNuvioSources
    }

    private var hasActiveSkyStreamSources: Bool {
#if os(iOS) && !targetEnvironment(macCatalyst)
        PlatformCapabilities.current.supportsSkyStreamPlugins
            && skyStreamPluginManager.providers.contains(where: \.isEnabled)
#else
        false
#endif
    }

    private var hasActiveNuvioSources: Bool {
#if os(iOS) && !targetEnvironment(macCatalyst)
        PlatformCapabilities.current.supportsNuvioPlugins
            && !nuvioPluginManager.enabledRepositories.isEmpty
#else
        false
#endif
    }

    private var sourceMatchingYear: Int? {
        guard let firstAirDate = tvShow?.firstAirDate else { return nil }
        return Int(firstAirDate.prefix(4))
    }

    private var activeSeasonDetail: TMDBSeasonDetail? {
        specialEpisodeContext?.seasonDetail ?? seasonDetail
    }

    private var activeSeasonTitle: String? {
        specialEpisodeContext?.title ?? currentSeasonTitle
    }

    private var autoModeTargetToken: String {
        AutoModeMediaTargetToken.make(
            tmdbID: tvShow?.id ?? 0,
            isMovie: false,
            episode: selectedEpisodeForSearch,
            playbackContext: selectedEpisodePlaybackContext
        )
    }

    private struct EpisodeRenderItem: Identifiable {
        let id: String
        let index: Int
        let episode: TMDBEpisode
    }

    private struct EpisodePage: Identifiable {
        let startIndex: Int
        let endIndex: Int

        var id: Int { startIndex }
        var title: String { "\(startIndex + 1)-\(endIndex)" }
    }

    private let episodePageSize = 100

    private func visibleEpisodes(for detail: TMDBSeasonDetail) -> [TMDBEpisode] {
        guard !showUnairedEpisodes else { return detail.episodes }
        let today = currentAirDateString()
        return detail.episodes.filter { episode in
            guard let airDate = validatedAirDateString(episode.airDate) else {

                return false
            }
            return airDate <= today
        }
    }

    private func validatedAirDateString(_ airDate: String?) -> String? {
        guard let airDate = airDate?.prefix(10), airDate.count == 10 else {
            return nil
        }

        let dateString = String(airDate)
        let parts = dateString.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return nil }
        let normalized = calendar.dateComponents([.year, .month, .day], from: date)
        guard normalized.year == year, normalized.month == month, normalized.day == day else {
            return nil
        }

        return dateString
    }

    private func currentAirDateString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func episodeRenderItems(for detail: TMDBSeasonDetail) -> [EpisodeRenderItem] {
        visibleEpisodes(for: detail).enumerated().map { index, episode in
            EpisodeRenderItem(
                id: "\(detail.seasonNumber)-\(episode.seasonNumber)-\(episode.episodeNumber)-\(episode.id)-\(index)",
                index: index,
                episode: episode
            )
        }
    }

    private func seasonDebugSummary(_ seasons: [TMDBSeason], limit: Int = 8) -> String {
        seasons.prefix(limit).map { season in
            "s\(season.seasonNumber):id\(season.id):eps\(season.episodeCount)"
        }.joined(separator: "|")
    }

    private func getSearchTitle() -> String {
        if let specialEpisodeContext {
            return specialEpisodeContext.title
        }
        if isAnime, let currentSeasonTitle, !currentSeasonTitle.isEmpty {
            return currentSeasonTitle
        }
        if isAnime, let seasonName = selectedSeason?.name, !seasonName.isEmpty {
            return seasonName
        }
        return tvShow?.name ?? "Unknown Show"
    }

    private func getOriginalTitle(for episode: TMDBEpisode?) -> String? {
        if let specialEpisodeContext {
            return specialEpisodeContext.alternateTitle ?? romajiTitle
        }
        if isAnime,
           let seasonNumber = episode?.seasonNumber ?? selectedSeason?.seasonNumber,
           let seasonRomaji = animeSeasonRomajiTitles[seasonNumber],
           !seasonRomaji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return seasonRomaji
        }
        return romajiTitle
    }

    private func playbackContext(for episode: TMDBEpisode) -> EpisodePlaybackContext? {
        if let specialEpisodeContext {
            return specialEpisodeContext.playbackContext(for: episode)
        }

        guard isAnime else { return nil }

        if PerformanceModeSettings.skipsAniListTraversalForAnimeDetails {
            return EpisodePlaybackContext(
                localSeasonNumber: episode.seasonNumber,
                localEpisodeNumber: episode.episodeNumber,
                anilistMediaId: nil,
                kitsuMediaId: nil,
                tmdbSeasonNumber: episode.seasonNumber,
                tmdbEpisodeNumber: episode.episodeNumber,
                tmdbEpisodeOffset: nil,
                animeAbsoluteEpisodeNumber: nil,
                animeSeasonEpisodeCount: nil,
                isSpecial: false,
                titleOnlySearch: false
            )
        }

        let aniEpisode = animeEpisodeContextIndex.episode(
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber
        )
        let absoluteEpisodeNumber = animeEpisodeContextIndex.absoluteNumber(
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber
        )

        guard aniEpisode != nil ||
              absoluteEpisodeNumber != nil ||
              animeSeasonAniListIds[episode.seasonNumber] != nil ||
              animeSeasonKitsuIds[episode.seasonNumber] != nil else {
            return nil
        }

        return EpisodePlaybackContext(
            localSeasonNumber: episode.seasonNumber,
            localEpisodeNumber: episode.episodeNumber,
            anilistMediaId: animeSeasonAniListIds[episode.seasonNumber],
            canonicalAniListMediaId: animeSeasonAniListIds[episode.seasonNumber].flatMap {
                let canonical = animeProviderAliases[$0] ?? $0
                return canonical > 0 ? canonical : nil
            },
            malMediaId: animeSeasonAniListIds[episode.seasonNumber].flatMap { providerID in
                if providerID < 0 {
                    return RemoteMediaNumericBoundary.positiveMagnitude(providerID)
                }
                let canonical = animeProviderAliases[providerID] ?? providerID
                return animeProviderAliases.first(where: {
                    $0.key < 0 && $0.value == canonical
                }).flatMap { RemoteMediaNumericBoundary.positiveMagnitude($0.key) }
            },
            kitsuMediaId: animeSeasonKitsuIds[episode.seasonNumber],
            tmdbSeasonNumber: aniEpisode?.tmdbSeasonNumber,
            tmdbEpisodeNumber: aniEpisode?.tmdbEpisodeNumber,
            tmdbEpisodeOffset: nil,
            animeAbsoluteEpisodeNumber: absoluteEpisodeNumber,
            animeSeasonEpisodeCount: animeEpisodeContextIndex.episodeCount(seasonNumber: episode.seasonNumber),
            isSpecial: false,
            titleOnlySearch: false
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let tvShow = tvShow {
                if showsMetadataDetails {
                    TVShowDetailsSection(tvShow: tvShow)
                }

                if showsInsertedContent {
                    insertedContent()
                }

                if !tvShow.seasons.isEmpty {
                    let regularSeasons = tvShow.seasons.filter { $0.seasonNumber > 0 }
                    let showSeasonSwitcher = shouldShowSeasonSwitcher(for: regularSeasons)
                    if showSeasonSwitcher && !useSeasonMenu {
                        HStack {
                            Text("Seasons")
                                .font(.title2)
                                .fontWeight(.bold)
                            Spacer()
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal)
                        .padding(.top)

                        seasonSelectorStyled
                        seasonSelectorInsertedContent

                        HStack {
                            Text(specialEpisodeContext?.title ?? "Episodes")
                                .font(.title2)
                                .fontWeight(.bold)

                            Spacer()

                            if let activeSeasonDetail {
                                episodePageMenu(for: activeSeasonDetail)
                            }

#if !os(tvOS)
                            if activeSeasonDetail != nil && hasActiveSources {
                                Button(action: startDownloadAllSeason) {
                                    Image(systemName: "arrow.down.circle")
                                        .font(.title3)
                                        .foregroundColor(.white)
                                }
                                .disabled(isDownloadingAll)
                            }
#endif
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal)
                        .padding(.top)
                    } else {
                        episodesSectionHeader
                        seasonSelectorInsertedContent
                    }

                    episodeListSection
                } else {
                    EmptyView()
                }
            } else {
                EmptyView()
            }
        }
#if os(iOS)
        .background(
            ShowDetailsWindowSceneReader { scene in
                let identifier = scene.session.persistentIdentifier
                if presentationSceneIdentifier != identifier {
                    presentationSceneIdentifier = identifier
                }
            }
            .frame(width: 0, height: 0)
        )
#endif
        .onAppear {
            if let tvShow = tvShow, let selectedSeason = selectedSeason {
                if !defersInitialSeasonLoad {
                    ensureSeasonDetailsLoaded(tvShowId: tvShow.id, season: selectedSeason, reason: "appear")
                }
                Task {
                    let romaji = await tmdbService.getRomajiTitle(for: "tv", id: tvShow.id)
                    await MainActor.run {
                        self.romajiTitle = romaji
                    }
                }
            }
        }
        .onChangeComp(of: defersInitialSeasonLoad) { _, isDeferred in
            guard !isDeferred,
                  let tvShow,
                  let selectedSeason else { return }
            ensureSeasonDetailsLoaded(
                tvShowId: tvShow.id,
                season: selectedSeason,
                reason: "notification-route-finished"
            )
        }
        .onChangeComp(of: autoModeTargetToken) { _, newToken in
            if autoModeRetrySession.targetToken != newToken {
                autoModeRetrySession.reset(targetToken: newToken)
            }
        }
        .onChangeComp(of: selectedEpisodeForSearch?.id) { _, _ in
            revealSelectedEpisodePageIfNeeded()
        }
        .onChangeComp(of: activeSeasonDetail?.id) { _, _ in
            revealSelectedEpisodePageIfNeeded()
        }
        .onDisappear {
            seasonLoadGeneration += 1
            seasonLoadTask?.cancel()
            seasonLoadTask = nil
        }
#if os(iOS)
        .task(id: animeFillerRequestKey) {
            await loadFillerMarkersForSelectedSeason()
        }
#endif
        .sheet(isPresented: $showingSearchResults) {
            let recoveryTargetToken = AutoModeMediaTargetToken.make(
                tmdbID: tvShow?.id ?? 0,
                isMovie: false,
                episode: selectedEpisodeForSearch,
                playbackContext: selectedEpisodePlaybackContext
            )
            let recoveryIdentity = autoModeRetrySession.recoveryIdentity(for: recoveryTargetToken)
            let recoveryEpisode = selectedEpisodeForSearch
            let recoveryPlaybackContext = selectedEpisodePlaybackContext
            ModulesSearchResultsSheet(
                mediaTitle: getSearchTitle(),
                seasonTitleOverride: activeSeasonTitle,
                originalTitle: getOriginalTitle(for: selectedEpisodeForSearch),
                isMovie: false,
                isAnimeContent: isAnime,
                selectedEpisode: selectedEpisodeForSearch,
                tmdbId: tvShow?.id ?? 0,
                mediaYear: sourceMatchingYear,
                animeSeasonTitle: isAnime ? activeSeasonTitle : nil,
                posterPath: specialEpisodeContext?.posterUrl ?? tvShow?.posterPath,
                originalAudioLanguage: tvShow?.originalLanguage,
                imdbId: specialEpisodeContext?.imdbId ?? tvShow?.externalIds?.imdbId,
                originalTMDBSeasonNumber: selectedEpisodePlaybackContext?.resolvedTMDBSeasonNumber ?? originalTMDBNumbers?.season,
                originalTMDBEpisodeNumber: selectedEpisodePlaybackContext?.resolvedTMDBEpisodeNumber ?? originalTMDBNumbers?.episode,
                specialTitleOnlySearch: selectedEpisodePlaybackContext?.titleOnlySearch ?? false,
                episodePlaybackContext: selectedEpisodePlaybackContext,
                autoModeOnly: AutoModeSettings.isEnabled(),
                autoModeRetrySession: autoModeRetrySession,
                autoModeRecoveryIdentity: recoveryIdentity,
                onAutoModePlaybackFailure: { report, identity in
                    Task { @MainActor in
                        handleAutoModePlaybackFailure(
                            report,
                            identity: identity,
                            episode: recoveryEpisode,
                            playbackContext: recoveryPlaybackContext
                        )
                    }
                },
                nextEpisodeNotificationRoute: nextEpisodeNotificationRoute,
                isAnimationGenre16: tvShow?.genres.contains { $0.id == 16 } ?? false
            )
        }
#if !os(tvOS)
        .sheet(isPresented: $showingDownloadSheet, onDismiss: {
            if isDownloadingAll {
                if downloadWasEnqueued || downloadWasSkipped {

                    downloadWasEnqueued = false
                    downloadWasSkipped = false
                    if !downloadAllQueue.isEmpty {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            showNextDownloadSheet()
                        }
                    } else {
                        isDownloadingAll = false
                        downloadAllSpecialContext = nil
                        downloadEpisodePlaybackContext = nil
                    }
                } else {

                    downloadAllQueue.removeAll()
                    isDownloadingAll = false
                    downloadAllSpecialContext = nil
                    downloadEpisodePlaybackContext = nil
                }
            }
        }) {
            ModulesSearchResultsSheet(
                mediaTitle: getSearchTitle(),
                seasonTitleOverride: activeSeasonTitle,
                originalTitle: getOriginalTitle(for: downloadEpisode ?? selectedEpisodeForSearch),
                isMovie: false,
                isAnimeContent: isAnime,
                selectedEpisode: downloadEpisode ?? selectedEpisodeForSearch,
                tmdbId: tvShow?.id ?? 0,
                mediaYear: sourceMatchingYear,
                animeSeasonTitle: isAnime ? activeSeasonTitle : nil,
                posterPath: downloadAllSpecialContext?.posterUrl ?? specialEpisodeContext?.posterUrl ?? tvShow?.posterPath,
                originalAudioLanguage: tvShow?.originalLanguage,
                imdbId: (downloadAllSpecialContext ?? specialEpisodeContext)?.imdbId
                    ?? tvShow?.externalIds?.imdbId,
                originalTMDBSeasonNumber: downloadEpisodePlaybackContext?.resolvedTMDBSeasonNumber ?? selectedEpisodePlaybackContext?.resolvedTMDBSeasonNumber ?? originalTMDBNumbers?.season,
                originalTMDBEpisodeNumber: downloadEpisodePlaybackContext?.resolvedTMDBEpisodeNumber ?? selectedEpisodePlaybackContext?.resolvedTMDBEpisodeNumber ?? originalTMDBNumbers?.episode,
                specialTitleOnlySearch: (downloadEpisodePlaybackContext ?? selectedEpisodePlaybackContext)?.titleOnlySearch ?? false,
                episodePlaybackContext: downloadEpisodePlaybackContext ?? selectedEpisodePlaybackContext,
                downloadMode: true,
                autoModeOnly: AutoModeSettings.isEnabled(),
                onDownloadEnqueued: isDownloadingAll ? {
                    downloadWasEnqueued = true
                } : nil,
                onSkipRequested: isDownloadingAll ? {
                    downloadWasSkipped = true
                } : nil,
                isAnimationGenre16: tvShow?.genres.contains { $0.id == 16 } ?? false
            )
        }
#endif
        .alert("No Active Sources", isPresented: $showingNoServicesAlert) {
            Button("OK") { }
        } message: {
            Text("You don't have any active sources. Open Services settings to add or enable one.")
        }
    }

    @ViewBuilder
    private var episodesSectionHeader: some View {
        let regularSeasons = tvShow?.seasons.filter { $0.seasonNumber > 0 } ?? []
        let showSeasonSwitcher = shouldShowSeasonSwitcher(for: regularSeasons)
        HStack {
            Text(specialEpisodeContext?.title ?? "Episodes")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)

            Spacer()

            if let activeSeasonDetail {
                episodePageMenu(for: activeSeasonDetail)
            }

#if !os(tvOS)
            if activeSeasonDetail != nil && hasActiveSources {
                Button(action: startDownloadAllSeason) {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                        .foregroundColor(.white)
                }
                .disabled(isDownloadingAll)
            }
#endif

            if let tvShow = tvShow, showSeasonSwitcher && useSeasonMenu {
                seasonMenu(for: tvShow)
            }
        }
        .padding(.horizontal)
        .padding(.top)
    }

    @ViewBuilder
    private func seasonMenu(for tvShow: TMDBTVShowWithSeasons) -> some View {
        let seasons = tvShow.seasons.filter { $0.seasonNumber > 0 }

        if shouldShowSeasonSwitcher(for: seasons) {
            Menu {
                ForEach(seasons) { season in
                    Button(action: {
                        selectSeason(season, tvShowId: tvShow.id)
                    }) {
                        HStack {
                            Text(season.name)
                            if specialEpisodeContext == nil && selectedSeason?.id == season.id {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(currentSeasonTitle ?? selectedSeason?.name ?? "Season 1")

                    Image(systemName: "chevron.down")
                }
                .foregroundColor(.white)
            }
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func episodePageMenu(for detail: TMDBSeasonDetail) -> some View {
        let pages = episodePages(for: detail)
        if pages.count > 1, let selectedPage = selectedEpisodePage(for: detail) {
            Menu {
                ForEach(pages) { page in
                    Button(action: {
                        selectEpisodePage(page, in: detail)
                    }) {
                        HStack {
                            Text(page.title)
                            if page.id == selectedPage.id {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedPage.title)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                }
                .foregroundColor(.white)
            }
        }
    }

    @ViewBuilder
    private var seasonSelectorStyled: some View {
        if let tvShow = tvShow {
            let seasons = tvShow.seasons.filter { $0.seasonNumber > 0 }
            if shouldShowSeasonSwitcher(for: seasons) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(seasons) { season in
                            seasonCard(season, tvShow: tvShow)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }
            } else {
                EmptyView()
            }
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func seasonCard(_ season: TMDBSeason, tvShow: TMDBTVShowWithSeasons) -> some View {
        let isSelected = specialEpisodeContext == nil && selectedSeason?.id == season.id
        let accent = accentManager.currentAccentColor
        let cardWidth: CGFloat = isTvOS ? 190 : 96
        let posterHeight: CGFloat = isTvOS ? 285 : 144

        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                selectSeason(season, tvShowId: tvShow.id)
            }
        } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .bottom) {
                    KFImage(URL(string: season.fullPosterURL ?? tvShow.fullPosterURL ?? ""))
                        .placeholder {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [accent.opacity(0.35), Color.black.opacity(0.35)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: cardWidth, height: posterHeight)
                                .overlay(
                                    VStack(spacing: 4) {
                                        Image(systemName: "tv")
                                            .font(.title3)
                                        Text("S\(season.seasonNumber)")
                                            .font(.caption)
                                            .fontWeight(.bold)
                                    }
                                    .foregroundColor(.white.opacity(0.8))
                                )
                        }
                        .resizable()
                        .aspectRatio(2/3, contentMode: .fill)
                        .frame(width: cardWidth, height: posterHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    LinearGradient(
                        colors: [.clear, Color.black.opacity(0.55)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    .frame(width: cardWidth, height: posterHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .allowsHitTesting(false)

                    if season.episodeCount > 0 {
                        Text("\(season.episodeCount) EP")
                            .font(.system(size: isTvOS ? 20 : 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 7)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            isSelected ? accent : Color.white.opacity(0.08),
                            lineWidth: isSelected ? 2.5 : 1
                        )
                )
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundColor(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(accent))
                            .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1.5))
                            .padding(6)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .shadow(
                    color: isSelected ? accent.opacity(0.55) : Color.black.opacity(0.25),
                    radius: isSelected ? 12 : 5,
                    x: 0,
                    y: isSelected ? 6 : 3
                )
                .scaleEffect(isSelected ? 1.0 : 0.96)

                Text(season.name)
                    .font(isTvOS ? .system(size: 26) : .caption)
                    .fontWeight(isSelected ? .semibold : .medium)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                    .frame(width: cardWidth)
                    .foregroundColor(isSelected ? .white : .white.opacity(0.65))
            }
#if os(tvOS)
            .padding(.vertical, 16)
#endif
        }
#if os(tvOS)
        .buttonStyle(.card)
#else
        .buttonStyle(PlainButtonStyle())
#endif
    }

    @ViewBuilder
    private var episodeListSection: some View {
        Group {
            if let detail = activeSeasonDetail {
                let episodeItems = visibleEpisodeRenderItems(for: detail)
                if episodeItems.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        Text("No aired episodes yet")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .padding(.horizontal)
                } else if horizontalEpisodeList {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 15) {
                                ForEach(episodeItems) { item in
                                    createEpisodeCell(episode: item.episode, index: item.index, playbackContext: playbackContext(for: item.episode))
                                        .id(episodeAnchor(item.episode))
                                }
                            }
                        }
                        .onChangeComp(of: selectedEpisodeForSearch?.id) { _, _ in
                            revealSelectedEpisodePageIfNeeded()
                            guard let selectedEpisodeForSearch else { return }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                                withAnimation(.easeInOut(duration: 0.32)) {
                                    proxy.scrollTo(episodeAnchor(selectedEpisodeForSearch), anchor: .center)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                } else if isIPad {
                    LazyVGrid(
                        columns: [
                            GridItem(
                                .adaptive(minimum: 300, maximum: 420),
                                spacing: 22,
                                alignment: .top
                            )
                        ],
                        alignment: .leading,
                        spacing: 28
                    ) {
                        ForEach(episodeItems) { item in
                            createEpisodeCell(
                                episode: item.episode,
                                index: item.index,
                                playbackContext: playbackContext(for: item.episode)
                            )
                            .id(episodeAnchor(item.episode))
                        }
                    }
                    .padding(.horizontal, 24)
                } else {
                    LazyVStack(spacing: 15) {
                        ForEach(episodeItems) { item in
                            createEpisodeCell(episode: item.episode, index: item.index, playbackContext: playbackContext(for: item.episode))
                                .id(episodeAnchor(item.episode))
                        }
                    }
                    .padding(.horizontal)
                }
            } else if isLoadingSeason {
                VStack(spacing: 12) {
                    EclipseLoadingIndicator()
                        .scaleEffect(1.2)
                    Text("Loading episodes...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func createEpisodeCell(episode: TMDBEpisode, index: Int, playbackContext: EpisodePlaybackContext? = nil) -> some View {
        if let tvShow = tvShow {
            let progress = ProgressManager.shared.getEpisodeProgress(
                showId: tvShow.id,
                seasonNumber: episode.seasonNumber,
                episodeNumber: episode.episodeNumber
            )
            let isSelected = selectedEpisodeForSearch?.id == episode.id
            let showTitle = specialEpisodeContext?.title ?? tvShow.name
            let posterURL = specialEpisodeContext?.posterUrl ?? tvShow.fullPosterURL

            EpisodeCell(
                episode: episode,
                showId: tvShow.id,
                showTitle: showTitle,
                showPosterURL: posterURL,
                progress: progress,
                isSelected: isSelected,
                onTap: { episodeTapAction(episode: episode, playbackContext: playbackContext) },
                onMarkWatched: { markAsWatched(episode: episode, playbackContext: playbackContext) },
                onResetProgress: { resetProgress(episode: episode) },
                onDownload: episodeDownloadAction(for: episode, playbackContext: playbackContext),
                playbackContext: playbackContext,
                isAnimeContent: isAnime,
                isFiller: isFillerEpisode(episode)
            )
        } else {
            EmptyView()
        }
    }

    private func isFillerEpisode(_ episode: TMDBEpisode) -> Bool {
#if os(iOS)
        episodeClassificationsBySeason[episode.seasonNumber]?
            .shouldSkip(episodeNumber: episode.episodeNumber) == true
#else
        false
#endif
    }

#if os(iOS)
    private var animeFillerRequestKey: String {
        guard isAnime,
              specialEpisodeContext == nil,
              let seasonNumber = selectedSeason?.seasonNumber,
              let providerId = animeSeasonAniListIds[seasonNumber] else {
            return "none"
        }
        return "\(seasonNumber):\(providerId)"
    }

    @MainActor
    private func loadFillerMarkersForSelectedSeason() async {
        guard isAnime,
              specialEpisodeContext == nil,
              let seasonNumber = selectedSeason?.seasonNumber,
              episodeClassificationsBySeason[seasonNumber] == nil,
              let providerId = animeSeasonAniListIds[seasonNumber] else {
            return
        }

        let malId: Int?
        if providerId < 0 {
            malId = RemoteMediaNumericBoundary.positiveMagnitude(providerId)
        } else if let cached = TrackerManager.shared.cachedMyAnimeListAnimeId(fromAniListId: providerId) {
            malId = cached
        } else {
            malId = await TrackerManager.shared.resolveMyAnimeListAnimeId(fromAniListId: providerId)
        }

        guard !Task.isCancelled, let malId, malId > 0 else { return }

        do {
            let classifications = try await AnimeFillerService.shared.episodeClassifications(malId: malId)
            guard !Task.isCancelled,
                  selectedSeason?.seasonNumber == seasonNumber,
                  animeSeasonAniListIds[seasonNumber] == providerId else { return }
            episodeClassificationsBySeason[seasonNumber] = classifications
            Logger.shared.log(
                "AnimeFiller: loaded season=\(seasonNumber) malId=\(malId) fillerEpisodes=\(classifications.explicitFillerCount)",
                type: "AniList"
            )
        } catch is CancellationError {
            return
        } catch {
            Logger.shared.log(
                "AnimeFiller: failed season=\(seasonNumber) malId=\(malId) error=\(error.localizedDescription)",
                type: "Error"
            )
        }
    }
#endif

    private func episodeDownloadAction(
        for episode: TMDBEpisode,
        playbackContext: EpisodePlaybackContext?
    ) -> (() -> Void)? {
#if os(tvOS)
        nil
#else
        return {
            if hasActiveSources {
                downloadEpisode = episode
                selectedEpisodeForSearch = episode
                selectedEpisodePlaybackContext = playbackContext
                downloadEpisodePlaybackContext = playbackContext
                showingDownloadSheet = true
            } else {
                showingNoServicesAlert = true
            }
        }
#endif
    }

    private func episodeTapAction(episode: TMDBEpisode, playbackContext: EpisodePlaybackContext? = nil) {
        selectedEpisodeForSearch = episode
        selectedEpisodePlaybackContext = playbackContext
#if !os(tvOS)
        if preferDownloadedMedia,
           let item = downloadedItem(for: episode) {
            playDownloadedItem(
                item,
                canonicalPlaybackContext: playbackContext ?? self.playbackContext(for: episode)
            )
            return
        }
#endif
        searchInServicesForEpisode(episode: episode, playbackContext: playbackContext)
    }

#if !os(tvOS)
    private func downloadedItem(for episode: TMDBEpisode) -> DownloadItem? {
        guard let tvShow else { return nil }
        return downloadManager.completedEpisodeDownloadItem(
            tmdbId: tvShow.id,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber,
            playbackContext: playbackContext(for: episode)
        )
    }

    private func playDownloadedItem(
        _ item: DownloadItem,
        from presenter: UIViewController? = nil,
        canonicalPlaybackContext: EpisodePlaybackContext? = nil
    ) {
        guard let fileURL = downloadManager.localFileURL(for: item) else {
            Logger.shared.log("Downloaded file not found for: \(item.id)", type: "Download")
            return
        }
        guard let originatingPresenter = presenter ?? downloadedPlaybackPresenter() else {
            Logger.shared.log("Downloaded playback has no presenter in its originating scene", type: "Player")
            return
        }

        let subtitles = downloadManager.localSubtitleURL(for: item).map { [$0.absoluteString] } ?? []
        let effectiveContext = canonicalPlaybackContext ?? item.episodePlaybackContext
        let effectiveMediaInfo: MediaInfo = {
            guard !item.isMovie, let effectiveContext else { return item.mediaInfo }
            return .episode(
                showId: item.tmdbId,
                seasonNumber: effectiveContext.localSeasonNumber,
                episodeNumber: effectiveContext.localEpisodeNumber,
                showTitle: item.playerTitleBase,
                showPosterURL: item.posterURL,
                isAnime: item.isAnime || effectiveContext.hasAnimeMediaId
            )
        }()
        let nextEpisodeRequest: (_ seasonNumber: Int, _ episodeNumber: Int) -> Void = { [weak originatingPresenter] seasonNumber, episodeNumber in
            guard let originatingPresenter else { return }
            let nextContext = downloadedPlaybackContext(
                currentContext: effectiveContext,
                isAnimeRequest: isAnime || item.isAnime || effectiveContext?.hasAnimeMediaId == true,
                requestedSeasonNumber: seasonNumber,
                requestedEpisodeNumber: episodeNumber
            )
            guard let nextItem = nextDownloadedEpisode(
                for: item.tmdbId,
                requestedSeasonNumber: seasonNumber,
                requestedEpisodeNumber: episodeNumber,
                currentItemId: item.id,
                currentPlaybackContext: effectiveContext,
                allowNextAvailableFallback: false
            ) else {
                Logger.shared.log("NextEpisode: No downloaded next episode found for tmdbId=\(item.tmdbId) after \(item.id)", type: "Player")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.playDownloadedItem(
                    nextItem,
                    from: originatingPresenter,
                    canonicalPlaybackContext: nextContext
                )
            }
        }
        let nextSeasonNumber = effectiveContext?.localSeasonNumber ?? item.seasonNumber ?? 0
        let nextEpisodeNumber = RemoteMediaNumericBoundary.adding(
            effectiveContext?.localEpisodeNumber ?? item.episodeNumber ?? 0,
            1
        ) ?? 0
        let localNextEpisode = nextDownloadedEpisode(
            for: item.tmdbId,
            requestedSeasonNumber: nextSeasonNumber,
            requestedEpisodeNumber: nextEpisodeNumber,
            currentItemId: item.id,
            currentPlaybackContext: effectiveContext
        )
        let request = PlaybackRequest(
            url: fileURL,
            subtitles: subtitles,
            mediaInfo: effectiveMediaInfo,
            mediaYear: sourceMatchingYear,
            episodePlaybackContext: effectiveContext,
            title: item.playerTitleBase,
            subtitle: item.displayTitle,
            artworkURL: item.posterURL.flatMap(URL.init(string:)),
            isAnime: item.isAnime || effectiveContext?.hasAnimeMediaId == true,
            isAnimation: tvShow?.genres.contains { $0.id == 16 } ?? false,
            originalTMDBSeasonNumber: effectiveContext?.resolvedTMDBSeasonNumber,
            originalTMDBEpisodeNumber: effectiveContext?.resolvedTMDBEpisodeNumber,
            onRequestNextEpisode: nextEpisodeRequest,
            localNextEpisodeFallback: PlaybackEpisodeCoordinate(
                seasonNumber: localNextEpisode?.seasonNumber,
                episodeNumber: localNextEpisode?.episodeNumber
            )
        )
        PlaybackCoordinator.shared.present(request, from: originatingPresenter)
    }

    @MainActor
    private func downloadedPlaybackPresenter() -> UIViewController? {
        let activeScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        let scene: UIWindowScene?
        if let presentationSceneIdentifier {
            scene = activeScenes.first(where: {
                $0.session.persistentIdentifier == presentationSceneIdentifier
            })
        } else {
            scene = activeScenes.count == 1 ? activeScenes.first : nil
        }
        let window = scene?.windows.first(where: { $0.isKeyWindow && $0.rootViewController != nil })
            ?? scene?.windows.first(where: {
                !$0.isHidden && $0.alpha > 0 && $0.windowLevel == .normal && $0.rootViewController != nil
            })
        return window?.rootViewController?.topmostViewController()
    }
#endif

    private func episodePages(for detail: TMDBSeasonDetail) -> [EpisodePage] {
        let episodes = visibleEpisodes(for: detail)
        return stride(from: 0, to: episodes.count, by: episodePageSize).map { startIndex in
            EpisodePage(
                startIndex: startIndex,
                endIndex: min(startIndex + episodePageSize, episodes.count)
            )
        }
    }

    private func episodePageKey(for detail: TMDBSeasonDetail) -> String {
        if let specialEpisodeContext {
            return "special-\(specialEpisodeContext.id)"
        }
        return "season-\(detail.id)-\(detail.seasonNumber)"
    }

    private func selectedEpisodePage(for detail: TMDBSeasonDetail) -> EpisodePage? {
        let pages = episodePages(for: detail)
        let selectedStart = selectedEpisodePageStartByKey[episodePageKey(for: detail)] ?? 0
        return pages.first(where: { $0.startIndex == selectedStart }) ?? pages.first
    }

    private func selectEpisodePage(_ page: EpisodePage, in detail: TMDBSeasonDetail) {
        let detailKey = episodePageKey(for: detail)
        let hydrationKey = "\(detailKey)-\(page.startIndex)"
        guard isAnime,
              specialEpisodeContext == nil,
              !hydratedAnimeEpisodePageKeys.contains(hydrationKey),
              let tvShow,
              let selectedSeason,
              page.startIndex < page.endIndex else {
            selectedEpisodePageStartByKey[detailKey] = page.startIndex
            return
        }

        let displayedEpisodes = visibleEpisodes(for: detail)
        guard page.endIndex <= displayedEpisodes.count else {
            selectedEpisodePageStartByKey[detailKey] = page.startIndex
            return
        }
        let pageEpisodeNumbers = Set(displayedEpisodes[page.startIndex..<page.endIndex].map(\.episodeNumber))
        let sourceEpisodes = animeEpisodeContextIndex
            .episodes(seasonNumber: selectedSeason.seasonNumber)
            .filter { pageEpisodeNumbers.contains($0.number) }
        guard !sourceEpisodes.isEmpty else {
            selectedEpisodePageStartByKey[detailKey] = page.startIndex
            return
        }

        seasonLoadTask?.cancel()
        seasonLoadGeneration += 1
        let generation = seasonLoadGeneration
        isLoadingSeason = true
        seasonLoadTask = Task {
            do {
                let hydrated = try await AniListService.shared.hydrateAnimeSeasonDetail(
                    tmdbShowId: tvShow.id,
                    season: selectedSeason,
                    episodes: sourceEpisodes,
                    tmdbService: tmdbService
                )
                let replacements = Dictionary(
                    hydrated.episodes.map { ($0.episodeNumber, $0) },
                    uniquingKeysWith: { existing, _ in existing }
                )
                let merged = TMDBSeasonDetail(
                    id: detail.id,
                    name: detail.name,
                    overview: detail.overview,
                    posterPath: detail.posterPath,
                    seasonNumber: detail.seasonNumber,
                    airDate: detail.airDate,
                    episodes: detail.episodes.map { replacements[$0.episodeNumber] ?? $0 }
                )
                await MainActor.run {
                    guard !Task.isCancelled,
                          generation == self.seasonLoadGeneration,
                          self.selectedSeason?.id == selectedSeason.id else { return }
                    self.seasonDetail = merged
                    self.hydratedAnimeEpisodePageKeys.insert(hydrationKey)
                    self.selectedEpisodePageStartByKey[detailKey] = page.startIndex
                    self.isLoadingSeason = false
                    self.seasonLoadTask = nil
                }
            } catch {
                await MainActor.run {
                    guard generation == self.seasonLoadGeneration else { return }
                    self.selectedEpisodePageStartByKey[detailKey] = page.startIndex
                    self.isLoadingSeason = false
                    self.seasonLoadTask = nil
                }
            }
        }
    }

    private func visibleEpisodeRenderItems(for detail: TMDBSeasonDetail) -> [EpisodeRenderItem] {
        let items = episodeRenderItems(for: detail)
        guard let page = selectedEpisodePage(for: detail), page.startIndex < page.endIndex else {
            return items
        }
        return Array(items[page.startIndex..<page.endIndex])
    }

    private func revealSelectedEpisodePageIfNeeded() {
        guard let detail = activeSeasonDetail,
              let selectedEpisodeForSearch,
              let index = visibleEpisodes(for: detail).firstIndex(where: {
                  $0.seasonNumber == selectedEpisodeForSearch.seasonNumber
                      && $0.episodeNumber == selectedEpisodeForSearch.episodeNumber
              }) else { return }
        let pageStart = (index / episodePageSize) * episodePageSize
        let key = episodePageKey(for: detail)
        if selectedEpisodePageStartByKey[key] != pageStart {
            selectedEpisodePageStartByKey[key] = pageStart
        }
    }

    private func episodeAnchor(_ episode: TMDBEpisode) -> String {
        MediaDetailEpisodeAnchor.id(for: episode)
    }

#if !os(tvOS)
    private func nextDownloadedEpisode(
        for tmdbId: Int,
        requestedSeasonNumber: Int,
        requestedEpisodeNumber: Int,
        currentItemId: String,
        currentPlaybackContext: EpisodePlaybackContext? = nil,
        allowNextAvailableFallback: Bool = true
    ) -> DownloadItem? {
        let currentItem = downloadManager.completedDownloads.first { $0.id == currentItemId }
        let currentContext = currentPlaybackContext ?? currentItem?.episodePlaybackContext
        let isAnimeRequest = isAnime
            || currentItem?.isAnime == true
            || currentContext?.hasAnimeMediaId == true
        let requestedContext = downloadedPlaybackContext(
            currentContext: currentContext,
            isAnimeRequest: isAnimeRequest,
            requestedSeasonNumber: requestedSeasonNumber,
            requestedEpisodeNumber: requestedEpisodeNumber
        )

        if !isAnimeRequest || requestedContext != nil,
           let requested = downloadManager.completedEpisodeDownloadItem(
               tmdbId: tmdbId,
               seasonNumber: requestedSeasonNumber,
               episodeNumber: requestedEpisodeNumber,
               playbackContext: requestedContext
           ),
           requested.id != currentItemId {
            return requested
        }

        guard !isAnimeRequest else { return nil }
        let episodes = downloadManager.completedDownloads
            .filter {
                !$0.isMovie &&
                $0.tmdbId == tmdbId &&
                $0.seasonNumber != nil &&
                $0.episodeNumber != nil &&
                downloadManager.localFileURL(for: $0) != nil
            }
            .sorted {
                if $0.seasonNumber == $1.seasonNumber {
                    return ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0)
                }
                return ($0.seasonNumber ?? 0) < ($1.seasonNumber ?? 0)
            }

        guard allowNextAvailableFallback else { return nil }

        guard let currentIndex = episodes.firstIndex(where: { $0.id == currentItemId }) else { return nil }
        let nextIndex = episodes.index(after: currentIndex)
        guard nextIndex < episodes.endIndex else { return nil }
        return episodes[nextIndex]
    }

    private func downloadedPlaybackContext(
        currentContext: EpisodePlaybackContext?,
        isAnimeRequest: Bool,
        requestedSeasonNumber: Int,
        requestedEpisodeNumber: Int
    ) -> EpisodePlaybackContext? {
        if let currentContext,
           currentContext.localSeasonNumber == requestedSeasonNumber {
            return currentContext.forEpisodeNumber(requestedEpisodeNumber)
        }
        guard isAnimeRequest,
              currentContext?.isSpecial != true else { return nil }
        let placeholder = TMDBEpisode(
            id: RemoteMediaNumericBoundary.syntheticIdentifier([
                (tvShow?.id ?? 0, 1_000_000),
                (requestedSeasonNumber, 10_000),
                (requestedEpisodeNumber, 1)
            ]),
            name: "Episode \(requestedEpisodeNumber)",
            overview: nil,
            stillPath: nil,
            episodeNumber: requestedEpisodeNumber,
            seasonNumber: requestedSeasonNumber,
            airDate: nil,
            runtime: nil,
            voteAverage: 0,
            voteCount: 0
        )
        return playbackContext(for: placeholder)
    }
#endif

    private var originalTMDBNumbers: (season: Int, episode: Int)? {
        guard isAnime,
              let ep = selectedEpisodeForSearch,
              let match = animeEpisodeContextIndex.episode(
                seasonNumber: ep.seasonNumber,
                episodeNumber: ep.episodeNumber
              ),
              let s = match.tmdbSeasonNumber,
              let e = match.tmdbEpisodeNumber
        else { return nil }
        return (s, e)
    }

    private func searchInServicesForEpisode(episode: TMDBEpisode, playbackContext: EpisodePlaybackContext? = nil) {
        guard (tvShow?.name) != nil else {
            return
        }

        if !hasActiveSources {
            showingNoServicesAlert = true
            return
        }

        selectedEpisodePlaybackContext = playbackContext
        let targetToken = AutoModeMediaTargetToken.make(
            tmdbID: tvShow?.id ?? 0,
            isMovie: false,
            episode: episode,
            playbackContext: playbackContext
        )
        autoModeRetrySession.reset(targetToken: targetToken)
        showingSearchResults = true
    }

    @MainActor
    private func handleAutoModePlaybackFailure(
        _ report: PlaybackFailureReport,
        identity: AutoModePlaybackRecoveryIdentity,
        episode: TMDBEpisode?,
        playbackContext: EpisodePlaybackContext?
    ) {
        guard report.context.autoMode,
              autoModeRetrySession.matches(identity),
              selectedEpisodeForSearch?.seasonNumber == episode?.seasonNumber,
              selectedEpisodeForSearch?.episodeNumber == episode?.episodeNumber else {
            return
        }
        autoModeRetrySession.recordPlaybackFailure(report)
        selectedEpisodePlaybackContext = playbackContext
        showingSearchResults = true
        Logger.shared.log(
            "TVShowSeasonsSection: Auto Mode playback failed source=\(report.context.sourceName) retry=\(autoModeRetrySession.retryCount); reopening remaining sources",
            type: "Player"
        )
    }

    private func markAsWatched(episode: TMDBEpisode, playbackContext: EpisodePlaybackContext? = nil) {
        guard let tvShow = tvShow else {
            return
        }
        ProgressManager.shared.markEpisodeAsWatched(
            showId: tvShow.id,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber,
            playbackContext: playbackContext,
            isAnime: isAnime
        )
    }

    private func resetProgress(episode: TMDBEpisode) {
        guard let tvShow = tvShow else {
            return
        }
        ProgressManager.shared.resetEpisodeProgress(
            showId: tvShow.id,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber
        )
    }

    private func selectSeason(_ season: TMDBSeason, tvShowId: Int) {
        let wasShowingSpecial = specialEpisodeContext != nil
        specialEpisodeContext = nil
        selectedEpisodePlaybackContext = nil
#if !os(tvOS)
        downloadEpisodePlaybackContext = nil
        downloadAllSpecialContext = nil
#endif
        selectedSeason = season
        if wasShowingSpecial {
            selectedEpisodeForSearch = seasonDetail.flatMap { visibleEpisodes(for: $0).first }
        }
        currentSeasonTitle = isAnime ? (animeSeasonTitles?[season.seasonNumber] ?? season.name) : nil
        loadSeasonDetails(tvShowId: tvShowId, season: season)
    }

    private func loadSeasonDetails(tvShowId: Int, season: TMDBSeason) {
        guard seasonDetail?.seasonNumber != season.seasonNumber || seasonDetail?.id != season.id else {
            currentSeasonTitle = isAnime ? (animeSeasonTitles?[season.seasonNumber] ?? season.name) : nil
            isLoadingSeason = false
            if specialEpisodeContext == nil, let detail = seasonDetail {
                selectedEpisodeForSearch = preferredEpisodeAfterSeasonLoad(detail)
            }
            return
        }
        seasonLoadTask?.cancel()
        seasonLoadGeneration += 1
        let generation = seasonLoadGeneration
        currentSeasonTitle = isAnime ? (animeSeasonTitles?[season.seasonNumber] ?? season.name) : nil
        isLoadingSeason = true
        seasonDetail = nil
        selectedEpisodeForSearch = nil
        selectedEpisodePlaybackContext = nil
#if !os(tvOS)
        downloadEpisodePlaybackContext = nil
#endif

        seasonLoadTask = Task {
            do {

                if isAnime, animeEpisodes != nil {
                    let seasonEpisodes = animeEpisodeContextIndex.episodes(seasonNumber: season.seasonNumber)
                    let detail = try await AniListService.shared.hydrateAnimeSeasonDetail(
                        tmdbShowId: tvShowId,
                        season: season,
                        episodes: seasonEpisodes,
                        tmdbService: tmdbService
                    )

                    await MainActor.run {
                        guard !Task.isCancelled,
                              generation == self.seasonLoadGeneration,
                              self.selectedSeason?.id == season.id else { return }
                        self.seasonDetail = detail
                        self.isLoadingSeason = false
                        self.seasonLoadTask = nil
                        if self.specialEpisodeContext == nil {
                            self.selectedEpisodeForSearch = self.preferredEpisodeAfterSeasonLoad(detail)
                        }
                    }
                } else {

                    let detail = try await tmdbService.getSeasonDetails(tvShowId: tvShowId, seasonNumber: season.seasonNumber)
                    await MainActor.run {
                        guard !Task.isCancelled,
                              generation == self.seasonLoadGeneration,
                              self.selectedSeason?.id == season.id else { return }
                        self.seasonDetail = detail
                        self.isLoadingSeason = false
                        self.seasonLoadTask = nil
                        if self.specialEpisodeContext == nil {
                            self.selectedEpisodeForSearch = self.preferredEpisodeAfterSeasonLoad(detail)
                        }
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard generation == self.seasonLoadGeneration else { return }
                    self.seasonLoadTask = nil
                    self.isLoadingSeason = false
                }
            } catch {
                await MainActor.run {
                    guard generation == self.seasonLoadGeneration else { return }
                    self.seasonLoadTask = nil
                    self.isLoadingSeason = false
                }
            }
        }
    }

    private func preferredEpisodeAfterSeasonLoad(_ detail: TMDBSeasonDetail) -> TMDBEpisode? {
        if let selectedEpisodeForSearch,
           selectedEpisodeForSearch.seasonNumber == detail.seasonNumber,
           let matching = visibleEpisodes(for: detail).first(where: {
               $0.episodeNumber == selectedEpisodeForSearch.episodeNumber
           }) {
            return matching
        }
        return visibleEpisodes(for: detail).first
    }

    private func ensureSeasonDetailsLoaded(tvShowId: Int, season: TMDBSeason, reason: String) {
        if seasonDetail?.seasonNumber == season.seasonNumber,
           seasonDetail?.id == season.id {
            currentSeasonTitle = isAnime ? (animeSeasonTitles?[season.seasonNumber] ?? season.name) : nil
            isLoadingSeason = false
            return
        }

        loadSeasonDetails(tvShowId: tvShowId, season: season)
    }

#if !os(tvOS)
    private func startDownloadAllSeason() {
        let detail = activeSeasonDetail
        guard let detail else {
            return
        }
        let episodes = visibleEpisodes(for: detail)
        guard !episodes.isEmpty else { return }
        let episodesToDownload = episodes.filter { !shouldSkipDownloadAllEpisode($0) }
        guard let first = episodesToDownload.first else {
            isDownloadingAll = false
            downloadAllQueue.removeAll()
            downloadAllSpecialContext = nil
            downloadEpisodePlaybackContext = nil
            Logger.shared.log("Download All skipped: every episode is already downloaded or queued for \(activeSeasonTitle ?? "season")", type: "Download")
            return
        }

        isDownloadingAll = true
        downloadAllQueue = Array(episodesToDownload.dropFirst())
        downloadAllSpecialContext = specialEpisodeContext
        downloadEpisode = first
        selectedEpisodeForSearch = first
        let context = playbackContext(for: first)
        selectedEpisodePlaybackContext = context
        downloadEpisodePlaybackContext = context
        showingDownloadSheet = true
    }

    private func showNextDownloadSheet() {
        while !downloadAllQueue.isEmpty {
            let next = downloadAllQueue.removeFirst()
            guard !shouldSkipDownloadAllEpisode(next) else {
                continue
            }

            downloadEpisode = next
            selectedEpisodeForSearch = next
            let context = downloadAllSpecialContext?.playbackContext(for: next) ?? playbackContext(for: next)
            selectedEpisodePlaybackContext = context
            downloadEpisodePlaybackContext = context
            showingDownloadSheet = true
            return
        }

        isDownloadingAll = false
        downloadAllSpecialContext = nil
        downloadEpisodePlaybackContext = nil
    }

    private func shouldSkipDownloadAllEpisode(_ episode: TMDBEpisode) -> Bool {
        guard let tvShow else { return false }
        let context = downloadAllSpecialContext?.playbackContext(for: episode)
            ?? playbackContext(for: episode)
        if downloadManager.completedEpisodeDownloadItem(
            tmdbId: tvShow.id,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber,
            playbackContext: context
        ) != nil {
            return true
        }

        guard let item = downloadManager.activeEpisodeDownloadItem(
            tmdbId: tvShow.id,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber,
            playbackContext: context
        ) else {
            return false
        }
        return item.status == .queued || item.status == .downloading || item.status == .paused
    }
#endif
}
