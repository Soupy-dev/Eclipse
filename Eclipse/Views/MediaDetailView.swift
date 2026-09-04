//
//  MediaDetailView.swift
//  Sora
//
//  Created by Francesco on 07/08/25.
//

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
    let source: LocalNotificationMediaSource?
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
        source = target.source
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

private final class MediaDetailCacheStore {
    static let shared = MediaDetailCacheStore()

    struct CachedDetail {
        let movieDetail: TMDBMovieDetail?
        let tvShowDetail: TMDBTVShowWithSeasons?
        let selectedSeason: TMDBSeason?
        let seasonDetail: TMDBSeasonDetail?
        let synopsis: String
        let romajiTitle: String?
        let logoURL: String?
        let alternatePosterURL: String?
        let isAnimeShow: Bool
        let animeRating: AnimeMetadataRating?
        let anilistEpisodes: [AniListEpisode]?
        let animeSeasonTitles: [Int: String]?
        let animeSeasonRomajiTitles: [Int: String]
        let animeSeasonAniListIds: [Int: Int]
        let animeSeasonKitsuIds: [Int: Int]
        let animeProviderAliases: [Int: Int]
        let animeSpecialEntries: [AniListSpecialSearchEntry]
        let animeSpecialsAreComplete: Bool
        let castMembers: [TMDBCastMember]
        let timestamp: Date
    }

    private var cache: [String: CachedDetail] = [:]
    private var accessOrder: [String] = []
    private let lock = NSLock()
    private let ttl: TimeInterval = 300
    private let maximumEntryCount = 8
    private let maximumEpisodeCost = 3_000

    func get(key: String) -> CachedDetail? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[key] else {
            return nil
        }
        guard Date().timeIntervalSince(entry.timestamp) < ttl else {
            cache[key] = nil
            accessOrder.removeAll { $0 == key }
            return nil
        }
        touch(key)
        return entry
    }

    func set(key: String, detail: CachedDetail) {
        lock.lock()
        defer { lock.unlock() }
        cache[key] = detail
        touch(key)
        evictIfNeeded()
    }

    func remove(key: String) {
        lock.lock()
        defer { lock.unlock() }
        cache[key] = nil
        accessOrder.removeAll { $0 == key }
    }

    func updateSpecialEntries(
        key: String,
        entries: [AniListSpecialSearchEntry],
        providerAliases: [Int: Int]
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let existing = cache[key] else { return }
        cache[key] = CachedDetail(
            movieDetail: existing.movieDetail,
            tvShowDetail: existing.tvShowDetail,
            selectedSeason: existing.selectedSeason,
            seasonDetail: existing.seasonDetail,
            synopsis: existing.synopsis,
            romajiTitle: existing.romajiTitle,
            logoURL: existing.logoURL,
            alternatePosterURL: existing.alternatePosterURL,
            isAnimeShow: existing.isAnimeShow,
            animeRating: existing.animeRating,
            anilistEpisodes: existing.anilistEpisodes,
            animeSeasonTitles: existing.animeSeasonTitles,
            animeSeasonRomajiTitles: existing.animeSeasonRomajiTitles,
            animeSeasonAniListIds: existing.animeSeasonAniListIds,
            animeSeasonKitsuIds: existing.animeSeasonKitsuIds,
            animeProviderAliases: providerAliases,
            animeSpecialEntries: entries,
            animeSpecialsAreComplete: true,
            castMembers: existing.castMembers,
            timestamp: Date()
        )
        touch(key)
        evictIfNeeded()
    }

    private func touch(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func episodeCost(of detail: CachedDetail) -> Int {
        let regular = detail.anilistEpisodes?.count
            ?? detail.seasonDetail?.episodes.count
            ?? 0
        let specials = RemoteMediaNumericBoundary.saturatingNonnegativeSum(
            detail.animeSpecialEntries.map(\.episodeCount)
        )
        return RemoteMediaNumericBoundary.saturatingNonnegativeSum([regular, specials])
    }

    private func evictIfNeeded() {
        let cutoff = Date().addingTimeInterval(-ttl)
        let expiredKeys = cache.compactMap { element in
            element.value.timestamp < cutoff ? element.key : nil
        }
        for key in expiredKeys {
            cache[key] = nil
        }
        if !expiredKeys.isEmpty {
            let expired = Set(expiredKeys)
            accessOrder.removeAll { expired.contains($0) }
        }

        func totalEpisodeCost() -> Int {
            RemoteMediaNumericBoundary.saturatingNonnegativeSum(
                cache.values.map(episodeCost(of:))
            )
        }
        while accessOrder.count > 1,
              (cache.count > maximumEntryCount
                  || totalEpisodeCost() > maximumEpisodeCost),
              let oldest = accessOrder.first {
            accessOrder.removeFirst()
            cache[oldest] = nil
        }
    }
}

enum MediaDetailTitleArtworkSettings {
    static let enabledKey = "mediaDetailTitleArtworkEnabled"
    static let defaultEnabled = true

    static func isEnabled(defaults: UserDefaults = ProfileSettingsStore.active) -> Bool {
        defaults.object(forKey: enabledKey) == nil ? defaultEnabled : defaults.bool(forKey: enabledKey)
    }
}

enum MediaDetailAlternatePosterSettings {
    static let enabledKey = "mediaDetailAlternatePosterEnabled"

    static var isSupportedOnThisDevice: Bool {
#if os(iOS)
        !isIPad
#else
        false
#endif
    }

    static var defaultEnabled: Bool {
        isSupportedOnThisDevice
    }

    static func isEnabled(defaults: UserDefaults = ProfileSettingsStore.active) -> Bool {
        defaults.object(forKey: enabledKey) == nil ? defaultEnabled : defaults.bool(forKey: enabledKey)
    }
}

enum MediaDetailAgeRatingSettings {
    static let enabledKey = "mediaDetailAgeRatingEnabled"
    static let defaultEnabled = false

    static func isEnabled(defaults: UserDefaults = ProfileSettingsStore.active) -> Bool {
        defaults.object(forKey: enabledKey) == nil ? defaultEnabled : defaults.bool(forKey: enabledKey)
    }
}

struct MediaDetailView: View {
    let searchResult: TMDBSearchResult
    private let watchTogetherAutoPlay: WatchTogetherMediaDescriptor?
    private let initialNotificationSelection: MediaDetailInitialNotificationSelection?

    @ObservedObject private var contentFilter = TMDBContentFilter.shared
    @Environment(\.presentationMode) private var presentationMode
    @State private var access: TMDBContentFilter.KidsAccessDecision
    @State private var resolveTask: Task<Void, Never>?

    @State private var detailsResolvedAllowedIdentity: String?

    init(
        searchResult: TMDBSearchResult,
        watchTogetherAutoPlay: WatchTogetherMediaDescriptor? = nil,
        initialNotificationSelection: MediaDetailInitialNotificationSelection? = nil
    ) {
        self.searchResult = searchResult
        self.watchTogetherAutoPlay = watchTogetherAutoPlay
        self.initialNotificationSelection = initialNotificationSelection

        _access = State(initialValue: Self.gatedAccessDecision(for: searchResult))
    }

    private static func gatedAccessDecision(for searchResult: TMDBSearchResult) -> TMDBContentFilter.KidsAccessDecision {
        let decision = TMDBContentFilter.shared.kidsAccessDecision(for: searchResult)
        guard decision == .allowed,
              TMDBContentFilter.shared.isKidsProfileActive,
              !TMDBContentFilter.carriesFullKidsPolicySignals(searchResult) else {
            return decision
        }
        switch TMDBMaturityRatingStore.shared.kidsDetailPolicyAllows(
            isMovie: searchResult.isMovie,
            id: searchResult.id
        ) {
        case .some(true): return .allowed
        case .some(false): return .denied
        case .none: return .unresolved
        }
    }

    var body: some View {
        Group {
            switch access {
            case .allowed:
                MediaDetailContentView(
                    searchResult: searchResult,
                    watchTogetherAutoPlay: watchTogetherAutoPlay,
                    initialNotificationSelection: initialNotificationSelection
                )
            case .unresolved:
                gateStatus(isResolving: true)
            case .denied:
                gateStatus(isResolving: false)
            }
        }
        .onAppear { startResolutionIfNeeded() }
        .onDisappear {
            resolveTask?.cancel()
            resolveTask = nil
        }
        .onChangeComp(of: contentFilter.isKidsProfileActive) { _, _ in
            detailsResolvedAllowedIdentity = nil
            reevaluate()
        }
        .onChangeComp(of: contentFilter.maturityRatingRevision) { _, _ in reevaluate() }
    }

    @ViewBuilder
    private func gateStatus(isResolving: Bool) -> some View {
        ZStack {
            EclipseTheme.shared.backgroundBase
                .ignoresSafeArea(.all)

            VStack(spacing: 16) {
                if isResolving {
                    VStack(spacing: 16) {
                        EclipseLoadingIndicator()
                            .scaleEffect(1.5)
                        Text("Checking this title...")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
#if os(tvOS)
                    .focusable()
#endif
                } else {
                    Image(systemName: "lock.fill")
                        .font(.system(size: isTvOS ? 72 : 48))
                        .foregroundColor(.secondary)
                    Text("Not available on this profile")
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Button("Go Back") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#if os(tvOS)
        .toolbar(.hidden, for: .tabBar)
        .onExitCommand { presentationMode.wrappedValue.dismiss() }
#endif
    }

    private func startResolutionIfNeeded() {
        guard access == .unresolved, resolveTask == nil else { return }
        resolveTask = Task { @MainActor in
            var decision = await contentFilter.resolveKidsAccess(for: searchResult)

            if decision == .allowed,
               contentFilter.isKidsProfileActive,
               !TMDBContentFilter.carriesFullKidsPolicySignals(searchResult),
               await !contentFilter.kidsPolicyAllowsPlayback(
                   isMovie: searchResult.isMovie,
                   id: searchResult.id,
                   title: searchResult.displayTitle
               ) {
                decision = .denied
            }
            guard !Task.isCancelled else { return }
            access = decision
            detailsResolvedAllowedIdentity = decision == .allowed
                ? searchResult.stableIdentity
                : nil
            resolveTask = nil
        }
    }

    private func reevaluate() {
        let decision = Self.gatedAccessDecision(for: searchResult)

        if decision == .unresolved,
           access == .allowed,
           detailsResolvedAllowedIdentity == searchResult.stableIdentity {
            return
        }
        guard decision != access else { return }
        access = decision
        startResolutionIfNeeded()
    }
}

struct MediaDetailContentView: View {
#if os(tvOS)
    private enum TVDetailFocus: Hashable {
        case loading
        case error
        case content
        case play
        case collection
        case bookmark
    }
#endif

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
    @State private var watchTogetherAutoPlayFailureCount = 0
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
    @State private var alternatePosterURL: String?
    @State private var isAnimeShow = false
    @State private var animeRating: AnimeMetadataRating?
    @State private var anilistEpisodes: [AniListEpisode]? = nil
    @State private var animeSeasonTitles: [Int: String]? = nil
    @State private var animeSeasonRomajiTitles: [Int: String] = [:]
    @State private var animeSeasonAniListIds: [Int: Int] = [:]
    @State private var animeSeasonKitsuIds: [Int: Int] = [:]
    @State private var animeProviderAliases: [Int: Int] = [:]
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
    @State private var animeStructureRevalidationTask: Task<Void, Never>?
    @State private var specialsLoadGeneration = 0
    @State private var detailContentRefreshTick = 0
    @State private var handledNotificationSelectionID: String?
    @State private var notificationEpisodeScrollGeneration = 0
    @State private var notificationRouteNotice: String?
#if os(tvOS)
    @FocusState private var tvDetailFocus: TVDetailFocus?
    @State private var showingTVNoSourcesGuidance = false
    @State private var didRequestTVContentFocus = false
    @FocusState private var tvFocusedCastIndex: Int?
    @FocusState private var tvFocusedStillIndex: Int?
    @FocusState private var tvFocusedTraktCommentID: Int?
#endif

    @StateObject private var serviceManager = ServiceManager.shared
    @StateObject private var stremioManager = StremioAddonManager.shared
#if os(iOS) && !targetEnvironment(macCatalyst)
    @StateObject private var skyStreamPluginManager = SkyStreamPluginManager.shared
    @StateObject private var nuvioPluginManager = NuvioPluginManager.shared
#endif
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
    @AppStorage(MediaDetailAlternatePosterSettings.enabledKey) private var mediaDetailAlternatePosterEnabled = MediaDetailAlternatePosterSettings.defaultEnabled
    @AppStorage(MediaDetailAgeRatingSettings.enabledKey) private var mediaDetailAgeRatingEnabled = MediaDetailAgeRatingSettings.defaultEnabled
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
        let date = searchResult.isMovie
            ? (movieDetail?.releaseDate ?? searchResult.releaseDate)
            : (tvShowDetail?.firstAirDate ?? searchResult.firstAirDate)
        guard let date else { return nil }
        return Int(date.prefix(4))
    }

    private var exactRegularAnimeSeedAniListId: Int? {
        if watchTogetherAutoPlay?.playbackContext?.isSpecial != true,
           let seed = watchTogetherAutoPlay?.playbackContext?.anilistMediaId,
           seed != 0 {
            return seed
        }
        if initialNotificationSelection?.source == .anime,
           initialNotificationSelection?.isAnimeSpecial != true,
           let seed = initialNotificationSelection?.sourceMediaID,
           seed != 0 {
            return seed
        }
        return nil
    }

    private var hasExactAnimeNavigationContext: Bool {
        exactRegularAnimeSeedAniListId != nil
            || searchResult.animeIdentitySeed != nil
            || watchTogetherAutoPlay?.isAnime == true
            || watchTogetherAutoPlay?.playbackContext?.hasAnimeMediaId == true
            || initialNotificationSelection?.source == .anime
            || initialNotificationSelection?.isAnimeSpecial == true
    }

    private var exactSpecialAnimeSeedAniListId: Int? {
        if watchTogetherAutoPlay?.playbackContext?.isSpecial == true,
           let id = watchTogetherAutoPlay?.playbackContext?.anilistMediaId,
           id != 0 {
            return id
        }
        if initialNotificationSelection?.isAnimeSpecial == true,
           let id = initialNotificationSelection?.sourceMediaID,
           id != 0 {
            return id
        }
        return nil
    }

    private var exactAnimeNavigationSeedAniListId: Int? {
        if let id = watchTogetherAutoPlay?.playbackContext?.anilistMediaId, id != 0 {
            return id
        }
        if initialNotificationSelection?.source == .anime,
           let id = initialNotificationSelection?.sourceMediaID,
           id != 0 {
            return id
        }
        if initialNotificationSelection?.isAnimeSpecial == true,
           let id = initialNotificationSelection?.sourceMediaID,
           id != 0 {
            return id
        }
        return nil
    }

    private static func animeProviderAliasMap(
        seasons: [AniListSeasonWithPoster],
        specials: [AniListSpecialSearchEntry] = []
    ) -> [Int: Int] {
        var aliases: [Int: Int] = [:]

        func register(rawID: Int, canonicalAniListID: Int?, malID: Int?) {
            guard let canonicalID = canonicalAniListID
                    ?? (rawID > 0 ? rawID : nil),
                  canonicalID > 0 else { return }
            aliases[canonicalID] = canonicalID
            aliases[rawID] = canonicalID
            if let providerID = RemoteMediaNumericBoundary.negativeProviderIdentifier(malID) {
                aliases[providerID] = canonicalID
            }
        }

        for season in seasons {
            register(
                rawID: season.anilistId,
                canonicalAniListID: season.canonicalAniListId,
                malID: season.malId
            )
        }
        for special in specials {
            register(
                rawID: special.id,
                canonicalAniListID: special.canonicalAniListId,
                malID: special.malId
            )
        }
        return aliases
    }

    private static func addingAnimeSpecialAliases(
        _ specials: [AniListSpecialSearchEntry],
        to existing: [Int: Int]
    ) -> [Int: Int] {
        var aliases = existing
        for special in specials {
            guard let canonicalID = special.canonicalAniListId
                    ?? (special.id > 0 ? special.id : nil),
                  canonicalID > 0 else {
                continue
            }
            aliases[canonicalID] = canonicalID
            aliases[special.id] = canonicalID
            if let providerID = RemoteMediaNumericBoundary.negativeProviderIdentifier(
                special.malId
            ) {
                aliases[providerID] = canonicalID
            }
        }
        return aliases
    }

    private func canonicalAnimeProviderID(_ id: Int) -> Int {
        Self.canonicalAnimeProviderID(id, aliases: animeProviderAliases)
    }

    private func animeProviderIDsMatch(_ lhs: Int, _ rhs: Int) -> Bool {
        canonicalAnimeProviderID(lhs) == canonicalAnimeProviderID(rhs)
    }

    private func exactAnimeMALID(for providerID: Int?) -> Int? {
        guard let providerID else { return nil }
        if providerID < 0 {
            return RemoteMediaNumericBoundary.positiveMagnitude(providerID)
        }
        let canonicalID = canonicalAnimeProviderID(providerID)
        return animeProviderAliases.first(where: {
            $0.key < 0 && $0.value == canonicalID
        }).flatMap { RemoteMediaNumericBoundary.positiveMagnitude($0.key) }
    }

    private static func canonicalAnimeProviderID(
        _ id: Int,
        aliases: [Int: Int]
    ) -> Int {
        aliases[id] ?? id
    }

    private static func animeProviderIDsMatch(
        _ lhs: Int,
        _ rhs: Int,
        aliases: [Int: Int]
    ) -> Bool {
        canonicalAnimeProviderID(lhs, aliases: aliases)
            == canonicalAnimeProviderID(rhs, aliases: aliases)
    }

    private func notificationAnimeProviderIDs(for rawIDs: some Sequence<Int>) -> Set<Int> {
        let canonicalIDs = Set(rawIDs.map(canonicalAnimeProviderID))
        var result = Set(rawIDs)
        result.formUnion(canonicalIDs)
        result.formUnion(animeProviderAliases.compactMap { storedID, canonicalID in
            canonicalIDs.contains(canonicalID) ? storedID : nil
        })
        return result
    }

    private var notificationAnimeRegularMediaIDs: Set<Int> {
        notificationAnimeProviderIDs(for: animeSeasonAniListIds.values)
    }

    private var notificationAnimeSpecialMediaIDs: Set<Int> {
        notificationAnimeProviderIDs(for: animeSpecialEntries.map(\.id))
    }

    private var preferDownloadedMedia: Bool {
#if os(tvOS)
        false
#else
        ProfileSettingsStore.active.bool(forKey: "preferDownloadedMedia")
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
#if os(tvOS)
            guard element != .trailers else {
                return false
            }
#endif
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
#if os(tvOS)
                    .focusable(!shouldShowHeroActions)
                    .focused($tvDetailFocus, equals: .content)
#endif
            }
#if !os(tvOS)
            navigationOverlay
#endif
        }
#if os(tvOS)
        .toolbar(.hidden, for: .tabBar)
#endif
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
#if os(tvOS)
            requestInitialTVFocusIfNeeded()
#endif
            if !hasLoadedContent {
                loadMediaDetails()
            } else {
                startTraktFeatureLoad()
                startExperimentalExtrasLoadIfNeeded()
                startSimilarTitlesLoadIfNeeded()
                resumeAnimeSpecialsLoadIfNeeded()
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
            if let animeStructureRevalidationTask {
                animeStructureRevalidationTask.cancel()
                self.animeStructureRevalidationTask = nil
            }
            specialsLoadGeneration += 1
        }
        .onChangeComp(of: trackerManager.trackerState.traktCommentsEnabled) { _, _ in
            if hasLoadedContent {
                startTraktFeatureLoad()
            }
        }
        .onChangeComp(of: mediaDetailElementOrder) { _, _ in
            handleMediaDetailLayoutPreferenceChange()
        }
        .onChangeComp(of: mediaDetailHiddenElements) { _, _ in
            handleMediaDetailLayoutPreferenceChange()
        }
        .onChangeComp(of: mediaDetailSimilarTitlesEnabled) { _, _ in
            handleMediaDetailLayoutPreferenceChange()
        }

        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in
            similarTitles = []
            similarTitlesLoadFailed = false
            startSimilarTitlesLoadIfNeeded()
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
                if let selection = canonicalRegularWatchTogetherSelection(
                    for: incomingPlaybackContext
                ) {
                    watchTogetherPlaybackContextOverride = selection.context
                    nextEpisodePlaybackContextOverride = selection.context
                    nextEpisodeResolvedTargetOverride = canonicalizedNextEpisodeTarget(
                        incomingResolvedTarget,
                        episode: selection.episode,
                        playbackContext: selection.context
                    )
                    selectedSpecialEpisodeContext = nil
                    selectedEpisodeForSearch = selection.episode
                    showingSearchResults = false
                    scheduleNextEpisodePresentation {
                        beginNewMainPlaybackSearchSession()
                        showingSearchResults = true
                    }
                    return
                }

                guard let selection = canonicalSpecialWatchTogetherSelection(
                    for: incomingPlaybackContext
                ) else {
                    failWatchTogetherPlayback("Watch Together could not resolve the exact anime special on this device. It stopped instead of falling back to TMDB.")
                    return
                }
                watchTogetherPlaybackContextOverride = selection.playbackContext
                nextEpisodePlaybackContextOverride = selection.playbackContext
                nextEpisodeResolvedTargetOverride = canonicalizedNextEpisodeTarget(
                    incomingResolvedTarget,
                    episode: selection.episode,
                    playbackContext: selection.playbackContext
                )
                selectedSpecialEpisodeContext = selection.context
                selectedEpisodeForSearch = selection.episode
                scheduleNextEpisodePresentation {
                    beginSpecialSearch(
                        context: selection.context,
                        episode: selection.episode,
                        playbackContextOverride: selection.playbackContext
                    )
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
                if let selection = canonicalRegularWatchTogetherSelection(
                       for: incomingPlaybackContext
                   ) {
                    nextEpisodePlaybackContextOverride = selection.context
                    nextEpisodeResolvedTargetOverride = canonicalizedNextEpisodeTarget(
                        incomingResolvedTarget,
                        episode: selection.episode,
                        playbackContext: selection.context
                    )
                    selectedSpecialEpisodeContext = nil
                    selectedEpisodeForSearch = selection.episode
                    showingSearchResults = false
                    scheduleNextEpisodePresentation {
                        beginNewMainPlaybackSearchSession()
                        showingSearchResults = true
                    }
                    return
                }
                if let selection = canonicalSpecialWatchTogetherSelection(
                       for: incomingPlaybackContext
                   ) {
                    nextEpisodePlaybackContextOverride = selection.playbackContext
                    nextEpisodeResolvedTargetOverride = canonicalizedNextEpisodeTarget(
                        incomingResolvedTarget,
                        episode: selection.episode,
                        playbackContext: selection.playbackContext
                    )
                    selectedSpecialEpisodeContext = selection.context
                    selectedEpisodeForSearch = selection.episode
                    scheduleNextEpisodePresentation {
                        beginSpecialSearch(
                            context: selection.context,
                            episode: selection.episode,
                            playbackContextOverride: selection.playbackContext
                        )
                    }
                    return
                }

                Logger.shared.log(
                    "NextEpisode: Could not resolve the exact canonical anime episode context",
                    type: "Player"
                )
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
#if os(tvOS)
        .onChangeComp(of: isLoading) { _, _ in
            requestInitialTVFocusIfNeeded()
        }
#endif
        .onChangeComp(of: isLoadingAnimeSpecials) { _, loading in
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
        .onChangeComp(of: scenePhase) { _, newPhase in
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
                mediaYear: nextEpisodeResolvedTargetOverride?.mediaYear ?? sourceMatchingYear,
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
                autoModeOnly: watchTogetherAutoPlay != nil || watchTogetherNextEpisodeAutoPlay || AutoModeSettings.isEnabled(),
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
                mediaYear: sourceMatchingYear,
                animeSeasonTitle: isAnimeShow ? "anime" : nil,
                posterPath: searchResult.isMovie ? movieDetail?.posterPath : tvShowDetail?.posterPath,
                originalAudioLanguage: searchResult.originalLanguage ?? (searchResult.isMovie ? movieDetail?.originalLanguage : tvShowDetail?.originalLanguage),
                imdbId: searchResult.isMovie ? movieDetail?.imdbId : tvShowDetail?.externalIds?.imdbId,
                originalTMDBSeasonNumber: playbackContext?.resolvedTMDBSeasonNumber,
                originalTMDBEpisodeNumber: playbackContext?.resolvedTMDBEpisodeNumber,
                episodePlaybackContext: playbackContext,
                downloadMode: true,
                autoModeOnly: AutoModeSettings.isEnabled(),
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
                mediaYear: nextEpisodeResolvedTargetOverride?.mediaYear ?? sourceMatchingYear,
                animeSeasonTitle: request.title,
                posterPath: request.posterUrl ?? tvShowDetail?.posterPath,
                originalAudioLanguage: searchResult.originalLanguage ?? tvShowDetail?.originalLanguage,
                imdbId: request.imdbId ?? tvShowDetail?.externalIds?.imdbId,
                originalTMDBSeasonNumber: request.originalSeasonNumber,
                originalTMDBEpisodeNumber: request.originalEpisodeNumber,
                specialTitleOnlySearch: request.titleOnly,
                episodePlaybackContext: request.playbackContext,
                autoModeOnly: watchTogetherAutoPlay != nil || watchTogetherNextEpisodeAutoPlay || AutoModeSettings.isEnabled(),
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
                animeMediaIDs: notificationAnimeRegularMediaIDs,
                animeSpecialMediaIDs: notificationAnimeSpecialMediaIDs,
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
#if os(tvOS)

        .focusable()
        .focused($tvDetailFocus, equals: .loading)
#endif
    }

    @ViewBuilder
    private func errorView(_ message: String) -> some View {
        VStack {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: isTvOS ? 90 : 60))
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
#if os(tvOS)

                didRequestTVContentFocus = false
                tvDetailFocus = .loading
#endif
                loadMediaDetails()
            }
            .padding(.top)
#if os(tvOS)
            .focused($tvDetailFocus, equals: .error)
#endif
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
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .applyLiquidGlassBackground(cornerRadius: 22)
                }
                .accessibilityLabel("Back")

                Spacer()
            }
            .padding(.horizontal, 16)

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
                        tvAwareHeroImageSection
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
                .modifier(ScrollClipModifier())
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { newOffset in
                    guard abs(scrollOffset - newOffset) >= scrollOffsetUpdateThreshold else { return }
                    scrollOffset = newOffset
                }
                .onChangeComp(of: notificationEpisodeScrollGeneration) { _, _ in
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
                    .onChangeComp(of: notificationEpisodeScrollGeneration) { _, _ in
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

            .setProcessor(DownsamplingImageProcessor(size: homeImageDecodeSize(width: proxy.size.width, height: proxy.size.height)))
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
                .setProcessor(DownsamplingImageProcessor(size: homeImageDecodeSize(width: 380, height: 118)))
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
                    canUseMainPlayButton ? playButtonText : "No Sources",
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

        if !isIPad, mediaDetailTitleArtworkEnabled, mediaDetailAlternatePosterEnabled,
           let alternatePosterURL {
            return alternatePosterURL
        }

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
    private var tvAwareHeroImageSection: some View {
#if os(tvOS)
        heroImageSection
            .padding(.horizontal, -Self.tvHorizontalSafeInset)
#else
        heroImageSection
#endif
    }

#if os(tvOS)
    private static var tvHorizontalSafeInset: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        let inset = window?.safeAreaInsets.left ?? 0
        return inset > 0 ? inset : 80
    }
#endif

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
        VStack(alignment: .center, spacing: isTvOS ? 20 : (isIPad ? 13 : 10)) {
            titleArtwork

            if shouldShowHeroDetails, let metadata = detailMetadataLine {
                Text(metadata)
                    .font(.system(

                        size: isTvOS ? 29 : (isIPad ? 20 : (showFullMetadata ? 17 * 0.72 : 17)),
                        weight: .semibold
                    ))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(showFullMetadata ? nil : 1)
                    .minimumScaleFactor(showFullMetadata ? 1 : 0.72)
                    .fixedSize(horizontal: false, vertical: showFullMetadata)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, isTvOS ? 60 : (isIPad ? 36 : 20))
                    .shadow(color: .black.opacity(0.70), radius: 8, x: 0, y: 3)
                    .contentShape(Rectangle())
#if !os(tvOS)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            showFullMetadata.toggle()
                        }
                    }
                    .accessibilityHint("Tap to expand or collapse media details")
#endif
            }

            if shouldShowHeroActions {
                experimentalPlayAndBookmarkSection
                    .padding(.top, isTvOS ? 16 : (isIPad ? 6 : 2))
            }

            if shouldShowHeroOverview {
                experimentalHeroSynopsisSection
                    .padding(.top, isTvOS ? 12 : (isIPad ? 2 : 0))
            }

            if shouldShowHeroDetails {
                detailRatingChips
                    .padding(.top, isTvOS ? 12 : (isIPad ? 2 : 0))
            }
        }
        .frame(maxWidth: isIPad ? 520 : .infinity, alignment: .center)
        .padding(.top, isIPad ? 24 : 0)
        .padding(.bottom, isTvOS ? 60 : (isIPad ? 24 : 34))
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
                .setProcessor(DownsamplingImageProcessor(size: homeImageDecodeSize(width: isTvOS ? 720 : (isIPad ? 420 : 334), height: isTvOS ? 250 : 140)))
                .placeholder {
                    titleText
                }
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(
                    maxWidth: ExperimentalFeatureState.isEnabledAtLaunch ? (isTvOS ? 720 : (isIPad ? 420 : 334)) : (isIPad ? 400 : 280),
                    maxHeight: ExperimentalFeatureState.isEnabledAtLaunch ? (isTvOS ? 250 : 132) : (isIPad ? 140 : 100)
                )
                .shadow(color: .black.opacity(0.52), radius: 6, x: 0, y: 3)
                .padding(.horizontal, ExperimentalFeatureState.isEnabledAtLaunch ? (isTvOS ? 60 : (isIPad ? 36 : 26)) : 0)
        } else {
            titleText
                .padding(.horizontal, ExperimentalFeatureState.isEnabledAtLaunch ? (isTvOS ? 60 : (isIPad ? 36 : 26)) : 0)
        }
    }

    @ViewBuilder
    private var titleText: some View {
        Text(searchResult.displayTitle)
            .font(ExperimentalFeatureState.isEnabledAtLaunch ? .system(size: isTvOS ? 76 : (isIPad ? 44 : 40), weight: .heavy) : .largeTitle)
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

        let additionalGenres = additions.enumerated().map { index, name in
            TMDBGenre(id: -2_000_000 - index, name: name)
        }
        return additionalGenres + tmdbGenres
    }

    private var detailVoteAverage: Double? {
        searchResult.isMovie ? (movieDetail?.voteAverage ?? searchResult.voteAverage) : (tvShowDetail?.voteAverage ?? searchResult.voteAverage)
    }

    private var detailAgeRating: String? {
        if searchResult.isMovie {
            return movieDetail?.releaseDates?.preferredCertification?.value
        }

        return tvShowDetail?.contentRatings?.preferredCertification?.value
    }

    @ViewBuilder
    private var detailRatingChips: some View {
        let tmdbRating = detailVoteAverage
        let ageRating = mediaDetailAgeRatingEnabled ? detailAgeRating : nil
        if (tmdbRating ?? 0) > 0 || traktRating != nil || (isAnimeShow && animeRating?.source == .myAnimeList) || ageRating != nil {
            HStack(spacing: isTvOS ? 24 : (isIPad ? 15 : 11)) {
                if let tmdbRating, tmdbRating > 0 {
                    ratingChip(label: "TMDB", value: String(format: "%.1f", tmdbRating), tint: .cyan)
                }

                if let traktRating {
                    ratingChip(label: "Trakt", value: traktRating.displayText, tint: .red)
                }

                if isAnimeShow, let animeRating, animeRating.source == .myAnimeList {
                    ratingChip(label: "MAL", value: String(format: "%.1f", animeRating.value), tint: .blue)
                }

                if let ageRating {
                    ratingChip(label: "Age", value: ageRating, tint: .orange)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.74)
            .padding(.horizontal, isTvOS ? 60 : (isIPad ? 36 : 24))
        }
    }

    private func ratingChip(label: String, value: String, tint: Color) -> some View {
        HStack(spacing: isTvOS ? 9 : 5) {
            Text(label)
                .font(.system(size: isTvOS ? 16 : (isIPad ? 12 : 10), weight: .heavy))
                .foregroundColor(label == "TMDB" ? .white : tint)
                .padding(.horizontal, isTvOS ? 9 : 4)
                .padding(.vertical, isTvOS ? 5 : 2)
                .background(
                    RoundedRectangle(cornerRadius: isTvOS ? 5 : 3, style: .continuous)
                        .fill(label == "TMDB" ? tint.opacity(0.42) : tint.opacity(0.22))
                )
            Text(value)
                .font(.system(size: isTvOS ? 30 : (isIPad ? 21 : 18), weight: .semibold))
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
            VStack(spacing: isTvOS ? 20 : 10) {
                Text(showFullSynopsis ? overviewText : String(overviewText.prefix(240)) + (overviewText.count > 240 ? "..." : ""))
                    .font(.system(size: isTvOS ? 29 : (isIPad ? 21 : 18), weight: .regular))
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

            .padding(.horizontal, isTvOS ? 300 : (isIPad ? 80 : 28))
        }
    }

    @ViewBuilder
    private var experimentalHeroSynopsisSection: some View {
        if let overviewText = currentOverviewText {

            let canExpand = overviewText.count > 150
#if os(tvOS)
            VStack(spacing: 24) {
                Text(overviewText)
                    .font(.system(size: 29, weight: .regular))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(showFullSynopsis ? nil : 4)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                    .padding(.horizontal, 300)
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

                    Text(canUseMainPlayButton ? playButtonText : "No Sources")
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
#if os(tvOS)
            .focused($tvDetailFocus, equals: .play)
#endif

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
#if os(tvOS)
            .focused($tvDetailFocus, equals: .bookmark)
#endif

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
#if os(tvOS)
            .focused($tvDetailFocus, equals: .collection)
#endif
        }
        .padding(.horizontal)
    }

    private var playButtonCornerRadius: CGFloat {
        isTvOS ? 26 : (isIPad ? 20 : 17)
    }

    @ViewBuilder
    private var experimentalPlayAndBookmarkSection: some View {
        VStack(spacing: isTvOS ? 30 : (isIPad ? 18 : 15)) {
            Button(action: {
#if os(tvOS)
                if canUseMainPlayButton {
                    searchInServices()
                } else {
                    showingTVNoSourcesGuidance = true
                }
#else
                searchInServices()
#endif
            }) {
                Text(canUseMainPlayButton ? playButtonText : "No Sources")
                    .font(.system(size: isTvOS ? 34 : (isIPad ? 25 : 22), weight: .bold))
                    .foregroundColor(canUseMainPlayButton ? .black : .white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                    .frame(maxWidth: .infinity)
                    .frame(height: isTvOS ? 80 : (isIPad ? 58 : 52))
                    .background(
                        RoundedRectangle(cornerRadius: playButtonCornerRadius, style: .continuous)
                            .fill(canUseMainPlayButton ? Color.white.opacity(0.72) : Color.white.opacity(0.16))
                            .background(
                                RoundedRectangle(cornerRadius: playButtonCornerRadius, style: .continuous)
                                    .fill(.ultraThinMaterial)
                                    .opacity(0.72)
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: playButtonCornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.32), lineWidth: 1)
                    )
            }
#if os(tvOS)
            .buttonStyle(.card)
            .accessibilityLabel(canUseMainPlayButton ? playButtonText : "No playable source")
            .accessibilityHint(canUseMainPlayButton ? "Finds a stream and starts playback." : "Explains how to add a source.")
            .focused($tvDetailFocus, equals: .play)
            .alert("No Sources Installed", isPresented: $showingTVNoSourcesGuidance) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Eclipse ships without content sources. Add a Service or Stremio addon in Settings › Services, then come back to play this title.")
            }
#else
            .buttonStyle(PlainButtonStyle())
            .disabled(!canUseMainPlayButton)
#endif

            HStack(spacing: isTvOS ? 44 : (isIPad ? 30 : 22)) {
                experimentalActionButton(
                    systemName: "rectangle.stack.badge.plus",
                    foregroundColor: .white,
                    title: "Add to Collection",
                    hint: "Opens the collection picker."
                ) {
                    showingAddToCollection = true
                }
#if os(tvOS)
                .focused($tvDetailFocus, equals: .collection)
#endif

                experimentalActionButton(
                    systemName: isBookmarked ? "heart.fill" : "heart",
                    foregroundColor: .white,
                    title: "Bookmark",
                    hint: "Adds or removes this title from Bookmarks.",
                    selectionState: isBookmarked
                ) {
                    toggleBookmark()
                }
#if os(tvOS)
                .focused($tvDetailFocus, equals: .bookmark)
#endif

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
        .padding(.horizontal, isTvOS ? 60 : (isIPad ? 36 : 28))

#if os(tvOS)
        .frame(maxWidth: 900)
#endif
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
                .font(.system(size: isTvOS ? 34 : (isIPad ? 26 : 22), weight: .semibold))
                .foregroundColor(foregroundColor)
                .frame(width: isTvOS ? 72 : (isIPad ? 54 : 48), height: isTvOS ? 72 : (isIPad ? 54 : 48))
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

#if os(tvOS)

    private func requestInitialTVFocusIfNeeded() {
        if isLoading {
            DispatchQueue.main.async {
                guard self.isLoading, !self.didRequestTVContentFocus else { return }
                self.tvDetailFocus = .loading
            }
            return
        }

        guard !didRequestTVContentFocus else { return }
        didRequestTVContentFocus = true

        let target: TVDetailFocus
        if errorMessage != nil {
            target = .error
        } else if shouldShowHeroActions {
            target = canUseMainPlayButton ? .play : .collection
        } else {
            target = .content
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.tvDetailFocus = target
        }
    }
#endif

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
                animeProviderAliases: animeProviderAliases,
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
            canonicalAniListMediaId: animeSeasonAniListIds[episode.seasonNumber].flatMap {
                let canonical = canonicalAnimeProviderID($0)
                return canonical > 0 ? canonical : nil
            },
            malMediaId: exactAnimeMALID(
                for: animeSeasonAniListIds[episode.seasonNumber]
            ),
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

    private var experimentalExtrasCardWidth: CGFloat {
        isTvOS ? 480 : (isIPad ? 330 : 250)
    }

    private var experimentalExtrasCardHeight: CGFloat {
        isTvOS ? 270 : (isIPad ? 186 : 142)
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
                        ForEach(Array(detailStills.prefix(10).enumerated()), id: \.offset) { index, still in
                            ZStack(alignment: .topTrailing) {
                                KFImage(URL(string: still.fullURL))

                                    .setProcessor(DownsamplingImageProcessor(size: homeImageDecodeSize(width: experimentalExtrasCardWidth, height: experimentalExtrasCardHeight)))
                                    .placeholder {
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .fill(Color.white.opacity(0.08))
                                    }
                                    .resizable()
                                    .aspectRatio(16/9, contentMode: .fill)
                                    .frame(width: experimentalExtrasCardWidth, height: experimentalExtrasCardHeight)
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
#else
                            .focusable()
                            .focused($tvFocusedStillIndex, equals: index)
                            .scaleEffect(tvFocusedStillIndex == index ? 1.05 : 1.0)
                            .animation(.easeOut(duration: 0.16), value: tvFocusedStillIndex)
#endif
                        }
                    }
                    .padding(.horizontal)
#if os(tvOS)
                    .padding(.vertical, 12)
#endif
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
#if os(tvOS)
                                .buttonStyle(.card)
#else
                                .buttonStyle(.plain)
#endif
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

                    .frame(width: isTvOS ? 88 : 48, height: isTvOS ? 88 : 48)
                    .overlay(
                        Image(systemName: "play.fill")
                            .font(.headline)
                            .foregroundColor(.white)
                            .offset(x: 1)
                    )
            }
            .frame(width: experimentalExtrasCardWidth, height: experimentalExtrasCardHeight)
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
                .frame(width: experimentalExtrasCardWidth, alignment: .leading)
        }

#if os(tvOS)
        .padding(.vertical, 20)
#endif
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

#if os(tvOS)
                            .buttonStyle(.card)
#else
                            .buttonStyle(PlainButtonStyle())
#endif
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

#if os(tvOS)
        .padding(.vertical, 20)
#endif
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
                    ForEach(Array(castMembers.prefix(20).enumerated()), id: \.offset) { index, member in
                        VStack(spacing: 8) {
                            if let url = member.fullProfileURL {
                                KFImage(URL(string: url))

                                    .setProcessor(DownsamplingImageProcessor(size: homeImageDecodeSize(width: isTvOS ? 140 : 80, height: isTvOS ? 140 : 80)))
                                    .placeholder {
                                        castPlaceholder
                                    }
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: isTvOS ? 140 : 80, height: isTvOS ? 140 : 80)
                                    .clipShape(Circle())
                            } else {
                                castPlaceholder
                            }

                            Text(member.name)
                                .font(isTvOS ? .system(size: 23) : .caption)
                                .fontWeight(.medium)
                                .foregroundColor(.white)
                                .lineLimit(1)

                            if let character = member.character, !character.isEmpty {
                                Text(character)
                                    .font(isTvOS ? .system(size: 23) : .caption2)
                                    .foregroundColor(.white.opacity(0.5))
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: isTvOS ? 180 : 85)
#if os(tvOS)
                        .focusable()
                        .focused($tvFocusedCastIndex, equals: index)
                        .scaleEffect(tvFocusedCastIndex == index ? 1.1 : 1.0)
                        .animation(.easeOut(duration: 0.16), value: tvFocusedCastIndex)
#endif
                    }
                }
                .padding(.horizontal)
#if os(tvOS)
                .padding(.vertical, 12)
#endif
            }
        }
        .padding(.top, 8)
    }

    private var castPlaceholder: some View {
        Circle()
            .fill(Color.white.opacity(0.08))
            .frame(width: isTvOS ? 140 : 80, height: isTvOS ? 140 : 80)
            .overlay(
                Image(systemName: "person.fill")
                    .font(isTvOS ? .largeTitle : .title2)
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
#if os(tvOS)
                            .focusable()
                            .focused($tvFocusedTraktCommentID, equals: item.id)
                            .scaleEffect(tvFocusedTraktCommentID == item.id ? 1.02 : 1.0)
                            .animation(.easeOut(duration: 0.16), value: tvFocusedTraktCommentID)
#endif
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

        let cardWidth: CGFloat = isTvOS ? 200 : 96
        let posterHeight: CGFloat = isTvOS ? 300 : 144

        let titleHeight: CGFloat = isTvOS ? 76 : 34
        let checkmarkDiameter: CGFloat = isTvOS ? 40 : 22

        Button(action: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                selectSpecialEntry(entry)
            }
        }) {
            VStack(spacing: 8) {
                ZStack(alignment: .bottom) {
                    specialPoster(urlString: entry.posterUrl, fallbackText: entry.formatLabel, width: cardWidth, height: posterHeight)

                    LinearGradient(
                        colors: [.clear, Color.black.opacity(0.6)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    .frame(width: cardWidth, height: posterHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .allowsHitTesting(false)

                    Text(entry.episodeCount == 1 ? entry.formatLabel : "\(entry.formatLabel) · \(entry.episodeCount)")

                        .font(isTvOS ? Font.caption.weight(.bold) : Font.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .padding(.horizontal, isTvOS ? 14 : 7)
                        .padding(.vertical, isTvOS ? 6 : 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, isTvOS ? 14 : 7)
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
                            .font(isTvOS ? Font.caption.weight(.heavy) : Font.system(size: 11, weight: .heavy))
                            .foregroundColor(.white)
                            .frame(width: checkmarkDiameter, height: checkmarkDiameter)
                            .background(Circle().fill(accent))
                            .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1.5))
                            .padding(isTvOS ? 10 : 6)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .shadow(
                    color: isSelected ? accent.opacity(0.55) : Color.black.opacity(0.25),
                    radius: isSelected ? 12 : 5,
                    x: 0,
                    y: isSelected ? 6 : 3
                )

                .scaleEffect(isTvOS ? 1.0 : (isSelected ? 1.0 : 0.96))

                Text(entry.preferredTitle)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: cardWidth, height: titleHeight, alignment: .top)
                    .foregroundColor(isSelected ? .white : .white.opacity(0.65))
            }

#if os(tvOS)
            .padding(.vertical, 20)
#endif
        }

#if os(tvOS)
        .buttonStyle(.card)
#else
        .buttonStyle(PlainButtonStyle())
#endif
    }

    @ViewBuilder
    private func specialPoster(urlString: String?, fallbackText: String, width: CGFloat, height: CGFloat) -> some View {
        if let urlString, let url = URL(string: urlString) {
            KFImage(url)
                .setProcessor(DownsamplingImageProcessor(size: homeImageDecodeSize(width: width, height: height)))
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

    private func startAnimeSpecialsLoad(
        tmdbShowId: Int,
        fallbackPosterURL: String?,
        baseAniListIds: [Int] = [],
        detailCacheKey: String
    ) {
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
                let providerAliases = Self.addingAnimeSpecialAliases(
                    entries,
                    to: self.animeProviderAliases
                )
                self.animeProviderAliases = providerAliases
                self.animeSpecialEntries = entries
                if let selected = self.selectedSpecialEpisodeContext, !entries.contains(where: { $0.id == selected.id }) {
                    self.selectedSpecialEpisodeContext = nil
                }
                self.isLoadingAnimeSpecials = false
                self.specialsLoadTask = nil

                MediaDetailCacheStore.shared.updateSpecialEntries(
                    key: detailCacheKey,
                    entries: entries,
                    providerAliases: providerAliases
                )
                if !entries.isEmpty {
                    self.reconcileLoadedAnimeSpecials(
                        entries,
                        providerAliases: providerAliases
                    )
                }
                Logger.shared.log("MediaDetailView loaded specials: tmdbId=\(tmdbShowId) count=\(entries.count)", type: "AniList")
            }
        }
    }

    private func detailCacheKeyForCurrentRoute() -> String {
        let base = PerformanceModeSettings.detailCacheKey(for: searchResult.stableIdentity)
        let routeSuffix = (searchResult.animeIdentitySeed?.anilistId).map { "anilist-\($0)" }
        return [base, "lang-\(selectedLanguage)", routeSuffix]
            .compactMap { $0 }
            .joined(separator: "|")
    }

    private func resumeAnimeSpecialsLoadIfNeeded() {
        guard hasLoadedContent,
              isAnimeShow,
              isLoadingAnimeSpecials,
              specialsLoadTask == nil,
              let detail = tvShowDetail else {
            return
        }
        Logger.shared.log(
            "MediaDetailView resuming pending specials hydration: tmdbId=\(detail.id)",
            type: "AniList"
        )
        startAnimeSpecialsLoad(
            tmdbShowId: detail.id,
            fallbackPosterURL: detail.fullPosterURL,
            baseAniListIds: Array(animeSeasonAniListIds.values),
            detailCacheKey: detailCacheKeyForCurrentRoute()
        )
    }

    @MainActor
    private func reconcileLoadedAnimeSpecials(
        _ entries: [AniListSpecialSearchEntry],
        providerAliases: [Int: Int]
    ) {
        var regularSeasonByProviderID: [Int: Int] = [:]
        for (seasonNumber, storedID) in animeSeasonAniListIds {
            let canonicalID = providerAliases[storedID] ?? storedID
            regularSeasonByProviderID[storedID] = seasonNumber
            regularSeasonByProviderID[canonicalID] = seasonNumber
            for (alias, target) in providerAliases where target == canonicalID {
                regularSeasonByProviderID[alias] = seasonNumber
            }
        }

        var specialSeasonByProviderID: [Int: Int] = [:]
        var specialContexts: [EpisodePlaybackContext] = []
        for entry in entries {
            guard let context = SpecialEpisodeListContext(
                entry: entry,
                tmdbShowId: searchResult.id
            ) else { continue }
            let canonicalID = providerAliases[entry.id] ?? entry.id
            specialSeasonByProviderID[entry.id] = context.localSeasonNumber
            specialSeasonByProviderID[canonicalID] = context.localSeasonNumber
            for (alias, target) in providerAliases where target == canonicalID {
                specialSeasonByProviderID[alias] = context.localSeasonNumber
            }
            specialContexts.append(contentsOf: context.episodes.map {
                context.playbackContext(for: $0)
            })
        }

#if !os(tvOS)
        DownloadManager.shared.reconcileAnimeStructuralContexts(
            tmdbId: searchResult.id,
            canonicalContexts: specialContexts,
            canonicalProviderIDByStoredID: providerAliases
        )
#endif
        ProgressManager.shared.reconcileAnimeStructuralCoordinates(
            showId: searchResult.id,
            regularSeasonByAniListID: regularSeasonByProviderID,
            specialSeasonByAniListID: specialSeasonByProviderID,
            canonicalEpisodeContexts: specialContexts,
            canonicalProviderIDByStoredID: providerAliases
        )
#if !os(tvOS)
        LocalNotificationManager.shared.reconcileAnimeStructuralRoles(
            tmdbID: searchResult.id,
            regularMediaIDs: Set(regularSeasonByProviderID.keys),
            specialMediaIDs: Set(specialSeasonByProviderID.keys),
            canonicalProviderIDByStoredID: providerAliases
        )
#endif
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
            anilistId: entry.canonicalAniListId ?? context.anilistId
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

    private func watchTogetherSpecialContextIsCompatible(
        incoming: EpisodePlaybackContext,
        resolved: EpisodePlaybackContext
    ) -> Bool {
        guard resolved.isSpecial,
              watchTogetherProviderContextIsCompatible(
                  incoming: incoming,
                  resolved: resolved
              ) else {
            return false
        }
        return true
    }

    private func watchTogetherProviderContextIsCompatible(
        incoming: EpisodePlaybackContext,
        resolved: EpisodePlaybackContext
    ) -> Bool {
        AnimeEpisodeIdentityPolicy.isSameEpisode(
            incoming,
            resolved,
            providerAliases: animeProviderAliases
        )
    }

    private func canonicalRegularWatchTogetherSelection(
        for incoming: EpisodePlaybackContext
    ) -> (episode: TMDBEpisode, context: EpisodePlaybackContext)? {
        var candidates: [AniListEpisode] = []
        if let tmdbSeason = incoming.resolvedTMDBSeasonNumber,
           let tmdbEpisode = incoming.resolvedTMDBEpisodeNumber {
            candidates = anilistEpisodes?.filter {
                $0.tmdbSeasonNumber == tmdbSeason
                    && $0.tmdbEpisodeNumber == tmdbEpisode
            } ?? []
        }
        candidates += anilistEpisodes?.filter {
            $0.seasonNumber == incoming.localSeasonNumber
                && $0.number == incoming.localEpisodeNumber
        } ?? []
        candidates += anilistEpisodes?.filter {
            $0.seasonNumber != incoming.localSeasonNumber
                && $0.number == incoming.localEpisodeNumber
        } ?? []
        for animeEpisode in candidates {
            let episode = tmdbEpisode(from: animeEpisode)
            guard let resolved = playbackContextForSearchSheet(episode),
                  watchTogetherProviderContextIsCompatible(
                      incoming: incoming,
                      resolved: resolved
                  ) else { continue }
            return (episode, resolved)
        }
        return nil
    }

    private func canonicalSpecialWatchTogetherSelection(
        for incoming: EpisodePlaybackContext
    ) -> (context: SpecialEpisodeListContext, episode: TMDBEpisode, playbackContext: EpisodePlaybackContext)? {
        canonicalSpecialMatch(for: incoming)
    }

    private func canonicalizedNextEpisodeTarget(
        _ target: ResolvedNextEpisodeTarget?,
        episode: TMDBEpisode,
        playbackContext: EpisodePlaybackContext
    ) -> ResolvedNextEpisodeTarget? {
        guard let target else { return nil }
        return ResolvedNextEpisodeTarget(
            showID: target.showID,
            episode: episode,
            playbackContext: playbackContext,
            mediaTitle: target.mediaTitle,
            seasonTitleOverride: target.seasonTitleOverride,
            originalTitle: target.originalTitle,
            posterURL: target.posterURL,
            imdbID: target.imdbID,
            isAnime: target.isAnime,
            isAnimation: target.isAnimation,
            mediaYear: target.mediaYear
        )
    }

    private func exactSpecialSelection(
        for incoming: EpisodePlaybackContext
    ) -> (context: SpecialEpisodeListContext, episode: TMDBEpisode)? {
        guard let match = canonicalSpecialMatch(for: incoming),
              watchTogetherSpecialContextIsCompatible(
                  incoming: incoming,
                  resolved: match.playbackContext
              ) else { return nil }
        return (match.context, match.episode)
    }

    private func canonicalSpecialMatch(
        for incoming: EpisodePlaybackContext
    ) -> (context: SpecialEpisodeListContext, episode: TMDBEpisode, playbackContext: EpisodePlaybackContext)? {
        for entry in animeSpecialEntries {
            guard let context = SpecialEpisodeListContext(
                entry: entry,
                tmdbShowId: searchResult.id
            ) else { continue }
            var candidates: [TMDBEpisode] = []
            if let tmdbSeason = incoming.resolvedTMDBSeasonNumber,
               let tmdbEpisode = incoming.resolvedTMDBEpisodeNumber {
                candidates = context.episodes.filter {
                    let resolved = context.playbackContext(for: $0)
                    return resolved.resolvedTMDBSeasonNumber == tmdbSeason
                        && resolved.resolvedTMDBEpisodeNumber == tmdbEpisode
                }
            }
            candidates += context.episodes.filter { episode in
                episode.episodeNumber == incoming.localEpisodeNumber
                    && !candidates.contains(where: { $0.id == episode.id })
            }
            for episode in candidates {
                let resolved = context.playbackContext(for: episode)
                if watchTogetherProviderContextIsCompatible(
                    incoming: incoming,
                    resolved: resolved
                ) {
                    return (context, episode, resolved)
                }
            }
        }
        return nil
    }

    private func beginSpecialSearch(
        context: SpecialEpisodeListContext,
        episode: TMDBEpisode?,
        playbackContextOverride: EpisodePlaybackContext? = nil
    ) {
        guard hasActiveSources else { return }

        let resolvedPlaybackContext = episode.map { context.playbackContext(for: $0) }
        let playbackContext = playbackContextOverride ?? resolvedPlaybackContext
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
                if let selection = canonicalRegularWatchTogetherSelection(for: context) {
                    watchTogetherPlaybackContextOverride = selection.context
                    selectedSpecialEpisodeContext = nil
                    selectedEpisodeForSearch = selection.episode
                    beginNewMainPlaybackSearchSession()
                    showingSearchResults = true
                    return
                }

                guard let selection = canonicalSpecialWatchTogetherSelection(for: context) else {
                    failWatchTogetherPlayback(
                        context.isSpecial
                            ? "Watch Together could not resolve the exact anime special on this device. It stopped instead of falling back to TMDB."
                            : watchTogetherAnimeEpisodeFailureMessage(for: context)
                    )
                    return
                }
                watchTogetherPlaybackContextOverride = selection.playbackContext
                selectedSpecialEpisodeContext = selection.context
                selectedEpisodeForSearch = selection.episode
                beginSpecialSearch(
                    context: selection.context,
                    episode: selection.episode,
                    playbackContextOverride: selection.playbackContext
                )
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

        if let seasonDetail,
           seasonDetail.seasonNumber == context.localSeasonNumber,
           let hydrated = seasonDetail.episodes.first(where: {
               $0.episodeNumber == context.localEpisodeNumber
           }) {
            return hydrated
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

            return nil
        }

        return TMDBEpisode(
            id: RemoteMediaNumericBoundary.syntheticIdentifier([
                (searchResult.id, 10_000),
                (context.localSeasonNumber, 1_000),
                (context.localEpisodeNumber, 1)
            ]),
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
        watchTogetherAutoPlayFailureCount += 1
        if watchTogetherAutoPlayFailureCount <= 3 {
            didStartWatchTogetherAutoPlay = false
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                startWatchTogetherPlaybackIfReady()
            }
        }
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
                playDownloadedItem(
                    item,
                    canonicalPlaybackContext: specialContext.playbackContext(for: episode)
                )
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
            playDownloadedItem(
                item,
                canonicalPlaybackContext: playbackContextForSearchSheet(episode)
            )
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
            animeSeasonAniListIds.first(where: {
                animeProviderIDsMatch($0.value, sourceMediaID)
            })?.key
        }
        let mappedAnimeSpecialEntry = selection.sourceMediaID.flatMap { sourceMediaID in
            animeSpecialEntries.first {
                animeProviderIDsMatch($0.id, sourceMediaID)
            }
        }

        if mappedAnimeSeasonNumber == nil,
           selection.isAnimeSpecial || mappedAnimeSpecialEntry != nil {
            guard !isLoadingAnimeSpecials else { return }
            if let entry = mappedAnimeSpecialEntry,
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

            targetSeasonNumber = animeSeasonAniListIds.first(where: {
                animeProviderIDsMatch($0.value, sourceMediaID)
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
            id: RemoteMediaNumericBoundary.syntheticIdentifier([
                (searchResult.id, 1_000_000),
                (aniEpisode.seasonNumber, 10_000),
                (aniEpisode.number, 1)
            ]),
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
        let context = selectedSpecialEpisodeContext?.playbackContext(for: episode)
            ?? playbackContextForSearchSheet(episode)
        return downloadManager.completedEpisodeDownloadItem(
            tmdbId: searchResult.id,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber,
            playbackContext: context
        )
    }

    private func latestDownloadedItemForShow() -> DownloadItem? {

        guard !isAnimeShow else { return nil }
        return downloadManager.completedDownloads
            .filter { !$0.isMovie && $0.tmdbId == searchResult.id && downloadManager.localFileURL(for: $0) != nil }
            .sorted {
                let lhsDate = $0.dateCompleted ?? $0.dateAdded
                let rhsDate = $1.dateCompleted ?? $1.dateAdded
                return lhsDate > rhsDate
            }
            .first
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

        guard let originatingPresenter = presenter ?? UIApplication.shared.eclipseTopmostViewController() else {
            Logger.shared.log("Downloaded playback has no presenter", type: "Player")
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
        let nextEpisodeRequest: ((_ seasonNumber: Int, _ episodeNumber: Int) -> Void)? = item.isMovie ? nil : { [weak originatingPresenter] seasonNumber, episodeNumber in
            guard let originatingPresenter else { return }
            let nextContext = downloadedPlaybackContext(
                currentContext: effectiveContext,
                isAnime: item.isAnime || effectiveContext?.hasAnimeMediaId == true,
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
        let localNextEpisode: DownloadItem? = item.isMovie ? nil : nextDownloadedEpisode(
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
            isAnimation: detailGenres.contains { $0.id == 16 },
            originalTMDBSeasonNumber: effectiveContext?.resolvedTMDBSeasonNumber,
            originalTMDBEpisodeNumber: effectiveContext?.resolvedTMDBEpisodeNumber,
            onRequestNextEpisode: nextEpisodeRequest,
            localNextEpisodeFallback: PlaybackEpisodeCoordinate(
                seasonNumber: localNextEpisode == nil ? nil : nextSeasonNumber,
                episodeNumber: localNextEpisode == nil ? nil : nextEpisodeNumber
            )
        )
        PlaybackCoordinator.shared.present(request, from: originatingPresenter)
    }

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
        let isAnimeRequest = currentItem?.isAnime == true
            || currentContext?.hasAnimeMediaId == true
        let requestedContext = downloadedPlaybackContext(
            currentContext: currentContext,
            isAnime: isAnimeRequest,
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
        isAnime: Bool,
        requestedSeasonNumber: Int,
        requestedEpisodeNumber: Int
    ) -> EpisodePlaybackContext? {
        if let currentContext,
           currentContext.localSeasonNumber == requestedSeasonNumber {
            return currentContext.forEpisodeNumber(requestedEpisodeNumber)
        }
        guard isAnime else { return nil }
        let placeholder = TMDBEpisode(
            id: RemoteMediaNumericBoundary.syntheticIdentifier([
                (searchResult.id, 1_000_000),
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
        return playbackContextForSearchSheet(placeholder)
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
            let context = selectedSpecialEpisodeContext?.playbackContext(for: ep)
                ?? playbackContextForSearchSheet(ep)
            return DownloadManager.shared.activeEpisodeDownloadItem(
                tmdbId: searchResult.id,
                seasonNumber: ep.seasonNumber,
                episodeNumber: ep.episodeNumber,
                playbackContext: context
            ) != nil
        }
        return false
    }

    private var isAlreadyDownloaded: Bool {
        if searchResult.isMovie {
            return DownloadManager.shared.isDownloaded(tmdbId: searchResult.id, isMovie: true)
        } else if let ep = selectedEpisodeForSearch {
            return downloadedItem(for: ep) != nil
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

            let filteredResults = await Self.filteredSimilarTitles(
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
    ) async -> [TMDBSearchResult] {
        var seen = Set<String>()
        var candidates: [TMDBSearchResult] = []

        for result in results {
            guard result.id != currentId,
                  result.isMovie == isMovie,
                  result.adult != true,
                  seen.insert(result.stableIdentity).inserted else {
                continue
            }
            candidates.append(result)

            if candidates.count >= 40 { break }
        }

        let allowed = await TMDBContentFilter.shared.filterSearchResultsResolvingRatings(candidates)
        return Array(allowed.prefix(15))
    }

    private struct ResolvedAnimeDetailMetadata {
        let anime: AniListAnimeWithSeasons?
        let rating: AnimeMetadataRating?
        let specialEntries: [AniListSpecialSearchEntry]
        let shouldLoadSpecialsAfterReveal: Bool
        let initialSeasonNumber: Int?
        let initialSeasonDetail: TMDBSeasonDetail?
        let initialEpisodeNumber: Int?
        let initialSpecialID: Int?
        let initialRouteNotice: String?

        let needsBackgroundRevalidation: Bool
    }

    private func prefetchExactAnimeSnapshotIfNeeded() async -> Bool {
        guard !searchResult.isMovie else { return false }
        let catalogSeedID = searchResult.animeIdentitySeed?.anilistId
        let seedID = exactAnimeNavigationSeedAniListId ?? catalogSeedID
        if seedID == nil {
            let asianCountries: Set<String> = ["JP", "CN", "KR", "TW"]
            let asianLanguages: Set<String> = ["ja", "zh", "ko"]
            let looksLikeAnimeCard = searchResult.isAnimeHint == true
                || (searchResult.genreIds?.contains(16) == true
                    && (
                    searchResult.originCountry?.contains(where: asianCountries.contains) == true
                        || searchResult.originalLanguage.map(asianLanguages.contains) == true
                    ))
            guard looksLikeAnimeCard else { return false }
        }

        let allowStaleSnapshot = initialNotificationSelection == nil
            && watchTogetherAutoPlay == nil
        return await AniListService.shared.prefetchAnimeDetailSnapshot(
            tmdbShowId: searchResult.id,
            seedAniListId: seedID,
            seedMALId: searchResult.animeIdentitySeed?.malId,
            allowStaleSnapshot: allowStaleSnapshot
        )
    }

    private func resolveRequiredAnimeSpecials(
        for detail: TMDBTVShowWithSeasons,
        animeData: AniListAnimeWithSeasons,
        requiredSpecialAniListIDs: [Int]
    ) async throws -> [AniListSpecialSearchEntry] {
        if animeData.id < 0 {
            guard let rootMALID = RemoteMediaNumericBoundary.positiveIdentifier(animeData.malId)
                ?? RemoteMediaNumericBoundary.positiveMagnitude(animeData.id) else {
                return []
            }
            return try await AniListService.shared.fetchRequiredMALSpecialSearchEntries(
                tmdbShowId: detail.id,
                rootMalId: rootMALID,
                fallbackPosterURL: detail.fullPosterURL
            )
        }
        return try await AniListService.shared.fetchRequiredSpecialSearchEntries(
            tmdbShowId: detail.id,
            fallbackPosterURL: detail.fullPosterURL,
            baseAniListIds: animeData.seasons.map(\.anilistId),
            requiredSpecialAniListIds: requiredSpecialAniListIDs,
            tmdbService: tmdbService
        )
    }

    private func prepareInitialAnimeSeasonDetail(
        show: TMDBTVShowWithSeasons,
        animeData: AniListAnimeWithSeasons,
        localSeasonNumber: Int?,
        targetEpisodeNumber: Int?
    ) async throws -> TMDBSeasonDetail? {
        guard let localSeasonNumber,
              let animeSeason = animeData.seasons.first(where: { $0.seasonNumber == localSeasonNumber }) else {
            return nil
        }
        let projectedSeason = TMDBSeason(
            id: RemoteMediaNumericBoundary.syntheticIdentifier([
                (show.id, 1_000),
                (animeSeason.seasonNumber, 1)
            ]),
            name: animeSeason.title,
            overview: "",
            posterPath: animeSeason.posterUrl ?? show.posterPath,
            seasonNumber: animeSeason.seasonNumber,
            episodeCount: animeSeason.episodes.count,
            airDate: nil
        )

        if animeSeason.seasonNumber == animeData.seasons.first?.seasonNumber {
            let episodes = animeSeason.episodes.sorted(by: episodeSort).map { tmdbEpisode(from: $0) }
            var detail = TMDBSeasonDetail(
                id: projectedSeason.id,
                name: projectedSeason.name,
                overview: projectedSeason.overview ?? "",
                posterPath: projectedSeason.posterPath,
                seasonNumber: projectedSeason.seasonNumber,
                airDate: projectedSeason.airDate,
                episodes: episodes
            )

            if let targetEpisodeNumber,
               let targetIndex = animeSeason.episodes.firstIndex(where: { $0.number == targetEpisodeNumber }),
               animeSeason.episodes[targetIndex].airDate == nil {
                let pageSize = 100
                let pageStart = (targetIndex / pageSize) * pageSize
                let pageEnd = min(pageStart + pageSize, animeSeason.episodes.count)
                let hydratedPage = try await AniListService.shared.hydrateAnimeSeasonDetail(
                    tmdbShowId: show.id,
                    season: projectedSeason,
                    episodes: Array(animeSeason.episodes[pageStart..<pageEnd]),
                    tmdbService: tmdbService
                )
                let replacements = Dictionary(
                    hydratedPage.episodes.map { ($0.episodeNumber, $0) },
                    uniquingKeysWith: { existing, _ in existing }
                )
                detail = TMDBSeasonDetail(
                    id: detail.id,
                    name: detail.name,
                    overview: detail.overview,
                    posterPath: detail.posterPath,
                    seasonNumber: detail.seasonNumber,
                    airDate: detail.airDate,
                    episodes: detail.episodes.map { replacements[$0.episodeNumber] ?? $0 }
                )
            }
            return detail
        }

        return try await AniListService.shared.hydrateAnimeSeasonDetail(
            tmdbShowId: show.id,
            season: projectedSeason,
            episodes: animeSeason.episodes,
            tmdbService: tmdbService
        )
    }

    private func resolveAnimeDetailMetadata(
        for detail: TMDBTVShowWithSeasons,
        detectedAsAnime: Bool,
        performanceModeEnabled: Bool,
        skipAniListTraversal: Bool,
        prefetchedSeedHasRegularMapping: Bool,
        allowStaleRevalidation: Bool = false
    ) async throws -> ResolvedAnimeDetailMetadata {
        guard detectedAsAnime else {
            Logger.shared.log("MediaDetailView: Skipping AniList fetch - not detected as anime", type: "AniList")
            return ResolvedAnimeDetailMetadata(
                anime: nil,
                rating: nil,
                specialEntries: [],
                shouldLoadSpecialsAfterReveal: false,
                initialSeasonNumber: nil,
                initialSeasonDetail: nil,
                initialEpisodeNumber: nil,
                initialSpecialID: nil,
                initialRouteNotice: nil,
                needsBackgroundRevalidation: false
            )
        }

        let watchTargetRequiresAnime = watchTogetherAutoPlay.map {
            $0.isAnime || $0.playbackContext?.hasAnimeMediaId == true
        } ?? false
        if watchTargetRequiresAnime, let target = watchTogetherAutoPlay {
            if let failure = target.animeContextFailureReason {
                throw NSError(
                    domain: "WatchTogether",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: failure]
                )
            }
            guard let context = target.playbackContext, context.hasAnimeMediaId else {
                throw NSError(
                    domain: "WatchTogether",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Watch Together could not read the exact anime episode context."]
                )
            }
        }

        if skipAniListTraversal {
            Logger.shared.log(
                "MediaDetailView: Skipping AniList traversal for \(detail.name) because detail traversal performance mode is enabled",
                type: "AniList"
            )

            let rating = detail.voteAverage > 0
                ? AnimeMetadataRating(value: detail.voteAverage, source: .tmdb)
                : nil
            if watchTargetRequiresAnime {
                throw NSError(
                    domain: "WatchTogether",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Watch Together requires full anime detail metadata for an exact handoff."]
                )
            }
            return ResolvedAnimeDetailMetadata(
                anime: nil,
                rating: rating,
                specialEntries: [],
                shouldLoadSpecialsAfterReveal: false,
                initialSeasonNumber: nil,
                initialSeasonDetail: nil,
                initialEpisodeNumber: nil,
                initialSpecialID: nil,
                initialRouteNotice: nil,
                needsBackgroundRevalidation: false
            )
        }

        let animeData: AniListAnimeWithSeasons
        var animeDataNeedsRevalidation = false
        do {
            try Task.checkCancellation()
            Logger.shared.log(
                "MediaDetailView: Starting AniMap-backed anime detail fetch for \(detail.name) (tmdbId=\(detail.id)) performanceMode=\(performanceModeEnabled)",
                type: "AniList"
            )
            let navigationSeed = exactAnimeNavigationSeedAniListId
                ?? searchResult.animeIdentitySeed?.anilistId
            let detailSeedAniListID = navigationSeed.flatMap { seed in
                seed < 0 || prefetchedSeedHasRegularMapping ? seed : nil
            }

            if watchTogetherAutoPlay == nil,
               let fresh = await AniListService.shared.cachedAnimeDetailsForImmediateReveal(
                title: detail.name,
                tmdbShowId: detail.id,
                seedAniListId: detailSeedAniListID,
                seedMALId: searchResult.animeIdentitySeed?.malId
            ) {
                animeData = fresh
            } else if allowStaleRevalidation,

                      let stale = await AniListService.shared.staleAnimeDetailsForRevalidation(
                          title: detail.name,
                          tmdbShowId: detail.id,
                          seedAniListId: navigationSeed,
                          seedMALId: searchResult.animeIdentitySeed?.malId
                      ) {
                Logger.shared.log(
                    "MediaDetailView: revealing stale anime graph for tmdbId=\(detail.id); background revalidation will follow",
                    type: "AniList"
                )
                animeData = stale
                animeDataNeedsRevalidation = true
            } else {
                animeData = try await AniListService.shared.fetchAnimeDetailsWithEpisodes(
                    title: detail.name,
                    tmdbShowId: detail.id,
                    tmdbService: tmdbService,
                    tmdbShowPoster: detail.fullPosterURL,
                    token: nil,
                    seedAniListId: detailSeedAniListID,
                    seedMALId: searchResult.animeIdentitySeed?.malId,
                    hydrationPolicy: watchTogetherAutoPlay != nil ? .complete : .initiallyVisible,
                    knownTMDBShowDetail: detail
                )
            }
            try Task.checkCancellation()
            Logger.shared.log(
                "MediaDetailView: Fetched AniList hybrid data for \(detail.name) with \(animeData.seasons.count) seasons, \(animeData.totalEpisodes) total episodes",
                type: "AniList"
            )

            let seasonMappings = animeData.seasons.map {
                (
                    seasonNumber: $0.seasonNumber,
                    anilistId: $0.canonicalAniListId ?? $0.anilistId
                )
            }
            TrackerManager.shared.registerAniListAnimeData(tmdbId: detail.id, seasons: seasonMappings)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            Logger.shared.log(
                "MediaDetailView: FAILED AniList fetch for \(detail.name): \(error.localizedDescription)",
                type: "Error"
            )
            throw error
        }

        try Task.checkCancellation()
        let regularProviderAliases = Self.animeProviderAliasMap(
            seasons: animeData.seasons
        )
        func regularProviderIDsMatch(_ lhs: Int, _ rhs: Int) -> Bool {
            Self.animeProviderIDsMatch(
                lhs,
                rhs,
                aliases: regularProviderAliases
            )
        }
        let notificationMappedSeason: AniListSeasonWithPoster? = initialNotificationSelection.flatMap { selection in
            guard selection.source == .anime,
                  let sourceMediaID = selection.sourceMediaID else { return nil }
            return animeData.seasons.first {
                regularProviderIDsMatch($0.anilistId, sourceMediaID)
            }
        }
        let notificationSpecialID: Int? = initialNotificationSelection.flatMap { selection in
            if selection.source == .anime, let sourceMediaID = selection.sourceMediaID {

                return notificationMappedSeason == nil ? sourceMediaID : nil
            }
            return selection.isAnimeSpecial ? selection.sourceMediaID : nil
        }

        func regularSelection(
            matching context: EpisodePlaybackContext
        ) -> (season: AniListSeasonWithPoster, episode: AniListEpisode)? {
            for candidateSeason in animeData.seasons {
                var candidateEpisodes: [AniListEpisode] = []
                if let tmdbSeason = context.resolvedTMDBSeasonNumber,
                   let tmdbEpisode = context.resolvedTMDBEpisodeNumber {
                    candidateEpisodes = candidateSeason.episodes.filter {
                        $0.tmdbSeasonNumber == tmdbSeason
                            && $0.tmdbEpisodeNumber == tmdbEpisode
                    }
                }
                candidateEpisodes += candidateSeason.episodes.filter { episode in
                    episode.number == context.localEpisodeNumber
                        && !candidateEpisodes.contains(where: { $0.number == episode.number })
                }
                for episode in candidateEpisodes {
                    let resolved = EpisodePlaybackContext(
                        localSeasonNumber: candidateSeason.seasonNumber,
                        localEpisodeNumber: episode.number,
                        anilistMediaId: candidateSeason.anilistId,
                        canonicalAniListMediaId: candidateSeason.canonicalAniListId
                            ?? (candidateSeason.anilistId > 0 ? candidateSeason.anilistId : nil),
                        malMediaId: candidateSeason.malId,
                        kitsuMediaId: candidateSeason.kitsuId,
                        tmdbSeasonNumber: episode.tmdbSeasonNumber,
                        tmdbEpisodeNumber: episode.tmdbEpisodeNumber,
                        tmdbEpisodeOffset: nil,
                        animeAbsoluteEpisodeNumber: nil,
                        animeSeasonEpisodeCount: candidateSeason.episodes.count,
                        isSpecial: false,
                        titleOnlySearch: false
                    )
                    if AnimeEpisodeIdentityPolicy.isSameEpisode(
                        context,
                        resolved,
                        providerAliases: regularProviderAliases
                    ) {
                        return (candidateSeason, episode)
                    }
                }
            }
            return nil
        }

        let watchContext = watchTogetherAutoPlay?.playbackContext
        let watchRegularSelection = watchContext.flatMap { regularSelection(matching: $0) }
        let watchRegularSeason = watchRegularSelection?.season
        let watchSpecialID = watchContext.flatMap { context in
            watchRegularSeason == nil ? context.anilistMediaId : nil
        }
        let catalogSeedID = searchResult.animeIdentitySeed?.anilistId
        let catalogMALProviderID = RemoteMediaNumericBoundary.negativeProviderIdentifier(
            searchResult.animeIdentitySeed?.malId
        )
        let catalogProviderID = animeData.id < 0
            ? (catalogMALProviderID ?? catalogSeedID)
            : catalogSeedID
        let catalogRegularSeason = catalogProviderID.flatMap { id in
            animeData.seasons.first {
                regularProviderIDsMatch($0.anilistId, id)
            }
        }
        let catalogSpecialID = catalogRegularSeason == nil ? catalogProviderID : nil
        var initialSpecialID: Int?
        if initialNotificationSelection != nil {
            initialSpecialID = notificationSpecialID
        } else if watchContext != nil {
            initialSpecialID = watchSpecialID
        } else {
            initialSpecialID = catalogSpecialID
        }
        var initialEpisodeNumber = initialNotificationSelection?.episodeNumber
            ?? watchRegularSelection?.episode.number
            ?? watchContext?.localEpisodeNumber

        var requestedSeason: AniListSeasonWithPoster?
        var initialRouteNotice: String?
        if let selection = initialNotificationSelection {
            if let notificationMappedSeason {
                requestedSeason = notificationMappedSeason
            } else if notificationSpecialID == nil {
                if selection.source == .anime, selection.sourceMediaID != nil {
                    initialRouteNotice = "Eclipse opened the show, but this anime target could not be matched safely on this device."
                } else if selection.isAnimeSpecial {
                    initialRouteNotice = "Eclipse opened the show, but this special could not be matched safely on this device."
                } else if let seasonNumber = selection.seasonNumber {
                    requestedSeason = animeData.seasons.first { $0.seasonNumber == seasonNumber }
                }
            }
            if notificationSpecialID == nil,
               requestedSeason == nil,
               initialRouteNotice == nil {
                if let seasonNumber = selection.seasonNumber {
                requestedSeason = animeData.seasons.first { $0.seasonNumber == seasonNumber }
                }
                if requestedSeason == nil {
                    initialRouteNotice = "Eclipse opened the show, but this anime season could not be matched safely on this device."
                }
            }
        } else if watchTargetRequiresAnime,
                  watchContext != nil,
                  let watchRegularSelection {
            let watchRegularSeason = watchRegularSelection.season
            requestedSeason = watchRegularSeason
        } else if let catalogRegularSeason {
            requestedSeason = catalogRegularSeason
        }

        var initialSeasonNumber: Int? = initialSpecialID == nil
            ? (requestedSeason?.seasonNumber ?? animeData.seasons.first?.seasonNumber)
            : nil
        let initialSeasonNumberForHydration = initialSeasonNumber
        let initialEpisodeNumberForHydration = initialEpisodeNumber

        let requiredSpecialAniListIDs = [initialSpecialID].compactMap { $0 }

        let requiresSpecialsBeforeReveal = initialSpecialID != nil
            || (watchTargetRequiresAnime && watchRegularSelection == nil)
        async let ratingTask = AniListService.shared.detailReadyAnimeRating(
            tmdbShowDetail: detail,
            animeData: animeData
        )
        async let specialsTask: [AniListSpecialSearchEntry] = {
            guard requiresSpecialsBeforeReveal else { return [] }
            return try await resolveRequiredAnimeSpecials(
                for: detail,
                animeData: animeData,
                requiredSpecialAniListIDs: requiredSpecialAniListIDs
            )
        }()
        async let initialSeasonDetailTask = prepareInitialAnimeSeasonDetail(
            show: detail,
            animeData: animeData,
            localSeasonNumber: initialSeasonNumberForHydration,
            targetEpisodeNumber: initialEpisodeNumberForHydration
        )
        let rating = await ratingTask
        let specials = try await specialsTask
        var initialSeasonDetail = try await initialSeasonDetailTask
        let providerAliases = Self.animeProviderAliasMap(
            seasons: animeData.seasons,
            specials: specials
        )

        func specialSelection(
            matching context: EpisodePlaybackContext
        ) -> (entry: AniListSpecialSearchEntry, episode: AniListEpisode)? {
            for entry in specials {
                let candidateEpisodes: [AniListEpisode]
                if let tmdbSeason = context.resolvedTMDBSeasonNumber,
                   let tmdbEpisode = context.resolvedTMDBEpisodeNumber {
                    candidateEpisodes = entry.episodes.filter {
                        $0.tmdbSeasonNumber == tmdbSeason
                            && $0.tmdbEpisodeNumber == tmdbEpisode
                    }
                } else {
                    candidateEpisodes = entry.episodes.filter {
                        $0.number == context.localEpisodeNumber
                    }
                }
                for episode in candidateEpisodes {
                    guard let localSeasonNumber = AnimeSyntheticSeasonKey.make(
                        providerID: entry.id
                    ) else { continue }
                    let resolved = EpisodePlaybackContext(
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
                        animeSeasonEpisodeCount: entry.episodes.count,
                        isSpecial: true,
                        titleOnlySearch: episode.tmdbSeasonNumber == nil
                    )
                    if AnimeEpisodeIdentityPolicy.isSameEpisode(
                        context,
                        resolved,
                        providerAliases: providerAliases
                    ) {
                        return (entry, episode)
                    }
                }
            }
            return nil
        }

        if let requestedSpecialID = initialSpecialID,
           let matchedEntry = specials.first(where: {
               Self.animeProviderIDsMatch(
                   $0.id,
                   requestedSpecialID,
                   aliases: providerAliases
               )
           }) {
            initialSpecialID = matchedEntry.id
        }

        if watchTargetRequiresAnime,
           let context = watchContext,
           watchRegularSeason == nil,
           let selection = specialSelection(matching: context) {
            initialSpecialID = selection.entry.id
            initialEpisodeNumber = selection.episode.number
            initialSeasonNumber = nil
            initialSeasonDetail = nil
        }

        if let requestedSpecialID = initialSpecialID,
           !specials.contains(where: {
               Self.animeProviderIDsMatch(
                   $0.id,
                   requestedSpecialID,
                   aliases: providerAliases
               )
           }) {
            if watchTargetRequiresAnime || catalogSpecialID != nil {
                throw NSError(
                    domain: watchTargetRequiresAnime ? "WatchTogether" : "AnimeDetail",
                    code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "This anime special could not be matched safely on this device."]
                )
            }
            initialRouteNotice = "Eclipse opened the show, but this special could not be matched safely on this device."
            initialSpecialID = nil
            initialSeasonNumber = animeData.seasons.first?.seasonNumber
            initialSeasonDetail = try await prepareInitialAnimeSeasonDetail(
                show: detail,
                animeData: animeData,
                localSeasonNumber: initialSeasonNumber,
                targetEpisodeNumber: nil
            )
        }

        if watchTargetRequiresAnime,
           let context = watchContext {
            let isResolvable = watchRegularSelection != nil
                || specialSelection(matching: context) != nil
            guard isResolvable else {
                throw NSError(
                    domain: "WatchTogether",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Watch Together could not resolve the exact anime episode on this device."]
                )
            }
        }

        if let selection = initialNotificationSelection,
           let episodeNumber = selection.episodeNumber,
           initialRouteNotice == nil {
            if let initialSpecialID,
               let entry = specials.first(where: { $0.id == initialSpecialID }),
               !(1...max(1, entry.episodeCount)).contains(episodeNumber) {
                initialRouteNotice = "Eclipse opened the correct special, but Episode \(episodeNumber) is not listed yet."
            } else if initialSpecialID == nil,
                      let initialSeasonDetail,
                      !initialSeasonDetail.episodes.contains(where: { $0.episodeNumber == episodeNumber }) {
                initialRouteNotice = "Eclipse opened the correct season, but Episode \(episodeNumber) is not listed yet."
            }
        }
        try Task.checkCancellation()
        return ResolvedAnimeDetailMetadata(
            anime: animeData,
            rating: rating,
            specialEntries: specials,
            shouldLoadSpecialsAfterReveal: !requiresSpecialsBeforeReveal,
            initialSeasonNumber: initialSeasonNumber,
            initialSeasonDetail: initialSeasonDetail,
            initialEpisodeNumber: initialEpisodeNumber,
            initialSpecialID: initialSpecialID,
            initialRouteNotice: initialRouteNotice,
            needsBackgroundRevalidation: animeDataNeedsRevalidation
        )
    }

    private static func animeStructureMateriallyDiffers(
        _ lhs: AniListAnimeWithSeasons,
        _ rhs: AniListAnimeWithSeasons
    ) -> Bool {
        if lhs.id != rhs.id { return true }
        if lhs.malId != rhs.malId { return true }
        if lhs.seasons.count != rhs.seasons.count { return true }
        for (old, new) in zip(lhs.seasons, rhs.seasons) {
            if old.anilistId != new.anilistId
                || old.seasonNumber != new.seasonNumber
                || old.episodes.count != new.episodes.count
                || old.title != new.title {
                return true
            }

            if old.canonicalAniListId != new.canonicalAniListId
                || old.malId != new.malId
                || old.kitsuId != new.kitsuId {
                return true
            }

            for (oldEpisode, newEpisode) in zip(old.episodes, new.episodes) {
                if oldEpisode.number != newEpisode.number
                    || oldEpisode.seasonNumber != newEpisode.seasonNumber
                    || oldEpisode.tmdbSeasonNumber != newEpisode.tmdbSeasonNumber
                    || oldEpisode.tmdbEpisodeNumber != newEpisode.tmdbEpisodeNumber {
                    return true
                }
            }
        }
        return false
    }

    private func startAnimeStructureRevalidation(
        detail: TMDBTVShowWithSeasons,
        staleAnime: AniListAnimeWithSeasons,
        revealedInitialSeasonNumber: Int?,
        revealedInitialSpecialID: Int?,
        prefetchedSeedHasRegularMapping: Bool,
        performanceModeEnabled: Bool,
        detailCacheKey: String
    ) {
        animeStructureRevalidationTask?.cancel()
        animeStructureRevalidationTask = Task {
            let fresh: ResolvedAnimeDetailMetadata
            do {
                fresh = try await resolveAnimeDetailMetadata(
                    for: detail,
                    detectedAsAnime: true,
                    performanceModeEnabled: performanceModeEnabled,
                    skipAniListTraversal: false,
                    prefetchedSeedHasRegularMapping: prefetchedSeedHasRegularMapping,
                    allowStaleRevalidation: false
                )
            } catch {
                if !Task.isCancelled, !(error is CancellationError) {
                    Logger.shared.log(
                        "MediaDetailView: anime structure revalidation failed tmdbId=\(detail.id): \(error.localizedDescription)",
                        type: "AniList"
                    )
                }
                return
            }
            guard !Task.isCancelled, let freshAnime = fresh.anime else { return }
            await MainActor.run {
                guard !Task.isCancelled, self.searchResult.id == detail.id else { return }
                guard Self.animeStructureMateriallyDiffers(staleAnime, freshAnime) else {
                    Logger.shared.log(
                        "MediaDetailView: anime revalidation confirmed revealed graph tmdbId=\(detail.id)",
                        type: "AniList"
                    )
                    return
                }
#if os(tvOS)

                let downloadSheetIsClosed = true
#else
                let downloadSheetIsClosed = !self.showingDownloadSheet
#endif
                let selectionIsUntouched = self.selectedSpecialEpisodeContext == nil
                    && revealedInitialSpecialID == nil
                    && fresh.initialSpecialID == nil
                    && self.selectedSeason?.seasonNumber == revealedInitialSeasonNumber
                    && !self.showingSearchResults
                    && downloadSheetIsClosed
                    && self.specialSearchRequest == nil
                guard selectionIsUntouched else {

                    MediaDetailCacheStore.shared.remove(key: detailCacheKey)
                    Logger.shared.log(
                        "MediaDetailView: anime revalidation deferred, user is interacting tmdbId=\(detail.id)",
                        type: "AniList"
                    )
                    return
                }
                self.applyRevalidatedAnimeStructure(
                    detail: detail,
                    metadata: fresh,
                    detailCacheKey: detailCacheKey
                )
            }
        }
    }

    @MainActor
    private func applyRevalidatedAnimeStructure(
        detail: TMDBTVShowWithSeasons,
        metadata: ResolvedAnimeDetailMetadata,
        detailCacheKey: String
    ) {
        guard let animeData = metadata.anime else { return }
        Logger.shared.log(
            "MediaDetailView: applying revalidated anime structure tmdbId=\(detail.id) seasons=\(animeData.seasons.count)",
            type: "AniList"
        )

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
                id: RemoteMediaNumericBoundary.syntheticIdentifier([
                    (detail.id, 1_000),
                    (aniSeason.seasonNumber, 1)
                ]),
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
        if let rating = metadata.rating {
            self.animeRating = rating
        }

        var seasonTitles: [Int: String] = [:]
        var seasonRomajiTitles: [Int: String] = [:]
        var seasonAniListIds: [Int: Int] = [:]
        var seasonKitsuIds: [Int: Int] = [:]
        var allEpisodes: [AniListEpisode] = []
        var canonicalEpisodeContexts: [EpisodePlaybackContext] = []
        var absoluteEpisodeOffset = 0
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
            canonicalEpisodeContexts.append(contentsOf: season.episodes.map { episode in
                EpisodePlaybackContext(
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
                        absoluteEpisodeOffset,
                        episode.number
                    ),
                    animeSeasonEpisodeCount: season.episodes.count,
                    isSpecial: false,
                    titleOnlySearch: false
                )
            })
            absoluteEpisodeOffset = RemoteMediaNumericBoundary.adding(
                absoluteEpisodeOffset,
                season.episodes.count
            ) ?? RemoteMediaNumericBoundary.maximumTotalEpisodeCount
        }
        self.animeSeasonTitles = seasonTitles
        self.animeSeasonRomajiTitles = seasonRomajiTitles
        self.animeSeasonAniListIds = seasonAniListIds
        self.animeSeasonKitsuIds = seasonKitsuIds
        self.anilistEpisodes = allEpisodes

        let currentSpecialEntries = self.animeSpecialEntries
        let canonicalProviderIDByStoredID = Self.animeProviderAliasMap(
            seasons: animeData.seasons,
            specials: currentSpecialEntries
        )
        self.animeProviderAliases = canonicalProviderIDByStoredID
        let regularSeasonByAniListID = animeData.seasons.reduce(
            into: [Int: Int]()
        ) { result, season in
            result[season.anilistId] = season.seasonNumber
            if let canonicalID = season.canonicalAniListId {
                result[canonicalID] = season.seasonNumber
            }
            if let providerID = RemoteMediaNumericBoundary.negativeProviderIdentifier(
                season.malId
            ) {
                result[providerID] = season.seasonNumber
            }
        }
        let specialSeasonByAniListID = currentSpecialEntries.reduce(
            into: [Int: Int]()
        ) { result, entry in
            if let context = SpecialEpisodeListContext(
                entry: entry,
                tmdbShowId: detail.id
            ) {
                result[entry.id] = context.localSeasonNumber
                if let canonicalID = entry.canonicalAniListId {
                    result[canonicalID] = context.localSeasonNumber
                }
                if let providerID = RemoteMediaNumericBoundary.negativeProviderIdentifier(
                    entry.malId
                ) {
                    result[providerID] = context.localSeasonNumber
                }
            }
        }
        for entry in currentSpecialEntries {
            guard let context = SpecialEpisodeListContext(
                entry: entry,
                tmdbShowId: detail.id
            ) else { continue }
            canonicalEpisodeContexts.append(contentsOf: context.episodes.map {
                context.playbackContext(for: $0)
            })
        }
#if !os(tvOS)
        DownloadManager.shared.reconcileAnimeStructuralContexts(
            tmdbId: detail.id,
            canonicalContexts: canonicalEpisodeContexts,
            canonicalProviderIDByStoredID: canonicalProviderIDByStoredID
        )
#endif
        ProgressManager.shared.reconcileAnimeStructuralCoordinates(
            showId: detail.id,
            regularSeasonByAniListID: regularSeasonByAniListID,
            specialSeasonByAniListID: specialSeasonByAniListID,
            canonicalEpisodeContexts: canonicalEpisodeContexts,
            canonicalProviderIDByStoredID: canonicalProviderIDByStoredID
        )
#if !os(tvOS)
        LocalNotificationManager.shared.reconcileAnimeStructuralRoles(
            tmdbID: detail.id,
            regularMediaIDs: Set(regularSeasonByAniListID.keys),
            specialMediaIDs: Set(specialSeasonByAniListID.keys),
            canonicalProviderIDByStoredID: canonicalProviderIDByStoredID
        )
#endif

        if let initialSeasonNumber = metadata.initialSeasonNumber,
           let initialSeason = aniSeasons.first(where: {
               $0.seasonNumber == initialSeasonNumber
           }) {
            self.selectedSpecialEpisodeContext = nil
            self.selectedSeason = initialSeason
            self.seasonDetail = metadata.initialSeasonDetail
            self.selectedEpisodeForSearch = metadata.initialSeasonDetail?.episodes.first
        } else {
            self.selectedSeason = nil
            self.seasonDetail = nil
            self.selectedEpisodeForSearch = nil
        }

        if self.initialNotificationSelection == nil,
           self.watchTogetherAutoPlay == nil {
            MediaDetailCacheStore.shared.set(key: detailCacheKey, detail: .init(
                movieDetail: nil,
                tvShowDetail: self.tvShowDetail,
                selectedSeason: self.selectedSeason,
                seasonDetail: self.seasonDetail,
                synopsis: self.synopsis,
                romajiTitle: self.romajiTitle,
                logoURL: self.logoURL,
                alternatePosterURL: self.alternatePosterURL,
                isAnimeShow: self.isAnimeShow,
                animeRating: self.animeRating,
                anilistEpisodes: self.anilistEpisodes,
                animeSeasonTitles: self.animeSeasonTitles,
                animeSeasonRomajiTitles: self.animeSeasonRomajiTitles,
                animeSeasonAniListIds: self.animeSeasonAniListIds,
                animeSeasonKitsuIds: self.animeSeasonKitsuIds,
                animeProviderAliases: self.animeProviderAliases,
                animeSpecialEntries: self.animeSpecialEntries,

                animeSpecialsAreComplete: false,
                castMembers: self.castMembers,
                timestamp: Date()
            ))
        }

        Logger.shared.log(
            "AnimeDetailTiming: tmdbId=\(detail.id) stage=revalidated-structure-applied seasons=\(animeData.seasons.count)",
            type: "AniList"
        )

        self.startAnimeSpecialsLoad(
            tmdbShowId: detail.id,
            fallbackPosterURL: detail.fullPosterURL,
            baseAniListIds: animeData.seasons.map(\.anilistId),
            detailCacheKey: detailCacheKey
        )
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
        if let animeStructureRevalidationTask {
            animeStructureRevalidationTask.cancel()
            self.animeStructureRevalidationTask = nil
        }
        specialsLoadGeneration += 1
        let catalogSeedID = searchResult.animeIdentitySeed?.anilistId
        let catalogRouteProviderIDs = Set([
            catalogSeedID,
            RemoteMediaNumericBoundary.negativeProviderIdentifier(
                searchResult.animeIdentitySeed?.malId
            )
        ].compactMap { $0 })
        let detailCacheKey = detailCacheKeyForCurrentRoute()

        if initialNotificationSelection == nil,
           watchTogetherAutoPlay == nil,
           let cached = MediaDetailCacheStore.shared.get(key: detailCacheKey),
           exactRegularAnimeSeedAniListId.map({ requestedID in
               cached.animeSeasonAniListIds.values.contains { storedID in
                   Self.animeProviderIDsMatch(
                       storedID,
                       requestedID,
                       aliases: cached.animeProviderAliases
                   )
               }
           }) ?? true,
           exactSpecialAnimeSeedAniListId.map({ id in
               cached.animeSpecialEntries.contains(where: {
                   Self.animeProviderIDsMatch(
                       $0.id,
                       id,
                       aliases: cached.animeProviderAliases
                   )
               })
           }) ?? true,
           (catalogRouteProviderIDs.isEmpty || catalogRouteProviderIDs.contains(where: { id in
               cached.animeSeasonAniListIds.values.contains(where: {
                   Self.animeProviderIDsMatch(
                       $0,
                       id,
                       aliases: cached.animeProviderAliases
                   )
               }) || cached.animeSpecialEntries.contains(where: {
                   Self.animeProviderIDsMatch(
                       $0.id,
                       id,
                       aliases: cached.animeProviderAliases
                   )
               })
           })) {
            let shouldResumeAnimeSpecials = cached.isAnimeShow
                && !cached.animeSpecialsAreComplete

            Task { @MainActor in
                self.movieDetail = cached.movieDetail
                self.tvShowDetail = cached.tvShowDetail
                self.selectedSeason = cached.selectedSeason
                self.seasonDetail = cached.seasonDetail
                self.synopsis = cached.synopsis
                self.romajiTitle = cached.romajiTitle
                self.logoURL = cached.logoURL
                self.alternatePosterURL = cached.alternatePosterURL
                self.isAnimeShow = cached.isAnimeShow
                self.animeRating = cached.animeRating
                self.anilistEpisodes = cached.anilistEpisodes
                self.animeSeasonTitles = cached.animeSeasonTitles
                self.animeSeasonRomajiTitles = cached.animeSeasonRomajiTitles
                self.animeSeasonAniListIds = cached.animeSeasonAniListIds
                self.animeSeasonKitsuIds = cached.animeSeasonKitsuIds
                self.animeProviderAliases = cached.animeProviderAliases
                self.animeSpecialEntries = cached.animeSpecialEntries
                self.castMembers = cached.castMembers
                if let requestedSpecialID = catalogRouteProviderIDs.first(where: { id in
                    !cached.animeSeasonAniListIds.values.contains(where: {
                        Self.animeProviderIDsMatch(
                            $0,
                            id,
                            aliases: cached.animeProviderAliases
                        )
                    }) && cached.animeSpecialEntries.contains(where: {
                        Self.animeProviderIDsMatch(
                            $0.id,
                            id,
                            aliases: cached.animeProviderAliases
                        )
                    })
                }),
                   let entry = cached.animeSpecialEntries.first(where: {
                       Self.animeProviderIDsMatch(
                           $0.id,
                           requestedSpecialID,
                           aliases: cached.animeProviderAliases
                       )
                   }),
                   let context = SpecialEpisodeListContext(entry: entry, tmdbShowId: searchResult.id) {
                    self.selectedSpecialEpisodeContext = context
                    self.selectedSeason = nil
                    self.seasonDetail = nil
                    self.selectedEpisodeForSearch = context.episodes.first
                } else {
                    self.selectedSpecialEpisodeContext = nil
                    self.selectedEpisodeForSearch = nil
                }
                self.isLoading = false
                self.hasLoadedContent = true
                self.isLoadingAnimeSpecials = shouldResumeAnimeSpecials
                self.startTraktFeatureLoad()
                self.startExperimentalExtrasLoadIfNeeded()
                self.startSimilarTitlesLoadIfNeeded()
                if shouldResumeAnimeSpecials {
                    Logger.shared.log(
                        "MediaDetailView cache hit has pending specials hydration: tmdbId=\(self.searchResult.id)",
                        type: "AniList"
                    )
                    self.startAnimeSpecialsLoad(
                        tmdbShowId: self.searchResult.id,
                        fallbackPosterURL: cached.tvShowDetail?.fullPosterURL,
                        baseAniListIds: Array(cached.animeSeasonAniListIds.values),
                        detailCacheKey: detailCacheKey
                    )
                }
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
        animeProviderAliases = [:]
        animeSpecialEntries = []
        alternatePosterURL = nil
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
        let detailLoadStartedAt = ProcessInfo.processInfo.systemUptime

        detailLoadTask = Task {
            do {
                if searchResult.isMovie {
                    async let detailTask = tmdbService.getMovieDetails(id: searchResult.id)
                    async let imagesTask = tmdbService.getMovieImages(
                        id: searchResult.id,
                        preferredLanguage: selectedLanguage
                    )
                    async let romajiTask = tmdbService.getRomajiTitle(
                        for: "movie",
                        id: searchResult.id
                    )
                    async let creditsTask = tmdbService.getMovieCredits(id: searchResult.id)

                    let detail = try await detailTask
                    if Task.isCancelled { return }
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        self.movieDetail = detail
                        self.synopsis = detail.overview ?? ""
                        self.romajiTitle = nil
                        self.logoURL = nil
                        self.alternatePosterURL = nil
                        self.castMembers = []
                        self.animeRating = nil
                        self.animeSpecialEntries = []
                        self.isLoadingAnimeSpecials = false
                        self.selectedSpecialEpisodeContext = nil
                        self.isLoading = false
                        self.hasLoadedContent = true

                        MediaDetailCacheStore.shared.set(key: detailCacheKey, detail: .init(
                            movieDetail: detail,
                            tvShowDetail: nil,
                            selectedSeason: nil,
                            seasonDetail: nil,
                            synopsis: self.synopsis,
                            romajiTitle: self.romajiTitle,
                            logoURL: self.logoURL,
                            alternatePosterURL: self.alternatePosterURL,
                            isAnimeShow: false,
                            animeRating: nil,
                            anilistEpisodes: nil,
                            animeSeasonTitles: nil,
                            animeSeasonRomajiTitles: [:],
                            animeSeasonAniListIds: [:],
                            animeSeasonKitsuIds: [:],
                            animeProviderAliases: [:],
                            animeSpecialEntries: [],
                            animeSpecialsAreComplete: true,
                            castMembers: [],
                            timestamp: Date()
                        ))
                        let elapsedMs = Int(
                            ((ProcessInfo.processInfo.systemUptime - detailLoadStartedAt) * 1_000).rounded()
                        )
                        Logger.shared.log(
                            "MediaDetailTiming: tmdbId=\(detail.id) medium=movie stage=first-render-ready elapsedMs=\(elapsedMs)",
                            type: "TMDB"
                        )
                        self.startTraktFeatureLoad()
                        self.startExperimentalExtrasLoadIfNeeded()
                        self.startSimilarTitlesLoadIfNeeded()
                    }

                    if !Task.isCancelled {
                        let loadedImages = try? await imagesTask
                        let loadedRomaji = await romajiTask
                        let loadedCredits = try? await creditsTask
                        guard !Task.isCancelled else { return }
                        let resolvedAlternatePosterURL: String?
                        if let loadedImages {
                            resolvedAlternatePosterURL = await tmdbService.bestAlternatePoster(
                                from: loadedImages,
                                excluding: [detail.posterPath, self.searchResult.posterPath],
                                matching: detail.posterPath ?? self.searchResult.posterPath
                            )?.fullURL
                        } else {
                            resolvedAlternatePosterURL = nil
                        }
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            guard !Task.isCancelled,
                                  self.searchResult.id == detail.id else { return }
                            self.romajiTitle = loadedRomaji
                            self.castMembers = loadedCredits?.cast ?? []
                            if let loadedImages,
                               let logo = tmdbService.getBestLogo(
                                   from: loadedImages,
                                   preferredLanguage: selectedLanguage
                               ) {
                                self.logoURL = logo.fullURL
                            }
                            self.alternatePosterURL = resolvedAlternatePosterURL
                            MediaDetailCacheStore.shared.set(key: detailCacheKey, detail: .init(
                                movieDetail: detail,
                                tvShowDetail: nil,
                                selectedSeason: nil,
                                seasonDetail: nil,
                                synopsis: self.synopsis,
                                romajiTitle: self.romajiTitle,
                                logoURL: self.logoURL,
                                alternatePosterURL: self.alternatePosterURL,
                                isAnimeShow: false,
                                animeRating: nil,
                                anilistEpisodes: nil,
                                animeSeasonTitles: nil,
                                animeSeasonRomajiTitles: [:],
                                animeSeasonAniListIds: [:],
                                animeSeasonKitsuIds: [:],
                                animeProviderAliases: [:],
                                animeSpecialEntries: [],
                                animeSpecialsAreComplete: true,
                                castMembers: self.castMembers,
                                timestamp: Date()
                            ))
                            let elapsedMs = Int(
                                ((ProcessInfo.processInfo.systemUptime - detailLoadStartedAt) * 1_000).rounded()
                            )
                            Logger.shared.log(
                                "MediaDetailTiming: tmdbId=\(detail.id) medium=movie stage=optional-presentation-ready elapsedMs=\(elapsedMs)",
                                type: "TMDB"
                            )
                        }
                    }
                } else {
                    async let detailTask = tmdbService.getTVShowWithSeasons(id: searchResult.id)
                    async let imagesTask = tmdbService.getTVShowImages(id: searchResult.id, preferredLanguage: selectedLanguage)
                    async let romajiTask = tmdbService.getRomajiTitle(for: "tv", id: searchResult.id)
                    async let creditsTask = tmdbService.getTVCredits(id: searchResult.id)
                    async let animeSnapshotTask: Bool = prefetchExactAnimeSnapshotIfNeeded()

                    let detail = try await detailTask
                    let primaryDetailElapsedMs = Int(
                        ((ProcessInfo.processInfo.systemUptime - detailLoadStartedAt) * 1_000).rounded()
                    )

                    let asianAnimationCountries: Set<String> = ["JP", "CN", "KR", "TW"]
                    let isAsianAnimation = detail.originCountry?.contains(where: { asianAnimationCountries.contains($0) }) ?? false
                    let isAnimation = detail.genres.contains { $0.id == 16 }
                    let hasExactAnimeIdentity = hasExactAnimeNavigationContext
                    let detectedAsAnime = hasExactAnimeIdentity || (isAsianAnimation && isAnimation)
                    let performanceModeEnabled = PerformanceModeSettings.isEnabled
                    let skipAniListTraversal = PerformanceModeSettings.skipsAniListTraversalForAnimeDetails
                    Logger.shared.log("MediaDetailView: \(detail.name) - isAsianAnimation=\(isAsianAnimation) isAnimation=\(isAnimation) detectedAsAnime=\(detectedAsAnime) originCountry=\(detail.originCountry ?? []) genres=\(detail.genres.map { $0.id })", type: "AniList")

                    let initialSeasonWarmTask: Task<Void, Never>? = {
                        let seedID = exactAnimeNavigationSeedAniListId
                            ?? searchResult.animeIdentitySeed?.anilistId
                        guard detectedAsAnime,
                              !skipAniListTraversal,
                              seedID.map({ $0 > 0 }) == true,
                              let firstSeasonNumber = detail.seasons
                                .filter({ $0.seasonNumber > 0 && $0.episodeCount > 0 })
                                .map(\.seasonNumber)
                                .min() else { return nil }
                        return Task {
                            _ = try? await tmdbService.getSeasonDetails(
                                tvShowId: detail.id,
                                seasonNumber: firstSeasonNumber
                            )
                        }
                    }()

                    defer { initialSeasonWarmTask?.cancel() }
                    let prefetchedSeedHasRegularMapping = await animeSnapshotTask
                    if detectedAsAnime {
                        let elapsedMs = Int(
                            ((ProcessInfo.processInfo.systemUptime - detailLoadStartedAt) * 1_000).rounded()
                        )
                        Logger.shared.log(
                            "AnimeDetailTiming: tmdbId=\(detail.id) stage=detail-and-prefetch elapsedMs=\(elapsedMs) tmdbDetailMs=\(primaryDetailElapsedMs) seedRegular=\(prefetchedSeedHasRegularMapping)",
                            type: "AniList"
                        )
                    }
                    async let animeMetadataTask = resolveAnimeDetailMetadata(
                        for: detail,
                        detectedAsAnime: detectedAsAnime,
                        performanceModeEnabled: performanceModeEnabled,
                        skipAniListTraversal: skipAniListTraversal,
                        prefetchedSeedHasRegularMapping: prefetchedSeedHasRegularMapping,
                        allowStaleRevalidation: initialNotificationSelection == nil
                            && watchTogetherAutoPlay == nil
                    )

                    let animeMetadata = try await animeMetadataTask
                    initialSeasonWarmTask?.cancel()
                    if detectedAsAnime {
                        let elapsedMs = Int(
                            ((ProcessInfo.processInfo.systemUptime - detailLoadStartedAt) * 1_000).rounded()
                        )
                        Logger.shared.log(
                            "AnimeDetailTiming: tmdbId=\(detail.id) stage=metadata-ready elapsedMs=\(elapsedMs) seasons=\(animeMetadata.anime?.seasons.count ?? 0)",
                            type: "AniList"
                        )
                    }
                    let animeData = animeMetadata.anime
                    let resolvedAnimeRating = animeMetadata.rating
                    let resolvedAnimeSpecials = animeMetadata.specialEntries
                    let shouldLoadAnimeSpecialsAfterReveal = animeMetadata.shouldLoadSpecialsAfterReveal

                    let images: TMDBImagesResponse? = nil
                    let romaji: String? = nil
                    let credits: TMDBCreditsResponse? = nil

                    let skippedTraversalInitialSeason: TMDBSeason?
                    let skippedTraversalInitialDetail: TMDBSeasonDetail?
                    if detectedAsAnime, skipAniListTraversal, animeData == nil {
                        let requestedTMDBSeasonNumber = watchTogetherAutoPlay?.playbackContext?.resolvedTMDBSeasonNumber
                            ?? initialNotificationSelection?.seasonNumber
                        let season = requestedTMDBSeasonNumber.flatMap { requested in
                            detail.seasons.first(where: { $0.seasonNumber == requested })
                        } ?? detail.seasons
                            .filter({ $0.seasonNumber > 0 })
                            .min(by: { $0.seasonNumber < $1.seasonNumber })
                        skippedTraversalInitialSeason = season
                        if let season {
                            skippedTraversalInitialDetail = try await tmdbService.getSeasonDetails(
                                tvShowId: detail.id,
                                seasonNumber: season.seasonNumber
                            )
                        } else {
                            skippedTraversalInitialDetail = nil
                        }
                    } else {
                        skippedTraversalInitialSeason = nil
                        skippedTraversalInitialDetail = nil
                    }
                    let skippedTraversalRouteNotice: String? = {
                        guard detectedAsAnime,
                              skipAniListTraversal,
                              let selection = initialNotificationSelection else { return nil }
                        if let requestedSeason = selection.seasonNumber,
                           skippedTraversalInitialSeason?.seasonNumber != requestedSeason {
                            return "Eclipse opened the show, but this anime season could not be matched safely on this device."
                        }
                        if let episodeNumber = selection.episodeNumber,
                           skippedTraversalInitialDetail?.episodes.contains(where: {
                               $0.episodeNumber == episodeNumber
                           }) != true {
                            return "Eclipse opened the correct season, but Episode \(episodeNumber) is not listed yet."
                        }
                        return nil
                    }()

                    if detectedAsAnime, !skipAniListTraversal, animeData == nil, !Task.isCancelled {
                        throw NSError(
                            domain: "AnimeDetail",
                            code: -1,
                            userInfo: [
                                NSLocalizedDescriptionKey: "Complete anime season mapping is temporarily unavailable. Please try again."
                            ]
                        )
                    }

                    if Task.isCancelled { return }
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        self.synopsis = detail.overview ?? ""
                        self.romajiTitle = romaji
                        self.isAnimeShow = detectedAsAnime
                        self.animeRating = resolvedAnimeRating
                        self.animeSpecialEntries = resolvedAnimeSpecials
                        self.isLoadingAnimeSpecials = shouldLoadAnimeSpecialsAfterReveal
                        self.castMembers = credits?.cast ?? []

                        if let animeData = animeData {
                            Logger.shared.log("MediaDetailView: Using AniList structure - \(animeData.seasons.count) seasons", type: "AniList")

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
                                    id: RemoteMediaNumericBoundary.syntheticIdentifier([
                                        (detail.id, 1_000),
                                        (aniSeason.seasonNumber, 1)
                                    ]),
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
                            var canonicalEpisodeContexts: [EpisodePlaybackContext] = []
                            var absoluteEpisodeOffset = 0
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
                                canonicalEpisodeContexts.append(contentsOf: season.episodes.map { episode in
                                    EpisodePlaybackContext(
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
                                            absoluteEpisodeOffset,
                                            episode.number
                                        ),
                                        animeSeasonEpisodeCount: season.episodes.count,
                                        isSpecial: false,
                                        titleOnlySearch: false
                                    )
                                })
                                absoluteEpisodeOffset = RemoteMediaNumericBoundary.adding(
                                    absoluteEpisodeOffset,
                                    season.episodes.count
                                ) ?? RemoteMediaNumericBoundary.maximumTotalEpisodeCount
                            }
                            self.animeSeasonTitles = seasonTitles
                            self.animeSeasonRomajiTitles = seasonRomajiTitles
                            self.animeSeasonAniListIds = seasonAniListIds
                            self.animeSeasonKitsuIds = seasonKitsuIds
                            self.anilistEpisodes = allEpisodes
                            let canonicalProviderIDByStoredID = Self.animeProviderAliasMap(
                                seasons: animeData.seasons,
                                specials: resolvedAnimeSpecials
                            )
                            self.animeProviderAliases = canonicalProviderIDByStoredID
                            let regularSeasonByAniListID = animeData.seasons.reduce(
                                into: [Int: Int]()
                            ) { result, season in
                                result[season.anilistId] = season.seasonNumber
                                if let canonicalID = season.canonicalAniListId {
                                    result[canonicalID] = season.seasonNumber
                                }
                                if let providerID = RemoteMediaNumericBoundary.negativeProviderIdentifier(
                                    season.malId
                                ) {
                                    result[providerID] = season.seasonNumber
                                }
                            }
                            let specialSeasonByAniListID = resolvedAnimeSpecials.reduce(
                                into: [Int: Int]()
                            ) { result, entry in
                                if let context = SpecialEpisodeListContext(
                                    entry: entry,
                                    tmdbShowId: detail.id
                                ) {
                                    result[entry.id] = context.localSeasonNumber
                                    if let canonicalID = entry.canonicalAniListId {
                                        result[canonicalID] = context.localSeasonNumber
                                    }
                                    if let providerID = RemoteMediaNumericBoundary.negativeProviderIdentifier(
                                        entry.malId
                                    ) {
                                        result[providerID] = context.localSeasonNumber
                                    }
                                }
                            }
                            for entry in resolvedAnimeSpecials {
                                guard let context = SpecialEpisodeListContext(
                                    entry: entry,
                                    tmdbShowId: detail.id
                                ) else { continue }
                                canonicalEpisodeContexts.append(contentsOf: context.episodes.map {
                                    context.playbackContext(for: $0)
                                })
                            }
#if !os(tvOS)
                            DownloadManager.shared.reconcileAnimeStructuralContexts(
                                tmdbId: detail.id,
                                canonicalContexts: canonicalEpisodeContexts,
                                canonicalProviderIDByStoredID: canonicalProviderIDByStoredID
                            )
#endif
                            ProgressManager.shared.reconcileAnimeStructuralCoordinates(
                                showId: detail.id,
                                regularSeasonByAniListID: regularSeasonByAniListID,
                                specialSeasonByAniListID: specialSeasonByAniListID,
                                canonicalEpisodeContexts: canonicalEpisodeContexts,
                                canonicalProviderIDByStoredID: canonicalProviderIDByStoredID
                            )
#if !os(tvOS)
                            LocalNotificationManager.shared.reconcileAnimeStructuralRoles(
                                tmdbID: detail.id,
                                regularMediaIDs: Set(regularSeasonByAniListID.keys),
                                specialMediaIDs: Set(specialSeasonByAniListID.keys),
                                canonicalProviderIDByStoredID: canonicalProviderIDByStoredID
                            )
#endif

                            if let specialID = animeMetadata.initialSpecialID,
                               let entry = resolvedAnimeSpecials.first(where: { $0.id == specialID }),
                               let context = SpecialEpisodeListContext(entry: entry, tmdbShowId: detail.id) {
                                self.selectedSpecialEpisodeContext = context
                                self.selectedSeason = nil
                                self.seasonDetail = nil
                                if let episodeNumber = animeMetadata.initialEpisodeNumber {
                                    self.selectedEpisodeForSearch = context.episodes.first(where: {
                                        $0.episodeNumber == episodeNumber
                                    })
                                } else {
                                    self.selectedEpisodeForSearch = context.episodes.first
                                }
                            } else if let initialSeasonNumber = animeMetadata.initialSeasonNumber,
                                      let initialSeason = aniSeasons.first(where: {
                                          $0.seasonNumber == initialSeasonNumber
                                      }) {
                                self.selectedSpecialEpisodeContext = nil
                                self.selectedSeason = initialSeason
                                self.seasonDetail = animeMetadata.initialSeasonDetail
                                if let episodeNumber = animeMetadata.initialEpisodeNumber {
                                    self.selectedEpisodeForSearch = animeMetadata.initialSeasonDetail?.episodes.first(where: {
                                        $0.episodeNumber == episodeNumber
                                    })
                                } else {
                                    self.selectedEpisodeForSearch = animeMetadata.initialSeasonDetail?.episodes.first
                                }
                            } else {
                                self.selectedSeason = nil
                                self.seasonDetail = nil
                                self.selectedEpisodeForSearch = nil
                            }

                            if let selection = self.initialNotificationSelection {
                                self.handledNotificationSelectionID = selection.id
                                self.notificationRouteNotice = animeMetadata.initialRouteNotice
                            }
                        } else {

                            Logger.shared.log("MediaDetailView: animeData is nil - falling back to pure TMDB seasons (\(detail.seasons.count) seasons)", type: "AniList")
                            self.tvShowDetail = detail
                            self.anilistEpisodes = nil
                            self.animeSeasonTitles = nil
                            self.animeSeasonRomajiTitles = [:]
                            self.animeSeasonAniListIds = [:]
                            self.animeSeasonKitsuIds = [:]
                            self.animeProviderAliases = [:]
                            if let firstSeason = skippedTraversalInitialSeason
                                ?? detail.seasons.first(where: { $0.seasonNumber > 0 }) {
                                self.selectedSeason = firstSeason
                            } else {
                                self.selectedSeason = nil
                            }
                            self.seasonDetail = skippedTraversalInitialDetail
                            let requestedEpisodeNumber = self.watchTogetherAutoPlay?.playbackContext?.resolvedTMDBEpisodeNumber
                                ?? self.initialNotificationSelection?.episodeNumber
                            if let requestedEpisodeNumber {
                                self.selectedEpisodeForSearch = skippedTraversalInitialDetail?.episodes.first(where: {
                                    $0.episodeNumber == requestedEpisodeNumber
                                })
                            } else {
                                self.selectedEpisodeForSearch = skippedTraversalInitialDetail?.episodes.first
                            }
                            if let selection = self.initialNotificationSelection {
                                self.handledNotificationSelectionID = selection.id
                                self.notificationRouteNotice = skippedTraversalRouteNotice
                            }
                        }

                        if let images, let logo = tmdbService.getBestLogo(from: images, preferredLanguage: selectedLanguage) {
                            self.logoURL = logo.fullURL
                        }
                        self.alternatePosterURL = images.flatMap {
                            tmdbService.getBestAlternatePoster(
                                from: $0,
                                excluding: [detail.posterPath, self.searchResult.posterPath]
                            )?.fullURL
                        }

                        if self.initialNotificationSelection == nil,
                           self.watchTogetherAutoPlay == nil,
                           !animeMetadata.needsBackgroundRevalidation {
                            MediaDetailCacheStore.shared.set(key: detailCacheKey, detail: .init(
                                movieDetail: nil,
                                tvShowDetail: self.tvShowDetail,
                                selectedSeason: self.selectedSeason,
                                seasonDetail: self.seasonDetail,
                                synopsis: self.synopsis,
                                romajiTitle: self.romajiTitle,
                                logoURL: self.logoURL,
                                alternatePosterURL: self.alternatePosterURL,
                                isAnimeShow: self.isAnimeShow,
                                animeRating: self.animeRating,
                                anilistEpisodes: self.anilistEpisodes,
                                animeSeasonTitles: self.animeSeasonTitles,
                                animeSeasonRomajiTitles: self.animeSeasonRomajiTitles,
                                animeSeasonAniListIds: self.animeSeasonAniListIds,
                                animeSeasonKitsuIds: self.animeSeasonKitsuIds,
                                animeProviderAliases: self.animeProviderAliases,
                                animeSpecialEntries: self.animeSpecialEntries,
                                animeSpecialsAreComplete: !shouldLoadAnimeSpecialsAfterReveal,
                                castMembers: self.castMembers,
                                timestamp: Date()
                            ))
                        }
                        if !detectedAsAnime {
                            self.animeSpecialEntries = []
                            self.isLoadingAnimeSpecials = false
                            self.selectedSpecialEpisodeContext = nil
                        }
                        self.isLoading = false
                        self.hasLoadedContent = true
                        let elapsedMs = Int(
                            ((ProcessInfo.processInfo.systemUptime - detailLoadStartedAt) * 1_000).rounded()
                        )
                        Logger.shared.log(
                            "\(detectedAsAnime ? "AnimeDetailTiming" : "MediaDetailTiming"): tmdbId=\(detail.id) medium=tv stage=first-render-ready elapsedMs=\(elapsedMs)",
                            type: detectedAsAnime ? "AniList" : "TMDB"
                        )
                        if self.initialNotificationSelection != nil,
                           self.notificationRouteNotice == nil,
                           self.selectedEpisodeForSearch != nil {
                            self.requestNotificationEpisodeScrollIfVisible()
                        }
                        self.startTraktFeatureLoad()
                        self.startExperimentalExtrasLoadIfNeeded()
                        self.startSimilarTitlesLoadIfNeeded()
                        if shouldLoadAnimeSpecialsAfterReveal, let animeData {
                            self.startAnimeSpecialsLoad(
                                tmdbShowId: detail.id,
                                fallbackPosterURL: detail.fullPosterURL,
                                baseAniListIds: animeData.seasons.map(\.anilistId),
                                detailCacheKey: detailCacheKey
                            )
                        }
                        if animeMetadata.needsBackgroundRevalidation, let animeData {
                            self.startAnimeStructureRevalidation(
                                detail: detail,
                                staleAnime: animeData,
                                revealedInitialSeasonNumber: animeMetadata.initialSeasonNumber,
                                revealedInitialSpecialID: animeMetadata.initialSpecialID,
                                prefetchedSeedHasRegularMapping: prefetchedSeedHasRegularMapping,
                                performanceModeEnabled: performanceModeEnabled,
                                detailCacheKey: detailCacheKey
                            )
                        }
                    }

                    if !Task.isCancelled {
                        let loadedImages = try? await imagesTask
                        let loadedRomaji = await romajiTask
                        let loadedCredits = try? await creditsTask
                        guard !Task.isCancelled else { return }
                        let resolvedAlternatePosterURL: String?
                        if let loadedImages {
                            resolvedAlternatePosterURL = await tmdbService.bestAlternatePoster(
                                from: loadedImages,
                                excluding: [detail.posterPath, self.searchResult.posterPath],
                                matching: detail.posterPath ?? self.searchResult.posterPath
                            )?.fullURL
                        } else {
                            resolvedAlternatePosterURL = nil
                        }
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            guard !Task.isCancelled,
                                  self.searchResult.id == detail.id else { return }
                            self.romajiTitle = loadedRomaji
                            self.castMembers = loadedCredits?.cast ?? []
                            if let loadedImages,
                               let logo = tmdbService.getBestLogo(
                                   from: loadedImages,
                                   preferredLanguage: selectedLanguage
                               ) {
                                self.logoURL = logo.fullURL
                            }
                            self.alternatePosterURL = resolvedAlternatePosterURL
                            if self.initialNotificationSelection == nil,
                               self.watchTogetherAutoPlay == nil,
                               !animeMetadata.needsBackgroundRevalidation {
                                MediaDetailCacheStore.shared.set(key: detailCacheKey, detail: .init(
                                    movieDetail: nil,
                                    tvShowDetail: self.tvShowDetail,
                                    selectedSeason: self.selectedSeason,
                                    seasonDetail: self.seasonDetail,
                                    synopsis: self.synopsis,
                                    romajiTitle: self.romajiTitle,
                                    logoURL: self.logoURL,
                                    alternatePosterURL: self.alternatePosterURL,
                                    isAnimeShow: self.isAnimeShow,
                                    animeRating: self.animeRating,
                                    anilistEpisodes: self.anilistEpisodes,
                                    animeSeasonTitles: self.animeSeasonTitles,
                                    animeSeasonRomajiTitles: self.animeSeasonRomajiTitles,
                                    animeSeasonAniListIds: self.animeSeasonAniListIds,
                                    animeSeasonKitsuIds: self.animeSeasonKitsuIds,
                                    animeProviderAliases: self.animeProviderAliases,
                                    animeSpecialEntries: self.animeSpecialEntries,
                                    animeSpecialsAreComplete: !self.isLoadingAnimeSpecials,
                                    castMembers: self.castMembers,
                                    timestamp: Date()
                                ))
                            }
                            let elapsedMs = Int(
                                ((ProcessInfo.processInfo.systemUptime - detailLoadStartedAt) * 1_000).rounded()
                            )
                            Logger.shared.log(
                                "\(detectedAsAnime ? "AnimeDetailTiming" : "MediaDetailTiming"): tmdbId=\(detail.id) stage=optional-presentation-ready elapsedMs=\(elapsedMs)",
                                type: detectedAsAnime ? "AniList" : "TMDB"
                            )
                        }
                    }
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, (error as? URLError)?.code != .cancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
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
    let animeSpecialMediaIDs: Set<Int>
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
                animeSpecialMediaIDs: animeSpecialMediaIDs,
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
    let canonicalAniListId: Int?
    let malId: Int?
    let kitsuId: Int?
    let title: String
    let alternateTitle: String?
    let formatLabel: String
    let posterUrl: String?
    let localSeasonNumber: Int
    let mappedSeasonNumber: Int?
    let episodeOffset: Int?
    let imdbId: String?
    let episodes: [TMDBEpisode]
    private let exactTMDBSeasonByEpisode: [Int: Int]
    private let exactTMDBEpisodeByEpisode: [Int: Int]

    init?(entry: AniListSpecialSearchEntry, tmdbShowId: Int) {
        guard let localSeasonNumber = AnimeSyntheticSeasonKey.make(providerID: entry.id) else {
            return nil
        }
        let title = entry.preferredTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        self.id = entry.id
        self.anilistId = entry.id
        self.canonicalAniListId = entry.canonicalAniListId
            ?? (entry.id > 0 ? entry.id : nil)
        self.malId = entry.malId
        self.kitsuId = entry.kitsuId
        self.title = title
        self.alternateTitle = entry.alternateSearchTitle
        self.formatLabel = entry.formatLabel
        self.posterUrl = entry.posterUrl
        self.localSeasonNumber = localSeasonNumber
        self.mappedSeasonNumber = entry.tmdbSeasonNumber

        self.episodeOffset = nil
        self.imdbId = entry.imdbId
        self.exactTMDBSeasonByEpisode = Dictionary(
            entry.episodes.compactMap { episode in
                guard let season = episode.tmdbSeasonNumber else { return nil }
                return (episode.number, season)
            },
            uniquingKeysWith: { existing, _ in existing }
        )
        self.exactTMDBEpisodeByEpisode = Dictionary(
            entry.episodes.compactMap { episode in
                guard let number = episode.tmdbEpisodeNumber else { return nil }
                return (episode.number, number)
            },
            uniquingKeysWith: { existing, _ in existing }
        )

        let count = RemoteMediaNumericBoundary.episodeCount(
            max(1, entry.episodeCount)
        ) ?? 1
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
                id: RemoteMediaNumericBoundary.syntheticIdentifier([
                    (tmdbShowId, 1_000_000),
                    (entry.id, 100),
                    (episodeNumber, 1)
                ]),
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
        let exactTMDBSeason = exactTMDBSeasonByEpisode[episode.episodeNumber]
        let exactTMDBEpisode = exactTMDBEpisodeByEpisode[episode.episodeNumber]
        return EpisodePlaybackContext(
            localSeasonNumber: localSeasonNumber,
            localEpisodeNumber: episode.episodeNumber,
            anilistMediaId: anilistId,
            canonicalAniListMediaId: canonicalAniListId,
            malMediaId: malId,
            kitsuMediaId: kitsuId,
            tmdbSeasonNumber: exactTMDBEpisode == nil ? nil : exactTMDBSeason,
            tmdbEpisodeNumber: exactTMDBEpisode,
            tmdbEpisodeOffset: nil,
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
