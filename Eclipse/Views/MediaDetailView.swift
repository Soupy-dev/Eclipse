import SwiftUI
import Kingfisher
import AVKit
#if os(iOS)
import Photos
import UIKit
#endif

struct MediaDetailInitialNotificationSelection: Equatable {
    enum Kind: Equatable {
        case episode
        case batch
        case season
    }

    let id: String
    let kind: Kind
    let sourceMediaID: Int?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let isAnimeSpecial: Bool
    let seasonLabel: String?

#if !os(tvOS)
    init(_ target: LocalNotificationNavigationTarget) {
        id = target.id
        switch target.kind {
        case .episode, .scheduleFallback: kind = .episode
        case .batch: kind = .batch
        case .season: kind = .season
        }
        sourceMediaID = target.sourceMediaID
        seasonNumber = target.seasonNumber
        episodeNumber = target.episodeNumber
        isAnimeSpecial = target.isAnimeSpecial
        seasonLabel = target.seasonLabel
    }
#endif
}

enum MediaDetailEpisodeAnchor {
    static func id(for episode: TMDBEpisode) -> String {
        "episode-\(episode.seasonNumber)-\(episode.episodeNumber)-\(episode.id)"
    }
}

#if os(iOS)
private struct StillPhotoSaveNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let offersSettings: Bool
}

private enum StillPhotoSaveError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The still image URL is invalid."
        case .invalidResponse:
            return "The downloaded file was not a valid image."
        case .httpStatus(let status):
            return "The image server returned HTTP \(status)."
        }
    }
}
#endif

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
        let animeRating: AnimeMetadataRating?
        let anilistEpisodes: [AniListEpisode]?
        let animeSeasonTitles: [Int: String]?
        let animeSeasonRomajiTitles: [Int: String]
        let animeSeasonAniListIds: [Int: Int]
        let animeSeasonKitsuIds: [Int: Int]
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
            animeRating: existing.animeRating,
            anilistEpisodes: existing.anilistEpisodes,
            animeSeasonTitles: existing.animeSeasonTitles,
            animeSeasonRomajiTitles: existing.animeSeasonRomajiTitles,
            animeSeasonAniListIds: existing.animeSeasonAniListIds,
            animeSeasonKitsuIds: existing.animeSeasonKitsuIds,
            animeSpecialEntries: entries,
            castMembers: existing.castMembers,
            timestamp: Date()
        )
    }
}

enum MediaDetailTitleArtworkSettings {
    static let enabledKey = "mediaDetailTitleArtworkEnabled"
    static let defaultEnabled = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) == nil ? defaultEnabled : defaults.bool(forKey: enabledKey)
    }
}

struct MediaDetailView: View {
    let searchResult: TMDBSearchResult
    private let watchTogetherAutoPlay: WatchTogetherMediaDescriptor?
    private let initialNotificationSelection: MediaDetailInitialNotificationSelection?
    
    @StateObject private var tmdbService = TMDBService.shared
    @StateObject private var trackerManager = TrackerManager.shared
    @State private var movieDetail: TMDBMovieDetail?
    @State private var tvShowDetail: TMDBTVShowWithSeasons?
    @State private var selectedSeason: TMDBSeason?
    @State private var seasonDetail: TMDBSeasonDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var ambientColor: Color = Color.black
    @State private var scrollOffset: CGFloat = 0
    @State private var showFullSynopsis: Bool = false
    @State private var showFullMetadata: Bool = true
    @State private var synopsis: String = ""
    @State private var isBookmarked: Bool = false
    @State private var showingSearchResults = false
    @State private var didStartWatchTogetherAutoPlay = false
    @State private var watchTogetherNextEpisodeAutoPlay = false
    @State private var watchTogetherPlaybackContextOverride: EpisodePlaybackContext?
    @State private var nextEpisodePlaybackContextOverride: EpisodePlaybackContext?
    @State private var nextEpisodeResolvedTargetOverride: ResolvedNextEpisodeTarget?
    @State private var nextEpisodeNotificationRoute = UUID()
#if !os(tvOS)
    @State private var showingDownloadSheet = false
    @State private var showingNotificationOptions = false
#endif
    @State private var showingAddToCollection = false
    @State private var selectedEpisodeForSearch: TMDBEpisode?
    @State private var romajiTitle: String?
    @State private var logoURL: String?
    @State private var isAnimeShow = false
    @State private var animeRating: AnimeMetadataRating?
    @State private var anilistEpisodes: [AniListEpisode]? = nil
    @State private var animeSeasonTitles: [Int: String]? = nil
    @State private var animeSeasonRomajiTitles: [Int: String] = [:]
    @State private var animeSeasonAniListIds: [Int: Int] = [:]
    @State private var animeSeasonKitsuIds: [Int: Int] = [:]
    @State private var animeSpecialEntries: [AniListSpecialSearchEntry] = []
    @State private var isLoadingAnimeSpecials = false
    @State private var selectedSpecialEpisodeContext: SpecialEpisodeListContext?
    @State private var specialSearchRequest: AnimeSpecialSearchRequest?
    @State private var nextEpisodePresentationToken = 0
    @State private var playSheetRequestId = UUID()
    @StateObject private var autoModeRetrySession = AutoModeRetrySession()
    
    @State private var castMembers: [TMDBCastMember] = []
    @State private var detailStills: [TMDBImage] = []
#if os(iOS)
    @State private var savingStillURL: String?
    @State private var stillPhotoSaveNotice: StillPhotoSaveNotice?
#endif
    @State private var detailTrailers: [TMDBVideo] = []
    @State private var similarTitles: [TMDBSearchResult] = []
    @State private var isLoadingExperimentalExtras = false
    @State private var isLoadingSimilarTitles = false
    @State private var similarTitlesLoadFailed = false
    @State private var traktComments: [TraktCommentReview] = []
    @State private var traktRating: TraktMediaRating?
    @State private var isLoadingTraktComments = false
    @State private var hasLoadedContent = false
    @State private var detailLoadTask: Task<Void, Never>?
    @State private var specialsLoadTask: Task<Void, Never>?
    @State private var traktFeatureLoadTask: Task<Void, Never>?
    @State private var experimentalExtrasLoadTask: Task<Void, Never>?
    @State private var similarTitlesLoadTask: Task<Void, Never>?
    @State private var specialsLoadGeneration = 0
    @State private var detailContentRefreshTick = 0
    @State private var handledNotificationSelectionID: String?
    @State private var notificationEpisodeScrollGeneration = 0
    @State private var notificationRouteNotice: String?
    
    @StateObject private var serviceManager = ServiceManager.shared
    @StateObject private var stremioManager = StremioAddonManager.shared
#if !os(tvOS)
    private let downloadManager = DownloadManager.shared
    @ObservedObject private var localNotificationManager = LocalNotificationManager.shared
#endif
    @ObservedObject private var libraryManager = LibraryManager.shared
    @ObservedObject private var theme = EclipseTheme.shared
    @StateObject private var accentManager = AccentColorManager.shared
    private let progressManager = ProgressManager.shared
    private static let notificationEpisodesAnchor = "media-detail-notification-episodes"
    
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("tmdbLanguage") private var selectedLanguage = "en-US"
    @AppStorage("mediaDetailElementOrder") private var mediaDetailElementOrder = MediaDetailElement.defaultOrderRawValue
    @AppStorage("mediaDetailHiddenElements") private var mediaDetailHiddenElements = ""
    @AppStorage("showCastSection") private var legacyShowCastSection = true
    @AppStorage(MediaDetailPlatformDefaults.seasonMenuKey) private var useSeasonMenu = MediaDetailPlatformDefaults.prefersCompactSeasonMenu
    @AppStorage(MediaDetailTitleArtworkSettings.enabledKey) private var mediaDetailTitleArtworkEnabled = MediaDetailTitleArtworkSettings.defaultEnabled
    @AppStorage(MediaDetailSimilarTitlesSettings.enabledKey) private var mediaDetailSimilarTitlesEnabled = MediaDetailSimilarTitlesSettings.defaultEnabled
    @AppStorage(ExperimentalMediaDesignPreset.storageKey) private var experimentalDesignPreset = ExperimentalMediaDesignPreset.defaultValue.rawValue
    @AppStorage(ExperimentalHeroBleedLevel.storageKey) private var experimentalHeroBleedLevel = ExperimentalHeroBleedLevel.defaultValue.rawValue
    @AppStorage(ExperimentalHomeCardShape.storageKey) private var experimentalHomeCardShape = ExperimentalHomeCardShape.defaultValue.rawValue
    private let nextEpisodeSheetPresentationDelay: TimeInterval = 1.2

    init(
        searchResult: TMDBSearchResult,
        watchTogetherAutoPlay: WatchTogetherMediaDescriptor? = nil,
        initialNotificationSelection: MediaDetailInitialNotificationSelection? = nil
    ) {
        self.searchResult = searchResult
        self.watchTogetherAutoPlay = watchTogetherAutoPlay
        self.initialNotificationSelection = initialNotificationSelection
    }

    private var atmosphereColor: Color {
        theme.atmosphereColor(dominant: ambientColor)
    }

    private var heroBlendColor: Color {
        theme.heroBlendColor(dominant: ambientColor)
    }

    /// Poster color for the scroll-attached banner bleed; nil for a
    /// near-black/absent backdrop so the app gradient stays clean.
    private var heroBleedColor: Color? {
        EclipseTheme.usableDominant(ambientColor)
    }

    private var mediaDetailHeroBleedColor: Color? {
        isIPad ? heroBlendColor : heroBleedColor
    }

    private var mediaDetailHeroBleedTail: CGFloat {
        guard isIPad else { return headerHeight * 0.62 }
        return min(max(UIScreen.main.bounds.height * 0.78, 680), 900)
    }

    private var mediaDetailHeroBleedStrength: Double {
        let configuredStrength = theme.scopedBleedStrength()
        guard isIPad, configuredStrength > 0.001 else { return configuredStrength }
        return min(max(configuredStrength * 1.18, 0.92), 1.25)
    }

    private var designMetrics: ExperimentalMediaDesignMetrics {
        ExperimentalMediaDesignMetrics(
            preset: ExperimentalMediaDesignPreset(rawValue: experimentalDesignPreset) ?? ExperimentalMediaDesignPreset.defaultValue,
            heroBleedLevel: ExperimentalHeroBleedLevel(rawValue: experimentalHeroBleedLevel) ?? ExperimentalHeroBleedLevel.defaultValue,
            cardShape: ExperimentalHomeCardShape(rawValue: experimentalHomeCardShape) ?? ExperimentalHomeCardShape.defaultValue
        )
    }

    private var backgroundScrollOffset: CGFloat {
#if os(iOS)
        isIPad ? 0 : scrollOffset
#else
        scrollOffset
#endif
    }

    private var scrollOffsetUpdateThreshold: CGFloat {
        ExperimentalFeatureState.isEnabledAtLaunch ? designMetrics.scrollOffsetThreshold : 8
    }

    private var hasActiveSources: Bool {
        !serviceManager.activeServices.isEmpty ||
        !stremioManager.activeAddons.isEmpty
    }

    private var preferDownloadedMedia: Bool {
#if os(tvOS)
        false
#else
        UserDefaults.standard.bool(forKey: "preferDownloadedMedia")
#endif
    }

#if !os(tvOS)
    private var notificationTitleAliases: [String] {
        var values = [
            searchResult.displayTitle,
            searchResult.title ?? "",
            searchResult.name ?? "",
            tvShowDetail?.name ?? "",
            tvShowDetail?.originalName ?? "",
            romajiTitle ?? ""
        ]
        if let animeSeasonTitles {
            values.append(contentsOf: animeSeasonTitles.values)
        }
        values.append(contentsOf: animeSeasonRomajiTitles.values)
        return values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var isFollowingLocalNotifications: Bool {
        guard !searchResult.isMovie else { return false }
        let source: LocalNotificationMediaSource = isAnimeShow ? .anime : .western
        guard let subscription = localNotificationManager.subscription(source: source, tmdbID: searchResult.id) else {
            return false
        }
        return subscription.episodeNotifications || subscription.futureSeasonNotifications
    }
#endif

    private var visibleMediaDetailElements: [MediaDetailElement] {
        MediaDetailElement.orderedElements(from: mediaDetailElementOrder).filter { element in
            guard ExperimentalFeatureState.isEnabledAtLaunch || (element != .stills && element != .trailers) else {
                return false
            }
            guard element != .similarTitles || mediaDetailSimilarTitlesEnabled else {
                return false
            }
            guard MediaDetailElement.isVisible(
                element,
                hiddenRawValue: mediaDetailHiddenElements,
                legacyShowCastSection: legacyShowCastSection
            ) else {
                return false
            }
            return searchResult.isMovie ? element.appliesToMovies : element.appliesToSeries
        }
    }

    private var experimentalHeroElements: Set<MediaDetailElement> {
        [.actions, .overview, .details]
    }

    private var visibleHeroElements: Set<MediaDetailElement> {
        Set(visibleMediaDetailElements)
    }

    private var visibleBodyMediaDetailElements: [MediaDetailElement] {
        guard ExperimentalFeatureState.isEnabledAtLaunch else {
            return visibleMediaDetailElements
        }
        return visibleMediaDetailElements.filter { !experimentalHeroElements.contains($0) }
    }

    private var shouldShowHeroActions: Bool {
        visibleHeroElements.contains(.actions)
    }

    private var shouldShowHeroOverview: Bool {
        visibleHeroElements.contains(.overview) && currentOverviewText != nil
    }

    private var shouldShowHeroDetails: Bool {
        visibleHeroElements.contains(.details)
    }

    private var hasPlayableDownloadForMainButton: Bool {
#if os(tvOS)
        false
#else
        guard preferDownloadedMedia else { return false }
        if searchResult.isMovie {
            return downloadManager.completedDownloadItem(tmdbId: searchResult.id, isMovie: true) != nil
        }
        return downloadManager.completedDownloads.contains {
            !$0.isMovie && $0.tmdbId == searchResult.id && downloadManager.localFileURL(for: $0) != nil
        }
#endif
    }

    private var canUseMainPlayButton: Bool {
        hasActiveSources || hasPlayableDownloadForMainButton
    }

    private var headerHeight: CGFloat {
#if os(tvOS)
        UIScreen.main.bounds.height * 0.8
#else
        if ExperimentalFeatureState.isEnabledAtLaunch {
            let measuredHeight = designMetrics.detailHeroHeight(
                screenHeight: UIScreen.main.bounds.height,
                isIPad: isIPad
            )
            return isIPad ? min(measuredHeight, 640) : measuredHeight
        }
        return isIPad ? 640 : min(max(UIScreen.main.bounds.height * 0.76, 620), 780)
#endif
    }


    private var minHeaderHeight: CGFloat {
#if os(tvOS)
        UIScreen.main.bounds.height * 0.8
#else
        isIPad ? 520 : 420
#endif
    }

    private struct MainPlayEpisodeKey: Hashable {
        let seasonNumber: Int
        let episodeNumber: Int
    }

    private struct MainPlayEpisodeCandidate {
        let key: MainPlayEpisodeKey
        let episode: TMDBEpisode?
    }

    private var playButtonText: String {
        if searchResult.isMovie {
            return "Play"
        }

        if selectedSpecialEpisodeContext != nil, let selectedEpisode = selectedEpisodeForSearch {
            return "Play \(episodeLabel(seasonNumber: selectedEpisode.seasonNumber, episodeNumber: selectedEpisode.episodeNumber, forceEpisodeOnly: true))"
        }

        if let target = resolveMainPlayEpisodeTarget() {
            return "Play \(episodeLabel(seasonNumber: target.key.seasonNumber, episodeNumber: target.key.episodeNumber))"
        }

        if let selectedEpisode = selectedEpisodeForSearch {
            return "Play \(episodeLabel(seasonNumber: selectedEpisode.seasonNumber, episodeNumber: selectedEpisode.episodeNumber))"
        }

        return "Play"
    }

    private func episodeLabel(seasonNumber: Int, episodeNumber: Int, forceEpisodeOnly: Bool = false) -> String {
        if forceEpisodeOnly || isAnimeShow {
            return "E\(episodeNumber)"
        }
        return "S\(seasonNumber)E\(episodeNumber)"
    }
    
    var body: some View {
        ZStack {
            EclipseTheme.shared.backgroundBase
                .ignoresSafeArea(.all)

            detailBackground
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
        .overlay(alignment: .top) {
            if let notificationRouteNotice {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "bell.badge")
                        .foregroundColor(.orange)
                    Text(notificationRouteNotice)
                        .font(.footnote.weight(.medium))
                        .foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            self.notificationRouteNotice = nil
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundColor(.white.opacity(0.65))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss notification navigation message")
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 54)
                .padding(.top, 68)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
#if !os(tvOS)
        .simultaneousGesture(edgeBackSwipeGesture)
#else
        .onExitCommand {
            presentationMode.wrappedValue.dismiss()
        }
#endif
        .onAppear {
            if !hasLoadedContent {
                loadMediaDetails()
            } else {
                startTraktFeatureLoad()
                startExperimentalExtrasLoadIfNeeded()
                startSimilarTitlesLoadIfNeeded()
            }
            updateBookmarkStatus()
            startWatchTogetherPlaybackIfReady()
            if hasLoadedContent {
                Task { await applyInitialNotificationSelectionIfNeeded() }
            }
        }
        .onDisappear {
            if let detailLoadTask {
                detailLoadTask.cancel()
                self.detailLoadTask = nil
            }
            if let specialsLoadTask {
                specialsLoadTask.cancel()
                self.specialsLoadTask = nil
            }
            if let traktFeatureLoadTask {
                Logger.shared.log("MediaDetail Trakt feature load task cancelled on disappear: id=\(searchResult.id)", type: "Tracker")
                traktFeatureLoadTask.cancel()
                self.traktFeatureLoadTask = nil
            }
            if let experimentalExtrasLoadTask {
                Logger.shared.log("MediaDetail experimental extras task cancelled on disappear: id=\(searchResult.id)", type: "TMDB")
                experimentalExtrasLoadTask.cancel()
                self.experimentalExtrasLoadTask = nil
            }
            if let similarTitlesLoadTask {
                Logger.shared.log("MediaDetail similar titles task cancelled on disappear: id=\(searchResult.id)", type: "TMDB")
                similarTitlesLoadTask.cancel()
                self.similarTitlesLoadTask = nil
            }
            specialsLoadGeneration += 1
        }
        .onChange(of: trackerManager.trackerState.traktCommentsEnabled) { _ in
            if hasLoadedContent {
                startTraktFeatureLoad()
            }
        }
        .onChange(of: mediaDetailElementOrder) { _ in
            handleMediaDetailLayoutPreferenceChange()
        }
        .onChange(of: mediaDetailHiddenElements) { _ in
            handleMediaDetailLayoutPreferenceChange()
        }
        .onChange(of: mediaDetailSimilarTitlesEnabled) { _ in
            handleMediaDetailLayoutPreferenceChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestNextEpisode)) { notification in
            guard notification.object as? UUID == nextEpisodeNotificationRoute,
                  let userInfo = notification.userInfo,
                  let tmdbId = userInfo["tmdbId"] as? Int,
                  tmdbId == searchResult.id,
                  let seasonNumber = userInfo["seasonNumber"] as? Int,
                  let episodeNumber = userInfo["episodeNumber"] as? Int else {
                return
            }
            watchTogetherNextEpisodeAutoPlay = userInfo["watchTogether"] as? Bool == true
            let incomingResolvedTarget = userInfo["resolvedTarget"] as? ResolvedNextEpisodeTarget
            let incomingPlaybackContext = incomingResolvedTarget?.playbackContext
                ?? userInfo["playbackContext"] as? EpisodePlaybackContext
            let incomingIsAnime = incomingResolvedTarget?.isAnime
                ?? (userInfo["isAnime"] as? Bool == true)
            let incomingIsExactTarget = userInfo["exactTarget"] as? Bool == true
            nextEpisodePlaybackContextOverride = incomingPlaybackContext
            nextEpisodeResolvedTargetOverride = incomingResolvedTarget

            if watchTogetherNextEpisodeAutoPlay, incomingIsAnime {
                let incomingMedia = WatchTogetherMediaDescriptor(
                    tmdbID: tmdbId,
                    mediaType: "tv",
                    seasonNumber: seasonNumber,
                    episodeNumber: episodeNumber,
                    playbackContext: incomingPlaybackContext,
                    isAnime: true
                )
                if let failure = incomingMedia.animeContextFailureReason {
                    failWatchTogetherPlayback(failure)
                    return
                }
                guard let incomingPlaybackContext else {
                    failWatchTogetherPlayback("Watch Together could not read the anime episode context, so it stopped instead of guessing a TMDB episode.")
                    return
                }
                if incomingPlaybackContext.isSpecial {
                    guard let anilistID = incomingPlaybackContext.anilistMediaId,
                          let entry = animeSpecialEntries.first(where: { $0.id == anilistID }),
                          let specialContext = SpecialEpisodeListContext(entry: entry, tmdbShowId: searchResult.id),
                          let episode = specialContext.episodes.first(where: {
                              $0.seasonNumber == incomingPlaybackContext.localSeasonNumber
                                  && $0.episodeNumber == incomingPlaybackContext.localEpisodeNumber
                          }) else {
                        failWatchTogetherPlayback("Watch Together could not resolve the exact anime special on this device. It stopped instead of falling back to TMDB.")
                        return
                    }
                    watchTogetherPlaybackContextOverride = incomingPlaybackContext
                    selectedSpecialEpisodeContext = specialContext
                    selectedEpisodeForSearch = episode
                    scheduleNextEpisodePresentation {
                        beginSpecialSearch(context: specialContext, episode: episode)
                    }
                    return
                }

                guard let episode = watchTogetherAnimeEpisode(from: incomingPlaybackContext) else {
                    watchTogetherPlaybackContextOverride = nil
                    failWatchTogetherPlayback(watchTogetherAnimeEpisodeFailureMessage(for: incomingPlaybackContext))
                    return
                }
                watchTogetherPlaybackContextOverride = incomingPlaybackContext
                selectedSpecialEpisodeContext = nil
                selectedEpisodeForSearch = episode
                showingSearchResults = false
                scheduleNextEpisodePresentation {
                    beginNewMainPlaybackSearchSession()
                    showingSearchResults = true
                }
                return
            }

            if incomingIsExactTarget, let incomingResolvedTarget {
                selectedSpecialEpisodeContext = nil
                selectedEpisodeForSearch = incomingResolvedTarget.episode
                showingSearchResults = false
                scheduleNextEpisodePresentation {
                    beginNewMainPlaybackSearchSession()
                    showingSearchResults = true
                }
                return
            }

            if incomingIsAnime, let incomingPlaybackContext {
                if incomingPlaybackContext.isSpecial {
                    guard let anilistID = incomingPlaybackContext.anilistMediaId,
                          let entry = animeSpecialEntries.first(where: { $0.id == anilistID }),
                          let specialContext = SpecialEpisodeListContext(entry: entry, tmdbShowId: searchResult.id),
                          let episode = specialContext.episodes.first(where: {
                              $0.seasonNumber == incomingPlaybackContext.localSeasonNumber
                                  && $0.episodeNumber == incomingPlaybackContext.localEpisodeNumber
                          }) else {
                        Logger.shared.log("NextEpisode: Could not resolve the exact anime special context", type: "Player")
                        return
                    }
                    selectedSpecialEpisodeContext = specialContext
                    selectedEpisodeForSearch = episode
                    scheduleNextEpisodePresentation {
                        beginSpecialSearch(context: specialContext, episode: episode)
                    }
                    return
                }

                guard let episode = watchTogetherAnimeEpisode(from: incomingPlaybackContext) else {
                    Logger.shared.log(
                        "NextEpisode: \(watchTogetherAnimeEpisodeFailureMessage(for: incomingPlaybackContext))",
                        type: "Player"
                    )
                    return
                }
                selectedSpecialEpisodeContext = nil
                selectedEpisodeForSearch = episode
                showingSearchResults = false
                scheduleNextEpisodePresentation {
                    beginNewMainPlaybackSearchSession()
                    showingSearchResults = true
                }
                return
            } else if incomingIsAnime, incomingIsExactTarget {
                Logger.shared.log("NextEpisode: Exact anime target arrived without its mapping context", type: "Player")
                return
            }

            if let specialContext = selectedSpecialEpisodeContext,
               let nextSpecialEpisode = specialContext.episodes.first(where: { $0.seasonNumber == seasonNumber && $0.episodeNumber == episodeNumber }) {
                selectedEpisodeForSearch = nextSpecialEpisode
                scheduleNextEpisodePresentation {
                    beginSpecialSearch(context: specialContext, episode: nextSpecialEpisode)
                }
                return
            }

            // Find the next episode in the current season detail
            if let episodes = seasonDetail?.episodes,
               let nextEp = episodes.first(where: { $0.seasonNumber == seasonNumber && $0.episodeNumber == episodeNumber }) {
                selectedEpisodeForSearch = nextEp
                showingSearchResults = false
                scheduleNextEpisodePresentation {
                    beginNewMainPlaybackSearchSession()
                    showingSearchResults = true
                }
            } else {
                Task { @MainActor in
                    if incomingIsExactTarget {
                        if let exactEpisode = await episodeForPlayback(
                            seasonNumber: seasonNumber,
                            episodeNumber: episodeNumber
                        ) {
                            selectedSpecialEpisodeContext = nil
                            selectedEpisodeForSearch = exactEpisode
                            showingSearchResults = false
                            scheduleNextEpisodePresentation {
                                beginNewMainPlaybackSearchSession()
                                showingSearchResults = true
                            }
                        } else {
                            Logger.shared.log(
                                "NextEpisode: Exact target S\(seasonNumber)E\(episodeNumber) could not be loaded for tmdbId=\(tmdbId)",
                                type: "Player"
                            )
                        }
                        return
                    }

                    if let specialContext = selectedSpecialEpisodeContext,
                       let currentIndex = specialContext.episodes.firstIndex(where: {
                           $0.seasonNumber == seasonNumber && $0.episodeNumber == episodeNumber - 1
                       }),
                       specialContext.episodes.indices.contains(currentIndex + 1) {
                        let next = specialContext.episodes[currentIndex + 1]
                        selectedEpisodeForSearch = next
                        scheduleNextEpisodePresentation {
                            beginSpecialSearch(context: specialContext, episode: next)
                        }
                        return
                    }

                    if isAnimeShow,
                       let orderedEpisodes = anilistEpisodes?.sorted(by: episodeSort),
                       let currentIndex = orderedEpisodes.firstIndex(where: {
                           $0.seasonNumber == seasonNumber && $0.number == episodeNumber - 1
                       }),
                       orderedEpisodes.indices.contains(currentIndex + 1) {
                        let next = tmdbEpisode(from: orderedEpisodes[currentIndex + 1])
                        selectedEpisodeForSearch = next
                        showingSearchResults = false
                        scheduleNextEpisodePresentation {
                            beginNewMainPlaybackSearchSession()
                            showingSearchResults = true
                        }
                        return
                    }

                    if let nextSeasonNumber = tvShowDetail?.seasons
                        .filter({ $0.seasonNumber > seasonNumber && $0.seasonNumber > 0 })
                        .map(\.seasonNumber)
                        .min(),
                       let next = await episodeForPlayback(seasonNumber: nextSeasonNumber, episodeNumber: 1) {
                        selectedEpisodeForSearch = next
                        showingSearchResults = false
                        scheduleNextEpisodePresentation {
                            beginNewMainPlaybackSearchSession()
                            showingSearchResults = true
                        }
                        return
                    }

                    Logger.shared.log("NextEpisode: Could not resolve an episode after S\(seasonNumber)E\(episodeNumber - 1) for tmdbId=\(tmdbId)", type: "Player")
                }
            }
        }
        .onChangeComp(of: libraryManager.collections) { _, _ in
            updateBookmarkStatus()
        }
        .onChangeComp(of: showingSearchResults) { _, newValue in
            if !newValue {
                refreshDetailContentLayout(reason: "play sheet dismissed")
            }
        }
        .onChangeComp(of: hasLoadedContent) { _, loaded in
            if loaded {
                startWatchTogetherPlaybackIfReady()
                Task { await applyInitialNotificationSelectionIfNeeded() }
            }
        }
        .onChange(of: isLoadingAnimeSpecials) { loading in
            if !loading {
                startWatchTogetherPlaybackIfReady()
                Task { await applyInitialNotificationSelectionIfNeeded() }
            }
        }
#if !os(tvOS)
        .onChangeComp(of: showingDownloadSheet) { _, newValue in
            if !newValue {
                refreshDetailContentLayout(reason: "download sheet dismissed")
            }
        }
#endif
        .onChangeComp(of: specialSearchRequest?.id) { _, newValue in
            if newValue == nil {
                refreshDetailContentLayout(reason: "special search sheet dismissed")
            }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                updateBookmarkStatus()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .playerDidClose)) { notification in
            guard playerCloseNotificationMatchesDetail(notification) else { return }
            refreshDetailContentLayout(reason: "player closed")
        }
        .onDisappear {
            invalidatePendingNextEpisodePresentation()
        }
        .sheet(isPresented: $showingSearchResults, onDismiss: {
            watchTogetherNextEpisodeAutoPlay = false
            nextEpisodePlaybackContextOverride = nil
            nextEpisodeResolvedTargetOverride = nil
        }) {
            let exactWatchTogetherContext = exactWatchTogetherPlaybackContext(for: selectedEpisodeForSearch)
            let isWatchTogetherPlayback = watchTogetherAutoPlay != nil || watchTogetherNextEpisodeAutoPlay
            let isForcedWatchTogetherAnime = isWatchTogetherPlayback && !searchResult.isMovie && (
                watchTogetherAutoPlay?.isAnime == true
                    || watchTogetherAutoPlay?.playbackContext?.hasAnimeMediaId == true
                    || watchTogetherPlaybackContextOverride?.hasAnimeMediaId == true
                    || isAnimeShow
            )
            // A forced Watch Together anime handoff may only use the exact context carried by
            // the session. Falling back to the receiver's ordinary detail-sheet context can
            // silently translate a different cour/season into S1E1.
            let playbackContext = isForcedWatchTogetherAnime
                ? exactWatchTogetherContext
                : (exactWatchTogetherContext ?? playbackContextForSearchSheet(selectedEpisodeForSearch))
            let playbackIsAnime = nextEpisodeResolvedTargetOverride?.isAnime
                ?? (watchTogetherAutoPlay?.isAnime == true || playbackContext?.hasAnimeMediaId == true || isAnimeShow)
            let recoveryTargetToken = AutoModeMediaTargetToken.make(
                tmdbID: searchResult.id,
                isMovie: searchResult.isMovie,
                episode: selectedEpisodeForSearch,
                playbackContext: playbackContext
            )
            let recoveryIdentity = autoModeRetrySession.recoveryIdentity(for: recoveryTargetToken)
            let recoveryEpisode = selectedEpisodeForSearch
            let recoveryResolvedTarget = nextEpisodeResolvedTargetOverride
            let recoveryWasWatchTogetherNext = watchTogetherNextEpisodeAutoPlay
            ModulesSearchResultsSheet(
                mediaTitle: {
                    if let target = nextEpisodeResolvedTargetOverride {
                        return target.seasonTitleOverride ?? target.mediaTitle
                    }
                    if isAnimeShow, let episode = selectedEpisodeForSearch,
                       let seasonTitle = animeSeasonTitles?[episode.seasonNumber] {
                        return seasonTitle
                    }
                    return searchResult.displayTitle
                }(),
                seasonTitleOverride: {
                    if let target = nextEpisodeResolvedTargetOverride {
                        return target.seasonTitleOverride
                    }
                    if isAnimeShow, let episode = selectedEpisodeForSearch,
                       let seasonTitle = animeSeasonTitles?[episode.seasonNumber] {
                        return seasonTitle
                    }
                    return nil
                }(),
                originalTitle: nextEpisodeResolvedTargetOverride?.originalTitle
                    ?? originalTitleForSearchSheet(selectedEpisodeForSearch),
                isMovie: searchResult.isMovie,
                isAnimeContent: playbackIsAnime,
                selectedEpisode: selectedEpisodeForSearch,
                tmdbId: searchResult.id,
                animeSeasonTitle: playbackIsAnime ? "anime" : nil,
                posterPath: nextEpisodeResolvedTargetOverride?.posterURL
                    ?? (searchResult.isMovie ? movieDetail?.posterPath : tvShowDetail?.posterPath),
                originalAudioLanguage: searchResult.originalLanguage ?? (searchResult.isMovie ? movieDetail?.originalLanguage : tvShowDetail?.originalLanguage),
                imdbId: nextEpisodeResolvedTargetOverride?.imdbID
                    ?? (searchResult.isMovie ? movieDetail?.imdbId : tvShowDetail?.externalIds?.imdbId),
                originalTMDBSeasonNumber: playbackContext?.resolvedTMDBSeasonNumber,
                originalTMDBEpisodeNumber: playbackContext?.resolvedTMDBEpisodeNumber,
                specialTitleOnlySearch: playbackContext?.titleOnlySearch ?? false,
                episodePlaybackContext: playbackContext,
                autoModeOnly: watchTogetherAutoPlay != nil || watchTogetherNextEpisodeAutoPlay || UserDefaults.standard.bool(forKey: "servicesAutoModeEnabled"),
                forceAutomaticPlayback: watchTogetherAutoPlay != nil || watchTogetherNextEpisodeAutoPlay,
                autoModeRetrySession: autoModeRetrySession,
                autoModeRecoveryIdentity: recoveryIdentity,
                onAutoModePlaybackFailure: { report, identity in
                    Task { @MainActor in
                        handleMainAutoModePlaybackFailure(
                            report,
                            identity: identity,
                            episode: recoveryEpisode,
                            playbackContext: playbackContext,
                            resolvedTarget: recoveryResolvedTarget,
                            wasWatchTogetherNext: recoveryWasWatchTogetherNext
                        )
                    }
                },
                nextEpisodeNotificationRoute: nextEpisodeNotificationRoute,
                isAnimationGenre16: nextEpisodeResolvedTargetOverride?.isAnimation
                    ?? detailGenres.contains { $0.id == 16 }
            )
            .id(playSheetRequestId)
        }
#if !os(tvOS)
        .sheet(isPresented: $showingDownloadSheet) {
            let playbackContext = playbackContextForSearchSheet(selectedEpisodeForSearch)
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
                originalTitle: originalTitleForSearchSheet(selectedEpisodeForSearch),
                isMovie: searchResult.isMovie,
                isAnimeContent: isAnimeShow,
                selectedEpisode: selectedEpisodeForSearch,
                tmdbId: searchResult.id,
                animeSeasonTitle: isAnimeShow ? "anime" : nil,
                posterPath: searchResult.isMovie ? movieDetail?.posterPath : tvShowDetail?.posterPath,
                originalAudioLanguage: searchResult.originalLanguage ?? (searchResult.isMovie ? movieDetail?.originalLanguage : tvShowDetail?.originalLanguage),
                imdbId: searchResult.isMovie ? movieDetail?.imdbId : tvShowDetail?.externalIds?.imdbId,
                originalTMDBSeasonNumber: playbackContext?.resolvedTMDBSeasonNumber,
                originalTMDBEpisodeNumber: playbackContext?.resolvedTMDBEpisodeNumber,
                episodePlaybackContext: playbackContext,
                downloadMode: true,
                autoModeOnly: UserDefaults.standard.bool(forKey: "servicesAutoModeEnabled"),
                isAnimationGenre16: detailGenres.contains { $0.id == 16 }
            )
        }
#endif
        .sheet(item: $specialSearchRequest, onDismiss: {
            watchTogetherNextEpisodeAutoPlay = false
            nextEpisodePlaybackContextOverride = nil
            nextEpisodeResolvedTargetOverride = nil
        }) { request in
            let recoveryTargetToken = AutoModeMediaTargetToken.make(
                tmdbID: searchResult.id,
                isMovie: false,
                episode: request.episode,
                playbackContext: request.playbackContext
            )
            let recoveryIdentity = autoModeRetrySession.recoveryIdentity(for: recoveryTargetToken)
            let recoveryResolvedTarget = nextEpisodeResolvedTargetOverride
            let recoveryWasWatchTogetherNext = watchTogetherNextEpisodeAutoPlay
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
                originalAudioLanguage: searchResult.originalLanguage ?? tvShowDetail?.originalLanguage,
                imdbId: request.imdbId ?? tvShowDetail?.externalIds?.imdbId,
                originalTMDBSeasonNumber: request.originalSeasonNumber,
                originalTMDBEpisodeNumber: request.originalEpisodeNumber,
                specialTitleOnlySearch: request.titleOnly,
                episodePlaybackContext: request.playbackContext,
                autoModeOnly: watchTogetherAutoPlay != nil || watchTogetherNextEpisodeAutoPlay || UserDefaults.standard.bool(forKey: "servicesAutoModeEnabled"),
                forceAutomaticPlayback: watchTogetherAutoPlay != nil || watchTogetherNextEpisodeAutoPlay,
                autoModeRetrySession: autoModeRetrySession,
                autoModeRecoveryIdentity: recoveryIdentity,
                onAutoModePlaybackFailure: { report, identity in
                    Task { @MainActor in
                        handleSpecialAutoModePlaybackFailure(
                            report,
                            identity: identity,
                            request: request,
                            resolvedTarget: recoveryResolvedTarget,
                            wasWatchTogetherNext: recoveryWasWatchTogetherNext
                        )
                    }
                },
                nextEpisodeNotificationRoute: nextEpisodeNotificationRoute,
                isAnimationGenre16: detailGenres.contains { $0.id == 16 }
            )
        }
        .sheet(isPresented: $showingAddToCollection) {
            AddToCollectionView(searchResult: searchResult)
        }
#if !os(tvOS)
        .sheet(isPresented: $showingNotificationOptions) {
            MediaNotificationOptionsView(
                source: isAnimeShow ? .anime : .western,
                tmdbID: searchResult.id,
                title: tvShowDetail?.name ?? searchResult.displayTitle,
                titleAliases: notificationTitleAliases,
                animeMediaIDs: Set(animeSeasonAniListIds.values),
                westernSeasonIDs: Set((tvShowDetail?.seasons ?? []).filter { $0.seasonNumber > 0 }.map(\.id))
            )
        }
#endif
#if os(iOS)
        .alert(item: $stillPhotoSaveNotice) { notice in
            if notice.offersSettings {
                return Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    primaryButton: .default(Text("Open Settings")) {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    },
                    secondaryButton: .cancel()
                )
            }
            return Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
#endif
    }

    @ViewBuilder
    private var detailBackground: some View {
        if ExperimentalFeatureState.isEnabledAtLaunch {
            AtmosphereBackdrop(
                input: theme.atmosphereInput(
                    dominant: ambientColor,
                    hasHeroBleed: false,
                    heroHeight: headerHeight,
                    fadeDistance: headerHeight * 0.62
                ),
                scrollOffset: backgroundScrollOffset
            )
        } else if theme.atmosphereStyle == .solid {
            atmosphereColor
        } else {
            LinearGradient(
                stops: [
                    .init(color: EclipseTheme.shared.backgroundBase, location: 0.0),
                    .init(color: ambientColor.opacity(0.74), location: 0.12),
                    .init(color: ambientColor.opacity(0.30), location: 0.34),
                    .init(color: EclipseTheme.shared.backgroundBase, location: 0.72)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
    
    @ViewBuilder
    private var loadingView: some View {
        VStack {
            EclipseLoadingIndicator()
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
                        .font(.system(size: ExperimentalFeatureState.isEnabledAtLaunch ? 28 : 16, weight: .medium))
                        .foregroundColor(.white)
                        .frame(
                            width: ExperimentalFeatureState.isEnabledAtLaunch ? 58 : 32,
                            height: ExperimentalFeatureState.isEnabledAtLaunch ? 58 : 32
                        )
                        .background(
                            Circle()
                                .fill(ExperimentalFeatureState.isEnabledAtLaunch ? atmosphereColor.opacity(0.36) : Color.clear)
                                .background(
                                    Circle()
                                        .fill(.ultraThinMaterial)
                                        .opacity(ExperimentalFeatureState.isEnabledAtLaunch ? 0.72 : 0)
                                )
                        )
                        .applyLiquidGlassBackground(cornerRadius: ExperimentalFeatureState.isEnabledAtLaunch ? 29 : 16)
                }
                
                Spacer()
            }
            .padding(.horizontal, ExperimentalFeatureState.isEnabledAtLaunch ? 22 : 16)
            .padding(.top, ExperimentalFeatureState.isEnabledAtLaunch ? 20 : 0)
            
            Spacer()
        }
    }

#if !os(tvOS)
    private var edgeBackSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .global)
            .onEnded { value in
                guard value.startLocation.x <= 32,
                      value.translation.width > 70,
                      abs(value.translation.height) < 70 else {
                    return
                }
                presentationMode.wrappedValue.dismiss()
            }
    }
#endif
    
    @ViewBuilder
    private var mainScrollView: some View {
        let _ = detailContentRefreshTick
        if isIPad && horizontalSizeClass == .regular {
            iPadImmersiveDetailLayout
        } else {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        heroImageSection
                        contentContainer
                    }
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ScrollOffsetPreferenceKey.self,
                                value: -geo.frame(in: .named("mediaDetailScroll")).origin.y
                            )
                        }
                    )
                    .heroBannerBleed(
                        color: ExperimentalFeatureState.isEnabledAtLaunch ? mediaDetailHeroBleedColor : nil,
                        heroHeight: headerHeight,
                        tail: mediaDetailHeroBleedTail,
                        strength: mediaDetailHeroBleedStrength
                    )
                }
                .coordinateSpace(name: "mediaDetailScroll")
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { newOffset in
                    guard abs(scrollOffset - newOffset) >= scrollOffsetUpdateThreshold else { return }
                    scrollOffset = newOffset
                }
                .onChange(of: notificationEpisodeScrollGeneration) { _ in
                    withAnimation(.easeInOut(duration: 0.38)) {
                        if let selectedEpisodeForSearch {
                            proxy.scrollTo(
                                MediaDetailEpisodeAnchor.id(for: selectedEpisodeForSearch),
                                anchor: .center
                            )
                        } else {
                            proxy.scrollTo(Self.notificationEpisodesAnchor, anchor: .top)
                        }
                    }
                }
            }
        }
    }

    private var iPadImmersiveSecondaryElements: [MediaDetailElement] {
        visibleMediaDetailElements.filter {
            $0 != .actions && $0 != .overview && $0 != .details && $0 != .episodes
        }
    }

    private var showsIPadImmersiveEpisodes: Bool {
        !searchResult.isMovie && visibleMediaDetailElements.contains(.episodes)
    }

    @ViewBuilder
    private var iPadImmersiveDetailLayout: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                iPadImmersiveBackdrop(proxy: proxy)

                ScrollViewReader { scrollProxy in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 24) {
                            Color.clear
                                .frame(height: max(150, proxy.size.height * 0.16))

                            iPadImmersiveHeroCard

                            if showsIPadImmersiveEpisodes {
                                episodesSection
                                    .id(Self.notificationEpisodesAnchor)
                            }

                            if !iPadImmersiveSecondaryElements.isEmpty {
                                VStack(alignment: .leading, spacing: max(20, designMetrics.sectionSpacing * 0.68)) {
                                    ForEach(iPadImmersiveSecondaryElements) { element in
                                        mediaDetailElementView(element)
                                    }
                                }
                                .frame(maxWidth: 900, alignment: .leading)
                            }

                            Spacer(minLength: max(48, proxy.safeAreaInsets.bottom + 24))
                        }
                        .padding(.leading, max(32, proxy.safeAreaInsets.leading + 28))
                        .padding(.trailing, max(28, proxy.safeAreaInsets.trailing + 28))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: notificationEpisodeScrollGeneration) { _ in
                        withAnimation(.easeInOut(duration: 0.38)) {
                            if let selectedEpisodeForSearch {
                                scrollProxy.scrollTo(
                                    MediaDetailEpisodeAnchor.id(for: selectedEpisodeForSearch),
                                    anchor: .center
                                )
                            } else {
                                scrollProxy.scrollTo(Self.notificationEpisodesAnchor, anchor: .top)
                            }
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func iPadImmersiveBackdrop(proxy: GeometryProxy) -> some View {
        EclipseTheme.shared.backgroundBase
            .ignoresSafeArea()

        KFImage(URL(string: detailHeroImageURL ?? ""))
            .placeholder {
                Rectangle()
                    .fill(EclipseTheme.shared.backgroundBase)
            }
            .onSuccess { result in
                ambientColor = Color.ambientColor(from: result.image)
            }
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .ignoresSafeArea()

        LinearGradient(
            stops: [
                .init(color: Color.black.opacity(0.08), location: 0.00),
                .init(color: Color.black.opacity(0.14), location: 0.24),
                .init(color: heroBlendColor.opacity(0.42), location: 0.56),
                .init(color: heroBlendColor.opacity(0.80), location: 0.76),
                .init(color: EclipseTheme.shared.backgroundBase.opacity(0.96), location: 1.00)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()

        LinearGradient(
            stops: [
                .init(color: Color.black.opacity(0.72), location: 0.00),
                .init(color: Color.black.opacity(0.42), location: 0.34),
                .init(color: Color.black.opacity(0.12), location: 0.66),
                .init(color: .clear, location: 1.00)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: min(proxy.size.width * 0.72, 900))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var iPadImmersiveHeroCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            iPadImmersiveTitle

            if shouldShowHeroDetails {
                iPadImmersiveMetadata
            }

            if shouldShowHeroOverview, let overviewText = currentOverviewText {
                Text(overviewText)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(showFullSynopsis ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard overviewText.count > 180 else { return }
                        withAnimation(.easeInOut(duration: 0.28)) {
                            showFullSynopsis.toggle()
                        }
                    }
            }

            if shouldShowHeroActions {
                iPadImmersiveActions
            }

            if shouldShowHeroDetails {
                detailRatingChips
                    .padding(.horizontal, -36)
            }
        }
        .padding(22)
        .frame(maxWidth: 620, alignment: .leading)
        .applyLiquidGlassBackground(
            cornerRadius: 28,
            fallbackFill: Color.black.opacity(0.22),
            fallbackMaterial: .ultraThinMaterial,
            glassTint: Color.white.opacity(0.025)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.11), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var iPadImmersiveTitle: some View {
        if mediaDetailTitleArtworkEnabled, let logoURL {
            KFImage(URL(string: logoURL))
                .placeholder {
                    iPadImmersiveTitleText
                }
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 380, maxHeight: 118, alignment: .leading)
                .shadow(color: .black.opacity(0.48), radius: 8, x: 0, y: 4)
        } else {
            iPadImmersiveTitleText
        }
    }

    private var iPadImmersiveTitleText: some View {
        Text(searchResult.displayTitle)
            .font(.system(size: 44, weight: .heavy))
            .foregroundColor(.white)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .shadow(color: .black.opacity(0.55), radius: 7, x: 0, y: 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var iPadImmersiveMetadata: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(Array(detailMetadataValues.enumerated()), id: \.offset) { _, value in
                    iPadImmersiveMetadataChip(value)
                }
            }
            .padding(.horizontal, 1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func iPadImmersiveMetadataChip(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundColor(.white.opacity(0.90))
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(Color.white.opacity(0.09), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            }
    }

    @ViewBuilder
    private var iPadImmersiveActions: some View {
        HStack(spacing: 10) {
            Button(action: searchInServices) {
                Label(
                    canUseMainPlayButton ? playButtonText : "No Services",
                    systemImage: canUseMainPlayButton ? "play.fill" : "exclamationmark.triangle"
                )
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
            }
            .buttonStyle(.plain)
            .disabled(!canUseMainPlayButton)
            .applyLiquidGlassBackground(
                cornerRadius: 14,
                fallbackFill: canUseMainPlayButton ? Color.white.opacity(0.11) : Color.white.opacity(0.05),
                fallbackMaterial: .thinMaterial,
                glassTint: canUseMainPlayButton ? Color.white.opacity(0.025) : nil
            )

            iPadImmersiveActionButton(
                systemName: isBookmarked ? "heart.fill" : "heart",
                accessibilityTitle: "Bookmark",
                tint: isBookmarked ? accentManager.currentAccentColor : .white,
                action: toggleBookmark
            )

            iPadImmersiveActionButton(
                systemName: "rectangle.stack.badge.plus",
                accessibilityTitle: "Add to Collection"
            ) {
                showingAddToCollection = true
            }

#if !os(tvOS)
            if !searchResult.isMovie {
                iPadImmersiveActionButton(
                    systemName: isFollowingLocalNotifications ? "bell.fill" : "bell",
                    accessibilityTitle: "Notifications",
                    tint: isFollowingLocalNotifications ? accentManager.currentAccentColor : .white
                ) {
                    showingNotificationOptions = true
                }
            }

            if searchResult.isMovie {
                iPadImmersiveActionButton(
                    systemName: downloadButtonIcon,
                    accessibilityTitle: "Download",
                    tint: downloadButtonColor,
                    action: downloadInServices
                )
                .disabled(!hasActiveSources || isCurrentlyDownloading)
            }
#endif
        }
    }

    private func iPadImmersiveActionButton(
        systemName: String,
        accessibilityTitle: String,
        tint: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 19, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .applyLiquidGlassBackground(
            cornerRadius: 14,
            fallbackFill: Color.white.opacity(0.08),
            fallbackMaterial: .thinMaterial,
            glassTint: Color.white.opacity(0.02)
        )
        .accessibilityLabel(accessibilityTitle)
    }

    private func refreshDetailContentLayout(reason: String) {
        guard hasLoadedContent, !isLoading else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard hasLoadedContent, !isLoading else { return }
            detailContentRefreshTick += 1
        }
    }

    private func handleMediaDetailLayoutPreferenceChange() {
        refreshDetailContentLayout(reason: "media-detail-layout-preferences")
        if hasLoadedContent {
            startExperimentalExtrasLoadIfNeeded()
            startSimilarTitlesLoadIfNeeded()
        }
    }

    private func playerCloseNotificationMatchesDetail(_ notification: Notification) -> Bool {
        guard let tmdbId = notification.userInfo?["tmdbId"] as? Int else {
            return true
        }
        return tmdbId == searchResult.id
    }
    
    @ViewBuilder
    private var heroImageSection: some View {
        if ExperimentalFeatureState.isEnabledAtLaunch {
            // Top-anchor the hero content over the lower image so that expanding the synopsis grows the section DOWNWARD
            // (pushing the.
            ZStack(alignment: .top) {
                heroBackdrop
                    .frame(height: headerHeight)

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                        .frame(height: headerHeight * (isIPad ? 0.12 : 0.40))
                    headerSection
                        .frame(maxWidth: .infinity, alignment: isIPad ? .trailing : .center)
                        .padding(.horizontal, isIPad ? 48 : 0)
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        } else {
            ZStack(alignment: .bottom) {
                heroBackdrop
                headerSection
            }
        }
    }

    private var heroBackdrop: some View {
        ZStack(alignment: .bottom) {
            StretchyHeaderView(
                backdropURL: detailHeroImageURL,
                isMovie: searchResult.isMovie,
                headerHeight: headerHeight,
                minHeaderHeight: minHeaderHeight,
                onAmbientColorExtracted: { color in
                    ambientColor = color
                }
            )

            gradientOverlay
        }
    }
    
    @ViewBuilder
    private var contentContainer: some View {
        VStack(spacing: 0) {
            VStack(
                alignment: .leading,
                spacing: ExperimentalFeatureState.isEnabledAtLaunch ? max(18, designMetrics.sectionSpacing * 0.62) : 16
            ) {
                ForEach(visibleBodyMediaDetailElements) { element in
                    mediaDetailElementView(element)
                }
                
                Spacer(minLength: 50)
            }
            .frame(maxWidth: isIPad ? 900 : .infinity)
            .background(
                detailContentBackground
            )
            .padding(.top, ExperimentalFeatureState.isEnabledAtLaunch ? max(18, designMetrics.sectionSpacing * 0.45) : 0)
            .padding(.bottom, ExperimentalFeatureState.isEnabledAtLaunch ? 28 : 0)
        }
    }

    @ViewBuilder
    private var detailContentBackground: some View {
        if ExperimentalFeatureState.isEnabledAtLaunch {
            Color.clear
        } else if theme.atmosphereStyle == .solid {
            atmosphereColor
        } else {
            LinearGradient(
                colors: [ambientColor, Color.clear, EclipseTheme.shared.backgroundBase],
                startPoint: .top,
                endPoint: UnitPoint(x: 0.5, y: 0.34)
            )
        }
    }
    
    @ViewBuilder
    private var gradientOverlay: some View {
        if ExperimentalFeatureState.isEnabledAtLaunch {
            // Bottom fade only - the artwork stays clean to the top edge (the back
            // and top-right buttons carry their own backings), so there is no dark
            // "box" behind the status bar.
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: heroBlendColor.opacity(0.30), location: 0.32),
                    .init(color: heroBlendColor.opacity(0.64), location: 0.60),
                    .init(color: heroBlendColor.opacity(0.90), location: 0.84),
                    .init(color: heroBlendColor.opacity(1.0), location: 1.0)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: max(designMetrics.heroBottomFadeHeight + 150, isIPad ? 680 : 570))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
        } else {
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: atmosphereColor.opacity(theme.atmosphereStyle == .solid ? 0.0 : 0.0), location: 0.0),
                    .init(color: atmosphereColor.opacity(theme.atmosphereStyle == .solid ? 0.25 : 0.16), location: 0.20),
                    .init(color: atmosphereColor.opacity(theme.atmosphereStyle == .solid ? 0.62 : 0.42), location: 0.62),
                    .init(color: atmosphereColor.opacity(1), location: 1.0)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 0))
        }
    }

    private var detailHeroImageURL: String? {
#if !os(tvOS)
        if ExperimentalFeatureState.isEnabledAtLaunch && !isIPad && !isTvOS {
            if searchResult.isMovie {
                return movieDetail?.fullPosterURL
                    ?? searchResult.fullPosterURL
                    ?? movieDetail?.fullBackdropURL
                    ?? searchResult.fullBackdropURL
            }
            return tvShowDetail?.fullPosterURL
                ?? searchResult.fullPosterURL
                ?? tvShowDetail?.fullBackdropURL
                ?? searchResult.fullBackdropURL
        }
#endif

        if searchResult.isMovie {
            return movieDetail?.fullBackdropURL ?? searchResult.fullBackdropURL ?? movieDetail?.fullPosterURL ?? searchResult.fullPosterURL
        }
        return tvShowDetail?.fullBackdropURL ?? searchResult.fullBackdropURL ?? tvShowDetail?.fullPosterURL ?? searchResult.fullPosterURL
    }
    
    @ViewBuilder
    private var headerSection: some View {
        if ExperimentalFeatureState.isEnabledAtLaunch {
            experimentalHeaderSection
        } else {
            legacyHeaderSection
        }
    }

    @ViewBuilder
    private var legacyHeaderSection: some View {
        VStack(alignment: .center, spacing: 8) {
            titleArtwork
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 10)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var experimentalHeaderSection: some View {
        VStack(alignment: .center, spacing: isIPad ? 13 : 10) {
            titleArtwork

            if shouldShowHeroDetails, let metadata = detailMetadataLine {
                Text(metadata)
                    .font(.system(
                        size: isIPad ? 20 : (showFullMetadata ? 17 * 0.72 : 17),
                        weight: .semibold
                    ))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(showFullMetadata ? nil : 1)
                    .minimumScaleFactor(showFullMetadata ? 1 : 0.72)
                    .fixedSize(horizontal: false, vertical: showFullMetadata)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, isIPad ? 36 : 20)
                    .shadow(color: .black.opacity(0.70), radius: 8, x: 0, y: 3)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            showFullMetadata.toggle()
                        }
                    }
                    .accessibilityHint("Tap to expand or collapse media details")
            }

            if shouldShowHeroActions {
                experimentalPlayAndBookmarkSection
                    .padding(.top, isIPad ? 6 : 2)
            }

            if shouldShowHeroOverview {
                experimentalHeroSynopsisSection
                    .padding(.top, isIPad ? 2 : 0)
            }

            if shouldShowHeroDetails {
                detailRatingChips
                    .padding(.top, isIPad ? 2 : 0)
            }
        }
        .frame(maxWidth: isIPad ? 520 : .infinity, alignment: .center)
        .padding(.top, isIPad ? 24 : 0)
        .padding(.bottom, isIPad ? 24 : 34)
        .background {
            if isIPad {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
            }
        }
    }

    @ViewBuilder
    private var titleArtwork: some View {
        if !mediaDetailTitleArtworkEnabled {
            EmptyView()
        } else if let logoURL = logoURL {
            KFImage(URL(string: logoURL))
                .placeholder {
                    titleText
                }
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(
                    maxWidth: ExperimentalFeatureState.isEnabledAtLaunch ? (isIPad ? 420 : 334) : (isIPad ? 400 : 280),
                    maxHeight: ExperimentalFeatureState.isEnabledAtLaunch ? 132 : (isIPad ? 140 : 100)
                )
                .shadow(color: .black.opacity(0.52), radius: 6, x: 0, y: 3)
                .padding(.horizontal, ExperimentalFeatureState.isEnabledAtLaunch ? (isIPad ? 36 : 26) : 0)
        } else {
            titleText
                .padding(.horizontal, ExperimentalFeatureState.isEnabledAtLaunch ? (isIPad ? 36 : 26) : 0)
        }
    }
    
    @ViewBuilder
    private var titleText: some View {
        Text(searchResult.displayTitle)
            .font(ExperimentalFeatureState.isEnabledAtLaunch ? .system(size: isIPad ? 44 : 40, weight: .heavy) : .largeTitle)
            .fontWeight(.bold)
            .foregroundColor(.white)
            .lineLimit(3)
            .multilineTextAlignment(.center)
            .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var detailMetadataLine: String? {
        detailMetadataValues.isEmpty ? nil : detailMetadataValues.joined(separator: " \u{00B7} ")
    }

    private var detailMetadataValues: [String] {
        var values: [String] = []

        if let detailDate, !detailDate.isEmpty {
            values.append(detailDate)
        }

        if searchResult.isMovie {
            if let runtime = movieDetail?.runtime, runtime > 0,
               let runtimeText = movieDetail?.runtimeFormatted,
               !runtimeText.isEmpty {
                values.append(runtimeText)
            }
            if let status = movieDetail?.status, !status.isEmpty {
                values.append(status)
            }
        } else if let tvShowDetail {
            if let episodes = tvShowDetail.numberOfEpisodes, episodes > 0 {
                values.append("\(episodes) EPS")
            }
            if let status = tvShowDetail.status, !status.isEmpty {
                values.append(status)
            }
        }

        values.append(contentsOf: detailGenres.prefix(5).map(\.name))
        return values
    }

    private var detailDate: String? {
        let rawDate = searchResult.isMovie
            ? (movieDetail?.releaseDate ?? searchResult.releaseDate)
            : (tvShowDetail?.firstAirDate ?? searchResult.firstAirDate)
        guard let rawDate, !rawDate.isEmpty else { return nil }
        return String(rawDate.prefix(10))
    }

    private var detailGenres: [TMDBGenre] {
        searchResult.isMovie ? (movieDetail?.genres ?? []) : (tvShowDetail?.genres ?? [])
    }

    private static func mergedAnimeDetailGenres(
        tmdbGenres: [TMDBGenre],
        animeGenres: [String]
    ) -> [TMDBGenre] {
        func normalized(_ value: String) -> String {
            value.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .joined()
        }

        let tmdbKeys = Set(tmdbGenres.map { normalized($0.name) })
        func isAlreadyRepresented(_ key: String) -> Bool {
            if tmdbKeys.contains(key) { return true }
            if ["action", "adventure"].contains(key), tmdbKeys.contains("actionadventure") {
                return true
            }
            if ["scifi", "fantasy"].contains(key), tmdbKeys.contains("scififantasy") {
                return true
            }
            if ["war", "politics"].contains(key), tmdbKeys.contains("warpolitics") {
                return true
            }
            return false
        }

        var seen = tmdbKeys
        let additions = animeGenres.compactMap { rawValue -> String? in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalized(value)
            guard !value.isEmpty,
                  !key.isEmpty,
                  !isAlreadyRepresented(key),
                  seen.insert(key).inserted else { return nil }
            return value
        }

        // Put the genuinely anime-specific additions first so the compact hero
        // metadata surfaces them instead of hiding them behind TMDB's broad genres.
        let additionalGenres = additions.enumerated().map { index, name in
            TMDBGenre(id: -2_000_000 - index, name: name)
        }
        return additionalGenres + tmdbGenres
    }

    private var detailVoteAverage: Double? {
        searchResult.isMovie ? (movieDetail?.voteAverage ?? searchResult.voteAverage) : (tvShowDetail?.voteAverage ?? searchResult.voteAverage)
    }

    @ViewBuilder
    private var detailRatingChips: some View {
        let tmdbRating = detailVoteAverage
        if (tmdbRating ?? 0) > 0 || traktRating != nil || (isAnimeShow && animeRating?.source == .myAnimeList) {
            HStack(spacing: isIPad ? 15 : 11) {
                if let tmdbRating, tmdbRating > 0 {
                    ratingChip(label: "TMDB", value: String(format: "%.1f", tmdbRating), tint: .cyan)
                }

                if let traktRating {
                    ratingChip(label: "Trakt", value: traktRating.displayText, tint: .red)
                }

                if isAnimeShow, let animeRating, animeRating.source == .myAnimeList {
                    ratingChip(label: "MAL", value: String(format: "%.1f", animeRating.value), tint: .blue)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.74)
            .padding(.horizontal, isIPad ? 36 : 24)
        }
    }

    private func ratingChip(label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: isIPad ? 12 : 10, weight: .heavy))
                .foregroundColor(label == "TMDB" ? .white : tint)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(label == "TMDB" ? tint.opacity(0.42) : tint.opacity(0.22))
                )
            Text(value)
                .font(.system(size: isIPad ? 21 : 18, weight: .semibold))
                .foregroundColor(.white)
        }
        .shadow(color: .black.opacity(0.55), radius: 5, x: 0, y: 2)
    }
    
    @ViewBuilder
    private var synopsisSection: some View {
        if ExperimentalFeatureState.isEnabledAtLaunch {
            experimentalSynopsisSection
        } else {
            legacySynopsisSection
        }
    }

    @ViewBuilder
    private var legacySynopsisSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let overviewText = currentOverviewText {
                Text(showFullSynopsis ? overviewText : String(overviewText.prefix(200)) + (overviewText.count > 200 ? "..." : ""))
                    .font(.body)
                    .foregroundColor(.white)
                    .lineLimit(showFullSynopsis ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal)
#if !os(tvOS)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showFullSynopsis.toggle()
                        }
                    }
#endif
#if os(tvOS)
                if overviewText.count > 200 {
                    tvSynopsisToggleButton
                        .padding(.top, 12)
                }
#endif
            }
        }
    }

    @ViewBuilder
    private var experimentalSynopsisSection: some View {
        if let overviewText = currentOverviewText {
            VStack(spacing: 10) {
                Text(showFullSynopsis ? overviewText : String(overviewText.prefix(240)) + (overviewText.count > 240 ? "..." : ""))
                    .font(.system(size: isIPad ? 21 : 18, weight: .regular))
                    .foregroundColor(.white.opacity(0.90))
                    .lineLimit(showFullSynopsis ? nil : 4)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .shadow(color: .black.opacity(0.42), radius: 6, x: 0, y: 3)
#if !os(tvOS)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showFullSynopsis.toggle()
                        }
                    }
#endif
#if os(tvOS)
                if overviewText.count > 240 {
                    tvSynopsisToggleButton
                }
#endif
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, isIPad ? 80 : 28)
        }
    }

    @ViewBuilder
    private var experimentalHeroSynopsisSection: some View {
        if let overviewText = currentOverviewText {
            // The hero content is top-anchored (see heroImageSection), so expanding
            // here grows the section downward - pushing the cast/episodes below it
            // down, never the title/buttons above it up.
            let canExpand = overviewText.count > 150
#if os(tvOS)
            VStack(spacing: 12) {
                Text(overviewText)
                    .font(.system(size: isIPad ? 21 : 18, weight: .regular))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(showFullSynopsis ? nil : 4)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, isIPad ? 98 : 28)
                    .shadow(color: .black.opacity(0.60), radius: 7, x: 0, y: 3)

                if canExpand {
                    tvSynopsisToggleButton
                }
            }
#else
            Text(overviewText)
                .font(.system(size: isIPad ? 18 : 18, weight: .regular))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(showFullSynopsis ? nil : 4)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, isIPad ? 40 : 28)
                .shadow(color: .black.opacity(0.60), radius: 7, x: 0, y: 3)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard canExpand else { return }
                    withAnimation(.easeInOut(duration: 0.28)) {
                        showFullSynopsis.toggle()
                    }
                }
#endif
        }
    }

#if os(tvOS)
    private var tvSynopsisToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.28)) {
                showFullSynopsis.toggle()
            }
        } label: {
            Label(
                showFullSynopsis ? "Show Less" : "Read More",
                systemImage: showFullSynopsis ? "chevron.up" : "chevron.down"
            )
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
#endif

    private var currentOverviewText: String? {
        let trimmedSynopsis = synopsis.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSynopsis.isEmpty {
            return trimmedSynopsis
        }

        let overview = searchResult.isMovie ? movieDetail?.overview : tvShowDetail?.overview
        let trimmedOverview = overview?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedOverview, !trimmedOverview.isEmpty else { return nil }
        return trimmedOverview
    }
    
    @ViewBuilder
    private var playAndBookmarkSection: some View {
        if ExperimentalFeatureState.isEnabledAtLaunch {
            experimentalPlayAndBookmarkSection
        } else {
            legacyPlayAndBookmarkSection
        }
    }

    @ViewBuilder
    private var legacyPlayAndBookmarkSection: some View {
        HStack(spacing: 8) {
            Button(action: {
                searchInServices()
            }) {
                HStack {
                    Image(systemName: canUseMainPlayButton ? "play.fill" : "exclamationmark.triangle")
                    
                    Text(canUseMainPlayButton ? playButtonText : "No Services")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .padding(.horizontal, 25)
                .applyLiquidGlassBackground(
                    cornerRadius: 12,
                    fallbackFill: canUseMainPlayButton ? Color.black.opacity(0.2) : Color.gray.opacity(0.3),
                    fallbackMaterial: canUseMainPlayButton ? .ultraThinMaterial : .thinMaterial,
                    glassTint: canUseMainPlayButton ? nil : Color.gray.opacity(0.3)
                )
                .foregroundColor(canUseMainPlayButton ? .white : .secondary)
                .cornerRadius(8)
            }
            .disabled(!canUseMainPlayButton)
            
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
            
#if !os(tvOS)
            if !searchResult.isMovie {
                Button {
                    showingNotificationOptions = true
                } label: {
                    Image(systemName: isFollowingLocalNotifications ? "bell.fill" : "bell")
                        .font(.title2)
                        .frame(width: 42, height: 42)
                        .applyLiquidGlassBackground(cornerRadius: 12)
                        .foregroundColor(isFollowingLocalNotifications ? accentManager.currentAccentColor : .white)
                        .cornerRadius(8)
                }
                .accessibilityLabel("Notifications")
                .accessibilityValue(isFollowingLocalNotifications ? "Following" : "Not following")
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
#endif
            
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
    private var experimentalPlayAndBookmarkSection: some View {
        VStack(spacing: isIPad ? 18 : 15) {
            Button(action: {
                searchInServices()
            }) {
                Text(canUseMainPlayButton ? playButtonText : "No Services")
                    .font(.system(size: isIPad ? 25 : 22, weight: .bold))
                    .foregroundColor(canUseMainPlayButton ? .black : .white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                    .frame(maxWidth: .infinity)
                    .frame(height: isIPad ? 58 : 52)
                    .background(
                        RoundedRectangle(cornerRadius: isIPad ? 20 : 17, style: .continuous)
                            .fill(canUseMainPlayButton ? Color.white.opacity(0.72) : Color.white.opacity(0.16))
                            .background(
                                RoundedRectangle(cornerRadius: isIPad ? 20 : 17, style: .continuous)
                                    .fill(.ultraThinMaterial)
                                    .opacity(0.72)
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: isIPad ? 20 : 17, style: .continuous)
                            .stroke(Color.white.opacity(0.32), lineWidth: 1)
                    )
            }
#if os(tvOS)
            .buttonStyle(.card)
            .accessibilityLabel(canUseMainPlayButton ? playButtonText : "No playable source")
            .accessibilityHint("Finds a stream and starts playback.")
#else
            .buttonStyle(PlainButtonStyle())
#endif
            .disabled(!canUseMainPlayButton)

            HStack(spacing: isIPad ? 30 : 22) {
                experimentalActionButton(
                    systemName: "rectangle.stack.badge.plus",
                    foregroundColor: .white,
                    title: "Add to Collection",
                    hint: "Opens the collection picker."
                ) {
                    showingAddToCollection = true
                }

                experimentalActionButton(
                    systemName: isBookmarked ? "heart.fill" : "heart",
                    foregroundColor: .white,
                    title: "Bookmark",
                    hint: "Adds or removes this title from Bookmarks.",
                    selectionState: isBookmarked
                ) {
                    toggleBookmark()
                }

#if !os(tvOS)
                if !searchResult.isMovie {
                    experimentalActionButton(
                        systemName: isFollowingLocalNotifications ? "bell.fill" : "bell",
                        foregroundColor: isFollowingLocalNotifications ? accentManager.currentAccentColor : .white,
                        title: "Notifications",
                        hint: "Choose episode and future-season alerts.",
                        selectionState: isFollowingLocalNotifications
                    ) {
                        showingNotificationOptions = true
                    }
                }

                if searchResult.isMovie {
                    experimentalActionButton(
                        systemName: downloadButtonIcon,
                        foregroundColor: downloadButtonColor,
                        title: "Download",
                        hint: "Finds a downloadable stream."
                    ) {
                        downloadInServices()
                    }
                    .disabled(!hasActiveSources || isCurrentlyDownloading)
                }
#endif
            }
        }
        .padding(.horizontal, isIPad ? 36 : 28)
    }

    private func experimentalActionButton(
        systemName: String,
        foregroundColor: Color,
        title: String,
        hint: String,
        selectionState: Bool? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: isIPad ? 26 : 22, weight: .semibold))
                .foregroundColor(foregroundColor)
                .frame(width: isIPad ? 54 : 48, height: isIPad ? 54 : 48)
                .shadow(color: .black.opacity(0.45), radius: 6, x: 0, y: 2)
                .contentShape(Circle())
        }
#if os(tvOS)
        .buttonStyle(.card)
#else
        .buttonStyle(PlainButtonStyle())
#endif
        .accessibilityLabel(title)
        .accessibilityValue(selectionState.map { $0 ? "Selected" : "Not selected" } ?? "")
        .accessibilityHint(hint)
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
                specialEpisodeContext: $selectedSpecialEpisodeContext,
                seasonSelectorInsertedContent: AnyView(specialsOVASection),
                hasSpecialEpisodeChoices: !animeSpecialEntries.isEmpty,
                animeEpisodes: anilistEpisodes,
                animeEpisodeContextIndex: AnimeEpisodeContextIndex(episodes: anilistEpisodes ?? []),
                animeSeasonTitles: animeSeasonTitles,
                animeSeasonRomajiTitles: animeSeasonRomajiTitles,
                animeSeasonAniListIds: animeSeasonAniListIds,
                animeSeasonKitsuIds: animeSeasonKitsuIds,
                nextEpisodeNotificationRoute: nextEpisodeNotificationRoute,
                showsMetadataDetails: false,
                showsInsertedContent: false,
                defersInitialSeasonLoad: initialNotificationSelection.map {
                    handledNotificationSelectionID != $0.id
                } ?? false,
                tmdbService: tmdbService
            ) {
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func mediaDetailElementView(_ element: MediaDetailElement) -> some View {
        switch element {
        case .actions:
            playAndBookmarkSection
        case .overview:
            synopsisSection
        case .details:
            if searchResult.isMovie {
                MovieDetailsSection(
                    movie: movieDetail,
                    compactHeroMetadata: ExperimentalFeatureState.isEnabledAtLaunch
                )
            } else {
                TVShowDetailsSection(
                    tvShow: tvShowDetail,
                    ratingOverride: isAnimeShow ? animeRating?.displayText : nil,
                    compactHeroMetadata: ExperimentalFeatureState.isEnabledAtLaunch
                )
            }
        case .cast:
            if !castMembers.isEmpty {
                castSection
            }
        case .similarTitles:
            similarTitlesSection
        case .ratingNotes:
            StarRatingView(
                mediaId: searchResult.id,
                isAnime: isAnimeShow,
                usesIPadAtmosphereStyle: ExperimentalFeatureState.isEnabledAtLaunch && isIPad
            )
        case .traktComments:
            traktCommentsSection
        case .episodes:
            episodesSection
                .id(Self.notificationEpisodesAnchor)
        case .stills:
            experimentalStillsSection
        case .trailers:
            experimentalTrailersSection
        }
    }

    private func originalTitleForSearchSheet(_ episode: TMDBEpisode?) -> String? {
        guard isAnimeShow,
              let seasonNumber = episode?.seasonNumber,
              let seasonRomaji = animeSeasonRomajiTitles[seasonNumber],
              !seasonRomaji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return romajiTitle
        }
        return seasonRomaji
    }

    private func playbackContextForSearchSheet(_ episode: TMDBEpisode?) -> EpisodePlaybackContext? {
        guard isAnimeShow, let episode else { return nil }

        // Performance Mode only changes Home catalog sourcing. The separate
        // detail-traversal toggle is the setting that intentionally gives up
        // AniList/Kitsu episode identity and absolute-number mappings.
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

        let aniEpisode = anilistEpisodes?.first {
            $0.seasonNumber == episode.seasonNumber && $0.number == episode.episodeNumber
        }
        let absoluteEpisodeNumber = animeAbsoluteEpisodeNumber(for: episode)

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
            animeSeasonEpisodeCount: animeSeasonEpisodeCount(for: episode.seasonNumber),
            isSpecial: false,
            titleOnlySearch: false
        )
    }

    private func exactWatchTogetherPlaybackContext(
        for episode: TMDBEpisode?
    ) -> EpisodePlaybackContext? {
        guard let context = nextEpisodePlaybackContextOverride ?? watchTogetherPlaybackContextOverride,
              let episode,
              context.localSeasonNumber == episode.seasonNumber,
              context.localEpisodeNumber == episode.episodeNumber else {
            return nil
        }
        return context
    }

    private func animeAbsoluteEpisodeNumber(for episode: TMDBEpisode) -> Int? {
        guard let anilistEpisodes else { return nil }

        var absolute = 0
        for aniEpisode in anilistEpisodes.sorted(by: episodeSort) {
            absolute += 1
            if aniEpisode.seasonNumber == episode.seasonNumber && aniEpisode.number == episode.episodeNumber {
                return absolute
            }
        }

        return nil
    }

    private func animeSeasonEpisodeCount(for seasonNumber: Int) -> Int? {
        guard let anilistEpisodes else { return nil }
        let count = anilistEpisodes.filter { $0.seasonNumber == seasonNumber }.count
        return count > 0 ? count : nil
    }
    
    private func toggleBookmark() {
        withAnimation(.easeInOut(duration: 0.2)) {
            libraryManager.toggleBookmark(for: searchResult)
            updateBookmarkStatus()
        }
    }

    @ViewBuilder
    private var experimentalStillsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            experimentalSectionTitle("Stills", isLoading: isLoadingExperimentalExtras && detailStills.isEmpty)

            if detailStills.isEmpty && !isLoadingExperimentalExtras {
                experimentalEmptyCard(title: nil, message: "No stills available")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(Array(detailStills.prefix(10).enumerated()), id: \.offset) { _, still in
                            ZStack(alignment: .topTrailing) {
                                KFImage(URL(string: still.fullURL))
                                    .placeholder {
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .fill(Color.white.opacity(0.08))
                                    }
                                    .resizable()
                                    .aspectRatio(16/9, contentMode: .fill)
                                    .frame(width: isIPad ? 330 : 250, height: isIPad ? 186 : 142)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                    )

#if os(iOS)
                                Button {
                                    saveStillToPhotos(still)
                                } label: {
                                    Group {
                                        if savingStillURL == still.fullURL {
                                            ProgressView()
                                                .tint(.white)
                                        } else {
                                            Image(systemName: "square.and.arrow.down")
                                        }
                                    }
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(width: 38, height: 38)
                                    .background(.ultraThinMaterial, in: Circle())
                                }
                                .buttonStyle(.plain)
                                .disabled(savingStillURL != nil)
                                .padding(10)
                                .accessibilityLabel(savingStillURL == still.fullURL ? "Saving still" : "Save still to Photos")
#endif
                            }
#if os(iOS)
                            .contextMenu {
                                Button {
                                    saveStillToPhotos(still)
                                } label: {
                                    Label("Save to Photos", systemImage: "square.and.arrow.down")
                                }
                                .disabled(savingStillURL != nil)
                            }
#endif
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

#if os(iOS)
    @MainActor
    private func saveStillToPhotos(_ still: TMDBImage) {
        guard savingStillURL == nil else { return }
        let stillURLString = still.fullURL
        savingStillURL = stillURLString

        Task {
            do {
                let authorization = await photoAddAuthorizationStatus()
                guard authorization == .authorized || authorization == .limited else {
                    savingStillURL = nil
                    stillPhotoSaveNotice = StillPhotoSaveNotice(
                        title: "Photos Access Needed",
                        message: "Allow Eclipse to add photos in Settings, then try saving this still again.",
                        offersSettings: authorization == .denied || authorization == .restricted
                    )
                    return
                }

                guard let url = URL(string: stillURLString) else {
                    throw StillPhotoSaveError.invalidURL
                }
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw StillPhotoSaveError.invalidResponse
                }
                guard (200...299).contains(httpResponse.statusCode) else {
                    throw StillPhotoSaveError.httpStatus(httpResponse.statusCode)
                }
                let mimeType = response.mimeType?.lowercased()
                guard !data.isEmpty,
                      mimeType == nil || mimeType?.hasPrefix("image/") == true else {
                    throw StillPhotoSaveError.invalidResponse
                }

                try await addStillDataToPhotos(data)
                savingStillURL = nil
                stillPhotoSaveNotice = StillPhotoSaveNotice(
                    title: "Saved to Photos",
                    message: "The full-resolution still was added to your photo library.",
                    offersSettings: false
                )
            } catch {
                savingStillURL = nil
                stillPhotoSaveNotice = StillPhotoSaveNotice(
                    title: "Couldn’t Save Still",
                    message: error.localizedDescription,
                    offersSettings: false
                )
                Logger.shared.log("Failed to save TMDB still to Photos: \(error.localizedDescription)", type: "Error")
            }
        }
    }

    private func photoAddAuthorizationStatus() async -> PHAuthorizationStatus {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard currentStatus == .notDetermined else { return currentStatus }

        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func addStillDataToPhotos(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: StillPhotoSaveError.invalidResponse)
                }
            }
        }
    }
#endif

    @ViewBuilder
    private var experimentalTrailersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            experimentalSectionTitle("Trailers", isLoading: isLoadingExperimentalExtras && detailTrailers.isEmpty)

            if detailTrailers.isEmpty && !isLoadingExperimentalExtras {
                experimentalEmptyCard(title: nil, message: "No trailers available")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(Array(detailTrailers.prefix(8).enumerated()), id: \.offset) { _, trailer in
                            if let destination = trailer.playbackURL {
                                Link(destination: destination) {
                                    experimentalTrailerCard(trailer)
                                }
                                .buttonStyle(.plain)
                            } else {
                                experimentalTrailerCard(trailer)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    private func experimentalTrailerCard(_ trailer: TMDBVideo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if let thumbnailURL = trailer.thumbnailURL {
                    KFImage(thumbnailURL)
                        .placeholder {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        }
                        .resizable()
                        .aspectRatio(16/9, contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                }

                Circle()
                    .fill(Color.black.opacity(0.48))
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: "play.fill")
                            .font(.headline)
                            .foregroundColor(.white)
                            .offset(x: 1)
                    )
            }
            .frame(width: isIPad ? 330 : 250, height: isIPad ? 186 : 142)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )

            Text(trailer.name)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(width: isIPad ? 330 : 250, alignment: .leading)
        }
    }

    private func experimentalSectionTitle(_ title: String, isLoading: Bool) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)

            if isLoading {
                EclipseLoadingIndicator()
                    .scaleEffect(0.75)
            }

            Spacer()
        }
        .padding(.horizontal)
    }

    private func experimentalEmptyCard(title: String?, message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
            }

            HStack(spacing: 12) {
                Image(systemName: "rectangle.slash")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.5))

                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.62))

                Spacer()
            }
            .padding(16)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var similarTitlesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            experimentalSectionTitle(similarTitlesSectionTitle, isLoading: isLoadingSimilarTitles && similarTitles.isEmpty)

            if similarTitles.isEmpty && !isLoadingSimilarTitles {
                experimentalEmptyCard(
                    title: nil,
                    message: similarTitlesLoadFailed ? "Similar titles unavailable" : "No similar titles available"
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(Array(similarTitles.prefix(15)), id: \.stableIdentity) { item in
                            NavigationLink(destination: MediaDetailView(searchResult: item)) {
                                similarTitleCard(item)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.top, 8)
    }

    private var similarTitlesSectionTitle: String {
        searchResult.isMovie ? "Similar Movies" : "Similar Shows"
    }

    private func similarTitleCard(_ item: TMDBSearchResult) -> some View {
        let posterWidth: CGFloat = isTvOS ? 180 : (isIPad ? 132 : 104)
        let posterHeight: CGFloat = posterWidth * 1.5

        return VStack(alignment: .leading, spacing: 8) {
            KFImage(URL(string: item.fullPosterURL ?? ""))
                .setProcessor(DownsamplingImageProcessor(size: homeImageDecodeSize(width: posterWidth, height: posterHeight)))
                .placeholder {
                    FallbackImageView(
                        isMovie: item.isMovie,
                        size: CGSize(width: posterWidth, height: posterHeight)
                    )
                }
                .resizable()
                .aspectRatio(2/3, contentMode: .fill)
                .frame(width: posterWidth, height: posterHeight)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.24), radius: 8, x: 0, y: 4)

            Text(item.displayTitle)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: posterWidth, alignment: .leading)

            if let metadata = similarTitleMetadata(item) {
                Text(metadata)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.58))
                    .lineLimit(1)
                    .frame(width: posterWidth, alignment: .leading)
            }
        }
        .frame(width: posterWidth, alignment: .leading)
    }

    private func similarTitleMetadata(_ item: TMDBSearchResult) -> String? {
        var parts: [String] = []
        if !item.displayDate.isEmpty {
            parts.append(String(item.displayDate.prefix(4)))
        }
        if let voteAverage = item.voteAverage, voteAverage > 0 {
            parts.append(String(format: "%.1f TMDB", voteAverage))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " - ")
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
    private var traktCommentsSection: some View {
        if trackerManager.trackerState.traktCommentsEnabled && (isLoadingTraktComments || !traktComments.isEmpty) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("Trakt Reviews")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)

                    if isLoadingTraktComments {
                        EclipseLoadingIndicator()
                            .scaleEffect(0.75)
                    }

                    Spacer()
                }
                .padding(.horizontal)

                if !traktComments.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(traktComments.prefix(5)) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(item.authorName)
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.white)
                                        .lineLimit(1)

                                    if item.isReview {
                                        Text("Review")
                                            .font(.caption2)
                                            .fontWeight(.medium)
                                            .foregroundColor(.white.opacity(0.75))
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(Color.white.opacity(0.12))
                                            .clipShape(Capsule())
                                    }

                                    Spacer()

                                    Label("\(item.likes)", systemImage: "heart.fill")
                                        .font(.caption2)
                                        .foregroundColor(.white.opacity(0.55))
                                }

                                Text(item.comment)
                                    .font(.subheadline)
                                    .foregroundColor(.white.opacity(0.82))
                                    .lineLimit(6)
                                    .fixedSize(horizontal: false, vertical: true)

                                if let createdAt = formattedTraktDate(item.createdAt) {
                                    Text(createdAt)
                                        .font(.caption2)
                                        .foregroundColor(.white.opacity(0.45))
                                }
                            }
                            .padding(14)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(10)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var specialsOVASection: some View {
        if isAnimeShow && (isLoadingAnimeSpecials || !animeSpecialEntries.isEmpty) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Specials & OVAs")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)

                    if isLoadingAnimeSpecials {
                        EclipseLoadingIndicator()
                            .scaleEffect(0.75)
                            .padding(.leading, 2)
                    } else if !animeSpecialEntries.isEmpty {
                        Text("\(animeSpecialEntries.count)")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.white.opacity(0.85))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: Capsule())
                    }

                    Spacer()
                }
                .padding(.horizontal)

                if !animeSpecialEntries.isEmpty {
                    if useSeasonMenu {
                        specialsOVAMenu
                            .padding(.horizontal)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(animeSpecialEntries) { entry in
                                    specialEntryButton(entry)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private var specialsOVAMenu: some View {
        Menu {
            ForEach(animeSpecialEntries) { entry in
                Button(action: {
                    selectSpecialEntry(entry)
                }) {
                    HStack {
                        Text("\(entry.preferredTitle) (\(entry.formatLabel))")
                        if selectedSpecialEpisodeContext?.id == entry.id {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(selectedSpecialEpisodeContext?.title ?? "Select Special or OVA")
                    .lineLimit(1)

                Spacer()

                Image(systemName: "chevron.down")
                    .font(.caption)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .applyLiquidGlassBackground(cornerRadius: 12)
        }
    }

    @ViewBuilder
    private func specialEntryButton(_ entry: AniListSpecialSearchEntry) -> some View {
        let isSelected = selectedSpecialEpisodeContext?.id == entry.id
        let accent = accentManager.currentAccentColor
        let cardWidth: CGFloat = 96
        let posterHeight: CGFloat = 144

        Button(action: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                selectSpecialEntry(entry)
            }
        }) {
            VStack(spacing: 8) {
                ZStack(alignment: .bottom) {
                    specialPoster(urlString: entry.posterUrl, fallbackText: entry.formatLabel, width: cardWidth, height: posterHeight)

                    // Bottom scrim for badge legibility
                    LinearGradient(
                        colors: [.clear, Color.black.opacity(0.6)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    .frame(width: cardWidth, height: posterHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .allowsHitTesting(false)

                    Text(entry.episodeCount == 1 ? entry.formatLabel : "\(entry.formatLabel) · \(entry.episodeCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 7)
                        .frame(maxWidth: cardWidth - 12)
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

                Text(entry.preferredTitle)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: cardWidth, height: 34, alignment: .top)
                    .foregroundColor(isSelected ? .white : .white.opacity(0.65))
            }
        }
        .buttonStyle(PlainButtonStyle())
    }

    @ViewBuilder
    private func specialPoster(urlString: String?, fallbackText: String, width: CGFloat, height: CGFloat) -> some View {
        if let urlString, let url = URL(string: urlString) {
            KFImage(url)
                .placeholder {
                    specialPosterPlaceholder(fallbackText, width: width, height: height)
                }
                .resizable()
                .aspectRatio(2/3, contentMode: .fill)
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            specialPosterPlaceholder(fallbackText, width: width, height: height)
        }
    }

    private func specialPosterPlaceholder(_ fallbackText: String, width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [accentManager.currentAccentColor.opacity(0.35), Color.black.opacity(0.35)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: width, height: height)
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.title2)
                    Text(fallbackText)
                        .font(.caption2)
                        .fontWeight(.bold)
                        .lineLimit(1)
                }
                .foregroundColor(.white.opacity(0.8))
            )
    }

    private func startAnimeSpecialsLoad(tmdbShowId: Int, fallbackPosterURL: String?, baseAniListIds: [Int] = []) {
        guard isAnimeShow, !searchResult.isMovie else {
            animeSpecialEntries = []
            isLoadingAnimeSpecials = false
            selectedSpecialEpisodeContext = nil
            return
        }
        guard !PerformanceModeSettings.skipsAniListTraversalForAnimeDetails else {
            animeSpecialEntries = []
            isLoadingAnimeSpecials = false
            selectedSpecialEpisodeContext = nil
            Logger.shared.log("MediaDetailView skipped anime specials because AniList traversal is disabled", type: "AniList")
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
                baseAniListIds: baseAniListIds,
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
                        key: PerformanceModeSettings.detailCacheKey(for: self.searchResult.stableIdentity),
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

    private func currentMainPlaybackContextForRecovery() -> EpisodePlaybackContext? {
        let exactWatchTogetherContext = exactWatchTogetherPlaybackContext(for: selectedEpisodeForSearch)
        let isWatchTogetherPlayback = watchTogetherAutoPlay != nil || watchTogetherNextEpisodeAutoPlay
        let isForcedWatchTogetherAnime = isWatchTogetherPlayback && !searchResult.isMovie && (
            watchTogetherAutoPlay?.isAnime == true
                || watchTogetherAutoPlay?.playbackContext?.hasAnimeMediaId == true
                || watchTogetherPlaybackContextOverride?.hasAnimeMediaId == true
                || isAnimeShow
        )
        return isForcedWatchTogetherAnime
            ? exactWatchTogetherContext
            : (exactWatchTogetherContext ?? playbackContextForSearchSheet(selectedEpisodeForSearch))
    }

    private func mainAutoModeTargetToken() -> String {
        AutoModeMediaTargetToken.make(
            tmdbID: searchResult.id,
            isMovie: searchResult.isMovie,
            episode: selectedEpisodeForSearch,
            playbackContext: currentMainPlaybackContextForRecovery()
        )
    }

    private func beginNewMainPlaybackSearchSession() {
        autoModeRetrySession.reset(targetToken: mainAutoModeTargetToken())
        playSheetRequestId = UUID()
    }

    private func beginSpecialSearch(context: SpecialEpisodeListContext, episode: TMDBEpisode?) {
        guard hasActiveSources else { return }

        let playbackContext = episode.map { context.playbackContext(for: $0) }
        let request = AnimeSpecialSearchRequest(
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
        let targetToken = AutoModeMediaTargetToken.make(
            tmdbID: searchResult.id,
            isMovie: false,
            episode: episode,
            playbackContext: playbackContext
        )
        autoModeRetrySession.reset(targetToken: targetToken)
        specialSearchRequest = request
    }

    @MainActor
    private func handleMainAutoModePlaybackFailure(
        _ report: PlaybackFailureReport,
        identity: AutoModePlaybackRecoveryIdentity,
        episode: TMDBEpisode?,
        playbackContext: EpisodePlaybackContext?,
        resolvedTarget: ResolvedNextEpisodeTarget?,
        wasWatchTogetherNext: Bool
    ) {
        guard report.context.autoMode,
              autoModeRetrySession.matches(identity),
              selectedEpisodeForSearch?.seasonNumber == episode?.seasonNumber,
              selectedEpisodeForSearch?.episodeNumber == episode?.episodeNumber else {
            return
        }
        autoModeRetrySession.recordPlaybackFailure(report)
        nextEpisodePlaybackContextOverride = playbackContext
        nextEpisodeResolvedTargetOverride = resolvedTarget
        if wasWatchTogetherNext {
            watchTogetherNextEpisodeAutoPlay = true
        }
        playSheetRequestId = UUID()
        showingSearchResults = true
        Logger.shared.log(
            "MediaDetailView: Auto Mode playback failed source=\(report.context.sourceName) retry=\(autoModeRetrySession.retryCount); reopening remaining sources",
            type: "Player"
        )
    }

    @MainActor
    private func handleSpecialAutoModePlaybackFailure(
        _ report: PlaybackFailureReport,
        identity: AutoModePlaybackRecoveryIdentity,
        request: AnimeSpecialSearchRequest,
        resolvedTarget: ResolvedNextEpisodeTarget?,
        wasWatchTogetherNext: Bool
    ) {
        guard report.context.autoMode,
              autoModeRetrySession.matches(identity),
              selectedEpisodeForSearch?.seasonNumber == request.episode?.seasonNumber,
              selectedEpisodeForSearch?.episodeNumber == request.episode?.episodeNumber else {
            return
        }
        autoModeRetrySession.recordPlaybackFailure(report)
        nextEpisodePlaybackContextOverride = request.playbackContext
        nextEpisodeResolvedTargetOverride = resolvedTarget
        if wasWatchTogetherNext {
            watchTogetherNextEpisodeAutoPlay = true
        }
        specialSearchRequest = request
        Logger.shared.log(
            "MediaDetailView: special Auto Mode playback failed source=\(report.context.sourceName) retry=\(autoModeRetrySession.retryCount); reopening remaining sources",
            type: "Player"
        )
    }

    private func scheduleNextEpisodePresentation(action: @escaping () -> Void) {
        // Invalidate the currently playing target immediately. The delayed sheet presentation
        // may not run for a few tenths of a second, and a late failure from the old player must
        // not reopen that old target during the gap.
        autoModeRetrySession.reset(targetToken: mainAutoModeTargetToken())
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
    }

    private func resolveMainPlayEpisodeTarget() -> MainPlayEpisodeCandidate? {
        let candidates = mainPlayEpisodeCandidates()
        guard !candidates.isEmpty else { return nil }

        let progressByEpisode = episodeProgressByKey()
        let latestWatchedIndex = candidates.indices.last(where: { index in
            guard let progress = progressByEpisode[candidates[index].key] else { return false }
            return isWatchedForMainPlay(progress)
        })

        let inProgressIndices = candidates.indices.filter { index in
            guard let progress = progressByEpisode[candidates[index].key] else { return false }
            return hasResumeProgress(progress)
        }

        let eligibleInProgressIndices: [Int]
        if let latestWatchedIndex {
            eligibleInProgressIndices = inProgressIndices.filter { $0 > latestWatchedIndex }
        } else {
            eligibleInProgressIndices = inProgressIndices
        }

        if let index = eligibleInProgressIndices.last {
            return candidates[index]
        }

        if let latestWatchedIndex {
            let nextIndex = candidates.index(after: latestWatchedIndex)
            if nextIndex < candidates.endIndex {
                return candidates[nextIndex]
            }
        }

        if let index = inProgressIndices.last {
            return candidates[index]
        }

        return candidates.first
    }

    private func mainPlayEpisodeCandidates() -> [MainPlayEpisodeCandidate] {
        if isAnimeShow, let anilistEpisodes, !anilistEpisodes.isEmpty {
            return uniqueMainPlayCandidates(
                anilistEpisodes
                    .sorted(by: episodeSort)
                    .map {
                        MainPlayEpisodeCandidate(
                            key: .init(seasonNumber: $0.seasonNumber, episodeNumber: $0.number),
                            episode: nil
                        )
                    }
            )
        }

        if let tvShowDetail {
            let regularSeasons = tvShowDetail.seasons
                .filter { $0.seasonNumber > 0 }
                .sorted { $0.seasonNumber < $1.seasonNumber }

            var candidates: [MainPlayEpisodeCandidate] = []
            for season in regularSeasons {
                if let loadedSeason = seasonDetail, loadedSeason.seasonNumber == season.seasonNumber {
                    candidates.append(contentsOf: loadedSeason.episodes
                        .sorted { $0.episodeNumber < $1.episodeNumber }
                        .map {
                            MainPlayEpisodeCandidate(
                                key: .init(seasonNumber: $0.seasonNumber, episodeNumber: $0.episodeNumber),
                                episode: $0
                            )
                        }
                    )
                    continue
                }

                guard season.episodeCount > 0 else { continue }
                candidates.append(contentsOf: (1...season.episodeCount).map { episodeNumber in
                    MainPlayEpisodeCandidate(
                        key: .init(seasonNumber: season.seasonNumber, episodeNumber: episodeNumber),
                        episode: nil
                    )
                })
            }

            if !candidates.isEmpty {
                return uniqueMainPlayCandidates(candidates)
            }
        }

        if let seasonDetail {
            return uniqueMainPlayCandidates(
                seasonDetail.episodes
                    .sorted { $0.episodeNumber < $1.episodeNumber }
                    .map {
                        MainPlayEpisodeCandidate(
                            key: .init(seasonNumber: $0.seasonNumber, episodeNumber: $0.episodeNumber),
                            episode: $0
                        )
                    }
            )
        }

        return []
    }

    private func uniqueMainPlayCandidates(_ candidates: [MainPlayEpisodeCandidate]) -> [MainPlayEpisodeCandidate] {
        var indexesByKey: [MainPlayEpisodeKey: Int] = [:]
        var result: [MainPlayEpisodeCandidate] = []

        for candidate in candidates {
            if let index = indexesByKey[candidate.key] {
                if result[index].episode == nil, candidate.episode != nil {
                    result[index] = candidate
                }
                continue
            }

            indexesByKey[candidate.key] = result.count
            result.append(candidate)
        }

        return result
    }

    private func episodeProgressByKey() -> [MainPlayEpisodeKey: EpisodeProgressEntry] {
        let entries = progressManager.getProgressData().episodeProgress
        var result: [MainPlayEpisodeKey: EpisodeProgressEntry] = [:]

        for entry in entries where entry.showId == searchResult.id {
            let key = MainPlayEpisodeKey(seasonNumber: entry.seasonNumber, episodeNumber: entry.episodeNumber)
            if let existing = result[key], existing.lastUpdated >= entry.lastUpdated {
                continue
            }
            result[key] = entry
        }

        return result
    }

    private func isWatchedForMainPlay(_ entry: EpisodeProgressEntry) -> Bool {
        entry.isWatched || entry.progress >= 0.85
    }

    private func hasResumeProgress(_ entry: EpisodeProgressEntry) -> Bool {
        !isWatchedForMainPlay(entry) && (entry.currentTime > 0 || entry.progress > 0)
    }

    @MainActor
    private func startWatchTogetherPlaybackIfReady() {
        guard let target = watchTogetherAutoPlay,
              hasLoadedContent,
              !isLoading,
              !didStartWatchTogetherAutoPlay else {
            return
        }

        if target.playbackContext?.isSpecial == true, isLoadingAnimeSpecials {
            return
        }

        didStartWatchTogetherAutoPlay = true
        Task { @MainActor in
            if searchResult.isMovie {
                selectedEpisodeForSearch = nil
                beginNewMainPlaybackSearchSession()
                showingSearchResults = true
                return
            }

            if target.isAnime || target.playbackContext?.hasAnimeMediaId == true {
                if let failure = target.animeContextFailureReason {
                    failWatchTogetherPlayback(failure)
                    return
                }
                guard let context = target.playbackContext else {
                    failWatchTogetherPlayback("Watch Together could not read the anime episode context, so it stopped instead of guessing a TMDB episode.")
                    return
                }
                if context.isSpecial {
                    guard let anilistID = context.anilistMediaId,
                          let entry = animeSpecialEntries.first(where: { $0.id == anilistID }),
                          let specialContext = SpecialEpisodeListContext(entry: entry, tmdbShowId: searchResult.id),
                          let episode = specialContext.episodes.first(where: {
                              $0.seasonNumber == context.localSeasonNumber
                                  && $0.episodeNumber == context.localEpisodeNumber
                          }) else {
                        failWatchTogetherPlayback("Watch Together could not resolve the exact anime special on this device. It stopped instead of falling back to TMDB.")
                        return
                    }
                    watchTogetherPlaybackContextOverride = context
                    selectedSpecialEpisodeContext = specialContext
                    selectedEpisodeForSearch = episode
                    beginSpecialSearch(context: specialContext, episode: episode)
                    return
                }

                guard let episode = watchTogetherAnimeEpisode(from: context) else {
                    watchTogetherPlaybackContextOverride = nil
                    failWatchTogetherPlayback(watchTogetherAnimeEpisodeFailureMessage(for: context))
                    return
                }
                watchTogetherPlaybackContextOverride = context
                selectedSpecialEpisodeContext = nil
                selectedEpisodeForSearch = episode
                beginNewMainPlaybackSearchSession()
                showingSearchResults = true
                return
            }

            guard let seasonNumber = target.seasonNumber,
                  let episodeNumber = target.episodeNumber else {
                Logger.shared.log(
                    "WatchTogether: incoming non-anime episode has no usable season/episode tmdbId=\(searchResult.id)",
                    type: "Player"
                )
                failWatchTogetherPlayback("Watch Together could not identify the exact episode, so playback was not started.")
                return
            }

            let episode = await exactEpisodeForWatchTogether(
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber
            )

            guard let episode else {
                Logger.shared.log(
                    "WatchTogether: could not resolve incoming episode tmdbId=\(searchResult.id) S\(seasonNumber)E\(episodeNumber)",
                    type: "Player"
                )
                failWatchTogetherPlayback("Watch Together could not load the exact S\(seasonNumber)E\(episodeNumber), so playback was not started.")
                return
            }

            selectedEpisodeForSearch = episode
            beginNewMainPlaybackSearchSession()
            showingSearchResults = true
        }
    }

    @MainActor
    private func exactEpisodeForWatchTogether(seasonNumber: Int, episodeNumber: Int) async -> TMDBEpisode? {
        if let loaded = seasonDetail,
           loaded.seasonNumber == seasonNumber {
            return loaded.episodes.first(where: { $0.episodeNumber == episodeNumber })
        }

        guard let show = tvShowDetail,
              let season = show.seasons.first(where: { $0.seasonNumber == seasonNumber }) else {
            return nil
        }
        do {
            let detail = try await tmdbService.getSeasonDetails(tvShowId: searchResult.id, seasonNumber: seasonNumber)
            guard let episode = detail.episodes.first(where: { $0.episodeNumber == episodeNumber }) else {
                return nil
            }
            selectedSeason = season
            seasonDetail = detail
            return episode
        } catch {
            Logger.shared.log(
                "WatchTogether: exact episode load failed tmdbId=\(searchResult.id) S\(seasonNumber)E\(episodeNumber): \(error.localizedDescription)",
                type: "Player"
            )
            return nil
        }
    }

    private func watchTogetherAnimeEpisode(from context: EpisodePlaybackContext) -> TMDBEpisode? {
        guard watchTogetherAnimeSeasonIdentityFailureReason(for: context) == nil else {
            return nil
        }

        if let exact = anilistEpisodes?.first(where: {
            $0.seasonNumber == context.localSeasonNumber && $0.number == context.localEpisodeNumber
        }) {
            return tmdbEpisode(from: exact)
        }

        let receiverHasTargetSeasonMapping = animeSeasonAniListIds[context.localSeasonNumber] != nil
            || animeSeasonKitsuIds[context.localSeasonNumber] != nil
            || anilistEpisodes?.contains(where: { $0.seasonNumber == context.localSeasonNumber }) == true
        guard !receiverHasTargetSeasonMapping else {
            // The receiver knows this season but cannot resolve the carried episode exactly.
            // Do not fabricate a local episode and risk launching the wrong cour or S1E1.
            return nil
        }

        // Performance/detail traversal can intentionally leave the receiver without anime
        // mappings. In that case the carried local coordinates remain the only exact identity,
        // so a synthetic display episode is safe as long as the carried context stays attached.
        return TMDBEpisode(
            id: searchResult.id * 10_000 + context.localSeasonNumber * 1_000 + context.localEpisodeNumber,
            name: "Episode \(context.localEpisodeNumber)",
            overview: nil,
            stillPath: nil,
            episodeNumber: context.localEpisodeNumber,
            seasonNumber: context.localSeasonNumber,
            airDate: nil,
            runtime: nil,
            voteAverage: 0,
            voteCount: 0
        )
    }

    private func watchTogetherAnimeSeasonIdentityFailureReason(
        for context: EpisodePlaybackContext
    ) -> String? {
        let seasonNumber = context.localSeasonNumber
        if let carriedAniListID = context.anilistMediaId,
           let receiverAniListID = animeSeasonAniListIds[seasonNumber],
           receiverAniListID != carriedAniListID {
            return "Watch Together found a different AniList season mapping on this device. It stopped instead of guessing the episode."
        }
        if let carriedKitsuID = context.kitsuMediaId,
           let receiverKitsuID = animeSeasonKitsuIds[seasonNumber],
           receiverKitsuID != carriedKitsuID {
            return "Watch Together found a different Kitsu season mapping on this device. It stopped instead of guessing the episode."
        }
        return nil
    }

    private func watchTogetherAnimeEpisodeFailureMessage(
        for context: EpisodePlaybackContext
    ) -> String {
        watchTogetherAnimeSeasonIdentityFailureReason(for: context)
            ?? "Watch Together could not resolve the exact anime episode from this device's season mapping. It stopped instead of falling back to S1E1."
    }

    private func failWatchTogetherPlayback(_ message: String) {
        Logger.shared.log("WatchTogether: \(message)", type: "Player")
        errorMessage = message
    }
    
    private func searchInServices() {
        if searchResult.isMovie {
            selectedEpisodeForSearch = nil
#if !os(tvOS)
            if preferDownloadedMedia,
               let item = downloadManager.completedDownloadItem(tmdbId: searchResult.id, isMovie: true) {
                playDownloadedItem(item)
                return
            }
#endif

            guard hasActiveSources else { return }
            beginNewMainPlaybackSearchSession()
            showingSearchResults = true
            return
        }

        Task { @MainActor in
            await prepareMainEpisodeAndPresent()
        }
    }

    @MainActor
    private func prepareMainEpisodeAndPresent() async {
        if let specialContext = selectedSpecialEpisodeContext {
            let episode = selectedEpisodeForSearch.flatMap { selected in
                specialContext.episodes.first(where: { $0.id == selected.id })
            } ?? specialContext.episodes.first
            selectedEpisodeForSearch = episode
#if !os(tvOS)
            if preferDownloadedMedia,
               let episode,
               let item = downloadedItem(for: episode) {
                playDownloadedItem(item)
                return
            }
#endif
            guard hasActiveSources else { return }
            beginSpecialSearch(context: specialContext, episode: episode)
            return
        }

        let episode = await resolveContinueEpisodeForMainPlay()
        selectedEpisodeForSearch = episode

#if !os(tvOS)
        if preferDownloadedMedia,
           let episode,
           let item = downloadedItem(for: episode) {
            playDownloadedItem(item)
            return
        }
        if preferDownloadedMedia,
           !hasActiveSources,
           let item = latestDownloadedItemForShow() {
            playDownloadedItem(item)
            return
        }
#endif

        guard hasActiveSources else { return }
        beginNewMainPlaybackSearchSession()
        showingSearchResults = true
    }

    @MainActor
    private func resolveContinueEpisodeForMainPlay() async -> TMDBEpisode? {
        if let target = resolveMainPlayEpisodeTarget() {
            let episode: TMDBEpisode?
            if let targetEpisode = target.episode {
                episode = targetEpisode
            } else {
                episode = await episodeForPlayback(
                    seasonNumber: target.key.seasonNumber,
                    episodeNumber: target.key.episodeNumber
                )
            }

            if let episode {
                Logger.shared.log("MediaDetailView main play using target episode: id=\(searchResult.id) S\(target.key.seasonNumber)E\(target.key.episodeNumber)", type: "Progress")
                return episode
            } else {
                Logger.shared.log("MediaDetailView main play target episode missing: id=\(searchResult.id) S\(target.key.seasonNumber)E\(target.key.episodeNumber)", type: "Progress")
            }
        }

        if let first = await firstPlayableEpisode() {
            Logger.shared.log("MediaDetailView main play defaulted first episode: id=\(searchResult.id) S\(first.seasonNumber)E\(first.episodeNumber)", type: "Progress")
            return first
        }

        Logger.shared.log("MediaDetailView main play found no episode: id=\(searchResult.id)", type: "Progress")
        return nil
    }

    @MainActor
    private func firstPlayableEpisode() async -> TMDBEpisode? {
        if let first = seasonDetail?.episodes.first {
            return first
        }

        if isAnimeShow, let first = anilistEpisodes?.sorted(by: episodeSort).first {
            return tmdbEpisode(from: first)
        }

        guard let tvShowDetail,
              let firstSeason = tvShowDetail.seasons.filter({ $0.seasonNumber > 0 }).sorted(by: { $0.seasonNumber < $1.seasonNumber }).first else {
            return nil
        }

        return await episodeForPlayback(seasonNumber: firstSeason.seasonNumber, episodeNumber: 1)
    }

    @MainActor
    private func applyInitialNotificationSelectionIfNeeded() async {
        guard hasLoadedContent,
              let selection = initialNotificationSelection,
              handledNotificationSelectionID != selection.id,
              !searchResult.isMovie else { return }

        let mappedAnimeSeasonNumber = selection.sourceMediaID.flatMap { sourceMediaID in
            animeSeasonAniListIds.first(where: { $0.value == sourceMediaID })?.key
        }

        if selection.isAnimeSpecial, mappedAnimeSeasonNumber == nil {
            guard !isLoadingAnimeSpecials else { return }
            if let sourceMediaID = selection.sourceMediaID,
               let entry = animeSpecialEntries.first(where: { $0.id == sourceMediaID }),
               let context = SpecialEpisodeListContext(entry: entry, tmdbShowId: searchResult.id) {
                selectedSpecialEpisodeContext = context
                selectedSeason = nil
                seasonDetail = nil
                if let episodeNumber = selection.episodeNumber {
                    if let episode = context.episodes.first(where: {
                        $0.episodeNumber == episodeNumber
                    }) {
                        selectedEpisodeForSearch = episode
                    } else {
                        selectedEpisodeForSearch = context.episodes.first
                        notificationRouteNotice = "Eclipse opened the correct special, but Episode \(episodeNumber) is not listed yet."
                    }
                } else {
                    selectedEpisodeForSearch = context.episodes.first
                }
                handledNotificationSelectionID = selection.id
                requestNotificationEpisodeScrollIfVisible()
                return
            }

            handledNotificationSelectionID = selection.id
            notificationRouteNotice = "Eclipse opened the show, but this special could not be matched safely on this device."
            return
        }

        var targetSeasonNumber = mappedAnimeSeasonNumber ?? selection.seasonNumber
        if isAnimeShow, let sourceMediaID = selection.sourceMediaID,
           mappedAnimeSeasonNumber == nil {
            // AniList sequel/cour identities are authoritative. A label such as
            // "Season 2" is not safe to reinterpret as the detail screen's
            // local season 2 when that AniList node is not part of this show.
            targetSeasonNumber = animeSeasonAniListIds.first(where: {
                $0.value == sourceMediaID
            })?.key
        }

        guard let targetSeasonNumber,
              let detail = await notificationSeasonDetail(seasonNumber: targetSeasonNumber) else {
            handledNotificationSelectionID = selection.id
            if selection.kind == .season {
                let label = selection.seasonLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
                notificationRouteNotice = "\((label?.isEmpty == false ? label : nil) ?? "This season") is upcoming. Episode details are not available yet."
            } else {
                notificationRouteNotice = "Eclipse opened the show, but this episode could not be matched safely."
            }
            return
        }

        selectedSpecialEpisodeContext = nil
        if let episodeNumber = selection.episodeNumber {
            if let episode = detail.episodes.first(where: { $0.episodeNumber == episodeNumber }) {
                selectedEpisodeForSearch = episode
            } else {
                notificationRouteNotice = "Eclipse opened the correct season, but Episode \(episodeNumber) is not listed yet."
            }
        } else {
            selectedEpisodeForSearch = detail.episodes.first
        }
        handledNotificationSelectionID = selection.id
        requestNotificationEpisodeScrollIfVisible()
    }

    @MainActor
    private func notificationSeasonDetail(seasonNumber: Int) async -> TMDBSeasonDetail? {
        if let loaded = seasonDetail, loaded.seasonNumber == seasonNumber {
            if let season = tvShowDetail?.seasons.first(where: { $0.seasonNumber == seasonNumber }) {
                selectedSeason = season
            }
            return loaded
        }

        guard let show = tvShowDetail,
              let season = show.seasons.first(where: { $0.seasonNumber == seasonNumber }) else {
            return nil
        }

        if isAnimeShow, anilistEpisodes != nil {
            let episodes = (anilistEpisodes ?? [])
                .filter { $0.seasonNumber == seasonNumber }
                .sorted(by: episodeSort)
                .map(tmdbEpisode)
            let detail = TMDBSeasonDetail(
                id: season.id,
                name: season.name,
                overview: season.overview ?? "",
                posterPath: season.posterPath,
                seasonNumber: season.seasonNumber,
                airDate: season.airDate,
                episodes: episodes
            )
            selectedSeason = season
            seasonDetail = detail
            return detail
        }

        do {
            let detail = try await tmdbService.getSeasonDetails(
                tvShowId: searchResult.id,
                seasonNumber: seasonNumber
            )
            selectedSeason = season
            seasonDetail = detail
            return detail
        } catch {
            Logger.shared.log(
                "Notification route could not load tmdbId=\(searchResult.id) season=\(seasonNumber): \(error.localizedDescription)",
                type: "Error"
            )
            return nil
        }
    }

    @MainActor
    private func requestNotificationEpisodeScrollIfVisible() {
        guard visibleMediaDetailElements.contains(.episodes) else {
            if let episode = selectedEpisodeForSearch {
                let label = isAnimeShow
                    ? "Episode \(episode.episodeNumber)"
                    : "S\(episode.seasonNumber)E\(episode.episodeNumber)"
                notificationRouteNotice = "Opened \(label), but Episodes is hidden in Appearance settings."
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            notificationEpisodeScrollGeneration &+= 1
        }
    }

    @MainActor
    private func episodeForPlayback(seasonNumber: Int, episodeNumber: Int) async -> TMDBEpisode? {
        if let loaded = seasonDetail,
           loaded.seasonNumber == seasonNumber,
           let episode = loaded.episodes.first(where: { $0.episodeNumber == episodeNumber }) {
            return episode
        }

        if isAnimeShow,
           let aniEpisode = anilistEpisodes?.first(where: { $0.seasonNumber == seasonNumber && $0.number == episodeNumber }) {
            return tmdbEpisode(from: aniEpisode)
        }

        if let show = tvShowDetail,
           let season = show.seasons.first(where: { $0.seasonNumber == seasonNumber }) {
            do {
                let detail = try await tmdbService.getSeasonDetails(tvShowId: searchResult.id, seasonNumber: seasonNumber)
                selectedSeason = season
                seasonDetail = detail
                return detail.episodes.first(where: { $0.episodeNumber == episodeNumber })
            } catch {
                Logger.shared.log("MediaDetailView failed loading last watched season S\(seasonNumber): \(error.localizedDescription)", type: "Progress")
            }
        }

        return nil
    }

    private func tmdbEpisode(from aniEpisode: AniListEpisode) -> TMDBEpisode {
        TMDBEpisode(
            id: searchResult.id * 1000 + aniEpisode.seasonNumber * 100 + aniEpisode.number,
            name: aniEpisode.title,
            overview: aniEpisode.description,
            stillPath: aniEpisode.stillPath,
            episodeNumber: aniEpisode.number,
            seasonNumber: aniEpisode.seasonNumber,
            airDate: aniEpisode.airDate,
            runtime: aniEpisode.runtime,
            voteAverage: 0,
            voteCount: 0
        )
    }

    private func episodeSort(_ lhs: AniListEpisode, _ rhs: AniListEpisode) -> Bool {
        if lhs.seasonNumber == rhs.seasonNumber {
            return lhs.number < rhs.number
        }
        return lhs.seasonNumber < rhs.seasonNumber
    }

#if !os(tvOS)
    private func downloadedItem(for episode: TMDBEpisode) -> DownloadItem? {
        downloadManager.completedDownloadItem(
            tmdbId: searchResult.id,
            isMovie: false,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber
        )
    }

    private func latestDownloadedItemForShow() -> DownloadItem? {
        downloadManager.completedDownloads
            .filter { !$0.isMovie && $0.tmdbId == searchResult.id && downloadManager.localFileURL(for: $0) != nil }
            .sorted {
                let lhsDate = $0.dateCompleted ?? $0.dateAdded
                let rhsDate = $1.dateCompleted ?? $1.dateAdded
                return lhsDate > rhsDate
            }
            .first
    }

    private func playDownloadedItem(_ item: DownloadItem, from presenter: UIViewController? = nil) {
        guard let fileURL = downloadManager.localFileURL(for: item) else {
            Logger.shared.log("Downloaded file not found for: \(item.id)", type: "Download")
            return
        }

        guard let originatingPresenter = presenter ?? UIApplication.shared.eclipseTopmostViewController() else {
            Logger.shared.log("Downloaded playback has no presenter", type: "Player")
            return
        }
        let subtitles = downloadManager.localSubtitleURL(for: item).map { [$0.absoluteString] } ?? []
        let nextEpisodeRequest: ((_ seasonNumber: Int, _ episodeNumber: Int) -> Void)? = item.isMovie ? nil : { [weak originatingPresenter] seasonNumber, episodeNumber in
            guard let originatingPresenter else { return }
            guard let nextItem = nextDownloadedEpisode(
                for: item.tmdbId,
                requestedSeasonNumber: seasonNumber,
                requestedEpisodeNumber: episodeNumber,
                currentItemId: item.id,
                allowNextAvailableFallback: false
            ) else {
                Logger.shared.log("NextEpisode: No downloaded next episode found for tmdbId=\(item.tmdbId) after \(item.id)", type: "Player")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.playDownloadedItem(nextItem, from: originatingPresenter)
            }
        }
        let localNextEpisode: DownloadItem? = item.isMovie ? nil : nextDownloadedEpisode(
            for: item.tmdbId,
            requestedSeasonNumber: item.seasonNumber ?? 0,
            requestedEpisodeNumber: (item.episodeNumber ?? 0) + 1,
            currentItemId: item.id
        )
        let request = PlaybackRequest(
            url: fileURL,
            subtitles: subtitles,
            mediaInfo: item.mediaInfo,
            episodePlaybackContext: item.episodePlaybackContext,
            title: item.playerTitleBase,
            subtitle: item.displayTitle,
            artworkURL: item.posterURL.flatMap(URL.init(string:)),
            isAnime: item.isAnime || item.episodePlaybackContext?.hasAnimeMediaId == true,
            isAnimation: detailGenres.contains { $0.id == 16 },
            originalTMDBSeasonNumber: item.episodePlaybackContext?.resolvedTMDBSeasonNumber,
            originalTMDBEpisodeNumber: item.episodePlaybackContext?.resolvedTMDBEpisodeNumber,
            onRequestNextEpisode: nextEpisodeRequest,
            localNextEpisodeFallback: PlaybackEpisodeCoordinate(
                seasonNumber: localNextEpisode?.seasonNumber,
                episodeNumber: localNextEpisode?.episodeNumber
            )
        )
        PlaybackCoordinator.shared.present(request, from: originatingPresenter)
    }

    private func nextDownloadedEpisode(
        for tmdbId: Int,
        requestedSeasonNumber: Int,
        requestedEpisodeNumber: Int,
        currentItemId: String,
        allowNextAvailableFallback: Bool = true
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

        guard allowNextAvailableFallback else { return nil }

        guard let currentIndex = episodes.firstIndex(where: { $0.id == currentItemId }) else { return nil }
        let nextIndex = episodes.index(after: currentIndex)
        guard nextIndex < episodes.endIndex else { return nil }
        return episodes[nextIndex]
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
#endif

    private func startTraktFeatureLoad() {
        traktFeatureLoadTask?.cancel()

        let shouldLoadComments = trackerManager.trackerState.traktCommentsEnabled

        guard shouldLoadComments || traktRating == nil else {
            traktComments = []
            isLoadingTraktComments = false
            return
        }

        isLoadingTraktComments = shouldLoadComments && traktComments.isEmpty

        let tmdbId = searchResult.id
        let isMovie = searchResult.isMovie
        traktFeatureLoadTask = Task {
            async let loadedComments: [TraktCommentReview] = shouldLoadComments
                ? TrackerManager.shared.fetchTraktComments(tmdbId: tmdbId, isMovie: isMovie)
                : []
            async let loadedRating: TraktMediaRating? = TrackerManager.shared.fetchTraktRating(tmdbId: tmdbId, isMovie: isMovie)

            guard !Task.isCancelled else { return }
            let comments = await loadedComments
            let rating = await loadedRating
            await MainActor.run {
                self.traktComments = comments
                self.traktRating = rating
                self.isLoadingTraktComments = false
                self.refreshDetailContentLayout(reason: "trakt-features")
            }
        }
    }

    private func startExperimentalExtrasLoadIfNeeded() {
        experimentalExtrasLoadTask?.cancel()

        guard ExperimentalFeatureState.isEnabledAtLaunch else {
            detailStills = []
            detailTrailers = []
            isLoadingExperimentalExtras = false
            return
        }

        let shouldLoadExtras = visibleMediaDetailElements.contains(.stills) || visibleMediaDetailElements.contains(.trailers)
        guard shouldLoadExtras else {
            detailStills = []
            detailTrailers = []
            isLoadingExperimentalExtras = false
            return
        }

        let tmdbId = searchResult.id
        let isMovie = searchResult.isMovie
        isLoadingExperimentalExtras = detailStills.isEmpty && detailTrailers.isEmpty

        experimentalExtrasLoadTask = Task {
            let images: TMDBImagesResponse?
            let trailers: [TMDBVideo]

            if isMovie {
                async let imagesResult: TMDBImagesResponse? = try? tmdbService.getMovieImages(id: tmdbId, preferredLanguage: selectedLanguage)
                async let videosResult: [TMDBVideo]? = try? tmdbService.getMovieVideos(id: tmdbId)

                images = await imagesResult
                let loadedVideos = (await videosResult) ?? []
                trailers = loadedVideos.filter { $0.isTrailerLike && $0.playbackURL != nil }
            } else {
                async let imagesResult: TMDBImagesResponse? = try? tmdbService.getTVShowImages(id: tmdbId, preferredLanguage: selectedLanguage)
                async let videosResult: [TMDBVideo]? = try? tmdbService.getTVShowVideos(id: tmdbId)

                images = await imagesResult
                let loadedVideos = (await videosResult) ?? []
                trailers = loadedVideos.filter { $0.isTrailerLike && $0.playbackURL != nil }
            }

            let stills = (images?.backdrops ?? [])
                .sorted {
                    let lhsVotes = $0.voteCount ?? 0
                    let rhsVotes = $1.voteCount ?? 0
                    if lhsVotes != rhsVotes { return lhsVotes > rhsVotes }
                    return ($0.voteAverage ?? 0) > ($1.voteAverage ?? 0)
                }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled, self.searchResult.id == tmdbId else { return }
                self.detailStills = stills
                self.detailTrailers = trailers
                self.isLoadingExperimentalExtras = false
                self.experimentalExtrasLoadTask = nil
                self.refreshDetailContentLayout(reason: "experimental-extras")
            }
        }
    }

    private func startSimilarTitlesLoadIfNeeded() {
        similarTitlesLoadTask?.cancel()

        let similarElementVisible = mediaDetailSimilarTitlesEnabled && MediaDetailElement.isVisible(
            .similarTitles,
            hiddenRawValue: mediaDetailHiddenElements,
            legacyShowCastSection: legacyShowCastSection
        )

        guard similarElementVisible else {
            similarTitles = []
            isLoadingSimilarTitles = false
            similarTitlesLoadFailed = false
            similarTitlesLoadTask = nil
            return
        }

        let tmdbId = searchResult.id
        let isMovie = searchResult.isMovie
        isLoadingSimilarTitles = similarTitles.isEmpty
        similarTitlesLoadFailed = false

        similarTitlesLoadTask = Task {
            let loadedResults: [TMDBSearchResult]?
            if isMovie {
                loadedResults = (try? await tmdbService.getMovieRecommendations(id: tmdbId))?.map(\.asSearchResult)
            } else {
                loadedResults = (try? await tmdbService.getTVRecommendations(id: tmdbId))?.map(\.asSearchResult)
            }

            let filteredResults = Self.filteredSimilarTitles(
                loadedResults ?? [],
                currentId: tmdbId,
                isMovie: isMovie
            )

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled, self.searchResult.id == tmdbId, self.searchResult.isMovie == isMovie else { return }
                self.similarTitles = filteredResults
                self.similarTitlesLoadFailed = loadedResults == nil
                self.isLoadingSimilarTitles = false
                self.similarTitlesLoadTask = nil
                self.refreshDetailContentLayout(reason: "similar-titles")
            }
        }
    }

    private static func filteredSimilarTitles(
        _ results: [TMDBSearchResult],
        currentId: Int,
        isMovie: Bool
    ) -> [TMDBSearchResult] {
        var seen = Set<String>()
        var filtered: [TMDBSearchResult] = []

        for result in results {
            guard result.id != currentId,
                  result.isMovie == isMovie,
                  result.adult != true,
                  seen.insert(result.stableIdentity).inserted else {
                continue
            }
            filtered.append(result)
            if filtered.count >= 15 { break }
        }

        return filtered
    }

    private struct ResolvedAnimeDetailMetadata {
        let anime: AniListAnimeWithSeasons?
        let rating: AnimeMetadataRating?
    }

    /// Resolves the expensive provider graph independently from images, title
    /// artwork and credits. `loadMediaDetails` still publishes the page only
    /// after every required branch has completed, so this reduces wall time
    /// without exposing a partially assembled detail screen.
    private func resolveAnimeDetailMetadata(
        for detail: TMDBTVShowWithSeasons,
        detectedAsAnime: Bool,
        performanceModeEnabled: Bool,
        skipAniListTraversal: Bool
    ) async -> ResolvedAnimeDetailMetadata {
        guard detectedAsAnime else {
            Logger.shared.log("MediaDetailView: Skipping AniList fetch - not detected as anime", type: "AniList")
            return ResolvedAnimeDetailMetadata(anime: nil, rating: nil)
        }

        if skipAniListTraversal {
            Logger.shared.log(
                "MediaDetailView: Skipping AniList traversal for \(detail.name) because detail traversal performance mode is enabled",
                type: "AniList"
            )
            // The explicit skip setting promises reduced metadata accuracy. Do
            // not replace the skipped AniList graph with MAL's much larger
            // title-search/detail traversal; use the already-loaded TMDB value.
            let rating = detail.voteAverage > 0
                ? AnimeMetadataRating(value: detail.voteAverage, source: .tmdb)
                : nil
            return ResolvedAnimeDetailMetadata(anime: nil, rating: rating)
        }

        var animeData: AniListAnimeWithSeasons?
        do {
            try Task.checkCancellation()
            Logger.shared.log(
                "MediaDetailView: Starting AniMap-backed anime detail fetch for \(detail.name) (tmdbId=\(detail.id)) performanceMode=\(performanceModeEnabled)",
                type: "AniList"
            )
            animeData = try await AniListService.shared.fetchAnimeDetailsWithEpisodes(
                title: detail.name,
                tmdbShowId: detail.id,
                tmdbService: tmdbService,
                tmdbShowPoster: detail.fullPosterURL,
                token: nil
            )
            try Task.checkCancellation()
            Logger.shared.log(
                "MediaDetailView: Fetched AniList hybrid data for \(detail.name) with \(animeData?.seasons.count ?? 0) seasons, \(animeData?.totalEpisodes ?? 0) total episodes",
                type: "AniList"
            )

            if let animeData {
                let seasonMappings = animeData.seasons.map {
                    (seasonNumber: $0.seasonNumber, anilistId: $0.anilistId)
                }
                TrackerManager.shared.registerAniListAnimeData(tmdbId: detail.id, seasons: seasonMappings)
            }
        } catch is CancellationError {
            return ResolvedAnimeDetailMetadata(anime: nil, rating: nil)
        } catch {
            Logger.shared.log(
                "MediaDetailView: FAILED AniList fetch for \(detail.name): \(error.localizedDescription)",
                type: "Error"
            )
        }

        guard !Task.isCancelled else {
            return ResolvedAnimeDetailMetadata(anime: nil, rating: nil)
        }
        let rating = await AniListService.shared.preferredAnimeRating(
            title: detail.name,
            tmdbShowId: detail.id,
            tmdbShowDetail: detail,
            tmdbService: tmdbService,
            animeData: animeData
        )
        return ResolvedAnimeDetailMetadata(anime: animeData, rating: rating)
    }

    private func formattedTraktDate(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        guard let date else { return nil }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
    
    private func loadMediaDetails() {
        if let existingTask = detailLoadTask {
            existingTask.cancel()
            detailLoadTask = nil
        }
        if let specialsLoadTask {
            specialsLoadTask.cancel()
            self.specialsLoadTask = nil
        }
        if let traktFeatureLoadTask {
            Logger.shared.log("MediaDetail cancelling stale Trakt feature task before reload: id=\(searchResult.id)", type: "Tracker")
            traktFeatureLoadTask.cancel()
            self.traktFeatureLoadTask = nil
        }
        if let experimentalExtrasLoadTask {
            Logger.shared.log("MediaDetail cancelling stale experimental extras task before reload: id=\(searchResult.id)", type: "TMDB")
            experimentalExtrasLoadTask.cancel()
            self.experimentalExtrasLoadTask = nil
        }
        if let similarTitlesLoadTask {
            Logger.shared.log("MediaDetail cancelling stale similar titles task before reload: id=\(searchResult.id)", type: "TMDB")
            similarTitlesLoadTask.cancel()
            self.similarTitlesLoadTask = nil
        }
        specialsLoadGeneration += 1
        let detailCacheKey = PerformanceModeSettings.detailCacheKey(for: searchResult.stableIdentity)

        // Check view-level cache first for instant back-navigation
        if let cached = MediaDetailCacheStore.shared.get(key: detailCacheKey) {
            // Defer state update to next run loop tick so SwiftUI properly re-renders
            Task { @MainActor in
                self.movieDetail = cached.movieDetail
                self.tvShowDetail = cached.tvShowDetail
                self.selectedSeason = cached.selectedSeason
                self.seasonDetail = nil
                self.synopsis = cached.synopsis
                self.romajiTitle = cached.romajiTitle
                self.logoURL = cached.logoURL
                self.isAnimeShow = cached.isAnimeShow
                self.animeRating = cached.animeRating
                self.anilistEpisodes = cached.anilistEpisodes
                self.animeSeasonTitles = cached.animeSeasonTitles
                self.animeSeasonRomajiTitles = cached.animeSeasonRomajiTitles
                self.animeSeasonAniListIds = cached.animeSeasonAniListIds
                self.animeSeasonKitsuIds = cached.animeSeasonKitsuIds
                self.animeSpecialEntries = cached.animeSpecialEntries
                self.selectedEpisodeForSearch = nil
                self.castMembers = cached.castMembers
                self.selectedSpecialEpisodeContext = nil
                self.isLoading = false
                self.hasLoadedContent = true
                if cached.isAnimeShow, !self.searchResult.isMovie, cached.animeSpecialEntries.isEmpty {
                    self.startAnimeSpecialsLoad(
                        tmdbShowId: self.searchResult.id,
                        fallbackPosterURL: cached.tvShowDetail?.fullPosterURL,
                        baseAniListIds: Array(cached.animeSeasonAniListIds.values)
                    )
                } else {
                    self.isLoadingAnimeSpecials = false
                }
                self.startTraktFeatureLoad()
                self.startExperimentalExtrasLoadIfNeeded()
                self.startSimilarTitlesLoadIfNeeded()
            }
            return
        }

        isLoading = true
        errorMessage = nil
        seasonDetail = nil
        selectedEpisodeForSearch = nil
        animeRating = nil
        animeSeasonRomajiTitles = [:]
        animeSeasonAniListIds = [:]
        animeSeasonKitsuIds = [:]
        animeSpecialEntries = []
        isLoadingAnimeSpecials = false
        traktComments = []
        traktRating = nil
        detailStills = []
        detailTrailers = []
        similarTitles = []
        similarTitlesLoadFailed = false
        isLoadingTraktComments = false
        isLoadingExperimentalExtras = false
        isLoadingSimilarTitles = false
        selectedSpecialEpisodeContext = nil
        
        detailLoadTask = Task {
            do {
                if searchResult.isMovie {
                    let detail = try await tmdbService.getMovieDetails(id: searchResult.id)

                    let images = try await tmdbService.getMovieImages(id: searchResult.id, preferredLanguage: selectedLanguage)

                    let romaji = await tmdbService.getRomajiTitle(for: "movie", id: searchResult.id)

                    let credits = try? await tmdbService.getMovieCredits(id: searchResult.id)

                    
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
                        self.animeRating = nil
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
                            animeRating: nil,
                            anilistEpisodes: nil,
                            animeSeasonTitles: nil,
                            animeSeasonRomajiTitles: [:],
                            animeSeasonAniListIds: [:],
                            animeSeasonKitsuIds: [:],
                            animeSpecialEntries: [],
                            castMembers: self.castMembers,
                            timestamp: Date()
                        ))
                        self.startTraktFeatureLoad()
                        self.startExperimentalExtrasLoadIfNeeded()
                        self.startSimilarTitlesLoadIfNeeded()
                    }
                } else {
                    async let detailTask = tmdbService.getTVShowWithSeasons(id: searchResult.id)
                    async let imagesTask = tmdbService.getTVShowImages(id: searchResult.id, preferredLanguage: selectedLanguage)
                    async let romajiTask = tmdbService.getRomajiTitle(for: "tv", id: searchResult.id)
                    async let creditsTask = tmdbService.getTVCredits(id: searchResult.id)

                    let detail = try await detailTask

                    // Detect anime/donghua as soon as the primary TMDB detail
                    // arrives, then overlap its provider traversal with the
                    // already-running image/title/credit requests.
                    let asianAnimationCountries: Set<String> = ["JP", "CN", "KR", "TW"]
                    let isAsianAnimation = detail.originCountry?.contains(where: { asianAnimationCountries.contains($0) }) ?? false
                    let isAnimation = detail.genres.contains { $0.id == 16 }
                    let detectedAsAnime = isAsianAnimation && isAnimation
                    let performanceModeEnabled = PerformanceModeSettings.isEnabled
                    let skipAniListTraversal = PerformanceModeSettings.skipsAniListTraversalForAnimeDetails
                    Logger.shared.log("MediaDetailView: \(detail.name) - isAsianAnimation=\(isAsianAnimation) isAnimation=\(isAnimation) detectedAsAnime=\(detectedAsAnime) originCountry=\(detail.originCountry ?? []) genres=\(detail.genres.map { $0.id })", type: "AniList")

                    async let animeMetadataTask = resolveAnimeDetailMetadata(
                        for: detail,
                        detectedAsAnime: detectedAsAnime,
                        performanceModeEnabled: performanceModeEnabled,
                        skipAniListTraversal: skipAniListTraversal
                    )

                    let images: TMDBImagesResponse?
                    do {
                        images = try await imagesTask
                    } catch {
                        images = nil
                    }

                    let romaji = await romajiTask

                    let credits: TMDBCreditsResponse?
                    do {
                        credits = try await creditsTask
                    } catch {
                        credits = nil
                    }

                    let animeMetadata = await animeMetadataTask
                    let animeData = animeMetadata.anime
                    let resolvedAnimeRating = animeMetadata.rating

                    if Task.isCancelled { return }
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        self.synopsis = detail.overview ?? ""
                        self.romajiTitle = romaji
                        self.isAnimeShow = detectedAsAnime
                        self.animeRating = resolvedAnimeRating
                        self.castMembers = credits?.cast ?? []
                        
                        if let animeData = animeData {
                            Logger.shared.log("MediaDetailView: Using AniList structure - \(animeData.seasons.count) seasons", type: "AniList")
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
                                genres: Self.mergedAnimeDetailGenres(
                                    tmdbGenres: detail.genres,
                                    animeGenres: animeData.genres ?? []
                                ),
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
                            var seasonRomajiTitles: [Int: String] = [:]
                            var seasonAniListIds: [Int: Int] = [:]
                            var seasonKitsuIds: [Int: Int] = [:]
                            var allEpisodes: [AniListEpisode] = []
                            for season in animeData.seasons {
                                seasonTitles[season.seasonNumber] = season.title
                                if let romaji = season.romajiTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                                   !romaji.isEmpty {
                                    seasonRomajiTitles[season.seasonNumber] = romaji
                                }
                                seasonAniListIds[season.seasonNumber] = season.anilistId
                                if let kitsuId = season.kitsuId, kitsuId > 0 {
                                    seasonKitsuIds[season.seasonNumber] = kitsuId
                                }
                                allEpisodes.append(contentsOf: season.episodes)
                            }
                            self.animeSeasonTitles = seasonTitles
                            self.animeSeasonRomajiTitles = seasonRomajiTitles
                            self.animeSeasonAniListIds = seasonAniListIds
                            self.animeSeasonKitsuIds = seasonKitsuIds
                            self.anilistEpisodes = allEpisodes
                            
                            if let firstSeason = aniSeasons.first {
                                self.selectedSeason = firstSeason
                            } else {
                                self.selectedSeason = nil
                            }
                        } else {
                            // Fallback to TMDB seasons
                            Logger.shared.log("MediaDetailView: animeData is nil - falling back to pure TMDB seasons (\(detail.seasons.count) seasons)", type: "AniList")
                            self.tvShowDetail = detail
                            self.anilistEpisodes = nil
                            self.animeSeasonTitles = nil
                            self.animeSeasonRomajiTitles = [:]
                            self.animeSeasonAniListIds = [:]
                            self.animeSeasonKitsuIds = [:]
                            if let firstSeason = detail.seasons.first(where: { $0.seasonNumber > 0 }) {
                                self.selectedSeason = firstSeason
                            } else {
                                self.selectedSeason = nil
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
                            animeRating: self.animeRating,
                            anilistEpisodes: self.anilistEpisodes,
                            animeSeasonTitles: self.animeSeasonTitles,
                            animeSeasonRomajiTitles: self.animeSeasonRomajiTitles,
                            animeSeasonAniListIds: self.animeSeasonAniListIds,
                            animeSeasonKitsuIds: self.animeSeasonKitsuIds,
                            animeSpecialEntries: self.animeSpecialEntries,
                            castMembers: self.castMembers,
                            timestamp: Date()
                        ))
                        if detectedAsAnime {
                            self.startAnimeSpecialsLoad(
                                tmdbShowId: detail.id,
                                fallbackPosterURL: detail.fullPosterURL,
                                baseAniListIds: Array(self.animeSeasonAniListIds.values)
                            )
                        } else {
                            self.animeSpecialEntries = []
                            self.isLoadingAnimeSpecials = false
                            self.selectedSpecialEpisodeContext = nil
                        }
                        self.startTraktFeatureLoad()
                        self.startExperimentalExtrasLoadIfNeeded()
                        self.startSimilarTitlesLoadIfNeeded()
                    }
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                    self.hasLoadedContent = true
                }
            }
        }
    }

}

#if !os(tvOS)
private struct MediaNotificationOptionsView: View {
    let source: LocalNotificationMediaSource
    let tmdbID: Int
    let title: String
    let titleAliases: [String]
    let animeMediaIDs: Set<Int>
    let westernSeasonIDs: Set<Int>

    @StateObject private var manager = LocalNotificationManager.shared
    @AppStorage(ScheduleWindow.storageKey)
    private var scheduleWindowDays = ScheduleWindow.defaultValue.rawValue
    @Environment(\.presentationMode) private var presentationMode
    @State private var notice: LocalNotificationNotice?
    @State private var isUpdating = false

    private var subscription: LocalMediaNotificationSubscription? {
        manager.subscription(source: source, tmdbID: tmdbID)
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 9) {
                        Image(systemName: subscription == nil ? "bell.badge" : "bell.badge.fill")
                            .font(.system(size: 42, weight: .semibold))
                            .foregroundColor(.orange)
                        Text(title)
                            .font(.title3.bold())
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                        Text("Choose what Eclipse should check for on this device.")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.58))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 12)

                    GlassSection(header: "Notify Me") {
                        VStack(spacing: 0) {
                            notificationOptionRow(
                                icon: "calendar",
                                title: "Upcoming Episodes",
                                detail: "Alerts for episodes in your rolling \(ScheduleWindow.sanitizedDays(scheduleWindowDays))-day Schedule range.",
                                isOn: subscription?.episodeNotifications == true
                            ) {
                                update(
                                    episodes: !(subscription?.episodeNotifications ?? false),
                                    seasons: subscription?.futureSeasonNotifications ?? false
                                )
                            }

                            GlassDivider(leadingInset: 16)

                            notificationOptionRow(
                                icon: "sparkles",
                                title: "Future Seasons",
                                detail: "Checks for newly announced seasons and known premiere dates when Eclipse refreshes.",
                                isOn: subscription?.futureSeasonNotifications == true
                            ) {
                                update(
                                    episodes: subscription?.episodeNotifications ?? false,
                                    seasons: !(subscription?.futureSeasonNotifications ?? false)
                                )
                            }
                        }
                    }

                    GlassSectionFooter("These are local reminders. Eclipse must be opened periodically to learn new or changed dates. “Aired” reflects the schedule, not guaranteed streaming availability.")

                    if source == .anime, !animeMediaIDs.contains(where: { $0 > 0 }) {
                        GlassSectionFooter("AniList identity is not available while Eclipse is using MyAnimeList fallback. Existing confirmed reminders are kept, but estimated schedule rows cannot create alerts and Future Seasons stays unavailable until AniList is restored.")
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .navigationTitle("Notifications")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { presentationMode.wrappedValue.dismiss() }
                }
            }
            .background(SettingsGradientBackground().ignoresSafeArea())
            .eclipseDarkToolbar()
        }
        .preferredColorScheme(.dark)
        .alert(item: $notice) { notice in
            if notice.offersSettings {
                return Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    primaryButton: .default(Text("Open Settings")) {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    },
                    secondaryButton: .cancel()
                )
            }
            return Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func notificationOptionRow(
        icon: String,
        title: String,
        detail: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(.orange)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                    Text(detail)
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(isOn ? .orange : .white.opacity(0.28))
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isUpdating)
        .opacity(isUpdating ? 0.72 : 1)
        .accessibilityValue(isOn ? "On" : "Off")
    }

    private func update(episodes: Bool, seasons: Bool) {
        guard !isUpdating else { return }
        isUpdating = true
        Task {
            let result = await manager.updateMediaSubscription(
                source: source,
                tmdbID: tmdbID,
                title: title,
                titleAliases: titleAliases,
                animeMediaIDs: animeMediaIDs,
                westernSeasonIDs: westernSeasonIDs,
                episodeNotifications: episodes,
                futureSeasonNotifications: seasons
            )
            notice = LocalNotificationNotice.from(result)
            isUpdating = false
        }
    }
}
#endif

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
            animeAbsoluteEpisodeNumber: nil,
            animeSeasonEpisodeCount: nil,
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
