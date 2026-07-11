import SwiftUI
import Kingfisher
import AVKit

struct TVShowDetailsSection: View {
    let tvShow: TMDBTVShowWithSeasons?
    let ratingOverride: String?
    var compactHeroMetadata: Bool

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

                    if let ageRating = getAgeRating(from: tvShow.contentRatings) {
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
        guard let contentRatings else { return nil }

        for rating in contentRatings.results where rating.iso31661 == "US" && !rating.rating.isEmpty {
            return rating.rating
        }

        for rating in contentRatings.results where !rating.rating.isEmpty {
            return rating.rating
        }

        return nil
    }
}

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
            // Preserve the first occurrence if malformed provider data repeats
            // a number; that matches the previous `first(where:)` behavior.
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
    var showsMetadataDetails: Bool = true
    var showsInsertedContent: Bool = true
    let tmdbService: TMDBService
    @ViewBuilder let insertedContent: () -> InsertedContent
    
    @State private var isLoadingSeason = false
    @State private var showingSearchResults = false
    @State private var selectedEpisodePlaybackContext: EpisodePlaybackContext?
#if !os(tvOS)
    @State private var showingDownloadSheet = false
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
#if os(iOS)
    @State private var fillerEpisodeNumbersBySeason: [Int: Set<Int>] = [:]
#endif
    
    @StateObject private var serviceManager = ServiceManager.shared
    @StateObject private var stremioManager = StremioAddonManager.shared
    @StateObject private var accentManager = AccentColorManager.shared
#if !os(tvOS)
    private let downloadManager = DownloadManager.shared
#endif
    @AppStorage("horizontalEpisodeList") private var horizontalEpisodeList: Bool = false
#if !os(tvOS)
    @AppStorage("preferDownloadedMedia") private var preferDownloadedMedia: Bool = false
#endif
    private var isGroupedBySeasons: Bool {
        return tvShow?.seasons.filter { $0.seasonNumber > 0 }.count ?? 0 > 1
    }
    
    private var useSeasonMenu: Bool {
        return UserDefaults.standard.bool(forKey: "seasonMenu")
    }

    private func shouldShowSeasonSwitcher(for seasons: [TMDBSeason]) -> Bool {
        seasons.count > 1 || (isAnime && !seasons.isEmpty && (hasSpecialEpisodeChoices || specialEpisodeContext != nil))
    }

    private var hasActiveSources: Bool {
        !serviceManager.activeServices.isEmpty ||
        !stremioManager.activeAddons.isEmpty
    }

    private var activeSeasonDetail: TMDBSeasonDetail? {
        specialEpisodeContext?.seasonDetail ?? seasonDetail
    }

    private var activeSeasonTitle: String? {
        specialEpisodeContext?.title ?? currentSeasonTitle
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

    private func episodeRenderItems(for detail: TMDBSeasonDetail) -> [EpisodeRenderItem] {
        detail.episodes.enumerated().map { index, episode in
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

        // Performance Mode keeps Home catalogs on their fast path but, per its
        // Settings description, detail pages retain full anime metadata. Only
        // the explicit traversal-skip toggle should discard provider identity.
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
        .onAppear {
            if let tvShow = tvShow, let selectedSeason = selectedSeason {
                ensureSeasonDetailsLoaded(tvShowId: tvShow.id, season: selectedSeason, reason: "appear")
                Task {
                    let romaji = await tmdbService.getRomajiTitle(for: "tv", id: tvShow.id)
                    await MainActor.run {
                        self.romajiTitle = romaji
                    }
                }
            }
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
            ModulesSearchResultsSheet(
                mediaTitle: getSearchTitle(),
                seasonTitleOverride: activeSeasonTitle,
                originalTitle: getOriginalTitle(for: selectedEpisodeForSearch),
                isMovie: false,
                isAnimeContent: isAnime,
                selectedEpisode: selectedEpisodeForSearch,
                tmdbId: tvShow?.id ?? 0,
                animeSeasonTitle: isAnime ? activeSeasonTitle : nil,
                posterPath: specialEpisodeContext?.posterUrl ?? tvShow?.posterPath,
                imdbId: tvShow?.externalIds?.imdbId,
                originalTMDBSeasonNumber: selectedEpisodePlaybackContext?.resolvedTMDBSeasonNumber ?? originalTMDBNumbers?.season,
                originalTMDBEpisodeNumber: selectedEpisodePlaybackContext?.resolvedTMDBEpisodeNumber ?? originalTMDBNumbers?.episode,
                specialTitleOnlySearch: selectedEpisodePlaybackContext?.titleOnlySearch ?? false,
                episodePlaybackContext: selectedEpisodePlaybackContext,
                autoModeOnly: UserDefaults.standard.bool(forKey: "servicesAutoModeEnabled"),
                isAnimationGenre16: tvShow?.genres.contains { $0.id == 16 } ?? false
            )
        }
#if !os(tvOS)
        .sheet(isPresented: $showingDownloadSheet, onDismiss: {
            if isDownloadingAll {
                if downloadWasEnqueued || downloadWasSkipped {
                    // Download enqueued or skipped - advance to next episode
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
                    // "Done" was tapped without download/skip - cancel entire queue
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
                animeSeasonTitle: isAnime ? activeSeasonTitle : nil,
                posterPath: downloadAllSpecialContext?.posterUrl ?? specialEpisodeContext?.posterUrl ?? tvShow?.posterPath,
                imdbId: tvShow?.externalIds?.imdbId,
                originalTMDBSeasonNumber: downloadEpisodePlaybackContext?.resolvedTMDBSeasonNumber ?? selectedEpisodePlaybackContext?.resolvedTMDBSeasonNumber ?? originalTMDBNumbers?.season,
                originalTMDBEpisodeNumber: downloadEpisodePlaybackContext?.resolvedTMDBEpisodeNumber ?? selectedEpisodePlaybackContext?.resolvedTMDBEpisodeNumber ?? originalTMDBNumbers?.episode,
                specialTitleOnlySearch: (downloadEpisodePlaybackContext ?? selectedEpisodePlaybackContext)?.titleOnlySearch ?? false,
                episodePlaybackContext: downloadEpisodePlaybackContext ?? selectedEpisodePlaybackContext,
                downloadMode: true,
                autoModeOnly: UserDefaults.standard.bool(forKey: "servicesAutoModeEnabled"),
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
        .alert("No Active Services", isPresented: $showingNoServicesAlert) {
            Button("OK") { }
        } message: {
            Text("You don't have any active services. Please go to the Services tab to download and activate services.")
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
                        selectedEpisodePageStartByKey[episodePageKey(for: detail)] = page.startIndex
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
        let cardWidth: CGFloat = 96
        let posterHeight: CGFloat = 144

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

                    // Bottom scrim for legibility of the episode-count pill
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
                            .font(.system(size: 10, weight: .bold))
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
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .medium)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                    .frame(width: cardWidth)
                    .foregroundColor(isSelected ? .white : .white.opacity(0.65))
            }
        }
        .buttonStyle(PlainButtonStyle())
    }

    @ViewBuilder
    private var episodeListSection: some View {
        Group {
            if let detail = activeSeasonDetail {
                let episodeItems = visibleEpisodeRenderItems(for: detail)
                if horizontalEpisodeList {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 15) {
                            ForEach(episodeItems) { item in
                                createEpisodeCell(episode: item.episode, index: item.index, playbackContext: playbackContext(for: item.episode))
                            }
                        }
                    }
                    .padding(.horizontal)
                } else {
                    LazyVStack(spacing: 15) {
                        ForEach(episodeItems) { item in
                            createEpisodeCell(episode: item.episode, index: item.index, playbackContext: playbackContext(for: item.episode))
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
        fillerEpisodeNumbersBySeason[episode.seasonNumber]?.contains(episode.episodeNumber) == true
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
              fillerEpisodeNumbersBySeason[seasonNumber] == nil,
              let providerId = animeSeasonAniListIds[seasonNumber] else {
            return
        }

        let malId: Int?
        if providerId < 0 {
            // MAL fallback entries use a negative provider-safe ID whose magnitude is MAL's ID.
            malId = abs(providerId)
        } else if let cached = TrackerManager.shared.cachedMyAnimeListAnimeId(fromAniListId: providerId) {
            malId = cached
        } else {
            malId = await TrackerManager.shared.resolveMyAnimeListAnimeId(fromAniListId: providerId)
        }

        guard !Task.isCancelled, let malId, malId > 0 else { return }

        do {
            let episodeNumbers = try await AnimeFillerService.shared.fillerEpisodeNumbers(malId: malId)
            guard !Task.isCancelled,
                  selectedSeason?.seasonNumber == seasonNumber,
                  animeSeasonAniListIds[seasonNumber] == providerId else { return }
            fillerEpisodeNumbersBySeason[seasonNumber] = episodeNumbers
            Logger.shared.log(
                "AnimeFiller: loaded season=\(seasonNumber) malId=\(malId) fillerEpisodes=\(episodeNumbers.count)",
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
            playDownloadedItem(item)
            return
        }
#endif
        searchInServicesForEpisode(episode: episode, playbackContext: playbackContext)
    }

#if !os(tvOS)
    private func downloadedItem(for episode: TMDBEpisode) -> DownloadItem? {
        guard let tvShow else { return nil }
        return downloadManager.completedDownloadItem(
            tmdbId: tvShow.id,
            isMovie: false,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber
        )
    }

    private func playDownloadedItem(_ item: DownloadItem) {
        guard let fileURL = downloadManager.localFileURL(for: item) else {
            Logger.shared.log("Downloaded file not found for: \(item.id)", type: "Download")
            return
        }

        let inAppRaw = Settings.normalizedInAppPlayer(UserDefaults.standard.string(forKey: "inAppPlayer"))
        let subtitleArray: [String]? = downloadManager.localSubtitleURL(for: item).map { [$0.absoluteString] }

        if inAppRaw == "mpv" {
            let preset = PlayerPreset.presets.first
            let pvc = PlayerViewController(
                url: fileURL,
                preset: preset ?? PlayerPreset(id: .sdrRec709, title: "Default", summary: "", stream: nil, commands: []),
                headers: [:],
                subtitles: subtitleArray,
                mediaInfo: item.mediaInfo
            )
            pvc.isAnimeHint = item.isAnime || item.episodePlaybackContext?.hasAnimeMediaId == true
            pvc.isAnimationContentHint = tvShow?.genres.contains { $0.id == 16 }
            pvc.episodePlaybackContext = item.episodePlaybackContext
            pvc.originalTMDBSeasonNumber = item.episodePlaybackContext?.resolvedTMDBSeasonNumber
            pvc.originalTMDBEpisodeNumber = item.episodePlaybackContext?.resolvedTMDBEpisodeNumber
            pvc.modalPresentationStyle = .fullScreen

            pvc.onRequestNextEpisode = { seasonNumber, episodeNumber in
                guard let nextItem = nextDownloadedEpisode(
                    for: item.tmdbId,
                    requestedSeasonNumber: seasonNumber,
                    requestedEpisodeNumber: episodeNumber,
                    currentItemId: item.id
                ) else {
                    Logger.shared.log("NextEpisode: No downloaded next episode found for tmdbId=\(item.tmdbId) after \(item.id)", type: "Player")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    playDownloadedItem(nextItem)
                }
            }

            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController,
               let topmostVC = rootVC.topmostViewController() as UIViewController? {
                topmostVC.present(pvc, animated: true, completion: nil)
            }
        } else {
            let playerVC = NormalPlayer()
            let item2 = AVPlayerItem(url: fileURL)
            playerVC.player = AVPlayer(playerItem: item2)
            playerVC.mediaInfo = item.mediaInfo
            playerVC.episodePlaybackContext = item.episodePlaybackContext
            playerVC.modalPresentationStyle = .fullScreen

            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController,
               let topmostVC = rootVC.topmostViewController() as UIViewController? {
                topmostVC.present(playerVC, animated: true) {
                    playerVC.playAtDefaultSpeed()
                }
            }
        }
    }
#endif

    private func episodePages(for detail: TMDBSeasonDetail) -> [EpisodePage] {
        stride(from: 0, to: detail.episodes.count, by: episodePageSize).map { startIndex in
            EpisodePage(
                startIndex: startIndex,
                endIndex: min(startIndex + episodePageSize, detail.episodes.count)
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

    private func visibleEpisodeRenderItems(for detail: TMDBSeasonDetail) -> [EpisodeRenderItem] {
        let items = episodeRenderItems(for: detail)
        guard let page = selectedEpisodePage(for: detail), page.startIndex < page.endIndex else {
            return items
        }
        return Array(items[page.startIndex..<page.endIndex])
    }

#if !os(tvOS)
    private func nextDownloadedEpisode(
        for tmdbId: Int,
        requestedSeasonNumber: Int,
        requestedEpisodeNumber: Int,
        currentItemId: String
    ) -> DownloadItem? {
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

        if let requested = episodes.first(where: {
            $0.seasonNumber == requestedSeasonNumber && $0.episodeNumber == requestedEpisodeNumber
        }) {
            return requested
        }

        guard let currentIndex = episodes.firstIndex(where: { $0.id == currentItemId }) else { return nil }
        let nextIndex = episodes.index(after: currentIndex)
        guard nextIndex < episodes.endIndex else { return nil }
        return episodes[nextIndex]
    }
#endif
    
    /// Look up the original TMDB season/episode numbers for the currently selected episode.
    /// Returns nil for non-anime or when no AniList episode match is found.
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
        showingSearchResults = true
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
            selectedEpisodeForSearch = seasonDetail?.episodes.first
        }
        currentSeasonTitle = isAnime ? (animeSeasonTitles?[season.seasonNumber] ?? season.name) : nil
        loadSeasonDetails(tvShowId: tvShowId, season: season)
    }

    private func loadSeasonDetails(tvShowId: Int, season: TMDBSeason) {
        guard seasonDetail?.seasonNumber != season.seasonNumber || seasonDetail?.id != season.id else {
            currentSeasonTitle = isAnime ? (animeSeasonTitles?[season.seasonNumber] ?? season.name) : nil
            isLoadingSeason = false
            if specialEpisodeContext == nil, let firstEpisode = seasonDetail?.episodes.first {
                selectedEpisodeForSearch = firstEpisode
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
                // For anime, build season detail from cached AniList episodes with TMDB metadata
                if isAnime, animeEpisodes != nil {
                    let seasonEpisodes = animeEpisodeContextIndex.episodes(seasonNumber: season.seasonNumber)
                    
                    let tmdbEpisodes: [TMDBEpisode] = seasonEpisodes.map { aniEp in
                        TMDBEpisode(
                            id: tvShowId * 1000 + season.seasonNumber * 100 + aniEp.number,
                            name: aniEp.title,
                            overview: aniEp.description,
                            stillPath: aniEp.stillPath,
                            episodeNumber: aniEp.number,
                            seasonNumber: aniEp.seasonNumber,
                            airDate: aniEp.airDate,
                            runtime: nil,
                            voteAverage: 0,
                            voteCount: 0
                        )
                    }
                    
                    let detail = TMDBSeasonDetail(
                        id: season.id,
                        name: season.name,
                        overview: season.overview ?? "",
                        posterPath: season.posterPath,
                        seasonNumber: season.seasonNumber,
                        airDate: season.airDate,
                        episodes: tmdbEpisodes
                    )
                    
                    await MainActor.run {
                        guard !Task.isCancelled,
                              generation == self.seasonLoadGeneration,
                              self.selectedSeason?.id == season.id else { return }
                        self.seasonDetail = detail
                        self.isLoadingSeason = false
                        self.seasonLoadTask = nil
                        if self.specialEpisodeContext == nil, let firstEpisode = detail.episodes.first {
                            self.selectedEpisodeForSearch = firstEpisode
                        }
                    }
                } else {
                    // For regular TV shows, fetch from TMDB
                    let detail = try await tmdbService.getSeasonDetails(tvShowId: tvShowId, seasonNumber: season.seasonNumber)
                    await MainActor.run {
                        guard !Task.isCancelled,
                              generation == self.seasonLoadGeneration,
                              self.selectedSeason?.id == season.id else { return }
                        self.seasonDetail = detail
                        self.isLoadingSeason = false
                        self.seasonLoadTask = nil
                        if self.specialEpisodeContext == nil, let firstEpisode = detail.episodes.first {
                            self.selectedEpisodeForSearch = firstEpisode
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
        guard let episodes = detail?.episodes, !episodes.isEmpty else {
            return
        }
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
        if downloadManager.completedDownloadItem(
            tmdbId: tvShow.id,
            isMovie: false,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber
        ) != nil {
            return true
        }

        guard let item = downloadManager.downloadItem(
            tmdbId: tvShow.id,
            isMovie: false,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber
        ) else {
            return false
        }

        switch item.status {
        case .queued, .downloading, .paused:
            return true
        case .completed, .failed:
            return false
        }
    }
#endif
}
