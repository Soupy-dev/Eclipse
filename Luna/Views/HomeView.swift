//
//  HomeView.swift
//  Sora

import SwiftUI
import Kingfisher

struct HomeView: View {
    @State private var showingSettings = false
    @State private var isHoveringWatchNow = false
    @State private var isHoveringWatchlist = false
    @State private var continueWatchingItems: [ContinueWatchingItem] = []
    
    @AppStorage("tmdbLanguage") private var selectedLanguage = "en-US"
    
    @StateObject private var homeViewModel = HomeViewModel()
    @ObservedObject private var catalogManager = CatalogManager.shared
    @StateObject private var tmdbService = TMDBService.shared
    @StateObject private var contentFilter = TMDBContentFilter.shared
    
    private var enabledCatalogs: [Catalog] {
        return catalogManager.getEnabledCatalogs()
    }
    
    private var heroHeight: CGFloat {
#if os(tvOS)
        UIScreen.main.bounds.height * 0.8
#else
        isIPad ? 720 : 580
#endif
    }

    private var ambientColor: Color { homeViewModel.ambientColor }
    
    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack {
                homeContent
            }
        } else {
            NavigationView {
                homeContent
            }
            .navigationViewStyle(StackNavigationViewStyle())
        }
    }
    
    private var homeContent: some View {
        ZStack {
            GlobalGradientBackground()
                .ignoresSafeArea(.all)
            
            Group {
                homeViewModel.ambientColor
            }
            .ignoresSafeArea(.all)
            
            if homeViewModel.isLoading {
                loadingView
            } else if let errorMessage = homeViewModel.errorMessage {
                errorView(errorMessage)
            } else {
                mainScrollView
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            refreshContinueWatchingItems()
            if !homeViewModel.hasLoadedContent {
                homeViewModel.loadContent(tmdbService: tmdbService, catalogManager: catalogManager, contentFilter: contentFilter)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshContinueWatchingItems()
        }
        .onChangeComp(of: contentFilter.filterHorror) { _, _ in
            if homeViewModel.hasLoadedContent {
                homeViewModel.loadContent(tmdbService: tmdbService, catalogManager: catalogManager, contentFilter: contentFilter)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }
    
    @ViewBuilder
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading amazing content...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    @ViewBuilder
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 50))
                .foregroundColor(.orange)
            
            Text("Connection Error")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text(message)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Button("Retry") {
                loadContent()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .foregroundColor(.white)
            .cornerRadius(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    @ViewBuilder
    private var mainScrollView: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                heroSection
                continueWatchingSection
                contentSections
            }
        }
        .ignoresSafeArea(edges: [.top, .leading, .trailing])
    }

    @ViewBuilder
    private var continueWatchingSection: some View {
        if !continueWatchingItems.isEmpty {
            ContinueWatchingSection(
                items: continueWatchingItems,
                tmdbService: tmdbService,
                onDataChanged: refreshContinueWatchingItems
            )
        }
    }

    
    @ViewBuilder
    private var heroSection: some View {
        ZStack(alignment: .bottom) {
            StretchyHeaderView(
                backdropURL: homeViewModel.heroContent?.fullBackdropURL ?? homeViewModel.heroContent?.fullPosterURL,
                isMovie: homeViewModel.heroContent?.mediaType == "movie",
                headerHeight: heroHeight,
                minHeaderHeight: 300,
                onAmbientColorExtracted: { color in
                    homeViewModel.ambientColor = color
                }
            )
            
            heroGradientOverlay
            heroContentInfo
        }
    }
    
    @ViewBuilder
    private var heroGradientOverlay: some View {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: ambientColor.opacity(0.0), location: 0.0),
                .init(color: ambientColor.opacity(0.4), location: 0.2),
                .init(color: ambientColor.opacity(0.7), location: 0.6),
                .init(color: ambientColor.opacity(1), location: 1.0)
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 0))
    }
    
    @ViewBuilder
    private var heroContentInfo: some View {
        if let hero = homeViewModel.heroContent {
            VStack(alignment: .center, spacing: isTvOS ? 30 : 12) {
                HStack {
                    Text(hero.isMovie ? "Movie" : "TV Series")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, isTvOS ? 16 : 8)
                        .padding(.vertical, isTvOS ? 10 : 4)
                        .applyLiquidGlassBackground(cornerRadius: 12)
                    
                    if (hero.voteAverage ?? 0.0) > 0 {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Image(systemName: "star.fill")
                                .foregroundColor(.yellow)
                            
                            Text(String(format: "%.1f", hero.voteAverage ?? 0.0))
                                .fontWeight(.medium)
                                .foregroundColor(.white)
                        }
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, isTvOS ? 16 : 8)
                        .padding(.vertical, isTvOS ? 10 : 4)
                        .applyLiquidGlassBackground(cornerRadius: 12)
                    }
                }
                
                heroTitleText(hero)
                
                if let overview = hero.overview, !overview.isEmpty {
                    Text(String(overview.prefix(100)) + (overview.count > 100 ? "..." : ""))
                        .font(.system(size: isTvOS ? 30 : 15))
                        .shadow(color: .black.opacity(0.6), radius: 8, x: 0, y: 4)
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
                
                HStack(spacing: 16) {
                    NavigationLink(destination: MediaDetailView(searchResult: hero)) {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                                .font(.subheadline)
                            Text("Watch Now")
                                .fontWeight(.semibold)
                                .fixedSize()
                                .lineLimit(1)
                        }
                        .foregroundColor(isHoveringWatchNow ? .black : .white)
                        .tvos({ view in
                            view.frame(width: 200, height: 60)
                                .buttonStyle(PlainButtonStyle())
#if os(tvOS)
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(_): isHoveringWatchNow = true
                                    case .ended: isHoveringWatchNow = false
                                    }
                                }
#endif
                        }, else: { view in
                            view
                                .frame(width: 140, height: 42)
                                .buttonStyle(PlainButtonStyle())
                                .applyLiquidGlassBackground(cornerRadius: 12)
                        })
                    }
                    
                    Button(action: {
                        // TODO: Add to watchlist
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.subheadline)
                            Text("Watchlist")
                                .fontWeight(.semibold)
                                .fixedSize()
                                .lineLimit(1)
                        }
                        .foregroundColor(isHoveringWatchlist ? .black : .white)
                        .tvos({ view in
                            view.frame(width: 200, height: 60)
                                .buttonStyle(PlainButtonStyle())
#if os(tvOS)
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(_): isHoveringWatchlist = true
                                    case .ended: isHoveringWatchlist = false
                                    }
                                }
#endif
                        }, else: { view in
                            view.frame(width: 140, height: 42)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.black.opacity(0.3))
                                        .background(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(.white.opacity(0.3), lineWidth: 1)
                                        )
                                )
                        })
                        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
        }
    }
    
    @ViewBuilder
    private func heroTitleText(_ hero: TMDBSearchResult) -> some View {
        Text(hero.displayTitle)
            .font(.system(size: isTvOS ? 40 : 25))
            .fontWeight(.bold)
            .shadow(color: .black.opacity(0.6), radius: 8, x: 0, y: 4)
            .foregroundColor(.white)
            .lineLimit(2)
            .multilineTextAlignment(.center)
    }
    
    @ViewBuilder
    private var contentSections: some View {
        VStack(spacing: 0) {
            let catalogs = enabledCatalogs.filter { catalog in
                if let items = homeViewModel.catalogResults[catalog.id], !items.isEmpty {
                    return true
                }
                return false
            }
            
            ForEach(Array(catalogs.enumerated()), id: \.element.id) { index, catalog in
                if let items = homeViewModel.catalogResults[catalog.id], !items.isEmpty {
                    let limitedItems = Array(items.prefix(15))
                    let displayItems = catalog.id == "trending"
                        ? limitedItems.filter { $0.id != homeViewModel.heroContent?.id }
                        : limitedItems
                    
                    MediaSection(
                        title: catalog.name,
                        items: displayItems
                    )
                    
                    if index < catalogs.count - 1 {
                        SectionDivider()
                    }
                }
            }
            
            Spacer(minLength: 50)
        }
        .background(
            LinearGradient(
                colors: [ambientColor, LunaTheme.shared.globalGradientEnabled ? LunaTheme.shared.globalGradientColor.opacity(0.15) : Color.clear, LunaTheme.shared.backgroundBase],
                startPoint: .top,
                endPoint: UnitPoint(x: 0.5, y: 0.3)
            )
        )
    }
    
    private func loadContent() {
        homeViewModel.loadContent(
            tmdbService: tmdbService,
            catalogManager: catalogManager,
            contentFilter: contentFilter
        )
    }

    private func refreshContinueWatchingItems() {
        continueWatchingItems = ProgressManager.shared.getContinueWatchingItems()
    }

}

struct MediaSection: View {
    let title: String
    let items: [TMDBSearchResult]
    
    var gap: Double { isTvOS ? 50.0 : (isIPad ? 28.0 : 20.0) }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title)
                    .font(isTvOS ? .headline : .title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal, isTvOS ? 40 : 16)
            
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: gap) {
                    ForEach(items) { item in
                        MediaCard(result: item)
                    }
                }
                .padding(.horizontal, isTvOS ? 40 : 16)
            }
            .modifier(ScrollClipModifier())
            .buttonStyle(.borderless)
        }
        .padding(.top, isTvOS ? 40 : 24)
        .opacity(items.isEmpty ? 0 : 1)
    }
}

struct ScrollClipModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.scrollClipDisabled()
        } else {
            content
        }
    }
}

struct SectionDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            line
            Image(systemName: "sparkle")
                .font(.system(size: 8))
                .foregroundColor(.white.opacity(0.2))
            line
        }
        .padding(.horizontal, 60)
        .padding(.top, 28)
        .padding(.bottom, 4)
    }
    
    private var line: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear, .white.opacity(0.12), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 0.5)
    }
}

struct MediaCard: View {
    let result: TMDBSearchResult
    @State private var isHovering: Bool = false
    @Environment(\.heroNamespace) private var heroNamespace
    
    var body: some View {
        NavigationLink(destination: MediaDetailView(searchResult: result)
            .heroDestination(id: "media-\(result.id)", namespace: heroNamespace)
        ) {
            VStack(alignment: .leading, spacing: 6) {
                KFImage(URL(string: result.fullPosterURL ?? ""))
                    .placeholder {
                        FallbackImageView(
                            isMovie: result.isMovie,
                            size: CGSize(width: 120, height: 180)
                        )
                    }
                    .resizable()
                    .aspectRatio(2/3, contentMode: .fill)
                    .tvos({ view in
                        view
                            .frame(width: 280, height: 380)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .hoverEffect(.highlight)
                            .modifier(ContinuousHoverModifier(isHovering: $isHovering))
                            .padding(.vertical, 30)
                    }, else: { view in
                        view
                            .frame(width: 120 * iPadScale, height: 180 * iPadScale)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
                    })
                    .heroSource(id: "media-\(result.id)", namespace: heroNamespace)
                
                VStack(alignment: .leading, spacing: isTvOS ? 10 : 3) {
                    Text(result.displayTitle)
                        .tvos({ view in
                            view
                                .foregroundColor(isHovering ? .white : .secondary)
                                .fontWeight(.semibold)
                        }, else: { view in
                            view
                                .foregroundColor(.white)
                                .fontWeight(.medium)
                        })
                        .font(.caption)
                        .lineLimit(1)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)

                    HStack(alignment: .center, spacing: isTvOS ? 18 : 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundColor(.yellow)
                            
                            Text(String(format: "%.1f", result.voteAverage ?? 0.0))
                                .font(.caption2)
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .fixedSize()
                        }
                            .padding(.horizontal, isTvOS ? 16 : 8)
                            .padding(.vertical, isTvOS ? 10 : 4)
                            .applyLiquidGlassBackground(cornerRadius: 12)

                        Spacer()

                        Text(result.isMovie ? "Movie" : "TV")
                            .font(.caption2)
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, isTvOS ? 16 : 8)
                            .padding(.vertical, isTvOS ? 10 : 4)
                            .applyLiquidGlassBackground(cornerRadius: 12)
                    }
                }
                .frame(width: isTvOS ? 280 : 120 * iPadScale, alignment: .leading)
            }
        }
        .tvos({ view in
            view.buttonStyle(BorderlessButtonStyle())
        }, else: { view in
            view.buttonStyle(PlainButtonStyle())
        })
    }
}

struct ContinueWatchingSection: View {
    let items: [ContinueWatchingItem]
    let tmdbService: TMDBService
    let onDataChanged: () -> Void

    private var gap: Double { isTvOS ? 50.0 : (isIPad ? 24.0 : 16.0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Continue Watching")
                    .font(isTvOS ? .headline : .title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                Spacer()
            }
            .padding(.horizontal, isTvOS ? 40 : 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: gap) {
                    ForEach(items) { item in
                        ContinueWatchingCard(item: item, tmdbService: tmdbService, onDataChanged: onDataChanged)
                    }
                }
                .padding(.horizontal, isTvOS ? 40 : 16)
            }
            .modifier(ScrollClipModifier())
            .buttonStyle(.borderless)
        }
        .padding(.top, isTvOS ? 40 : 24)
    }
}

struct ContinueWatchingCard: View {
    let item: ContinueWatchingItem
    let tmdbService: TMDBService
    let onDataChanged: () -> Void

    @AppStorage("tmdbLanguage") private var selectedLanguage = "en-US"

    @State private var backdropURL: String?
    @State private var logoURL: String?
    @State private var title: String = ""
    @State private var isHovering = false
    @State private var isLoaded = false
    @State private var showingSearchResults = false
    @State private var showingDetails = false

    // Anime metadata resolved from TMDB + AniList (mirrors MediaDetailView logic)
    @State private var isAnimeContent = false
    @State private var animeSeasonTitle: String? = nil
    @State private var originalTitle: String? = nil
    @State private var isMetadataReady = false
    @State private var pendingOpenSheet = false
    @State private var imdbId: String? = nil

    private var cardWidth: CGFloat { isTvOS ? 380 : (isIPad ? 360 : 260) }
    private var cardHeight: CGFloat { isTvOS ? 220 : (isIPad ? 200 : 146) }
    private var logoMaxWidth: CGFloat { isTvOS ? 200 : (isIPad ? 180 : 140) }
    private var logoMaxHeight: CGFloat { isTvOS ? 60 : (isIPad ? 52 : 40) }

    private var displayTitle: String {
        title.isEmpty ? item.title : title
    }

    /// Title to pass to the search sheet – uses the AniList season title for anime, matching MediaDetailView's logic
    private var searchSheetTitle: String {
        if isAnimeContent, !item.isMovie,
           let seasonTitle = animeSeasonTitle {
            return seasonTitle
        }
        return displayTitle
    }

    private var selectedEpisodeForSearch: TMDBEpisode? {
        guard !item.isMovie,
              let seasonNumber = item.seasonNumber,
              let episodeNumber = item.episodeNumber else {
            return nil
        }

        return TMDBEpisode(
            id: Int("\(item.tmdbId)\(seasonNumber)\(episodeNumber)") ?? item.tmdbId,
            name: "",
            overview: nil,
            stillPath: nil,
            episodeNumber: episodeNumber,
            seasonNumber: seasonNumber,
            airDate: nil,
            runtime: nil,
            voteAverage: 0,
            voteCount: 0
        )
    }

    private var detailSearchResult: TMDBSearchResult {
        TMDBSearchResult(
            id: item.tmdbId,
            mediaType: item.isMovie ? "movie" : "tv",
            title: item.isMovie ? displayTitle : nil,
            name: item.isMovie ? nil : displayTitle,
            overview: nil,
            posterPath: nil,
            backdropPath: nil,
            releaseDate: nil,
            firstAirDate: nil,
            voteAverage: nil,
            popularity: 0,
            adult: nil,
            genreIds: nil
        )
    }

    var body: some View {
        Button {
            if isMetadataReady {
                showingSearchResults = true
            } else {
                pendingOpenSheet = true
            }
        } label: {
            ZStack(alignment: .bottomLeading) {
                ZStack {
                    if let backdropURL {
                        KFImage(URL(string: backdropURL))
                            .placeholder { backdropPlaceholder }
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        backdropPlaceholder
                    }
                }
                .frame(width: cardWidth, height: cardHeight)
                .clipped()

                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black.opacity(0.3), location: 0.4),
                        .init(color: .black.opacity(0.85), location: 1.0)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: isTvOS ? 10 : 6) {
                    Spacer()

                    HStack(alignment: .bottom, spacing: isTvOS ? 12 : 8) {
                        if let logoURL {
                            KFImage(URL(string: logoURL))
                                .placeholder { titleText }
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: logoMaxWidth, maxHeight: logoMaxHeight, alignment: .leading)
                        } else {
                            titleText
                        }

                        Spacer()

                        if !item.isMovie, let season = item.seasonNumber, let episode = item.episodeNumber {
                            Text("S\(season) E\(episode)")
                                .font(isTvOS ? .subheadline : .caption)
                                .fontWeight(.medium)
                                .foregroundColor(.white.opacity(0.9))
                        }
                    }

                    HStack(spacing: isTvOS ? 12 : 8) {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.white.opacity(0.3))
                                    .frame(height: isTvOS ? 6 : 4)

                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.white)
                                    .frame(width: geometry.size.width * item.progress, height: isTvOS ? 6 : 4)
                            }
                        }
                        .frame(height: isTvOS ? 6 : 4)

                        Text(item.remainingTime)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.white.opacity(0.8))
                            .fixedSize()
                    }
                }
                .padding(isTvOS ? 16 : 12)
            }
            .frame(width: cardWidth, height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(isHovering ? 0.5 : 0.15), lineWidth: isHovering ? 2 : 0.5)
            )
            .shadow(color: .black.opacity(0.35), radius: isHovering ? 12 : 8, x: 0, y: isHovering ? 8 : 4)
            .scaleEffect(isHovering ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isHovering)
            .modifier(ContinuousHoverModifier(isHovering: $isHovering))
        }
        .tvos({ view in
            view.buttonStyle(BorderlessButtonStyle())
        }, else: { view in
            view.buttonStyle(PlainButtonStyle())
        })
        .task {
            await loadMediaDetails()
        }
        .sheet(isPresented: $showingSearchResults) {
            ModulesSearchResultsSheet(
                mediaTitle: searchSheetTitle,
                seasonTitleOverride: isAnimeContent ? animeSeasonTitle : nil,
                originalTitle: originalTitle,
                isMovie: item.isMovie,
                isAnimeContent: isAnimeContent,
                selectedEpisode: selectedEpisodeForSearch,
                tmdbId: item.tmdbId,
                animeSeasonTitle: isAnimeContent ? "anime" : nil,
                posterPath: item.posterURL,
                imdbId: imdbId
            )
        }
        .contextMenu {
            Button {
                showingDetails = true
            } label: {
                Label("Details", systemImage: "info.circle")
            }

            Button {
                markAsWatched()
            } label: {
                Label("Mark as Watched", systemImage: "checkmark.circle")
            }

            Button(role: .destructive) {
                removeFromContinueWatching()
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .background(
            NavigationLink(destination: MediaDetailView(searchResult: detailSearchResult), isActive: $showingDetails) {
                EmptyView()
            }
            .hidden()
        )
    }

    @ViewBuilder
    private var titleText: some View {
        Text(displayTitle)
            .font(isTvOS ? .title3 : .subheadline)
            .fontWeight(.bold)
            .foregroundColor(.white)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
    }

    @ViewBuilder
    private var backdropPlaceholder: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [Color.gray.opacity(0.4), Color.gray.opacity(0.2)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                Image(systemName: item.isMovie ? "film" : "tv")
                    .font(isTvOS ? .largeTitle : .title)
                    .foregroundColor(.gray.opacity(0.5))
            )
    }

    private func loadMediaDetails() async {
        guard !isLoaded else { return }

        do {
            if item.isMovie {
                async let detailsTask = tmdbService.getMovieDetails(id: item.tmdbId)
                async let imagesTask = tmdbService.getMovieImages(id: item.tmdbId, preferredLanguage: selectedLanguage)
                async let romajiTask = tmdbService.getRomajiTitle(for: "movie", id: item.tmdbId)

                let (details, images, romaji) = try await (detailsTask, imagesTask, romajiTask)

                await MainActor.run {
                    self.title = details.title
                    self.backdropURL = details.fullBackdropURL ?? details.fullPosterURL ?? item.posterURL
                    if let logo = tmdbService.getBestLogo(from: images, preferredLanguage: selectedLanguage) {
                        self.logoURL = logo.fullURL
                    }
                    self.originalTitle = romaji
                    self.imdbId = details.imdbId
                    self.isAnimeContent = false
                    self.isLoaded = true
                    self.isMetadataReady = true
                    if self.pendingOpenSheet {
                        self.pendingOpenSheet = false
                        self.showingSearchResults = true
                    }
                }
            } else {
                // Fetch TMDB details, images, and romaji title in parallel
                async let detailsTask = tmdbService.getTVShowDetails(id: item.tmdbId)
                async let imagesTask = tmdbService.getTVShowImages(id: item.tmdbId, preferredLanguage: selectedLanguage)
                async let romajiTask = tmdbService.getRomajiTitle(for: "tv", id: item.tmdbId)

                let (details, images, romaji) = try await (detailsTask, imagesTask, romajiTask)

                // Anime detection: same logic as MediaDetailView
                let isJapanese = details.originCountry?.contains("JP") ?? false
                let isAnimation = details.genres.contains { $0.id == 16 }
                let detectedAsAnime = isJapanese && isAnimation

                // Set visual details immediately
                await MainActor.run {
                    self.title = details.name
                    self.backdropURL = details.fullBackdropURL ?? details.fullPosterURL ?? item.posterURL
                    if let logo = tmdbService.getBestLogo(from: images, preferredLanguage: selectedLanguage) {
                        self.logoURL = logo.fullURL
                    }
                    self.originalTitle = romaji
                    self.imdbId = details.externalIds?.imdbId
                    self.isLoaded = true
                }

                if detectedAsAnime {
                    // Fetch AniList data for correct season title mapping
                    do {
                        let animeData = try await AniListService.shared.fetchAnimeDetailsWithEpisodes(
                            title: details.name,
                            tmdbShowId: details.id,
                            tmdbService: tmdbService,
                            tmdbShowPoster: details.fullPosterURL,
                            token: nil
                        )

                        // Register AniList season IDs for tracker sync (same as MediaDetailView)
                        let seasonMappings = animeData.seasons.map { (seasonNumber: $0.seasonNumber, anilistId: $0.anilistId) }
                        TrackerManager.shared.registerAniListAnimeData(tmdbId: details.id, seasons: seasonMappings)

                        // Find the season title for the episode the user was watching
                        let matchedSeasonTitle: String? = {
                            guard let sn = item.seasonNumber else { return animeData.seasons.first?.title }
                            return animeData.seasons.first(where: { $0.seasonNumber == sn })?.title
                                ?? animeData.seasons.first?.title
                        }()

                        await MainActor.run {
                            self.isAnimeContent = true
                            self.animeSeasonTitle = matchedSeasonTitle
                            self.isMetadataReady = true
                            if self.pendingOpenSheet {
                                self.pendingOpenSheet = false
                                self.showingSearchResults = true
                            }
                        }

                        Logger.shared.log("ContinueWatchingCard: Resolved anime metadata for \(details.name), seasonTitle=\(matchedSeasonTitle ?? "nil")", type: "AniList")
                    } catch {
                        // AniList fetch failed – still mark as anime but without season title
                        Logger.shared.log("ContinueWatchingCard: AniList fetch failed for \(details.name): \(error.localizedDescription)", type: "AniList")
                        await MainActor.run {
                            self.isAnimeContent = true
                            self.isMetadataReady = true
                            if self.pendingOpenSheet {
                                self.pendingOpenSheet = false
                                self.showingSearchResults = true
                            }
                        }
                    }
                } else {
                    // Not anime – metadata is ready
                    await MainActor.run {
                        self.isAnimeContent = false
                        self.isMetadataReady = true
                        if self.pendingOpenSheet {
                            self.pendingOpenSheet = false
                            self.showingSearchResults = true
                        }
                    }
                }
            }
        } catch {
            await MainActor.run {
                if self.title.isEmpty {
                    self.title = item.title
                }
                self.backdropURL = item.posterURL
                self.isLoaded = true
                self.isMetadataReady = true
                if self.pendingOpenSheet {
                    self.pendingOpenSheet = false
                    self.showingSearchResults = true
                }
            }
        }
    }

    private func markAsWatched() {
        ProgressManager.shared.markContinueWatchingItemAsWatched(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            onDataChanged()
        }
    }

    private func removeFromContinueWatching() {
        ProgressManager.shared.removeContinueWatchingItem(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            onDataChanged()
        }
    }
}

struct ContinuousHoverModifier: ViewModifier {
    @Binding var isHovering: Bool
    
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content
                .onContinuousHover { phase in
                    switch phase {
                    case .active(_):
                        isHovering = true
                    case .ended:
                        isHovering = false
                    }
                }
        } else {
            content
        }
    }
}
