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
    /// Non-nil for anime to force E## format
    let animeSeasonTitle: String?
    let posterPath: String?
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
    /// Called when a download has been enqueued (for Download All flow)
    var onDownloadEnqueued: (() -> Void)? = nil
    /// Called when user taps "Skip" (for Download All flow)
    var onSkipRequested: (() -> Void)? = nil
    /// When provided, selecting a source resolves a request instead of presenting a new player.
    var onResolvedPlaybackRequest: ((PlayerResolvedPlaybackRequest) -> Void)? = nil
    /// TMDB genre 16 (animation) hint, used to distinguish western cartoons from live action.
    var isAnimationGenre16: Bool = false

    @Environment(\.presentationMode) var presentationMode
    @StateObject private var viewModel = ModulesSearchResultsViewModel()
    @StateObject private var serviceManager = ServiceManager.shared
    @StateObject private var stremioManager = StremioAddonManager.shared
    @StateObject private var algorithmManager = AlgorithmManager.shared
    @StateObject private var healthStore = SourceHealthStore.shared
    @State private var autoModeDidRun = false
    @State private var autoModeRunToken: String?
    @State private var autoModeCancelled = false
    @State private var autoModeAttemptedSourceIds: Set<String> = []
    @State private var autoModeRetryScheduled = false
    @State private var autoModeLastFailureMessage: String?
    @State private var autoModeDownloadTask: Task<Void, Never>?
    @State private var serviceStreamExtractionRequest: JSCallbackDeadline<ServiceStreamExtractionResult>?
    @State private var serviceStreamExtractionGeneration: UUID?
    @State private var showManualPicker = false
    @State private var sheetHostController: UIViewController?
    @AppStorage(ServicesSheetPresentationSettings.stremioStyleEnabledKey) private var stremioStyleSheetEnabled = ServicesSheetPresentationSettings.defaultStremioStyleEnabled
    @State private var selectedStremioStyleSourceId: String?
    private static let autoModeInitialMatchThreshold = 0.85
    private static let maxRetainedServiceResultsPerService = 300
    private static let maxVisibleServiceResultsPerService = 80
    private static let maxRetainedStremioStreamsPerAddon = 300
    private static let maxVisibleStremioStreamsPerAddon = 80

    private var effectiveTitle: String { seasonTitleOverride ?? mediaTitle }
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
        guard let selectedEpisode else { return episodePlaybackContext }
        return episodePlaybackContext?.forEpisodeNumber(selectedEpisode.episodeNumber)
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

    private var sourceKindList: String {
        "services or addons"
    }

    private var sourceKindSelectionList: String {
        "service or addon"
    }

    private var stremioCatalogTitleCandidates: [String] {
        var candidates: [String] = []
        if hasAnimeLookupContext,
           let originalTitle,
           !originalTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(originalTitle)
        }
        candidates.append(contentsOf: titleRankingCandidates())
        candidates.append(displayTitle)
        if let fallbackAnimeSearchQuery {
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
        let anySearching = viewModel.isSearching || viewModel.isSearchingStremio
        if anySearching {
            let completed = viewModel.searchedServices.count + viewModel.stremioSearchedAddons.count
            let total = viewModel.totalServicesCount + stremioManager.activeAddons.count
            return "Searching... (\(completed)/\(total))"
        }
        return "Search complete"
    }
    
    private var searchStatusColor: Color {
        (viewModel.isSearching || viewModel.isSearchingStremio) ? .secondary : .green
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
            
            if viewModel.isSearching || viewModel.isSearchingStremio {
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

        var id: String {
            switch self {
            case .service(let s): return s.id.uuidString
            case .stremio(let a): return a.id.uuidString
            }
        }

        var sortIndex: Int64 {
            switch self {
            case .service(let s): return s.sortIndex
            case .stremio(let a): return a.sortIndex
            }
        }

        var sourceId: String {
            switch self {
            case .service(let s): return SourceHealth.serviceId(s)
            case .stremio(let a): return SourceHealth.stremioId(a)
            }
        }

        var displayName: String {
            switch self {
            case .service(let s): return s.metadata.sourceName
            case .stremio(let a): return a.manifest.name
            }
        }
    }

    private var sortedResultItems: [ResultItem] {
        let services: [ResultItem] = serviceManager.activeServices.map { .service($0) }
        let addons: [ResultItem] = stremioManager.activeAddons.map { .stremio($0) }
        let orderRank = autoModeSourceOrderRank
        return (services + addons).sorted {
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
        return orderedIds.compactMap { byId[$0] }
    }

    @ViewBuilder
    private var unifiedResultsSections: some View {
        ForEach(sortedResultItems) { item in
            switch item {
            case .service(let service):
                serviceSection(service: service)
            case .stremio(let addon):
                stremioAddonSection(addon: addon)
            }
        }
    }

    private var stremioStyleResultItems: [ResultItem] {
        guard let selectedStremioStyleSourceId else { return sortedResultItems }
        return sortedResultItems.filter { $0.sourceId == selectedStremioStyleSourceId }
    }

    private var hasStremioStyleResults: Bool {
        stremioStyleResultItems.contains { item in
            switch item {
            case .service(let service):
                guard let results = viewModel.moduleResults[service.id] else { return false }
                // `filterResults` ranks every element and then partitions a
                // non-empty prefix, so existence is exactly `!results.isEmpty`.
                return !results.isEmpty
            case .stremio(let addon):
                return !(viewModel.stremioResults[addon.id] ?? []).isEmpty
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
                if viewModel.isSearching || viewModel.isSearchingStremio {
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
                if let results = viewModel.moduleResults[service.id] {
                    let filtered = filterResults(for: results)
                    let visibleResults = filtered.highQuality + filtered.lowQuality
                    ForEach(visibleResults, id: \.id) { result in
                        stremioStyleServiceRow(result: result, service: service)
                    }
                }
            case .stremio(let addon):
                if let streams = viewModel.stremioResults[addon.id] {
                    ForEach(Array(streams.prefix(Self.maxVisibleStremioStreamsPerAddon).enumerated()), id: \.offset) { _, stream in
                        stremioStyleStreamRow(stream: stream, addon: addon)
                    }
                }
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
                if results.isEmpty {
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
        TextField("Threshold (0.0 - 1.0)", value: $viewModel.highQualityThreshold, format: .number)
            .keyboardType(.decimalPad)
        
        Button("Save") {
            viewModel.highQualityThreshold = max(0.0, min(1.0, viewModel.highQualityThreshold))
            UserDefaults.standard.set(viewModel.highQualityThreshold, forKey: "highQualityThreshold")
        }
        
        Button("Cancel", role: .cancel) {
            viewModel.highQualityThreshold = UserDefaults.standard.object(forKey: "highQualityThreshold") as? Double ?? 0.9
        }
    }
    
    @ViewBuilder
    private var qualityThresholdAlertMessage: some View {
        Text("Set the minimum similarity score (0.0 to 1.0) for results to be considered high quality. Current: \(String(format: "%.2f", viewModel.highQualityThreshold)) (\(Int(viewModel.highQualityThreshold * 100))%)")
    }
    
    @ViewBuilder
    private var serverSelectionDialogContent: some View {
        ForEach(viewModel.streamOptions) { option in
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
                        serviceHref: viewModel.pendingServiceHref
                    )
                }
            }
        }
        Button("No Subtitles") {
            viewModel.showingSubtitlePicker = false
            if let service = viewModel.pendingService,
               let streamURL = viewModel.pendingStreamURL {
                dispatchStreamAction(streamURL, service: service, subtitle: nil, headers: viewModel.pendingHeaders, streamName: viewModel.pendingStreamName, serviceHref: viewModel.pendingServiceHref)
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
        let threshold = viewModel.highQualityThreshold
        let highQuality = sortedResults.filter { $0.initialSimilarity >= threshold }.map { $0.result }
        let lowQuality = sortedResults.filter { $0.initialSimilarity < threshold }.map { $0.result }
        
        return (highQuality, lowQuality)
    }

    private var isAutoModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "servicesAutoModeEnabled")
    }

    private var selectedAutoModeSourceIds: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "servicesAutoModeSourceIds") ?? [])
    }

    private func autoModeUnavailableMessage() -> String {
        let selectedActive = sortedResultItems.filter { selectedAutoModeSourceIds.contains($0.sourceId) }
        guard !selectedActive.isEmpty else {
            return "Auto Mode is enabled, but no active \(sourceKindSelectionList) is selected. Please select at least one source in Services settings."
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
            let lhsEligible = lhs.initialSimilarity >= Self.autoModeInitialMatchThreshold
            let rhsEligible = rhs.initialSimilarity >= Self.autoModeInitialMatchThreshold

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
        return [
            sheetTitleBaseForMatching,
            effectiveTitle,
            mediaTitle,
            normalizedAnimeSequelTitle,
            strippedAnimeFallbackTitle,
            originalTitle
        ]
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
            normalizedAnimeSequelTitle,
            strippedAnimeFallbackTitle
        ]

        if !(isAnimeContent || animeSeasonTitle != nil) {
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
        return rankedServiceResults(results)
            .first { $0.initialSimilarity >= Self.autoModeInitialMatchThreshold }?
            .result
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
            streamsAreFiltered: true
        )
    }

    private func filteredStremioStreams(_ streams: [StremioStream], addon: StremioAddon) -> [StremioStream] {
        let sourceId = SourceHealth.stremioId(addon)
        guard let configuration = StreamLanguageFilter.configuration(sourceId: sourceId) else {
            return Array(streams.prefix(Self.maxRetainedStremioStreamsPerAddon))
        }
        return Array(
            streams.lazy
                .filter { !StreamLanguageFilter.shouldHide(stremio: $0, configuration: configuration) }
                .prefix(Self.maxRetainedStremioStreamsPerAddon)
        )
    }

    private func filteredServiceStreamOptions(_ options: [StreamOption], service: Service) -> [StreamOption] {
        let sourceId = SourceHealth.serviceId(service)
        guard let configuration = StreamLanguageFilter.configuration(sourceId: sourceId) else {
            return options
        }
        return options.filter { option in
            !StreamLanguageFilter.shouldHide(
                languageHints: option.languageHints,
                metadata: [option.name, option.url] + option.metadataHints,
                configuration: configuration
            )
        }
    }

    @MainActor
    private func maybeRunAutoModeSelection() {
        guard !autoModeOnly,
              isAutoModeEnabled,
              !autoModeDidRun,
              !viewModel.isSearching,
              !viewModel.isSearchingStremio else { return }

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
            }
        }

        viewModel.streamError = "Auto Mode could not find a playable match in the selected sources. Try selecting more \(sourceKindList)."
        viewModel.showingStreamError = true
    }

    private var requestToken: String {
        [
            downloadMode ? "download" : "play",
            isMovie ? "movie" : "show",
            "\(tmdbId)",
            "\(selectedEpisode?.seasonNumber ?? 0)",
            "\(selectedEpisode?.episodeNumber ?? 0)"
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
    private func finishResolvedPlayback(_ request: PlayerResolvedPlaybackRequest) {
        guard let onResolvedPlaybackRequest else { return }

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
    private func captureSheetHostControllerIfNeeded() {
        guard sheetHostController == nil,
              let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else {
            return
        }

        sheetHostController = rootVC.topmostViewController()
    }

    @MainActor
    private func currentTopmostViewController() -> UIViewController? {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else {
            return nil
        }

        return rootVC.topmostViewController()
    }

    @MainActor
    private func dismissAutoModeSheetBeforePlaybackIfNeeded(_ completion: @escaping (UIViewController?) -> Void) {
        guard shouldDismissAutoModeSheetBeforePlayback else {
            completion(currentTopmostViewController())
            return
        }

        if let hostController = sheetHostController,
           hostController.presentingViewController != nil {
            hostController.dismiss(animated: true) {
                Task { @MainActor in
                    self.sheetHostController = nil
                    completion(self.currentTopmostViewController())
                }
            }
            return
        }

        presentationMode.wrappedValue.dismiss()
        sheetHostController = nil
        DispatchQueue.main.async {
            Task { @MainActor in
                completion(self.currentTopmostViewController())
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
                    autoModeCancelled = true
                    autoModeDidRun = true
                    cancelAutoModeDownloadValidation()
                    presentationMode.wrappedValue.dismiss()
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
    private func startAutoModeIfNeeded() {
        guard isAutoModeEnabled, !showManualPicker else { return }
        guard autoModeRunToken != requestToken else { return }

        autoModeRunToken = requestToken
        autoModeDidRun = true
        autoModeCancelled = false
        autoModeAttemptedSourceIds.removeAll()
        autoModeRetryScheduled = false
        autoModeLastFailureMessage = nil
        viewModel.moduleResults.removeAll()
        viewModel.stremioResults.removeAll()
        viewModel.searchedServices.removeAll()
        viewModel.stremioSearchedAddons.removeAll()
        viewModel.failedServices.removeAll()
        viewModel.streamError = nil
        viewModel.showingStreamError = false
        viewModel.isSearching = false
        viewModel.isSearchingStremio = false
        viewModel.currentFetchingTitle = ""
        viewModel.streamFetchProgress = "Checking selected sources..."

        Task { @MainActor in
            await runOrderedAutoModeSelection()
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
        if let fallbackAnimeSearchQuery,
           fallbackAnimeSearchQuery.caseInsensitiveCompare(primary) != .orderedSame {
            queries.append(fallbackAnimeSearchQuery)
        }
        if primary.caseInsensitiveCompare(effectiveTitle) != .orderedSame {
            queries.append(effectiveTitle)
        }
        if let originalTitle, !originalTitle.isEmpty && originalTitle.lowercased() != effectiveTitle.lowercased() {
            queries.append(originalTitle)
        }
        return queries
    }

    @MainActor
    private func runOrderedAutoModeSelection() async {
        let orderedItems = activeAutoModeItems
        guard !orderedItems.isEmpty else {
            showAutoModeFailure(autoModeUnavailableMessage())
            return
        }

        for item in orderedItems where !autoModeAttemptedSourceIds.contains(item.sourceId) {
            guard !autoModeCancelled else { return }
            autoModeAttemptedSourceIds.insert(item.sourceId)
            switch item {
            case .service(let service):
                viewModel.currentFetchingTitle = service.metadata.sourceName
                viewModel.streamFetchProgress = "Searching \(service.metadata.sourceName)..."
                if let result = await findAutoModeServiceResult(service) {
                    guard !autoModeCancelled else { return }
                    viewModel.currentFetchingTitle = result.title
                    viewModel.streamFetchProgress = "Found match in \(service.metadata.sourceName). Fetching stream..."
                    await playContent(result, autoModeLaunch: true)
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
                    guard !autoModeCancelled else { return }
                    viewModel.currentFetchingTitle = stream.displayName
                    viewModel.streamFetchProgress = "Found stream in \(addon.manifest.name)."
                    playStremioStream(stream, addon: addon, autoModeLaunch: true)
                    return
                }
                if !autoModeCancelled {
                    updateAutoModeSourceStatus(
                        sourceName: addon.manifest.name,
                        message: "No playable stream was returned. Trying the next selected source..."
                    )
                }
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
            guard !autoModeCancelled else { return nil }
            viewModel.streamFetchProgress = "Searching \(service.metadata.sourceName) for \(query)..."
            let results = await serviceManager.searchSingleActiveService(service: service, query: query)
            guard !autoModeCancelled else { return nil }
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

    @MainActor
    private func showAutoModeFailure(_ message: String) {
        viewModel.isFetchingStreams = false
        viewModel.streamError = message
        viewModel.showingStreamError = true
    }

    @MainActor
    private func updateAutoModeSourceStatus(sourceName: String, message: String) {
        autoModeLastFailureMessage = "\(sourceName): \(message)"
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
        showManualPicker = true
        viewModel.moduleResults.removeAll()
        viewModel.stremioResults.removeAll()
        viewModel.searchedServices.removeAll()
        viewModel.stremioSearchedAddons.removeAll()
        viewModel.failedServices.removeAll()
        viewModel.streamError = nil
        viewModel.showingStreamError = false
        startProgressiveSearch()
        startStremioSearch()
    }
    
    var body: some View {
        NavigationView {
            Group {
                if autoModeOnly && !showManualPicker {
                    autoModeProgressView
                } else if stremioStyleSheetEnabled {
                    List {
                        stremioStyleHeader

                        if serviceManager.activeServices.isEmpty && stremioManager.activeAddons.isEmpty {
                            noActiveServicesSection
                        } else if hasStremioStyleResults {
                            stremioStyleResults
                        } else if !(viewModel.isSearching || viewModel.isSearchingStremio) {
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

                        if serviceManager.activeServices.isEmpty && stremioManager.activeAddons.isEmpty {
                            noActiveServicesSection
                        } else {
                            unifiedResultsSections
                        }
                    }
                    .eclipseSettingsStyle(allowsAnimatedBackground: false)
                }
            }
            .navigationTitle(autoModeOnly && !showManualPicker ? (downloadMode ? "Auto Download" : "Auto Mode") : (downloadMode ? "Download Source" : "Services Result"))
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
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
                        
                        Section("Filter Settings") {
                            Button(action: {
                                viewModel.showingFilterEditor = true
                            }) {
                                HStack {
                                    Image(systemName: "slider.horizontal.3")
                                    Text("Quality Threshold")
                                    Spacer()
                                    Text("\(Int(viewModel.highQualityThreshold * 100))%")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        if downloadMode && onSkipRequested != nil {
                            Button("Skip") {
                                onSkipRequested?()
                                presentationMode.wrappedValue.dismiss()
                            }
                        }
                        
                        Button("Done") {
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                }
            }
        }
        .alert(downloadMode ? "Download Content" : "Play Content", isPresented: $viewModel.showingPlayAlert) {
            playAlertButtons
        } message: {
            playAlertMessage
        }
        .overlay(streamFetchingOverlay)
        .onAppear {
            captureSheetHostControllerIfNeeded()
            autoModeDidRun = false
            if autoModeOnly && !showManualPicker {
                startAutoModeIfNeeded()
            } else {
                startProgressiveSearch()
                startStremioSearch()
            }
        }
        .onChangeComp(of: requestToken) { _, _ in
            Logger.shared.log("ServicesResultsSheet request token changed: \(requestToken)", type: "Stream")
            cancelAutoModeDownloadValidation()
            autoModeDidRun = false
            autoModeRunToken = nil
            autoModeCancelled = false
            if autoModeOnly && !showManualPicker {
                startAutoModeIfNeeded()
            }
        }
        .onChangeComp(of: viewModel.isSearching) { _, _ in
            maybeRunAutoModeSelection()
        }
        .onChangeComp(of: viewModel.isSearchingStremio) { _, _ in
            maybeRunAutoModeSelection()
        }
        .alert("Quality Threshold", isPresented: $viewModel.showingFilterEditor) {
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
                        autoModeCancelled = true
                        cancelAutoModeDownloadValidation()
                        viewModel.streamError = nil
                        onSkipRequested?()
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                Button("Manual Select") {
                    switchToManualPicker()
                }
                Button(downloadMode && onSkipRequested != nil ? "Stop Downloads" : "Cancel", role: .cancel) {
                    autoModeCancelled = true
                    cancelAutoModeDownloadValidation()
                    viewModel.streamError = nil
                    presentationMode.wrappedValue.dismiss()
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
            cancelAutoModeDownloadValidation()
            serviceStreamExtractionGeneration = nil
            serviceStreamExtractionRequest?.cancel()
            serviceStreamExtractionRequest = nil
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
        .adaptiveConfirmationDialog("Select Stream", isPresented: $viewModel.showingStremioStreamPicker, titleVisibility: .visible) {
            stremioStreamPickerContent
        } message: {
            stremioStreamPickerMessage
        }
    }
    
    private func startProgressiveSearch() {
        let activeServices = serviceManager.activeServices
        viewModel.totalServicesCount = activeServices.count
        
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
                        self.viewModel.moduleResults[service.id] = self.retainedServiceResults(results ?? [])
                        self.viewModel.searchedServices.insert(service.id)
                        
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
                                        let additional = additionalResults ?? []
                                        let existing = self.viewModel.moduleResults[service.id] ?? []
                                        self.viewModel.moduleResults[service.id] = self.mergedServiceResults(existing: existing, additional: additional)
                                        
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
                                                        let additional = additionalResults ?? []
                                                        let existing = self.viewModel.moduleResults[service.id] ?? []
                                                        self.viewModel.moduleResults[service.id] = self.mergedServiceResults(existing: existing, additional: additional)
                                                        
                                                        if additionalResults == nil {
                                                            self.viewModel.failedServices.insert(service.id)
                                                        }
                                                    }
                                                },
                                                onComplete: {
                                                    Task { @MainActor in
                                                        self.viewModel.isSearching = false
                                                    }
                                                }
                                            )
                                        }
                                    } else {
                                        Task { @MainActor in
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
                                        let additional = additionalResults ?? []
                                        let existing = self.viewModel.moduleResults[service.id] ?? []
                                        self.viewModel.moduleResults[service.id] = self.mergedServiceResults(existing: existing, additional: additional)
                                        
                                        if additionalResults == nil {
                                            self.viewModel.failedServices.insert(service.id)
                                        }
                                    }
                                },
                                onComplete: {
                                    Task { @MainActor in
                                        self.viewModel.isSearching = false
                                    }
                                }
                            )
                        }
                    } else {
                        Task { @MainActor in
                            self.viewModel.isSearching = false
                        }
                    }
                }
            )
        }
    }

    // MARK: - Stremio Addon Search

    private func startStremioSearch() {
        let active = stremioManager.activeAddons
        guard !active.isEmpty else { return }

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
                        self.viewModel.stremioResults[addon.id] = self.filteredStremioStreams(streams, addon: addon)
                        self.viewModel.stremioSearchedAddons.insert(addon.id)
                    }
                },
                onComplete: {
                    Task { @MainActor in
                        self.viewModel.isSearchingStremio = false
                    }
                }
            )
        }
    }

    // MARK: - Stremio Results Section

    @ViewBuilder
    private func stremioAddonSection(addon: StremioAddon) -> some View {
        let streams = viewModel.stremioResults[addon.id]
        let hasSearched = viewModel.stremioSearchedAddons.contains(addon.id)
        let isCurrentlySearching = viewModel.isSearchingStremio && !hasSearched

        if let streams = streams {
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
        if let streams = viewModel.stremioStreamOptions {
            ForEach(Array(streams.prefix(Self.maxVisibleStremioStreamsPerAddon))) { stream in
                Button {
                    viewModel.showingStremioStreamPicker = false
                    if let addon = viewModel.selectedStremioAddon {
                        playStremioStream(stream, addon: addon, autoModeLaunch: viewModel.pendingPlaybackAutoMode)
                    }
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

    // MARK: - Play / Download Stremio Stream

    private func playStremioStream(_ stream: StremioStream, addon: StremioAddon, autoModeLaunch: Bool = false, retryCount: Int = 0) {
        guard !StreamLanguageFilter.shouldHide(
            stremio: stream,
            sourceId: SourceHealth.stremioId(addon)
        ) else {
            Logger.shared.log("Stremio: stream hidden by extra service settings addon=\(addon.manifest.name)", type: "Stream")
            handleStremioPlaybackPreparationFailure(
                addon,
                message: "This Stremio stream is hidden by your extra service settings.",
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
        let allSubtitles: [(url: String, lang: String?)] = (stream.subtitles ?? []).compactMap { sub in
            guard let url = sub.url, !url.isEmpty else { return nil }
            return (url: url, lang: sub.lang)
        }
        let subtitleURLs = allSubtitles.map { $0.url }
        let subtitleNames = allSubtitles.map { $0.lang ?? "Unknown" }

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

            if onResolvedPlaybackRequest == nil,
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

            let inAppPlayer = Settings.normalizedInAppPlayer(UserDefaults.standard.string(forKey: "inAppPlayer"))
            Logger.shared.log("Playback resolve diagnostics source=\(addon.manifest.name) kind=stremio player=\(inAppPlayer) host=\(streamURL.host ?? "nil") ext=\(streamURL.pathExtension.isEmpty ? "none" : streamURL.pathExtension) namedStream=\(streamName?.isEmpty == false) headerKeys=[\(finalHeaders.keys.sorted().joined(separator: ","))] subtitles=\(subtitles.count) autoMode=\(autoModeLaunch)", type: "StreamDiagnostics")
            Logger.shared.log("[PlaybackTrace \(playbackTraceID)] stage=resolved source=\(addon.manifest.name) kind=stremio player=\(inAppPlayer) host=\(streamURL.host ?? "nil") autoMode=\(autoModeLaunch) retry=\(retryCount)", type: "PlaybackTrace")

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
                    launchContext: resolvedLaunchContext
                )
                finishResolvedPlayback(request)
                return
            }

#if os(tvOS)
            presentTVPlayback(
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
#else
            if inAppPlayer == "mpv" {
                let preset = PlayerPreset.presets.first
                let subtitleArray: [String]? = subtitles.isEmpty ? nil : subtitles

                let pvc = PlayerViewController(
                    url: streamURL,
                    preset: preset ?? PlayerPreset(id: .sdrRec709, title: "Default", summary: "", stream: nil, commands: []),
                    headers: finalHeaders,
                    subtitles: subtitleArray,
                    subtitleNames: subtitleNames.isEmpty ? nil : subtitleNames,
                    mediaInfo: playerMediaInfo,
                    imdbId: imdbId
                )
                let launchContext = PlaybackLaunchContext(
                    traceID: playbackTraceID,
                    traceCreatedAt: playbackTraceCreatedAt,
                    sourceId: SourceHealth.stremioId(addon),
                    sourceName: addon.manifest.name,
                    sourceKind: .stremio,
                    autoMode: autoModeLaunch,
                    streamURL: url,
                    streamName: streamName,
                    headers: finalHeaders,
                    subtitles: subtitleArray ?? [],
                    subtitleNames: subtitleNames,
                    retryCount: retryCount,
                    titleCandidates: stremioCatalogTitleCandidates
                )
                configurePlaybackRecovery(pvc, context: launchContext)
                let isAnimeHint = hasAnimeLookupContext
                pvc.isAnimeHint = isAnimeHint
                pvc.isAnimationContentHint = isAnimationGenre16
                pvc.originalTMDBSeasonNumber = effectivePlaybackContext?.resolvedTMDBSeasonNumber ?? originalTMDBSeasonNumber
                pvc.originalTMDBEpisodeNumber = effectivePlaybackContext?.resolvedTMDBEpisodeNumber ?? originalTMDBEpisodeNumber
                pvc.episodePlaybackContext = effectivePlaybackContext
                pvc.onRequestNextEpisode = { seasonNumber, nextEpisodeNumber in
                    NotificationCenter.default.post(
                        name: .requestNextEpisode,
                        object: nil,
                        userInfo: [
                            "tmdbId": tmdbId,
                            "seasonNumber": seasonNumber,
                            "episodeNumber": nextEpisodeNumber
                        ]
                    )
                }

                Logger.shared.log("Stremio: presenting \(inAppPlayer) player", type: "Stream")
                pvc.modalPresentationStyle = .fullScreen

                dismissAutoModeSheetBeforePlaybackIfNeeded { topmostVC in
                    if let topmostVC {
                        topmostVC.present(pvc, animated: true, completion: nil)
                    } else {
                        Logger.shared.log("Failed to find root view controller to present player", type: "Error")
                    }
                }
                return
            }

            // Default AVPlayer path
            let asset = AVURLAsset(url: streamURL, options: ["AVURLAssetHTTPHeaderFieldsKey": finalHeaders])
            let playerVC = NormalPlayer()
            let item = AVPlayerItem(asset: asset)
            playerVC.player = AVPlayer(playerItem: item)
            let launchContext = PlaybackLaunchContext(
                traceID: playbackTraceID,
                traceCreatedAt: playbackTraceCreatedAt,
                sourceId: SourceHealth.stremioId(addon),
                sourceName: addon.manifest.name,
                sourceKind: .stremio,
                autoMode: autoModeLaunch,
                streamURL: url,
                streamName: streamName,
                headers: finalHeaders,
                subtitles: subtitles,
                subtitleNames: subtitleNames,
                retryCount: retryCount
            )
            configurePlaybackRecovery(playerVC, context: launchContext)
            if isMovie {
                playerVC.mediaInfo = .movie(id: tmdbId, title: playerMediaTitle, posterURL: posterURL, isAnime: isAnimeContent)
            } else if let episode = selectedEpisode {
                playerVC.mediaInfo = .episode(showId: tmdbId, seasonNumber: episode.seasonNumber, episodeNumber: episode.episodeNumber, showTitle: playerMediaTitle, showPosterURL: posterURL, isAnime: isAnimeContent)
            }
            playerVC.episodePlaybackContext = effectivePlaybackContext
            playerVC.modalPresentationStyle = .fullScreen

            dismissAutoModeSheetBeforePlaybackIfNeeded { topmostVC in
                if let topmostVC {
                    topmostVC.present(playerVC, animated: true) {
                        playerVC.playAtDefaultSpeed()
                    }
                } else {
                    Logger.shared.log("Failed to find root view controller to present player", type: "Error")
                }
            }
#endif
        }
    }

#if os(tvOS)
    @MainActor
    private func presentTVPlayback(
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
            NotificationCenter.default.post(
                name: .requestNextEpisode,
                object: nil,
                userInfo: [
                    "tmdbId": requestedTMDBID,
                    "seasonNumber": seasonNumber,
                    "episodeNumber": nextEpisodeNumber
                ]
            )
        }

        let request = PlaybackRequest(
            url: url,
            preset: preset,
            headers: headers,
            subtitles: subtitles,
            subtitleNames: subtitleNames,
            subtitleHeadersByURL: subtitleHeadersByURL,
            mediaInfo: mediaInfo,
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
            onRequestNextEpisode: nextEpisodeRequest
        )
        let controller = PlaybackCoordinator.shared.makeViewController(for: request)
        controller.modalPresentationStyle = .fullScreen

        Logger.shared.log(
            "ServicesResultsSheet: presenting tvOS playback source=\(sourceName) subtitles=\(subtitles.count) resume=\(resumePosition != nil)",
            type: "Player"
        )
        dismissAutoModeSheetBeforePlaybackIfNeeded { topmostVC in
            guard let topmostVC else {
                self.viewModel.streamError = "Failed to open player. Please try again."
                self.viewModel.showingStreamError = true
                Logger.shared.log("ServicesResultsSheet: no presenter for tvOS playback", type: "Error")
                return
            }
            topmostVC.present(controller, animated: true)
        }
    }
#endif

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
            handleServicePlaybackPreparationFailure(service, message: "All streams from \(service.metadata.sourceName) are hidden by your extra service settings.")
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
                serviceHref: viewModel.pendingServiceHref
            )
        } else if let streamURL = extractSingleStreamURL(streams: streams, sources: sources) {
            if StreamLanguageFilter.shouldHide(
                languageHints: [],
                metadata: [streamURL.url],
                sourceId: SourceHealth.serviceId(service)
            ) {
                Logger.shared.log("Single stream hidden by extra service settings for \(service.metadata.sourceName)", type: "Stream")
                handleServicePlaybackPreparationFailure(service, message: "This stream is hidden by your extra service settings.")
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
            for (idx, source) in sources.enumerated() {
                guard let rawUrl = source["streamUrl"] as? String ?? source["url"] as? String, !rawUrl.isEmpty else { continue }
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
        } else if let streams = streams, streams.count > 1 {
            availableStreams = parseStreamStrings(streams)
        }
        
        return availableStreams
    }
    
    private func parseStreamStrings(_ streams: [String]) -> [StreamOption] {
        var options: [StreamOption] = []
        var index = 0
        var unnamedCount = 1
        
        while index < streams.count {
            let entry = streams[index]
            if isURL(entry) {
                options.append(StreamOption(name: "Stream \(unnamedCount)", url: entry, headers: nil, subtitle: nil, subtitleTracks: []))
                unnamedCount += 1
                index += 1
            } else {
                let nextIndex = index + 1
                if nextIndex < streams.count, isURL(streams[nextIndex]) {
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
        stringValues(in: source, keys: ["lang", "language", "languages", "audioLanguage", "audioLanguages", "dubLanguage", "dubLanguages"])
    }

    private func metadataHints(in source: [String: Any]) -> [String] {
        stringValues(in: source, keys: ["title", "name", "label", "quality", "provider", "type", "filename", "file", "streamName", "server"])
    }

    private func stringValues(in source: [String: Any], keys: [String]) -> [String] {
        keys.flatMap { key -> [String] in
            guard let rawValue = source[key] else { return [] }
            if let value = streamMetadataString(from: rawValue) {
                return [value]
            }
            if let values = rawValue as? [Any] {
                return values.compactMap(streamMetadataString(from:))
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
            if let streamUrl = firstSource["streamUrl"] as? String {
                return (streamUrl, safeConvertToHeaders(firstSource["headers"]))
            } else if let urlString = firstSource["url"] as? String {
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
    private func resolveSubtitleSelection(subtitles: [String]?, defaultSubtitle: String?, service: Service, streamURL: String, headers: [String: String]?, structuredSubtitleTracks: [ServiceSubtitleTrack] = [], streamName: String? = nil, serviceHref: String? = nil) {
        if !structuredSubtitleTracks.isEmpty {
            dispatchStreamAction(
                streamURL,
                service: service,
                subtitle: defaultSubtitle,
                subtitleTracks: structuredSubtitleTracks,
                headers: headers,
                streamName: streamName,
                serviceHref: serviceHref
            )
            return
        }

        guard let subtitles = subtitles, !subtitles.isEmpty else {
            dispatchStreamAction(streamURL, service: service, subtitle: defaultSubtitle, headers: headers, streamName: streamName, serviceHref: serviceHref)
            return
        }
        
        let options = parseSubtitleOptions(from: subtitles)
        guard !options.isEmpty else {
            dispatchStreamAction(streamURL, service: service, subtitle: defaultSubtitle, headers: headers, streamName: streamName, serviceHref: serviceHref)
            return
        }
        
        if options.count == 1 {
            dispatchStreamAction(streamURL, service: service, subtitle: options[0].url, headers: headers, streamName: streamName, serviceHref: serviceHref)
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
        viewModel.isFetchingStreams = false
        viewModel.showingSubtitlePicker = true
    }
    
    /// Routes to either play or download based on downloadMode
    private func dispatchStreamAction(_ url: String, service: Service, subtitle: String?, subtitleTracks: [ServiceSubtitleTrack] = [], subtitleNames: [String]? = nil, subtitleHeadersByURL: [String: [String: String]]? = nil, headers: [String: String]?, streamName: String? = nil, serviceHref: String? = nil) {
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
            
            if onResolvedPlaybackRequest == nil,
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

            let inAppPlayer = Settings.normalizedInAppPlayer(UserDefaults.standard.string(forKey: "inAppPlayer"))
            Logger.shared.log("Playback resolve diagnostics source=\(service.metadata.sourceName) kind=service player=\(inAppPlayer) host=\(streamURL.host ?? "nil") ext=\(streamURL.pathExtension.isEmpty ? "none" : streamURL.pathExtension) namedStream=\(streamName?.isEmpty == false) headerKeys=[\(finalHeaders.keys.sorted().joined(separator: ","))] subtitles=\(subtitles?.count ?? 0) autoMode=\(autoModeLaunch) retry=\(retryCount)", type: "StreamDiagnostics")
            Logger.shared.log("[PlaybackTrace \(playbackTraceID)] stage=resolved source=\(service.metadata.sourceName) kind=service player=\(inAppPlayer) host=\(streamURL.host ?? "nil") autoMode=\(autoModeLaunch) retry=\(retryCount)", type: "PlaybackTrace")
            
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
                    launchContext: resolvedLaunchContext
                )
                finishResolvedPlayback(request)
                return
            }

#if os(tvOS)
            presentTVPlayback(
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
#else
            if inAppPlayer == "mpv" {
                let preset = PlayerPreset.presets.first
                let subtitleArray = resolvedSubtitleArray
                
                // Prepare mediaInfo before creating player
                var playerMediaInfo: MediaInfo? = nil
                let posterURL = resolvedPosterURL
                if isMovie {
                    playerMediaInfo = .movie(id: tmdbId, title: playerMediaTitle, posterURL: posterURL, isAnime: isAnimeContent)
                } else if let episode = selectedEpisode {
                    playerMediaInfo = .episode(showId: tmdbId, seasonNumber: episode.seasonNumber, episodeNumber: episode.episodeNumber, showTitle: playerMediaTitle, showPosterURL: posterURL, isAnime: isAnimeContent)
                }
                
                let pvc = PlayerViewController(
                    url: streamURL,
                    preset: preset ?? PlayerPreset(id: .sdrRec709, title: "Default", summary: "", stream: nil, commands: []),
                    headers: finalHeaders,
                    subtitles: subtitleArray,
                    subtitleNames: subtitleNames,
                    subtitleHeadersByURL: subtitleHeadersByURL,
                    mediaInfo: playerMediaInfo,
                    imdbId: imdbId
                )
                let launchContext = PlaybackLaunchContext(
                    traceID: playbackTraceID,
                    traceCreatedAt: playbackTraceCreatedAt,
                    sourceId: SourceHealth.serviceId(service),
                    sourceName: service.metadata.sourceName,
                    sourceKind: .service,
                    autoMode: autoModeLaunch,
                    streamURL: url,
                    streamName: streamName,
                    headers: finalHeaders,
                    subtitles: subtitleArray ?? [],
                    subtitleNames: subtitleNames,
                    subtitleHeadersByURL: subtitleHeadersByURL,
                    retryCount: retryCount,
                    titleCandidates: titleMatchCandidates(),
                    serviceContentHref: serviceHref
                )
                configurePlaybackRecovery(pvc, context: launchContext)
                let isAnimeHint = hasAnimeLookupContext
                pvc.isAnimeHint = isAnimeHint
                pvc.isAnimationContentHint = isAnimationGenre16
                pvc.originalTMDBSeasonNumber = effectivePlaybackContext?.resolvedTMDBSeasonNumber ?? originalTMDBSeasonNumber
                pvc.originalTMDBEpisodeNumber = effectivePlaybackContext?.resolvedTMDBEpisodeNumber ?? originalTMDBEpisodeNumber
                pvc.episodePlaybackContext = effectivePlaybackContext
                pvc.onRequestNextEpisode = { seasonNumber, nextEpisodeNumber in
                    NotificationCenter.default.post(
                        name: .requestNextEpisode,
                        object: nil,
                        userInfo: [
                            "tmdbId": tmdbId,
                            "seasonNumber": seasonNumber,
                            "episodeNumber": nextEpisodeNumber
                        ]
                    )
                }
                let mediaInfoLabel: String = {
                    guard let info = playerMediaInfo else { return "nil" }
                    switch info {
                    case .movie(let id, let title, _, let isAnime):
                        return "movie id=\(id) title=\(title) isAnime=\(isAnime)"
                    case .episode(let showId, let seasonNumber, let episodeNumber, let showTitle, _, let isAnime):
                        return "episode showId=\(showId) s=\(seasonNumber) e=\(episodeNumber) title=\(String(describing: showTitle)) isAnime=\(isAnime)"
                    }
                }()
                Logger.shared.log("ServicesResultsSheet: presenting MPV isAnimeHint=\(isAnimeHint) isAnimeContent=\(isAnimeContent) mediaInfo=\(mediaInfoLabel)", type: "Stream")
                pvc.modalPresentationStyle = .fullScreen
                
                dismissAutoModeSheetBeforePlaybackIfNeeded { topmostVC in
                    if let topmostVC {
                        topmostVC.present(pvc, animated: true, completion: nil)
                    } else {
                        Logger.shared.log("Failed to find root view controller to present MPV player", type: "Error")
                    }
                }
                return
            } else {
                let playerVC = NormalPlayer()
                let asset = AVURLAsset(url: streamURL, options: ["AVURLAssetHTTPHeaderFieldsKey": finalHeaders])
                let item = AVPlayerItem(asset: asset)
                playerVC.player = AVPlayer(playerItem: item)
                let launchContext = PlaybackLaunchContext(
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
                configurePlaybackRecovery(playerVC, context: launchContext)
                if isMovie {
                    let posterURL = resolvedPosterURL
                    playerVC.mediaInfo = .movie(id: tmdbId, title: playerMediaTitle, posterURL: posterURL, isAnime: isAnimeContent)
                } else if let episode = selectedEpisode {
                    let posterURL = resolvedPosterURL
                    playerVC.mediaInfo = .episode(showId: tmdbId, seasonNumber: episode.seasonNumber, episodeNumber: episode.episodeNumber, showTitle: playerMediaTitle, showPosterURL: posterURL, isAnime: isAnimeContent)
                }
                playerVC.episodePlaybackContext = effectivePlaybackContext
                playerVC.modalPresentationStyle = .fullScreen
                
                dismissAutoModeSheetBeforePlaybackIfNeeded { topmostVC in
                    if let topmostVC {
                        topmostVC.present(playerVC, animated: true) {
                            playerVC.playAtDefaultSpeed()
                        }
                    } else {
                        Logger.shared.log("Failed to find root view controller to present player", type: "Error")
                        self.viewModel.streamError = "Failed to open player. Please try again."
                        self.viewModel.showingStreamError = true
                    }
                }
            }
#endif
        }
    }
    
#if !os(tvOS)
    private func downloadStreamURL(_ url: String, service: Service, subtitle: String?, subtitleHeaders: [String: String]? = nil, headers: [String: String]?, autoModeLaunch: Bool = false) {
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
