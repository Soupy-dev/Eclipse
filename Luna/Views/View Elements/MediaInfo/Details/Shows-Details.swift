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
    let relatedMedia: [TMDBSearchResult]
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
    @AppStorage("horizontalEpisodeList") private var horizontalEpisodeList: Bool = false
    private let relatedPosterWidth: CGFloat = 86
    private let relatedPosterHeight: CGFloat = 128
    
    private var isGroupedBySeasons: Bool {
        return tvShow?.seasons.filter { $0.seasonNumber > 0 }.count ?? 0 > 1
    }
    
    private var useSeasonMenu: Bool {
        return UserDefaults.standard.bool(forKey: "seasonMenu")
    }
    
    private func getSearchTitle() -> String {
        if isAnime, let seasonName = selectedSeason?.name, !seasonName.isEmpty {
            return seasonName
        }
        return tvShow?.name ?? "Unknown Show"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let tvShow = tvShow {
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
                    if isGroupedBySeasons && !useSeasonMenu {
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
                        relatedMediaSection
                        
                        HStack {
                            Text("Episodes")
                                .font(.title2)
                                .fontWeight(.bold)
                            
                            Spacer()
                            
                            if seasonDetail != nil && !serviceManager.activeServices.isEmpty {
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
                        episodesSectionHeader
                        relatedMediaSection
                    }
                    
                    episodeListSection
                }
            }
        }
        .onAppear {
            if let tvShow = tvShow, let selectedSeason = selectedSeason {
                loadSeasonDetails(tvShowId: tvShow.id, season: selectedSeason)
                Task {
                    let romaji = await tmdbService.getRomajiTitle(for: "tv", id: tvShow.id)
                    await MainActor.run {
                        self.romajiTitle = romaji
                    }
                }
            }
        }
        .sheet(isPresented: $showingSearchResults) {
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
                originalTMDBEpisodeNumber: originalTMDBNumbers?.episode
            )
        }
        .sheet(isPresented: $showingDownloadSheet, onDismiss: {
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
        HStack {
            Text("Episodes")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Spacer()
            
            if seasonDetail != nil && !serviceManager.activeServices.isEmpty {
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
        
        if seasons.count > 1 {
            Menu {
                ForEach(seasons) { season in
                    Button(action: {
                        selectedSeason = season
                        loadSeasonDetails(tvShowId: tvShow.id, season: season)
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
                    Text(selectedSeason?.name ?? "Season 1")
                    
                    Image(systemName: "chevron.down")
                }
                .foregroundColor(.white)
            }
        }
    }
    
    @ViewBuilder
    private var seasonSelectorStyled: some View {
        if let tvShow = tvShow {
            let seasons = tvShow.seasons.filter { $0.seasonNumber > 0 }
            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(seasons) { season in
                            Button(action: {
                                selectedSeason = season
                                loadSeasonDetails(tvShowId: tvShow.id, season: season)
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
            }
        }
    }

    @ViewBuilder
    private var relatedMediaSection: some View {
        if !relatedMedia.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Related Media")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(relatedMedia, id: \.id) { media in
                            NavigationLink(destination: MediaDetailView(searchResult: media)) {
                                VStack(spacing: 6) {
                                    KFImage(URL(string: media.fullPosterURL ?? ""))
                                        .placeholder {
                                            Rectangle()
                                                .fill(Color.gray.opacity(0.3))
                                                .frame(width: relatedPosterWidth, height: relatedPosterHeight)
                                        }
                                        .resizable()
                                        .aspectRatio(2/3, contentMode: .fill)
                                        .frame(width: relatedPosterWidth, height: relatedPosterHeight)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))

                                    Text(media.displayTitle)
                                        .font(.caption2)
                                        .foregroundColor(.white)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                        .frame(width: relatedPosterWidth)
                                        .accessibilityLabel(media.displayTitle)
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
                            .accessibilityLabel("View details for \(media.displayTitle)")
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.top, 4)
        }
    }
    
    @ViewBuilder
    private var episodeListSection: some View {
        Group {
            if let seasonDetail = seasonDetail {
                if horizontalEpisodeList {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 15) {
                            ForEach(Array(seasonDetail.episodes.enumerated()), id: \.element.id) { index, episode in
                                createEpisodeCell(episode: episode, index: index)
                            }
                        }
                    }
                    .padding(.horizontal)
                } else {
                    LazyVStack(spacing: 15) {
                        ForEach(Array(seasonDetail.episodes.enumerated()), id: \.element.id) { index, episode in
                            createEpisodeCell(episode: episode, index: index)
                        }
                    }
                    .padding(.horizontal)
                }
            } else if isLoadingSeason {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Loading episodes...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
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
                    if !serviceManager.activeServices.isEmpty {
                        downloadEpisode = episode
                        selectedEpisodeForSearch = episode
                        showingDownloadSheet = true
                    }
                }
            )
        } else {
            EmptyView()
        }
    }
    
    private func episodeTapAction(episode: TMDBEpisode) {
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
        guard (tvShow?.name) != nil else { return }
        
        if serviceManager.activeServices.isEmpty {
            showingNoServicesAlert = true
            return
        }
        
        showingSearchResults = true
    }
    
    private func markAsWatched(episode: TMDBEpisode) {
        guard let tvShow = tvShow else { return }
        ProgressManager.shared.markEpisodeAsWatched(
            showId: tvShow.id,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber
        )
    }
    
    private func resetProgress(episode: TMDBEpisode) {
        guard let tvShow = tvShow else { return }
        ProgressManager.shared.resetEpisodeProgress(
            showId: tvShow.id,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber
        )
    }
    
    private func loadSeasonDetails(tvShowId: Int, season: TMDBSeason) {
        isLoadingSeason = true
        seasonDetail = nil
        selectedEpisodeForSearch = nil
        
        Task {
            do {
                // For anime, build season detail from cached AniList episodes with TMDB metadata
                if isAnime, let animeEpisodes = animeEpisodes {
                    let seasonEpisodes = animeEpisodes.filter { $0.seasonNumber == season.seasonNumber }
                    
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
                        self.seasonDetail = detail
                        self.isLoadingSeason = false
                        if let firstEpisode = detail.episodes.first {
                            self.selectedEpisodeForSearch = firstEpisode
                        }
                    }
                } else {
                    // For regular TV shows, fetch from TMDB
                    let detail = try await tmdbService.getSeasonDetails(tvShowId: tvShowId, seasonNumber: season.seasonNumber)
                    await MainActor.run {
                        self.seasonDetail = detail
                        self.isLoadingSeason = false
                        if let firstEpisode = detail.episodes.first {
                            self.selectedEpisodeForSearch = firstEpisode
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.isLoadingSeason = false
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
        guard let episodes = seasonDetail?.episodes, !episodes.isEmpty else { return }
        isDownloadingAll = true
        downloadAllQueue = Array(episodes.dropFirst())
        if let first = episodes.first {
            downloadEpisode = first
            selectedEpisodeForSearch = first
            showingDownloadSheet = true
        }
    }
    
    private func showNextDownloadSheet() {
        guard !downloadAllQueue.isEmpty else {
            isDownloadingAll = false
            return
        }
        let next = downloadAllQueue.removeFirst()
        downloadEpisode = next
        selectedEpisodeForSearch = next
        showingDownloadSheet = true
    }
}
