import AVKit
import SwiftUI
import Kingfisher

extension Notification.Name {
    static let requestNextEpisode = Notification.Name("requestNextEpisode")
}

#if os(tvOS)
private extension UIViewController {
    func topmostViewController() -> UIViewController {
        if let presentedViewController {
            return presentedViewController.topmostViewController()
        }
        if let navigationController = self as? UINavigationController {
            return navigationController.visibleViewController?.topmostViewController() ?? navigationController
        }
        if let tabBarController = self as? UITabBarController {
            return tabBarController.selectedViewController?.topmostViewController() ?? tabBarController
        }
        return self
    }
}
#endif

private struct ServicesSheetPresentationAnchor: UIViewRepresentable {
    let onResolve: (UIViewController) -> Void

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
        var onResolve: ((UIViewController) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            resolveIfAttached()
        }

        func resolveIfAttached() {
            guard window != nil else { return }
            var responder: UIResponder? = self
            var nearestController: UIViewController?
            var presentedSheetController: UIViewController?
            while let current = responder?.next {
                if let controller = current as? UIViewController {
                    nearestController = nearestController ?? controller
                    if controller.presentingViewController != nil {
                        presentedSheetController = controller
                        break
                    }
                }
                responder = current
            }
            guard let controller = presentedSheetController ?? nearestController else { return }
            DispatchQueue.main.async { [weak self, weak controller] in
                guard let controller else { return }
                self?.onResolve?(controller)
            }
        }
    }
}

struct StreamOption: Identifiable {
    let id = UUID()
    let name: String
    let url: String
    let headers: [String: String]?
    let subtitle: String?
    let subtitleTracks: [ServiceSubtitleTrack]
    let languageHints: [String]
    let metadataHints: [String]

    var qualitySearchLabel: String {
        ([name] + metadataHints + [url]).joined(separator: " ")
    }

    init(
        name: String,
        url: String,
        headers: [String: String]?,
        subtitle: String?,
        subtitleTracks: [ServiceSubtitleTrack],
        languageHints: [String] = [],
        metadataHints: [String] = []
    ) {
        self.name = name
        self.url = url
        self.headers = headers
        self.subtitle = subtitle
        self.subtitleTracks = subtitleTracks
        self.languageHints = languageHints
        self.metadataHints = metadataHints
    }
}

struct ServiceSubtitleTrack: Hashable {
    let title: String
    let url: String
    let headers: [String: String]?
}

/// A Service search hit is only a title/details link. The Stremio-style sheet must resolve that
/// link into real stream metadata before it can truthfully apply the user's language/quality
/// rules and present the row as a stream.
private struct StremioStyleResolvedServiceStream: Identifiable {
    let id = UUID()
    let service: Service
    let result: SearchItem
    let option: StreamOption
    let topLevelSubtitles: [String]?
    let resolvedAt: Date
}

#if os(iOS) && !targetEnvironment(macCatalyst)
/// A SkyStream row can only be built after the resolver has crossed the VOD/security boundary.
/// Keeping the validated descriptor beside the shared StreamOption prevents a later picker or
/// Auto Mode callback from reconstructing playback from raw JavaScript values.
private struct ValidatedSkyStreamOption: Identifiable, Hashable {
    let id: UUID
    let resolved: SkyStreamResolvedStream
    let option: StreamOption

    init(
        id: UUID = UUID(),
        resolved: SkyStreamResolvedStream,
        option: StreamOption
    ) {
        self.id = id
        self.resolved = resolved
        self.option = option
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
#endif

private enum StremioStyleServiceResolutionState {
    case queued
    case checking
    case resolved([StremioStyleResolvedServiceStream])
    case failed
    case verificationRequired(URL)

    var isPending: Bool {
        switch self {
        case .queued, .checking:
            return true
        case .resolved, .failed, .verificationRequired:
            return false
        }
    }
}

/// Each probe owns a separate JavaScript context. ServiceSandboxState tracks one live operation
/// per controller, so sharing a controller across candidates would let one cancellation detach a
/// different candidate's callbacks.
private final class StremioStyleServiceResolutionWork {
    let id = UUID()
    let key: String
    let controller: JSController
    var streamRequest: JSCallbackDeadline<ServiceStreamExtractionResult>?

    init(key: String, service: Service) {
        self.key = key
        controller = JSController()
        controller.loadScript(service.jsScript, service: service)
    }

    func cancel() {
        if streamRequest?.cancel() != true {
            controller.cancelPendingServiceOperation(reason: "stremio-style-service-resolution-cancelled")
        }
        streamRequest = nil
    }
}

@MainActor
final class AutoModeRetrySession: ObservableObject {
    private(set) var id = UUID()
    private(set) var targetToken: String?
    private(set) var attemptedSourceIds: Set<String> = []
    private(set) var retryCount = 0
    private(set) var lastFailureMessage: String?

    func reset(targetToken: String? = nil) {
        id = UUID()
        self.targetToken = targetToken
        attemptedSourceIds.removeAll()
        retryCount = 0
        lastFailureMessage = nil
    }

    func recoveryIdentity(for targetToken: String) -> AutoModePlaybackRecoveryIdentity? {
        guard self.targetToken == targetToken else { return nil }
        return AutoModePlaybackRecoveryIdentity(sessionID: id, targetToken: targetToken)
    }

    func matches(_ identity: AutoModePlaybackRecoveryIdentity) -> Bool {
        id == identity.sessionID && targetToken == identity.targetToken
    }

    func recordAttempt(sourceId: String) {
        attemptedSourceIds.insert(sourceId)
    }

    func recordPlaybackFailure(_ report: PlaybackFailureReport) {
        attemptedSourceIds.insert(report.context.sourceId)
        retryCount = max(retryCount, report.context.retryCount + 1)
        lastFailureMessage = "\(report.context.sourceName): \(report.message)"
    }

    func recordStatus(sourceName: String, message: String) {
        lastFailureMessage = "\(sourceName): \(message)"
    }
}

struct AutoModePlaybackRecoveryIdentity: Equatable {
    let sessionID: UUID
    let targetToken: String
}

enum AutoModeMediaTargetToken {
    static func make(
        tmdbID: Int,
        isMovie: Bool,
        episode: TMDBEpisode?,
        playbackContext: EpisodePlaybackContext?
    ) -> String {
        func value(_ number: Int?) -> String { number.map(String.init) ?? "-" }
        let context = playbackContext
        return [
            isMovie ? "movie" : "episode",
            String(tmdbID),
            value(episode?.seasonNumber),
            value(episode?.episodeNumber),
            value(context?.localSeasonNumber),
            value(context?.localEpisodeNumber),
            value(context?.anilistMediaId),
            value(context?.kitsuMediaId),
            value(context?.resolvedTMDBSeasonNumber),
            value(context?.resolvedTMDBEpisodeNumber),
            context?.isSpecial == true ? "special" : "regular",
            context?.titleOnlySearch == true ? "title-only" : "episode-search"
        ].joined(separator: ":")
    }
}

struct PlayerResolvedPlaybackRequest {
    let url: URL
    let preset: PlayerPreset
    let headers: [String: String]?
    let subtitles: [String]?
    let subtitleNames: [String]?
    var subtitleHeadersByURL: [String: [String: String]]? = nil
    let mediaInfo: MediaInfo?
    let imdbId: String?
    let isAnimeHint: Bool
    let isAnimationContentHint: Bool?
    let originalTMDBSeasonNumber: Int?
    let originalTMDBEpisodeNumber: Int?
    let episodePlaybackContext: EpisodePlaybackContext?
    let launchContext: PlaybackLaunchContext?
    var autoModeRecoveryIdentity: AutoModePlaybackRecoveryIdentity? = nil
    /// Release/first-air year carried across in-player source replacement. Providers that do not
    /// use title/year matching continue to ignore this optional value.
    var mediaYear: Int? = nil
}

@MainActor
final class ModulesSearchResultsViewModel: ObservableObject {
    @Published var moduleResults: [UUID: [SearchItem]] = [:]
    @Published var isSearching = true
    @Published var searchedServices: Set<UUID> = []
    @Published var failedServices: Set<UUID> = []
    @Published var totalServicesCount = 0
    
    @Published var isFetchingStreams = false
    @Published var currentFetchingTitle = ""
    @Published var streamFetchProgress = ""
    @Published var streamOptions: [StreamOption] = []
    @Published var streamError: String?
    @Published var showingStreamError = false
    @Published var showingStreamMenu = false

    /// Set alongside `streamError` when the failure is attributable to an unresolved
    /// Cloudflare/DDoS-Guard challenge (CloudflareBypassManager tried silently and gave up).
    /// Drives an extra "Verify Cloudflare" action on the stream error alert.
    @Published var pendingCloudflareURL: URL?
    var pendingCloudflareRetry: (() -> Void)?
    
    @Published var selectedResult: SearchItem?
    @Published var showingPlayAlert = false
    @Published var expandedServices: Set<UUID> = []
    @Published var showingFilterEditor = false
    @Published var highQualityThreshold: Double = 0.9
    
    @Published var showingSeasonPicker = false
    @Published var showingEpisodePicker = false
    @Published var showingSubtitlePicker = false
    @Published var availableSeasons: [[EpisodeLink]] = []
    @Published var selectedSeasonIndex = 0
    @Published var pendingEpisodes: [EpisodeLink] = []
    @Published var subtitleOptions: [(title: String, url: String)] = []

    // MARK: - Stremio addon results
    @Published var stremioResults: [UUID: [StremioStream]] = [:]
    @Published var stremioSearchedAddons: Set<UUID> = []
    @Published var isSearchingStremio = false
    @Published var selectedStremioStream: StremioStream? = nil
    @Published var selectedStremioAddon: StremioAddon? = nil
    @Published var showingStremioPlayAlert = false
    @Published var stremioStreamOptions: [StremioStream]? = nil
    @Published var showingStremioStreamPicker = false

    var pendingSubtitles: [String]?
    var pendingService: Service?
    var pendingResult: SearchItem?
    var pendingJSController: JSController?
    var pendingStreamURL: String?
    var pendingStreamName: String?
    var pendingStreamLanguageHints: [String] = []
    var pendingStreamMetadataHints: [String] = []
    var pendingHeaders: [String: String]?
    var pendingSubtitleHeadersByURL: [String: [String: String]]?
    /// Show/details URL from the selected service search result. This is the URL accepted by
    /// `extractEpisodes`; keep it distinct from the selected episode's stream-extraction href.
    var pendingServiceHref: String?
    var pendingPlaybackAutoMode = false
    var pendingPlaybackRetryCount = 0
    
    init() {
        highQualityThreshold = UserDefaults.standard.object(forKey: "highQualityThreshold") as? Double ?? 0.9
    }
    
    func resetPickerState() {
        availableSeasons = []
        pendingEpisodes = []
        pendingResult = nil
        pendingJSController = nil
        selectedSeasonIndex = 0
        isFetchingStreams = false
#if os(tvOS)
        // Preserve the existing Apple TV picker-state behavior. The service content href is used
        // only by iPhone/iPad next-episode pre-staging.
        pendingServiceHref = nil
#endif
    }
    
    func resetStreamState() {
        isFetchingStreams = false
        showingStreamMenu = false
        pendingSubtitles = nil
        pendingService = nil
        pendingServiceHref = nil
        pendingStreamName = nil
        pendingStreamLanguageHints = []
        pendingStreamMetadataHints = []
        pendingSubtitleHeadersByURL = nil
        pendingPlaybackAutoMode = false
        pendingPlaybackRetryCount = 0
    }
}

struct ModulesSearchResultsSheet: View {
    /// Base title from caller (TMDB or season-specific)
    let mediaTitle: String
    /// Optional season-specific override (AniList season title)
    let seasonTitleOverride: String?
    let originalTitle: String?
    let isMovie: Bool
    let isAnimeContent: Bool
    let selectedEpisode: TMDBEpisode?
    let tmdbId: Int
    /// Optional release/first-air year used as a wrong-title guard by search-based providers.
    var mediaYear: Int? = nil
    /// Non-nil for anime to force E## format
    let animeSeasonTitle: String?
    let posterPath: String?
    /// TMDB's original language, used by the optional original-audio stream filter.
    var originalAudioLanguage: String? = nil
    /// IMDB ID for Stremio addon lookups (tt-prefixed)
    var imdbId: String? = nil
    /// Original TMDB season/episode numbers for anime (before AniList restructuring), used by TheIntroDB.
    var originalTMDBSeasonNumber: Int? = nil
    var originalTMDBEpisodeNumber: Int? = nil
    /// One-episode specials should search by exact title instead of appending E1.
    var specialTitleOnlySearch: Bool = false
    var episodePlaybackContext: EpisodePlaybackContext? = nil
    /// When true, selecting a stream downloads instead of playing
    var downloadMode: Bool = false
    /// When true, show only the compact Auto Mode runner instead of the full results picker.
    var autoModeOnly: Bool = false
    /// Explicit player source changes must remain manual even when global Auto Mode is enabled.
    /// This does not disable the separate Auto-Select Episodes preference.
    var ignoresAutoMode: Bool = false
    /// Watch Together can request automatic local source resolution without changing the user's
    /// global Auto Mode preference. It still uses the normal source ordering and matching rules.
    var forceAutomaticPlayback: Bool = false
    /// Caller-owned state that survives a dismissed Auto Mode sheet so a failed player can
    /// resume at the next source instead of starting the same provider again from retry zero.
    var autoModeRetrySession: AutoModeRetrySession? = nil
    /// Immutable identity for the caller's exact playback target. Unlike the session reference,
    /// this value cannot drift if another tap resets that shared session while resolution is live.
    var autoModeRecoveryIdentity: AutoModePlaybackRecoveryIdentity? = nil
    /// Live recovery owner used after the Auto Mode sheet has been dismissed for playback.
    var onAutoModePlaybackFailure: ((PlaybackFailureReport, AutoModePlaybackRecoveryIdentity) -> Void)? = nil
    /// An in-player Watch Together transition is not the shared media yet, but it still requires
    /// fail-closed anime title/context matching before the coordinator commits that revision.
    var watchTogetherExactHandoff: Bool = false
    /// Called when a download has been enqueued (for Download All flow)
    var onDownloadEnqueued: (() -> Void)? = nil
    /// Called when user taps "Skip" (for Download All flow)
    var onSkipRequested: (() -> Void)? = nil
    /// When provided, selecting a source resolves a request instead of presenting a new player.
    var onResolvedPlaybackRequest: ((PlayerResolvedPlaybackRequest) -> Void)? = nil
    /// Called synchronously after a source has been resolved but before this sheet begins
    /// dismissing. In-player replacements use this to fence callbacks from the outgoing item
    /// during the short dismissal-to-resolution handoff without treating a cancelled sheet as a
    /// committed source change.
    var onPlaybackSelectionCommitted: (() -> Void)? = nil
    /// Scopes legacy next-episode notifications to the detail window that launched playback.
    /// UUID routing avoids waking a second Stage Manager window showing the same title.
    var nextEpisodeNotificationRoute: UUID? = nil
    /// TMDB genre 16 (animation) hint, used to distinguish western cartoons from live action.
    var isAnimationGenre16: Bool = false

    @Environment(\.presentationMode) var presentationMode
    @StateObject private var viewModel = ModulesSearchResultsViewModel()
    @StateObject private var serviceManager = ServiceManager.shared
    @StateObject private var stremioManager = StremioAddonManager.shared
#if os(iOS) && !targetEnvironment(macCatalyst)
    @StateObject private var skyStreamManager = SkyStreamPluginManager.shared
#endif
    @StateObject private var algorithmManager = AlgorithmManager.shared
    @StateObject private var healthStore = SourceHealthStore.shared
    @State private var autoModeDidRun = false
    @State private var autoModeRunToken: String?
    @State private var autoModeCancelled = false
    @State private var autoModeAttemptedSourceIds: Set<String> = []
    @State private var autoModeRetryScheduled = false
    @State private var autoModeLastFailureMessage: String?
    @State private var autoModeSelectionTask: Task<Void, Never>?
    @State private var isSheetActive = false
    @State private var autoModeDownloadTask: Task<Void, Never>?
    @State private var serviceStreamExtractionRequest: JSCallbackDeadline<ServiceStreamExtractionResult>?
    @State private var serviceStreamExtractionGeneration: UUID?
    @State private var showManualPicker = false
    @State private var sheetHostController: UIViewController?
    @AppStorage(ServicesSheetPresentationSettings.stremioStyleEnabledKey) private var stremioStyleSheetEnabled = ServicesSheetPresentationSettings.defaultStremioStyleEnabled
    @AppStorage(ServicesResultRankingSettings.minimumSimilarityKey) private var storedServiceResultMinimumSimilarity = ServicesResultRankingSettings.defaultMinimumSimilarity
    @AppStorage(ServicesResultRankingSettings.dropMismatchedResultsKey) private var dropMismatchedServiceResults = ServicesResultRankingSettings.defaultDropMismatchedResults
    @State private var selectedStremioStyleSourceId: String?
    @State private var thresholdEditorValue = ServicesResultRankingSettings.defaultMinimumSimilarity
    @State private var manualSearchGeneration = UUID()
    @State private var stremioStyleServiceResolutionGeneration = UUID()
    @State private var stremioStyleServiceResolutionStates: [String: StremioStyleServiceResolutionState] = [:]
    @State private var stremioStyleServiceResolutionWork: [UUID: StremioStyleServiceResolutionWork] = [:]
    @State private var selectedResolvedServiceStream: StremioStyleResolvedServiceStream?
    @State private var showingResolvedServiceStreamAlert = false
#if os(iOS) && !targetEnvironment(macCatalyst)
    @State private var skyStreamResults: [String: [ValidatedSkyStreamOption]] = [:]
    @State private var skyStreamSearchedSourceIds: Set<String> = []
    @State private var skyStreamSearchingSourceIds: Set<String> = []
    @State private var skyStreamSearchTask: Task<Void, Never>?
    @State private var selectedSkyStreamOption: ValidatedSkyStreamOption?
    @State private var selectedSkyStreamProvider: SkyStreamProviderDescriptor?
    @State private var skyStreamPickerOptions: [ValidatedSkyStreamOption] = []
    @State private var showingSkyStreamPlayAlert = false
    @State private var showingSkyStreamPicker = false
#endif
    private static let maxRetainedServiceResultsPerService = 300
    private static let maxVisibleServiceResultsPerService = 80
    private static let maxRetainedServiceStreamOptions = 300
    private static let maxInspectedServiceStreamEntries = 1_200
    private static let maxMetadataValuesPerField = 32
    private static let maxRetainedStremioStreamsPerAddon = 300
    private static let maxVisibleStremioStreamsPerAddon = 80
#if os(iOS) && !targetEnvironment(macCatalyst)
    // Each validated option can retain a bounded manifest/route graph, so keep the UI cache much
    // smaller than raw Service/Stremio rows. The resolver already returns its strongest options.
    private static let maxRetainedSkyStreamOptionsPerProvider = 8
    private static let maxVisibleSkyStreamOptionsPerProvider = 8
    private static let maxConcurrentSkyStreamResolutions = 3
#endif
    // Probes are intentionally bounded because timed-out provider networking can outlive its JS
    // context. The larger ranked pool still lets resolution backfill past early rule-rejected hits.
    private static let maxStremioStyleServiceCandidatesPerSource = 80
    private static let maxStremioStyleServiceCandidatesPerSheet = 80
    private static let maxConcurrentStremioStyleServiceResolutions = 2
    private static let resolvedServiceStreamFreshness: TimeInterval = 120

    private var activeAutoModeRetrySession: AutoModeRetrySession? {
        guard let session = autoModeRetrySession,
              let identity = autoModeRecoveryIdentity,
              session.matches(identity) else {
            return nil
        }
        return session
    }

    private var playbackRecoveryIdentityIsCurrent: Bool {
        guard let identity = autoModeRecoveryIdentity else { return true }
        return autoModeRetrySession?.matches(identity) == true
    }

    private var serviceResultMinimumSimilarity: Double {
        ServicesResultRankingSettings.clampedMinimumSimilarity(storedServiceResultMinimumSimilarity)
    }

    private var shouldDropMismatchedServiceResults: Bool {
        dropMismatchedServiceResults
    }

    private var effectiveTitle: String { seasonTitleOverride ?? mediaTitle }
    private var isForcedWatchTogetherAnimePlayback: Bool {
        (forceAutomaticPlayback || watchTogetherExactHandoff)
            && !isMovie
            && (isAnimeContent
                || animeSeasonTitle != nil
                || episodePlaybackContext?.hasAnimeMediaId == true)
    }
    private var playerMediaTitle: String {
        if isAnimeContent || animeSeasonTitle != nil {
            if let title = nonPlaceholderAnimeTitle(seasonTitleOverride) {
                return title
            }
            if let title = nonPlaceholderAnimeTitle(animeSeasonTitle) {
                return title
            }
        }
        return effectiveTitle
    }
    private var animeEffectiveTitle: String { effectiveTitle }
    private var strippedAnimeFallbackTitle: String? {
        guard isAnimeContent || animeSeasonTitle != nil else { return nil }
        let stripped = effectiveTitle
            .replacingOccurrences(of: "(?i)season\\s+\\d+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty,
              stripped.caseInsensitiveCompare(effectiveTitle) != .orderedSame else {
            return nil
        }
        return stripped
    }
    private var normalizedAnimeSequelTitle: String? {
        guard isAnimeContent || animeSeasonTitle != nil,
              let seasonNumber = selectedEpisode?.seasonNumber,
              seasonNumber > 1 else {
            return nil
        }

        let trimmedTitle = effectiveTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = String(seasonNumber)
        guard trimmedTitle.hasSuffix(suffix) else { return nil }

        let attachedBaseTitle = String(trimmedTitle.dropLast(suffix.count))
        guard let lastCharacter = attachedBaseTitle.last,
              lastCharacter.isLetter else {
            return nil
        }

        let baseTitle = attachedBaseTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(baseTitle) Season \(seasonNumber)"
    }
    private var fallbackAnimeSearchQuery: String? {
        guard let strippedAnimeFallbackTitle else { return nil }
        if let episode = selectedEpisode {
            if specialTitleOnlySearch {
                return strippedAnimeFallbackTitle
            }
            if isAnimeContent || animeSeasonTitle != nil {
                return "\(strippedAnimeFallbackTitle) E\(episode.episodeNumber)"
            }
            return "\(strippedAnimeFallbackTitle) S\(episode.seasonNumber)E\(episode.episodeNumber)"
        }
        return strippedAnimeFallbackTitle
    }
    private var normalizedAnimeSequelSearchQuery: String? {
        guard let normalizedAnimeSequelTitle else { return nil }
        if let episode = selectedEpisode, !specialTitleOnlySearch {
            return "\(normalizedAnimeSequelTitle) E\(episode.episodeNumber)"
        }
        return normalizedAnimeSequelTitle
    }

    private var displayTitle: String {
        if let episode = selectedEpisode {
            if specialTitleOnlySearch {
                return animeSeasonTitle != nil ? animeEffectiveTitle : effectiveTitle
            }
            if isAnimeContent || animeSeasonTitle != nil {
                return "\(animeEffectiveTitle) E\(episode.episodeNumber)"
            }
            return "\(effectiveTitle) S\(episode.seasonNumber)E\(episode.episodeNumber)"
        }
        return effectiveTitle
    }
    
    private var episodeSeasonInfo: String {
        guard let episode = selectedEpisode else { return "" }
        if specialTitleOnlySearch {
            return "Special"
        }
        if isAnimeContent || animeSeasonTitle != nil {
            return "E\(episode.episodeNumber)"
        }
        return "S\(episode.seasonNumber)E\(episode.episodeNumber)"
    }
    
    private var mediaTypeText: String { isMovie ? "Movie" : "TV Show" }
    private var mediaTypeColor: Color { isMovie ? .purple : .green }
    private var resolvedPosterURL: String? {
        posterPath.flatMap { path in
            path.hasPrefix("http") ? path : "https://image.tmdb.org/t/p/w500\(path)"
        }
    }

    private var effectivePlaybackContext: EpisodePlaybackContext? {
        guard let context = episodePlaybackContext,
              let selectedEpisode else { return episodePlaybackContext }
        if (forceAutomaticPlayback || watchTogetherExactHandoff),
           isAnimeContent || animeSeasonTitle != nil || context.hasAnimeMediaId {
            // Forced automatic anime playback is the Watch Together path. It must keep the
            // exact carried context; retargeting a near match can turn a cross-cour handoff
            // into the receiver's local S1E1.
            guard context.localSeasonNumber == selectedEpisode.seasonNumber,
                  context.localEpisodeNumber == selectedEpisode.episodeNumber else {
                return nil
            }
            return context
        }
        if context.localSeasonNumber == selectedEpisode.seasonNumber,
           context.localEpisodeNumber == selectedEpisode.episodeNumber {
            // The context supplied by MediaDetail/Watch Together is already exact. Re-projecting
            // it through a fallback episode number can corrupt an anime handoff into S1E1.
            return context
        }
        guard !context.isSpecial,
              context.localSeasonNumber == selectedEpisode.seasonNumber else {
            // EpisodePlaybackContext cannot safely translate across anime seasons/cours.
            return nil
        }
        return context.forEpisodeNumber(selectedEpisode.episodeNumber)
    }

    private var hasAnimeLookupContext: Bool {
        isAnimeContent ||
            animeSeasonTitle != nil ||
            effectivePlaybackContext?.hasAnimeMediaId == true
    }

    private var shouldSearchStremio: Bool {
        guard !isMovie,
              let context = effectivePlaybackContext,
              context.isSpecial else {
            return true
        }
        return context.resolvedTMDBSeasonNumber != nil && context.resolvedTMDBEpisodeNumber != nil
    }

    private var streamLookupSeasonNumber: Int? {
        if let context = effectivePlaybackContext, context.isSpecial {
            return context.resolvedTMDBSeasonNumber
        }
        guard !specialTitleOnlySearch else { return nil }
        return effectivePlaybackContext?.resolvedTMDBSeasonNumber ?? originalTMDBSeasonNumber ?? selectedEpisode?.seasonNumber
    }

    private var streamLookupEpisodeNumber: Int? {
        if let context = effectivePlaybackContext, context.isSpecial {
            return context.resolvedTMDBEpisodeNumber
        }
        guard !specialTitleOnlySearch else { return nil }
        return effectivePlaybackContext?.resolvedTMDBEpisodeNumber ?? originalTMDBEpisodeNumber ?? selectedEpisode?.episodeNumber
    }

    private var stremioLookupAniListId: Int? {
        effectivePlaybackContext?.anilistMediaId
    }

#if os(iOS) && !targetEnvironment(macCatalyst)
    private var activeSkyStreamProviders: [SkyStreamProviderDescriptor] {
        guard PlatformCapabilities.current.supportsSkyStreamPlugins,
              skyStreamManager.isLoaded else { return [] }
        return skyStreamManager.providers.filter(\.isEnabled)
    }

    private var skyStreamResolutionTarget: SkyStreamResolutionTarget {
        // Keep canonical anime identities ahead of decorated search queries. SkyStream bounds
        // this vocabulary before handing it to third-party code, so appending these after the
        // Stremio query ladder could silently discard the title that actually clears the 85%
        // identity gate.
        var aliases = [
            animeSeasonTitle,
            seasonTitleOverride,
            normalizedAnimeSequelTitle
        ].compactMap { $0 }
        if !isForcedWatchTogetherAnimePlayback {
            aliases.append(contentsOf: [originalTitle, strippedAnimeFallbackTitle].compactMap { $0 })
        }
        aliases.append(effectiveTitle)
        aliases.append(contentsOf: stremioCatalogTitleCandidates)

        var seenAliases = Set<String>()
        aliases = aliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter {
                seenAliases.insert(
                    $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                ).inserted
            }

        let primaryTitle = playerMediaTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        aliases.removeAll { $0.caseInsensitiveCompare(primaryTitle) == .orderedSame }

        var absoluteCandidates: [Int] = []
        if let absolute = effectivePlaybackContext?.animeAbsoluteEpisodeNumber {
            absoluteCandidates.append(absolute)
        }
        if let localEpisode = effectivePlaybackContext?.localEpisodeNumber ?? selectedEpisode?.episodeNumber {
            absoluteCandidates.append(localEpisode)
        }
        if let mappedEpisode = streamLookupEpisodeNumber {
            absoluteCandidates.append(mappedEpisode)
        }
        var seenEpisodes = Set<Int>()
        absoluteCandidates = absoluteCandidates.filter { $0 > 0 && seenEpisodes.insert($0).inserted }

        let dubSearchText = ([primaryTitle] + aliases).joined(separator: " ")
        let wantsDubbed: Bool? = dubSearchText.range(
            of: #"(?i)(?:^|[^a-z0-9])(?:dub|dubbed)(?:$|[^a-z0-9])"#,
            options: .regularExpression
        ) == nil ? nil : true

        return SkyStreamResolutionTarget(
            kind: isMovie ? .movie : .episode,
            title: primaryTitle,
            aliases: Array(aliases.prefix(8)),
            year: hasAnimeLookupContext
                ? nil
                : mediaYear.flatMap { (1800...3000).contains($0) ? $0 : nil },
            season: isMovie ? nil : streamLookupSeasonNumber,
            episode: isMovie ? nil : streamLookupEpisodeNumber,
            absoluteEpisodeCandidates: Array(absoluteCandidates.prefix(3)),
            isAnime: hasAnimeLookupContext,
            isSpecial: specialTitleOnlySearch || effectivePlaybackContext?.isSpecial == true,
            wantsDubbed: wantsDubbed,
            requiresExactIdentity: forceAutomaticPlayback || watchTogetherExactHandoff
        )
    }
#endif

    private var sourceKindList: String {
#if os(iOS) && !targetEnvironment(macCatalyst)
        "services, addons, or SkyStream providers"
#else
        "services or addons"
#endif
    }

    private var sourceKindSelectionList: String {
#if os(iOS) && !targetEnvironment(macCatalyst)
        "service, addon, or SkyStream provider"
#else
        "service or addon"
#endif
    }

    private var activeSkyStreamSourceCount: Int {
#if os(iOS) && !targetEnvironment(macCatalyst)
        activeSkyStreamProviders.count
#else
        0
#endif
    }

    private var searchedSkyStreamSourceCount: Int {
#if os(iOS) && !targetEnvironment(macCatalyst)
        skyStreamSearchedSourceIds.subtracting(skyStreamSearchingSourceIds).count
#else
        0
#endif
    }

    private var isSearchingSkyStream: Bool {
#if os(iOS) && !targetEnvironment(macCatalyst)
        !skyStreamSearchingSourceIds.isEmpty
#else
        false
#endif
    }

    private var hasAnyActiveSources: Bool {
        !serviceManager.activeServices.isEmpty
            || !stremioManager.activeAddons.isEmpty
            || activeSkyStreamSourceCount > 0
    }

    private var stremioCatalogTitleCandidates: [String] {
        var candidates: [String] = []
        if hasAnimeLookupContext,
           !isForcedWatchTogetherAnimePlayback,
           let originalTitle,
           !originalTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(originalTitle)
        }
        candidates.append(contentsOf: titleRankingCandidates())
        candidates.append(displayTitle)
        if !isForcedWatchTogetherAnimePlayback,
           let fallbackAnimeSearchQuery {
            candidates.append(fallbackAnimeSearchQuery)
        }
        if let episodeName = selectedEpisode?.name, !episodeName.isEmpty {
            candidates.append("\(sheetTitleBaseForMatching) \(episodeName)")
        }

        var seen = Set<String>()
        return candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert(normalizeTitleForRanking($0)).inserted }
    }
    
    private var searchStatusText: String {
        let anySearching = viewModel.isSearching || viewModel.isSearchingStremio || isSearchingSkyStream
        if anySearching {
            let completed = viewModel.searchedServices.count
                + viewModel.stremioSearchedAddons.count
                + searchedSkyStreamSourceCount
            let total = viewModel.totalServicesCount
                + stremioManager.activeAddons.count
                + activeSkyStreamSourceCount
            return "Searching... (\(completed)/\(total))"
        }
        if isResolvingStremioStyleServiceStreams {
            return "Checking streams against Extra Source Settings..."
        }
        return "Search complete"
    }
    
    private var searchStatusColor: Color {
        isStremioStyleSearchActive ? .secondary : .green
    }
    
    private func lowerQualityResultsText(count: Int) -> String {
        "\(count) lower quality result\(count == 1 ? "" : "s") (<\(Int(viewModel.highQualityThreshold * 100))%)"
    }

    private func nonPlaceholderAnimeTitle(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty, trimmed.lowercased() != "anime" else {
            return nil
        }
        return trimmed
    }
    
    @ViewBuilder
    private var searchInfoSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Searching for:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text(displayTitle)
                    .font(.headline)
                    .fontWeight(.semibold)
                
                if let episode = selectedEpisode, !episode.name.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(episode.name)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Spacer()
                            Text(episodeSeasonInfo)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .cornerRadius(8)
                        }
                        
                        if let overview = episode.overview, !overview.isEmpty {
                            Text(overview)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                statusBar
            }
            .padding(.vertical, 8)
        }
    }
    
    @ViewBuilder
    private var statusBar: some View {
        HStack {
            Text(mediaTypeText)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(mediaTypeColor.opacity(0.2))
                .foregroundColor(mediaTypeColor)
                .cornerRadius(8)
            
            Spacer()
            
            if viewModel.isSearching || viewModel.isSearchingStremio || isSearchingSkyStream {
                HStack(spacing: 8) {
                    EclipseLoadingIndicator()
                        .scaleEffect(0.8)
                    Text(searchStatusText)
                        .font(.caption)
                        .foregroundColor(searchStatusColor)
                }
            } else {
                Text(searchStatusText)
                    .font(.caption)
                    .foregroundColor(searchStatusColor)
            }
        }
    }
    
    @ViewBuilder
    private var noActiveServicesSection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundColor(.orange)
                
                Text("No Active Sources")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Text("You don't have any active \(sourceKindList). Add or enable a source in Settings.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }
    
    private enum ResultItem: Identifiable {
        case service(Service)
        case stremio(StremioAddon)
#if os(iOS) && !targetEnvironment(macCatalyst)
        case skyStream(SkyStreamProviderDescriptor)
#endif

        var id: String {
            switch self {
            case .service(let s): return s.id.uuidString
            case .stremio(let a): return a.id.uuidString
#if os(iOS) && !targetEnvironment(macCatalyst)
            case .skyStream(let provider): return provider.id
#endif
            }
        }

        var sortIndex: Int64 {
            switch self {
            case .service(let s): return s.sortIndex
            case .stremio(let a): return a.sortIndex
#if os(iOS) && !targetEnvironment(macCatalyst)
            case .skyStream(let provider): return Int64(provider.sortIndex)
#endif
            }
        }

        var sourceId: String {
            switch self {
            case .service(let s): return SourceHealth.serviceId(s)
            case .stremio(let a): return SourceHealth.stremioId(a)
#if os(iOS) && !targetEnvironment(macCatalyst)
            case .skyStream(let provider): return provider.id
#endif
            }
        }

        var displayName: String {
            switch self {
            case .service(let s): return s.metadata.sourceName
            case .stremio(let a): return a.manifest.name
#if os(iOS) && !targetEnvironment(macCatalyst)
            case .skyStream(let provider): return provider.displayName
#endif
            }
        }
    }

    private var sortedResultItems: [ResultItem] {
        let services: [ResultItem] = serviceManager.activeServices.map { .service($0) }
        let addons: [ResultItem] = stremioManager.activeAddons.map { .stremio($0) }
#if os(iOS) && !targetEnvironment(macCatalyst)
        let skyStreamProviders: [ResultItem] = activeSkyStreamProviders.map { .skyStream($0) }
#else
        let skyStreamProviders: [ResultItem] = []
#endif
        let orderRank = autoModeSourceOrderRank
        return (services + addons + skyStreamProviders).sorted {
            let lhsRank = orderRank[autoModeSourceId(for: $0)]
            let rhsRank = orderRank[autoModeSourceId(for: $1)]
            if let lhsRank, let rhsRank, lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            if lhsRank != nil {
                return true
            }
            if rhsRank != nil {
                return false
            }
            if $0.sortIndex == $1.sortIndex {
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            return $0.sortIndex < $1.sortIndex
        }
    }

    private var autoModeSourceOrderIds: [String] {
        UserDefaults.standard.stringArray(forKey: "servicesAutoModeSourceOrderIds") ?? []
    }

    private var autoModeSourceOrderRank: [String: Int] {
        var ranks: [String: Int] = [:]
        for (index, sourceId) in autoModeSourceOrderIds.enumerated() where ranks[sourceId] == nil {
            ranks[sourceId] = index
        }
        return ranks
    }

    private var activeAutoModeItems: [ResultItem] {
        _ = healthStore.version
        let items = sortedResultItems
        let byId = items.reduce(into: [String: ResultItem]()) { result, item in
            let id = autoModeSourceId(for: item)
            if result[id] == nil {
                result[id] = item
            }
        }
        let orderedIds = AutoModeSourceSelection.orderedSelectedSourceIds(
            availableSourceIds: items.map { autoModeSourceId(for: $0) }
        )
        // Forced Watch Together playback is fail-closed: an empty explicit selection must not
        // silently broaden into every installed source, and recently unhealthy sources retain
        // the same Auto Mode quarantine across all three source families.
        return orderedIds
            .compactMap { byId[$0] }
            .filter { !healthStore.shouldSkipForAutoMode(sourceId: $0.sourceId) }
    }

    @ViewBuilder
    private var unifiedResultsSections: some View {
        ForEach(sortedResultItems) { item in
            switch item {
            case .service(let service):
                serviceSection(service: service)
            case .stremio(let addon):
                stremioAddonSection(addon: addon)
#if os(iOS) && !targetEnvironment(macCatalyst)
            case .skyStream(let provider):
                skyStreamSection(provider: provider)
#endif
            }
        }
    }

    private var stremioStyleResultItems: [ResultItem] {
        guard let selectedStremioStyleSourceId else { return sortedResultItems }
        return sortedResultItems.filter { $0.sourceId == selectedStremioStyleSourceId }
    }

    private var isResolvingStremioStyleServiceStreams: Bool {
        stremioStyleServiceResolutionStates.values.contains(where: \.isPending)
    }

    private var isStremioStyleSearchActive: Bool {
        viewModel.isSearching
            || viewModel.isSearchingStremio
            || isSearchingSkyStream
            || isResolvingStremioStyleServiceStreams
    }

    private func stremioStyleServiceNeedsResolvedStreams(_ service: Service) -> Bool {
        StreamLanguageFilter.configuration(sourceId: SourceHealth.serviceId(service))?.canHideStreams == true
    }

    private func stremioStyleServiceResolutionKey(service: Service, result: SearchItem) -> String {
        "\(stremioStyleServiceResolutionGeneration.uuidString)|\(service.id.uuidString)|\(result.href)"
    }

    private func allStremioStyleServiceResolutionCandidates() -> [(service: Service, result: SearchItem)] {
        var candidatesByService: [(service: Service, results: [SearchItem])] = []
        for item in sortedResultItems {
            guard case .service(let service) = item,
                  stremioStyleServiceNeedsResolvedStreams(service),
                  let results = viewModel.moduleResults[service.id] else {
                continue
            }

            let filtered = filterResults(for: results)
            let sourceCandidates = Array(
                (filtered.highQuality + filtered.lowQuality)
                    .prefix(Self.maxStremioStyleServiceCandidatesPerSource)
            )
            if !sourceCandidates.isEmpty {
                candidatesByService.append((service, sourceCandidates))
            }
        }

        // Interleave sources so the global safety cap cannot be consumed entirely by the first
        // one or two providers in the user's ordering.
        var candidates: [(service: Service, result: SearchItem)] = []
        for index in 0..<Self.maxStremioStyleServiceCandidatesPerSource {
            for source in candidatesByService where source.results.indices.contains(index) {
                guard candidates.count < Self.maxStremioStyleServiceCandidatesPerSheet else { break }
                candidates.append((source.service, source.results[index]))
            }
            if candidates.count == Self.maxStremioStyleServiceCandidatesPerSheet { break }
        }
        return candidates
    }

    private func stremioStyleServiceCandidates(for service: Service) -> [SearchItem] {
        allStremioStyleServiceResolutionCandidates()
            .filter { $0.service.id == service.id }
            .map(\.result)
    }

    private func visibleResolvedServiceStreams(for service: Service) -> [StremioStyleResolvedServiceStream] {
        var visible: [StremioStyleResolvedServiceStream] = []
        let configuration = StreamLanguageFilter.configuration(
            sourceId: SourceHealth.serviceId(service)
        )
        for result in stremioStyleServiceCandidates(for: service) {
            let key = stremioStyleServiceResolutionKey(service: service, result: result)
            guard case .resolved(let resolvedStreams) = stremioStyleServiceResolutionStates[key] else {
                continue
            }
            for resolved in resolvedStreams where serviceStreamOptionIsVisible(
                resolved.option,
                configuration: configuration
            ) {
                visible.append(resolved)
                if visible.count == Self.maxVisibleServiceResultsPerService {
                    return visible
                }
            }
        }
        return visible
    }

    private func hasPendingStremioStyleServiceResolution(for service: Service) -> Bool {
        stremioStyleServiceCandidates(for: service).contains { result in
            let key = stremioStyleServiceResolutionKey(service: service, result: result)
            return stremioStyleServiceResolutionStates[key]?.isPending == true
        }
    }

    private func stremioStyleServiceResolutionAttention(
        for service: Service
    ) -> (failedCount: Int, verificationURL: URL?) {
        var failedCount = 0
        var verificationURL: URL?
        for result in stremioStyleServiceCandidates(for: service) {
            let key = stremioStyleServiceResolutionKey(service: service, result: result)
            switch stremioStyleServiceResolutionStates[key] {
            case .failed:
                failedCount += 1
            case .verificationRequired(let url):
                failedCount += 1
                if verificationURL == nil {
                    verificationURL = url
                }
            case .queued, .checking, .resolved, .none:
                break
            }
        }
        return (failedCount, verificationURL)
    }

    private var hasStremioStyleResults: Bool {
        stremioStyleResultItems.contains { item in
            switch item {
            case .service(let service):
                if stremioStyleServiceNeedsResolvedStreams(service) {
                    let attention = stremioStyleServiceResolutionAttention(for: service)
                    return hasPendingStremioStyleServiceResolution(for: service)
                        || !visibleResolvedServiceStreams(for: service).isEmpty
                        || attention.failedCount > 0
                }
                guard let results = viewModel.moduleResults[service.id] else { return false }
                let filtered = filterResults(for: results)
                return !filtered.highQuality.isEmpty || !filtered.lowQuality.isEmpty
            case .stremio(let addon):
                return !visibleStremioStreams(for: addon).isEmpty
#if os(iOS) && !targetEnvironment(macCatalyst)
            case .skyStream(let provider):
                return !visibleSkyStreamOptions(for: provider).isEmpty
                    || skyStreamSearchingSourceIds.contains(provider.id)
#endif
            }
        }
    }

    @ViewBuilder
    private var stremioStyleHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    stremioStyleFilterButton(title: "All", sourceId: nil)

                    ForEach(sortedResultItems) { item in
                        stremioStyleFilterButton(title: item.displayName, sourceId: item.sourceId)
                    }
                }
            }

            HStack(spacing: 6) {
                if isStremioStyleSearchActive {
                    EclipseLoadingIndicator()
                        .scaleEffect(0.55)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }

                Text(searchStatusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(Color.clear)
        .eclipseHideListRowSeparator()
    }

    private func stremioStyleFilterButton(title: String, sourceId: String?) -> some View {
        let isSelected = selectedStremioStyleSourceId == sourceId
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedStremioStyleSourceId = sourceId
            }
        } label: {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(isSelected ? .white : .primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(isSelected ? Color.accentColor : Color.primary.opacity(0.08))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var stremioStyleResults: some View {
        ForEach(stremioStyleResultItems) { item in
            switch item {
            case .service(let service):
                if stremioStyleServiceNeedsResolvedStreams(service) {
                    let streams = visibleResolvedServiceStreams(for: service)
                    ForEach(streams) { stream in
                        stremioStyleResolvedServiceRow(stream)
                    }
                    if hasPendingStremioStyleServiceResolution(for: service) {
                        stremioStyleServiceResolutionRow(service: service)
                    }
                    if stremioStyleServiceResolutionAttention(for: service).failedCount > 0 {
                        stremioStyleServiceAttentionRow(service: service)
                    }
                } else if let results = viewModel.moduleResults[service.id] {
                    let filtered = filterResults(for: results)
                    let visibleResults = filtered.highQuality + filtered.lowQuality
                    ForEach(visibleResults, id: \.id) { result in
                        stremioStyleServiceRow(result: result, service: service)
                    }
                }
            case .stremio(let addon):
                let streams = visibleStremioStreams(for: addon)
                if !streams.isEmpty {
                    ForEach(Array(streams.prefix(Self.maxVisibleStremioStreamsPerAddon).enumerated()), id: \.offset) { _, stream in
                        stremioStyleStreamRow(stream: stream, addon: addon)
                    }
                }
#if os(iOS) && !targetEnvironment(macCatalyst)
            case .skyStream(let provider):
                ForEach(visibleSkyStreamOptions(for: provider)) { stream in
                    stremioStyleSkyStreamRow(stream, provider: provider)
                }
#endif
            }
        }
    }

    private func stremioStyleServiceRow(result: SearchItem, service: Service) -> some View {
        let similarity = max(
            algorithmManager.calculateSimilarity(original: effectiveTitle, result: result.title),
            originalTitle.map { algorithmManager.calculateSimilarity(original: $0, result: result.title) } ?? 0
        )

        return Button {
            viewModel.selectedResult = result
            viewModel.showingPlayAlert = true
        } label: {
            HStack(alignment: .top, spacing: 12) {
                stremioStyleActionIcon

                VStack(alignment: .leading, spacing: 5) {
                    Text(service.metadata.sourceName)
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)

                    Text(result.title)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        Text("\(Int(similarity * 100))% match")
                        if let episode = selectedEpisode {
                            Text("•")
                            Text("Episode \(episode.episodeNumber)")
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                Spacer(minLength: 0)
            }
            .stremioStyleStreamCard()
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .eclipseHideListRowSeparator()
        .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
    }

    private func stremioStyleResolvedServiceRow(_ resolved: StremioStyleResolvedServiceStream) -> some View {
        let similarity = max(
            algorithmManager.calculateSimilarity(original: effectiveTitle, result: resolved.result.title),
            originalTitle.map { algorithmManager.calculateSimilarity(original: $0, result: resolved.result.title) } ?? 0
        )

        return Button {
            selectStremioStyleResolvedServiceStream(resolved)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                stremioStyleActionIcon

                VStack(alignment: .leading, spacing: 5) {
                    Text("\(resolved.service.metadata.sourceName) · \(resolved.option.name)")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(resolved.result.title)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        Text("\(Int(similarity * 100))% match")
                        if let episode = selectedEpisode {
                            Text("•")
                            Text("Episode \(episode.episodeNumber)")
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                Spacer(minLength: 0)
            }
            .stremioStyleStreamCard()
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .eclipseHideListRowSeparator()
        .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
    }

    private func stremioStyleServiceResolutionRow(service: Service) -> some View {
        HStack(spacing: 10) {
            EclipseLoadingIndicator()
                .scaleEffect(0.55)
                .frame(width: 14, height: 14)
            Text("Checking \(service.metadata.sourceName) streams against Extra Source Settings…")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .listRowBackground(Color.clear)
        .eclipseHideListRowSeparator()
    }

    private func stremioStyleServiceAttentionRow(service: Service) -> some View {
        let attention = stremioStyleServiceResolutionAttention(for: service)
        let hasVerification = attention.verificationURL != nil

        return Button {
            handleStremioStyleServiceResolutionAttention(
                service: service,
                verificationURL: attention.verificationURL
            )
        } label: {
            HStack(spacing: 10) {
                Image(systemName: hasVerification ? "checkmark.shield" : "arrow.clockwise.circle")
                    .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(hasVerification
                         ? "Cloudflare verification is needed for \(service.metadata.sourceName)."
                         : "Some \(service.metadata.sourceName) streams could not be checked.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                    Text(stremioStyleServiceAttentionActionTitle(hasVerification: hasVerification))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.accentColor)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .eclipseHideListRowSeparator()
    }

    private func stremioStyleStreamRow(stream: StremioStream, addon: StremioAddon) -> some View {
        Button {
            viewModel.selectedStremioStream = stream
            viewModel.selectedStremioAddon = addon
            viewModel.showingStremioPlayAlert = true
        } label: {
            HStack(alignment: .top, spacing: 12) {
                stremioStyleActionIcon

                VStack(alignment: .leading, spacing: 5) {
                    Text("\(addon.manifest.name) · \(stremioStreamLabel(for: stream))")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if let details = stremioStyleDetails(for: stream) {
                        Text(details)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(4)
                            .multilineTextAlignment(.leading)
                    }

                    HStack(spacing: 6) {
                        if let size = stream.formattedVideoSize {
                            Label(size, systemImage: "externaldrive")
                        }
                        if let language = AutoModeStreamSelection.stremioLanguageLabel(for: stream) {
                            Label(language, systemImage: "globe")
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                Spacer(minLength: 0)
            }
            .stremioStyleStreamCard()
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .eclipseHideListRowSeparator()
        .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
    }

    private var stremioStyleActionIcon: some View {
        Image(systemName: downloadMode ? "arrow.down" : "play.fill")
            .font(.caption.bold())
            .foregroundColor(.white)
            .frame(width: 34, height: 34)
            .background(Color.green)
            .clipShape(Circle())
    }

    private func stremioStyleDetails(for stream: StremioStream) -> String? {
        let headline = stremioStreamLabel(for: stream)
        var seen = Set<String>()
        let details = [stream.description, stream.behaviorHints?.filename, stream.title]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare(headline) != .orderedSame }
            .filter { seen.insert($0.lowercased()).inserted }
        guard !details.isEmpty else { return nil }
        return details.joined(separator: "\n")
    }
    
    @ViewBuilder
    private func serviceSection(service: Service) -> some View {
        let results = viewModel.moduleResults[service.id]
        let hasSearched = viewModel.searchedServices.contains(service.id)
        let isCurrentlySearching = viewModel.isSearching && !hasSearched
        
        if let results = results {
            let filteredResults = filterResults(for: results)
            
            Section(header: serviceHeader(for: service, highQualityCount: filteredResults.highQuality.count, lowQualityCount: filteredResults.lowQuality.count, isSearching: false)) {
                healthWarningRow(sourceId: SourceHealth.serviceId(service))
                if results.isEmpty || (filteredResults.highQuality.isEmpty && filteredResults.lowQuality.isEmpty) {
                    noResultsRow
                } else {
                    serviceResultsContent(filteredResults: filteredResults, service: service)
                }
            }
        } else if isCurrentlySearching {
            Section(header: serviceHeader(for: service, highQualityCount: 0, lowQualityCount: 0, isSearching: true)) {
                healthWarningRow(sourceId: SourceHealth.serviceId(service))
                searchingRow
            }
        } else if !viewModel.isSearching && !hasSearched {
            Section(header: serviceHeader(for: service, highQualityCount: 0, lowQualityCount: 0, isSearching: false)) {
                healthWarningRow(sourceId: SourceHealth.serviceId(service))
                notSearchedRow
            }
        }
    }

    @ViewBuilder
    private func healthWarningRow(sourceId: String) -> some View {
        if let warning = healthStore.warningText(for: sourceId) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(warning)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }
    
    @ViewBuilder
    private var noResultsRow: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.orange)
            Text("No results found")
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
    }
    
    @ViewBuilder
    private var searchingRow: some View {
        HStack {
            EclipseLoadingIndicator()
                .scaleEffect(0.8)
            Text("Searching...")
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
    }
    
    @ViewBuilder
    private var notSearchedRow: some View {
        HStack {
            Image(systemName: "minus.circle")
                .foregroundColor(.gray)
            Text("Not searched")
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
    }
    
    @ViewBuilder
    private func serviceResultsContent(filteredResults: (highQuality: [SearchItem], lowQuality: [SearchItem]), service: Service) -> some View {
        ForEach(filteredResults.highQuality, id: \.id) { searchResult in
            EnhancedMediaResultRow(
                result: searchResult,
                originalTitle: effectiveTitle,
                alternativeTitle: originalTitle,
                episode: selectedEpisode,
                onTap: {
                    viewModel.selectedResult = searchResult
                    viewModel.showingPlayAlert = true
                }, highQualityThreshold: viewModel.highQualityThreshold
            )
        }
        
        if !filteredResults.lowQuality.isEmpty {
            lowQualityResultsSection(filteredResults: filteredResults, service: service)
        }
    }
    
    @ViewBuilder
    private func lowQualityResultsSection(filteredResults: (highQuality: [SearchItem], lowQuality: [SearchItem]), service: Service) -> some View {
        let isExpanded = viewModel.expandedServices.contains(service.id)
        
        Button(action: {
            withAnimation(.easeInOut(duration: 0.3)) {
                if isExpanded {
                    viewModel.expandedServices.remove(service.id)
                } else {
                    viewModel.expandedServices.insert(service.id)
                }
            }
        }) {
            HStack {
                Image(systemName: "questionmark.circle")
                    .foregroundColor(.orange)
                
                Text(lowerQualityResultsText(count: filteredResults.lowQuality.count))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(PlainButtonStyle())
        
        if isExpanded {
            ForEach(filteredResults.lowQuality, id: \.id) { searchResult in
                CompactMediaResultRow(
                    result: searchResult,
                    originalTitle: effectiveTitle,
                    alternativeTitle: originalTitle,
                    episode: selectedEpisode,
                    onTap: {
                        viewModel.selectedResult = searchResult
                        viewModel.showingPlayAlert = true
                    }, highQualityThreshold: viewModel.highQualityThreshold
                )
            }
        }
    }
    
    private var actionVerb: String { downloadMode ? "Download" : "Play" }
    
    @ViewBuilder
    private var playAlertButtons: some View {
        Button(actionVerb) {
            viewModel.showingPlayAlert = false
            if let result = viewModel.selectedResult {
                Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    await playContent(result)
                }
            }
        }
        Button("Cancel", role: .cancel) {
            viewModel.selectedResult = nil
        }
    }
    
    @ViewBuilder
    private var playAlertMessage: some View {
        if let result = viewModel.selectedResult, let episode = selectedEpisode {
            Text("\(actionVerb) Episode \(episode.episodeNumber) of '\(result.title)'?")
        } else if let result = viewModel.selectedResult {
            Text("\(actionVerb) '\(result.title)'?")
        }
    }

    @ViewBuilder
    private var resolvedServiceStreamAlertButtons: some View {
        Button(actionVerb) {
            showingResolvedServiceStreamAlert = false
            guard let resolved = selectedResolvedServiceStream,
                  !filteredServiceStreamOptions([resolved.option], service: resolved.service).isEmpty else {
                selectedResolvedServiceStream = nil
                return
            }

            viewModel.pendingPlaybackAutoMode = false
            viewModel.pendingPlaybackRetryCount = 0
            resolveSubtitleSelection(
                subtitles: resolved.topLevelSubtitles,
                defaultSubtitle: resolved.option.subtitle,
                service: resolved.service,
                streamURL: resolved.option.url,
                headers: resolved.option.headers,
                structuredSubtitleTracks: resolved.option.subtitleTracks,
                streamName: resolved.option.name,
                streamLanguageHints: resolved.option.languageHints,
                streamMetadataHints: resolved.option.metadataHints,
                serviceHref: resolved.result.href
            )
            selectedResolvedServiceStream = nil
        }
        Button("Cancel", role: .cancel) {
            selectedResolvedServiceStream = nil
        }
    }

    @ViewBuilder
    private var resolvedServiceStreamAlertMessage: some View {
        if let resolved = selectedResolvedServiceStream {
            Text("\(actionVerb) '\(resolved.option.name)' from \(resolved.service.metadata.sourceName)?")
        }
    }
    
    @ViewBuilder
    private var streamFetchingOverlay: some View {
        if viewModel.isFetchingStreams {
            ZStack {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                
                VStack(spacing: 20) {
                    EclipseLoadingIndicator(tint: .white)
                        .scaleEffect(1.5)
                    
                    VStack(spacing: 8) {
                        Text("Fetching Streams")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                        
                        Text(viewModel.currentFetchingTitle)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        
                        if !viewModel.streamFetchProgress.isEmpty {
                            Text(viewModel.streamFetchProgress)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                .padding(30)
                .applyLiquidGlassBackground(cornerRadius: 16)
                .padding(.horizontal, 40)
            }
        }
    }
    
    @ViewBuilder
    private var qualityThresholdAlertContent: some View {
        TextField(stremioStyleSheetEnabled ? "Threshold (0.5 - 1.0)" : "Threshold (0.0 - 1.0)", value: $thresholdEditorValue, format: .number)
            .keyboardType(.decimalPad)
        
        Button("Save") {
            if stremioStyleSheetEnabled {
                storedServiceResultMinimumSimilarity = ServicesResultRankingSettings.clampedMinimumSimilarity(thresholdEditorValue)
            } else {
                viewModel.highQualityThreshold = max(0.0, min(1.0, thresholdEditorValue))
                UserDefaults.standard.set(viewModel.highQualityThreshold, forKey: "highQualityThreshold")
            }
        }
        
        Button("Cancel", role: .cancel) {}
    }
    
    @ViewBuilder
    private var qualityThresholdAlertMessage: some View {
        if stremioStyleSheetEnabled {
            Text("Set the ranking similarity used by Extra Source Settings to drop unmatched search results. Current: \(String(format: "%.2f", thresholdEditorValue)) (\(Int(thresholdEditorValue * 100))%)")
        } else {
            Text("Set the minimum similarity score (0.0 to 1.0) for results to be considered high quality. Current: \(String(format: "%.2f", thresholdEditorValue)) (\(Int(thresholdEditorValue * 100))%)")
        }
    }
    
    @ViewBuilder
    private var serverSelectionDialogContent: some View {
        let visibleOptions: [StreamOption] = {
            guard let service = viewModel.pendingService else { return [] }
            return filteredServiceStreamOptions(viewModel.streamOptions, service: service)
        }()

        ForEach(visibleOptions) { option in
            Button(option.name) {
                viewModel.showingStreamMenu = false
                if let service = viewModel.pendingService {
                    resolveSubtitleSelection(
                        subtitles: viewModel.pendingSubtitles,
                        defaultSubtitle: option.subtitle,
                        service: service,
                        streamURL: option.url,
                        headers: option.headers,
                        structuredSubtitleTracks: option.subtitleTracks,
                        streamName: option.name,
                        streamLanguageHints: option.languageHints,
                        streamMetadataHints: option.metadataHints,
                        serviceHref: viewModel.pendingServiceHref
                    )
                }
            }
        }
        Button("Cancel", role: .cancel) {
            cancelPendingAutoModeChoice("Auto Mode needs you to choose a stream option before it can continue.")
        }
    }
    
    @ViewBuilder
    private var serverSelectionDialogMessage: some View {
        Text("Choose a server to stream from")
    }
    
    @ViewBuilder
    private var seasonPickerDialogContent: some View {
        ForEach(Array(viewModel.availableSeasons.enumerated()), id: \.offset) { index, season in
            Button("Season \(index + 1) (\(season.count) episodes)") {
                viewModel.selectedSeasonIndex = index
                viewModel.pendingEpisodes = season
                viewModel.showingSeasonPicker = false
                viewModel.showingEpisodePicker = true
            }
        }
        Button("Cancel", role: .cancel) {
            cancelPendingAutoModeChoice("Auto Mode needs you to choose a season before it can continue.")
        }
    }
    
    @ViewBuilder
    private var seasonPickerDialogMessage: some View {
        Text("Season \(selectedEpisode?.seasonNumber ?? 1) not found. Please choose the correct season:")
    }
    
    @ViewBuilder
    private var episodePickerDialogContent: some View {
        ForEach(viewModel.pendingEpisodes, id: \.href) { episode in
            Button("Episode \(episode.number)") {
                proceedWithSelectedEpisode(episode)
            }
        }
        Button("Cancel", role: .cancel) {
            cancelPendingAutoModeChoice("Auto Mode needs you to choose an episode before it can continue.")
        }
    }
    
    @ViewBuilder
    private var episodePickerDialogMessage: some View {
        if let episode = selectedEpisode {
            Text("Choose the correct episode for S\(episode.seasonNumber)E\(episode.episodeNumber):")
        } else {
            Text("Choose an episode:")
        }
    }
    
    @ViewBuilder
    private var subtitlePickerDialogContent: some View {
        ForEach(viewModel.subtitleOptions, id: \.url) { option in
            Button(option.title) {
                viewModel.showingSubtitlePicker = false
                if let service = viewModel.pendingService,
                   let streamURL = viewModel.pendingStreamURL {
                    dispatchStreamAction(
                        streamURL,
                        service: service,
                        subtitle: option.url,
                        subtitleNames: [option.title],
                        subtitleHeadersByURL: viewModel.pendingSubtitleHeadersByURL,
                        headers: viewModel.pendingHeaders,
                        streamName: viewModel.pendingStreamName,
                        streamLanguageHints: viewModel.pendingStreamLanguageHints,
                        streamMetadataHints: viewModel.pendingStreamMetadataHints,
                        serviceHref: viewModel.pendingServiceHref
                    )
                }
            }
        }
        Button("No Subtitles") {
            viewModel.showingSubtitlePicker = false
            if let service = viewModel.pendingService,
               let streamURL = viewModel.pendingStreamURL {
                dispatchStreamAction(
                    streamURL,
                    service: service,
                    subtitle: nil,
                    headers: viewModel.pendingHeaders,
                    streamName: viewModel.pendingStreamName,
                    streamLanguageHints: viewModel.pendingStreamLanguageHints,
                    streamMetadataHints: viewModel.pendingStreamMetadataHints,
                    serviceHref: viewModel.pendingServiceHref
                )
            }
        }
        Button("Cancel", role: .cancel) {
            cancelPendingAutoModeChoice("Auto Mode needs you to choose a subtitle option before it can continue.")
        }
    }
    
    @ViewBuilder
    private var subtitlePickerDialogMessage: some View {
        Text("Choose a subtitle track")
    }
    
    private func filterResults(for results: [SearchItem]) -> (highQuality: [SearchItem], lowQuality: [SearchItem]) {
        let sortedResults = rankedServiceResults(results).prefix(Self.maxVisibleServiceResultsPerService)
        let visibleResults: [RankedSearchResult]
        if shouldDropMismatchedServiceResults {
            visibleResults = sortedResults.filter { $0.initialSimilarity >= serviceResultMinimumSimilarity }
        } else {
            visibleResults = Array(sortedResults)
        }
        let threshold = viewModel.highQualityThreshold
        let highQuality = visibleResults.filter { $0.initialSimilarity >= threshold }.map { $0.result }
        let lowQuality = visibleResults.filter { $0.initialSimilarity < threshold }.map { $0.result }
        
        return (highQuality, lowQuality)
    }

    private var isAutoModeEnabled: Bool {
        !ignoresAutoMode && (forceAutomaticPlayback
            || watchTogetherExactHandoff
            || UserDefaults.standard.bool(forKey: "servicesAutoModeEnabled"))
    }

    private var selectedAutoModeSourceIds: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "servicesAutoModeSourceIds") ?? [])
    }

    private func autoModeUnavailableMessage() -> String {
        let selectedActive = sortedResultItems.filter { selectedAutoModeSourceIds.contains($0.sourceId) }
        guard !selectedActive.isEmpty else {
            return "Auto Mode is enabled, but no active \(sourceKindSelectionList) is selected. Please select at least one source in Services settings."
        }

        if selectedActive.allSatisfy({ healthStore.shouldSkipForAutoMode(sourceId: $0.sourceId) }) {
            return "Auto Mode skipped every selected source because each has a recent unhealthy status. Choose a source manually or retry after checking source health."
        }

        return "Auto Mode could not find a playable result from the selected sources. Try again or choose a source manually."
    }

    private func autoModeSourceId(for item: ResultItem) -> String {
        item.sourceId
    }

    private struct RankedSearchResult {
        let index: Int
        let result: SearchItem
        let initialSimilarity: Double
        let titleSimilarity: Double
        let animeSeasonPreference: Int
        let tieBreakScore: Int
    }

    private func rankedServiceResults(_ results: [SearchItem]) -> [RankedSearchResult] {
        results.enumerated().map { index, result in
            RankedSearchResult(
                index: index,
                result: result,
                initialSimilarity: resultSimilarity(result),
                titleSimilarity: titleRankingScore(result),
                animeSeasonPreference: animeSeasonPreferenceScore(result),
                tieBreakScore: resultTieBreakScore(result)
            )
        }
        .sorted { lhs, rhs in
            let lhsEligible = lhs.initialSimilarity >= serviceResultMinimumSimilarity
            let rhsEligible = rhs.initialSimilarity >= serviceResultMinimumSimilarity

            if lhsEligible != rhsEligible {
                return lhsEligible && !rhsEligible
            }

            if lhsEligible && rhsEligible,
               lhs.animeSeasonPreference != rhs.animeSeasonPreference {
                return lhs.animeSeasonPreference > rhs.animeSeasonPreference
            }

            if lhsEligible && rhsEligible,
               !scoresAreEquivalent(lhs.titleSimilarity, rhs.titleSimilarity) {
                return lhs.titleSimilarity > rhs.titleSimilarity
            }

            if !scoresAreEquivalent(lhs.initialSimilarity, rhs.initialSimilarity) {
                return lhs.initialSimilarity > rhs.initialSimilarity
            }

            if lhs.tieBreakScore != rhs.tieBreakScore {
                return lhs.tieBreakScore > rhs.tieBreakScore
            }

            return lhs.index < rhs.index
        }
    }

    private func scoresAreEquivalent(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.0001
    }

    private func normalizeTitle(_ title: String) -> String {
        title
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sheetTitleBaseForMatching: String {
        stripEpisodeSuffix(from: displayTitle)
    }

    private func stripEpisodeSuffix(from title: String) -> String {
        let patterns = [
            #"(?i)\s*-\s*S\d{1,3}E\d{1,4}$"#,
            #"(?i)\s*S\d{1,3}E\d{1,4}$"#,
            #"(?i)\s*-\s*E\d{1,4}$"#,
            #"(?i)\s*E\d{1,4}$"#,
            #"(?i)\s*episode\s+\d{1,4}$"#
        ]

        var stripped = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in patterns {
            if let range = stripped.range(of: pattern, options: .regularExpression) {
                stripped.removeSubrange(range)
                break
            }
        }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func titleMatchCandidates() -> [String] {
        var seen = Set<String>()
        var candidates: [String?] = [
            sheetTitleBaseForMatching,
            effectiveTitle,
            mediaTitle,
            normalizedAnimeSequelTitle
        ]
        if !isForcedWatchTogetherAnimePlayback {
            candidates.append(strippedAnimeFallbackTitle)
            candidates.append(originalTitle)
        }
        return candidates
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .filter { seen.insert(normalizeTitle($0)).inserted }
    }

    private func titleRankingCandidates() -> [String] {
        var seen = Set<String>()
        var candidates = [
            sheetTitleBaseForMatching,
            effectiveTitle,
            mediaTitle,
            normalizedAnimeSequelTitle
        ]

        if !isForcedWatchTogetherAnimePlayback {
            candidates.append(strippedAnimeFallbackTitle)
        }

        if !(isAnimeContent || animeSeasonTitle != nil),
           !isForcedWatchTogetherAnimePlayback {
            candidates.append(originalTitle)
        }

        return candidates.compactMap { raw in
            guard let raw else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let key = normalizeTitleForRanking(value)
            guard seen.insert(key).inserted else { return nil }
            return value
        }
    }

    private func titleRankingScore(_ result: SearchItem) -> Double {
        rankingCandidates(for: result)
            .map { titleSimilarityForRanking(expected: $0, result: result.title) }
            .max() ?? resultSimilarity(result)
    }

    private func rankingCandidates(for result: SearchItem) -> [String] {
        guard isAnimeContent || animeSeasonTitle != nil,
              let alternate = originalTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !alternate.isEmpty,
              serviceResultLooksLikeAlternateTitle(result, alternateTitle: alternate) else {
            return titleRankingCandidates()
        }

        return [alternate]
    }

    private func serviceResultLooksLikeAlternateTitle(_ result: SearchItem, alternateTitle: String) -> Bool {
        let displayScore = titleSimilarityForRanking(expected: sheetTitleBaseForMatching, result: result.title)
        let alternateScore = titleSimilarityForRanking(expected: alternateTitle, result: result.title)
        return alternateScore >= 0.82 && alternateScore > displayScore + 0.06
    }

    private func forcedWatchTogetherAnimeResultMatchesDestination(
        _ result: SearchItem
    ) -> Bool {
        guard isForcedWatchTogetherAnimePlayback else { return true }
        let resultKey = exactWatchTogetherAnimeTitleKey(result.title)
        guard !resultKey.isEmpty else { return false }
        let targetKeys = [
            seasonTitleOverride,
            Optional(effectiveTitle),
            Optional(mediaTitle),
            normalizedAnimeSequelTitle
        ]
        .compactMap { $0 }
        .map(exactWatchTogetherAnimeTitleKey)
        .filter { !$0.isEmpty }

        // Only known technical suffixes are ignored. Arbitrary prefix matching is unsafe for
        // anime because sequel/cour titles often begin with the base title, and punctuation can
        // itself distinguish entries (for example Gintama variants).
        return targetKeys.contains(resultKey)
    }

    private func exactWatchTogetherAnimeTitleKey(_ rawTitle: String) -> String {
        func collapsedWhitespace(_ value: String) -> String {
            value
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var value = collapsedWhitespace(
            rawTitle
                .lowercased()
                .replacingOccurrences(of: "’", with: "'")
                .replacingOccurrences(of: "‘", with: "'")
                .replacingOccurrences(of: "–", with: "-")
                .replacingOccurrences(of: "—", with: "-")
        )
        let technicalSuffixes = [
            " (english dub)", " [english dub]", " - english dub", " english dub",
            " (english sub)", " [english sub]", " - english sub", " english sub",
            " (dual audio)", " [dual audio]", " - dual audio", " dual audio",
            " (multi audio)", " [multi audio]", " - multi audio", " multi audio",
            " (uncensored)", " [uncensored]", " - uncensored", " uncensored",
            " (remastered)", " [remastered]", " - remastered", " remastered",
            " (dubbed)", " [dubbed]", " - dubbed", " dubbed",
            " (subbed)", " [subbed]", " - subbed", " subbed",
            " (dub)", " [dub]", " - dub", " dub",
            " (sub)", " [sub]", " - sub", " sub",
            " (1080p)", " [1080p]", " - 1080p", " 1080p",
            " (720p)", " [720p]", " - 720p", " 720p",
            " (4k)", " [4k]", " - 4k", " 4k",
            " (hd)", " [hd]", " - hd", " hd"
        ]
        var removedSuffix = true
        while removedSuffix {
            removedSuffix = false
            for suffix in technicalSuffixes where value.hasSuffix(suffix) {
                value.removeLast(suffix.count)
                value = collapsedWhitespace(value)
                removedSuffix = true
                break
            }
        }
        return collapsedWhitespace(stripEpisodeSuffix(from: value))
    }

    private func titleSimilarityForRanking(expected: String, result: String) -> Double {
        let expectedCanonical = normalizeTitleForRanking(expected)
        let resultCanonical = normalizeTitleForRanking(result)

        let rawSimilarity = algorithmManager.calculateSimilarity(original: expected, result: result)
        let canonicalSimilarity = algorithmManager.calculateSimilarity(original: expectedCanonical, result: resultCanonical)
        let tokenScore = tokenOverlapScore(expectedCanonical, resultCanonical)

        var score = max(rawSimilarity, canonicalSimilarity) * 0.70 + tokenScore * 0.30

        if !expectedCanonical.isEmpty {
            if resultCanonical == expectedCanonical {
                score += 0.15
            } else if resultCanonical.contains(expectedCanonical) || expectedCanonical.contains(resultCanonical) {
                score += 0.08
            }
        }

        return max(0, score)
    }

    private func normalizeTitleForRanking(_ title: String) -> String {
        title
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func tokenOverlapScore(_ lhs: String, _ rhs: String) -> Double {
        let ignored: Set<String> = ["a", "an", "and", "the", "of", "to", "in", "on", "tv", "series", "episode"]
        let lhsTokens = Set(lhs.split(separator: " ").map(String.init).filter { $0.count > 1 && !ignored.contains($0) })
        let rhsTokens = Set(rhs.split(separator: " ").map(String.init).filter { $0.count > 1 && !ignored.contains($0) })

        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return 0 }
        let shared = lhsTokens.intersection(rhsTokens).count
        return Double(shared) / Double(max(lhsTokens.count, rhsTokens.count))
    }

    private func resultSimilarity(_ result: SearchItem) -> Double {
        titleMatchCandidates()
            .map { algorithmManager.calculateSimilarity(original: $0, result: result.title) }
            .max() ?? 0.0
    }

    private enum AnimeSeasonPreferenceMarker: Hashable {
        case season(Int)
        case part(Int)
    }

    private func animeSeasonPreferenceScore(_ result: SearchItem) -> Int {
        guard isAnimeContent || animeSeasonTitle != nil,
              let seasonNumber = selectedEpisode?.seasonNumber,
              seasonNumber > 1 else {
            return 0
        }

        let expectedTitle = stripEpisodeSuffix(from: effectiveTitle)
        let expectedMarkers = animeSeasonPreferenceMarkers(
            in: expectedTitle,
            terminalSeasonNumber: seasonNumber
        )
        guard !expectedMarkers.isEmpty else { return 0 }

        let resultTitle = stripEpisodeSuffix(from: result.title)
        return expectedMarkers.allSatisfy { animeResultTitle(resultTitle, matches: $0) } ? 1 : 0
    }

    private func animeSeasonPreferenceMarkers(
        in title: String,
        terminalSeasonNumber: Int? = nil
    ) -> Set<AnimeSeasonPreferenceMarker> {
        let normalized = normalizeTitle(title)
        let tokens = normalized.split(separator: " ").map(String.init)
        var markers = Set<AnimeSeasonPreferenceMarker>()

        for (index, token) in tokens.enumerated() {
            let nextToken = index + 1 < tokens.count ? tokens[index + 1] : nil

            if token == "season", let nextToken, let number = Int(nextToken) {
                markers.insert(.season(number))
            } else if let number = markerNumber(after: "season", in: token) {
                markers.insert(.season(number))
            }

            if token == "part", let nextToken, let number = Int(nextToken) {
                markers.insert(.part(number))
            } else if let number = markerNumber(after: "part", in: token) {
                markers.insert(.part(number))
            }

            if nextToken == "season", let number = ordinalNumber(from: token) {
                markers.insert(.season(number))
            }
        }

        if markers.isEmpty,
           let terminalSeasonNumber,
           titleContainsTerminalAnimeSeasonNumber(normalized, seasonNumber: terminalSeasonNumber) {
            markers.insert(.season(terminalSeasonNumber))
        }

        return markers
    }

    private func animeResultTitle(_ title: String, matches marker: AnimeSeasonPreferenceMarker) -> Bool {
        let explicitMarkers = animeSeasonPreferenceMarkers(in: title)
        if explicitMarkers.contains(marker) {
            return true
        }

        guard explicitMarkers.isEmpty,
              case let .season(seasonNumber) = marker else {
            return false
        }

        return titleContainsTerminalAnimeSeasonNumber(title, seasonNumber: seasonNumber)
    }

    private func titleContainsTerminalAnimeSeasonNumber(_ title: String, seasonNumber: Int) -> Bool {
        let patterns = [
            "[a-z]\(seasonNumber)$",
            "\\b\(seasonNumber)$"
        ]
        return patterns.contains { title.range(of: $0, options: .regularExpression) != nil }
    }

    private func markerNumber(after prefix: String, in token: String) -> Int? {
        guard token.hasPrefix(prefix) else { return nil }
        let suffix = token.dropFirst(prefix.count)
        return suffix.isEmpty ? nil : Int(suffix)
    }

    private func ordinalNumber(from token: String) -> Int? {
        for suffix in ["st", "nd", "rd", "th"] where token.hasSuffix(suffix) {
            return Int(token.dropLast(suffix.count))
        }
        return nil
    }

    private func resultTieBreakScore(_ result: SearchItem) -> Int {
        let normalizedResult = normalizeTitle(result.title)
        let expectedTitles = titleMatchCandidates()
            .map(normalizeTitle)
            .filter { !$0.isEmpty }

        var score = 0
        for candidate in expectedTitles {
            if normalizedResult == candidate {
                score += 10
            } else if normalizedResult.contains(candidate) || candidate.contains(normalizedResult) {
                score += 4
            }
        }

        if let episode = selectedEpisode {
            let seasonEpisodeToken = "s\(episode.seasonNumber)e\(episode.episodeNumber)"
            let episodeToken = "e\(episode.episodeNumber)"
            if normalizedResult.contains(seasonEpisodeToken) || normalizedResult.contains(episodeToken) {
                score += 3
            }
        }

        if !sheetTitleBaseForMatching.isEmpty {
            let sheetScore = algorithmManager.calculateSimilarity(original: sheetTitleBaseForMatching, result: result.title)
            score += Int(sheetScore * 10)
        }

        return score
    }

    private func bestServiceResult(for service: Service) -> SearchItem? {
        guard let results = viewModel.moduleResults[service.id], !results.isEmpty else { return nil }
        let ranked = rankedServiceResults(results)
        let best: RankedSearchResult?
        if isForcedWatchTogetherAnimePlayback {
            best = ranked.first { forcedWatchTogetherAnimeResultMatchesDestination($0.result) }
        } else {
            best = ranked.first
        }
        guard let best else { return nil }
        guard shouldDropMismatchedServiceResults else { return best.result }
        return best.initialSimilarity >= serviceResultMinimumSimilarity ? best.result : nil
    }

    private func retainedServiceResults(_ results: [SearchItem]) -> [SearchItem] {
        guard results.count > Self.maxRetainedServiceResultsPerService else {
            return results
        }

        return rankedServiceResults(results)
            .prefix(Self.maxRetainedServiceResultsPerService)
            .map { $0.result }
    }

    private func mergedServiceResults(existing: [SearchItem], additional: [SearchItem]) -> [SearchItem] {
        guard !additional.isEmpty else {
            return retainedServiceResults(existing)
        }

        var seenHrefs = Set(existing.map { $0.href })
        let newResults = additional.filter { seenHrefs.insert($0.href).inserted }
        return retainedServiceResults(existing + newResults)
    }

    private func bestStreamOption(from options: [StreamOption]) -> StreamOption? {
        let preference = AutoModeQualityPreference.current
        guard preference.usesAutomaticSelection else {
            return nil
        }
        let rankedOptions = options.enumerated().map { index, option in
            let info = AutoModeStreamSelection.streamQualityInfo(from: option.qualitySearchLabel)
            return (
                index: index,
                option: option,
                hasDetectedQuality: info.resolutionHeight != nil,
                score: AutoModeStreamSelection.streamPreferenceScore(
                    info: info,
                    preference: preference,
                    index: index
                )
            )
        }
        guard rankedOptions.contains(where: { $0.hasDetectedQuality }) else {
            return nil
        }
        return rankedOptions.max { lhs, rhs in lhs.score < rhs.score }?.option
    }

    private func bestStremioStream(from streams: [StremioStream], addon: StremioAddon) -> StremioStream? {
        AutoModeStreamSelection.bestStremioStream(
            from: filteredStremioStreams(streams, addon: addon),
            sourceId: SourceHealth.stremioId(addon),
            streamsAreFiltered: true,
            isAnime: hasAnimeLookupContext,
            originalAudioLanguage: originalAudioLanguage
        )
    }

    private func filteredStremioStreams(_ streams: [StremioStream], addon: StremioAddon) -> [StremioStream] {
        let sourceId = SourceHealth.stremioId(addon)
        guard let configuration = StreamLanguageFilter.configuration(sourceId: sourceId) else {
            return Array(streams.prefix(Self.maxRetainedStremioStreamsPerAddon))
        }
        return Array(
            streams.lazy
                .filter {
                    !StreamLanguageFilter.shouldHide(
                        stremio: $0,
                        configuration: configuration,
                        originalAudioLanguage: originalAudioLanguage,
                        isAnime: hasAnimeLookupContext
                    )
                }
                .prefix(Self.maxRetainedStremioStreamsPerAddon)
        )
    }

    /// Re-evaluate stored results at the presentation boundary so changing
    /// Extra Source Settings cannot leave an already-loaded forbidden stream
    /// visible in either sheet layout.
    private func visibleStremioStreams(for addon: StremioAddon) -> [StremioStream] {
        guard let streams = viewModel.stremioResults[addon.id] else { return [] }
        return filteredStremioStreams(streams, addon: addon)
    }

    private func filteredServiceStreamOptions(_ options: [StreamOption], service: Service) -> [StreamOption] {
        let sourceId = SourceHealth.serviceId(service)
        guard let configuration = StreamLanguageFilter.configuration(sourceId: sourceId) else {
            return options
        }
        return options.filter { option in
            serviceStreamOptionIsVisible(option, configuration: configuration)
        }
    }

    private func serviceStreamOptionIsVisible(
        _ option: StreamOption,
        configuration: StreamLanguageFilter.Configuration?
    ) -> Bool {
        guard let configuration else { return true }
        return !StreamLanguageFilter.shouldHide(
            languageHints: option.languageHints,
            metadata: [option.name, option.url] + option.metadataHints,
            configuration: configuration,
            originalAudioLanguage: originalAudioLanguage,
            isAnime: hasAnimeLookupContext
        )
    }

#if os(iOS) && !targetEnvironment(macCatalyst)
    /// The sole SkyStream -> StreamOption conversion seam. Every URL/header on the resulting
    /// option comes from the validator-issued descriptor, never from the raw ABI record.
    private func validatedSkyStreamOption(
        from resolved: SkyStreamResolvedStream
    ) -> ValidatedSkyStreamOption {
        let descriptor = resolved.playback
        let subtitles = descriptor.subtitles.map { subtitle in
            ServiceSubtitleTrack(
                title: subtitle.label ?? subtitle.language ?? "Subtitle",
                url: subtitle.remoteURL.url.absoluteString,
                headers: subtitle.headers.values.isEmpty ? nil : subtitle.headers.values
            )
        }

        let languageHints = boundedSkyStreamMetadataValues(
            resolved.streamRecord.additionalFields,
            matching: ["audio", "language", "languages", "lang", "dub", "dubbed"]
        )
        var metadataHints = [
            resolved.streamRecord.source,
            resolved.streamRecord.name,
            resolved.streamRecord.qualityLabel,
            resolved.streamRecord.quality.map { "\($0)p" },
            resolved.streamRecord.mediaType,
            resolved.episodeRecord?.dubStatus?.rawValue,
            resolved.loadedItem.providerName
        ].compactMap { $0 }
        metadataHints.append(contentsOf: boundedSkyStreamMetadataValues(
            resolved.streamRecord.additionalFields,
            matching: ["server", "codec", "audio", "quality", "resolution", "language", "lang"]
        ))

        let option = StreamOption(
            name: resolved.displayName,
            url: descriptor.underlyingRemoteURL.url.absoluteString,
            headers: descriptor.headers.values.isEmpty ? nil : descriptor.headers.values,
            subtitle: subtitles.first?.url,
            subtitleTracks: subtitles,
            languageHints: languageHints,
            metadataHints: Array(metadataHints.prefix(32))
        )
        return ValidatedSkyStreamOption(resolved: resolved, option: option)
    }

    private func boundedSkyStreamMetadataValues(
        _ values: [String: SkyStreamJSONValue],
        matching allowedKeys: Set<String>
    ) -> [String] {
        var result: [String] = []
        for key in values.keys.sorted() where allowedKeys.contains(key.lowercased()) {
            guard let value = values[key] else { continue }
            switch value {
            case .string(let string):
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed.utf8.count <= 256 { result.append(trimmed) }
            case .array(let entries):
                for entry in entries.prefix(8) {
                    guard case .string(let string) = entry else { continue }
                    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, trimmed.utf8.count <= 128 { result.append(trimmed) }
                }
            case .null, .boolean, .integer, .number, .object:
                break
            }
            if result.count >= 16 { break }
        }
        return Array(result.prefix(16))
    }

    private func visibleSkyStreamOptions(
        for provider: SkyStreamProviderDescriptor
    ) -> [ValidatedSkyStreamOption] {
        var retained = Array(
            (skyStreamResults[provider.id] ?? [])
                .filter { skyStreamResultIsCurrent($0, provider: provider) }
                .prefix(Self.maxRetainedSkyStreamOptionsPerProvider)
        )
        if downloadMode {
            retained = retained.filter(isSkyStreamDownloadCompatible)
        }
        guard let configuration = StreamLanguageFilter.configuration(sourceId: provider.id) else {
            return Array(retained.prefix(Self.maxVisibleSkyStreamOptionsPerProvider))
        }
        return Array(retained.lazy.filter {
            serviceStreamOptionIsVisible($0.option, configuration: configuration)
        }.prefix(Self.maxVisibleSkyStreamOptionsPerProvider))
    }

    /// Results can remain in SwiftUI state for a run-loop turn while another window updates or
    /// disables a package. Bind every row back to the currently installed payload/domain before
    /// it can be shown, downloaded, or translated into a proxy session.
    private func skyStreamResultIsCurrent(
        _ stream: ValidatedSkyStreamOption,
        provider: SkyStreamProviderDescriptor
    ) -> Bool {
        let reference = stream.resolved.contentReference
        guard reference.isStructurallyValid,
              reference.sourceID == provider.id,
              stream.resolved.provider.id == provider.id,
              let currentAuthority = skyStreamManager.runtimeAuthoritySnapshot(
                  sourceID: provider.id
              ),
              currentAuthority.revision == stream.resolved.playback.identity.authorityRevision,
              currentAuthority.provider.isEnabled,
              currentAuthority.provider.packageName == stream.resolved.provider.packageName,
              currentAuthority.provider.providerID == stream.resolved.provider.providerID,
              currentAuthority.provider.selectedDomainURL
                == stream.resolved.provider.selectedDomainURL,
              currentAuthority.plugin.id == reference.packageName,
              let expectedScriptHash = reference.scriptSHA256,
              expectedScriptHash.caseInsensitiveCompare(
                  currentAuthority.plugin.scriptSHA256
              ) == .orderedSame,
              reference.pluginVersion == currentAuthority.plugin.manifest.version else {
            return false
        }
        return stream.resolved.playback.identity.packageID == reference.packageName
            && stream.resolved.playback.identity.providerID == (reference.providerID ?? "root")
            && stream.resolved.playback.identity.payloadSHA256
                .caseInsensitiveCompare(expectedScriptHash) == .orderedSame
    }

    private func bestSkyStreamOption(
        from options: [ValidatedSkyStreamOption]
    ) -> ValidatedSkyStreamOption? {
        guard !options.isEmpty else { return nil }
        if options.count == 1 { return options[0] }
        guard let best = bestStreamOption(from: options.map(\.option)) else { return nil }
        return options.first { $0.option.id == best.id }
    }

    private func isSkyStreamDownloadCompatible(_ stream: ValidatedSkyStreamOption) -> Bool {
        let descriptor = stream.resolved.playback
        let transportIsSupported: Bool
        switch descriptor.mediaKind {
        case .direct:
            transportIsSupported = descriptor.proxyOptions == nil
                && descriptor.acceptedManifests.isEmpty
                && (descriptor.finiteContentLength ?? 0) > 0
        case .hls:
            transportIsSupported = DownloadManager.skyStreamHLSRejectionReason(descriptor) == nil
        case .dash:
            transportIsSupported = false
        }
        return transportIsSupported
            && stream.resolved.contentReference.isStructurallyValid
            && stream.resolved.contentReference.sourceID == stream.resolved.provider.id
    }
#endif

    @MainActor
    private func selectStremioStyleResolvedServiceStream(_ resolved: StremioStyleResolvedServiceStream) {
        guard Date().timeIntervalSince(resolved.resolvedAt) <= Self.resolvedServiceStreamFreshness else {
            let key = stremioStyleServiceResolutionKey(service: resolved.service, result: resolved.result)
            stremioStyleServiceResolutionStates[key] = .queued
            startNextStremioStyleServiceResolutions()
            return
        }

        selectedResolvedServiceStream = resolved
        showingResolvedServiceStreamAlert = true
    }

    private func stremioStyleServiceAttentionActionTitle(hasVerification: Bool) -> String {
#if os(tvOS)
        return "Retry check"
#else
        return hasVerification ? "Verify and retry" : "Retry check"
#endif
    }

    @MainActor
    private func handleStremioStyleServiceResolutionAttention(
        service: Service,
        verificationURL: URL?
    ) {
#if !os(tvOS)
        if let verificationURL {
            Task { @MainActor in
                do {
                    try await CloudflareBypassManager.shared.triggerBypass(for: verificationURL)
                    guard isSheetActive else { return }
                    retryFailedStremioStyleServiceResolutions(for: service)
                } catch {
                    Logger.shared.log(
                        "Stremio-style stream verification did not complete source=\(service.metadata.sourceName) error=\(error.localizedDescription)",
                        type: "Service"
                    )
                }
            }
            return
        }
#endif
        retryFailedStremioStyleServiceResolutions(for: service)
    }

    @MainActor
    private func retryFailedStremioStyleServiceResolutions(for service: Service) {
        for result in stremioStyleServiceCandidates(for: service) {
            let key = stremioStyleServiceResolutionKey(service: service, result: result)
            switch stremioStyleServiceResolutionStates[key] {
            case .failed, .verificationRequired:
                stremioStyleServiceResolutionStates[key] = .queued
            case .queued, .checking, .resolved, .none:
                break
            }
        }
        startNextStremioStyleServiceResolutions()
    }

    /// The bypass manager's pending URL is process-wide. Only associate it with a background
    /// probe when its host matches that Service's known page/base hosts; otherwise another
    /// concurrent source may have raised it and this candidate remains a generic retryable failure.
    @MainActor
    private func matchingPendingCloudflareURL(
        requestURLStrings: [String],
        service: Service
    ) -> URL? {
        guard let pendingURL = CloudflareBypassManager.shared.pendingVerificationURL,
              let pendingHost = pendingURL.host?.lowercased() else {
            return nil
        }

        let expectedHosts = Set((requestURLStrings + [service.metadata.baseUrl]).compactMap {
            URL(string: $0)?.host?.lowercased()
        })
        return expectedHosts.contains(pendingHost) ? pendingURL : nil
    }

    @MainActor
    private func resetStremioStyleServiceResolution() {
        // Advance the generation before cancelling contexts so timeout/Promise callbacks from the
        // old request can never publish into the replacement sheet state.
        stremioStyleServiceResolutionGeneration = UUID()
        let work = Array(stremioStyleServiceResolutionWork.values)
        stremioStyleServiceResolutionWork.removeAll()
        stremioStyleServiceResolutionStates.removeAll()
        selectedResolvedServiceStream = nil
        showingResolvedServiceStreamAlert = false
        work.forEach { $0.cancel() }
    }

    @MainActor
    private func beginNewManualSearchGeneration() {
        manualSearchGeneration = UUID()
#if os(iOS) && !targetEnvironment(macCatalyst)
        skyStreamSearchTask?.cancel()
        skyStreamSearchTask = nil
        skyStreamSearchingSourceIds.removeAll()
        selectedSkyStreamOption = nil
        selectedSkyStreamProvider = nil
        skyStreamPickerOptions = []
        showingSkyStreamPlayAlert = false
        showingSkyStreamPicker = false
#endif
    }

    @MainActor
    private func isCurrentManualSearchGeneration(_ generation: UUID) -> Bool {
        isSheetActive && generation == manualSearchGeneration
    }

    @MainActor
    private func scheduleStremioStyleServiceResolution() {
        guard isSheetActive,
              stremioStyleSheetEnabled,
              !(autoModeOnly && !showManualPicker) else {
            resetStremioStyleServiceResolution()
            return
        }

        let candidates = allStremioStyleServiceResolutionCandidates()
        let validKeys = Set(candidates.map {
            stremioStyleServiceResolutionKey(service: $0.service, result: $0.result)
        })

        let obsoleteWork = stremioStyleServiceResolutionWork.filter { !validKeys.contains($0.value.key) }
        for (serviceID, work) in obsoleteWork {
            stremioStyleServiceResolutionWork.removeValue(forKey: serviceID)
            work.cancel()
        }
        stremioStyleServiceResolutionStates = stremioStyleServiceResolutionStates.filter {
            validKeys.contains($0.key)
        }

        for candidate in candidates {
            let key = stremioStyleServiceResolutionKey(service: candidate.service, result: candidate.result)
            if stremioStyleServiceResolutionStates[key] == nil {
                stremioStyleServiceResolutionStates[key] = .queued
            }
        }

        startNextStremioStyleServiceResolutions()
    }

    @MainActor
    private func startNextStremioStyleServiceResolutions() {
        guard isSheetActive, stremioStyleSheetEnabled else { return }

        while stremioStyleServiceResolutionWork.count < Self.maxConcurrentStremioStyleServiceResolutions {
            guard let candidate = allStremioStyleServiceResolutionCandidates().first(where: { candidate in
                let key = stremioStyleServiceResolutionKey(service: candidate.service, result: candidate.result)
                guard case .queued = stremioStyleServiceResolutionStates[key] else { return false }
                return stremioStyleServiceResolutionWork[candidate.service.id] == nil
            }) else {
                return
            }
            beginStremioStyleServiceResolution(service: candidate.service, result: candidate.result)
        }
    }

    @MainActor
    private func beginStremioStyleServiceResolution(service: Service, result: SearchItem) {
        let generation = stremioStyleServiceResolutionGeneration
        let key = stremioStyleServiceResolutionKey(service: service, result: result)
        guard case .queued = stremioStyleServiceResolutionStates[key],
              stremioStyleServiceResolutionWork[service.id] == nil else {
            return
        }

        let work = StremioStyleServiceResolutionWork(key: key, service: service)
        stremioStyleServiceResolutionStates[key] = .checking
        stremioStyleServiceResolutionWork[service.id] = work

        work.controller.fetchEpisodesJS(url: result.href, module: service) { episodes in
            Task { @MainActor in
                guard isCurrentStremioStyleServiceResolution(
                    work,
                    generation: generation,
                    service: service,
                    result: result
                ) else { return }

                guard let targetHref = stremioStyleTargetStreamHref(episodes: episodes, result: result) else {
                    let failureState: StremioStyleServiceResolutionState
                    if let verificationURL = matchingPendingCloudflareURL(
                        requestURLStrings: [result.href],
                        service: service
                    ) {
                        failureState = .verificationRequired(verificationURL)
                    } else {
                        failureState = .failed
                    }
                    finishStremioStyleServiceResolution(
                        work,
                        generation: generation,
                        service: service,
                        state: failureState
                    )
                    return
                }

                let softsub = service.metadata.softsub ?? false
                work.streamRequest = work.controller.fetchStreamUrlJS(
                    episodeUrl: targetHref,
                    softsub: softsub,
                    module: service,
                    timeoutNanoseconds: 8_000_000_000
                ) { streamResult in
                    Task { @MainActor in
                        guard isCurrentStremioStyleServiceResolution(
                            work,
                            generation: generation,
                            service: service,
                            result: result
                        ) else { return }

                        let parsed = parseStreamOptions(
                            streams: streamResult.streams,
                            sources: streamResult.sources
                        )
                        guard !parsed.isEmpty else {
                            let failureState: StremioStyleServiceResolutionState
                            if let verificationURL = matchingPendingCloudflareURL(
                                requestURLStrings: [result.href, targetHref],
                                service: service
                            ) {
                                failureState = .verificationRequired(verificationURL)
                            } else {
                                failureState = .failed
                            }
                            finishStremioStyleServiceResolution(
                                work,
                                generation: generation,
                                service: service,
                                state: failureState
                            )
                            return
                        }

                        let allowed = filteredServiceStreamOptions(parsed, service: service)
                        let resolvedAt = Date()
                        let resolved = allowed.prefix(Self.maxVisibleServiceResultsPerService).map { option in
                            StremioStyleResolvedServiceStream(
                                service: service,
                                result: result,
                                option: option,
                                topLevelSubtitles: streamResult.subtitles,
                                resolvedAt: resolvedAt
                            )
                        }
                        if resolved.isEmpty {
                            Logger.shared.log(
                                "Stremio-style sheet hid all \(parsed.count) resolved streams from \(service.metadata.sourceName) before presentation",
                                type: "Stream"
                            )
                        }
                        finishStremioStyleServiceResolution(
                            work,
                            generation: generation,
                            service: service,
                            state: .resolved(resolved)
                        )
                    }
                }
            }
        }
    }

    @MainActor
    private func isCurrentStremioStyleServiceResolution(
        _ work: StremioStyleServiceResolutionWork,
        generation: UUID,
        service: Service,
        result: SearchItem
    ) -> Bool {
        guard isSheetActive,
              stremioStyleSheetEnabled,
              generation == stremioStyleServiceResolutionGeneration,
              let currentWork = stremioStyleServiceResolutionWork[service.id],
              currentWork.id == work.id,
              currentWork.key == work.key,
              stremioStyleServiceNeedsResolvedStreams(service) else {
            return false
        }
        return viewModel.moduleResults[service.id]?.contains(where: { $0.href == result.href }) == true
    }

    @MainActor
    private func finishStremioStyleServiceResolution(
        _ work: StremioStyleServiceResolutionWork,
        generation: UUID,
        service: Service,
        state: StremioStyleServiceResolutionState
    ) {
        guard generation == stremioStyleServiceResolutionGeneration,
              stremioStyleServiceResolutionWork[service.id]?.id == work.id else {
            return
        }
        stremioStyleServiceResolutionStates[work.key] = state
        stremioStyleServiceResolutionWork.removeValue(forKey: service.id)
        work.streamRequest = nil
        startNextStremioStyleServiceResolutions()
    }

    private func stremioStyleTargetStreamHref(episodes: [EpisodeLink], result: SearchItem) -> String? {
        guard !episodes.isEmpty else { return nil }
        if isMovie {
            let firstHref = episodes.first?.href.trimmingCharacters(in: .whitespacesAndNewlines)
            return firstHref?.isEmpty == false ? firstHref : result.href
        }

        guard let selectedEpisode else { return nil }
        let seasons = parseSeasons(from: episodes)
        return findEpisodeHref(
            seasons: seasons,
            seasonIndex: selectedEpisode.seasonNumber - 1,
            episodeNumber: selectedEpisode.episodeNumber,
            bundledEpisodeNumbers: bundledEpisodeNumberCandidates(for: selectedEpisode),
            allowAutomaticEpisodeResolution: standaloneAutoSelectEpisodesEnabled
        )
    }

    @MainActor
    private func maybeRunAutoModeSelection() {
        guard !autoModeOnly,
              isAutoModeEnabled,
              !autoModeDidRun,
              !viewModel.isSearching,
              !viewModel.isSearchingStremio,
              !isSearchingSkyStream else { return }

        autoModeDidRun = true
        Task { @MainActor in
            await runAutoModeSelection()
        }
    }

    @MainActor
    private func runAutoModeSelection() async {
        let orderedSelections = activeAutoModeItems

        guard !orderedSelections.isEmpty else {
            viewModel.streamError = autoModeUnavailableMessage()
            viewModel.showingStreamError = true
            return
        }

        for item in orderedSelections {
            switch item {
            case .service(let service):
                if let result = bestServiceResult(for: service) {
                    await playContent(result, autoModeLaunch: true)
                    return
                }
            case .stremio(let addon):
                if let stream = bestStremioStream(from: viewModel.stremioResults[addon.id] ?? [], addon: addon) {
                    playStremioStream(stream, addon: addon, autoModeLaunch: true)
                    return
                }
#if os(iOS) && !targetEnvironment(macCatalyst)
            case .skyStream(let provider):
                let streams = visibleSkyStreamOptions(for: provider)
                if let stream = bestSkyStreamOption(from: streams) {
                    playSkyStream(stream, provider: provider, autoModeLaunch: true)
                    return
                }
                if streams.count == 1, let stream = streams.first {
                    // "Ask" only needs a picker when there is an actual choice. Match the
                    // existing Service/Stremio behavior for a sole verified candidate.
                    playSkyStream(stream, provider: provider, autoModeLaunch: true)
                    return
                }
                if streams.count > 1 {
                    selectedSkyStreamProvider = provider
                    skyStreamPickerOptions = streams
                    viewModel.pendingPlaybackAutoMode = true
                    showingSkyStreamPicker = true
                    return
                }
#endif
            }
        }

        viewModel.streamError = "Auto Mode could not find a playable match in the selected sources. Try selecting more \(sourceKindList)."
        viewModel.showingStreamError = true
    }

    private var requestToken: String {
        [
            downloadMode ? "download" : "play",
            AutoModeMediaTargetToken.make(
                tmdbID: tmdbId,
                isMovie: isMovie,
                episode: selectedEpisode,
                playbackContext: effectivePlaybackContext
            ),
            normalizeTitleForRanking(playerMediaTitle),
            forceAutomaticPlayback ? "watch-together" : "local",
            watchTogetherExactHandoff ? "exact-handoff" : "normal-handoff"
        ].joined(separator: ":")
    }

    private var shouldDismissAutoModeSheetBeforePlayback: Bool {
        autoModeOnly && !showManualPicker
    }

    private var shouldForceAutoResolutionForDownload: Bool {
        downloadMode && autoModeOnly && !showManualPicker
    }

    private var shouldUseAutomaticResolution: Bool {
        viewModel.pendingPlaybackAutoMode || shouldForceAutoResolutionForDownload
    }

    private var standaloneAutoSelectEpisodesEnabled: Bool {
        UserDefaults.standard.bool(forKey: "servicesAutoSelectEpisodesEnabled")
    }

    private var shouldUseAutomaticEpisodeResolution: Bool {
        shouldUseAutomaticResolution || standaloneAutoSelectEpisodesEnabled
    }

    @MainActor
    private func deactivateSheetForDismissal() {
        isSheetActive = false
        beginNewManualSearchGeneration()
        resetStremioStyleServiceResolution()
        autoModeCancelled = true
        autoModeSelectionTask?.cancel()
        autoModeSelectionTask = nil
        cancelAutoModeDownloadValidation()
        serviceStreamExtractionGeneration = nil
        serviceStreamExtractionRequest?.cancel()
        serviceStreamExtractionRequest = nil
    }

    @MainActor
    private func dismissSheetWithoutPlaybackHandoff() {
        deactivateSheetForDismissal()
        presentationMode.wrappedValue.dismiss()
    }

    @MainActor
    private func finishResolvedPlayback(_ request: PlayerResolvedPlaybackRequest) {
        guard let onResolvedPlaybackRequest else {
            invalidateAbandonedSkyStreamProxy(
                request.url,
                launchContext: request.launchContext
            )
            return
        }

        // Resolution may finish after the user has manually dismissed the source sheet. In that
        // case the caller's short post-dismissal selection grace must not turn a cancelled picker
        // into a playback change. Authorize the handoff while this sheet is still active, before
        // we intentionally dismiss it below; the delayed callback must not re-check this state
        // because a normal selection and Watch Together Auto Mode both dismiss before delivery.
        guard isSheetActive else {
            invalidateAbandonedSkyStreamProxy(
                request.url,
                launchContext: request.launchContext
            )
            Logger.shared.log(
                "ServicesResultsSheet: discarded resolved playback request because the source sheet is no longer active",
                type: "Player"
            )
            return
        }
        onPlaybackSelectionCommitted?()

        if shouldDismissAutoModeSheetBeforePlayback {
            dismissAutoModeSheetBeforePlaybackIfNeeded { _ in
                onResolvedPlaybackRequest(request)
            }
            return
        }

        presentationMode.wrappedValue.dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            onResolvedPlaybackRequest(request)
        }
    }

    @MainActor
    private func invalidateAbandonedSkyStreamProxy(
        _ url: URL,
        launchContext: PlaybackLaunchContext?
    ) {
#if os(iOS) && !targetEnvironment(macCatalyst)
        guard launchContext?.sourceKind == .skyStream else { return }
        MPVHeaderProxy.shared.invalidateSession(for: url)
#endif
    }

    @MainActor
    private func dismissAutoModeSheetBeforePlaybackIfNeeded(
        presentationRetryCount: Int = 0,
        _ completion: @escaping (UIViewController?) -> Void
    ) {
        guard shouldDismissAutoModeSheetBeforePlayback else {
            completion(sheetHostController)
            return
        }

        if let hostController = sheetHostController,
           let originatingPresenter = hostController.presentingViewController {
            hostController.dismiss(animated: true) {
                Task { @MainActor in
                    self.sheetHostController = nil
                    completion(originatingPresenter.topmostViewController())
                }
            }
            return
        }

        if presentationRetryCount < 10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                dismissAutoModeSheetBeforePlaybackIfNeeded(
                    presentationRetryCount: presentationRetryCount + 1,
                    completion
                )
            }
            return
        }

        presentationMode.wrappedValue.dismiss()
        sheetHostController = nil
        DispatchQueue.main.async {
            Task { @MainActor in
                completion(nil)
            }
        }
    }

    @ViewBuilder
    private var autoModeProgressView: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                EclipseLoadingIndicator(tint: .white)
                    .scaleEffect(1.35)

                VStack(spacing: 8) {
                    Text(downloadMode ? "Auto Download" : "Auto Mode")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)

                    Text(displayTitle)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)

                    if !viewModel.currentFetchingTitle.isEmpty {
                        Text(viewModel.currentFetchingTitle)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.white.opacity(0.8))
                            .lineLimit(1)
                    }

                    Text(viewModel.streamFetchProgress.isEmpty ? "Preparing..." : viewModel.streamFetchProgress)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)

                    if let autoModeLastFailureMessage {
                        Text(autoModeLastFailureMessage)
                            .font(.caption)
                            .foregroundColor(.orange.opacity(0.95))
                            .multilineTextAlignment(.center)
                    }
                }

                Button(role: .cancel) {
                    autoModeDidRun = true
                    dismissSheetWithoutPlaybackHandoff()
                } label: {
                    Text(downloadMode ? "Stop" : "Cancel")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
            .padding(28)
            .frame(maxWidth: 360)
            .applyLiquidGlassBackground(cornerRadius: 16)
            .padding(.horizontal, 28)
        }
    }

    @MainActor
    private func forcedWatchTogetherMediaIsCurrent() -> Bool {
        guard forceAutomaticPlayback || watchTogetherExactHandoff else { return true }
        guard isSheetActive else { return false }
        guard forceAutomaticPlayback else { return true }
        return forcedWatchTogetherSharedMediaMatchesCurrent()
    }

    @MainActor
    private func forcedWatchTogetherSharedMediaMatchesCurrent() -> Bool {
        guard forceAutomaticPlayback else { return true }

        let context = effectivePlaybackContext
        let descriptor = WatchTogetherMediaDescriptor(
            tmdbID: tmdbId,
            mediaType: isMovie ? "movie" : "tv",
            seasonNumber: isMovie
                ? nil
                : context?.resolvedTMDBSeasonNumber ?? originalTMDBSeasonNumber ?? selectedEpisode?.seasonNumber,
            episodeNumber: isMovie
                ? nil
                : context?.resolvedTMDBEpisodeNumber ?? originalTMDBEpisodeNumber ?? selectedEpisode?.episodeNumber,
            playbackContext: context,
            isAnime: isAnimeContent || context?.hasAnimeMediaId == true,
            title: playerMediaTitle
        )
        return WatchTogetherCoordinator.shared.isCurrentSharedMedia(descriptor)
    }

    @MainActor
    private func startAutoModeIfNeeded() {
        guard isAutoModeEnabled, !showManualPicker else { return }
        guard autoModeRunToken != requestToken else { return }
#if os(iOS) && !targetEnvironment(macCatalyst)
        if selectedAutoModeSourceIds.contains(where: { $0.hasPrefix(SkyStreamStableID.prefix) }),
           !skyStreamManager.isLoaded {
            viewModel.currentFetchingTitle = "Loading SkyStream sources..."
            viewModel.streamFetchProgress = "Restoring installed source state..."
            return
        }
#endif
        if isForcedWatchTogetherAnimePlayback,
           effectivePlaybackContext == nil {
            showAutoModeFailure("Watch Together lost the exact anime episode context. Playback stopped instead of guessing S1E1.")
            return
        }
        guard forcedWatchTogetherMediaIsCurrent() else { return }

        autoModeRunToken = requestToken
        beginNewManualSearchGeneration()
        resetStremioStyleServiceResolution()
        autoModeDidRun = true
        autoModeCancelled = false
        autoModeAttemptedSourceIds = activeAutoModeRetrySession?.attemptedSourceIds ?? []
        autoModeRetryScheduled = false
        autoModeLastFailureMessage = activeAutoModeRetrySession?.lastFailureMessage
        viewModel.moduleResults.removeAll()
        viewModel.stremioResults.removeAll()
#if os(iOS) && !targetEnvironment(macCatalyst)
        skyStreamResults.removeAll()
        skyStreamSearchedSourceIds.removeAll()
        skyStreamSearchingSourceIds.removeAll()
#endif
        viewModel.searchedServices.removeAll()
        viewModel.stremioSearchedAddons.removeAll()
        viewModel.failedServices.removeAll()
        viewModel.streamError = nil
        viewModel.showingStreamError = false
        viewModel.isSearching = false
        viewModel.isSearchingStremio = false
        viewModel.currentFetchingTitle = ""
        viewModel.streamFetchProgress = "Checking selected sources..."

        autoModeSelectionTask?.cancel()
        autoModeSelectionTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            await runOrderedAutoModeSelection()
            if !Task.isCancelled {
                autoModeSelectionTask = nil
            }
        }
    }

    private var autoModeSearchQueries: [String] {
        let primary: String
        if let ep = selectedEpisode {
            if specialTitleOnlySearch {
                primary = animeSeasonTitle != nil ? animeEffectiveTitle : effectiveTitle
            } else if animeSeasonTitle != nil {
                primary = "\(animeEffectiveTitle) E\(ep.episodeNumber)"
            } else {
                primary = "\(effectiveTitle) S\(ep.seasonNumber)E\(ep.episodeNumber)"
            }
        } else {
            primary = effectiveTitle
        }

        var queries = [primary]
        if let normalizedAnimeSequelSearchQuery,
           normalizedAnimeSequelSearchQuery.caseInsensitiveCompare(primary) != .orderedSame {
            queries.append(normalizedAnimeSequelSearchQuery)
        }
        if primary.caseInsensitiveCompare(effectiveTitle) != .orderedSame {
            queries.append(effectiveTitle)
        }
        if !isForcedWatchTogetherAnimePlayback {
            if let fallbackAnimeSearchQuery,
               fallbackAnimeSearchQuery.caseInsensitiveCompare(primary) != .orderedSame {
                queries.append(fallbackAnimeSearchQuery)
            }
            if let originalTitle,
               !originalTitle.isEmpty,
               originalTitle.lowercased() != effectiveTitle.lowercased() {
                queries.append(originalTitle)
            }
        }
        var seen = Set<String>()
        return queries.filter { seen.insert(normalizeTitle($0)).inserted }
    }

    @MainActor
    private func runOrderedAutoModeSelection() async {
        guard !Task.isCancelled,
              forcedWatchTogetherMediaIsCurrent() else { return }
        let orderedItems = activeAutoModeItems
        guard !orderedItems.isEmpty else {
            showAutoModeFailure(autoModeUnavailableMessage())
            return
        }

        for item in orderedItems where !autoModeAttemptedSourceIds.contains(item.sourceId) {
            guard !Task.isCancelled,
                  !autoModeCancelled,
                  forcedWatchTogetherMediaIsCurrent() else { return }
            autoModeAttemptedSourceIds.insert(item.sourceId)
            activeAutoModeRetrySession?.recordAttempt(sourceId: item.sourceId)
            switch item {
            case .service(let service):
                viewModel.currentFetchingTitle = service.metadata.sourceName
                viewModel.streamFetchProgress = "Searching \(service.metadata.sourceName)..."
                if let result = await findAutoModeServiceResult(service) {
                    guard !Task.isCancelled,
                          !autoModeCancelled,
                          forcedWatchTogetherMediaIsCurrent() else { return }
                    viewModel.currentFetchingTitle = result.title
                    viewModel.streamFetchProgress = "Found match in \(service.metadata.sourceName). Fetching stream..."
                    await playContent(
                        result,
                        autoModeLaunch: true,
                        retryCount: activeAutoModeRetrySession?.retryCount ?? 0
                    )
                    return
                }
                updateAutoModeSourceStatus(
                    sourceName: service.metadata.sourceName,
                    message: "No matching result was found. Trying the next selected source..."
                )
            case .stremio(let addon):
                viewModel.currentFetchingTitle = addon.manifest.name
                viewModel.streamFetchProgress = "Checking \(addon.manifest.name)..."
                if let stream = await findAutoModeStremioStream(addon) {
                    guard !Task.isCancelled,
                          !autoModeCancelled,
                          forcedWatchTogetherMediaIsCurrent() else { return }
                    viewModel.currentFetchingTitle = stream.displayName
                    viewModel.streamFetchProgress = "Found stream in \(addon.manifest.name)."
                    playStremioStream(
                        stream,
                        addon: addon,
                        autoModeLaunch: true,
                        retryCount: activeAutoModeRetrySession?.retryCount ?? 0
                    )
                    return
                }
                if !autoModeCancelled {
                    updateAutoModeSourceStatus(
                        sourceName: addon.manifest.name,
                        message: "No playable stream was returned. Trying the next selected source..."
                    )
                }
#if os(iOS) && !targetEnvironment(macCatalyst)
            case .skyStream(let provider):
                viewModel.currentFetchingTitle = provider.displayName
                viewModel.streamFetchProgress = "Checking \(provider.displayName)..."
                if let stream = await findAutoModeSkyStream(provider) {
                    guard !Task.isCancelled,
                          !autoModeCancelled,
                          forcedWatchTogetherMediaIsCurrent() else { return }
                    viewModel.currentFetchingTitle = stream.option.name
                    viewModel.streamFetchProgress = "Found verified VOD in \(provider.displayName)."
                    playSkyStream(
                        stream,
                        provider: provider,
                        autoModeLaunch: true,
                        retryCount: activeAutoModeRetrySession?.retryCount ?? 0
                    )
                    return
                }
                if !autoModeCancelled {
                    updateAutoModeSourceStatus(
                        sourceName: provider.displayName,
                        message: "No verified VOD stream was returned. Trying the next selected source..."
                    )
                }
#endif
            }
        }

        let exhaustedMessage = "Auto Mode could not find a playable result from the selected sources."
        if let autoModeLastFailureMessage {
            showAutoModeFailure("\(autoModeLastFailureMessage)\n\n\(exhaustedMessage)")
        } else {
            showAutoModeFailure(exhaustedMessage)
        }
    }

    @MainActor
    private func findAutoModeServiceResult(_ service: Service) async -> SearchItem? {
        var combined: [SearchItem] = []
        var seenHrefs = Set<String>()

        for query in autoModeSearchQueries {
            guard !Task.isCancelled,
                  !autoModeCancelled,
                  forcedWatchTogetherMediaIsCurrent() else { return nil }
            viewModel.streamFetchProgress = "Searching \(service.metadata.sourceName) for \(query)..."
            let results = await serviceManager.searchSingleActiveService(service: service, query: query)
            guard !Task.isCancelled,
                  !autoModeCancelled,
                  forcedWatchTogetherMediaIsCurrent() else { return nil }
            let newResults = results.filter { seenHrefs.insert($0.href).inserted }
            combined.append(contentsOf: newResults)
            combined = retainedServiceResults(combined)
            viewModel.moduleResults[service.id] = combined
            viewModel.searchedServices.insert(service.id)
        }

        return bestServiceResult(for: service)
    }

    @MainActor
    private func findAutoModeStremioStream(_ addon: StremioAddon) async -> StremioStream? {
        guard !Task.isCancelled,
              forcedWatchTogetherMediaIsCurrent() else { return nil }
        guard shouldSearchStremio else {
            viewModel.stremioResults[addon.id] = []
            viewModel.stremioSearchedAddons.insert(addon.id)
            Logger.shared.log("Auto Mode Stremio skipped for special without TMDB episode mapping: \(addon.manifest.name)", type: "Stremio")
            return nil
        }

        let type = isMovie ? "movie" : "series"
        let season = streamLookupSeasonNumber
        let episode = streamLookupEpisodeNumber

        let fetchedStreams = await stremioManager.fetchStreamsFromAddon(
            addon,
            tmdbId: tmdbId,
            imdbId: imdbId,
            type: type,
            season: season,
            episode: episode,
            anilistId: stremioLookupAniListId,
            playbackContext: effectivePlaybackContext,
            titleCandidates: stremioCatalogTitleCandidates
        )
        guard !Task.isCancelled,
              forcedWatchTogetherMediaIsCurrent() else { return nil }
        let streams = filteredStremioStreams(fetchedStreams, addon: addon)

        viewModel.stremioResults[addon.id] = streams
        viewModel.stremioSearchedAddons.insert(addon.id)

        if let best = bestStremioStream(from: streams, addon: addon) {
            return best
        } else if streams.count > 1 {
            let fallbackReason = AutoModeQualityPreference.current.usesAutomaticSelection ? "no quality label" : "auto quality disabled"
            viewModel.stremioStreamOptions = streams
            viewModel.selectedStremioAddon = addon
            viewModel.pendingPlaybackAutoMode = true
            viewModel.isFetchingStreams = false
            viewModel.showingStremioStreamPicker = true
            autoModeCancelled = true
            Logger.shared.log("Auto Mode found \(streams.count) Stremio streams for \(addon.manifest.name) but \(fallbackReason); showing picker", type: "Stremio")
            return nil
        }

        return nil
    }

#if os(iOS) && !targetEnvironment(macCatalyst)
    @MainActor
    private func findAutoModeSkyStream(
        _ provider: SkyStreamProviderDescriptor
    ) async -> ValidatedSkyStreamOption? {
        guard !Task.isCancelled,
              !autoModeCancelled,
              forcedWatchTogetherMediaIsCurrent() else { return nil }

        do {
            let asksForQuality = !AutoModeQualityPreference.current.usesAutomaticSelection
            let resolved = try await SkyStreamResolver.shared.resolve(
                sourceID: provider.id,
                target: skyStreamResolutionTarget,
                mode: asksForQuality ? .manual : .autoMode,
                purpose: downloadMode ? .offlineDownload : .playback,
                originalAudioLanguage: originalAudioLanguage
            )
            guard !Task.isCancelled,
                  !autoModeCancelled,
                  forcedWatchTogetherMediaIsCurrent() else { return nil }

            var allowed = resolved.map(validatedSkyStreamOption(from:)).filter {
                guard let configuration = StreamLanguageFilter.configuration(sourceId: provider.id) else {
                    return true
                }
                return serviceStreamOptionIsVisible($0.option, configuration: configuration)
            }
            if downloadMode {
                allowed = allowed.filter(isSkyStreamDownloadCompatible)
            }

            // Auto Mode validates one top-ranked candidate for the fast path. If that candidate
            // is hidden by explicit language/quality rules, only then spend the extra work to
            // inspect the bounded manual pool so a provider is not incorrectly skipped.
            if allowed.isEmpty,
               downloadMode
                || StreamLanguageFilter.configuration(sourceId: provider.id)?.canHideStreams == true {
                let fallback = try await SkyStreamResolver.shared.resolve(
                    sourceID: provider.id,
                    target: skyStreamResolutionTarget,
                    mode: .manual,
                    purpose: downloadMode ? .offlineDownload : .playback,
                    originalAudioLanguage: originalAudioLanguage
                )
                guard !Task.isCancelled,
                      !autoModeCancelled,
                      forcedWatchTogetherMediaIsCurrent() else { return nil }
                let configuration = StreamLanguageFilter.configuration(sourceId: provider.id)
                allowed = fallback.map(validatedSkyStreamOption(from:)).filter {
                    serviceStreamOptionIsVisible($0.option, configuration: configuration)
                }
                if downloadMode {
                    allowed = allowed.filter(isSkyStreamDownloadCompatible)
                }
            }

            skyStreamResults[provider.id] = Array(
                allowed.prefix(Self.maxRetainedSkyStreamOptionsPerProvider)
            )
            skyStreamSearchedSourceIds.insert(provider.id)
            let best = bestSkyStreamOption(from: allowed)
            if allowed.count > 1, asksForQuality || best == nil {
                selectedSkyStreamProvider = provider
                skyStreamPickerOptions = Array(
                    allowed.prefix(Self.maxVisibleSkyStreamOptionsPerProvider)
                )
                viewModel.pendingPlaybackAutoMode = true
                viewModel.pendingPlaybackRetryCount = activeAutoModeRetrySession?.retryCount ?? 0
                viewModel.isFetchingStreams = false
                showingSkyStreamPicker = true
                autoModeCancelled = true
                return nil
            }
            return best ?? allowed.first
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled,
                  !autoModeCancelled,
                  forcedWatchTogetherMediaIsCurrent() else { return nil }
            Logger.shared.log(
                "SkyStream: Auto Mode resolution failed sourceID=\(provider.id) errorType=\(String(reflecting: type(of: error)))",
                type: "SkyStream"
            )
            skyStreamResults[provider.id] = []
            skyStreamSearchedSourceIds.insert(provider.id)
            return nil
        }
    }
#endif

    @MainActor
    private func showAutoModeFailure(_ message: String) {
        viewModel.isFetchingStreams = false
        viewModel.streamError = message
        viewModel.showingStreamError = true
    }

    @MainActor
    private func updateAutoModeSourceStatus(sourceName: String, message: String) {
        autoModeLastFailureMessage = "\(sourceName): \(message)"
        activeAutoModeRetrySession?.recordStatus(sourceName: sourceName, message: message)
        viewModel.currentFetchingTitle = sourceName
        viewModel.streamFetchProgress = "Continuing Auto Mode..."
    }

    @MainActor
    private func shouldRetryNextAutoModeSource(autoModeLaunch: Bool?) -> Bool {
        autoModeOnly
            && !showManualPicker
            && !autoModeCancelled
            && (autoModeLaunch ?? viewModel.pendingPlaybackAutoMode)
    }

    @MainActor
    private func retryNextAutoModeSource(sourceName: String, message: String) {
        updateAutoModeSourceStatus(
            sourceName: sourceName,
            message: "\(message) Trying the next selected source..."
        )
        viewModel.resetPickerState()
        viewModel.resetStreamState()
        viewModel.subtitleOptions = []
        viewModel.pendingStreamURL = nil
        viewModel.pendingHeaders = nil
        viewModel.streamError = nil
        viewModel.showingStreamError = false

        guard !autoModeRetryScheduled else { return }
        autoModeRetryScheduled = true
        Task { @MainActor in
            await Task.yield()
            autoModeRetryScheduled = false
            guard !autoModeCancelled else { return }
            await runOrderedAutoModeSelection()
        }
    }

    @MainActor
    private func cancelPendingAutoModeChoice(_ message: String) {
        let wasAutoModeChoice = shouldUseAutomaticResolution
        viewModel.resetPickerState()
        viewModel.resetStreamState()
        viewModel.subtitleOptions = []
        viewModel.pendingStreamURL = nil
        viewModel.pendingHeaders = nil

        if wasAutoModeChoice && autoModeOnly && !showManualPicker {
            showAutoModeFailure(message)
        }
    }

    @MainActor
    private func handleServicePlaybackPreparationFailure(_ service: Service, message: String, autoModeLaunch: Bool? = nil) {
        if shouldRetryNextAutoModeSource(autoModeLaunch: autoModeLaunch) {
            #if !os(tvOS)
            // A Cloudflare wall is usually one tap away from working. Silently moving on to the
            // next candidate would trade the user's best-ranked source for a worse one just to
            // avoid an interruption — show the verification sheet and retry THIS source first;
            // only fall back to skipping if verification itself fails or is cancelled.
            if let cloudflareURL = viewModel.pendingCloudflareURL {
                resolveCloudflareChallengeDuringAutoMode(
                    cloudflareURL,
                    sourceName: service.metadata.sourceName,
                    fallbackMessage: message
                )
                return
            }
            #endif
            retryNextAutoModeSource(sourceName: service.metadata.sourceName, message: message)
            return
        }
        viewModel.isFetchingStreams = false
        viewModel.streamError = message
        viewModel.showingStreamError = true
    }

    @MainActor
    private func handleStremioPlaybackPreparationFailure(_ addon: StremioAddon, message: String, autoModeLaunch: Bool) {
        if shouldRetryNextAutoModeSource(autoModeLaunch: autoModeLaunch) {
            retryNextAutoModeSource(sourceName: addon.manifest.name, message: message)
            return
        }
        viewModel.isFetchingStreams = false
        viewModel.streamError = message
        viewModel.showingStreamError = true
    }

    @MainActor
    private func handlePlaybackStartupFailure(_ report: PlaybackFailureReport) {
        if shouldRetryNextAutoModeSource(autoModeLaunch: report.context.autoMode) {
            retryNextAutoModeSource(sourceName: report.context.sourceName, message: report.message)
            return
        }
        viewModel.isFetchingStreams = false
        viewModel.streamError = "\(report.context.sourceName) could not start playback. \(report.message)"
        viewModel.showingStreamError = true
    }

#if !os(tvOS)
    private func configurePlaybackRecovery(_ player: PlayerViewController, context: PlaybackLaunchContext) {
        player.playbackLaunchContext = context
        player.onPlaybackStartupFailure = { report in
            Task { @MainActor in
                handlePlaybackStartupFailure(report)
            }
        }
    }

    private func configurePlaybackRecovery(_ player: NormalPlayer, context: PlaybackLaunchContext) {
        player.playbackLaunchContext = context
        player.onPlaybackStartupFailure = { report in
            Task { @MainActor in
                handlePlaybackStartupFailure(report)
            }
        }
    }
#endif

    @MainActor
    private func cancelAutoModeDownloadValidation() {
        let task = autoModeDownloadTask
        autoModeDownloadTask = nil
        task?.cancel()
    }

    @MainActor
    private func switchToManualPicker() {
        autoModeCancelled = true
        cancelAutoModeDownloadValidation()
        beginNewManualSearchGeneration()
        resetStremioStyleServiceResolution()
        showManualPicker = true
        viewModel.moduleResults.removeAll()
        viewModel.stremioResults.removeAll()
        viewModel.searchedServices.removeAll()
        viewModel.stremioSearchedAddons.removeAll()
        viewModel.failedServices.removeAll()
#if os(iOS) && !targetEnvironment(macCatalyst)
        skyStreamResults.removeAll()
        skyStreamSearchedSourceIds.removeAll()
#endif
        viewModel.streamError = nil
        viewModel.showingStreamError = false
        startProgressiveSearch()
        startStremioSearch()
#if os(iOS) && !targetEnvironment(macCatalyst)
        startSkyStreamSearch()
#endif
    }
    
    var body: some View {
        NavigationView {
            Group {
                if autoModeOnly && !showManualPicker {
                    autoModeProgressView
                } else if stremioStyleSheetEnabled {
                    List {
                        stremioStyleHeader

                        if !hasAnyActiveSources {
                            noActiveServicesSection
                        } else if hasStremioStyleResults {
                            stremioStyleResults
                        } else if !isStremioStyleSearchActive {
                            noResultsRow
                                .listRowBackground(Color.clear)
                                .eclipseHideListRowSeparator()
                        }
                    }
                    .listStyle(.plain)
                    .eclipseSettingsStyle(allowsAnimatedBackground: false)
                } else {
                    List {
                        searchInfoSection
                            .background(EclipseScrollTracker())

                        if !hasAnyActiveSources {
                            noActiveServicesSection
                        } else {
                            unifiedResultsSections
                        }
                    }
                    .eclipseSettingsStyle(allowsAnimatedBackground: false)
                }
            }
            .navigationTitle(autoModeOnly && !showManualPicker ? (downloadMode ? "Auto Download" : "Auto Mode") : (downloadMode ? "Download Source" : "Source Results"))
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !stremioStyleSheetEnabled || shouldDropMismatchedServiceResults {
                        Menu {
                            if !stremioStyleSheetEnabled {
                                Section("Matching Algorithm") {
                                    ForEach(SimilarityAlgorithm.allCases, id: \.self) { algorithm in
                                        Button(action: {
                                            algorithmManager.selectedAlgorithm = algorithm
                                        }) {
                                            HStack {
                                                Text(algorithm.displayName)
                                                if algorithmManager.selectedAlgorithm == algorithm {
                                                    Spacer()
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            Section("Filter Settings") {
                                Button(action: {
                                    thresholdEditorValue = stremioStyleSheetEnabled
                                        ? serviceResultMinimumSimilarity
                                        : viewModel.highQualityThreshold
                                    viewModel.showingFilterEditor = true
                                }) {
                                    HStack {
                                        Image(systemName: "slider.horizontal.3")
                                        Text(stremioStyleSheetEnabled ? "Ranking Similarity" : "Quality Threshold")
                                        Spacer()
                                        Text("\(Int((stremioStyleSheetEnabled ? serviceResultMinimumSimilarity : viewModel.highQualityThreshold) * 100))%")
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        if downloadMode && onSkipRequested != nil {
                            Button("Skip") {
                                deactivateSheetForDismissal()
                                onSkipRequested?()
                                presentationMode.wrappedValue.dismiss()
                            }
                        }
                        
                        Button("Done") {
                            dismissSheetWithoutPlaybackHandoff()
                        }
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .alert(downloadMode ? "Download Content" : "Play Content", isPresented: $viewModel.showingPlayAlert) {
            playAlertButtons
        } message: {
            playAlertMessage
        }
        .alert(downloadMode ? "Download Stream" : "Play Stream", isPresented: $showingResolvedServiceStreamAlert) {
            resolvedServiceStreamAlertButtons
        } message: {
            resolvedServiceStreamAlertMessage
        }
        .overlay(streamFetchingOverlay)
        // SwiftUI does not expose an interactive-dismiss callback on the iOS 15 deployment
        // target. Callback-based source pickers therefore use their explicit Done/Cancel paths,
        // which can deactivate resolution synchronously before the dismissal animation begins.
        .interactiveDismissDisabled(onResolvedPlaybackRequest != nil)
        .background(
            ServicesSheetPresentationAnchor { controller in
                if sheetHostController !== controller {
                    sheetHostController = controller
                }
                if onResolvedPlaybackRequest != nil {
                    // These sheets are also presented from UIKit hosting controllers, where the
                    // SwiftUI modifier alone is not guaranteed to own adaptive dismissal.
                    controller.isModalInPresentation = true
                }
            }
            .frame(width: 0, height: 0)
        )
        .onAppear {
            isSheetActive = true
            beginNewManualSearchGeneration()
            resetStremioStyleServiceResolution()
            autoModeDidRun = false
            if autoModeOnly && !showManualPicker {
                startAutoModeIfNeeded()
            } else {
                startProgressiveSearch()
                startStremioSearch()
#if os(iOS) && !targetEnvironment(macCatalyst)
                startSkyStreamSearch()
#endif
            }
        }
        .onChangeComp(of: requestToken) { _, _ in
            Logger.shared.log("ServicesResultsSheet request token changed: \(requestToken)", type: "Stream")
            beginNewManualSearchGeneration()
            resetStremioStyleServiceResolution()
            cancelAutoModeDownloadValidation()
            autoModeSelectionTask?.cancel()
            autoModeSelectionTask = nil
            autoModeDidRun = false
            autoModeRunToken = nil
            autoModeCancelled = false
            if autoModeOnly && !showManualPicker {
                startAutoModeIfNeeded()
            } else {
                viewModel.moduleResults.removeAll()
                viewModel.stremioResults.removeAll()
                viewModel.searchedServices.removeAll()
                viewModel.stremioSearchedAddons.removeAll()
                viewModel.failedServices.removeAll()
#if os(iOS) && !targetEnvironment(macCatalyst)
                skyStreamResults.removeAll()
                skyStreamSearchedSourceIds.removeAll()
#endif
                startProgressiveSearch()
                startStremioSearch()
#if os(iOS) && !targetEnvironment(macCatalyst)
                startSkyStreamSearch()
#endif
            }
        }
        .onChangeComp(of: stremioStyleSheetEnabled) { _, enabled in
            if enabled {
                scheduleStremioStyleServiceResolution()
            } else {
                resetStremioStyleServiceResolution()
            }
        }
        .onChangeComp(of: storedServiceResultMinimumSimilarity) { _, _ in
            scheduleStremioStyleServiceResolution()
        }
        .onChangeComp(of: dropMismatchedServiceResults) { _, _ in
            scheduleStremioStyleServiceResolution()
        }
        .onChangeComp(of: viewModel.isSearching) { _, _ in
            maybeRunAutoModeSelection()
        }
        .onChangeComp(of: viewModel.isSearchingStremio) { _, _ in
            maybeRunAutoModeSelection()
        }
#if os(iOS) && !targetEnvironment(macCatalyst)
        .onChangeComp(of: skyStreamManager.isLoaded) { _, isLoaded in
            guard isLoaded, isSheetActive else { return }
            if autoModeOnly && !showManualPicker {
                startAutoModeIfNeeded()
            } else {
                startSkyStreamSearch()
            }
        }
        // Resolver storage/preferences are persisted back into installedPlugins after a search.
        // Watching the presentation topology avoids recursively restarting every source while
        // still reacting to installs, updates, provider/domain changes, and enablement changes.
        .onChangeComp(of: skyStreamManager.providers) { _, _ in
            guard isSheetActive, skyStreamManager.isLoaded else { return }
            beginNewManualSearchGeneration()
            if autoModeOnly && !showManualPicker {
                autoModeRunToken = nil
                startAutoModeIfNeeded()
            } else {
                resetStremioStyleServiceResolution()
                viewModel.moduleResults.removeAll()
                viewModel.stremioResults.removeAll()
                viewModel.searchedServices.removeAll()
                viewModel.stremioSearchedAddons.removeAll()
                viewModel.failedServices.removeAll()
                startProgressiveSearch()
                startStremioSearch()
                startSkyStreamSearch()
            }
        }
#endif
        .alert(stremioStyleSheetEnabled ? "Ranking Similarity" : "Quality Threshold", isPresented: $viewModel.showingFilterEditor) {
            qualityThresholdAlertContent
        } message: {
            qualityThresholdAlertMessage
        }
        .adaptiveConfirmationDialog("Select Server", isPresented: $viewModel.showingStreamMenu, titleVisibility: .visible) {
            serverSelectionDialogContent
        } message: {
            serverSelectionDialogMessage
        }
        .adaptiveConfirmationDialog("Select Season", isPresented: $viewModel.showingSeasonPicker, titleVisibility: .visible) {
            seasonPickerDialogContent
        } message: {
            seasonPickerDialogMessage
        }
        .adaptiveConfirmationDialog("Select Episode", isPresented: $viewModel.showingEpisodePicker, titleVisibility: .visible) {
            episodePickerDialogContent
        } message: {
            episodePickerDialogMessage
        }
        .adaptiveConfirmationDialog("Select Subtitle", isPresented: $viewModel.showingSubtitlePicker, titleVisibility: .visible) {
            subtitlePickerDialogContent
        } message: {
            subtitlePickerDialogMessage
        }
        .alert("Stream Error", isPresented: $viewModel.showingStreamError) {
            if autoModeOnly && !showManualPicker {
                if downloadMode && onSkipRequested != nil {
                    Button("Skip Episode") {
                        deactivateSheetForDismissal()
                        viewModel.streamError = nil
                        onSkipRequested?()
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                Button("Manual Select") {
                    switchToManualPicker()
                }
                Button(downloadMode && onSkipRequested != nil ? "Stop Downloads" : "Cancel", role: .cancel) {
                    viewModel.streamError = nil
                    dismissSheetWithoutPlaybackHandoff()
                }
            } else {
                #if !os(tvOS)
                if viewModel.pendingCloudflareURL != nil {
                    Button("Verify Cloudflare") {
                        verifyPendingCloudflareChallenge()
                    }
                }
                #endif
                Button("OK", role: .cancel) {
                    viewModel.streamError = nil
                    viewModel.pendingCloudflareURL = nil
                    viewModel.pendingCloudflareRetry = nil
                }
            }
        } message: {
            if let error = viewModel.streamError {
                Text(viewModel.pendingCloudflareURL != nil
                     ? "\(error)\n\nThis source is behind a Cloudflare security check. Tap Verify Cloudflare to complete it."
                     : error)
            }
        }
        .onDisappear {
            deactivateSheetForDismissal()
        }
        .alert(downloadMode ? "Download Stream" : "Play Stream", isPresented: $viewModel.showingStremioPlayAlert) {
            Button(actionVerb) {
                viewModel.showingStremioPlayAlert = false
                if let stream = viewModel.selectedStremioStream,
                   let addon = viewModel.selectedStremioAddon {
                    playStremioStream(stream, addon: addon)
                }
            }
            Button("Cancel", role: .cancel) {
                viewModel.selectedStremioStream = nil
                viewModel.selectedStremioAddon = nil
            }
        } message: {
            if let stream = viewModel.selectedStremioStream {
                Text("\(actionVerb) '\(stream.displayName)'?")
            }
        }
#if os(iOS) && !targetEnvironment(macCatalyst)
        .alert(downloadMode ? "Download Stream" : "Play Stream", isPresented: $showingSkyStreamPlayAlert) {
            Button(actionVerb) {
                showingSkyStreamPlayAlert = false
                if let stream = selectedSkyStreamOption,
                   let provider = selectedSkyStreamProvider {
                    playSkyStream(stream, provider: provider)
                }
                selectedSkyStreamOption = nil
            }
            Button("Cancel", role: .cancel) {
                selectedSkyStreamOption = nil
                selectedSkyStreamProvider = nil
            }
        } message: {
            if let stream = selectedSkyStreamOption {
                Text("\(actionVerb) '\(stream.option.name)'?")
            }
        }
#endif
        .adaptiveConfirmationDialog("Select Stream", isPresented: $viewModel.showingStremioStreamPicker, titleVisibility: .visible) {
            stremioStreamPickerContent
        } message: {
            stremioStreamPickerMessage
        }
#if os(iOS) && !targetEnvironment(macCatalyst)
        .adaptiveConfirmationDialog("Select Verified Stream", isPresented: $showingSkyStreamPicker, titleVisibility: .visible) {
            skyStreamPickerContent
        } message: {
            skyStreamPickerMessage
        }
#endif
    }
    
    @MainActor
    private func startProgressiveSearch() {
        let searchGeneration = manualSearchGeneration
        let activeServices = serviceManager.activeServices
        viewModel.totalServicesCount = activeServices.count
        viewModel.isSearching = !activeServices.isEmpty
        
        guard !activeServices.isEmpty else {
            viewModel.isSearching = false
            return
        }
        
        // Build search query
        let searchQuery: String
        if let ep = selectedEpisode {
            if specialTitleOnlySearch {
                searchQuery = animeSeasonTitle != nil ? animeEffectiveTitle : effectiveTitle
            } else if animeSeasonTitle != nil {
                searchQuery = "\(animeEffectiveTitle) E\(ep.episodeNumber)"
            } else {
                searchQuery = "\(effectiveTitle) S\(ep.seasonNumber)E\(ep.episodeNumber)"
            }
        } else {
            searchQuery = effectiveTitle
        }
        
        let baseTitleQuery = normalizedAnimeSequelSearchQuery
            ?? fallbackAnimeSearchQuery
            ?? (searchQuery.caseInsensitiveCompare(effectiveTitle) == .orderedSame ? nil : effectiveTitle)
        let hasAlternativeTitle = originalTitle.map { !$0.isEmpty && $0.lowercased() != effectiveTitle.lowercased() } ?? false
        
        Task {
            await serviceManager.searchInActiveServicesProgressively(
                query: searchQuery,
                onResult: { service, results in
                    Task { @MainActor in
                        guard self.isCurrentManualSearchGeneration(searchGeneration) else { return }
                        self.viewModel.moduleResults[service.id] = self.retainedServiceResults(results ?? [])
                        self.viewModel.searchedServices.insert(service.id)
                        self.scheduleStremioStyleServiceResolution()
                        
                        if results == nil {
                            self.viewModel.failedServices.insert(service.id)
                        } else {
                            self.viewModel.failedServices.remove(service.id)
                        }
                    }
                },
                onComplete: {
                    // Second tier: search with base title if different from primary query
                    if let baseTitleQuery = baseTitleQuery {
                        Task {
                            await self.serviceManager.searchInActiveServicesProgressively(
                                query: baseTitleQuery,
                                onResult: { service, additionalResults in
                                    Task { @MainActor in
                                        guard self.isCurrentManualSearchGeneration(searchGeneration) else { return }
                                        let additional = additionalResults ?? []
                                        let existing = self.viewModel.moduleResults[service.id] ?? []
                                        self.viewModel.moduleResults[service.id] = self.mergedServiceResults(existing: existing, additional: additional)
                                        self.scheduleStremioStyleServiceResolution()
                                        
                                        if additionalResults == nil {
                                            self.viewModel.failedServices.insert(service.id)
                                        }
                                    }
                                },
                                onComplete: {
                                    // Third tier: search with romaji/original title
                                    if hasAlternativeTitle, let altTitle = self.originalTitle {
                                        Task {
                                            await self.serviceManager.searchInActiveServicesProgressively(
                                                query: altTitle,
                                                onResult: { service, additionalResults in
                                                    Task { @MainActor in
                                                        guard self.isCurrentManualSearchGeneration(searchGeneration) else { return }
                                                        let additional = additionalResults ?? []
                                                        let existing = self.viewModel.moduleResults[service.id] ?? []
                                                        self.viewModel.moduleResults[service.id] = self.mergedServiceResults(existing: existing, additional: additional)
                                                        self.scheduleStremioStyleServiceResolution()
                                                        
                                                        if additionalResults == nil {
                                                            self.viewModel.failedServices.insert(service.id)
                                                        }
                                                    }
                                                },
                                                onComplete: {
                                                    Task { @MainActor in
                                                        guard self.isCurrentManualSearchGeneration(searchGeneration) else { return }
                                                        self.viewModel.isSearching = false
                                                    }
                                                }
                                            )
                                        }
                                    } else {
                                        Task { @MainActor in
                                            guard self.isCurrentManualSearchGeneration(searchGeneration) else { return }
                                            self.viewModel.isSearching = false
                                        }
                                    }
                                }
                            )
                        }
                    } else if hasAlternativeTitle, let altTitle = self.originalTitle {
                        // No base title query, go straight to romaji
                        Task {
                            await self.serviceManager.searchInActiveServicesProgressively(
                                query: altTitle,
                                onResult: { service, additionalResults in
                                    Task { @MainActor in
                                        guard self.isCurrentManualSearchGeneration(searchGeneration) else { return }
                                        let additional = additionalResults ?? []
                                        let existing = self.viewModel.moduleResults[service.id] ?? []
                                        self.viewModel.moduleResults[service.id] = self.mergedServiceResults(existing: existing, additional: additional)
                                        self.scheduleStremioStyleServiceResolution()
                                        
                                        if additionalResults == nil {
                                            self.viewModel.failedServices.insert(service.id)
                                        }
                                    }
                                },
                                onComplete: {
                                    Task { @MainActor in
                                        guard self.isCurrentManualSearchGeneration(searchGeneration) else { return }
                                        self.viewModel.isSearching = false
                                    }
                                }
                            )
                        }
                    } else {
                        Task { @MainActor in
                            guard self.isCurrentManualSearchGeneration(searchGeneration) else { return }
                            self.viewModel.isSearching = false
                        }
                    }
                }
            )
        }
    }

#if os(iOS) && !targetEnvironment(macCatalyst)
    // MARK: - SkyStream Search

    @MainActor
    private func startSkyStreamSearch() {
        skyStreamSearchTask?.cancel()
        skyStreamSearchTask = nil
        skyStreamResults.removeAll()
        skyStreamSearchedSourceIds.removeAll()
        skyStreamSearchingSourceIds.removeAll()

        guard isSheetActive,
              skyStreamManager.isLoaded,
              PlatformCapabilities.current.supportsSkyStreamPlugins else { return }

        let providers = activeSkyStreamProviders
        guard !providers.isEmpty else { return }

        let generation = manualSearchGeneration
        let target = skyStreamResolutionTarget
        skyStreamSearchingSourceIds = Set(providers.map(\.id))

        skyStreamSearchTask = Task { @MainActor in
            // Publish one verified stream per provider first, then expand the same cached
            // resolutions for the picker. This keeps first-result latency comparable to addon
            // fanout without relaxing the VOD boundary or allowing unbounded provider work.
            await runSkyStreamSearchPhase(
                providers: providers,
                target: target,
                mode: .manualFast,
                generation: generation,
                isFinalPhase: false
            )
            guard !Task.isCancelled,
                  isCurrentManualSearchGeneration(generation) else { return }
            guard forcedWatchTogetherMediaIsCurrent() else {
                // Watch Together can advance while the first verified rows are resolving. Stop
                // the old sheet cleanly instead of leaving every provider in a permanent
                // searching state; a replacement/cancelled search owns its own cleanup path.
                skyStreamSearchingSourceIds.removeAll()
                skyStreamSearchTask = nil
                return
            }
            await runSkyStreamSearchPhase(
                providers: providers,
                target: target,
                mode: .manual,
                generation: generation,
                isFinalPhase: true
            )

            guard !Task.isCancelled,
                  isCurrentManualSearchGeneration(generation) else { return }
            skyStreamSearchingSourceIds.removeAll()
            skyStreamSearchTask = nil
            maybeRunAutoModeSelection()
        }
    }

    @MainActor
    private func runSkyStreamSearchPhase(
        providers: [SkyStreamProviderDescriptor],
        target: SkyStreamResolutionTarget,
        mode: SkyStreamResolutionMode,
        generation: UUID,
        isFinalPhase: Bool
    ) async {
        let resolutionPurpose: SkyStreamResolutionPurpose = downloadMode
            ? .offlineDownload
            : .playback
        let resolutionOriginalAudioLanguage = originalAudioLanguage
        await withTaskGroup(
            of: (provider: SkyStreamProviderDescriptor, streams: [SkyStreamResolvedStream], error: String?).self
        ) { group in
            var nextProviderIndex = 0
            let initialCount = min(Self.maxConcurrentSkyStreamResolutions, providers.count)

            for provider in providers.prefix(initialCount) {
                nextProviderIndex += 1
                group.addTask {
                    do {
                        let streams = try await SkyStreamResolver.shared.resolve(
                            sourceID: provider.id,
                            target: target,
                            mode: mode,
                            purpose: resolutionPurpose,
                            originalAudioLanguage: resolutionOriginalAudioLanguage
                        )
                        return (provider, streams, nil)
                    } catch is CancellationError {
                        return (provider, [], nil)
                    } catch {
                        return (provider, [], Self.skyStreamFailureDiagnostic(error))
                    }
                }
            }

            for await result in group {
                guard !Task.isCancelled,
                      isCurrentManualSearchGeneration(generation),
                      forcedWatchTogetherMediaIsCurrent() else {
                    group.cancelAll()
                    return
                }

                let normalized = result.streams
                    .prefix(Self.maxRetainedSkyStreamOptionsPerProvider)
                    .map(validatedSkyStreamOption(from:))
                if !normalized.isEmpty || skyStreamResults[result.provider.id] == nil {
                    let existing = skyStreamResults[result.provider.id] ?? []
                    skyStreamResults[result.provider.id] = normalized.map { candidate in
                        guard let prior = existing.first(where: {
                            $0.resolved.provider.id == candidate.resolved.provider.id
                                && $0.resolved.streamRecord.id == candidate.resolved.streamRecord.id
                                && $0.resolved.playback.identity == candidate.resolved.playback.identity
                                && $0.resolved.playback.mediaKind == candidate.resolved.playback.mediaKind
                                && $0.resolved.playback.underlyingRemoteURL.url
                                    == candidate.resolved.playback.underlyingRemoteURL.url
                                && $0.option.name == candidate.option.name
                        }) else {
                            return candidate
                        }
                        // Preserve SwiftUI identity without preserving potentially short-lived
                        // headers, cookies, manifests, subtitle routes, or content references
                        // from the fast phase. The full phase's validator output always wins.
                        return ValidatedSkyStreamOption(
                            id: prior.id,
                            resolved: candidate.resolved,
                            option: candidate.option
                        )
                    }
                }
                skyStreamSearchedSourceIds.insert(result.provider.id)
                if isFinalPhase {
                    skyStreamSearchingSourceIds.remove(result.provider.id)
                }

                if let error = result.error {
                    Logger.shared.log(
                        "SkyStream: \(isFinalPhase ? "picker" : "fast") resolution returned no rows sourceID=\(result.provider.id) failure=\(error)",
                        type: "SkyStream"
                    )
                } else {
                    Logger.shared.log(
                        "SkyStream: \(isFinalPhase ? "picker" : "fast") resolution completed sourceID=\(result.provider.id) verified=\(normalized.count)",
                        type: "SkyStream"
                    )
                }

                if nextProviderIndex < providers.count {
                    let provider = providers[nextProviderIndex]
                    nextProviderIndex += 1
                    group.addTask {
                        do {
                            let streams = try await SkyStreamResolver.shared.resolve(
                                sourceID: provider.id,
                                target: target,
                                mode: mode,
                                purpose: resolutionPurpose,
                                originalAudioLanguage: resolutionOriginalAudioLanguage
                            )
                            return (provider, streams, nil)
                        } catch is CancellationError {
                            return (provider, [], nil)
                        } catch {
                            return (provider, [], Self.skyStreamFailureDiagnostic(error))
                        }
                    }
                }
            }
        }
    }

    nonisolated private static func skyStreamFailureDiagnostic(_ error: Error) -> String {
        if let resolverError = error as? SkyStreamResolverError {
            return "type=SkyStreamResolverError code=\(String(describing: resolverError)) reason=\(resolverError.localizedDescription)"
        }

        if let runtimeError = error as? SkyStreamRuntimeError {
            let code: String
            let reason: String
            switch runtimeError {
            case .pluginRejected:
                code = "pluginRejected"
                reason = "The SkyStream plugin rejected the operation."
            default:
                code = String(describing: runtimeError)
                reason = runtimeError.localizedDescription
            }
            return "type=SkyStreamRuntimeError code=\(code) reason=\(reason)"
        }

        return "type=\(String(reflecting: type(of: error)))"
    }
#endif

    // MARK: - Stremio Addon Search

    @MainActor
    private func startStremioSearch() {
        let searchGeneration = manualSearchGeneration
        let active = stremioManager.activeAddons
        guard !active.isEmpty else {
            viewModel.isSearchingStremio = false
            return
        }

        guard shouldSearchStremio else {
            for addon in active {
                viewModel.stremioResults[addon.id] = []
                viewModel.stremioSearchedAddons.insert(addon.id)
            }
            viewModel.isSearchingStremio = false
            Logger.shared.log("Stremio: skipping special without TMDB episode mapping for title='\(displayTitle)'", type: "Stremio")
            return
        }

        viewModel.isSearchingStremio = true

        let type = isMovie ? "movie" : "series"
        // For anime, AniList restructuring remaps season/episode numbers.
        // Stremio addons index by the original TMDB numbering, so prefer those.
        let season = streamLookupSeasonNumber
        let episode = streamLookupEpisodeNumber

        Task {
            await stremioManager.fetchStreamsFromAddons(
                tmdbId: tmdbId,
                imdbId: imdbId,
                type: type,
                season: season,
                episode: episode,
                anilistId: stremioLookupAniListId,
                playbackContext: effectivePlaybackContext,
                titleCandidates: stremioCatalogTitleCandidates,
                onResult: { addon, streams in
                    Task { @MainActor in
                        guard self.isCurrentManualSearchGeneration(searchGeneration) else { return }
                        self.viewModel.stremioResults[addon.id] = self.filteredStremioStreams(streams, addon: addon)
                        self.viewModel.stremioSearchedAddons.insert(addon.id)
                    }
                },
                onComplete: {
                    Task { @MainActor in
                        guard self.isCurrentManualSearchGeneration(searchGeneration) else { return }
                        self.viewModel.isSearchingStremio = false
                    }
                }
            )
        }
    }

    // MARK: - Stremio Results Section

    @ViewBuilder
    private func stremioAddonSection(addon: StremioAddon) -> some View {
        let streams = visibleStremioStreams(for: addon)
        let hasSearched = viewModel.stremioSearchedAddons.contains(addon.id)
        let isCurrentlySearching = viewModel.isSearchingStremio && !hasSearched

        if viewModel.stremioResults[addon.id] != nil {
            Section(header: stremioAddonHeader(for: addon, streamCount: streams.count, isSearching: false)) {
                healthWarningRow(sourceId: SourceHealth.stremioId(addon))
                if streams.isEmpty {
                    noResultsRow
                } else {
                    stremioMediaRow(streams: streams, addon: addon)
                }
            }
        } else if isCurrentlySearching {
            Section(header: stremioAddonHeader(for: addon, streamCount: 0, isSearching: true)) {
                healthWarningRow(sourceId: SourceHealth.stremioId(addon))
                searchingRow
            }
        } else if !viewModel.isSearchingStremio && !hasSearched {
            Section(header: stremioAddonHeader(for: addon, streamCount: 0, isSearching: false)) {
                healthWarningRow(sourceId: SourceHealth.stremioId(addon))
                notSearchedRow
            }
        }
    }

    @ViewBuilder
    private func stremioAddonHeader(for addon: StremioAddon, streamCount: Int, isSearching: Bool) -> some View {
        HStack {
            if let logo = addon.manifest.logo, let logoURL = URL(string: logo) {
                KFImage(logoURL)
                    .placeholder {
                        Image(systemName: "play.circle")
                            .foregroundColor(.secondary)
                    }
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "play.circle")
                    .foregroundColor(.secondary)
                    .frame(width: 20, height: 20)
            }

            Text(addon.manifest.name)
                .font(.subheadline)
                .fontWeight(.medium)

            if healthStore.warningText(for: SourceHealth.stremioId(addon)) != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.caption)
                    .padding(.leading, 4)
            }

            Spacer()

            if isSearching {
                EclipseLoadingIndicator()
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            } else if streamCount > 0 {
                Text("\(streamCount)")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.2))
                    .foregroundColor(.green)
                    .cornerRadius(4)
            }
        }
    }

    @ViewBuilder
    private func stremioMediaRow(streams: [StremioStream], addon: StremioAddon) -> some View {
        Button(action: {
            if streams.count == 1, let stream = streams.first {
                viewModel.selectedStremioStream = stream
                viewModel.selectedStremioAddon = addon
                viewModel.showingStremioPlayAlert = true
            } else {
                viewModel.stremioStreamOptions = streams
                viewModel.selectedStremioAddon = addon
                viewModel.showingStremioStreamPicker = true
            }
        }) {
            HStack(spacing: 12) {
                KFImage(resolvedPosterURL.flatMap { URL(string: $0) })
                    .placeholder {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.2))
                            .overlay(
                                Image(systemName: "photo")
                                    .font(.title2)
                                    .foregroundColor(.gray)
                            )
                    }
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 70, height: 95)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 8) {
                    Text(displayTitle)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundColor(.primary)

                    if let episode = selectedEpisode {
                        HStack {
                            Image(systemName: "tv")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Text("Episode \(episode.episodeNumber)")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if !episode.name.isEmpty {
                                Text("• \(episode.name)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }

                    HStack {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)

                            Text("\(streams.count) stream\(streams.count == 1 ? "" : "s")")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundColor(.green)
                        }

                        Spacer()

                        Image(systemName: "play.circle.fill")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                    }
                }

                Spacer()
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(PlainButtonStyle())
    }

    @ViewBuilder
    private var stremioStreamPickerContent: some View {
        if let addon = viewModel.selectedStremioAddon,
           let streamOptions = viewModel.stremioStreamOptions {
            let streams = filteredStremioStreams(streamOptions, addon: addon)
            ForEach(Array(streams.prefix(Self.maxVisibleStremioStreamsPerAddon))) { stream in
                Button {
                    viewModel.showingStremioStreamPicker = false
                    playStremioStream(stream, addon: addon, autoModeLaunch: viewModel.pendingPlaybackAutoMode)
                } label: {
                    Text(stremioStreamLabel(for: stream))
                }
            }
            if streams.count > Self.maxVisibleStremioStreamsPerAddon {
                Text("Showing the first \(Self.maxVisibleStremioStreamsPerAddon) ranked streams.")
                    .foregroundStyle(.secondary)
            }
        }
        Button("Cancel", role: .cancel) {
            viewModel.stremioStreamOptions = nil
            viewModel.selectedStremioAddon = nil
            viewModel.pendingPlaybackAutoMode = false
        }
    }

    @ViewBuilder
    private var stremioStreamPickerMessage: some View {
        Text("Choose a stream to \(actionVerb.lowercased())")
    }

    private func stremioStreamLabel(for stream: StremioStream) -> String {
        AutoModeStreamSelection.stremioStreamLabel(for: stream)
    }

    private func smartPlayerMetadata(for stream: StremioStream) -> String {
        AutoModeStreamSelection.smartPlayerMetadata(for: stream)
    }

#if os(iOS) && !targetEnvironment(macCatalyst)
    // MARK: - SkyStream Results

    @ViewBuilder
    private func skyStreamSection(provider: SkyStreamProviderDescriptor) -> some View {
        let streams = visibleSkyStreamOptions(for: provider)
        let hasSearched = skyStreamSearchedSourceIds.contains(provider.id)
        let isSearching = skyStreamSearchingSourceIds.contains(provider.id)

        Section(header: skyStreamHeader(for: provider, streamCount: streams.count, isSearching: isSearching)) {
            healthWarningRow(sourceId: provider.id)
            // The fast phase can legitimately find nothing while the bounded full phase is still
            // checking lower-ranked candidates. Do not flash a false final "No results" state.
            if isSearching && streams.isEmpty {
                searchingRow
            } else if hasSearched {
                if streams.isEmpty {
                    noResultsRow
                } else {
                    skyStreamMediaRow(streams: streams, provider: provider)
                }
            } else {
                notSearchedRow
            }
        }
    }

    private func skyStreamHeader(
        for provider: SkyStreamProviderDescriptor,
        streamCount: Int,
        isSearching: Bool
    ) -> some View {
        HStack {
            Image(systemName: "shippingbox")
                .foregroundColor(.secondary)
                .frame(width: 20, height: 20)

            Text(provider.displayName)
                .font(.subheadline)
                .fontWeight(.medium)

            if healthStore.warningText(for: provider.id) != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.caption)
                    .padding(.leading, 4)
            }

            Spacer()

            if isSearching {
                EclipseLoadingIndicator()
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            } else if streamCount > 0 {
                Text("\(streamCount)")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.2))
                    .foregroundColor(.green)
                    .cornerRadius(4)
            }
        }
    }

    private func skyStreamMediaRow(
        streams: [ValidatedSkyStreamOption],
        provider: SkyStreamProviderDescriptor
    ) -> some View {
        Button {
            if streams.count == 1, let stream = streams.first {
                selectSkyStreamForConfirmation(stream, provider: provider)
            } else {
                selectedSkyStreamProvider = provider
                skyStreamPickerOptions = streams
                showingSkyStreamPicker = true
            }
        } label: {
            HStack(spacing: 12) {
                KFImage(resolvedPosterURL.flatMap { URL(string: $0) })
                    .placeholder {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.2))
                            .overlay(
                                Image(systemName: "photo")
                                    .font(.title2)
                                    .foregroundColor(.gray)
                            )
                    }
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 70, height: 95)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 8) {
                    Text(displayTitle)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundColor(.primary)

                    if let episode = selectedEpisode {
                        Text("Episode \(episode.episodeNumber)\(episode.name.isEmpty ? "" : " • \(episode.name)")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    HStack {
                        Text("\(streams.count) verified VOD stream\(streams.count == 1 ? "" : "s")")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.green)
                        Spacer()
                        Image(systemName: "play.circle.fill")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    private func stremioStyleSkyStreamRow(
        _ stream: ValidatedSkyStreamOption,
        provider: SkyStreamProviderDescriptor
    ) -> some View {
        Button {
            selectSkyStreamForConfirmation(stream, provider: provider)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                stremioStyleActionIcon
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(provider.displayName) · \(stream.option.name)")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(displayTitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("Verified VOD")
                        .font(.caption)
                        .foregroundColor(.green)
                }
                Spacer(minLength: 0)
            }
            .stremioStyleStreamCard()
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .eclipseHideListRowSeparator()
        .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
    }

    @MainActor
    private func selectSkyStreamForConfirmation(
        _ stream: ValidatedSkyStreamOption,
        provider: SkyStreamProviderDescriptor
    ) {
        // Re-check visibility at the selection boundary. Extra Source Settings can change while
        // a result sheet remains open in another window.
        guard visibleSkyStreamOptions(for: provider).contains(where: { $0.id == stream.id }) else {
            viewModel.streamError = "This stream is hidden by your Extra Source Settings."
            viewModel.showingStreamError = true
            return
        }
        selectedSkyStreamOption = stream
        selectedSkyStreamProvider = provider
        showingSkyStreamPlayAlert = true
    }

    @ViewBuilder
    private var skyStreamPickerContent: some View {
        if let provider = selectedSkyStreamProvider {
            let visible = visibleSkyStreamOptions(for: provider)
            let allowedIDs = Set(skyStreamPickerOptions.map(\.id))
            ForEach(visible.filter { allowedIDs.contains($0.id) }) { stream in
                Button(stream.option.name) {
                    showingSkyStreamPicker = false
                    if viewModel.pendingPlaybackAutoMode {
                        autoModeCancelled = false
                    }
                    playSkyStream(
                        stream,
                        provider: provider,
                        autoModeLaunch: viewModel.pendingPlaybackAutoMode,
                        retryCount: viewModel.pendingPlaybackRetryCount
                    )
                }
            }
        }
        Button("Cancel", role: .cancel) {
            let wasAutoModeChoice = viewModel.pendingPlaybackAutoMode
            showingSkyStreamPicker = false
            selectedSkyStreamProvider = nil
            skyStreamPickerOptions = []
            viewModel.pendingPlaybackAutoMode = false
            if wasAutoModeChoice && autoModeOnly && !showManualPicker {
                showAutoModeFailure("Auto Mode needs you to choose a SkyStream quality before it can continue.")
            }
        }
    }

    @ViewBuilder
    private var skyStreamPickerMessage: some View {
        Text("Choose a verified VOD stream to \(actionVerb.lowercased())")
    }

    @MainActor
    private func handleSkyStreamPlaybackPreparationFailure(
        _ provider: SkyStreamProviderDescriptor,
        message: String,
        autoModeLaunch: Bool
    ) {
        if shouldRetryNextAutoModeSource(autoModeLaunch: autoModeLaunch) {
            retryNextAutoModeSource(sourceName: provider.displayName, message: message)
            return
        }
        viewModel.isFetchingStreams = false
        viewModel.streamError = message
        viewModel.showingStreamError = true
    }

    /// SkyStream playback accepts only a validator-issued descriptor and a URL manufactured by
    /// the typed local proxy. Raw plugin URLs and headers have no route into this function.
    @MainActor
    private func playSkyStream(
        _ selectedStream: ValidatedSkyStreamOption,
        provider: SkyStreamProviderDescriptor,
        autoModeLaunch: Bool = false,
        retryCount: Int = 0
    ) {
        guard isSheetActive,
              forcedWatchTogetherMediaIsCurrent(),
              playbackRecoveryIdentityIsCurrent else { return }

        // Rebind by stable row identity so a confirmation alert opened during the fast phase
        // cannot launch that phase's older signed headers after the full phase refreshes them.
        guard let stream = visibleSkyStreamOptions(for: provider).first(where: {
            $0.id == selectedStream.id
        }) else {
            handleSkyStreamPlaybackPreparationFailure(
                provider,
                message: "This SkyStream result is no longer available under your Extra Source Settings.",
                autoModeLaunch: autoModeLaunch
            )
            return
        }

        guard !downloadMode else {
            downloadSkyStream(stream, provider: provider, autoModeLaunch: autoModeLaunch)
            return
        }

        viewModel.resetStreamState()

        let playbackTraceID = String(UUID().uuidString.prefix(8))
        let playbackTraceCreatedAt = Date()
        guard let streamURL = MPVHeaderProxy.shared.makeSkyStreamProxyURL(
            for: stream.resolved.playback,
            traceID: playbackTraceID
        ) else {
            Logger.shared.log(
                "SkyStream: typed proxy translation failed sourceID=\(provider.id)",
                type: "SkyStream"
            )
            handleSkyStreamPlaybackPreparationFailure(
                provider,
                message: "The verified SkyStream could not be prepared for local playback.",
                autoModeLaunch: autoModeLaunch
            )
            return
        }

        let descriptor = stream.resolved.playback
        guard let subtitleProxyURLs = MPVHeaderProxy.shared.skyStreamSubtitleProxyURLs(
            for: descriptor,
            streamProxyURL: streamURL
        ) else {
            MPVHeaderProxy.shared.invalidateSession(for: streamURL)
            handleSkyStreamPlaybackPreparationFailure(
                provider,
                message: "The verified SkyStream subtitles could not be attached safely.",
                autoModeLaunch: autoModeLaunch
            )
            return
        }
        var subtitleURLs: [String] = []
        for subtitle in descriptor.subtitles {
            guard let proxyURL = subtitleProxyURLs[subtitle.remoteURL.url.absoluteString] else {
                MPVHeaderProxy.shared.invalidateSession(for: streamURL)
                handleSkyStreamPlaybackPreparationFailure(
                    provider,
                    message: "The verified SkyStream subtitle route changed before playback.",
                    autoModeLaunch: autoModeLaunch
                )
                return
            }
            subtitleURLs.append(proxyURL.absoluteString)
        }
        let subtitleNames = descriptor.subtitles.map {
            $0.label ?? $0.language ?? "Subtitle"
        }
        // The typed proxy owns upstream headers. Passing them to MPV would send credentials to
        // the loopback origin and duplicate policy outside the descriptor's route whitelist.
        // Subtitle routes use that same immutable session and therefore carry no player headers.
        let playerHeaders: [String: String] = [:]

        let playbackPlan = PlaybackLaunchPlan.make(
            // SkyStream's immutable route graph lives in Eclipse's in-process MPV proxy. Keep
            // the session in-process instead of handing its loopback URL to AVPlayer/external
            // selection paths that cannot safely adopt the route graph.
            selection: .mpv,
            deviceFamily: .current
        )
        Logger.shared.log(
            "Playback resolve diagnostics sourceID=\(provider.id) kind=skystream player=\(playbackPlan.primary.rawValue) media=\(descriptor.mediaKind.rawValue) subtitles=\(subtitleURLs.count) autoMode=\(autoModeLaunch) retry=\(retryCount)",
            type: "StreamDiagnostics"
        )
        Logger.shared.log(
            "[PlaybackTrace \(playbackTraceID)] stage=resolved sourceID=\(provider.id) kind=skystream autoMode=\(autoModeLaunch) retry=\(retryCount)",
            type: "PlaybackTrace"
        )

        let contentReference = ProviderContentReference.skyStream(stream.resolved.contentReference)
        if isMovie {
            ProgressManager.shared.recordMovieSourceInfo(
                movieId: tmdbId,
                sourceId: provider.id,
                reference: contentReference
            )
        } else if let episode = selectedEpisode {
            ProgressManager.shared.recordEpisodeSourceInfo(
                showId: tmdbId,
                seasonNumber: episode.seasonNumber,
                episodeNumber: episode.episodeNumber,
                sourceId: provider.id,
                reference: contentReference
            )
        }

        let posterURL = resolvedPosterURL
        let playerMediaInfo: MediaInfo? = {
            if isMovie {
                return .movie(
                    id: tmdbId,
                    title: playerMediaTitle,
                    posterURL: posterURL,
                    isAnime: isAnimeContent
                )
            }
            guard let episode = selectedEpisode else { return nil }
            return .episode(
                showId: tmdbId,
                seasonNumber: episode.seasonNumber,
                episodeNumber: episode.episodeNumber,
                showTitle: playerMediaTitle,
                showPosterURL: posterURL,
                isAnime: isAnimeContent
            )
        }()

        let resolvedSubtitleArray: [String]? = subtitleURLs.isEmpty ? nil : subtitleURLs
        let resolvedSubtitleNames: [String]? = subtitleNames.isEmpty ? nil : subtitleNames
        let resolvedSubtitleHeaders: [String: [String: String]]? = nil
        let resolvedPreset = PlayerPreset.presets.first
            ?? PlayerPreset(id: .sdrRec709, title: "Default", summary: "", stream: nil, commands: [])
        let launchContext = PlaybackLaunchContext(
            traceID: playbackTraceID,
            traceCreatedAt: playbackTraceCreatedAt,
            sourceId: provider.id,
            sourceName: provider.displayName,
            sourceKind: .skyStream,
            autoMode: autoModeLaunch,
            streamURL: streamURL.absoluteString,
            streamName: stream.option.name,
            headers: playerHeaders,
            subtitles: resolvedSubtitleArray ?? [],
            subtitleNames: resolvedSubtitleNames,
            subtitleHeadersByURL: resolvedSubtitleHeaders,
            retryCount: retryCount,
            titleCandidates: [skyStreamResolutionTarget.title] + skyStreamResolutionTarget.aliases,
            providerContentReference: contentReference
        )
        let resolvedAnimeHint = hasAnimeLookupContext

        if onResolvedPlaybackRequest != nil {
            guard playbackRecoveryIdentityIsCurrent else {
                MPVHeaderProxy.shared.invalidateSession(for: streamURL)
                Logger.shared.log(
                    "ServicesResultsSheet: discarded stale SkyStream resolution before caller handoff",
                    type: "Player"
                )
                return
            }
            let request = PlayerResolvedPlaybackRequest(
                url: streamURL,
                preset: resolvedPreset,
                headers: playerHeaders,
                subtitles: resolvedSubtitleArray,
                subtitleNames: resolvedSubtitleNames,
                subtitleHeadersByURL: resolvedSubtitleHeaders,
                mediaInfo: playerMediaInfo,
                imdbId: imdbId,
                isAnimeHint: resolvedAnimeHint,
                isAnimationContentHint: isAnimationGenre16,
                originalTMDBSeasonNumber: effectivePlaybackContext?.resolvedTMDBSeasonNumber ?? originalTMDBSeasonNumber,
                originalTMDBEpisodeNumber: effectivePlaybackContext?.resolvedTMDBEpisodeNumber ?? originalTMDBEpisodeNumber,
                episodePlaybackContext: effectivePlaybackContext,
                launchContext: launchContext,
                autoModeRecoveryIdentity: autoModeRecoveryIdentity,
                mediaYear: mediaYear
            )
            finishResolvedPlayback(request)
            return
        }

        presentCoordinatedPlayback(
            url: streamURL,
            preset: resolvedPreset,
            headers: playerHeaders,
            subtitles: resolvedSubtitleArray ?? [],
            subtitleNames: resolvedSubtitleNames,
            subtitleHeadersByURL: resolvedSubtitleHeaders,
            mediaInfo: playerMediaInfo,
            imdbID: imdbId,
            launchContext: launchContext,
            isAnime: resolvedAnimeHint,
            isAnimation: isAnimationGenre16,
            originalTMDBSeasonNumber: effectivePlaybackContext?.resolvedTMDBSeasonNumber ?? originalTMDBSeasonNumber,
            originalTMDBEpisodeNumber: effectivePlaybackContext?.resolvedTMDBEpisodeNumber ?? originalTMDBEpisodeNumber,
            sourceName: provider.displayName
        )
    }

    @MainActor
    private func downloadSkyStream(
        _ stream: ValidatedSkyStreamOption,
        provider: SkyStreamProviderDescriptor,
        autoModeLaunch: Bool
    ) {
        let displayDownloadTitle: String
        if isMovie {
            displayDownloadTitle = effectiveTitle
        } else if let episode = selectedEpisode {
            if specialTitleOnlySearch {
                displayDownloadTitle = animeSeasonTitle != nil ? animeEffectiveTitle : effectiveTitle
            } else if isAnimeContent || animeSeasonTitle != nil {
                displayDownloadTitle = "\(animeEffectiveTitle) E\(episode.episodeNumber)"
            } else {
                displayDownloadTitle = "\(effectiveTitle) S\(episode.seasonNumber)E\(episode.episodeNumber)"
            }
        } else {
            displayDownloadTitle = effectiveTitle
        }

        viewModel.resetStreamState()
        viewModel.isFetchingStreams = autoModeLaunch
        viewModel.currentFetchingTitle = provider.displayName
        viewModel.streamFetchProgress = "Preparing verified VOD download..."

        let result = DownloadManager.shared.enqueueValidatedSkyStreamDownload(
            tmdbId: tmdbId,
            isMovie: isMovie,
            title: playerMediaTitle,
            displayTitle: displayDownloadTitle,
            posterURL: resolvedPosterURL,
            seasonNumber: selectedEpisode?.seasonNumber,
            episodeNumber: selectedEpisode?.episodeNumber,
            episodeName: selectedEpisode?.name,
            resolved: stream.resolved,
            isAnime: isAnimeContent,
            episodePlaybackContext: effectivePlaybackContext,
            cancellationRequested: { autoModeLaunch && autoModeCancelled }
        )

        switch result {
        case .accepted:
            viewModel.isFetchingStreams = false
            Logger.shared.log(
                "SkyStream: verified VOD download enqueued sourceID=\(provider.id)",
                type: "Download"
            )
            onDownloadEnqueued?()
            presentationMode.wrappedValue.dismiss()
        case .invalid(let reason):
            handleSkyStreamPlaybackPreparationFailure(
                provider,
                message: "Download verification failed. \(reason)",
                autoModeLaunch: autoModeLaunch
            )
        case .cloudflareChallenge:
            // The typed SkyStream entry point never emits this today; retain a fail-closed case
            // so adding a new result path cannot accidentally enqueue an unvalidated fallback.
            handleSkyStreamPlaybackPreparationFailure(
                provider,
                message: "Download verification requires a fresh provider resolution.",
                autoModeLaunch: autoModeLaunch
            )
        case .cancelled:
            viewModel.isFetchingStreams = false
        }
    }
#endif

    // MARK: - Play / Download Stremio Stream

    private func playStremioStream(_ stream: StremioStream, addon: StremioAddon, autoModeLaunch: Bool = false, retryCount: Int = 0) {
        guard !StreamLanguageFilter.shouldHide(
            stremio: stream,
            sourceId: SourceHealth.stremioId(addon),
            originalAudioLanguage: originalAudioLanguage,
            isAnime: hasAnimeLookupContext
        ) else {
            Logger.shared.log("Stremio: stream hidden by extra service settings addon=\(addon.manifest.name)", type: "Stream")
            handleStremioPlaybackPreparationFailure(
                addon,
                message: "This Stremio stream is hidden by your Extra Source Settings.",
                autoModeLaunch: autoModeLaunch
            )
            return
        }

        // Keep playback HTTP-only.
        guard let urlString = stream.url, stream.isDirectHTTP else {
            Logger.shared.log("Stremio: rejected non-HTTP stream", type: "Error")
            handleStremioPlaybackPreparationFailure(
                addon,
                message: "Stremio addon returned a non-HTTP stream.",
                autoModeLaunch: autoModeLaunch
            )
            return
        }

        // Gather ALL subtitles from the stream (not just the first)
        let allSubtitles: [(url: String, name: String)] = (stream.subtitles ?? []).compactMap { sub in
            guard let url = sub.url, !url.isEmpty else { return nil }
            return (url: url, name: sub.playbackDisplayName)
        }
        let subtitleURLs = allSubtitles.map { $0.url }
        let subtitleNames = allSubtitles.map { $0.name }

        if downloadMode {
#if os(tvOS)
            handleStremioPlaybackPreparationFailure(
                addon,
                message: "Downloads are not available on Apple TV.",
                autoModeLaunch: autoModeLaunch
            )
#else
            downloadStremioStream(
                urlString,
                addon: addon,
                subtitle: subtitleURLs.first,
                headers: stream.proxyHeaders,
                autoModeLaunch: autoModeLaunch
            )
#endif
        } else {
            playStremioStreamURL(urlString, addon: addon, subtitles: subtitleURLs, subtitleNames: subtitleNames, headers: stream.proxyHeaders, streamName: smartPlayerMetadata(for: stream), autoModeLaunch: autoModeLaunch, retryCount: retryCount)
        }
    }

    private func playStremioStreamURL(_ url: String, addon: StremioAddon, subtitles: [String], subtitleNames: [String], headers: [String: String]?, streamName: String? = nil, autoModeLaunch: Bool = false, retryCount: Int = 0) {
        let playbackTraceID = String(UUID().uuidString.prefix(8))
        let playbackTraceCreatedAt = Date()
        viewModel.resetStreamState()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)

            guard !Task.isCancelled,
                  forcedWatchTogetherMediaIsCurrent() else { return }

            guard let streamURL = URL(string: url) else {
                Logger.shared.log("Invalid Stremio stream URL: \(ServiceSandboxState.redactedURL(url))", type: "Error")
                handleStremioPlaybackPreparationFailure(addon, message: "Invalid stream URL from Stremio addon.", autoModeLaunch: autoModeLaunch)
                return
            }

            // Keep playback HTTP-only.
            guard streamURL.scheme == "http" || streamURL.scheme == "https" else {
                Logger.shared.log("Stremio: non-HTTP scheme: \(streamURL.scheme ?? "nil")", type: "Error")
                handleStremioPlaybackPreparationFailure(addon, message: "Stremio addon returned a non-HTTP stream.", autoModeLaunch: autoModeLaunch)
                return
            }

#if !os(tvOS)
            let externalRaw = UserDefaults.standard.string(forKey: "externalPlayer") ?? ExternalPlayer.none.rawValue
            let external = ExternalPlayer(rawValue: externalRaw) ?? .none
            let schemeUrl = external.schemeURL(for: url)

            if !forceAutomaticPlayback,
               onResolvedPlaybackRequest == nil,
               let scheme = schemeUrl,
               UIApplication.shared.canOpenURL(scheme) {
                dismissAutoModeSheetBeforePlaybackIfNeeded { _ in
                    UIApplication.shared.open(scheme, options: [:], completionHandler: nil)
                    Logger.shared.log("Stremio: Opening external player", type: "General")
                }
                return
            }
#endif

            var finalHeaders: [String: String] = [
                "User-Agent": URLSession.randomUserAgent
            ]

            if let custom = headers {
                for (k, v) in custom {
                    finalHeaders[k] = v
                }
            }

            Logger.shared.log("Stremio: Final header keys: \(finalHeaders.keys.sorted())", type: "Stream")

            let playbackPlan = PlaybackLaunchPlan.make(
                selection: forceAutomaticPlayback ? .mpv : .selected,
                deviceFamily: .current
            )
            Logger.shared.log("Playback resolve diagnostics source=\(addon.manifest.name) kind=stremio player=\(playbackPlan.primary.rawValue) host=\(streamURL.host ?? "nil") ext=\(streamURL.pathExtension.isEmpty ? "none" : streamURL.pathExtension) namedStream=\(streamName?.isEmpty == false) headerKeys=[\(finalHeaders.keys.sorted().joined(separator: ","))] subtitles=\(subtitles.count) autoMode=\(autoModeLaunch)", type: "StreamDiagnostics")
            Logger.shared.log("[PlaybackTrace \(playbackTraceID)] stage=resolved source=\(addon.manifest.name) kind=stremio player=\(playbackPlan.primary.rawValue) host=\(streamURL.host ?? "nil") autoMode=\(autoModeLaunch) retry=\(retryCount)", type: "PlaybackTrace")

            var playerMediaInfo: MediaInfo? = nil
            let posterURL = resolvedPosterURL
            if isMovie {
                playerMediaInfo = .movie(id: tmdbId, title: playerMediaTitle, posterURL: posterURL, isAnime: isAnimeContent)
            } else if let episode = selectedEpisode {
                playerMediaInfo = .episode(showId: tmdbId, seasonNumber: episode.seasonNumber, episodeNumber: episode.episodeNumber, showTitle: playerMediaTitle, showPosterURL: posterURL, isAnime: isAnimeContent)
            }

            let resolvedSubtitleArray: [String]? = subtitles.isEmpty ? nil : subtitles
            let resolvedPreset = PlayerPreset.presets.first ?? PlayerPreset(id: .sdrRec709, title: "Default", summary: "", stream: nil, commands: [])
            let resolvedLaunchContext = PlaybackLaunchContext(
                traceID: playbackTraceID,
                traceCreatedAt: playbackTraceCreatedAt,
                sourceId: SourceHealth.stremioId(addon),
                sourceName: addon.manifest.name,
                sourceKind: .stremio,
                autoMode: autoModeLaunch,
                streamURL: url,
                streamName: streamName,
                headers: finalHeaders,
                subtitles: resolvedSubtitleArray ?? [],
                subtitleNames: subtitleNames,
                retryCount: retryCount,
                titleCandidates: stremioCatalogTitleCandidates
            )
            let resolvedAnimeHint = hasAnimeLookupContext

            if onResolvedPlaybackRequest != nil {
                guard playbackRecoveryIdentityIsCurrent else {
                    Logger.shared.log("ServicesResultsSheet: discarded stale Stremio resolution before caller handoff", type: "Player")
                    return
                }
                let request = PlayerResolvedPlaybackRequest(
                    url: streamURL,
                    preset: resolvedPreset,
                    headers: finalHeaders,
                    subtitles: resolvedSubtitleArray,
                    subtitleNames: subtitleNames.isEmpty ? nil : subtitleNames,
                    mediaInfo: playerMediaInfo,
                    imdbId: imdbId,
                    isAnimeHint: resolvedAnimeHint,
                    isAnimationContentHint: isAnimationGenre16,
                    originalTMDBSeasonNumber: effectivePlaybackContext?.resolvedTMDBSeasonNumber ?? originalTMDBSeasonNumber,
                    originalTMDBEpisodeNumber: effectivePlaybackContext?.resolvedTMDBEpisodeNumber ?? originalTMDBEpisodeNumber,
                    episodePlaybackContext: effectivePlaybackContext,
                    launchContext: resolvedLaunchContext,
                    autoModeRecoveryIdentity: autoModeRecoveryIdentity,
                    mediaYear: mediaYear
                )
                finishResolvedPlayback(request)
                return
            }

            presentCoordinatedPlayback(
                url: streamURL,
                preset: resolvedPreset,
                headers: finalHeaders,
                subtitles: resolvedSubtitleArray ?? [],
                subtitleNames: subtitleNames.isEmpty ? nil : subtitleNames,
                subtitleHeadersByURL: nil,
                mediaInfo: playerMediaInfo,
                imdbID: imdbId,
                launchContext: resolvedLaunchContext,
                isAnime: resolvedAnimeHint,
                isAnimation: isAnimationGenre16,
                originalTMDBSeasonNumber: effectivePlaybackContext?.resolvedTMDBSeasonNumber ?? originalTMDBSeasonNumber,
                originalTMDBEpisodeNumber: effectivePlaybackContext?.resolvedTMDBEpisodeNumber ?? originalTMDBEpisodeNumber,
                sourceName: addon.manifest.name
            )
            return
        }
    }

    @MainActor
    private func presentCoordinatedPlayback(
        url: URL,
        preset: PlayerPreset,
        headers: [String: String],
        subtitles: [String],
        subtitleNames: [String]?,
        subtitleHeadersByURL: [String: [String: String]]?,
        mediaInfo: MediaInfo?,
        imdbID: String?,
        launchContext: PlaybackLaunchContext,
        isAnime: Bool,
        isAnimation: Bool,
        originalTMDBSeasonNumber: Int?,
        originalTMDBEpisodeNumber: Int?,
        sourceName: String
    ) {
        guard forcedWatchTogetherMediaIsCurrent(),
              playbackRecoveryIdentityIsCurrent else {
            invalidateAbandonedSkyStreamProxy(url, launchContext: launchContext)
            return
        }
        let resumePosition: Double? = {
            let position: Double
            if isMovie {
                position = ProgressManager.shared.getMovieCurrentTime(movieId: tmdbId, title: playerMediaTitle)
            } else if let episode = selectedEpisode {
                position = ProgressManager.shared.getEpisodeCurrentTime(
                    showId: tmdbId,
                    seasonNumber: episode.seasonNumber,
                    episodeNumber: episode.episodeNumber
                )
            } else {
                position = 0
            }
            return position > 0 && position.isFinite ? position : nil
        }()

        let episodeSubtitle: String? = {
            guard let episode = selectedEpisode else { return nil }
            let number = specialTitleOnlySearch
                ? "Special"
                : (isAnimeContent || animeSeasonTitle != nil)
                    ? "Episode \(episode.episodeNumber)"
                    : "Season \(episode.seasonNumber), Episode \(episode.episodeNumber)"
            guard !episode.name.isEmpty else { return number }
            return "\(number) · \(episode.name)"
        }()

        let requestedTMDBID = tmdbId
        let nextEpisodeRequest: ((_ seasonNumber: Int, _ episodeNumber: Int) -> Void)? = isMovie ? nil : { seasonNumber, nextEpisodeNumber in
            var userInfo: [String: Any] = [
                "tmdbId": requestedTMDBID,
                "seasonNumber": seasonNumber,
                "episodeNumber": nextEpisodeNumber
            ]
            if forceAutomaticPlayback {
                userInfo["watchTogether"] = true
            }
            NotificationCenter.default.post(
                name: .requestNextEpisode,
                object: nextEpisodeNotificationRoute,
                userInfo: userInfo
            )
        }
        let resolvedNextEpisodeRequest: ((ResolvedNextEpisodeTarget) -> Void)? = isMovie ? nil : { target in
            var userInfo: [String: Any] = [
                "tmdbId": target.showID,
                "seasonNumber": target.episode.seasonNumber,
                "episodeNumber": target.episode.episodeNumber,
                "isAnime": target.isAnime,
                "exactTarget": true
            ]
            if let playbackContext = target.playbackContext {
                userInfo["playbackContext"] = playbackContext
            }
            userInfo["resolvedTarget"] = target
            if forceAutomaticPlayback {
                userInfo["watchTogether"] = true
            }
            NotificationCenter.default.post(
                name: .requestNextEpisode,
                object: nextEpisodeNotificationRoute,
                userInfo: userInfo
            )
        }

        let recoveryIdentity = autoModeRecoveryIdentity
        let recoveryCallback = onAutoModePlaybackFailure
        let request = PlaybackRequest(
            url: url,
            preset: preset,
            headers: headers,
            subtitles: subtitles,
            subtitleNames: subtitleNames,
            subtitleHeadersByURL: subtitleHeadersByURL,
            mediaInfo: mediaInfo,
            mediaYear: mediaYear,
            imdbID: imdbID,
            episodePlaybackContext: effectivePlaybackContext,
            launchContext: launchContext,
            resumePosition: resumePosition,
            title: playerMediaTitle,
            subtitle: episodeSubtitle,
            artworkURL: resolvedPosterURL.flatMap(URL.init(string:)),
            isAnime: isAnime,
            isAnimation: isAnimation,
            originalTMDBSeasonNumber: originalTMDBSeasonNumber,
            originalTMDBEpisodeNumber: originalTMDBEpisodeNumber,
            servicesOriginalTitle: originalTitle,
            servicesOriginalAudioLanguage: originalAudioLanguage,
            onRequestNextEpisode: nextEpisodeRequest,
            onRequestResolvedNextEpisode: resolvedNextEpisodeRequest,
            onPlaybackStartupFailure: { report in
                Task { @MainActor in
                    if report.context.autoMode,
                       let recoveryIdentity,
                       let recoveryCallback {
                        recoveryCallback(report, recoveryIdentity)
                    } else {
                        handlePlaybackStartupFailure(report)
                    }
                }
            }
        )

        let diagnosticSource = launchContext.sourceKind == .skyStream
            ? launchContext.sourceId
            : sourceName
        Logger.shared.log(
            "ServicesResultsSheet: presenting coordinated playback source=\(diagnosticSource) subtitles=\(subtitles.count) resume=\(resumePosition != nil)",
            type: "Player"
        )
        dismissAutoModeSheetBeforePlaybackIfNeeded { topmostVC in
            guard self.forcedWatchTogetherSharedMediaMatchesCurrent(),
                  self.playbackRecoveryIdentityIsCurrent else {
                self.invalidateAbandonedSkyStreamProxy(url, launchContext: launchContext)
                return
            }
            guard let topmostVC else {
                self.invalidateAbandonedSkyStreamProxy(url, launchContext: launchContext)
                let report = PlaybackFailureReport(
                    context: launchContext,
                    message: "Failed to locate the originating window for player presentation.",
                    isSourceFailure: false
                )
                if launchContext.autoMode,
                   let recoveryIdentity,
                   let recoveryCallback {
                    recoveryCallback(report, recoveryIdentity)
                } else {
                    self.viewModel.streamError = "Failed to open player. Please try again."
                    self.viewModel.showingStreamError = true
                }
                Logger.shared.log("ServicesResultsSheet: no presenter for coordinated playback", type: "Error")
                return
            }
            PlaybackCoordinator.shared.present(
                request,
                from: topmostVC,
                engine: launchContext.sourceKind == .skyStream
                    ? .mpv
                    : (forceAutomaticPlayback ? .mpv : .selected)
            )
        }
    }

#if !os(tvOS)
    private func downloadStremioStream(_ url: String, addon: StremioAddon, subtitle: String?, headers: [String: String]?, autoModeLaunch: Bool = false) {
        // Keep downloads HTTP-only.
        guard let parsed = URL(string: url),
              parsed.scheme == "http" || parsed.scheme == "https" else {
            Logger.shared.log("Stremio: non-HTTP download URL rejected", type: "Error")
            handleStremioPlaybackPreparationFailure(
                addon,
                message: "Stremio addon returned a non-HTTP download stream.",
                autoModeLaunch: autoModeLaunch
            )
            return
        }

        viewModel.resetStreamState()

        var finalHeaders: [String: String] = [
            "User-Agent": URLSession.randomUserAgent
        ]

        if let custom = headers {
            for (k, v) in custom {
                finalHeaders[k] = v
            }
        }

        let posterURL = resolvedPosterURL

        let displayTitle: String
        if isMovie {
            displayTitle = effectiveTitle
        } else if let ep = selectedEpisode {
            if specialTitleOnlySearch {
                displayTitle = animeSeasonTitle != nil ? animeEffectiveTitle : effectiveTitle
            } else if isAnimeContent || animeSeasonTitle != nil {
                displayTitle = "\(animeEffectiveTitle) E\(ep.episodeNumber)"
            } else {
                displayTitle = "\(effectiveTitle) S\(ep.seasonNumber)E\(ep.episodeNumber)"
            }
        } else {
            displayTitle = effectiveTitle
        }

        if autoModeLaunch {
            viewModel.isFetchingStreams = true
            viewModel.currentFetchingTitle = addon.manifest.name
            viewModel.streamFetchProgress = "Checking download stream..."
            cancelAutoModeDownloadValidation()
            autoModeDownloadTask = Task { @MainActor in
                let result = await DownloadManager.shared.enqueueValidatedAutoModeDownload(
                    tmdbId: tmdbId,
                    isMovie: isMovie,
                    title: playerMediaTitle,
                    displayTitle: displayTitle,
                    posterURL: posterURL,
                    seasonNumber: selectedEpisode?.seasonNumber,
                    episodeNumber: selectedEpisode?.episodeNumber,
                    episodeName: selectedEpisode?.name,
                    streamURL: url,
                    headers: finalHeaders,
                    subtitleURL: subtitle,
                    serviceBaseURL: addon.configuredURL,
                    isAnime: isAnimeContent,
                    episodePlaybackContext: effectivePlaybackContext,
                    cancellationRequested: { autoModeCancelled }
                )

                switch result {
                case .accepted:
                    viewModel.isFetchingStreams = false
                    Logger.shared.log("Stremio: Auto Mode download verified and enqueued: \(displayTitle)", type: "Download")
                    onDownloadEnqueued?()
                    presentationMode.wrappedValue.dismiss()
                case .invalid(let reason):
                    handleStremioPlaybackPreparationFailure(
                        addon,
                        message: "Download verification failed. \(reason)",
                        autoModeLaunch: true
                    )
                case .cloudflareChallenge(let challengeURL):
                    viewModel.pendingCloudflareURL = challengeURL
                    viewModel.pendingCloudflareRetry = {
                        self.downloadStremioStream(
                            url,
                            addon: addon,
                            subtitle: subtitle,
                            headers: headers,
                            autoModeLaunch: true
                        )
                    }
                    resolveCloudflareChallengeDuringAutoMode(
                        challengeURL,
                        sourceName: addon.manifest.name,
                        fallbackMessage: "Download verification failed. Cloudflare verification is required before this source can download."
                    )
                case .cancelled:
                    viewModel.isFetchingStreams = false
                }
            }
            return
        }

        DownloadManager.shared.enqueueDownload(
            tmdbId: tmdbId,
            isMovie: isMovie,
            title: playerMediaTitle,
            displayTitle: displayTitle,
            posterURL: posterURL,
            seasonNumber: selectedEpisode?.seasonNumber,
            episodeNumber: selectedEpisode?.episodeNumber,
            episodeName: selectedEpisode?.name,
            streamURL: url,
            headers: finalHeaders,
            subtitleURL: subtitle,
            serviceBaseURL: addon.configuredURL,
            isAnime: isAnimeContent,
            episodePlaybackContext: effectivePlaybackContext
        )

        Logger.shared.log("Stremio: Download enqueued: \(displayTitle)", type: "Download")

        onDownloadEnqueued?()
        presentationMode.wrappedValue.dismiss()
    }
#endif

    @ViewBuilder
    private func serviceHeader(for service: Service, highQualityCount: Int, lowQualityCount: Int, isSearching: Bool = false) -> some View {
        HStack {
            KFImage(URL(string: service.metadata.iconUrl))
                .placeholder {
                    Image(systemName: "tv.circle")
                        .foregroundColor(.secondary)
                }
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
            
            Text(service.metadata.sourceName)
                .font(.subheadline)
                .fontWeight(.medium)
            
            if viewModel.failedServices.contains(service.id) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.leading, 6)
            }

            if healthStore.warningText(for: SourceHealth.serviceId(service)) != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.caption)
                    .padding(.leading, 4)
            }
            
            Spacer()
            
            HStack(spacing: 4) {
                if isSearching {
                    EclipseLoadingIndicator()
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                } else {
                    if highQualityCount > 0 {
                        Text("\(highQualityCount)")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .foregroundColor(.green)
                            .cornerRadius(4)
                    }
                    
                    if lowQualityCount > 0 {
                        Text("\(lowQualityCount)")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundColor(.orange)
                            .cornerRadius(4)
                    }
                }
            }
        }
    }
    
    private func proceedWithSelectedEpisode(_ episode: EpisodeLink) {
        viewModel.showingEpisodePicker = false
        
        guard let jsController = viewModel.pendingJSController,
              let service = viewModel.pendingService else {
            Logger.shared.log("Missing controller or service for episode selection", type: "Error")
            viewModel.resetPickerState()
            return
        }
        
        viewModel.isFetchingStreams = true
        viewModel.streamFetchProgress = "Fetching selected episode stream..."
        
        fetchStreamForEpisode(episode.href, jsController: jsController, service: service)
    }
    
    /// Attributes a just-finished service request's result to an unresolved Cloudflare challenge,
    /// if that's what actually happened. `pendingVerificationURL` is shared, process-wide state
    /// on `CloudflareBypassManager`, so this only accepts it as "caused by this request" when
    /// its host matches what we just requested, or it's newly set since this request began —
    /// otherwise a stale flag from an unrelated earlier failure could misattribute this one.
    @MainActor
    @discardableResult
    private func updatePendingCloudflareVerification(
        requestURLString: String,
        hostBefore: String?,
        retry: @escaping () -> Void
    ) -> Bool {
        // Clear on every attempt so a resolved/unrelated earlier flag doesn't linger once this
        // attempt's own outcome is known.
        viewModel.pendingCloudflareURL = nil
        viewModel.pendingCloudflareRetry = nil

        guard let pendingURL = CloudflareBypassManager.shared.pendingVerificationURL else { return false }
        let requestHost = URL(string: requestURLString)?.host?.lowercased()
        let pendingHost = pendingURL.host?.lowercased()
        guard pendingHost != nil, pendingHost == requestHost || pendingHost != hostBefore else { return false }

        viewModel.pendingCloudflareURL = pendingURL
        viewModel.pendingCloudflareRetry = retry
        return true
    }

    /// Opens the Cloudflare verification sheet for `viewModel.pendingCloudflareURL` and, on
    /// success, retries whichever fetch flagged it. tvOS deliberately has no browser-backed
    /// bypass (CloudflareBypassManager has no visible `triggerBypass` there), so this — and the
    /// "Verify Cloudflare" action that calls it — only exists on platforms that can show it.
    #if !os(tvOS)
    @MainActor
    private func verifyPendingCloudflareChallenge() {
        guard let url = viewModel.pendingCloudflareURL else { return }
        let retry = viewModel.pendingCloudflareRetry
        viewModel.streamError = nil
        viewModel.pendingCloudflareURL = nil
        viewModel.pendingCloudflareRetry = nil
        Task { @MainActor in
            do {
                try await CloudflareBypassManager.shared.triggerBypass(for: url)
                retry?()
            } catch {
                Logger.shared.log("Cloudflare verification did not complete: \(error.localizedDescription)", type: "Service")
            }
        }
    }

    /// Auto Mode's equivalent of `verifyPendingCloudflareChallenge`: instead of waiting for a
    /// tap, it shows the sheet right away and retries THIS source on success. Only falls back
    /// to `retryNextAutoModeSource` (skipping to the next candidate) if verification itself
    /// fails or the user cancels it — never silently swaps sources just to avoid the sheet.
    @MainActor
    private func resolveCloudflareChallengeDuringAutoMode(
        _ url: URL,
        sourceName: String,
        fallbackMessage: String
    ) {
        let retry = viewModel.pendingCloudflareRetry
        viewModel.pendingCloudflareURL = nil
        viewModel.pendingCloudflareRetry = nil
        updateAutoModeSourceStatus(sourceName: sourceName, message: "\(sourceName) needs a quick Cloudflare check.")
        Task { @MainActor in
            do {
                try await CloudflareBypassManager.shared.triggerBypass(for: url)
                retry?()
            } catch {
                Logger.shared.log("Auto Mode Cloudflare verification did not complete for \(sourceName): \(error.localizedDescription)", type: "Service")
                guard !autoModeCancelled else { return }
                retryNextAutoModeSource(sourceName: sourceName, message: fallbackMessage)
            }
        }
    }
    #endif

    private func fetchStreamForEpisode(_ episodeHref: String, jsController: JSController, service: Service) {
        let softsub = service.metadata.softsub ?? false
        let cloudflareHostBefore = CloudflareBypassManager.shared.pendingVerificationURL?.host?.lowercased()
        serviceStreamExtractionRequest?.cancel()
        let extractionGeneration = UUID()
        serviceStreamExtractionGeneration = extractionGeneration
        serviceStreamExtractionRequest = jsController.fetchStreamUrlJS(episodeUrl: episodeHref, softsub: softsub, module: service) { streamResult in
            Task { @MainActor in
                guard self.serviceStreamExtractionGeneration == extractionGeneration else { return }
                self.serviceStreamExtractionRequest = nil
                self.serviceStreamExtractionGeneration = nil
                let (streams, subtitles, sources) = streamResult

                Logger.shared.log("Stream fetch result - Streams: \(streams?.count ?? 0), Sources: \(sources?.count ?? 0)", type: "Stream")
                self.viewModel.streamFetchProgress = "Processing stream data..."

                let requiresCloudflareVerification = self.updatePendingCloudflareVerification(
                    requestURLString: episodeHref,
                    hostBefore: cloudflareHostBefore,
                    retry: {
                        self.fetchStreamForEpisode(episodeHref, jsController: jsController, service: service)
                    }
                )

                guard !requiresCloudflareVerification else {
                    Logger.shared.log(
                        "Blocked service stream result while Cloudflare verification is pending service=\(service.metadata.sourceName)",
                        type: "Service"
                    )
                    self.handleServicePlaybackPreparationFailure(
                        service,
                        message: "Cloudflare verification is required before this source can load the selected stream."
                    )
                    return
                }

#if os(tvOS)
                // Apple TV retains its existing episode-href bookkeeping; iOS/iPadOS keep the
                // show/details href captured by playContent for pre-staging.
                self.viewModel.pendingServiceHref = episodeHref
#endif
                self.processStreamResult(streams: streams, subtitles: subtitles, sources: sources, service: service)
                self.viewModel.resetPickerState()
            }
        }
    }
    
    @MainActor
    private func playContent(_ result: SearchItem, autoModeLaunch: Bool = false, retryCount: Int = 0) async {
        Logger.shared.log("Starting playback for: \(result.title)", type: "Stream")
        
        viewModel.isFetchingStreams = true
        viewModel.currentFetchingTitle = result.title
        viewModel.streamFetchProgress = "Initializing..."
        viewModel.pendingPlaybackAutoMode = autoModeLaunch || shouldForceAutoResolutionForDownload
        viewModel.pendingPlaybackRetryCount = retryCount
#if !os(tvOS)
        viewModel.pendingServiceHref = result.href
#endif
        
        guard let service = serviceManager.activeServices.first(where: { service in
            viewModel.moduleResults[service.id]?.contains { $0.id == result.id } ?? false
        }) else {
            Logger.shared.log("Could not find service for result: \(result.title)", type: "Error")
            viewModel.isFetchingStreams = false
            viewModel.streamError = "Could not find the service for '\(result.title)'. Please try again."
            viewModel.showingStreamError = true
            return
        }
        
        Logger.shared.log("Using service: \(service.metadata.sourceName)", type: "Stream")
        viewModel.streamFetchProgress = "Loading service: \(service.metadata.sourceName)"
        
        let jsController = JSController()
        jsController.loadScript(service.jsScript, service: service)
        Logger.shared.log("JavaScript loaded successfully service=\(service.metadata.sourceName)", type: "Stream")
        
        viewModel.streamFetchProgress = "Fetching episodes..."
        let cloudflareHostBefore = CloudflareBypassManager.shared.pendingVerificationURL?.host?.lowercased()
        
        jsController.fetchEpisodesJS(url: result.href, module: service) { episodes in
            Task { @MainActor in
                let requiresCloudflareVerification = self.updatePendingCloudflareVerification(
                    requestURLString: result.href,
                    hostBefore: cloudflareHostBefore,
                    retry: {
                        Task { @MainActor in
                            await self.playContent(
                                result,
                                autoModeLaunch: autoModeLaunch,
                                retryCount: retryCount
                            )
                        }
                    }
                )
                guard !requiresCloudflareVerification else {
                    Logger.shared.log(
                        "Blocked service episode result while Cloudflare verification is pending service=\(service.metadata.sourceName)",
                        type: "Service"
                    )
                    self.handleServicePlaybackPreparationFailure(
                        service,
                        message: "Cloudflare verification is required before this source can load the selected title.",
                        autoModeLaunch: autoModeLaunch
                    )
                    return
                }
                self.handleEpisodesFetched(episodes, result: result, service: service, jsController: jsController)
            }
        }
    }
    
    @MainActor
    private func handleEpisodesFetched(_ episodes: [EpisodeLink], result: SearchItem, service: Service, jsController: JSController) {
        guard forcedWatchTogetherMediaIsCurrent() else { return }
        if isForcedWatchTogetherAnimePlayback,
           !forcedWatchTogetherAnimeResultMatchesDestination(result) {
            handleServicePlaybackPreparationFailure(
                service,
                message: "Watch Together rejected a source result for a different anime cour instead of guessing S1E1.",
                autoModeLaunch: true
            )
            return
        }
        Logger.shared.log("Fetched \(episodes.count) episodes for: \(result.title)", type: "Stream")
        viewModel.streamFetchProgress = "Found \(episodes.count) episode\(episodes.count == 1 ? "" : "s")"
        
        if episodes.isEmpty {
            Logger.shared.log("No episodes found for: \(result.title)", type: "Error")
            handleServicePlaybackPreparationFailure(service, message: "No episodes found for '\(result.title)'. The source may be unavailable.")
            return
        }
        
        if isMovie {
            let targetHref = episodes.first?.href ?? result.href
            Logger.shared.log("Movie - Using href: \(targetHref)", type: "Stream")
            viewModel.streamFetchProgress = "Preparing movie stream..."
            fetchFinalStream(href: targetHref, jsController: jsController, service: service)
            return
        }
        
        guard let selectedEp = selectedEpisode else {
            Logger.shared.log("No episode selected for TV show", type: "Error")
            handleServicePlaybackPreparationFailure(service, message: "No episode selected. Please select an episode first.")
            return
        }
        
        viewModel.streamFetchProgress = "Finding episode S\(selectedEp.seasonNumber)E\(selectedEp.episodeNumber)..."
        let seasons = parseSeasons(from: episodes)
        let targetSeasonIndex = selectedEp.seasonNumber - 1
        let targetEpisodeNumber = selectedEp.episodeNumber
        let bundledEpisodeNumbers = bundledEpisodeNumberCandidates(for: selectedEp)
        let allowAutomaticEpisodeResolution = shouldUseAutomaticEpisodeResolution
        Logger.shared.log("Episode auto-selection input source=\(service.metadata.sourceName) title='\(result.title)' target=S\(selectedEp.seasonNumber)E\(selectedEp.episodeNumber) episodes=\(episodes.count) seasons=\(episodeSeasonSummary(seasons)) autoMode=\(viewModel.pendingPlaybackAutoMode) forcedDownload=\(shouldForceAutoResolutionForDownload) standalone=\(standaloneAutoSelectEpisodesEnabled) allowed=\(allowAutomaticEpisodeResolution) animeContext=\(hasAnimeLookupContext) special=\(effectivePlaybackContext?.isSpecial ?? false) seasonEpisodeCount=\(logValue(effectivePlaybackContext?.animeSeasonEpisodeCount)) absolute=\(logValue(effectivePlaybackContext?.animeAbsoluteEpisodeNumber)) bundledCandidates=\(logValues(bundledEpisodeNumbers))", type: "Stream")
        
        if let targetHref = findEpisodeHref(
            seasons: seasons,
            seasonIndex: targetSeasonIndex,
            episodeNumber: targetEpisodeNumber,
            bundledEpisodeNumbers: bundledEpisodeNumbers,
            allowAutomaticEpisodeResolution: allowAutomaticEpisodeResolution
        ) {
            viewModel.streamFetchProgress = "Found episode, fetching stream..."
            fetchFinalStream(href: targetHref, jsController: jsController, service: service)
        } else {
            showEpisodePicker(seasons: seasons, result: result, jsController: jsController, service: service)
        }
    }
    
    private func parseSeasons(from episodes: [EpisodeLink]) -> [[EpisodeLink]] {
        var seasons: [[EpisodeLink]] = []
        var currentSeason: [EpisodeLink] = []
        var lastEpisodeNumber = 0
        
        for episode in episodes {
            if episode.number == 1 || episode.number <= lastEpisodeNumber {
                if !currentSeason.isEmpty {
                    seasons.append(currentSeason)
                    currentSeason = []
                }
            }
            currentSeason.append(episode)
            lastEpisodeNumber = episode.number
        }
        
        if !currentSeason.isEmpty {
            seasons.append(currentSeason)
        }
        
        return seasons
    }

    private func logValue(_ value: Int?) -> String {
        value.map { String($0) } ?? "nil"
    }

    private func logValues(_ values: [Int]) -> String {
        values.isEmpty ? "none" : values.map { String($0) }.joined(separator: ",")
    }

    private func episodeSeasonSummary(_ seasons: [[EpisodeLink]]) -> String {
        guard !seasons.isEmpty else { return "none" }
        return seasons.enumerated().map { index, season in
            let sample = season.prefix(5).map { String($0.number) }.joined(separator: ",")
            let suffix = season.count > 5 ? ",..." : ""
            return "S\(index + 1):count=\(season.count),nums=[\(sample)\(suffix)]"
        }.joined(separator: ";")
    }
    
    private func findEpisodeHref(seasons: [[EpisodeLink]], seasonIndex: Int, episodeNumber: Int, bundledEpisodeNumbers: [Int], allowAutomaticEpisodeResolution: Bool) -> String? {
        Logger.shared.log("Episode auto-selection resolving target=S\(seasonIndex + 1)E\(episodeNumber) allow=\(allowAutomaticEpisodeResolution) autoMode=\(viewModel.pendingPlaybackAutoMode) forcedDownload=\(shouldForceAutoResolutionForDownload) standalone=\(standaloneAutoSelectEpisodesEnabled)", type: "Stream")

        if seasonIndex >= 0 && seasonIndex < seasons.count {
            if let episode = seasons[seasonIndex].first(where: { $0.number == episodeNumber }) {
                Logger.shared.log("Found exact match: S\(seasonIndex + 1)E\(episodeNumber)", type: "Stream")
                return episode.href
            }
        } else {
            Logger.shared.log("Episode auto-selection exact check skipped for out-of-range seasonIndex=\(seasonIndex) seasons=\(seasons.count)", type: "Stream")
        }

        guard allowAutomaticEpisodeResolution else {
            Logger.shared.log("Episode auto-resolution skipped because automatic episode resolution is disabled for S\(seasonIndex + 1)E\(episodeNumber) autoMode=\(viewModel.pendingPlaybackAutoMode) standalone=\(standaloneAutoSelectEpisodesEnabled)", type: "Stream")
            return nil
        }

        let bundledEligible = shouldUseBundledEpisodeNumbers(seasons: seasons)
        if hasAnimeLookupContext || !bundledEpisodeNumbers.isEmpty {
            let stats = sourceEpisodeListStats(seasons: seasons)
            Logger.shared.log("Episode auto-selection bundled check eligible=\(bundledEligible) candidates=\(logValues(bundledEpisodeNumbers)) episodes=\(stats.count) maxEpisode=\(stats.maxNumber) seasonEpisodeCount=\(logValue(effectivePlaybackContext?.animeSeasonEpisodeCount)) special=\(effectivePlaybackContext?.isSpecial ?? false)", type: "Stream")
        }
        if bundledEligible,
           let bundledMatch = findBundledEpisodeHref(seasons: seasons, episodeNumbers: bundledEpisodeNumbers) {
            Logger.shared.log("Auto-resolved bundled anime episode \(bundledMatch.number) from S\(seasonIndex + 1)E\(episodeNumber)", type: "Stream")
            return bundledMatch.href
        }

        if let singleSeasonMatch = findSingleSeasonAnimeEpisodeHref(seasons: seasons, seasonIndex: seasonIndex, episodeNumber: episodeNumber) {
            Logger.shared.log("Auto-resolved anime episode \(episodeNumber) from single-season source list", type: "Stream")
            return singleSeasonMatch
        }

        let crossSeasonEligible = shouldUseCrossSeasonEpisodeFallback(seasonIndex: seasonIndex)
        if hasAnimeLookupContext || effectivePlaybackContext?.isSpecial == true {
            Logger.shared.log("Episode auto-selection cross-season check eligible=\(crossSeasonEligible) targetSeasonIndex=\(seasonIndex) animeContext=\(hasAnimeLookupContext) special=\(effectivePlaybackContext?.isSpecial ?? false)", type: "Stream")
        }
        if crossSeasonEligible {
            for season in seasons {
                if let episode = season.first(where: { $0.number == episodeNumber }) {
                    Logger.shared.log("Found episode \(episodeNumber) in different season, auto-playing", type: "Stream")
                    return episode.href
                }
            }
            Logger.shared.log("Episode auto-selection cross-season fallback found no episode \(episodeNumber)", type: "Stream")
        }

        Logger.shared.log("Episode auto-selection unresolved target=S\(seasonIndex + 1)E\(episodeNumber) seasons=\(episodeSeasonSummary(seasons))", type: "Stream")
        return nil
    }

    private func sourceEpisodeListStats(seasons: [[EpisodeLink]]) -> (count: Int, maxNumber: Int) {
        let numbers = seasons.flatMap { $0 }.map(\.number)
        return (numbers.count, numbers.max() ?? 0)
    }

    private func isStrictlyAscendingEpisodeSlice(_ episodes: [EpisodeLink]) -> Bool {
        guard episodes.count > 1 else { return true }
        for index in episodes.indices.dropFirst() where episodes[index].number <= episodes[episodes.index(before: index)].number {
            return false
        }
        return true
    }

    private func shouldUseBundledEpisodeNumbers(seasons: [[EpisodeLink]]) -> Bool {
        guard effectivePlaybackContext?.isSpecial != true,
              let seasonEpisodeCount = effectivePlaybackContext?.animeSeasonEpisodeCount,
              seasonEpisodeCount > 0 else {
            return false
        }

        let stats = sourceEpisodeListStats(seasons: seasons)
        return stats.maxNumber > seasonEpisodeCount
    }

    private func findSingleSeasonAnimeEpisodeHref(seasons: [[EpisodeLink]], seasonIndex: Int, episodeNumber: Int) -> String? {
        guard effectivePlaybackContext?.isSpecial != true else {
            Logger.shared.log("Episode auto-selection single-season anime skipped because context is a special", type: "Stream")
            return nil
        }
        guard hasAnimeLookupContext else {
            return nil
        }
        guard seasons.count == 1 else {
            Logger.shared.log("Episode auto-selection single-season anime skipped because source returned \(seasons.count) seasons", type: "Stream")
            return nil
        }
        guard seasonIndex > 0 else {
            Logger.shared.log("Episode auto-selection single-season anime skipped because target season index is \(seasonIndex)", type: "Stream")
            return nil
        }

        let stats = sourceEpisodeListStats(seasons: seasons)
        let season = seasons[0]
        let minEpisodeNumber = season.map(\.number).min() ?? 0
        if minEpisodeNumber > episodeNumber,
           episodeNumber > 0,
           season.indices.contains(episodeNumber - 1),
           isStrictlyAscendingEpisodeSlice(season) {
            let resolvedEpisode = season[episodeNumber - 1]
            Logger.shared.log("Episode auto-selection single-season anime using positional absolute-numbered slice targetE\(episodeNumber) sourceEpisode=\(resolvedEpisode.number) minEpisode=\(minEpisodeNumber) count=\(season.count)", type: "Stream")
            return resolvedEpisode.href
        }

        if let seasonEpisodeCount = effectivePlaybackContext?.animeSeasonEpisodeCount,
           seasonEpisodeCount > 0 {
            guard stats.count <= seasonEpisodeCount,
                  stats.maxNumber <= seasonEpisodeCount else {
                Logger.shared.log("Episode auto-selection single-season anime skipped because source looks bundled episodes=\(stats.count) maxEpisode=\(stats.maxNumber) seasonEpisodeCount=\(seasonEpisodeCount)", type: "Stream")
                return nil
            }
        }

        let matches = seasons.flatMap { $0 }.filter { $0.number == episodeNumber }
        guard matches.count == 1 else {
            Logger.shared.log("Episode auto-selection single-season anime skipped because episode \(episodeNumber) matchCount=\(matches.count)", type: "Stream")
            return nil
        }
        return matches.first?.href
    }

    private func bundledEpisodeNumberCandidates(for selectedEpisode: TMDBEpisode) -> [Int] {
        var numbers: [Int] = []

        if let absoluteEpisode = effectivePlaybackContext?.animeAbsoluteEpisodeNumber {
            numbers.append(absoluteEpisode)
        }

        if isAnimeContent,
           originalTMDBSeasonNumber == 1,
           let originalEpisode = originalTMDBEpisodeNumber {
            numbers.append(originalEpisode)
        }

        var seen = Set<Int>()
        return numbers
            .filter { $0 > 0 && $0 != selectedEpisode.episodeNumber }
            .filter { seen.insert($0).inserted }
    }

    private func findBundledEpisodeHref(seasons: [[EpisodeLink]], episodeNumbers: [Int]) -> (href: String, number: Int)? {
        guard !episodeNumbers.isEmpty else { return nil }

        let allEpisodes = seasons.flatMap { $0 }
        for episodeNumber in episodeNumbers {
            let matches = allEpisodes.filter { $0.number == episodeNumber }
            if matches.count == 1, let match = matches.first {
                return (match.href, episodeNumber)
            }
        }

        return nil
    }

    private func shouldUseCrossSeasonEpisodeFallback(seasonIndex: Int) -> Bool {
        if effectivePlaybackContext?.isSpecial == true {
            return true
        }

        if hasAnimeLookupContext {
            return seasonIndex <= 0
        }

        return true
    }
    
    @MainActor
    private func showEpisodePicker(seasons: [[EpisodeLink]], result: SearchItem, jsController: JSController, service: Service) {
        viewModel.pendingResult = result
        viewModel.pendingJSController = jsController
        viewModel.pendingService = service
        viewModel.isFetchingStreams = false
        
        if seasons.count > 1 {
            viewModel.availableSeasons = seasons
            viewModel.showingSeasonPicker = true
        } else if let firstSeason = seasons.first, !firstSeason.isEmpty {
            viewModel.pendingEpisodes = firstSeason
            viewModel.showingEpisodePicker = true
        } else {
            Logger.shared.log("No episodes found in any season", type: "Error")
            handleServicePlaybackPreparationFailure(service, message: "No episodes found in any season. The source may have incomplete data.")
        }
    }
    
    private func fetchFinalStream(href: String, jsController: JSController, service: Service) {
        let softsub = service.metadata.softsub ?? false
        let cloudflareHostBefore = CloudflareBypassManager.shared.pendingVerificationURL?.host?.lowercased()
        serviceStreamExtractionRequest?.cancel()
        let extractionGeneration = UUID()
        serviceStreamExtractionGeneration = extractionGeneration
        serviceStreamExtractionRequest = jsController.fetchStreamUrlJS(episodeUrl: href, softsub: softsub, module: service) { streamResult in
            Task { @MainActor in
                guard self.serviceStreamExtractionGeneration == extractionGeneration else { return }
                self.serviceStreamExtractionRequest = nil
                self.serviceStreamExtractionGeneration = nil
                let (streams, subtitles, sources) = streamResult
                let requiresCloudflareVerification = self.updatePendingCloudflareVerification(
                    requestURLString: href,
                    hostBefore: cloudflareHostBefore,
                    retry: {
                        self.fetchFinalStream(href: href, jsController: jsController, service: service)
                    }
                )
                guard !requiresCloudflareVerification else {
                    Logger.shared.log(
                        "Blocked service stream result while Cloudflare verification is pending service=\(service.metadata.sourceName)",
                        type: "Service"
                    )
                    self.handleServicePlaybackPreparationFailure(
                        service,
                        message: "Cloudflare verification is required before this source can load the selected stream."
                    )
                    return
                }
                self.processStreamResult(streams: streams, subtitles: subtitles, sources: sources, service: service)
            }
        }
    }
    
    @MainActor
    private func processStreamResult(streams: [String]?, subtitles: [String]?, sources: [[String: Any]]?, service: Service) {
        Logger.shared.log("Stream fetch result - Streams: \(streams?.count ?? 0), Sources: \(sources?.count ?? 0)", type: "Stream")
        viewModel.streamFetchProgress = "Processing stream data..."
        
        let parsedStreams = parseStreamOptions(streams: streams, sources: sources)
        let availableStreams = filteredServiceStreamOptions(parsedStreams, service: service)

        if !parsedStreams.isEmpty && availableStreams.isEmpty {
            Logger.shared.log("All \(parsedStreams.count) stream options hidden by extra service settings for \(service.metadata.sourceName)", type: "Stream")
            handleServicePlaybackPreparationFailure(service, message: "All streams from \(service.metadata.sourceName) are hidden by your Extra Source Settings.")
            return
        }
        
        if availableStreams.count > 1 {
            if shouldUseAutomaticResolution {
                if let selectedStream = bestStreamOption(from: availableStreams) {
                    let preference = AutoModeQualityPreference.current
                    Logger.shared.log("Auto Mode selected stream option '\(selectedStream.name)' for \(service.metadata.sourceName) preference=\(preference.rawValue) options=\(availableStreams.count)", type: "Stream")
                    viewModel.streamFetchProgress = "Selected \(selectedStream.name)."
                    resolveSubtitleSelection(
                        subtitles: subtitles,
                        defaultSubtitle: selectedStream.subtitle,
                        service: service,
                        streamURL: selectedStream.url,
                        headers: selectedStream.headers,
                        structuredSubtitleTracks: selectedStream.subtitleTracks,
                        streamName: selectedStream.name,
                        streamLanguageHints: selectedStream.languageHints,
                        streamMetadataHints: selectedStream.metadataHints,
                        serviceHref: viewModel.pendingServiceHref
                    )
                    return
                }
                let fallbackReason = AutoModeQualityPreference.current.usesAutomaticSelection ? "no quality label" : "auto quality disabled"
                Logger.shared.log("Auto Mode found \(availableStreams.count) stream options for \(service.metadata.sourceName) but \(fallbackReason); showing picker", type: "Stream")
                viewModel.streamFetchProgress = "\(service.metadata.sourceName) needs a stream choice."
            } else {
                Logger.shared.log("Found \(availableStreams.count) stream options, showing selection", type: "Stream")
            }
            viewModel.streamOptions = availableStreams
            viewModel.pendingSubtitles = subtitles
            viewModel.pendingService = service
            viewModel.isFetchingStreams = false
            viewModel.showingStreamMenu = true
            return
        }
        
        if let firstStream = availableStreams.first {
            resolveSubtitleSelection(
                subtitles: subtitles,
                defaultSubtitle: firstStream.subtitle,
                service: service,
                streamURL: firstStream.url,
                headers: firstStream.headers,
                structuredSubtitleTracks: firstStream.subtitleTracks,
                streamName: firstStream.name,
                streamLanguageHints: firstStream.languageHints,
                streamMetadataHints: firstStream.metadataHints,
                serviceHref: viewModel.pendingServiceHref
            )
        } else if let streamURL = extractSingleStreamURL(streams: streams, sources: sources) {
            if StreamLanguageFilter.shouldHide(
                languageHints: [],
                metadata: [streamURL.url],
                sourceId: SourceHealth.serviceId(service),
                originalAudioLanguage: originalAudioLanguage,
                isAnime: hasAnimeLookupContext
            ) {
                Logger.shared.log("Single stream hidden by extra service settings for \(service.metadata.sourceName)", type: "Stream")
                handleServicePlaybackPreparationFailure(service, message: "This stream is hidden by your Extra Source Settings.")
                return
            }
            resolveSubtitleSelection(
                subtitles: subtitles,
                defaultSubtitle: nil,
                service: service,
                streamURL: streamURL.url,
                headers: streamURL.headers,
                serviceHref: viewModel.pendingServiceHref
            )
        } else {
            Logger.shared.log("Failed to create URL from stream string", type: "Error")
            handleServicePlaybackPreparationFailure(service, message: "Failed to get a valid stream URL. The source may be temporarily unavailable.")
        }
    }
    
    private func parseStreamOptions(streams: [String]?, sources: [[String: Any]]?) -> [StreamOption] {
        var availableStreams: [StreamOption] = []
        
        if let sources = sources, !sources.isEmpty {
            for (idx, source) in sources.prefix(Self.maxInspectedServiceStreamEntries).enumerated() {
                guard availableStreams.count < Self.maxRetainedServiceStreamOptions else { break }
                guard let rawUrl = firstStringValue(in: source, keys: ["streamUrl", "url", "file", "src", "link", "stream"]), !rawUrl.isEmpty else { continue }
                let title = ["title", "name", "label", "quality"]
                    .compactMap { source[$0] as? String }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
                let headers = safeConvertToHeaders(source["headers"])
                let subtitle = source["subtitle"] as? String
                let subtitleTracks = parseStructuredSubtitleTracks(from: source)
                let option = StreamOption(
                    name: title ?? "Stream \(idx + 1)",
                    url: rawUrl,
                    headers: headers,
                    subtitle: subtitle,
                    subtitleTracks: subtitleTracks,
                    languageHints: languageHints(in: source),
                    metadataHints: metadataHints(in: source)
                )
                availableStreams.append(option)
            }
        } else if let streams = streams, !streams.isEmpty {
            availableStreams = parseStreamStrings(streams)
        }
        
        return availableStreams
    }
    
    private func parseStreamStrings(_ streams: [String]) -> [StreamOption] {
        var options: [StreamOption] = []
        var index = 0
        var unnamedCount = 1
        let inspectedCount = min(streams.count, Self.maxInspectedServiceStreamEntries)
        
        while index < inspectedCount, options.count < Self.maxRetainedServiceStreamOptions {
            let entry = streams[index]
            if isURL(entry) {
                options.append(StreamOption(name: "Stream \(unnamedCount)", url: entry, headers: nil, subtitle: nil, subtitleTracks: []))
                unnamedCount += 1
                index += 1
            } else {
                let nextIndex = index + 1
                if nextIndex < inspectedCount, isURL(streams[nextIndex]) {
                    options.append(StreamOption(name: entry, url: streams[nextIndex], headers: nil, subtitle: nil, subtitleTracks: [], metadataHints: [entry]))
                    index += 2
                } else {
                    index += 1
                }
            }
        }
        
        return options
    }

    private func languageHints(in source: [String: Any]) -> [String] {
        stringValues(in: source, keys: [
            "lang", "language", "languages", "languageCode", "languageCodes", "langCode", "langCodes",
            "locale", "locales", "audio", "audioLang", "audioLangs", "audioLanguage", "audioLanguages",
            "dub", "dubLang", "dubLanguage", "dubLanguages"
        ])
    }

    private func metadataHints(in source: [String: Any]) -> [String] {
        stringValues(in: source, keys: [
            "title", "name", "label", "quality", "provider", "type", "filename", "file", "streamName", "server",
            "source", "codec", "video", "audio", "audioTrack", "audioTracks"
        ])
    }

    private func stringValues(in source: [String: Any], keys: [String]) -> [String] {
        keys.flatMap { key -> [String] in
            guard let rawValue = source[key] else { return [] }
            if let value = streamMetadataString(from: rawValue) {
                return [value]
            }
            if let values = rawValue as? [Any] {
                return values.prefix(Self.maxMetadataValuesPerField).compactMap(streamMetadataString(from:))
            }
            return []
        }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }

    private func streamMetadataString(from value: Any) -> String? {
        if value is Bool || value is NSNull { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
    
    private func isURL(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://")
    }
    
    private func extractSingleStreamURL(streams: [String]?, sources: [[String: Any]]?) -> (url: String, headers: [String: String]?)? {
        if let sources = sources, let firstSource = sources.first {
            if let urlString = firstStringValue(in: firstSource, keys: ["streamUrl", "url", "file", "src", "link", "stream"]) {
                return (urlString, safeConvertToHeaders(firstSource["headers"]))
            }
        } else if let streams = streams, !streams.isEmpty {
            let urlCandidates = streams.filter { $0.hasPrefix("http") }
            if let firstURL = urlCandidates.first {
                return (firstURL, nil)
            } else if let first = streams.first {
                return (first, nil)
            }
        }
        return nil
    }

    private func firstStringValue(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func parseStructuredSubtitleTracks(from source: [String: Any]) -> [ServiceSubtitleTrack] {
        var tracks: [ServiceSubtitleTrack] = []

        let topLevelHeaders = safeConvertToHeaders(source["subtitleHeaders"])
        if let subtitleURL = firstStringValue(in: source, keys: ["subtitle", "subtitles"]), isURL(subtitleURL) {
            tracks.append(ServiceSubtitleTrack(title: "Subtitle", url: subtitleURL, headers: topLevelHeaders))
        }

        if let subtitleURLs = source["subtitles"] as? [String] {
            tracks.append(contentsOf: parseSubtitleOptions(from: subtitleURLs).map {
                ServiceSubtitleTrack(title: $0.title, url: $0.url, headers: topLevelHeaders)
            })
        }

        let rawTracks = (source["allSubtitles"] as? [[String: Any]])
            ?? (source["subtitleTracks"] as? [[String: Any]])
            ?? []

        for (index, item) in rawTracks.enumerated() {
            guard let url = firstStringValue(in: item, keys: ["url", "file", "src"]),
                  isURL(url) else { continue }
            let title = firstStringValue(in: item, keys: ["title", "label", "lang", "language", "name"])
                ?? "Subtitle \(index + 1)"
            let headers = safeConvertToHeaders(item["headers"]) ?? topLevelHeaders
            tracks.append(ServiceSubtitleTrack(title: title, url: url, headers: headers))
        }

        var seen = Set<String>()
        return tracks.filter { seen.insert($0.url).inserted }
    }
    
    @MainActor
    private func resolveSubtitleSelection(
        subtitles: [String]?,
        defaultSubtitle: String?,
        service: Service,
        streamURL: String,
        headers: [String: String]?,
        structuredSubtitleTracks: [ServiceSubtitleTrack] = [],
        streamName: String? = nil,
        streamLanguageHints: [String] = [],
        streamMetadataHints: [String] = [],
        serviceHref: String? = nil
    ) {
        if !structuredSubtitleTracks.isEmpty {
            dispatchStreamAction(
                streamURL,
                service: service,
                subtitle: defaultSubtitle,
                subtitleTracks: structuredSubtitleTracks,
                headers: headers,
                streamName: streamName,
                streamLanguageHints: streamLanguageHints,
                streamMetadataHints: streamMetadataHints,
                serviceHref: serviceHref
            )
            return
        }

        guard let subtitles = subtitles, !subtitles.isEmpty else {
            dispatchStreamAction(
                streamURL,
                service: service,
                subtitle: defaultSubtitle,
                headers: headers,
                streamName: streamName,
                streamLanguageHints: streamLanguageHints,
                streamMetadataHints: streamMetadataHints,
                serviceHref: serviceHref
            )
            return
        }
        
        let options = parseSubtitleOptions(from: subtitles)
        guard !options.isEmpty else {
            dispatchStreamAction(
                streamURL,
                service: service,
                subtitle: defaultSubtitle,
                headers: headers,
                streamName: streamName,
                streamLanguageHints: streamLanguageHints,
                streamMetadataHints: streamMetadataHints,
                serviceHref: serviceHref
            )
            return
        }
        
        if options.count == 1 {
            dispatchStreamAction(
                streamURL,
                service: service,
                subtitle: options[0].url,
                headers: headers,
                streamName: streamName,
                streamLanguageHints: streamLanguageHints,
                streamMetadataHints: streamMetadataHints,
                serviceHref: serviceHref
            )
            return
        }
        
        viewModel.subtitleOptions = options
        viewModel.pendingStreamURL = streamURL
        viewModel.pendingHeaders = headers
        viewModel.pendingSubtitleHeadersByURL = Dictionary(
            uniqueKeysWithValues: options.compactMap { option in
                guard let headers = structuredSubtitleTracks.first(where: { $0.url == option.url })?.headers,
                      !headers.isEmpty else {
                    return nil
                }
                return (option.url, headers)
            }
        )
        viewModel.pendingService = service
        viewModel.pendingServiceHref = serviceHref
        viewModel.pendingStreamName = streamName
        viewModel.pendingStreamLanguageHints = streamLanguageHints
        viewModel.pendingStreamMetadataHints = streamMetadataHints
        viewModel.isFetchingStreams = false
        viewModel.showingSubtitlePicker = true
    }
    
    /// Routes to either play or download based on downloadMode
    private func dispatchStreamAction(
        _ url: String,
        service: Service,
        subtitle: String?,
        subtitleTracks: [ServiceSubtitleTrack] = [],
        subtitleNames: [String]? = nil,
        subtitleHeadersByURL: [String: [String: String]]? = nil,
        headers: [String: String]?,
        streamName: String? = nil,
        streamLanguageHints: [String] = [],
        streamMetadataHints: [String] = [],
        serviceHref: String? = nil
    ) {
        let ruleMetadata = [streamName].compactMap { $0 } + streamMetadataHints + [url]
        guard !StreamLanguageFilter.shouldHide(
            languageHints: streamLanguageHints,
            metadata: ruleMetadata,
            sourceId: SourceHealth.serviceId(service),
            originalAudioLanguage: originalAudioLanguage,
            isAnime: hasAnimeLookupContext
        ) else {
            Logger.shared.log(
                "Service stream blocked by extra service settings source=\(service.metadata.sourceName) name=\(streamName ?? "unnamed")",
                type: "Stream"
            )
            handleServicePlaybackPreparationFailure(
                service,
                message: "This Service stream is hidden by your Extra Source Settings.",
                autoModeLaunch: viewModel.pendingPlaybackAutoMode
            )
            return
        }

        let structuredSubtitleURLs = subtitleTracks.map(\.url)
        let structuredSubtitleNames = subtitleTracks.map(\.title)
        let structuredSubtitleHeaders = subtitleHeadersByURL ?? subtitleHeadersDictionary(from: subtitleTracks)
        let playbackSubtitles: [String]?
        let playbackSubtitleNames: [String]?

        if !structuredSubtitleURLs.isEmpty {
            playbackSubtitles = structuredSubtitleURLs
            playbackSubtitleNames = structuredSubtitleNames
        } else if let subtitle {
            playbackSubtitles = [subtitle]
            playbackSubtitleNames = subtitleNames
        } else {
            playbackSubtitles = nil
            playbackSubtitleNames = nil
        }

        if downloadMode {
#if os(tvOS)
            handleServicePlaybackPreparationFailure(
                service,
                message: "Downloads are not available on Apple TV.",
                autoModeLaunch: viewModel.pendingPlaybackAutoMode
            )
#else
            let downloadSubtitleURL = playbackSubtitles?.first
            let downloadSubtitleHeaders = subtitleHeaders(for: downloadSubtitleURL, in: structuredSubtitleHeaders)
            downloadStreamURL(
                url,
                service: service,
                subtitle: downloadSubtitleURL,
                subtitleHeaders: downloadSubtitleHeaders,
                headers: headers,
                streamName: streamName,
                serviceHref: serviceHref,
                autoModeLaunch: viewModel.pendingPlaybackAutoMode
            )
#endif
        } else {
            playStreamURL(
                url,
                service: service,
                subtitles: playbackSubtitles,
                subtitleNames: playbackSubtitleNames,
                subtitleHeadersByURL: structuredSubtitleHeaders,
                headers: headers,
                streamName: streamName,
                serviceHref: serviceHref,
                autoModeLaunch: viewModel.pendingPlaybackAutoMode,
                retryCount: viewModel.pendingPlaybackRetryCount
            )
        }
    }

    private func subtitleHeadersDictionary(from tracks: [ServiceSubtitleTrack]) -> [String: [String: String]]? {
        let pairs = tracks.compactMap { track -> (String, [String: String])? in
            guard let headers = track.headers, !headers.isEmpty else { return nil }
            return (track.url, headers)
        }
        guard !pairs.isEmpty else { return nil }
        return pairs.reduce(into: [:]) { result, pair in
            // Providers occasionally repeat the same subtitle URL under multiple labels.
            // Preserve the first header set instead of trapping on a duplicate dictionary key.
            if result[pair.0] == nil {
                result[pair.0] = pair.1
            }
        }
    }

    private func subtitleHeaders(for url: String?, in headersByURL: [String: [String: String]]?) -> [String: String]? {
        guard let url else { return nil }
        return headersByURL?[url]
    }
    
    private func parseSubtitleOptions(from subtitles: [String]) -> [(title: String, url: String)] {
        var options: [(String, String)] = []
        var index = 0
        var fallbackIndex = 1
        
        while index < subtitles.count {
            let entry = subtitles[index]
            if isURL(entry) {
                options.append(("Subtitle \(fallbackIndex)", entry))
                fallbackIndex += 1
                index += 1
            } else {
                let nextIndex = index + 1
                if nextIndex < subtitles.count, isURL(subtitles[nextIndex]) {
                    options.append((entry, subtitles[nextIndex]))
                    fallbackIndex += 1
                    index += 2
                } else {
                    index += 1
                }
            }
        }
        return options
    }
    
    private func playStreamURL(_ url: String, service: Service, subtitles: [String]?, subtitleNames: [String]? = nil, subtitleHeadersByURL: [String: [String: String]]? = nil, headers: [String: String]?, streamName: String? = nil, serviceHref: String? = nil, autoModeLaunch: Bool = false, retryCount: Int = 0) {
        let playbackTraceID = String(UUID().uuidString.prefix(8))
        let playbackTraceCreatedAt = Date()
        viewModel.resetStreamState()
        
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)

            guard !Task.isCancelled,
                  forcedWatchTogetherMediaIsCurrent() else { return }

            guard let streamURL = URL(string: url) else {
                Logger.shared.log("Invalid stream URL: \(ServiceSandboxState.redactedURL(url))", type: "Error")
                handleServicePlaybackPreparationFailure(service, message: "Invalid stream URL. The source returned a malformed URL.", autoModeLaunch: autoModeLaunch)
                return
            }
            guard let streamScheme = streamURL.scheme?.lowercased(),
                  streamScheme == "http" || streamScheme == "https" else {
                Logger.shared.log("Invalid stream URL scheme: \(streamURL.scheme ?? "nil")", type: "Error")
                handleServicePlaybackPreparationFailure(service, message: "Invalid stream URL. The source did not return a playable HTTP stream.", autoModeLaunch: autoModeLaunch)
                return
            }
            
#if !os(tvOS)
            let externalRaw = UserDefaults.standard.string(forKey: "externalPlayer") ?? ExternalPlayer.none.rawValue
            let external = ExternalPlayer(rawValue: externalRaw) ?? .none
            let schemeUrl = external.schemeURL(for: url)
            
            if !forceAutomaticPlayback,
               onResolvedPlaybackRequest == nil,
               let scheme = schemeUrl,
               UIApplication.shared.canOpenURL(scheme) {
                dismissAutoModeSheetBeforePlaybackIfNeeded { _ in
                    UIApplication.shared.open(scheme, options: [:], completionHandler: nil)
                    Logger.shared.log("Opening external player", type: "General")
                }
                return
            }
#endif
            
            let serviceURL = service.metadata.baseUrl
            var finalHeaders: [String: String] = [
                "Origin": serviceURL,
                "Referer": serviceURL,
                "User-Agent": URLSession.randomUserAgent
            ]
            
            if let custom = headers {
                Logger.shared.log("Using custom header keys: \(custom.keys.sorted())", type: "Stream")
                for (k, v) in custom {
                    finalHeaders[k] = v
                }
                
                if finalHeaders["User-Agent"] == nil {
                    finalHeaders["User-Agent"] = URLSession.randomUserAgent
                }
            }
            
            Logger.shared.log("Final header keys: \(finalHeaders.keys.sorted())", type: "Stream")

            // Warm the resolved stream as early as possible, while the player is still being presented and MPV initializes, so
            // the byte.
#if !os(tvOS)
            ExperimentalMPVPreloadManager.shared.prewarm(
                url: streamURL,
                headers: finalHeaders,
                label: playerMediaTitle
            )
#endif

            let playbackPlan = PlaybackLaunchPlan.make(
                selection: forceAutomaticPlayback ? .mpv : .selected,
                deviceFamily: .current
            )
            Logger.shared.log("Playback resolve diagnostics source=\(service.metadata.sourceName) kind=service player=\(playbackPlan.primary.rawValue) host=\(streamURL.host ?? "nil") ext=\(streamURL.pathExtension.isEmpty ? "none" : streamURL.pathExtension) namedStream=\(streamName?.isEmpty == false) headerKeys=[\(finalHeaders.keys.sorted().joined(separator: ","))] subtitles=\(subtitles?.count ?? 0) autoMode=\(autoModeLaunch) retry=\(retryCount)", type: "StreamDiagnostics")
            Logger.shared.log("[PlaybackTrace \(playbackTraceID)] stage=resolved source=\(service.metadata.sourceName) kind=service player=\(playbackPlan.primary.rawValue) host=\(streamURL.host ?? "nil") autoMode=\(autoModeLaunch) retry=\(retryCount)", type: "PlaybackTrace")
            
            // Record service usage (async to avoid blocking player launch)
            Task {
                if self.isMovie {
                    ProgressManager.shared.recordMovieServiceInfo(movieId: self.tmdbId, serviceId: service.id, href: serviceHref)
                } else if let episode = self.selectedEpisode {
                    ProgressManager.shared.recordEpisodeServiceInfo(
                        showId: self.tmdbId,
                        seasonNumber: episode.seasonNumber,
                        episodeNumber: episode.episodeNumber,
                        serviceId: service.id,
                        href: serviceHref
                    )
                }
            }
            
            let posterURL = resolvedPosterURL
            var resolvedPlayerMediaInfo: MediaInfo? = nil
            if isMovie {
                resolvedPlayerMediaInfo = .movie(id: tmdbId, title: playerMediaTitle, posterURL: posterURL, isAnime: isAnimeContent)
            } else if let episode = selectedEpisode {
                resolvedPlayerMediaInfo = .episode(showId: tmdbId, seasonNumber: episode.seasonNumber, episodeNumber: episode.episodeNumber, showTitle: playerMediaTitle, showPosterURL: posterURL, isAnime: isAnimeContent)
            }
            let resolvedSubtitleArray = subtitles?.isEmpty == false ? subtitles : nil
            let resolvedPreset = PlayerPreset.presets.first ?? PlayerPreset(id: .sdrRec709, title: "Default", summary: "", stream: nil, commands: [])
            let resolvedLaunchContext = PlaybackLaunchContext(
                traceID: playbackTraceID,
                traceCreatedAt: playbackTraceCreatedAt,
                sourceId: SourceHealth.serviceId(service),
                sourceName: service.metadata.sourceName,
                sourceKind: .service,
                autoMode: autoModeLaunch,
                streamURL: url,
                streamName: streamName,
                headers: finalHeaders,
                subtitles: resolvedSubtitleArray ?? [],
                subtitleNames: subtitleNames,
                subtitleHeadersByURL: subtitleHeadersByURL,
                retryCount: retryCount,
                titleCandidates: titleMatchCandidates(),
                serviceContentHref: serviceHref
            )
            let resolvedAnimeHint = hasAnimeLookupContext

            if onResolvedPlaybackRequest != nil {
                guard playbackRecoveryIdentityIsCurrent else {
                    Logger.shared.log("ServicesResultsSheet: discarded stale service resolution before caller handoff", type: "Player")
                    return
                }
                let request = PlayerResolvedPlaybackRequest(
                    url: streamURL,
                    preset: resolvedPreset,
                    headers: finalHeaders,
                    subtitles: resolvedSubtitleArray,
                    subtitleNames: subtitleNames,
                    subtitleHeadersByURL: subtitleHeadersByURL,
                    mediaInfo: resolvedPlayerMediaInfo,
                    imdbId: imdbId,
                    isAnimeHint: resolvedAnimeHint,
                    isAnimationContentHint: isAnimationGenre16,
                    originalTMDBSeasonNumber: effectivePlaybackContext?.resolvedTMDBSeasonNumber ?? originalTMDBSeasonNumber,
                    originalTMDBEpisodeNumber: effectivePlaybackContext?.resolvedTMDBEpisodeNumber ?? originalTMDBEpisodeNumber,
                    episodePlaybackContext: effectivePlaybackContext,
                    launchContext: resolvedLaunchContext,
                    autoModeRecoveryIdentity: autoModeRecoveryIdentity,
                    mediaYear: mediaYear
                )
                finishResolvedPlayback(request)
                return
            }

            presentCoordinatedPlayback(
                url: streamURL,
                preset: resolvedPreset,
                headers: finalHeaders,
                subtitles: resolvedSubtitleArray ?? [],
                subtitleNames: subtitleNames,
                subtitleHeadersByURL: subtitleHeadersByURL,
                mediaInfo: resolvedPlayerMediaInfo,
                imdbID: imdbId,
                launchContext: resolvedLaunchContext,
                isAnime: resolvedAnimeHint,
                isAnimation: isAnimationGenre16,
                originalTMDBSeasonNumber: effectivePlaybackContext?.resolvedTMDBSeasonNumber ?? originalTMDBSeasonNumber,
                originalTMDBEpisodeNumber: effectivePlaybackContext?.resolvedTMDBEpisodeNumber ?? originalTMDBEpisodeNumber,
                sourceName: service.metadata.sourceName
            )
            return
        }
    }
    
#if !os(tvOS)
    private func downloadStreamURL(
        _ url: String,
        service: Service,
        subtitle: String?,
        subtitleHeaders: [String: String]? = nil,
        headers: [String: String]?,
        streamName: String? = nil,
        serviceHref: String? = nil,
        autoModeLaunch: Bool = false
    ) {
        guard let parsed = URL(string: url),
              parsed.scheme == "http" || parsed.scheme == "https" else {
            Logger.shared.log("Invalid download stream URL: \(ServiceSandboxState.redactedURL(url))", type: "Error")
            handleServicePlaybackPreparationFailure(
                service,
                message: "The source did not return a playable HTTP download stream.",
                autoModeLaunch: autoModeLaunch
            )
            return
        }

        viewModel.resetStreamState()
        
        let serviceURL = service.metadata.baseUrl
        var finalHeaders: [String: String] = [
            "Origin": serviceURL,
            "Referer": serviceURL,
            "User-Agent": URLSession.randomUserAgent
        ]
        
        if let custom = headers {
            for (k, v) in custom {
                finalHeaders[k] = v
            }
            if finalHeaders["User-Agent"] == nil {
                finalHeaders["User-Agent"] = URLSession.randomUserAgent
            }
        }
        
        let posterURL = resolvedPosterURL
        
        let displayTitle: String
        if isMovie {
            displayTitle = effectiveTitle
        } else if let ep = selectedEpisode {
            if specialTitleOnlySearch {
                displayTitle = animeSeasonTitle != nil ? animeEffectiveTitle : effectiveTitle
            } else if isAnimeContent || animeSeasonTitle != nil {
                displayTitle = "\(animeEffectiveTitle) E\(ep.episodeNumber)"
            } else {
                displayTitle = "\(effectiveTitle) S\(ep.seasonNumber)E\(ep.episodeNumber)"
            }
        } else {
            displayTitle = effectiveTitle
        }

        if autoModeLaunch {
            viewModel.isFetchingStreams = true
            viewModel.currentFetchingTitle = service.metadata.sourceName
            viewModel.streamFetchProgress = "Checking download stream..."
            cancelAutoModeDownloadValidation()
            autoModeDownloadTask = Task { @MainActor in
                let result = await DownloadManager.shared.enqueueValidatedAutoModeDownload(
                    tmdbId: tmdbId,
                    isMovie: isMovie,
                    title: playerMediaTitle,
                    displayTitle: displayTitle,
                    posterURL: posterURL,
                    seasonNumber: selectedEpisode?.seasonNumber,
                    episodeNumber: selectedEpisode?.episodeNumber,
                    episodeName: selectedEpisode?.name,
                    streamURL: url,
                    headers: finalHeaders,
                    subtitleURL: subtitle,
                    subtitleHeaders: subtitleHeaders,
                    serviceBaseURL: serviceURL,
                    sourceId: SourceHealth.serviceId(service),
                    serviceContentHref: serviceHref,
                    streamName: streamName,
                    isAnime: isAnimeContent,
                    episodePlaybackContext: effectivePlaybackContext,
                    cancellationRequested: { autoModeCancelled }
                )

                switch result {
                case .accepted:
                    viewModel.isFetchingStreams = false
                    Logger.shared.log("Auto Mode download verified and enqueued: \(displayTitle)", type: "Download")
                    onDownloadEnqueued?()
                    presentationMode.wrappedValue.dismiss()
                case .invalid(let reason):
                    handleServicePlaybackPreparationFailure(
                        service,
                        message: "Download verification failed. \(reason)",
                        autoModeLaunch: true
                    )
                case .cloudflareChallenge(let challengeURL):
                    // Same recovery as auto-mode streaming: show the verification once, then retry
                    // THIS source's download rather than skipping to a worse candidate.
                    viewModel.pendingCloudflareURL = challengeURL
                    viewModel.pendingCloudflareRetry = {
                        self.downloadStreamURL(
                            url,
                            service: service,
                            subtitle: subtitle,
                            subtitleHeaders: subtitleHeaders,
                            headers: headers,
                            streamName: streamName,
                            serviceHref: serviceHref,
                            autoModeLaunch: true
                        )
                    }
                    resolveCloudflareChallengeDuringAutoMode(
                        challengeURL,
                        sourceName: service.metadata.sourceName,
                        fallbackMessage: "Download verification failed. Cloudflare verification is required before this source can download."
                    )
                case .cancelled:
                    viewModel.isFetchingStreams = false
                }
            }
            return
        }
        
        DownloadManager.shared.enqueueDownload(
            tmdbId: tmdbId,
            isMovie: isMovie,
            title: playerMediaTitle,
            displayTitle: displayTitle,
            posterURL: posterURL,
            seasonNumber: selectedEpisode?.seasonNumber,
            episodeNumber: selectedEpisode?.episodeNumber,
            episodeName: selectedEpisode?.name,
            streamURL: url,
            headers: finalHeaders,
            subtitleURL: subtitle,
            subtitleHeaders: subtitleHeaders,
            serviceBaseURL: serviceURL,
            sourceId: SourceHealth.serviceId(service),
            serviceContentHref: serviceHref,
            streamName: streamName,
            isAnime: isAnimeContent,
            episodePlaybackContext: effectivePlaybackContext
        )
        
        Logger.shared.log("Download enqueued: \(displayTitle)", type: "Download")
        
        // Notify parent that download was enqueued (for Download All flow)
        onDownloadEnqueued?()
        
        // Dismiss the sheet after enqueuing
        presentationMode.wrappedValue.dismiss()
    }
#endif
    
    private func safeConvertToHeaders(_ value: Any?) -> [String: String]? {
        guard let value = value else { return nil }
        
        if value is NSNull { return nil }
        
        if let headers = value as? [String: String] {
            return headers
        }
        
        if let headersAny = value as? [String: Any] {
            var safeHeaders: [String: String] = [:]
            for (key, val) in headersAny {
                if let stringValue = val as? String {
                    safeHeaders[key] = stringValue
                } else if let numberValue = val as? NSNumber {
                    safeHeaders[key] = numberValue.stringValue
                } else if !(val is NSNull) {
                    safeHeaders[key] = String(describing: val)
                }
            }
            return safeHeaders.isEmpty ? nil : safeHeaders
        }
        
        if let headersAny = value as? [AnyHashable: Any] {
            var safeHeaders: [String: String] = [:]
            for (key, val) in headersAny {
                let stringKey = String(describing: key)
                if let stringValue = val as? String {
                    safeHeaders[stringKey] = stringValue
                } else if let numberValue = val as? NSNumber {
                    safeHeaders[stringKey] = numberValue.stringValue
                } else if !(val is NSNull) {
                    safeHeaders[stringKey] = String(describing: val)
                }
            }
            return safeHeaders.isEmpty ? nil : safeHeaders
        }
        
        Logger.shared.log("Unable to safely convert headers of type: \(type(of: value))", type: "Warning")
        return nil
    }
}

struct CompactMediaResultRow: View {
    let result: SearchItem
    let originalTitle: String
    let alternativeTitle: String?
    let episode: TMDBEpisode?
    let onTap: () -> Void
    let highQualityThreshold: Double
    
    private var similarityScore: Double {
        let primarySimilarity = calculateSimilarity(original: originalTitle, result: result.title)
        let alternativeSimilarity = alternativeTitle.map { calculateSimilarity(original: $0, result: result.title) } ?? 0.0
        return max(primarySimilarity, alternativeSimilarity)
    }
    
    private var scoreColor: Color {
        if similarityScore >= highQualityThreshold { return .green }
        else if similarityScore >= 0.75 { return .orange }
        else { return .red }
    }
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                KFImage(URL(string: result.imageUrl))
                    .placeholder {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .overlay(
                                Image(systemName: "photo")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            )
                    }
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 55)
                    .cornerRadius(6)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                    
                    HStack {
                        Text("\(Int(similarityScore * 100))%")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(scoreColor)
                        
                        Spacer()
                        
                        Image(systemName: "play.circle")
                            .font(.caption)
                    }
                }
                
                Spacer()
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private func calculateSimilarity(original: String, result: String) -> Double {
        return AlgorithmManager.shared.calculateSimilarity(original: original, result: result)
    }
}

private extension View {
    func stremioStyleStreamCard() -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct EnhancedMediaResultRow: View {
    let result: SearchItem
    let originalTitle: String
    let alternativeTitle: String?
    let episode: TMDBEpisode?
    let onTap: () -> Void
    let highQualityThreshold: Double
    
    private var similarityScore: Double {
        let primarySimilarity = calculateSimilarity(original: originalTitle, result: result.title)
        let alternativeSimilarity = alternativeTitle.map { calculateSimilarity(original: $0, result: result.title) } ?? 0.0
        return max(primarySimilarity, alternativeSimilarity)
    }
    
    private var scoreColor: Color {
        if similarityScore >= highQualityThreshold { return .green }
        else if similarityScore >= 0.75 { return .orange }
        else { return .red }
    }
    
    private var matchQuality: String {
        if similarityScore >= highQualityThreshold { return "Excellent" }
        else if similarityScore >= 0.75 { return "Good" }
        else { return "Fair" }
    }
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                KFImage(URL(string: result.imageUrl))
                    .placeholder {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.2))
                            .overlay(
                                Image(systemName: "photo")
                                    .font(.title2)
                                    .foregroundColor(.gray)
                            )
                    }
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 70, height: 95)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                
                VStack(alignment: .leading, spacing: 8) {
                    Text(result.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundColor(.primary)
                    
                    if let episode = episode {
                        HStack {
                            Image(systemName: "tv")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text("Episode \(episode.episodeNumber)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            if !episode.name.isEmpty {
                                Text("• \(episode.name)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    
                    HStack {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(scoreColor)
                                .frame(width: 6, height: 6)
                            
                            Text(matchQuality)
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundColor(scoreColor)
                        }
                        
                        Text("• \(Int(similarityScore * 100))% match")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Image(systemName: "play.circle.fill")
                            .font(.title2)
                            .tint(Color.accentColor)
                    }
                }
                
                Spacer()
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private func calculateSimilarity(original: String, result: String) -> Double {
        return AlgorithmManager.shared.calculateSimilarity(original: original, result: result)
    }
}
