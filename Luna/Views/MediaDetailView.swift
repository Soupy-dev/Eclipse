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
        let animeSpecialEntries: [AniListSpecialSearchEntry]
        let castMembers: [TMDBCastMember]
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

    func updateSpecialEntries(key: String, entries: [AniListSpecialSearchEntry]) {
        lock.lock()
        defer { lock.unlock() }
        guard let existing = cache[key] else { return }
        cache[key] = CachedDetail(
            movieDetail: existing.movieDetail,
            tvShowDetail: existing.tvShowDetail,
            selectedSeason: existing.selectedSeason,
            synopsis: existing.synopsis,
            romajiTitle: existing.romajiTitle,
            logoURL: existing.logoURL,
            isAnimeShow: existing.isAnimeShow,
            anilistEpisodes: existing.anilistEpisodes,
            animeSeasonTitles: existing.animeSeasonTitles,
            animeSpecialEntries: entries,
            castMembers: existing.castMembers,
            timestamp: Date()
        )
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
    @State private var animeSpecialEntries: [AniListSpecialSearchEntry] = []
    @State private var isLoadingAnimeSpecials = false
    @State private var selectedSpecialEpisodeContext: SpecialEpisodeListContext?
    @State private var specialSearchRequest: AnimeSpecialSearchRequest?
    @State private var nextEpisodePresentationToken = 0
    @State private var playSheetRequestId = UUID()
    
    @State private var castMembers: [TMDBCastMember] = []
    @State private var hasLoadedContent = false
    @State private var detailLoadTask: Task<Void, Never>?
    @State private var specialsLoadTask: Task<Void, Never>?
    @State private var specialsLoadGeneration = 0
    
    @StateObject private var serviceManager = ServiceManager.shared
    @StateObject private var stremioManager = StremioAddonManager.shared
    @ObservedObject private var libraryManager = LibraryManager.shared
    
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage("tmdbLanguage") private var selectedLanguage = "en-US"
    private let nextEpisodeSheetPresentationDelay: TimeInterval = 1.2

    private var hasActiveSources: Bool {
        !serviceManager.activeServices.isEmpty || !stremioManager.activeAddons.isEmpty
    }

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
        } else if selectedSpecialEpisodeContext != nil, let selectedEpisode = selectedEpisodeForSearch {
            return "Play E\(selectedEpisode.episodeNumber)"
        } else if let selectedEpisode = selectedEpisodeForSearch {
            return "Play S\(selectedEpisode.seasonNumber)E\(selectedEpisode.episodeNumber)"
        } else {
            return "Play"
        }
    }
    
    var body: some View {
        let _ = Logger.shared.log("MediaDetailView body evaluate: id=\(searchResult.id) type=\(searchResult.mediaType) isLoading=\(isLoading) hasLoaded=\(hasLoadedContent) error=\(errorMessage != nil) movieDetail=\(movieDetail != nil) tvDetail=\(tvShowDetail != nil) selectedSeason=\(selectedSeason?.seasonNumber.description ?? "nil") seasonDetailEpisodes=\(seasonDetail?.episodes.count ?? 0) selectedEpisode=\(selectedEpisodeForSearch.map { "S\($0.seasonNumber)E\($0.episodeNumber)" } ?? "nil") sheets=play:\(showingSearchResults),download:\(showingDownloadSheet)", type: "CrashProbe")
        ZStack {
            LunaTheme.shared.backgroundBase
                .ignoresSafeArea(.all)
            
            Group {
                ambientColor
            }
            .ignoresSafeArea(.all)
            
            if isLoading {
                let _ = Logger.shared.log("MediaDetailView body branch loading: id=\(searchResult.id)", type: "CrashProbe")
                loadingView
            } else if let errorMessage = errorMessage {
                let _ = Logger.shared.log("MediaDetailView body branch error: id=\(searchResult.id) message=\(errorMessage)", type: "CrashProbe")
                errorView(errorMessage)
            } else {
                let _ = Logger.shared.log("MediaDetailView body branch content: id=\(searchResult.id) isMovie=\(searchResult.isMovie)", type: "CrashProbe")
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
            Logger.shared.log("MediaDetailView onAppear: id=\(searchResult.id) hasLoaded=\(hasLoadedContent) isLoading=\(isLoading) taskActive=\(detailLoadTask != nil)", type: "CrashProbe")
            if !hasLoadedContent {
                loadMediaDetails()
            } else {
                Logger.shared.log("MediaDetailView onAppear using existing loaded state: id=\(searchResult.id) tvSeasons=\(tvShowDetail?.seasons.count ?? 0) selectedSeason=\(selectedSeason?.seasonNumber.description ?? "nil")", type: "CrashProbe")
            }
            updateBookmarkStatus()
        }
        .onDisappear {
            if let detailLoadTask {
                Logger.shared.log("MediaDetail load task cancelled on disappear: id=\(searchResult.id)", type: "CrashProbe")
                detailLoadTask.cancel()
                self.detailLoadTask = nil
            } else {
                Logger.shared.log("MediaDetailView onDisappear: id=\(searchResult.id) no active load task", type: "CrashProbe")
            }
            if let specialsLoadTask {
                Logger.shared.log("MediaDetail specials load task cancelled on disappear: id=\(searchResult.id)", type: "CrashProbe")
                specialsLoadTask.cancel()
                self.specialsLoadTask = nil
            }
            specialsLoadGeneration += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestNextEpisode)) { notification in
            Logger.shared.log("MediaDetailView nextEpisode notification received: id=\(searchResult.id) userInfo=\(notification.userInfo ?? [:])", type: "CrashProbe")
            guard let userInfo = notification.userInfo,
                  let tmdbId = userInfo["tmdbId"] as? Int,
                  tmdbId == searchResult.id,
                  let seasonNumber = userInfo["seasonNumber"] as? Int,
                  let episodeNumber = userInfo["episodeNumber"] as? Int else {
                Logger.shared.log("MediaDetailView nextEpisode ignored: id=\(searchResult.id) did not match/parse", type: "CrashProbe")
                return
            }

            if let specialContext = selectedSpecialEpisodeContext,
               let nextSpecialEpisode = specialContext.episodes.first(where: { $0.seasonNumber == seasonNumber && $0.episodeNumber == episodeNumber }) {
                Logger.shared.log("MediaDetailView nextEpisode matched special: id=\(searchResult.id) S\(seasonNumber)E\(episodeNumber) delay=\(nextEpisodeSheetPresentationDelay)", type: "CrashProbe")
                selectedEpisodeForSearch = nextSpecialEpisode
                scheduleNextEpisodePresentation {
                    beginSpecialSearch(context: specialContext, episode: nextSpecialEpisode)
                }
                return
            }

            // Find the next episode in the current season detail
            if let episodes = seasonDetail?.episodes,
               let nextEp = episodes.first(where: { $0.seasonNumber == seasonNumber && $0.episodeNumber == episodeNumber }) {
                Logger.shared.log("MediaDetailView nextEpisode matched: id=\(searchResult.id) S\(seasonNumber)E\(episodeNumber) delay=\(nextEpisodeSheetPresentationDelay)", type: "CrashProbe")
                selectedEpisodeForSearch = nextEp
                showingSearchResults = false
                scheduleNextEpisodePresentation {
                    Logger.shared.log("MediaDetailView nextEpisode presenting search sheet: id=\(searchResult.id) S\(seasonNumber)E\(episodeNumber)", type: "CrashProbe")
                    playSheetRequestId = UUID()
                    showingSearchResults = true
                }
            } else {
                Logger.shared.log("NextEpisode: Could not find S\(seasonNumber)E\(episodeNumber) in loaded season detail for tmdbId=\(tmdbId) loadedEpisodes=\(seasonDetail?.episodes.count ?? 0)", type: "Player")
            }
        }
        .onChangeComp(of: libraryManager.collections) { _, _ in
            Logger.shared.log("MediaDetailView collections changed: id=\(searchResult.id)", type: "CrashProbe")
            updateBookmarkStatus()
        }
        .onChangeComp(of: isLoading) { _, newValue in
            Logger.shared.log("MediaDetailView isLoading changed: id=\(searchResult.id) isLoading=\(newValue)", type: "CrashProbe")
        }
        .onChangeComp(of: hasLoadedContent) { _, newValue in
            Logger.shared.log("MediaDetailView hasLoadedContent changed: id=\(searchResult.id) hasLoaded=\(newValue)", type: "CrashProbe")
        }
        .onChangeComp(of: selectedSeason?.seasonNumber) { _, newValue in
            Logger.shared.log("MediaDetailView selectedSeason changed: id=\(searchResult.id) season=\(newValue?.description ?? "nil")", type: "CrashProbe")
        }
        .onChangeComp(of: seasonDetail?.episodes.count) { _, newValue in
            Logger.shared.log("MediaDetailView seasonDetail episode count changed: id=\(searchResult.id) count=\(newValue?.description ?? "nil")", type: "CrashProbe")
        }
        .onChangeComp(of: selectedEpisodeForSearch?.id) { _, _ in
            Logger.shared.log("MediaDetailView selectedEpisode changed: id=\(searchResult.id) episode=\(selectedEpisodeForSearch.map { "S\($0.seasonNumber)E\($0.episodeNumber):id\($0.id)" } ?? "nil")", type: "CrashProbe")
        }
        .onChangeComp(of: showingSearchResults) { _, newValue in
            Logger.shared.log("MediaDetailView showingSearchResults changed: id=\(searchResult.id) visible=\(newValue) episode=\(selectedEpisodeForSearch.map { "S\($0.seasonNumber)E\($0.episodeNumber)" } ?? "nil")", type: "CrashProbe")
        }
        .onChangeComp(of: showingDownloadSheet) { _, newValue in
            Logger.shared.log("MediaDetailView showingDownloadSheet changed: id=\(searchResult.id) visible=\(newValue) episode=\(selectedEpisodeForSearch.map { "S\($0.seasonNumber)E\($0.episodeNumber)" } ?? "nil")", type: "CrashProbe")
        }
        .onDisappear {
            invalidatePendingNextEpisodePresentation()
        }
        .sheet(isPresented: $showingSearchResults) {
            let _ = Logger.shared.log("MediaDetailView constructing play sheet: id=\(searchResult.id) isAnime=\(isAnimeShow) selectedEpisode=\(selectedEpisodeForSearch.map { "S\($0.seasonNumber)E\($0.episodeNumber)" } ?? "nil") autoMode=\(UserDefaults.standard.bool(forKey: "servicesAutoModeEnabled"))", type: "CrashProbe")
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
                autoModeOnly: UserDefaults.standard.bool(forKey: "servicesAutoModeEnabled")
            )
            .id(playSheetRequestId)
        }
        .sheet(isPresented: $showingDownloadSheet) {
            let _ = Logger.shared.log("MediaDetailView constructing download sheet: id=\(searchResult.id) isAnime=\(isAnimeShow) selectedEpisode=\(selectedEpisodeForSearch.map { "S\($0.seasonNumber)E\($0.episodeNumber)" } ?? "nil") autoMode=\(UserDefaults.standard.bool(forKey: "servicesAutoModeEnabled"))", type: "CrashProbe")
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
                downloadMode: true,
                autoModeOnly: UserDefaults.standard.bool(forKey: "servicesAutoModeEnabled")
            )
        }
        .sheet(item: $specialSearchRequest) { request in
            ModulesSearchResultsSheet(
                mediaTitle: request.title,
                seasonTitleOverride: request.title,
                originalTitle: request.originalTitle,
                isMovie: false,
                isAnimeContent: true,
                selectedEpisode: request.episode,
                tmdbId: searchResult.id,
                animeSeasonTitle: request.title,
                posterPath: request.posterUrl ?? tvShowDetail?.posterPath,
                imdbId: request.imdbId ?? tvShowDetail?.externalIds?.imdbId,
                originalTMDBSeasonNumber: request.originalSeasonNumber,
                originalTMDBEpisodeNumber: request.originalEpisodeNumber,
                specialTitleOnlySearch: request.titleOnly,
                episodePlaybackContext: request.playbackContext,
                autoModeOnly: UserDefaults.standard.bool(forKey: "servicesAutoModeEnabled")
            )
        }
        .sheet(isPresented: $showingAddToCollection) {
            let _ = Logger.shared.log("MediaDetailView constructing add-to-collection sheet: id=\(searchResult.id)", type: "CrashProbe")
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
        let _ = Logger.shared.log("MediaDetailView construct mainScrollView: id=\(searchResult.id) isLoading=\(isLoading) hasLoaded=\(hasLoadedContent) isAnime=\(isAnimeShow) tvSeasons=\(tvShowDetail?.seasons.count ?? 0) selectedSeason=\(selectedSeason?.seasonNumber.description ?? "nil")", type: "CrashProbe")
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
        let _ = Logger.shared.log("MediaDetailView construct contentContainer: id=\(searchResult.id) movie=\(searchResult.isMovie) cast=\(castMembers.count)", type: "CrashProbe")
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
                    Image(systemName: hasActiveSources ? "play.fill" : "exclamationmark.triangle")
                    
                    Text(hasActiveSources ? playButtonText : "No Services")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .padding(.horizontal, 25)
                .applyLiquidGlassBackground(
                    cornerRadius: 12,
                    fallbackFill: hasActiveSources ? Color.black.opacity(0.2) : Color.gray.opacity(0.3),
                    fallbackMaterial: hasActiveSources ? .ultraThinMaterial : .thinMaterial,
                    glassTint: hasActiveSources ? nil : Color.gray.opacity(0.3)
                )
                .foregroundColor(hasActiveSources ? .white : .secondary)
                .cornerRadius(8)
            }
            .disabled(!hasActiveSources)
            
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
                .disabled(!hasActiveSources || isCurrentlyDownloading)
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
            let _ = Logger.shared.log("MediaDetailView construct episodesSection: tmdbId=\(searchResult.id) isAnime=\(isAnimeShow) tvSeasons=\(tvShowDetail?.seasons.count ?? 0) selectedSeason=\(selectedSeason?.seasonNumber.description ?? "nil") anilistEpisodes=\(anilistEpisodes?.count ?? 0)", type: "CrashProbe")
            TVShowSeasonsSection(
                tvShow: tvShowDetail,
                isAnime: isAnimeShow,
                selectedSeason: $selectedSeason,
                seasonDetail: $seasonDetail,
                selectedEpisodeForSearch: $selectedEpisodeForSearch,
                specialEpisodeContext: $selectedSpecialEpisodeContext,
                seasonSelectorInsertedContent: AnyView(specialsOVASection),
                animeEpisodes: anilistEpisodes,
                animeSeasonTitles: animeSeasonTitles,
                tmdbService: tmdbService
            ) {
                if !castMembers.isEmpty {
                    castSection
                }
                
                StarRatingView(mediaId: searchResult.id)
            }
            .onAppear {
                Logger.shared.log("MediaDetailView episodesSection appeared: tmdbId=\(searchResult.id) isAnime=\(isAnimeShow) tvSeasons=\(tvShowDetail?.seasons.count ?? 0) selectedSeason=\(selectedSeason?.seasonNumber.description ?? "nil") anilistEpisodes=\(anilistEpisodes?.count ?? 0)", type: "CrashProbe")
            }
        }
    }
    
    private func toggleBookmark() {
        Logger.shared.log("MediaDetailView toggleBookmark: id=\(searchResult.id) wasBookmarked=\(isBookmarked)", type: "CrashProbe")
        withAnimation(.easeInOut(duration: 0.2)) {
            libraryManager.toggleBookmark(for: searchResult)
            updateBookmarkStatus()
        }
        Logger.shared.log("MediaDetailView toggleBookmark complete: id=\(searchResult.id) isBookmarked=\(isBookmarked)", type: "CrashProbe")
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

    @ViewBuilder
    private var specialsOVASection: some View {
        if isAnimeShow && (isLoadingAnimeSpecials || !animeSpecialEntries.isEmpty) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("Specials & OVAs")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)

                    if isLoadingAnimeSpecials {
                        ProgressView()
                            .scaleEffect(0.75)
                    }

                    Spacer()
                }
                .padding(.horizontal)

                if !animeSpecialEntries.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(animeSpecialEntries) { entry in
                                specialEntryButton(entry)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func specialEntryButton(_ entry: AniListSpecialSearchEntry) -> some View {
        Button(action: {
            selectSpecialEntry(entry)
        }) {
            VStack(spacing: 8) {
                specialPoster(urlString: entry.posterUrl, fallbackText: entry.formatLabel)

                Text(entry.preferredTitle)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 84, height: 34)
                    .foregroundColor(selectedSpecialEpisodeContext?.id == entry.id ? .accentColor : .white)

                Text(entry.episodeCount == 1 ? entry.formatLabel : "\(entry.formatLabel) - \(entry.episodeCount) eps")
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundColor(.white.opacity(0.65))
                    .frame(width: 84)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }

    @ViewBuilder
    private func specialPoster(urlString: String?, fallbackText: String) -> some View {
        if let urlString, let url = URL(string: urlString) {
            KFImage(url)
                .placeholder {
                    specialPosterPlaceholder(fallbackText)
                }
                .resizable()
                .aspectRatio(2/3, contentMode: .fill)
                .frame(width: 80, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            specialPosterPlaceholder(fallbackText)
        }
    }

    private func specialPosterPlaceholder(_ fallbackText: String) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.white.opacity(0.08))
            .frame(width: 80, height: 120)
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.title2)
                    Text(fallbackText)
                        .font(.caption2)
                        .fontWeight(.bold)
                        .lineLimit(1)
                }
                .foregroundColor(.white.opacity(0.7))
            )
    }

    private func startAnimeSpecialsLoad(tmdbShowId: Int, fallbackPosterURL: String?) {
        guard isAnimeShow, !searchResult.isMovie else {
            animeSpecialEntries = []
            isLoadingAnimeSpecials = false
            selectedSpecialEpisodeContext = nil
            return
        }

        specialsLoadTask?.cancel()
        specialsLoadGeneration += 1
        let generation = specialsLoadGeneration
        if animeSpecialEntries.isEmpty {
            isLoadingAnimeSpecials = true
        }
        selectedSpecialEpisodeContext = nil

        specialsLoadTask = Task {
            let entries = await AniListService.shared.fetchSpecialSearchEntries(
                tmdbShowId: tmdbShowId,
                fallbackPosterURL: fallbackPosterURL,
                tmdbService: tmdbService
            )

            await MainActor.run {
                guard !Task.isCancelled,
                      generation == self.specialsLoadGeneration,
                      self.searchResult.id == tmdbShowId else { return }
                self.animeSpecialEntries = entries
                if let selected = self.selectedSpecialEpisodeContext, !entries.contains(where: { $0.id == selected.id }) {
                    self.selectedSpecialEpisodeContext = nil
                }
                self.isLoadingAnimeSpecials = false
                self.specialsLoadTask = nil
                if !entries.isEmpty {
                    MediaDetailCacheStore.shared.updateSpecialEntries(
                        key: self.searchResult.stableIdentity,
                        entries: entries
                    )
                }
                Logger.shared.log("MediaDetailView loaded specials: tmdbId=\(tmdbShowId) count=\(entries.count)", type: "AniList")
            }
        }
    }

    private func selectSpecialEntry(_ entry: AniListSpecialSearchEntry) {
        guard let context = SpecialEpisodeListContext(entry: entry, tmdbShowId: searchResult.id) else {
            return
        }
        selectedSpecialEpisodeContext = context
        selectedEpisodeForSearch = context.episodes.first
        TrackerManager.shared.cacheAniListSeasonId(
            tmdbId: searchResult.id,
            seasonNumber: context.localSeasonNumber,
            anilistId: context.anilistId
        )
    }

    private func beginSpecialSearch(context: SpecialEpisodeListContext, episode: TMDBEpisode?) {
        guard hasActiveSources else { return }

        let playbackContext = episode.map { context.playbackContext(for: $0) }
        specialSearchRequest = AnimeSpecialSearchRequest(
            title: context.title,
            originalTitle: context.alternateTitle,
            episode: episode,
            originalSeasonNumber: playbackContext?.resolvedTMDBSeasonNumber,
            originalEpisodeNumber: playbackContext?.resolvedTMDBEpisodeNumber,
            imdbId: context.imdbId,
            posterUrl: context.posterUrl,
            titleOnly: playbackContext?.titleOnlySearch ?? true,
            playbackContext: playbackContext
        )
    }

    private func scheduleNextEpisodePresentation(action: @escaping () -> Void) {
        nextEpisodePresentationToken += 1
        let token = nextEpisodePresentationToken

        DispatchQueue.main.asyncAfter(deadline: .now() + nextEpisodeSheetPresentationDelay) {
            guard token == nextEpisodePresentationToken else { return }
            action()
        }
    }

    private func invalidatePendingNextEpisodePresentation() {
        nextEpisodePresentationToken += 1
    }
    
    private func updateBookmarkStatus() {
        isBookmarked = libraryManager.isBookmarked(searchResult)
        Logger.shared.log("MediaDetailView updateBookmarkStatus: id=\(searchResult.id) isBookmarked=\(isBookmarked)", type: "CrashProbe")
    }
    
    private func searchInServices() {
        Logger.shared.log("MediaDetailView searchInServices begin: id=\(searchResult.id) isMovie=\(searchResult.isMovie) hasActiveSources=\(hasActiveSources) selectedEpisodeBefore=\(selectedEpisodeForSearch.map { "S\($0.seasonNumber)E\($0.episodeNumber)" } ?? "nil") seasonDetailEpisodes=\(seasonDetail?.episodes.count ?? 0)", type: "CrashProbe")
        // This function will only be called when services are available
        // since the button is disabled when no services are active
        
        if !searchResult.isMovie {
            if let specialContext = selectedSpecialEpisodeContext {
                let episode = selectedEpisodeForSearch.flatMap { selected in
                    specialContext.episodes.first(where: { $0.id == selected.id })
                } ?? specialContext.episodes.first
                selectedEpisodeForSearch = episode
                beginSpecialSearch(context: specialContext, episode: episode)
                return
            }

            if selectedEpisodeForSearch != nil {
                Logger.shared.log("MediaDetailView searchInServices keeping selected episode: id=\(searchResult.id) episode=\(selectedEpisodeForSearch.map { "S\($0.seasonNumber)E\($0.episodeNumber)" } ?? "nil")", type: "CrashProbe")
            } else if let seasonDetail = seasonDetail, !seasonDetail.episodes.isEmpty {
                selectedEpisodeForSearch = seasonDetail.episodes.first
                Logger.shared.log("MediaDetailView searchInServices defaulted first episode: id=\(searchResult.id) episode=\(selectedEpisodeForSearch.map { "S\($0.seasonNumber)E\($0.episodeNumber)" } ?? "nil")", type: "CrashProbe")
            } else {
                selectedEpisodeForSearch = nil
                Logger.shared.log("MediaDetailView searchInServices no episode available: id=\(searchResult.id)", type: "CrashProbe")
            }
        } else {
            selectedEpisodeForSearch = nil
            Logger.shared.log("MediaDetailView searchInServices movie selected: id=\(searchResult.id)", type: "CrashProbe")
        }
        
        Logger.shared.log("MediaDetailView searchInServices presenting: id=\(searchResult.id) selectedEpisode=\(selectedEpisodeForSearch.map { "S\($0.seasonNumber)E\($0.episodeNumber)" } ?? "nil")", type: "CrashProbe")
        playSheetRequestId = UUID()
        showingSearchResults = true
    }
    
    private func downloadInServices() {
        Logger.shared.log("MediaDetailView downloadInServices begin: id=\(searchResult.id) isMovie=\(searchResult.isMovie) hasActiveSources=\(hasActiveSources) selectedEpisodeBefore=\(selectedEpisodeForSearch.map { "S\($0.seasonNumber)E\($0.episodeNumber)" } ?? "nil") seasonDetailEpisodes=\(seasonDetail?.episodes.count ?? 0)", type: "CrashProbe")
        if !searchResult.isMovie {
            if selectedEpisodeForSearch != nil {
                Logger.shared.log("MediaDetailView downloadInServices keeping selected episode: id=\(searchResult.id) episode=\(selectedEpisodeForSearch.map { "S\($0.seasonNumber)E\($0.episodeNumber)" } ?? "nil")", type: "CrashProbe")
            } else if let seasonDetail = seasonDetail, !seasonDetail.episodes.isEmpty {
                selectedEpisodeForSearch = seasonDetail.episodes.first
                Logger.shared.log("MediaDetailView downloadInServices defaulted first episode: id=\(searchResult.id) episode=\(selectedEpisodeForSearch.map { "S\($0.seasonNumber)E\($0.episodeNumber)" } ?? "nil")", type: "CrashProbe")
            } else {
                selectedEpisodeForSearch = nil
                Logger.shared.log("MediaDetailView downloadInServices no episode available: id=\(searchResult.id)", type: "CrashProbe")
            }
        } else {
            selectedEpisodeForSearch = nil
            Logger.shared.log("MediaDetailView downloadInServices movie selected: id=\(searchResult.id)", type: "CrashProbe")
        }
        
        Logger.shared.log("MediaDetailView downloadInServices presenting: id=\(searchResult.id) selectedEpisode=\(selectedEpisodeForSearch.map { "S\($0.seasonNumber)E\($0.episodeNumber)" } ?? "nil")", type: "CrashProbe")
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
        if let specialsLoadTask {
            Logger.shared.log("MediaDetail cancelling stale specials task before reload: id=\(searchResult.id)", type: "CrashProbe")
            specialsLoadTask.cancel()
            self.specialsLoadTask = nil
        }
        specialsLoadGeneration += 1
        let detailCacheKey = searchResult.stableIdentity
        Logger.shared.log("MediaDetail load start: id=\(searchResult.id) type=\(searchResult.mediaType) title=\(searchResult.displayTitle)", type: "CrashProbe")
        Logger.shared.log("MediaDetail cache lookup begin: key=\(detailCacheKey)", type: "CrashProbe")

        // Check view-level cache first for instant back-navigation
        if let cached = MediaDetailCacheStore.shared.get(key: detailCacheKey) {
            Logger.shared.log("MediaDetail cache hit: key=\(detailCacheKey) type=\(searchResult.mediaType)", type: "CrashProbe")
            // Defer state update to next run loop tick so SwiftUI properly re-renders
            Task { @MainActor in
                Logger.shared.log("MediaDetail cache apply begin: key=\(detailCacheKey) movie=\(cached.movieDetail != nil) tv=\(cached.tvShowDetail != nil) cachedSeasons=\(cached.tvShowDetail?.seasons.count ?? 0) cachedEpisodes=\(cached.anilistEpisodes?.count ?? 0)", type: "CrashProbe")
                self.movieDetail = cached.movieDetail
                self.tvShowDetail = cached.tvShowDetail
                self.selectedSeason = cached.selectedSeason
                self.seasonDetail = nil
                self.synopsis = cached.synopsis
                self.romajiTitle = cached.romajiTitle
                self.logoURL = cached.logoURL
                self.isAnimeShow = cached.isAnimeShow
                self.anilistEpisodes = cached.anilistEpisodes
                self.animeSeasonTitles = cached.animeSeasonTitles
                self.animeSpecialEntries = cached.animeSpecialEntries
                self.selectedEpisodeForSearch = nil
                self.castMembers = cached.castMembers
                self.selectedSpecialEpisodeContext = nil
                self.isLoading = false
                self.hasLoadedContent = true
                Logger.shared.log("MediaDetail cache state applied: key=\(detailCacheKey) tvSeasons=\(cached.tvShowDetail?.seasons.count ?? 0) selectedSeason=\(cached.selectedSeason?.seasonNumber.description ?? "nil") anilistEpisodes=\(cached.anilistEpisodes?.count ?? 0)", type: "CrashProbe")
                if cached.isAnimeShow, !self.searchResult.isMovie, cached.animeSpecialEntries.isEmpty {
                    self.startAnimeSpecialsLoad(
                        tmdbShowId: self.searchResult.id,
                        fallbackPosterURL: cached.tvShowDetail?.fullPosterURL
                    )
                } else {
                    self.isLoadingAnimeSpecials = false
                }
            }
            return
        }
        Logger.shared.log("MediaDetail cache miss: key=\(detailCacheKey)", type: "CrashProbe")

        isLoading = true
        errorMessage = nil
        seasonDetail = nil
        selectedEpisodeForSearch = nil
        animeSpecialEntries = []
        isLoadingAnimeSpecials = false
        selectedSpecialEpisodeContext = nil
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

                    Logger.shared.log("Movie detail fetch complete: tmdbId=\(searchResult.id) cast=\(credits?.cast.count ?? 0)", type: "CrashProbe")
                    
                    if Task.isCancelled { return }
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        Logger.shared.log("Movie detail apply state begin: tmdbId=\(searchResult.id)", type: "CrashProbe")
                        self.movieDetail = detail
                        self.synopsis = detail.overview ?? ""
                        self.romajiTitle = romaji
                        if let logo = tmdbService.getBestLogo(from: images, preferredLanguage: selectedLanguage) {
                            self.logoURL = logo.fullURL
                        }
                        self.castMembers = credits?.cast ?? []
                        self.animeSpecialEntries = []
                        self.isLoadingAnimeSpecials = false
                        self.selectedSpecialEpisodeContext = nil
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
                            animeSpecialEntries: [],
                            castMembers: self.castMembers,
                            timestamp: Date()
                        ))
                        Logger.shared.log("Movie detail apply state complete: tmdbId=\(searchResult.id) cast=\(self.castMembers.count) logo=\(self.logoURL != nil)", type: "CrashProbe")
                    }
                } else {
                    Logger.shared.log("TV detail fetch begin: tmdbId=\(searchResult.id)", type: "CrashProbe")
                    Logger.shared.log("TV detail step: queue getTVShowWithSeasons id=\(searchResult.id)", type: "CrashProbe")
                    Logger.shared.log("TV detail step: queue getTVShowImages id=\(searchResult.id)", type: "CrashProbe")
                    Logger.shared.log("TV detail step: queue getRomajiTitle id=\(searchResult.id)", type: "CrashProbe")
                    Logger.shared.log("TV detail step: queue getTVCredits id=\(searchResult.id)", type: "CrashProbe")
                    async let detailTask = tmdbService.getTVShowWithSeasons(id: searchResult.id)
                    async let imagesTask = tmdbService.getTVShowImages(id: searchResult.id, preferredLanguage: selectedLanguage)
                    async let romajiTask = tmdbService.getRomajiTitle(for: "tv", id: searchResult.id)
                    async let creditsTask = tmdbService.getTVCredits(id: searchResult.id)

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
                        Logger.shared.log("TV detail apply state on main begin: tmdbId=\(searchResult.id) detectedAsAnime=\(detectedAsAnime) animeData=\(animeData != nil) tmdbSeasons=\(detail.seasons.count)", type: "CrashProbe")
                        self.synopsis = detail.overview ?? ""
                        self.romajiTitle = romaji
                        self.isAnimeShow = detectedAsAnime
                        self.castMembers = credits?.cast ?? []
                        
                        if let animeData = animeData {
                            Logger.shared.log("MediaDetailView: Using AniList structure — \(animeData.seasons.count) seasons", type: "AniList")
                            // Build AniList seasons list with TMDB-compatible fields
                            let aniSeasons: [TMDBSeason] = animeData.seasons.map { aniSeason in
                                Logger.shared.log("MediaDetailView: converting AniList season tmdbId=\(detail.id) anilistId=\(aniSeason.anilistId) season=\(aniSeason.seasonNumber) title=\(aniSeason.title) episodes=\(aniSeason.episodes.count) poster=\(aniSeason.posterUrl != nil)", type: "CrashProbe")
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
                            Logger.shared.log("MediaDetailView: assigned detailWithAniSeasons tmdbId=\(detail.id) seasons=\(detailWithAniSeasons.seasons.count) totalEpisodes=\(detailWithAniSeasons.numberOfEpisodes ?? 0)", type: "CrashProbe")
                            
                            var seasonTitles: [Int: String] = [:]
                            var allEpisodes: [AniListEpisode] = []
                            for season in animeData.seasons {
                                Logger.shared.log("MediaDetailView: flatten AniList season tmdbId=\(detail.id) season=\(season.seasonNumber) title=\(season.title) episodes=\(season.episodes.count)", type: "CrashProbe")
                                seasonTitles[season.seasonNumber] = season.title
                                allEpisodes.append(contentsOf: season.episodes)
                            }
                            Logger.shared.log("MediaDetailView: AniList season conversion complete tmdbId=\(detail.id) aniSeasons=\(aniSeasons.count) summary=\(aniSeasons.prefix(8).map { "s\($0.seasonNumber):id\($0.id):eps\($0.episodeCount)" }.joined(separator: "|"))", type: "CrashProbe")
                            Logger.shared.log("MediaDetailView: anime state preassign tmdbId=\(detail.id) aniSeasons=\(aniSeasons.count) allEpisodes=\(allEpisodes.count) seasonTitles=\(seasonTitles.count)", type: "CrashProbe")
                            self.animeSeasonTitles = seasonTitles
                            self.anilistEpisodes = allEpisodes
                            
                            if let firstSeason = aniSeasons.first {
                                self.selectedSeason = firstSeason
                                Logger.shared.log("MediaDetailView: selected first AniList season tmdbId=\(detail.id) season=\(firstSeason.seasonNumber) episodeCount=\(firstSeason.episodeCount)", type: "CrashProbe")
                            } else {
                                self.selectedSeason = nil
                                Logger.shared.log("MediaDetailView: AniList data had no seasons to select tmdbId=\(detail.id)", type: "CrashProbe")
                            }
                        } else {
                            // Fallback to TMDB seasons
                            Logger.shared.log("MediaDetailView: animeData is nil — falling back to pure TMDB seasons (\(detail.seasons.count) seasons)", type: "AniList")
                            self.tvShowDetail = detail
                            self.anilistEpisodes = nil
                            self.animeSeasonTitles = nil
                            if let firstSeason = detail.seasons.first(where: { $0.seasonNumber > 0 }) {
                                self.selectedSeason = firstSeason
                                Logger.shared.log("MediaDetailView: selected first TMDB season tmdbId=\(detail.id) season=\(firstSeason.seasonNumber) episodeCount=\(firstSeason.episodeCount)", type: "CrashProbe")
                            } else {
                                self.selectedSeason = nil
                                Logger.shared.log("MediaDetailView: TMDB detail had no positive seasons tmdbId=\(detail.id) seasons=\(detail.seasons.count)", type: "CrashProbe")
                            }
                        }
                        
                        if let images, let logo = tmdbService.getBestLogo(from: images, preferredLanguage: selectedLanguage) {
                            self.logoURL = logo.fullURL
                            Logger.shared.log("MediaDetailView: assigned logo tmdbId=\(detail.id) hasLogo=true", type: "CrashProbe")
                        } else {
                            Logger.shared.log("MediaDetailView: assigned logo tmdbId=\(detail.id) hasLogo=false", type: "CrashProbe")
                        }
                        self.selectedEpisodeForSearch = nil
                        self.isLoading = false
                        self.hasLoadedContent = true
                        Logger.shared.log("MediaDetailView: state applied tmdbId=\(searchResult.id) isAnime=\(self.isAnimeShow) tvSeasons=\(self.tvShowDetail?.seasons.count ?? 0) selectedSeason=\(self.selectedSeason?.seasonNumber.description ?? "nil") anilistEpisodes=\(self.anilistEpisodes?.count ?? 0) hasLoaded=\(self.hasLoadedContent)", type: "CrashProbe")
                        
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
                            animeSpecialEntries: self.animeSpecialEntries,
                            castMembers: self.castMembers,
                            timestamp: Date()
                        ))
                        Logger.shared.log("MediaDetailView: cache stored key=\(detailCacheKey) selectedSeason=\(self.selectedSeason?.seasonNumber.description ?? "nil")", type: "CrashProbe")
                        if detectedAsAnime {
                            self.startAnimeSpecialsLoad(tmdbShowId: detail.id, fallbackPosterURL: detail.fullPosterURL)
                        } else {
                            self.animeSpecialEntries = []
                            self.isLoadingAnimeSpecials = false
                            self.selectedSpecialEpisodeContext = nil
                        }
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

struct SpecialEpisodeListContext: Identifiable {
    let id: Int
    let anilistId: Int
    let title: String
    let alternateTitle: String?
    let formatLabel: String
    let posterUrl: String?
    let localSeasonNumber: Int
    let mappedSeasonNumber: Int?
    let episodeOffset: Int?
    let imdbId: String?
    let episodes: [TMDBEpisode]

    init?(entry: AniListSpecialSearchEntry, tmdbShowId: Int) {
        let localSeasonNumber = 100_000 + entry.id
        let title = entry.preferredTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        self.id = entry.id
        self.anilistId = entry.id
        self.title = title
        self.alternateTitle = entry.alternateSearchTitle
        self.formatLabel = entry.formatLabel
        self.posterUrl = entry.posterUrl
        self.localSeasonNumber = localSeasonNumber
        self.mappedSeasonNumber = entry.tmdbSeasonNumber
        self.episodeOffset = entry.episodeOffset ?? 0
        self.imdbId = entry.imdbId

        let count = max(1, entry.episodeCount)
        self.episodes = (1...count).map { episodeNumber in
            let sourceEpisode = entry.episodes.first(where: { $0.number == episodeNumber })
            let resolvedEpisodeTitle: String
            if count == 1 {
                resolvedEpisodeTitle = title
            } else if let sourceTitle = sourceEpisode?.title.trimmingCharacters(in: .whitespacesAndNewlines),
                      !sourceTitle.isEmpty {
                resolvedEpisodeTitle = sourceTitle
            } else {
                resolvedEpisodeTitle = "Episode \(episodeNumber)"
            }
            return TMDBEpisode(
                id: tmdbShowId * 1_000_000 + entry.id * 100 + episodeNumber,
                name: resolvedEpisodeTitle,
                overview: sourceEpisode?.description,
                stillPath: sourceEpisode?.stillPath,
                episodeNumber: episodeNumber,
                seasonNumber: localSeasonNumber,
                airDate: sourceEpisode?.airDate,
                runtime: sourceEpisode?.runtime,
                voteAverage: 0,
                voteCount: 0
            )
        }
    }

    var seasonDetail: TMDBSeasonDetail {
        TMDBSeasonDetail(
            id: id,
            name: title,
            overview: "",
            posterPath: posterUrl,
            seasonNumber: localSeasonNumber,
            airDate: nil,
            episodes: episodes
        )
    }

    func playbackContext(for episode: TMDBEpisode) -> EpisodePlaybackContext {
        EpisodePlaybackContext(
            localSeasonNumber: localSeasonNumber,
            localEpisodeNumber: episode.episodeNumber,
            anilistMediaId: anilistId,
            tmdbSeasonNumber: mappedSeasonNumber,
            tmdbEpisodeNumber: mappedSeasonNumber == nil ? nil : (episodeOffset ?? 0) + episode.episodeNumber,
            tmdbEpisodeOffset: episodeOffset,
            isSpecial: true,
            titleOnlySearch: episodes.count == 1
        )
    }
}

private struct AnimeSpecialSearchRequest: Identifiable {
    let id = UUID()
    let title: String
    let originalTitle: String?
    let episode: TMDBEpisode?
    let originalSeasonNumber: Int?
    let originalEpisodeNumber: Int?
    let imdbId: String?
    let posterUrl: String?
    let titleOnly: Bool
    let playbackContext: EpisodePlaybackContext?
}
