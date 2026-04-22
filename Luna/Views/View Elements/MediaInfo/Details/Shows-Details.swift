//
//  ShowsDetails.swift
//  Sora
//
//  Created by Francesco on 07/08/25.
//

import SwiftUI
import Kingfisher

struct TVShowSeasonsSection<InsertedContent: View>: View {
    let tvShow: TMDBTVShowWithSeasons?
    let isAnime: Bool
    @Binding var selectedSeason: TMDBSeason?
    @Binding var seasonDetail: TMDBSeasonDetail?
    @Binding var selectedEpisodeForSearch: TMDBEpisode?
    var animeEpisodes: [AniListEpisode]? = nil
    var animeSeasonTitles: [Int: String]? = nil
    let tmdbService: TMDBService
    @ViewBuilder let insertedContent: () -> InsertedContent
    
    @State private var isLoadingSeason = false
    @State private var showingSearchResults = false
    @State private var showingDownloadSheet = false
    @State private var downloadEpisode: TMDBEpisode? = nil
    @State private var downloadAllQueue: [TMDBEpisode] = []
    @State private var isDownloadingAll = false
    @State private var downloadWasEnqueued = false
    @State private var downloadWasSkipped = false
    @State private var showingNoServicesAlert = false
    @State private var romajiTitle: String?
    @State private var currentSeasonTitle: String?
    
    @StateObject private var serviceManager = ServiceManager.shared
    @StateObject private var stremioManager = StremioAddonManager.shared
    @AppStorage("horizontalEpisodeList") private var horizontalEpisodeList: Bool = false
    private var isGroupedBySeasons: Bool {
        return tvShow?.seasons.filter { $0.seasonNumber > 0 }.count ?? 0 > 1
    }
    
    private var useSeasonMenu: Bool {
        return UserDefaults.standard.bool(forKey: "seasonMenu")
    }

    private var hasActiveSources: Bool {
        !serviceManager.activeServices.isEmpty || !stremioManager.activeAddons.isEmpty
    }

    private struct EpisodeRenderItem: Identifiable {
        let id: String
        let index: Int
        let episode: TMDBEpisode
    }

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
        if isAnime, let currentSeasonTitle, !currentSeasonTitle.isEmpty {
            return currentSeasonTitle
        }
        if isAnime, let seasonName = selectedSeason?.name, !seasonName.isEmpty {
            return seasonName
        }
        return tvShow?.name ?? "Unknown Show"
    }
    
    var body: some View {
        let _ = Logger.shared.log("TVShowSeasonsSection body evaluate: showId=\(tvShow?.id ?? 0) hasTVShow=\(tvShow != nil) isAnime=\(isAnime) seasons=\(tvShow?.seasons.count ?? 0) selectedSeason=\(selectedSeason?.seasonNumber.description ?? "nil") seasonDetailEpisodes=\(seasonDetail?.episodes.count ?? 0) isLoadingSeason=\(isLoadingSeason) selectedEpisode=\(selectedEpisodeForSearch.map { "S\($0.seasonNumber)E\($0.episodeNumber):id\($0.id)" } ?? "nil") sheets=play:\(showingSearchResults),download:\(showingDownloadSheet)", type: "CrashProbe")
        VStack(alignment: .leading, spacing: 8) {
            if let tvShow = tvShow {
                let _ = Logger.shared.log("TVShowSeasonsSection body branch tvShow: showId=\(tvShow.id) seasons=\(tvShow.seasons.count) grouped=\(isGroupedBySeasons) menu=\(useSeasonMenu)", type: "CrashProbe")
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
                    
                    if !tvShow.genres.isEmpty {
                        DetailRow(title: "Genres", value: tvShow.genres.map { $0.name }.joined(separator: ", "))
                    }
                    
                    if tvShow.voteAverage > 0 {
                        DetailRow(title: "Rating", value: String(format: "%.1f/10", tvShow.voteAverage))
                    }
                    
                    if let ageRating = getAgeRating(from: tvShow.contentRatings) {
                        DetailRow(title: "Age Rating", value: ageRating)
                    }
                    
                    if let firstAirDate = tvShow.firstAirDate, !firstAirDate.isEmpty {
                        DetailRow(title: "First aired", value: "\(firstAirDate)")
                    }
                    
                    if let lastAirDate = tvShow.lastAirDate, !lastAirDate.isEmpty {
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
                
                insertedContent()
                
                if !tvShow.seasons.isEmpty {
                    let _ = Logger.shared.log("TVShowSeasonsSection body branch seasons-present: showId=\(tvShow.id) seasons=\(tvShow.seasons.count)", type: "CrashProbe")
                    if isGroupedBySeasons && !useSeasonMenu {
                        let _ = Logger.shared.log("TVShowSeasonsSection body branch styled selector: showId=\(tvShow.id)", type: "CrashProbe")
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
                        HStack {
                            Text("Episodes")
                                .font(.title2)
                                .fontWeight(.bold)
                            
                            Spacer()
                            
                            if seasonDetail != nil && hasActiveSources {
                                Button(action: startDownloadAllSeason) {
                                    Image(systemName: "arrow.down.circle")
                                        .font(.title3)
                                        .foregroundColor(.white)
                                }
                                .disabled(isDownloadingAll)
                            }
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal)
                        .padding(.top)
                    } else {
                        let _ = Logger.shared.log("TVShowSeasonsSection body branch header/menu selector: showId=\(tvShow.id)", type: "CrashProbe")
                        episodesSectionHeader
                    }
                    
                    episodeListSection
                } else {
                    let _ = Logger.shared.log("TVShowSeasonsSection body branch no seasons: showId=\(tvShow.id)", type: "CrashProbe")
                    EmptyView()
                }
            } else {
                let _ = Logger.shared.log("TVShowSeasonsSection body branch missing tvShow", type: "CrashProbe")
                EmptyView()
            }
        }
        .onAppear {
            Logger.shared.log(
                "TVShowSeasonsSection appear begin: showId=\(tvShow?.id ?? 0) isAnime=\(isAnime) seasons=\(tvShow?.seasons.count ?? 0) grouped=\(isGroupedBySeasons) menu=\(useSeasonMenu) selectedSeason=\(selectedSeason?.seasonNumber.description ?? "nil") seasonDetailEpisodes=\(seasonDetail?.episodes.count ?? 0) animeEpisodes=\(animeEpisodes?.count ?? 0)",
                type: "CrashProbe"
            )
            if let tvShow = tvShow, let selectedSeason = selectedSeason {
                loadSeasonDetails(tvShowId: tvShow.id, season: selectedSeason)
                Task {
                    Logger.shared.log("TVShowSeasonsSection romaji fetch begin: showId=\(tvShow.id)", type: "CrashProbe")
                    let romaji = await tmdbService.getRomajiTitle(for: "tv", id: tvShow.id)
                    await MainActor.run {
                        self.romajiTitle = romaji
                        Logger.shared.log("TVShowSeasonsSection romaji fetch assigned: showId=\(tvShow.id) hasRomaji=\(romaji != nil)", type: "CrashProbe")
                    }
                }
            } else {
                Logger.shared.log("TVShowSeasonsSection appear missing required state: hasTVShow=\(tvShow != nil) hasSelectedSeason=\(selectedSeason != nil)", type: "CrashProbe")
            }
        }
        .onChangeComp(of: selectedSeason?.seasonNumber) { _, newValue in
            Logger.shared.log("TVShowSeasonsSection selectedSeason changed: showId=\(tvShow?.id ?? 0) season=\(newValue?.description ?? "nil")", type: "CrashProbe")
        }
        .onChangeComp(of: seasonDetail?.episodes.count) { _, newValue in
            Logger.shared.log("TVShowSeasonsSection seasonDetail episodes changed: showId=\(tvShow?.id ?? 0) count=\(newValue?.description ?? "nil") season=\(seasonDetail?.seasonNumber.description ?? "nil")", type: "CrashProbe")
        }
        .onChangeComp(of: selectedEpisodeForSearch?.id) { _, _ in
            Logger.shared.log("TVShowSeasonsSection selectedEpisode changed: showId=\(tvShow?.id ?? 0) episode=\(selectedEpisodeForSearch.map { "S\($0.seasonNumber)E\($0.episodeNumber):id\($0.id)" } ?? "nil")", type: "CrashProbe")
        }
        .onChangeComp(of: isLoadingSeason) { _, newValue in
            Logger.shared.log("TVShowSeasonsSection isLoadingSeason changed: showId=\(tvShow?.id ?? 0) isLoading=\(newValue)", type: "CrashProbe")
        }
        .onChangeComp(of: showingSearchResults) { _, newValue in
            Logger.shared.log("TVShowSeasonsSection showingSearchResults changed: showId=\(tvShow?.id ?? 0) visible=\(newValue) episode=\(selectedEpisodeForSearch.map { "S\($0.seasonNumber)E\($0.episodeNumber)" } ?? "nil")", type: "CrashProbe")
        }
        .onChangeComp(of: showingDownloadSheet) { _, newValue in
            Logger.shared.log("TVShowSeasonsSection showingDownloadSheet changed: showId=\(tvShow?.id ?? 0) visible=\(newValue) episode=\((downloadEpisode ?? selectedEpisodeForSearch).map { "S\($0.seasonNumber)E\($0.episodeNumber)" } ?? "nil") queue=\(downloadAllQueue.count) downloadingAll=\(isDownloadingAll)", type: "CrashProbe")
        }
        .sheet(isPresented: $showingSearchResults) {
            let _ = Logger.shared.log("TVShowSeasonsSection constructing play sheet: showId=\(tvShow?.id ?? 0) title=\(getSearchTitle()) isAnime=\(isAnime) selectedEpisode=\(selectedEpisodeForSearch.map { "S\($0.seasonNumber)E\($0.episodeNumber)" } ?? "nil") originalTMDB=\(originalTMDBNumbers.map { "S\($0.season)E\($0.episode)" } ?? "nil") autoMode=\(UserDefaults.standard.bool(forKey: "servicesAutoModeEnabled"))", type: "CrashProbe")
            ModulesSearchResultsSheet(
                mediaTitle: getSearchTitle(),
                seasonTitleOverride: currentSeasonTitle,
                originalTitle: romajiTitle,
                isMovie: false,
                isAnimeContent: isAnime,
                selectedEpisode: selectedEpisodeForSearch,
                tmdbId: tvShow?.id ?? 0,
                animeSeasonTitle: isAnime ? currentSeasonTitle : nil,
                posterPath: tvShow?.posterPath,
                imdbId: tvShow?.externalIds?.imdbId,
                originalTMDBSeasonNumber: originalTMDBNumbers?.season,
                originalTMDBEpisodeNumber: originalTMDBNumbers?.episode,
                autoModeOnly: UserDefaults.standard.bool(forKey: "servicesAutoModeEnabled")
            )
        }
        .sheet(isPresented: $showingDownloadSheet, onDismiss: {
            Logger.shared.log("TVShowSeasonsSection download sheet dismissed: showId=\(tvShow?.id ?? 0) downloadingAll=\(isDownloadingAll) enqueued=\(downloadWasEnqueued) skipped=\(downloadWasSkipped) queue=\(downloadAllQueue.count)", type: "CrashProbe")
            if isDownloadingAll {
                if downloadWasEnqueued || downloadWasSkipped {
                    // Download enqueued or skipped — advance to next episode
                    downloadWasEnqueued = false
                    downloadWasSkipped = false
                    if !downloadAllQueue.isEmpty {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            showNextDownloadSheet()
                        }
                    } else {
                        isDownloadingAll = false
                    }
                } else {
                    // "Done" was tapped without download/skip — cancel entire queue
                    downloadAllQueue.removeAll()
                    isDownloadingAll = false
                }
            }
        }) {
            let _ = Logger.shared.log("TVShowSeasonsSection constructing download sheet: showId=\(tvShow?.id ?? 0) title=\(getSearchTitle()) isAnime=\(isAnime) selectedEpisode=\((downloadEpisode ?? selectedEpisodeForSearch).map { "S\($0.seasonNumber)E\($0.episodeNumber)" } ?? "nil") originalTMDB=\(originalTMDBNumbers.map { "S\($0.season)E\($0.episode)" } ?? "nil") queue=\(downloadAllQueue.count) autoMode=\(UserDefaults.standard.bool(forKey: "servicesAutoModeEnabled"))", type: "CrashProbe")
            ModulesSearchResultsSheet(
                mediaTitle: getSearchTitle(),
                seasonTitleOverride: currentSeasonTitle,
                originalTitle: romajiTitle,
                isMovie: false,
                isAnimeContent: isAnime,
                selectedEpisode: downloadEpisode ?? selectedEpisodeForSearch,
                tmdbId: tvShow?.id ?? 0,
                animeSeasonTitle: isAnime ? currentSeasonTitle : nil,
                posterPath: tvShow?.posterPath,
                imdbId: tvShow?.externalIds?.imdbId,
                originalTMDBSeasonNumber: originalTMDBNumbers?.season,
                originalTMDBEpisodeNumber: originalTMDBNumbers?.episode,
                downloadMode: true,
                autoModeOnly: UserDefaults.standard.bool(forKey: "servicesAutoModeEnabled"),
                onDownloadEnqueued: isDownloadingAll ? {
                    downloadWasEnqueued = true
                } : nil,
                onSkipRequested: isDownloadingAll ? {
                    downloadWasSkipped = true
                } : nil
            )
        }
        .alert("No Active Services", isPresented: $showingNoServicesAlert) {
            Button("OK") { }
        } message: {
            Text("You don't have any active services. Please go to the Services tab to download and activate services.")
        }
    }
    
    @ViewBuilder
    private var episodesSectionHeader: some View {
        let _ = Logger.shared.log("TVShowSeasonsSection construct episodesSectionHeader: showId=\(tvShow?.id ?? 0) hasSeasonDetail=\(seasonDetail != nil) hasActiveSources=\(hasActiveSources) grouped=\(isGroupedBySeasons) menu=\(useSeasonMenu)", type: "CrashProbe")
        HStack {
            Text("Episodes")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Spacer()
            
            if seasonDetail != nil && hasActiveSources {
                Button(action: startDownloadAllSeason) {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                        .foregroundColor(.white)
                }
                .disabled(isDownloadingAll)
            }
            
            if let tvShow = tvShow, isGroupedBySeasons && useSeasonMenu {
                seasonMenu(for: tvShow)
            }
        }
        .padding(.horizontal)
        .padding(.top)
    }
    
    @ViewBuilder
    private func seasonMenu(for tvShow: TMDBTVShowWithSeasons) -> some View {
        let seasons = tvShow.seasons.filter { $0.seasonNumber > 0 }
        let _ = Logger.shared.log("TVShowSeasonsSection construct seasonMenu: showId=\(tvShow.id) seasons=\(seasons.count) selectedSeason=\(selectedSeason?.seasonNumber.description ?? "nil")", type: "CrashProbe")
        
        if seasons.count > 1 {
            Menu {
                ForEach(seasons) { season in
                    Button(action: {
                        selectSeason(season, tvShowId: tvShow.id)
                    }) {
                        HStack {
                            Text(season.name)
                            if selectedSeason?.id == season.id {
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
                .onAppear {
                    Logger.shared.log("TVShowSeasonsSection seasonMenu skipped: showId=\(tvShow.id) seasons=\(seasons.count)", type: "CrashProbe")
                }
        }
    }
    
    @ViewBuilder
    private var seasonSelectorStyled: some View {
        if let tvShow = tvShow {
            let seasons = tvShow.seasons.filter { $0.seasonNumber > 0 }
            let _ = Logger.shared.log("TVShowSeasonsSection construct seasonSelectorStyled: showId=\(tvShow.id) seasons=\(seasons.count) selected=\(selectedSeason?.seasonNumber.description ?? "nil")", type: "CrashProbe")
            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(seasons) { season in
                            Button(action: {
                                selectSeason(season, tvShowId: tvShow.id)
                            }) {
                                VStack(spacing: 8) {
                                    KFImage(URL(string: season.fullPosterURL ?? ""))
                                        .placeholder {
                                            Rectangle()
                                                .fill(Color.gray.opacity(0.3))
                                                .frame(width: 80, height: 120)
                                                .overlay(
                                                    VStack {
                                                        Image(systemName: "tv")
                                                            .font(.title2)
                                                            .foregroundColor(.white.opacity(0.7))
                                                        Text("S\(season.seasonNumber)")
                                                            .font(.caption)
                                                            .fontWeight(.bold)
                                                            .foregroundColor(.white.opacity(0.7))
                                                    }
                                                )
                                        }
                                        .resizable()
                                        .aspectRatio(2/3, contentMode: .fill)
                                        .frame(width: 80, height: 120)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(selectedSeason?.id == season.id ? Color.accentColor : Color.clear, lineWidth: 2)
                                        )
                                    
                                    Text(season.name)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .lineLimit(1)
                                        .multilineTextAlignment(.center)
                                        .frame(width: 80)
                                        .foregroundColor(selectedSeason?.id == season.id ? .accentColor : .white)
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal)
                }
                .onAppear {
                    Logger.shared.log("TVShowSeasonsSection season selector appeared: showId=\(tvShow.id) seasons=\(seasons.count) selected=\(selectedSeason?.seasonNumber.description ?? "nil") summary=\(seasonDebugSummary(seasons))", type: "CrashProbe")
                }
            } else {
                EmptyView()
                    .onAppear {
                        Logger.shared.log("TVShowSeasonsSection season selector skipped: showId=\(tvShow.id) seasons=\(seasons.count)", type: "CrashProbe")
                    }
            }
        } else {
            EmptyView()
                .onAppear {
                    Logger.shared.log("TVShowSeasonsSection season selector missing tvShow", type: "CrashProbe")
                }
        }
    }

    @ViewBuilder
    private var episodeListSection: some View {
        Group {
            if let seasonDetail = seasonDetail {
                let episodeItems = episodeRenderItems(for: seasonDetail)
                let _ = Logger.shared.log("TVShowSeasonsSection construct episodeListSection with detail: showId=\(tvShow?.id ?? 0) season=\(seasonDetail.seasonNumber) count=\(episodeItems.count) horizontal=\(horizontalEpisodeList)", type: "CrashProbe")
                if horizontalEpisodeList {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 15) {
                            ForEach(episodeItems) { item in
                                createEpisodeCell(episode: item.episode, index: item.index)
                            }
                        }
                        .onAppear {
                            Logger.shared.log("TVShowSeasonsSection episode list appeared: showId=\(tvShow?.id ?? 0) season=\(seasonDetail.seasonNumber) count=\(episodeItems.count) layout=horizontal", type: "CrashProbe")
                        }
                    }
                    .padding(.horizontal)
                } else {
                    LazyVStack(spacing: 15) {
                        ForEach(episodeItems) { item in
                            createEpisodeCell(episode: item.episode, index: item.index)
                        }
                    }
                    .onAppear {
                        Logger.shared.log("TVShowSeasonsSection episode list appeared: showId=\(tvShow?.id ?? 0) season=\(seasonDetail.seasonNumber) count=\(episodeItems.count) layout=vertical", type: "CrashProbe")
                    }
                    .padding(.horizontal)
                }
            } else if isLoadingSeason {
                let _ = Logger.shared.log("TVShowSeasonsSection construct episodeListSection loading: showId=\(tvShow?.id ?? 0)", type: "CrashProbe")
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Loading episodes...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                EmptyView()
                    .onAppear {
                        Logger.shared.log("TVShowSeasonsSection episodeListSection empty: showId=\(tvShow?.id ?? 0) selectedSeason=\(selectedSeason?.seasonNumber.description ?? "nil")", type: "CrashProbe")
                    }
            }
        }
    }
    
    @ViewBuilder
    private func createEpisodeCell(episode: TMDBEpisode, index: Int) -> some View {
        if let tvShow = tvShow {
            let progress = ProgressManager.shared.getEpisodeProgress(
                showId: tvShow.id,
                seasonNumber: episode.seasonNumber,
                episodeNumber: episode.episodeNumber
            )
            let isSelected = selectedEpisodeForSearch?.id == episode.id
            
            EpisodeCell(
                episode: episode,
                showId: tvShow.id,
                showTitle: tvShow.name,
                showPosterURL: tvShow.fullPosterURL,
                progress: progress,
                isSelected: isSelected,
                onTap: { episodeTapAction(episode: episode) },
                onMarkWatched: { markAsWatched(episode: episode) },
                onResetProgress: { resetProgress(episode: episode) },
                onDownload: {
                    Logger.shared.log("TVShowSeasonsSection episode download tapped: showId=\(tvShow.id) episode=S\(episode.seasonNumber)E\(episode.episodeNumber) hasActiveSources=\(hasActiveSources)", type: "CrashProbe")
                    if hasActiveSources {
                        downloadEpisode = episode
                        selectedEpisodeForSearch = episode
                        showingDownloadSheet = true
                    } else {
                        showingNoServicesAlert = true
                        Logger.shared.log("TVShowSeasonsSection episode download blocked no sources: showId=\(tvShow.id) episode=S\(episode.seasonNumber)E\(episode.episodeNumber)", type: "CrashProbe")
                    }
                }
            )
        } else {
            EmptyView()
                .onAppear {
                    Logger.shared.log("TVShowSeasonsSection createEpisodeCell missing tvShow: episode=S\(episode.seasonNumber)E\(episode.episodeNumber) index=\(index)", type: "CrashProbe")
                }
        }
    }
    
    private func episodeTapAction(episode: TMDBEpisode) {
        Logger.shared.log("TVShowSeasonsSection episode tapped: showId=\(tvShow?.id ?? 0) episode=S\(episode.seasonNumber)E\(episode.episodeNumber) id=\(episode.id)", type: "CrashProbe")
        selectedEpisodeForSearch = episode
        searchInServicesForEpisode(episode: episode)
    }
    
    /// Look up the original TMDB season/episode numbers for the currently selected episode.
    /// Returns nil for non-anime or when no AniList episode match is found.
    private var originalTMDBNumbers: (season: Int, episode: Int)? {
        guard isAnime,
              let ep = selectedEpisodeForSearch,
              let animeEps = animeEpisodes,
              let match = animeEps.first(where: { $0.seasonNumber == ep.seasonNumber && $0.number == ep.episodeNumber }),
              let s = match.tmdbSeasonNumber,
              let e = match.tmdbEpisodeNumber
        else { return nil }
        return (s, e)
    }
    
    private func searchInServicesForEpisode(episode: TMDBEpisode) {
        Logger.shared.log("TVShowSeasonsSection searchInServicesForEpisode begin: showId=\(tvShow?.id ?? 0) episode=S\(episode.seasonNumber)E\(episode.episodeNumber) hasActiveSources=\(hasActiveSources)", type: "CrashProbe")
        guard (tvShow?.name) != nil else {
            Logger.shared.log("TVShowSeasonsSection searchInServicesForEpisode aborted missing tvShow: episode=S\(episode.seasonNumber)E\(episode.episodeNumber)", type: "CrashProbe")
            return
        }
        
        if !hasActiveSources {
            showingNoServicesAlert = true
            Logger.shared.log("TVShowSeasonsSection searchInServicesForEpisode blocked no sources: showId=\(tvShow?.id ?? 0) episode=S\(episode.seasonNumber)E\(episode.episodeNumber)", type: "CrashProbe")
            return
        }
        
        Logger.shared.log("TVShowSeasonsSection searchInServicesForEpisode presenting: showId=\(tvShow?.id ?? 0) episode=S\(episode.seasonNumber)E\(episode.episodeNumber)", type: "CrashProbe")
        showingSearchResults = true
    }
    
    private func markAsWatched(episode: TMDBEpisode) {
        guard let tvShow = tvShow else {
            Logger.shared.log("TVShowSeasonsSection markAsWatched aborted missing tvShow: episode=S\(episode.seasonNumber)E\(episode.episodeNumber)", type: "CrashProbe")
            return
        }
        Logger.shared.log("TVShowSeasonsSection markAsWatched: showId=\(tvShow.id) episode=S\(episode.seasonNumber)E\(episode.episodeNumber)", type: "CrashProbe")
        ProgressManager.shared.markEpisodeAsWatched(
            showId: tvShow.id,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber
        )
    }
    
    private func resetProgress(episode: TMDBEpisode) {
        guard let tvShow = tvShow else {
            Logger.shared.log("TVShowSeasonsSection resetProgress aborted missing tvShow: episode=S\(episode.seasonNumber)E\(episode.episodeNumber)", type: "CrashProbe")
            return
        }
        Logger.shared.log("TVShowSeasonsSection resetProgress: showId=\(tvShow.id) episode=S\(episode.seasonNumber)E\(episode.episodeNumber)", type: "CrashProbe")
        ProgressManager.shared.resetEpisodeProgress(
            showId: tvShow.id,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber
        )
    }

    private func selectSeason(_ season: TMDBSeason, tvShowId: Int) {
        Logger.shared.log("TVShowSeasonsSection selectSeason begin: showId=\(tvShowId) season=\(season.seasonNumber)", type: "CrashProbe")
        selectedSeason = season
        currentSeasonTitle = isAnime ? (animeSeasonTitles?[season.seasonNumber] ?? season.name) : nil
        Logger.shared.log("TVShowSeasonsSection selected season: showId=\(tvShowId) season=\(season.seasonNumber)", type: "CrashProbe")
        loadSeasonDetails(tvShowId: tvShowId, season: season)
    }

    private func loadSeasonDetails(tvShowId: Int, season: TMDBSeason) {
        Logger.shared.log("TVShowSeasonsSection loadSeasonDetails start: showId=\(tvShowId) season=\(season.seasonNumber) seasonId=\(season.id) isAnime=\(isAnime) animeEpisodes=\(animeEpisodes?.count ?? 0)", type: "CrashProbe")
        currentSeasonTitle = isAnime ? (animeSeasonTitles?[season.seasonNumber] ?? season.name) : nil
        isLoadingSeason = true
        seasonDetail = nil
        selectedEpisodeForSearch = nil
        
        Task {
            Logger.shared.log("TVShowSeasonsSection loadSeasonDetails task entered: showId=\(tvShowId) season=\(season.seasonNumber) isAnime=\(isAnime)", type: "CrashProbe")
            do {
                // For anime, build season detail from cached AniList episodes with TMDB metadata
                if isAnime, let animeEpisodes = animeEpisodes {
                    let seasonEpisodes = animeEpisodes.filter { $0.seasonNumber == season.seasonNumber }
                    Logger.shared.log("TVShowSeasonsSection loadSeasonDetails anime filtered: showId=\(tvShowId) season=\(season.seasonNumber) sourceEpisodes=\(animeEpisodes.count) filtered=\(seasonEpisodes.count)", type: "CrashProbe")
                    
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
                    Logger.shared.log("TVShowSeasonsSection loadSeasonDetails anime mapped: showId=\(tvShowId) season=\(season.seasonNumber) mapped=\(tmdbEpisodes.count) first=\(tmdbEpisodes.first?.episodeNumber.description ?? "nil")", type: "CrashProbe")
                    
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
                        Logger.shared.log("TVShowSeasonsSection loadSeasonDetails anime assign begin: showId=\(tvShowId) season=\(season.seasonNumber)", type: "CrashProbe")
                        self.seasonDetail = detail
                        self.isLoadingSeason = false
                        if let firstEpisode = detail.episodes.first {
                            self.selectedEpisodeForSearch = firstEpisode
                            Logger.shared.log("TVShowSeasonsSection loadSeasonDetails anime selected first: showId=\(tvShowId) episode=S\(firstEpisode.seasonNumber)E\(firstEpisode.episodeNumber)", type: "CrashProbe")
                        } else {
                            Logger.shared.log("TVShowSeasonsSection loadSeasonDetails anime no first episode: showId=\(tvShowId) season=\(season.seasonNumber)", type: "CrashProbe")
                        }
                        Logger.shared.log("TVShowSeasonsSection loadSeasonDetails anime done: showId=\(tvShowId) season=\(season.seasonNumber) episodes=\(detail.episodes.count)", type: "CrashProbe")
                    }
                } else {
                    // For regular TV shows, fetch from TMDB
                    Logger.shared.log("TVShowSeasonsSection loadSeasonDetails tmdb fetch begin: showId=\(tvShowId) season=\(season.seasonNumber) reason=\(isAnime ? "anime-without-episodes" : "regular-tv")", type: "CrashProbe")
                    let detail = try await tmdbService.getSeasonDetails(tvShowId: tvShowId, seasonNumber: season.seasonNumber)
                    await MainActor.run {
                        Logger.shared.log("TVShowSeasonsSection loadSeasonDetails tmdb assign begin: showId=\(tvShowId) season=\(season.seasonNumber)", type: "CrashProbe")
                        self.seasonDetail = detail
                        self.isLoadingSeason = false
                        if let firstEpisode = detail.episodes.first {
                            self.selectedEpisodeForSearch = firstEpisode
                            Logger.shared.log("TVShowSeasonsSection loadSeasonDetails tmdb selected first: showId=\(tvShowId) episode=S\(firstEpisode.seasonNumber)E\(firstEpisode.episodeNumber)", type: "CrashProbe")
                        } else {
                            Logger.shared.log("TVShowSeasonsSection loadSeasonDetails tmdb no first episode: showId=\(tvShowId) season=\(season.seasonNumber)", type: "CrashProbe")
                        }
                        Logger.shared.log("TVShowSeasonsSection loadSeasonDetails tmdb done: showId=\(tvShowId) season=\(season.seasonNumber) episodes=\(detail.episodes.count)", type: "CrashProbe")
                    }
                }
            } catch {
                await MainActor.run {
                    self.isLoadingSeason = false
                    Logger.shared.log("TVShowSeasonsSection loadSeasonDetails failed: showId=\(tvShowId) season=\(season.seasonNumber) error=\(error.localizedDescription)", type: "CrashProbe")
                }
            }
        }
    }
    
    private func getAgeRating(from contentRatings: TMDBContentRatings?) -> String? {
        guard let contentRatings = contentRatings else { return nil }
        
        for rating in contentRatings.results {
            if rating.iso31661 == "US" && !rating.rating.isEmpty {
                return rating.rating
            }
        }
        
        for rating in contentRatings.results {
            if !rating.rating.isEmpty {
                return rating.rating
            }
        }
        
        return nil
    }
    
    private func startDownloadAllSeason() {
        Logger.shared.log("TVShowSeasonsSection startDownloadAllSeason begin: showId=\(tvShow?.id ?? 0) season=\(seasonDetail?.seasonNumber.description ?? "nil") episodes=\(seasonDetail?.episodes.count ?? 0) hasActiveSources=\(hasActiveSources)", type: "CrashProbe")
        guard let episodes = seasonDetail?.episodes, !episodes.isEmpty else {
            Logger.shared.log("TVShowSeasonsSection startDownloadAllSeason aborted no episodes: showId=\(tvShow?.id ?? 0)", type: "CrashProbe")
            return
        }
        isDownloadingAll = true
        downloadAllQueue = Array(episodes.dropFirst())
        if let first = episodes.first {
            downloadEpisode = first
            selectedEpisodeForSearch = first
            Logger.shared.log("TVShowSeasonsSection startDownloadAllSeason presenting first: showId=\(tvShow?.id ?? 0) first=S\(first.seasonNumber)E\(first.episodeNumber) remaining=\(downloadAllQueue.count)", type: "CrashProbe")
            showingDownloadSheet = true
        }
    }
    
    private func showNextDownloadSheet() {
        Logger.shared.log("TVShowSeasonsSection showNextDownloadSheet begin: showId=\(tvShow?.id ?? 0) queue=\(downloadAllQueue.count)", type: "CrashProbe")
        guard !downloadAllQueue.isEmpty else {
            isDownloadingAll = false
            Logger.shared.log("TVShowSeasonsSection showNextDownloadSheet completed queue: showId=\(tvShow?.id ?? 0)", type: "CrashProbe")
            return
        }
        let next = downloadAllQueue.removeFirst()
        downloadEpisode = next
        selectedEpisodeForSearch = next
        Logger.shared.log("TVShowSeasonsSection showNextDownloadSheet presenting next: showId=\(tvShow?.id ?? 0) episode=S\(next.seasonNumber)E\(next.episodeNumber) remaining=\(downloadAllQueue.count)", type: "CrashProbe")
        showingDownloadSheet = true
    }
}
