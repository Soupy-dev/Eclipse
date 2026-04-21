//
//  MediaDetailView.swift
//  Sora
//
//  Created by Francesco on 07/08/25.
//

import SwiftUI
import Kingfisher

// MARK: - View-Level Detail Cache
// Stores the fully-loaded state for a media detail screen so back-navigation is instant.
private final class MediaDetailCacheStore {
    static let shared = MediaDetailCacheStore()
    
    struct CachedDetail {
        let movieDetail: TMDBMovieDetail?
        let tvShowDetail: TMDBTVShowWithSeasons?
        let selectedSeason: TMDBSeason?
        let synopsis: String
        let romajiTitle: String?
        let logoURL: String?
        let isAnimeShow: Bool
        let anilistEpisodes: [AniListEpisode]?
        let animeSeasonTitles: [Int: String]?
        let castMembers: [TMDBCastMember]
        let relatedMedia: [TMDBSearchResult]
        let timestamp: Date
    }
    
    private var cache: [String: CachedDetail] = [:]
    private let lock = NSLock()
    private let ttl: TimeInterval = 300 // 5 minutes
    
    func get(key: String) -> CachedDetail? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[key],
              Date().timeIntervalSince(entry.timestamp) < ttl else {
            return nil
        }
        return entry
    }
    
    func set(key: String, detail: CachedDetail) {
        lock.lock()
        defer { lock.unlock() }
        cache[key] = detail
        // Evict old entries if cache grows too large
        if cache.count > 50 {
            let cutoff = Date().addingTimeInterval(-ttl)
            cache = cache.filter { $0.value.timestamp > cutoff }
        }
    }
}

struct MediaDetailView: View {
    let searchResult: TMDBSearchResult
    
    @StateObject private var tmdbService = TMDBService.shared
    @State private var movieDetail: TMDBMovieDetail?
    @State private var tvShowDetail: TMDBTVShowWithSeasons?
    @State private var selectedSeason: TMDBSeason?
    @State private var seasonDetail: TMDBSeasonDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var ambientColor: Color = Color.black
    @State private var showFullSynopsis: Bool = false
    @State private var synopsis: String = ""
    @State private var isBookmarked: Bool = false
    @State private var showingSearchResults = false
    @State private var showingDownloadSheet = false
    @State private var showingAddToCollection = false
    @State private var selectedEpisodeForSearch: TMDBEpisode?
    @State private var romajiTitle: String?
    @State private var logoURL: String?
    @State private var isAnimeShow = false
    @State private var anilistEpisodes: [AniListEpisode]? = nil
    @State private var animeSeasonTitles: [Int: String]? = nil
    
    @State private var castMembers: [TMDBCastMember] = []
    @State private var relatedMedia: [TMDBSearchResult] = []
    
    @State private var hasLoadedContent = false
    @State private var detailLoadTask: Task<Void, Never>?
    
    @StateObject private var serviceManager = ServiceManager.shared
    @ObservedObject private var libraryManager = LibraryManager.shared
    
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage("tmdbLanguage") private var selectedLanguage = "en-US"
    private let nextEpisodeSheetPresentationDelay: TimeInterval = 1.2

    private var headerHeight: CGFloat {
#if os(tvOS)
        UIScreen.main.bounds.height * 0.8
#else
        isIPad ? 680 : 550
#endif
    }


    private var minHeaderHeight: CGFloat {
#if os(tvOS)
        UIScreen.main.bounds.height * 0.8
#else
        isIPad ? 500 : 400
#endif
    }

    private var playButtonText: String {
        if searchResult.isMovie {
            return "Play"
        } else if let selectedEpisode = selectedEpisodeForSearch {
            return "Play S\(selectedEpisode.seasonNumber)E\(selectedEpisode.episodeNumber)"
        } else {
            return "Play"
        }
    }
    
    var body: some View {
        ZStack {
            LunaTheme.shared.backgroundBase
                .ignoresSafeArea(.all)
            
            Group {
                ambientColor
            }
            .ignoresSafeArea(.all)
            
            if isLoading {
                loadingView
            } else if let errorMessage = errorMessage {
                errorView(errorMessage)
            } else {
                mainScrollView
            }
#if !os(tvOS)
            navigationOverlay
#endif
        }
        .navigationBarHidden(true)
#if !os(tvOS)
        .gesture(
            DragGesture()
                .onEnded { value in
                    if value.translation.width > 100 && abs(value.translation.height) < 50 {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
        )
#else
        .onExitCommand {
            presentationMode.wrappedValue.dismiss()
        }
#endif
        .onAppear {
            if !hasLoadedContent {
                loadMediaDetails()
            }
            updateBookmarkStatus()
        }
        .onDisappear {
            if let detailLoadTask {
                Logger.shared.log("MediaDetail load task cancelled on disappear: id=\(searchResult.id)", type: "CrashProbe")
                detailLoadTask.cancel()
                self.detailLoadTask = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestNextEpisode)) { notification in
            guard let userInfo = notification.userInfo,
                  let tmdbId = userInfo["tmdbId"] as? Int,
                  tmdbId == searchResult.id,
                  let seasonNumber = userInfo["seasonNumber"] as? Int,
                  let episodeNumber = userInfo["episodeNumber"] as? Int else { return }

            // Find the next episode in the current season detail
            if let episodes = seasonDetail?.episodes,
               let nextEp = episodes.first(where: { $0.seasonNumber == seasonNumber && $0.episodeNumber == episodeNumber }) {
                selectedEpisodeForSearch = nextEp
                showingSearchResults = false
                // Delay to ensure the player is fully dismissed before presenting the sheet
                DispatchQueue.main.asyncAfter(deadline: .now() + nextEpisodeSheetPresentationDelay) {
                    showingSearchResults = true
                }
            } else {
                Logger.shared.log("NextEpisode: Could not find S\(seasonNumber)E\(episodeNumber) in loaded season detail for tmdbId=\(tmdbId)", type: "Player")
            }
        }
        .onChangeComp(of: libraryManager.collections) { _, _ in
            updateBookmarkStatus()
        }
        .sheet(isPresented: $showingSearchResults) {
            ModulesSearchResultsSheet(
                mediaTitle: {
                    if isAnimeShow, let episode = selectedEpisodeForSearch,
                       let seasonTitle = animeSeasonTitles?[episode.seasonNumber] {
                        return seasonTitle
                    }
                    return searchResult.displayTitle
                }(),
                seasonTitleOverride: {
                    if isAnimeShow, let episode = selectedEpisodeForSearch,
                       let seasonTitle = animeSeasonTitles?[episode.seasonNumber] {
                        return seasonTitle
                    }
                    return nil
                }(),
                originalTitle: romajiTitle,
                isMovie: searchResult.isMovie,
                isAnimeContent: isAnimeShow,
                selectedEpisode: selectedEpisodeForSearch,
                tmdbId: searchResult.id,
                animeSeasonTitle: isAnimeShow ? "anime" : nil,
                posterPath: searchResult.isMovie ? movieDetail?.posterPath : tvShowDetail?.posterPath,
                imdbId: searchResult.isMovie ? movieDetail?.imdbId : tvShowDetail?.externalIds?.imdbId
            )
        }
        .sheet(isPresented: $showingDownloadSheet) {
            ModulesSearchResultsSheet(
                mediaTitle: {
                    if isAnimeShow, let episode = selectedEpisodeForSearch,
                       let seasonTitle = animeSeasonTitles?[episode.seasonNumber] {
                        return seasonTitle
                    }
                    return searchResult.displayTitle
                }(),
                seasonTitleOverride: {
                    if isAnimeShow, let episode = selectedEpisodeForSearch,
                       let seasonTitle = animeSeasonTitles?[episode.seasonNumber] {
                        return seasonTitle
                    }
                    return nil
                }(),
                originalTitle: romajiTitle,
                isMovie: searchResult.isMovie,
                isAnimeContent: isAnimeShow,
                selectedEpisode: selectedEpisodeForSearch,
                tmdbId: searchResult.id,
                animeSeasonTitle: isAnimeShow ? "anime" : nil,
                posterPath: searchResult.isMovie ? movieDetail?.posterPath : tvShowDetail?.posterPath,
                imdbId: searchResult.isMovie ? movieDetail?.imdbId : tvShowDetail?.externalIds?.imdbId,
                downloadMode: true
            )
        }
        .sheet(isPresented: $showingAddToCollection) {
            AddToCollectionView(searchResult: searchResult)
        }
    }
    
    @ViewBuilder
    private var loadingView: some View {
        VStack {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading...")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    @ViewBuilder
    private func errorView(_ message: String) -> some View {
        VStack {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            
            Text("Error")
                .font(.title2)
                .padding(.top)
            
            Text(message)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button("Try Again") {
                loadMediaDetails()
            }
            .padding(.top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    @ViewBuilder
    private var navigationOverlay: some View {
        VStack {
            HStack {
                Button(action: {
                    presentationMode.wrappedValue.dismiss()
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .applyLiquidGlassBackground(cornerRadius: 16)
                }
                
                Spacer()
            }
            .padding(.horizontal)
            
            Spacer()
        }
    }
    
    @ViewBuilder
    private var mainScrollView: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                heroImageSection
                contentContainer
            }
        }
        .ignoresSafeArea(edges: [.top, .leading, .trailing])
    }
    
    @ViewBuilder
    private var heroImageSection: some View {
        ZStack(alignment: .bottom) {
            StretchyHeaderView(
                backdropURL: {
                    if searchResult.isMovie {
                        return movieDetail?.fullBackdropURL ?? movieDetail?.fullPosterURL
                    } else {
                        return tvShowDetail?.fullBackdropURL ?? tvShowDetail?.fullPosterURL
                    }
                }(),
                isMovie: searchResult.isMovie,
                headerHeight: headerHeight,
                minHeaderHeight: minHeaderHeight,
                onAmbientColorExtracted: { color in
                    ambientColor = color
                }
            )
            
            gradientOverlay
            headerSection
        }
    }
    
    @ViewBuilder
    private var contentContainer: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                synopsisSection
                playAndBookmarkSection
                
                if searchResult.isMovie {
                    MovieDetailsSection(movie: movieDetail)
                    
                    if !castMembers.isEmpty {
                        castSection
                    }
                    
                    StarRatingView(mediaId: searchResult.id)
                } else {
                    episodesSection
                }
                
                Spacer(minLength: 50)
            }
            .background(
                ZStack {
                    LinearGradient(
                        colors: [ambientColor, LunaTheme.shared.backgroundBase],
                        startPoint: .top,
                        endPoint: UnitPoint(x: 0.5, y: 0.35)
                    )
                }
            )
        }
    }
    
    @ViewBuilder
    private var gradientOverlay: some View {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: ambientColor.opacity(0.0), location: 0.0),
                .init(color: ambientColor.opacity(0.4), location: 0.2),
                .init(color: ambientColor.opacity(0.6), location: 0.5),
                .init(color: ambientColor.opacity(1), location: 1.0)
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 0))
    }
    
    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .center, spacing: 8) {
            if let logoURL = logoURL {
                KFImage(URL(string: logoURL))
                    .placeholder {
                        titleText
                    }
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: isIPad ? 400 : 280, maxHeight: isIPad ? 140 : 100)
                    .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
            } else {
                titleText
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 10)
        .padding(.horizontal)
    }
    
    @ViewBuilder
    private var titleText: some View {
        Text(searchResult.displayTitle)
            .font(.largeTitle)
            .fontWeight(.bold)
            .foregroundColor(.white)
            .lineLimit(3)
            .multilineTextAlignment(.center)
            .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
            .frame(maxWidth: .infinity, alignment: .center)
    }
    
    @ViewBuilder
    private var synopsisSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !synopsis.isEmpty {
                Text(showFullSynopsis ? synopsis : String(synopsis.prefix(180)) + (synopsis.count > 180 ? "..." : ""))
                    .font(.body)
                    .foregroundColor(.white)
                    .lineLimit(showFullSynopsis ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showFullSynopsis.toggle()
                        }
                    }
            } else if let overview = searchResult.isMovie ? movieDetail?.overview : tvShowDetail?.overview,
                      !overview.isEmpty {
                Text(showFullSynopsis ? overview : String(overview.prefix(200)) + (overview.count > 200 ? "..." : ""))
                    .font(.body)
                    .foregroundColor(.white)
                    .lineLimit(showFullSynopsis ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showFullSynopsis.toggle()
                        }
                    }
            }
        }
    }
    
    @ViewBuilder
    private var playAndBookmarkSection: some View {
        HStack(spacing: 8) {
            Button(action: {
                searchInServices()
            }) {
                HStack {
                    Image(systemName: serviceManager.activeServices.isEmpty ? "exclamationmark.triangle" : "play.fill")
                    
                    Text(serviceManager.activeServices.isEmpty ? "No Services" : playButtonText)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .padding(.horizontal, 25)
                .applyLiquidGlassBackground(
                    cornerRadius: 12,
                    fallbackFill: serviceManager.activeServices.isEmpty ? Color.gray.opacity(0.3) : Color.black.opacity(0.2),
                    fallbackMaterial: serviceManager.activeServices.isEmpty ? .thinMaterial : .ultraThinMaterial,
                    glassTint: serviceManager.activeServices.isEmpty ? Color.gray.opacity(0.3) : nil
                )
                .foregroundColor(serviceManager.activeServices.isEmpty ? .secondary : .white)
                .cornerRadius(8)
            }
            .disabled(serviceManager.activeServices.isEmpty)
            
            Button(action: {
                toggleBookmark()
            }) {
                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.title2)
                    .frame(width: 42, height: 42)
                    .applyLiquidGlassBackground(cornerRadius: 12)
                    .foregroundColor(isBookmarked ? .yellow : .white)
                    .cornerRadius(8)
            }
            
            if searchResult.isMovie {
                Button(action: {
                    downloadInServices()
                }) {
                    Image(systemName: downloadButtonIcon)
                        .font(.title2)
                        .frame(width: 42, height: 42)
                        .applyLiquidGlassBackground(
                            cornerRadius: 12,
                            glassTint: downloadButtonTint
                        )
                        .foregroundColor(downloadButtonColor)
                        .cornerRadius(8)
                }
                .disabled(serviceManager.activeServices.isEmpty || isCurrentlyDownloading)
            }
            
            Button(action: {
                showingAddToCollection = true
            }) {
                Image(systemName: "plus")
                    .font(.title2)
                    .frame(width: 42, height: 42)
                    .applyLiquidGlassBackground(cornerRadius: 12)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
        }
        .padding(.horizontal)
    }
    
    @ViewBuilder
    private var episodesSection: some View {
        if !searchResult.isMovie {
            TVShowSeasonsSection(
                tvShow: tvShowDetail,
                isAnime: isAnimeShow,
                selectedSeason: $selectedSeason,
                seasonDetail: $seasonDetail,
                selectedEpisodeForSearch: $selectedEpisodeForSearch,
                animeEpisodes: anilistEpisodes,
                animeSeasonTitles: animeSeasonTitles,
                tmdbService: tmdbService
            ) {
                if !castMembers.isEmpty {
                    castSection
                }
                
                StarRatingView(mediaId: searchResult.id)
            }
        }
    }
    
    private func toggleBookmark() {
        withAnimation(.easeInOut(duration: 0.2)) {
            libraryManager.toggleBookmark(for: searchResult)
            updateBookmarkStatus()
        }
    }
    
    // MARK: - Cast Section
    
    @ViewBuilder
    private var castSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cast")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .padding(.horizontal)
            
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(Array(castMembers.prefix(20).enumerated()), id: \.offset) { _, member in
                        VStack(spacing: 8) {
                            if let url = member.fullProfileURL {
                                KFImage(URL(string: url))
                                    .placeholder {
                                        castPlaceholder
                                    }
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 80, height: 80)
                                    .clipShape(Circle())
                            } else {
                                castPlaceholder
                            }
                            
                            Text(member.name)
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.white)
                                .lineLimit(1)
                            
                            if let character = member.character, !character.isEmpty {
                                Text(character)
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.5))
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: 85)
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.top, 8)
    }
    
    private var castPlaceholder: some View {
        Circle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 80, height: 80)
            .overlay(
                Image(systemName: "person.fill")
                    .font(.title2)
                    .foregroundColor(.white.opacity(0.3))
            )
    }
    
    // MARK: - Related Section
    
    private func updateBookmarkStatus() {
        isBookmarked = libraryManager.isBookmarked(searchResult)
    }
    
    private func searchInServices() {
        // This function will only be called when services are available
        // since the button is disabled when no services are active
        
        if !searchResult.isMovie {
            if selectedEpisodeForSearch != nil {
            } else if let seasonDetail = seasonDetail, !seasonDetail.episodes.isEmpty {
                selectedEpisodeForSearch = seasonDetail.episodes.first
            } else {
                selectedEpisodeForSearch = nil
            }
        } else {
            selectedEpisodeForSearch = nil
        }
        
        showingSearchResults = true
    }
    
    private func downloadInServices() {
        if !searchResult.isMovie {
            if selectedEpisodeForSearch != nil {
            } else if let seasonDetail = seasonDetail, !seasonDetail.episodes.isEmpty {
                selectedEpisodeForSearch = seasonDetail.episodes.first
            } else {
                selectedEpisodeForSearch = nil
            }
        } else {
            selectedEpisodeForSearch = nil
        }
        
        showingDownloadSheet = true
    }
    
    private var isCurrentlyDownloading: Bool {
        if searchResult.isMovie {
            return DownloadManager.shared.isDownloading(tmdbId: searchResult.id, isMovie: true)
        } else if let ep = selectedEpisodeForSearch {
            return DownloadManager.shared.isDownloading(tmdbId: searchResult.id, isMovie: false, seasonNumber: ep.seasonNumber, episodeNumber: ep.episodeNumber)
        }
        return false
    }
    
    private var isAlreadyDownloaded: Bool {
        if searchResult.isMovie {
            return DownloadManager.shared.isDownloaded(tmdbId: searchResult.id, isMovie: true)
        } else if let ep = selectedEpisodeForSearch {
            return DownloadManager.shared.isDownloaded(tmdbId: searchResult.id, isMovie: false, seasonNumber: ep.seasonNumber, episodeNumber: ep.episodeNumber)
        }
        return false
    }
    
    private var downloadButtonIcon: String {
        if isAlreadyDownloaded {
            return "checkmark.circle.fill"
        } else if isCurrentlyDownloading {
            return "arrow.down.circle"
        }
        return "arrow.down.circle"
    }
    
    private var downloadButtonColor: Color {
        if isAlreadyDownloaded {
            return .green
        } else if isCurrentlyDownloading {
            return .blue
        }
        return .white
    }
    
    private var downloadButtonTint: Color? {
        if isAlreadyDownloaded {
            return Color.green.opacity(0.2)
        } else if isCurrentlyDownloading {
            return Color.blue.opacity(0.2)
        }
        return nil
    }
    
    private func loadMediaDetails() {
        if let existingTask = detailLoadTask {
            Logger.shared.log("MediaDetail cancelling previous task before reload: id=\(searchResult.id)", type: "CrashProbe")
            existingTask.cancel()
            detailLoadTask = nil
        }
        let detailCacheKey = searchResult.stableIdentity
        Logger.shared.log("MediaDetail load start: id=\(searchResult.id) type=\(searchResult.mediaType) title=\(searchResult.displayTitle)", type: "CrashProbe")
        Logger.shared.log("MediaDetail cache lookup begin: key=\(detailCacheKey)", type: "CrashProbe")

        // Check view-level cache first for instant back-navigation
        if let cached = MediaDetailCacheStore.shared.get(key: detailCacheKey) {
            Logger.shared.log("MediaDetail cache hit: key=\(detailCacheKey) type=\(searchResult.mediaType)", type: "CrashProbe")
            // Defer state update to next run loop tick so SwiftUI properly re-renders
            Task { @MainActor in
                self.movieDetail = cached.movieDetail
                self.tvShowDetail = cached.tvShowDetail
                self.selectedSeason = cached.selectedSeason
                self.synopsis = cached.synopsis
                self.romajiTitle = cached.romajiTitle
                self.logoURL = cached.logoURL
                self.isAnimeShow = cached.isAnimeShow
                self.anilistEpisodes = cached.anilistEpisodes
                self.animeSeasonTitles = cached.animeSeasonTitles
                self.castMembers = cached.castMembers
                self.relatedMedia = cached.relatedMedia
                self.isLoading = false
                self.hasLoadedContent = true
            }
            return
        }
        Logger.shared.log("MediaDetail cache miss: key=\(detailCacheKey)", type: "CrashProbe")

        isLoading = true
        errorMessage = nil
        Logger.shared.log("MediaDetail scheduling async task: id=\(searchResult.id)", type: "CrashProbe")
        
        detailLoadTask = Task {
            Logger.shared.log("MediaDetail async task entered: id=\(searchResult.id)", type: "CrashProbe")
            defer {
                if Task.isCancelled {
                    Logger.shared.log("MediaDetail async task finished as cancelled: id=\(searchResult.id)", type: "CrashProbe")
                } else {
                    Logger.shared.log("MediaDetail async task finished: id=\(searchResult.id)", type: "CrashProbe")
                }
            }
            do {
                if searchResult.isMovie {
                    Logger.shared.log("Movie detail fetch begin: tmdbId=\(searchResult.id)", type: "CrashProbe")
                    Logger.shared.log("Movie detail step: getMovieDetails start id=\(searchResult.id)", type: "CrashProbe")
                    let detail = try await tmdbService.getMovieDetails(id: searchResult.id)
                    Logger.shared.log("Movie detail step: getMovieDetails done id=\(searchResult.id)", type: "CrashProbe")

                    Logger.shared.log("Movie detail step: getMovieImages start id=\(searchResult.id)", type: "CrashProbe")
                    let images = try await tmdbService.getMovieImages(id: searchResult.id, preferredLanguage: selectedLanguage)
                    Logger.shared.log("Movie detail step: getMovieImages done id=\(searchResult.id)", type: "CrashProbe")

                    Logger.shared.log("Movie detail step: getRomajiTitle start id=\(searchResult.id)", type: "CrashProbe")
                    let romaji = await tmdbService.getRomajiTitle(for: "movie", id: searchResult.id)
                    Logger.shared.log("Movie detail step: getRomajiTitle done id=\(searchResult.id)", type: "CrashProbe")

                    Logger.shared.log("Movie detail step: getMovieCredits start id=\(searchResult.id)", type: "CrashProbe")
                    let credits = try? await tmdbService.getMovieCredits(id: searchResult.id)
                    Logger.shared.log("Movie detail step: getMovieCredits done id=\(searchResult.id) cast=\(credits?.cast.count ?? 0)", type: "CrashProbe")

                    Logger.shared.log("Movie detail step: getMovieRecommendations start id=\(searchResult.id)", type: "CrashProbe")
                    let recommendations = try? await tmdbService.getMovieRecommendations(id: searchResult.id)
                    Logger.shared.log("Movie detail step: getMovieRecommendations done id=\(searchResult.id) recs=\(recommendations?.count ?? 0)", type: "CrashProbe")
                    Logger.shared.log("Movie detail fetch complete: tmdbId=\(searchResult.id) cast=\(credits?.cast.count ?? 0) recs=\(recommendations?.count ?? 0)", type: "CrashProbe")
                    
                    if Task.isCancelled { return }
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        self.movieDetail = detail
                        self.synopsis = detail.overview ?? ""
                        self.romajiTitle = romaji
                        if let logo = tmdbService.getBestLogo(from: images, preferredLanguage: selectedLanguage) {
                            self.logoURL = logo.fullURL
                        }
                        self.castMembers = credits?.cast ?? []
                        self.relatedMedia = recommendations?.map { $0.asSearchResult } ?? []
                        self.isLoading = false
                        self.hasLoadedContent = true
                        
                        // Store in view-level cache for instant back-navigation
                        MediaDetailCacheStore.shared.set(key: detailCacheKey, detail: .init(
                            movieDetail: detail,
                            tvShowDetail: nil,
                            selectedSeason: nil,
                            synopsis: self.synopsis,
                            romajiTitle: self.romajiTitle,
                            logoURL: self.logoURL,
                            isAnimeShow: false,
                            anilistEpisodes: nil,
                            animeSeasonTitles: nil,
                            castMembers: self.castMembers,
                            relatedMedia: self.relatedMedia,
                            timestamp: Date()
                        ))
                    }
                } else {
                    Logger.shared.log("TV detail fetch begin: tmdbId=\(searchResult.id)", type: "CrashProbe")
                    Logger.shared.log("TV detail step: queue getTVShowWithSeasons id=\(searchResult.id)", type: "CrashProbe")
                    Logger.shared.log("TV detail step: queue getTVShowImages id=\(searchResult.id)", type: "CrashProbe")
                    Logger.shared.log("TV detail step: queue getRomajiTitle id=\(searchResult.id)", type: "CrashProbe")
                    Logger.shared.log("TV detail step: queue getTVCredits id=\(searchResult.id)", type: "CrashProbe")
                    Logger.shared.log("TV detail step: queue getTVRecommendations id=\(searchResult.id)", type: "CrashProbe")
                    async let detailTask = tmdbService.getTVShowWithSeasons(id: searchResult.id)
                    async let imagesTask = tmdbService.getTVShowImages(id: searchResult.id, preferredLanguage: selectedLanguage)
                    async let romajiTask = tmdbService.getRomajiTitle(for: "tv", id: searchResult.id)
                    async let creditsTask = tmdbService.getTVCredits(id: searchResult.id)
                    async let recommendationsTask = tmdbService.getTVRecommendations(id: searchResult.id)

                    let detail = try await detailTask
                    Logger.shared.log("TV detail step: getTVShowWithSeasons done id=\(searchResult.id) seasons=\(detail.seasons.count)", type: "CrashProbe")

                    let images: TMDBImagesResponse?
                    do {
                        images = try await imagesTask
                        Logger.shared.log("TV detail step: getTVShowImages done id=\(searchResult.id) hasImages=true", type: "CrashProbe")
                    } catch {
                        images = nil
                        Logger.shared.log("TV detail step: getTVShowImages failed id=\(searchResult.id) error=\(error.localizedDescription)", type: "CrashProbe")
                    }

                    let romaji = await romajiTask
                    Logger.shared.log("TV detail step: getRomajiTitle done id=\(searchResult.id)", type: "CrashProbe")

                    let credits: TMDBCreditsResponse?
                    do {
                        credits = try await creditsTask
                        Logger.shared.log("TV detail step: getTVCredits done id=\(searchResult.id) cast=\(credits?.cast.count ?? 0)", type: "CrashProbe")
                    } catch {
                        credits = nil
                        Logger.shared.log("TV detail step: getTVCredits failed id=\(searchResult.id) error=\(error.localizedDescription)", type: "CrashProbe")
                    }

                    let recommendations: [TMDBTVShow]?
                    do {
                        recommendations = try await recommendationsTask
                        Logger.shared.log("TV detail step: getTVRecommendations done id=\(searchResult.id) recs=\(recommendations?.count ?? 0)", type: "CrashProbe")
                    } catch {
                        recommendations = nil
                        Logger.shared.log("TV detail step: getTVRecommendations failed id=\(searchResult.id) error=\(error.localizedDescription)", type: "CrashProbe")
                    }
                    let recommendationMedia = recommendations?.map { $0.asSearchResult } ?? []
                    
                    // Detect anime/donghua for tracking/catalog — includes JP, CN, KR, TW animation
                    let asianAnimationCountries: Set<String> = ["JP", "CN", "KR", "TW"]
                    let isAsianAnimation = detail.originCountry?.contains(where: { asianAnimationCountries.contains($0) }) ?? false
                    let isAnimation = detail.genres.contains { $0.id == 16 }
                    let detectedAsAnime = isAsianAnimation && isAnimation
                    Logger.shared.log("MediaDetailView: \(detail.name) — isAsianAnimation=\(isAsianAnimation) isAnimation=\(isAnimation) detectedAsAnime=\(detectedAsAnime) originCountry=\(detail.originCountry ?? []) genres=\(detail.genres.map { $0.id })", type: "AniList")
                    
                    // Fetch AniList hybrid seasons/episodes if anime
                    var animeData: AniListAnimeWithSeasons? = nil
                    if detectedAsAnime {
                        do {
                            Logger.shared.log("MediaDetailView: Starting AniList fetch for \(detail.name) (tmdbId=\(detail.id))", type: "AniList")
                            animeData = try await AniListService.shared.fetchAnimeDetailsWithEpisodes(
                                title: detail.name,
                                tmdbShowId: detail.id,
                                tmdbService: tmdbService,
                                tmdbShowPoster: detail.fullPosterURL,
                                token: nil
                            )
                            Logger.shared.log("MediaDetailView: Fetched AniList hybrid data for \(detail.name) with \(animeData?.seasons.count ?? 0) seasons, \(animeData?.totalEpisodes ?? 0) total episodes", type: "AniList")
                            
                            // Register AniList season IDs with tracker for accurate syncing
                            if let animeData = animeData {
                                let seasonMappings = animeData.seasons.map { (seasonNumber: $0.seasonNumber, anilistId: $0.anilistId) }
                                TrackerManager.shared.registerAniListAnimeData(tmdbId: detail.id, seasons: seasonMappings)
                            }
                        } catch {
                            Logger.shared.log("MediaDetailView: FAILED AniList fetch for \(detail.name): \(error.localizedDescription)", type: "Error")
                        }
                    } else {
                        Logger.shared.log("MediaDetailView: Skipping AniList fetch — not detected as anime", type: "AniList")
                    }
                    
                    Logger.shared.log("TV detail step: apply state start id=\(searchResult.id)", type: "CrashProbe")
                    if Task.isCancelled { return }
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        self.synopsis = detail.overview ?? ""
                        self.romajiTitle = romaji
                        self.isAnimeShow = detectedAsAnime
                        self.castMembers = credits?.cast ?? []
                        self.relatedMedia = recommendationMedia
                        
                        if let animeData = animeData {
                            Logger.shared.log("MediaDetailView: Using AniList structure — \(animeData.seasons.count) seasons", type: "AniList")
                            // Build AniList seasons list with TMDB-compatible fields
                            let aniSeasons: [TMDBSeason] = animeData.seasons.map { aniSeason in
                                var posterPath: String?
                                if let posterUrl = aniSeason.posterUrl {
                                    if posterUrl.contains("image.tmdb.org") {
                                        if let range = posterUrl.range(of: "/original") {
                                            posterPath = String(posterUrl[range.lowerBound...]).replacingOccurrences(of: "/original", with: "")
                                        }
                                    } else {
                                        posterPath = posterUrl
                                    }
                                } else {
                                    posterPath = detail.posterPath
                                }
                                
                                return TMDBSeason(
                                    id: detail.id * 1000 + aniSeason.seasonNumber,
                                    name: aniSeason.title,
                                    overview: "",
                                    posterPath: posterPath,
                                    seasonNumber: aniSeason.seasonNumber,
                                    episodeCount: aniSeason.episodes.count,
                                    airDate: nil
                                )
                            }
                            
                            let detailWithAniSeasons = TMDBTVShowWithSeasons(
                                id: detail.id,
                                name: detail.name,
                                overview: detail.overview,
                                posterPath: detail.posterPath,
                                backdropPath: detail.backdropPath,
                                firstAirDate: detail.firstAirDate,
                                lastAirDate: detail.lastAirDate,
                                voteAverage: detail.voteAverage,
                                popularity: detail.popularity,
                                genres: detail.genres,
                                tagline: detail.tagline,
                                status: detail.status,
                                originalLanguage: detail.originalLanguage,
                                originalName: detail.originalName,
                                adult: detail.adult,
                                voteCount: detail.voteCount,
                                numberOfSeasons: animeData.seasons.count,
                                numberOfEpisodes: animeData.totalEpisodes,
                                episodeRunTime: detail.episodeRunTime,
                                inProduction: detail.inProduction,
                                languages: detail.languages,
                                originCountry: detail.originCountry,
                                type: detail.type,
                                seasons: aniSeasons,
                                contentRatings: detail.contentRatings,
                                externalIds: detail.externalIds
                            )
                            
                            self.tvShowDetail = detailWithAniSeasons
                            
                            var seasonTitles: [Int: String] = [:]
                            var allEpisodes: [AniListEpisode] = []
                            for season in animeData.seasons {
                                seasonTitles[season.seasonNumber] = season.title
                                allEpisodes.append(contentsOf: season.episodes)
                            }
                            self.animeSeasonTitles = seasonTitles
                            self.anilistEpisodes = allEpisodes
                            
                            if let firstSeason = aniSeasons.first {
                                self.selectedSeason = firstSeason
                            }
                        } else {
                            // Fallback to TMDB seasons
                            Logger.shared.log("MediaDetailView: animeData is nil — falling back to pure TMDB seasons (\(detail.seasons.count) seasons)", type: "AniList")
                            self.tvShowDetail = detail
                            if let firstSeason = detail.seasons.first(where: { $0.seasonNumber > 0 }) {
                                self.selectedSeason = firstSeason
                            }
                        }
                        
                        if let images, let logo = tmdbService.getBestLogo(from: images, preferredLanguage: selectedLanguage) {
                            self.logoURL = logo.fullURL
                        }
                        self.selectedEpisodeForSearch = nil
                        self.isLoading = false
                        self.hasLoadedContent = true
                        
                        // Store in view-level cache for instant back-navigation
                        MediaDetailCacheStore.shared.set(key: detailCacheKey, detail: .init(
                            movieDetail: nil,
                            tvShowDetail: self.tvShowDetail,
                            selectedSeason: self.selectedSeason,
                            synopsis: self.synopsis,
                            romajiTitle: self.romajiTitle,
                            logoURL: self.logoURL,
                            isAnimeShow: self.isAnimeShow,
                            anilistEpisodes: self.anilistEpisodes,
                            animeSeasonTitles: self.animeSeasonTitles,
                            castMembers: self.castMembers,
                            relatedMedia: self.relatedMedia,
                            timestamp: Date()
                        ))
                    }
                    Logger.shared.log("TV detail fetch complete: tmdbId=\(searchResult.id)", type: "CrashProbe")
                }
            } catch is CancellationError {
                Logger.shared.log("MediaDetail load cancelled: id=\(searchResult.id) type=\(searchResult.mediaType)", type: "CrashProbe")
            } catch {
                Logger.shared.log("MediaDetail load failed: id=\(searchResult.id) type=\(searchResult.mediaType) error=\(error.localizedDescription)", type: "CrashProbe")
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                    self.hasLoadedContent = true
                }
            }
        }
    }

}
