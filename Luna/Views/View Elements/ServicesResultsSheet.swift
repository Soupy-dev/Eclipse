//
//  ModulesSearchResultsSheet.swift
//  Sora
//
//  Created by Francesco on 09/08/25.
//

import AVKit
import SwiftUI
import Kingfisher

extension Notification.Name {
    static let requestNextEpisode = Notification.Name("requestNextEpisode")
}

struct StreamOption: Identifiable {
    let id = UUID()
    let name: String
    let url: String
    let headers: [String: String]?
    let subtitle: String?
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
    var pendingHeaders: [String: String]?
    var pendingServiceHref: String?
    
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
        pendingServiceHref = nil
    }
    
    func resetStreamState() {
        isFetchingStreams = false
        showingStreamMenu = false
        pendingSubtitles = nil
        pendingService = nil
        pendingServiceHref = nil
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
    /// When true, selecting a stream downloads instead of playing
    var downloadMode: Bool = false
    /// When true, show only the compact Auto Mode runner instead of the full results picker.
    var autoModeOnly: Bool = false
    /// Called when a download has been enqueued (for Download All flow)
    var onDownloadEnqueued: (() -> Void)? = nil
    /// Called when user taps "Skip" (for Download All flow)
    var onSkipRequested: (() -> Void)? = nil
    
    @Environment(\.presentationMode) var presentationMode
    @StateObject private var viewModel = ModulesSearchResultsViewModel()
    @StateObject private var serviceManager = ServiceManager.shared
    @StateObject private var stremioManager = StremioAddonManager.shared
    @StateObject private var algorithmManager = AlgorithmManager.shared
    @State private var autoModeDidRun = false
    @State private var autoModeRunToken: String?
    @State private var autoModeCancelled = false
    @State private var showManualPicker = false

    private var effectiveTitle: String { seasonTitleOverride ?? mediaTitle }
    private var animeEffectiveTitle: String {
        guard animeSeasonTitle != nil else { return effectiveTitle }
        let stripped = effectiveTitle
            .replacingOccurrences(of: "(?i)season\\s+\\d+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? effectiveTitle : stripped
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
    
    private var searchStatusText: String {
        let anySearching = viewModel.isSearching || viewModel.isSearchingStremio
        if anySearching {
            return "Searching... (\(viewModel.searchedServices.count + viewModel.stremioSearchedAddons.count)/\(viewModel.totalServicesCount + stremioManager.activeAddons.count))"
        }
        return "Search complete"
    }
    
    private var searchStatusColor: Color {
        (viewModel.isSearching || viewModel.isSearchingStremio) ? .secondary : .green
    }
    
    private func lowerQualityResultsText(count: Int) -> String {
        "\(count) lower quality result\(count == 1 ? "" : "s") (<\(Int(viewModel.highQualityThreshold * 100))%)"
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
                    ProgressView()
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
                
                Text("No Active Services")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Text("You don't have any active services or Stremio addons. Please go to the Services tab to download and activate services.")
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

        var id: UUID {
            switch self {
            case .service(let s): return s.id
            case .stremio(let a): return a.id
            }
        }

        var sortIndex: Int64 {
            switch self {
            case .service(let s): return s.sortIndex
            case .stremio(let a): return a.sortIndex
            }
        }
    }

    private var sortedResultItems: [ResultItem] {
        let services: [ResultItem] = serviceManager.activeServices.map { .service($0) }
        let addons: [ResultItem] = stremioManager.activeAddons.map { .stremio($0) }
        return (services + addons).sorted { $0.sortIndex < $1.sortIndex }
    }

    private var activeAutoModeItems: [ResultItem] {
        let configuredIds = selectedAutoModeSourceIds
        let selectedItems = sortedResultItems.filter { configuredIds.contains(autoModeSourceId(for: $0)) }
        let byId = Dictionary(uniqueKeysWithValues: selectedItems.map { (autoModeSourceId(for: $0), $0) })
        let orderedIds = UserDefaults.standard.stringArray(forKey: "servicesAutoModeSourceOrderIds") ?? []
        var ordered = orderedIds.compactMap { byId[$0] }
        let existing = Set(ordered.map { autoModeSourceId(for: $0) })
        ordered.append(contentsOf: selectedItems.filter { !existing.contains(autoModeSourceId(for: $0)) })
        return ordered
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
    
    @ViewBuilder
    private func serviceSection(service: Service) -> some View {
        let results = viewModel.moduleResults[service.id]
        let hasSearched = viewModel.searchedServices.contains(service.id)
        let isCurrentlySearching = viewModel.isSearching && !hasSearched
        
        if let results = results {
            let filteredResults = filterResults(for: results)
            
            Section(header: serviceHeader(for: service, highQualityCount: filteredResults.highQuality.count, lowQualityCount: filteredResults.lowQuality.count, isSearching: false)) {
                if results.isEmpty {
                    noResultsRow
                } else {
                    serviceResultsContent(filteredResults: filteredResults, service: service)
                }
            }
        } else if isCurrentlySearching {
            Section(header: serviceHeader(for: service, highQualityCount: 0, lowQualityCount: 0, isSearching: true)) {
                searchingRow
            }
        } else if !viewModel.isSearching && !hasSearched {
            Section(header: serviceHeader(for: service, highQualityCount: 0, lowQualityCount: 0, isSearching: false)) {
                notSearchedRow
            }
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
            ProgressView()
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
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
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
                if let service = viewModel.pendingService {
                    resolveSubtitleSelection(
                        subtitles: viewModel.pendingSubtitles,
                        defaultSubtitle: option.subtitle,
                        service: service,
                        streamURL: option.url,
                        headers: option.headers,
                        serviceHref: viewModel.pendingServiceHref
                    )
                }
            }
        }
        Button("Cancel", role: .cancel) { }
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
            viewModel.resetPickerState()
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
            viewModel.resetPickerState()
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
                    dispatchStreamAction(streamURL, service: service, subtitle: option.url, headers: viewModel.pendingHeaders, serviceHref: viewModel.pendingServiceHref)
                }
            }
        }
        Button("No Subtitles") {
            viewModel.showingSubtitlePicker = false
            if let service = viewModel.pendingService,
               let streamURL = viewModel.pendingStreamURL {
                dispatchStreamAction(streamURL, service: service, subtitle: nil, headers: viewModel.pendingHeaders, serviceHref: viewModel.pendingServiceHref)
            }
        }
        Button("Cancel", role: .cancel) {
            viewModel.subtitleOptions = []
            viewModel.pendingStreamURL = nil
            viewModel.pendingHeaders = nil
            viewModel.pendingServiceHref = nil
        }
    }
    
    @ViewBuilder
    private var subtitlePickerDialogMessage: some View {
        Text("Choose a subtitle track")
    }
    
    private func filterResults(for results: [SearchItem]) -> (highQuality: [SearchItem], lowQuality: [SearchItem]) {
        let sortedResults = results.enumerated().map { index, result -> (index: Int, result: SearchItem, similarity: Double) in
            let primarySimilarity = algorithmManager.calculateSimilarity(original: mediaTitle, result: result.title)
            let originalSimilarity = originalTitle.map { algorithmManager.calculateSimilarity(original: $0, result: result.title) } ?? 0.0
            return (index: index, result: result, similarity: max(primarySimilarity, originalSimilarity))
        }.sorted {
            if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
            return $0.index < $1.index
        }
        
        let threshold = viewModel.highQualityThreshold
        let highQuality = sortedResults.filter { $0.similarity >= threshold }.map { $0.result }
        let lowQuality = sortedResults.filter { $0.similarity < threshold }.map { $0.result }
        
        return (highQuality, lowQuality)
    }

    private var isAutoModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "servicesAutoModeEnabled")
    }

    private var selectedAutoModeSourceIds: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "servicesAutoModeSourceIds") ?? [])
    }

    private func autoModeSourceId(for item: ResultItem) -> String {
        switch item {
        case .service(let service):
            return "service:\(service.id.uuidString)"
        case .stremio(let addon):
            return "stremio:\(addon.id.uuidString)"
        }
    }

    private func normalizeTitle(_ title: String) -> String {
        title
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resultSimilarity(_ result: SearchItem) -> Double {
        let primarySimilarity = algorithmManager.calculateSimilarity(original: mediaTitle, result: result.title)
        let originalSimilarity = originalTitle.map { algorithmManager.calculateSimilarity(original: $0, result: result.title) } ?? 0.0
        return max(primarySimilarity, originalSimilarity)
    }

    private func resultTieBreakScore(_ result: SearchItem) -> Int {
        let normalizedResult = normalizeTitle(result.title)
        let expectedTitles = [displayTitle, effectiveTitle, mediaTitle, originalTitle]
            .compactMap { $0 }
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

        return score
    }

    private func bestServiceResult(for service: Service) -> SearchItem? {
        guard let results = viewModel.moduleResults[service.id], !results.isEmpty else { return nil }
        let threshold = viewModel.highQualityThreshold

        let ranked = results.enumerated().map { index, result in
            let similarity = resultSimilarity(result)
            return (index: index, result: result, similarity: similarity)
        }
        .filter { $0.similarity >= threshold }
        .sorted { lhs, rhs in
            if lhs.similarity != rhs.similarity { return lhs.similarity > rhs.similarity }
            return lhs.index < rhs.index
        }

        return ranked.first?.result
    }

    private func stremioStreamScore(_ stream: StremioStream) -> Double {
        let shortDescription = stream.description.map { String($0.prefix(120)) }
        let title = [stream.name, stream.title, shortDescription].compactMap { $0 }.joined(separator: " ")
        let baseSimilarity = algorithmManager.calculateSimilarity(original: displayTitle, result: title)
        let lower = title.lowercased()

        let qualityBonus: Double
        if lower.contains("2160") || lower.contains("4k") {
            qualityBonus = 0.08
        } else if lower.contains("1080") {
            qualityBonus = 0.06
        } else if lower.contains("720") {
            qualityBonus = 0.04
        } else {
            qualityBonus = 0.0
        }

        return baseSimilarity + qualityBonus
    }

    private func bestStremioStream(from streams: [StremioStream]) -> StremioStream? {
        guard !streams.isEmpty else { return nil }
        guard let candidate = streams.enumerated().max(by: { lhs, rhs in
            let lhsScore = stremioStreamScore(lhs.element)
            let rhsScore = stremioStreamScore(rhs.element)
            if lhsScore == rhsScore {
                return lhs.offset > rhs.offset
            }
            return lhsScore < rhsScore
        })?.element else {
            return nil
        }

        return stremioStreamScore(candidate) >= viewModel.highQualityThreshold ? candidate : nil
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
            viewModel.streamError = "Auto Mode is enabled, but no active service/addon is selected. Please select at least one source in Services settings."
            viewModel.showingStreamError = true
            return
        }

        for item in orderedSelections {
            switch item {
            case .service(let service):
                if let result = bestServiceResult(for: service) {
                    await playContent(result)
                    return
                }
            case .stremio(let addon):
                if let stream = bestStremioStream(from: viewModel.stremioResults[addon.id] ?? []) {
                    playStremioStream(stream, addon: addon)
                    return
                }
            }
        }

        viewModel.streamError = "Auto Mode could not find a match above your quality threshold in the selected sources. Try lowering the quality threshold or selecting more services/addons."
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

    @ViewBuilder
    private var autoModeProgressView: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
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
                }

                Button(role: .cancel) {
                    autoModeCancelled = true
                    autoModeDidRun = true
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
            showAutoModeFailure("Auto Mode is enabled, but no active service/addon is selected. Please select at least one source in Services settings.")
            return
        }

        for item in orderedItems {
            guard !autoModeCancelled else { return }
            switch item {
            case .service(let service):
                viewModel.currentFetchingTitle = service.metadata.sourceName
                viewModel.streamFetchProgress = "Searching \(service.metadata.sourceName)..."
                if let result = await findAutoModeServiceResult(service) {
                    guard !autoModeCancelled else { return }
                    viewModel.currentFetchingTitle = result.title
                    viewModel.streamFetchProgress = "Found match in \(service.metadata.sourceName). Fetching stream..."
                    await playContent(result)
                    return
                }
            case .stremio(let addon):
                viewModel.currentFetchingTitle = addon.manifest.name
                viewModel.streamFetchProgress = "Checking \(addon.manifest.name)..."
                if let stream = await findAutoModeStremioStream(addon) {
                    guard !autoModeCancelled else { return }
                    viewModel.currentFetchingTitle = stream.displayName
                    viewModel.streamFetchProgress = "Found stream in \(addon.manifest.name)."
                    playStremioStream(stream, addon: addon)
                    return
                }
            }
        }

        showAutoModeFailure("Auto Mode could not find a match above your quality threshold in the selected sources.")
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
            viewModel.moduleResults[service.id] = combined
            viewModel.searchedServices.insert(service.id)

            if let best = bestServiceResult(for: service) {
                return best
            }
        }

        return nil
    }

    @MainActor
    private func findAutoModeStremioStream(_ addon: StremioAddon) async -> StremioStream? {
        let client = StremioClient.shared
        let type = isMovie ? "movie" : "series"
        let season = originalTMDBSeasonNumber ?? (specialTitleOnlySearch ? nil : selectedEpisode?.seasonNumber)
        let episode = originalTMDBEpisodeNumber ?? (specialTitleOnlySearch ? nil : selectedEpisode?.episodeNumber)

        guard let contentId = client.buildContentId(
            tmdbId: tmdbId,
            imdbId: imdbId,
            type: type,
            season: season,
            episode: episode,
            addon: addon
        ) else {
            viewModel.stremioResults[addon.id] = []
            viewModel.stremioSearchedAddons.insert(addon.id)
            return nil
        }

        do {
            let streams = try await client.fetchStreams(baseURL: addon.configuredURL, type: type, id: contentId)
            viewModel.stremioResults[addon.id] = streams
            viewModel.stremioSearchedAddons.insert(addon.id)
            return bestStremioStream(from: streams)
        } catch {
            viewModel.stremioResults[addon.id] = []
            viewModel.stremioSearchedAddons.insert(addon.id)
            Logger.shared.log("Auto Mode Stremio failed for \(addon.manifest.name): \(error.localizedDescription)", type: "Stremio")
            return nil
        }
    }

    @MainActor
    private func showAutoModeFailure(_ message: String) {
        viewModel.isFetchingStreams = false
        viewModel.streamError = message
        viewModel.showingStreamError = true
    }

    @MainActor
    private func switchToManualPicker() {
        autoModeCancelled = true
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
                } else {
                    List {
                        searchInfoSection
                            .background(LunaScrollTracker())

                        if serviceManager.activeServices.isEmpty && stremioManager.activeAddons.isEmpty {
                            noActiveServicesSection
                        } else {
                            unifiedResultsSections
                        }
                    }
                    .lunaSettingsStyle()
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
            autoModeDidRun = false
            if autoModeOnly && !showManualPicker {
                startAutoModeIfNeeded()
            } else {
                startProgressiveSearch()
                startStremioSearch()
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
                    viewModel.streamError = nil
                    presentationMode.wrappedValue.dismiss()
                }
            } else {
                Button("OK", role: .cancel) {
                    viewModel.streamError = nil
                }
            }
        } message: {
            if let error = viewModel.streamError {
                Text(error)
            }
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
        
        // Check if anime via TrackerManager (for logging)
        let isAnime = TrackerManager.shared.cachedAniListId(for: tmdbId) != nil
        
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
        
        let baseTitleQuery = searchQuery.caseInsensitiveCompare(effectiveTitle) == .orderedSame ? nil : effectiveTitle
        let hasAlternativeTitle = originalTitle.map { !$0.isEmpty && $0.lowercased() != effectiveTitle.lowercased() } ?? false
        
        Task {
            await serviceManager.searchInActiveServicesProgressively(
                query: searchQuery,
                onResult: { service, results in
                    Task { @MainActor in
                        self.viewModel.moduleResults[service.id] = results ?? []
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
                                        let existingHrefs = Set(existing.map { $0.href })
                                        let newResults = additional.filter { !existingHrefs.contains($0.href) }
                                        self.viewModel.moduleResults[service.id] = existing + newResults
                                        
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
                                                        let existingHrefs = Set(existing.map { $0.href })
                                                        let newResults = additional.filter { !existingHrefs.contains($0.href) }
                                                        self.viewModel.moduleResults[service.id] = existing + newResults
                                                        
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
                                        let existingHrefs = Set(existing.map { $0.href })
                                        let newResults = additional.filter { !existingHrefs.contains($0.href) }
                                        self.viewModel.moduleResults[service.id] = existing + newResults
                                        
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

        viewModel.isSearchingStremio = true

        let type = isMovie ? "movie" : "series"
        // For anime, AniList restructuring remaps season/episode numbers.
        // Stremio addons index by the original TMDB numbering, so prefer those.
        let season = originalTMDBSeasonNumber ?? (specialTitleOnlySearch ? nil : selectedEpisode?.seasonNumber)
        let episode = originalTMDBEpisodeNumber ?? (specialTitleOnlySearch ? nil : selectedEpisode?.episodeNumber)

        Task {
            await stremioManager.fetchStreamsFromAddons(
                tmdbId: tmdbId,
                imdbId: imdbId,
                type: type,
                season: season,
                episode: episode,
                onResult: { addon, streams in
                    Task { @MainActor in
                        self.viewModel.stremioResults[addon.id] = streams
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
                if streams.isEmpty {
                    noResultsRow
                } else {
                    stremioMediaRow(streams: streams, addon: addon)
                }
            }
        } else if isCurrentlySearching {
            Section(header: stremioAddonHeader(for: addon, streamCount: 0, isSearching: true)) {
                searchingRow
            }
        } else if !viewModel.isSearchingStremio && !hasSearched {
            Section(header: stremioAddonHeader(for: addon, streamCount: 0, isSearching: false)) {
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

            Spacer()

            if isSearching {
                ProgressView()
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
                KFImage(posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w500\($0)") })
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
            ForEach(streams) { stream in
                Button {
                    viewModel.showingStremioStreamPicker = false
                    if let addon = viewModel.selectedStremioAddon {
                        playStremioStream(stream, addon: addon)
                    }
                } label: {
                    Text(stremioStreamLabel(for: stream))
                }
            }
        }
        Button("Cancel", role: .cancel) {
            viewModel.stremioStreamOptions = nil
            viewModel.selectedStremioAddon = nil
        }
    }

    @ViewBuilder
    private var stremioStreamPickerMessage: some View {
        Text("Choose a stream to \(actionVerb.lowercased())")
    }

    private func stremioStreamLabel(for stream: StremioStream) -> String {
        var parts: [String] = []
        if let name = stream.name, !name.isEmpty { parts.append(name) }

        // Parse quality info from title lines (Torrentio/Comet format)
        if let title = stream.title, !title.isEmpty {
            let lines = title.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let qualityTags = extractQualityTags(from: lines)
            if !qualityTags.isEmpty {
                parts.append(qualityTags)
            } else if let firstLine = lines.first, firstLine != stream.name {
                parts.append(firstLine)
            }
        }

        return parts.isEmpty ? "Stream" : parts.joined(separator: " · ")
    }

    private func extractQualityTags(from lines: [String]) -> String {
        let resolutionPatterns = ["4k", "2160p", "1080p", "720p", "480p", "360p"]
        let qualityPatterns = ["bluray", "blu-ray", "bdrip", "brrip", "dvdrip", "dvd", "webrip", "web-dl", "webdl", "web", "hdtv", "hdrip", "cam", "ts", "hdcam", "remux"]
        let codecPatterns = ["hevc", "h265", "h.265", "x265", "h264", "h.264", "x264", "av1", "vp9", "xvid"]
        let hdrPatterns = ["hdr10+", "hdr10", "hdr", "dolby vision", "dv", "sdr"]
        let audioPatterns = ["atmos", "truehd", "dts-hd", "dts", "dd5.1", "dd+", "aac", "5.1", "7.1"]

        var tags: [String] = []
        let allText = lines.joined(separator: " ").lowercased()

        // Resolution
        for pattern in resolutionPatterns {
            if allText.contains(pattern) {
                tags.append(pattern == "4k" ? "4K" : pattern.uppercased())
                break
            }
        }

        // Source quality
        for pattern in qualityPatterns {
            if allText.contains(pattern) {
                let display: String
                switch pattern {
                case "bluray", "blu-ray": display = "BluRay"
                case "bdrip": display = "BDRip"
                case "brrip": display = "BRRip"
                case "dvdrip": display = "DVDRip"
                case "dvd": display = "DVD"
                case "webrip": display = "WEBRip"
                case "web-dl", "webdl": display = "WEB-DL"
                case "web": display = "WEB"
                case "hdtv": display = "HDTV"
                case "hdrip": display = "HDRip"
                case "cam": display = "CAM"
                case "ts": display = "TS"
                case "hdcam": display = "HDCAM"
                case "remux": display = "Remux"
                default: display = pattern.uppercased()
                }
                tags.append(display)
                break
            }
        }

        // Codec
        for pattern in codecPatterns {
            if allText.contains(pattern) {
                let display: String
                switch pattern {
                case "hevc", "h265", "h.265", "x265": display = "HEVC"
                case "h264", "h.264", "x264": display = "H.264"
                case "av1": display = "AV1"
                default: display = pattern.uppercased()
                }
                tags.append(display)
                break
            }
        }

        // HDR
        for pattern in hdrPatterns {
            if allText.contains(pattern) {
                let display: String
                switch pattern {
                case "hdr10+": display = "HDR10+"
                case "hdr10": display = "HDR10"
                case "hdr": display = "HDR"
                case "dolby vision", "dv": display = "DV"
                default: display = pattern.uppercased()
                }
                tags.append(display)
                break
            }
        }

        // Audio
        for pattern in audioPatterns {
            if allText.contains(pattern) {
                let display: String
                switch pattern {
                case "atmos": display = "Atmos"
                case "truehd": display = "TrueHD"
                case "dts-hd": display = "DTS-HD"
                case "dts": display = "DTS"
                case "dd5.1": display = "DD5.1"
                case "dd+": display = "DD+"
                default: display = pattern
                }
                tags.append(display)
                break
            }
        }

        // File size (look for patterns like "2.5 GB", "800 MB")
        let sizeRegex = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?\s*(?:GB|MB|gb|mb))"#)
        if let match = sizeRegex?.firstMatch(in: lines.joined(separator: " "), range: NSRange(location: 0, length: lines.joined(separator: " ").utf16.count)) {
            if let range = Range(match.range(at: 1), in: lines.joined(separator: " ")) {
                tags.append(String(lines.joined(separator: " ")[range]))
            }
        }

        return tags.joined(separator: " · ")
    }

    // MARK: - Play / Download Stremio Stream

    private func playStremioStream(_ stream: StremioStream, addon: StremioAddon) {
        // SAFETY: Double-check this is a direct HTTP(S) stream - NO torrents allowed
        guard let urlString = stream.url, stream.isDirectHTTP else {
            Logger.shared.log("Stremio: SAFETY BLOCK - Rejected non-HTTP stream", type: "Error")
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
            downloadStremioStream(urlString, addon: addon, subtitle: subtitleURLs.first, headers: stream.proxyHeaders)
        } else {
            playStremioStreamURL(urlString, addon: addon, subtitles: subtitleURLs, subtitleNames: subtitleNames, headers: stream.proxyHeaders)
        }
    }

    private func playStremioStreamURL(_ url: String, addon: StremioAddon, subtitles: [String], subtitleNames: [String], headers: [String: String]?) {
        viewModel.resetStreamState()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)

            guard let streamURL = URL(string: url) else {
                Logger.shared.log("Invalid Stremio stream URL: \(url)", type: "Error")
                viewModel.streamError = "Invalid stream URL from Stremio addon."
                viewModel.showingStreamError = true
                return
            }

            // SAFETY: Verify HTTP(S) scheme - NO torrents, magnet links, or other schemes ever
            guard streamURL.scheme == "http" || streamURL.scheme == "https" else {
                Logger.shared.log("Stremio: SAFETY BLOCK - Non-HTTP scheme: \(streamURL.scheme ?? "nil")", type: "Error")
                return
            }

            let externalRaw = UserDefaults.standard.string(forKey: "externalPlayer") ?? ExternalPlayer.none.rawValue
            let external = ExternalPlayer(rawValue: externalRaw) ?? .none
            let schemeUrl = external.schemeURL(for: url)

            if let scheme = schemeUrl, UIApplication.shared.canOpenURL(scheme) {
                UIApplication.shared.open(scheme, options: [:], completionHandler: nil)
                Logger.shared.log("Stremio: Opening external player with scheme: \(scheme)", type: "General")
                return
            }

            var finalHeaders: [String: String] = [
                "User-Agent": URLSession.randomUserAgent
            ]

            if let custom = headers {
                for (k, v) in custom {
                    finalHeaders[k] = v
                }
            }

            Logger.shared.log("Stremio: Final headers: \(finalHeaders)", type: "Stream")

            let inAppRaw = UserDefaults.standard.string(forKey: "inAppPlayer") ?? "VLC"
            let inAppPlayer = inAppRaw

            var playerMediaInfo: MediaInfo? = nil
            let posterURL = posterPath.flatMap { "https://image.tmdb.org/t/p/w500\($0)" }
            if isMovie {
                playerMediaInfo = .movie(id: tmdbId, title: mediaTitle, posterURL: posterURL, isAnime: isAnimeContent)
            } else if let episode = selectedEpisode {
                playerMediaInfo = .episode(showId: tmdbId, seasonNumber: episode.seasonNumber, episodeNumber: episode.episodeNumber, showTitle: mediaTitle, showPosterURL: posterURL, isAnime: isAnimeContent)
            }

            if inAppPlayer == "mpv" || inAppPlayer == "VLC" {
                let preset = PlayerPreset.presets.first
                let subtitleArray: [String]? = subtitles.isEmpty ? nil : subtitles

                let pvc = PlayerViewController(
                    url: streamURL,
                    preset: preset ?? PlayerPreset(id: .sdrRec709, title: "Default", summary: "", stream: nil, commands: []),
                    headers: finalHeaders,
                    subtitles: subtitleArray,
                    subtitleNames: subtitleNames.isEmpty ? nil : subtitleNames,
                    mediaInfo: playerMediaInfo
                )
                let isAnimeHint = isAnimeContent || animeSeasonTitle != nil || TrackerManager.shared.cachedAniListId(for: tmdbId) != nil
                pvc.isAnimeHint = isAnimeHint
                pvc.originalTMDBSeasonNumber = originalTMDBSeasonNumber
                pvc.originalTMDBEpisodeNumber = originalTMDBEpisodeNumber
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

                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = windowScene.windows.first?.rootViewController,
                   let topmostVC = rootVC.topmostViewController() as UIViewController? {
                    topmostVC.present(pvc, animated: true, completion: nil)
                } else {
                    Logger.shared.log("Failed to find root view controller to present player", type: "Error")
                }
                return
            }

            // Default AVPlayer path
            let asset = AVURLAsset(url: streamURL, options: ["AVURLAssetHTTPHeaderFieldsKey": finalHeaders])
            let playerVC = NormalPlayer()
            let item = AVPlayerItem(asset: asset)
            playerVC.player = AVPlayer(playerItem: item)
            if isMovie {
                playerVC.mediaInfo = .movie(id: tmdbId, title: mediaTitle, posterURL: posterURL, isAnime: isAnimeContent)
            } else if let episode = selectedEpisode {
                playerVC.mediaInfo = .episode(showId: tmdbId, seasonNumber: episode.seasonNumber, episodeNumber: episode.episodeNumber, showTitle: mediaTitle, showPosterURL: posterURL, isAnime: isAnimeContent)
            }
            playerVC.modalPresentationStyle = .fullScreen

            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController,
               let topmostVC = rootVC.topmostViewController() as UIViewController? {
                topmostVC.present(playerVC, animated: true) {
                    playerVC.player?.play()
                }
            }
        }
    }

    private func downloadStremioStream(_ url: String, addon: StremioAddon, subtitle: String?, headers: [String: String]?) {
        // SAFETY: Verify HTTP(S) URL - NO torrents, magnet links, or other schemes ever
        guard let parsed = URL(string: url),
              parsed.scheme == "http" || parsed.scheme == "https" else {
            Logger.shared.log("Stremio: SAFETY BLOCK - Non-HTTP download URL rejected", type: "Error")
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

        let posterURL = posterPath.flatMap { "https://image.tmdb.org/t/p/w500\($0)" }

        let displayTitle: String
        if isMovie {
            displayTitle = mediaTitle
        } else if let ep = selectedEpisode {
            if specialTitleOnlySearch {
                displayTitle = animeSeasonTitle != nil ? animeEffectiveTitle : effectiveTitle
            } else if isAnimeContent || animeSeasonTitle != nil {
                displayTitle = "\(animeEffectiveTitle) E\(ep.episodeNumber)"
            } else {
                displayTitle = "\(effectiveTitle) S\(ep.seasonNumber)E\(ep.episodeNumber)"
            }
        } else {
            displayTitle = mediaTitle
        }

        DownloadManager.shared.enqueueDownload(
            tmdbId: tmdbId,
            isMovie: isMovie,
            title: mediaTitle,
            displayTitle: displayTitle,
            posterURL: posterURL,
            seasonNumber: selectedEpisode?.seasonNumber,
            episodeNumber: selectedEpisode?.episodeNumber,
            episodeName: selectedEpisode?.name,
            streamURL: url,
            headers: finalHeaders,
            subtitleURL: subtitle,
            serviceBaseURL: addon.configuredURL,
            isAnime: isAnimeContent
        )

        Logger.shared.log("Stremio: Download enqueued: \(displayTitle)", type: "Download")

        onDownloadEnqueued?()
        presentationMode.wrappedValue.dismiss()
    }
    
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
            
            Spacer()
            
            HStack(spacing: 4) {
                if isSearching {
                    ProgressView()
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
    
    private func fetchStreamForEpisode(_ episodeHref: String, jsController: JSController, service: Service) {
        let softsub = service.metadata.softsub ?? false
        jsController.fetchStreamUrlJS(episodeUrl: episodeHref, softsub: softsub, module: service) { streamResult in
            Task { @MainActor in
                let (streams, subtitles, sources) = streamResult
                
                Logger.shared.log("Stream fetch result - Streams: \(streams?.count ?? 0), Sources: \(sources?.count ?? 0)", type: "Stream")
                self.viewModel.streamFetchProgress = "Processing stream data..."
                
                self.viewModel.pendingServiceHref = episodeHref
                self.processStreamResult(streams: streams, subtitles: subtitles, sources: sources, service: service)
                self.viewModel.resetPickerState()
            }
        }
    }
    
    @MainActor
    private func playContent(_ result: SearchItem) async {
        Logger.shared.log("Starting playback for: \(result.title)", type: "Stream")
        
        viewModel.isFetchingStreams = true
        viewModel.currentFetchingTitle = result.title
        viewModel.streamFetchProgress = "Initializing..."
        
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
        jsController.loadScript(service.jsScript)
        Logger.shared.log("JavaScript loaded successfully", type: "Stream")
        
        viewModel.streamFetchProgress = "Fetching episodes..."
        
        jsController.fetchEpisodesJS(url: result.href) { episodes in
            Task { @MainActor in
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
            viewModel.isFetchingStreams = false
            viewModel.streamError = "No episodes found for '\(result.title)'. The source may be unavailable."
            viewModel.showingStreamError = true
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
            viewModel.isFetchingStreams = false
            viewModel.streamError = "No episode selected. Please select an episode first."
            viewModel.showingStreamError = true
            return
        }
        
        viewModel.streamFetchProgress = "Finding episode S\(selectedEp.seasonNumber)E\(selectedEp.episodeNumber)..."
        let seasons = parseSeasons(from: episodes)
        let targetSeasonIndex = selectedEp.seasonNumber - 1
        let targetEpisodeNumber = selectedEp.episodeNumber
        
        if let targetHref = findEpisodeHref(seasons: seasons, seasonIndex: targetSeasonIndex, episodeNumber: targetEpisodeNumber) {
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
    
    private func findEpisodeHref(seasons: [[EpisodeLink]], seasonIndex: Int, episodeNumber: Int) -> String? {
        if seasonIndex >= 0 && seasonIndex < seasons.count {
            if let episode = seasons[seasonIndex].first(where: { $0.number == episodeNumber }) {
                Logger.shared.log("Found exact match: S\(seasonIndex + 1)E\(episodeNumber)", type: "Stream")
                return episode.href
            }
        }
        
        for season in seasons {
            if let episode = season.first(where: { $0.number == episodeNumber }) {
                Logger.shared.log("Found episode \(episodeNumber) in different season, auto-playing", type: "Stream")
                return episode.href
            }
        }
        
        return nil
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
            viewModel.streamError = "No episodes found in any season. The source may have incomplete data."
            viewModel.showingStreamError = true
        }
    }
    
    private func fetchFinalStream(href: String, jsController: JSController, service: Service) {
        let softsub = service.metadata.softsub ?? false
        jsController.fetchStreamUrlJS(episodeUrl: href, softsub: softsub, module: service) { streamResult in
            Task { @MainActor in
                let (streams, subtitles, sources) = streamResult
                self.processStreamResult(streams: streams, subtitles: subtitles, sources: sources, service: service)
            }
        }
    }
    
    @MainActor
    private func processStreamResult(streams: [String]?, subtitles: [String]?, sources: [[String: Any]]?, service: Service) {
        Logger.shared.log("Stream fetch result - Streams: \(streams?.count ?? 0), Sources: \(sources?.count ?? 0)", type: "Stream")
        viewModel.streamFetchProgress = "Processing stream data..."
        
        let availableStreams = parseStreamOptions(streams: streams, sources: sources)
        
        if availableStreams.count > 1 {
            Logger.shared.log("Found \(availableStreams.count) stream options, showing selection", type: "Stream")
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
                serviceHref: viewModel.pendingServiceHref
            )
        } else if let streamURL = extractSingleStreamURL(streams: streams, sources: sources) {
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
            viewModel.isFetchingStreams = false
            viewModel.streamError = "Failed to get a valid stream URL. The source may be temporarily unavailable."
            viewModel.showingStreamError = true
        }
    }
    
    private func parseStreamOptions(streams: [String]?, sources: [[String: Any]]?) -> [StreamOption] {
        var availableStreams: [StreamOption] = []
        
        if let sources = sources, !sources.isEmpty {
            for (idx, source) in sources.enumerated() {
                guard let rawUrl = source["streamUrl"] as? String ?? source["url"] as? String, !rawUrl.isEmpty else { continue }
                let title = (source["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let headers = safeConvertToHeaders(source["headers"])
                let subtitle = source["subtitle"] as? String
                let option = StreamOption(
                    name: title?.isEmpty == false ? title! : "Stream \(idx + 1)",
                    url: rawUrl,
                    headers: headers,
                    subtitle: subtitle
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
                options.append(StreamOption(name: "Stream \(unnamedCount)", url: entry, headers: nil, subtitle: nil))
                unnamedCount += 1
                index += 1
            } else {
                let nextIndex = index + 1
                if nextIndex < streams.count, isURL(streams[nextIndex]) {
                    options.append(StreamOption(name: entry, url: streams[nextIndex], headers: nil, subtitle: nil))
                    index += 2
                } else {
                    index += 1
                }
            }
        }
        
        return options
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
    
    @MainActor
    private func resolveSubtitleSelection(subtitles: [String]?, defaultSubtitle: String?, service: Service, streamURL: String, headers: [String: String]?, serviceHref: String? = nil) {
        guard let subtitles = subtitles, !subtitles.isEmpty else {
            dispatchStreamAction(streamURL, service: service, subtitle: defaultSubtitle, headers: headers, serviceHref: serviceHref)
            return
        }
        
        let options = parseSubtitleOptions(from: subtitles)
        guard !options.isEmpty else {
            dispatchStreamAction(streamURL, service: service, subtitle: defaultSubtitle, headers: headers, serviceHref: serviceHref)
            return
        }
        
        if options.count == 1 {
            dispatchStreamAction(streamURL, service: service, subtitle: options[0].url, headers: headers, serviceHref: serviceHref)
            return
        }
        
        viewModel.subtitleOptions = options
        viewModel.pendingStreamURL = streamURL
        viewModel.pendingHeaders = headers
        viewModel.pendingService = service
        viewModel.pendingServiceHref = serviceHref
        viewModel.isFetchingStreams = false
        viewModel.showingSubtitlePicker = true
    }
    
    /// Routes to either play or download based on downloadMode
    private func dispatchStreamAction(_ url: String, service: Service, subtitle: String?, headers: [String: String]?, serviceHref: String? = nil) {
        if downloadMode {
            downloadStreamURL(url, service: service, subtitle: subtitle, headers: headers)
        } else {
            playStreamURL(url, service: service, subtitle: subtitle, headers: headers, serviceHref: serviceHref)
        }
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
    
    private func playStreamURL(_ url: String, service: Service, subtitle: String?, headers: [String: String]?, serviceHref: String? = nil) {
        viewModel.resetStreamState()
        
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            
            guard let streamURL = URL(string: url) else {
                Logger.shared.log("Invalid stream URL: \(url)", type: "Error")
                viewModel.streamError = "Invalid stream URL. The source returned a malformed URL."
                viewModel.showingStreamError = true
                return
            }
            
            let externalRaw = UserDefaults.standard.string(forKey: "externalPlayer") ?? ExternalPlayer.none.rawValue
            let external = ExternalPlayer(rawValue: externalRaw) ?? .none
            let schemeUrl = external.schemeURL(for: url)
            
            if let scheme = schemeUrl, UIApplication.shared.canOpenURL(scheme) {
                UIApplication.shared.open(scheme, options: [:], completionHandler: nil)
                Logger.shared.log("Opening external player with scheme: \(scheme)", type: "General")
                return
            }
            
            let serviceURL = service.metadata.baseUrl
            var finalHeaders: [String: String] = [
                "Origin": serviceURL,
                "Referer": serviceURL,
                "User-Agent": URLSession.randomUserAgent
            ]
            
            if let custom = headers {
                Logger.shared.log("Using custom headers: \(custom)", type: "Stream")
                for (k, v) in custom {
                    finalHeaders[k] = v
                }
                
                if finalHeaders["User-Agent"] == nil {
                    finalHeaders["User-Agent"] = URLSession.randomUserAgent
                }
            }
            
            Logger.shared.log("Final headers: \(finalHeaders)", type: "Stream")
            
            let inAppRaw = UserDefaults.standard.string(forKey: "inAppPlayer") ?? "VLC"
            let inAppPlayer = inAppRaw
            
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
            
            if inAppPlayer == "mpv" {
                let preset = PlayerPreset.presets.first
                let subtitleArray: [String]? = subtitle.map { [$0] }
                
                // Prepare mediaInfo before creating player
                var playerMediaInfo: MediaInfo? = nil
                let posterURL = posterPath.flatMap { "https://image.tmdb.org/t/p/w500\($0)" }
                if isMovie {
                    playerMediaInfo = .movie(id: tmdbId, title: mediaTitle, posterURL: posterURL, isAnime: isAnimeContent)
                } else if let episode = selectedEpisode {
                    playerMediaInfo = .episode(showId: tmdbId, seasonNumber: episode.seasonNumber, episodeNumber: episode.episodeNumber, showTitle: mediaTitle, showPosterURL: posterURL, isAnime: isAnimeContent)
                }
                
                let pvc = PlayerViewController(
                    url: streamURL,
                    preset: preset ?? PlayerPreset(id: .sdrRec709, title: "Default", summary: "", stream: nil, commands: []),
                    headers: finalHeaders,
                    subtitles: subtitleArray,
                    mediaInfo: playerMediaInfo
                )
                let isAnimeHint = isAnimeContent || animeSeasonTitle != nil || TrackerManager.shared.cachedAniListId(for: tmdbId) != nil
                pvc.isAnimeHint = isAnimeHint
                pvc.originalTMDBSeasonNumber = originalTMDBSeasonNumber
                pvc.originalTMDBEpisodeNumber = originalTMDBEpisodeNumber
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
                        return "episode showId=\(showId) s=\(seasonNumber) e=\(episodeNumber) title=\(showTitle) isAnime=\(isAnime)"
                    }
                }()
                Logger.shared.log("ServicesResultsSheet: presenting MPV isAnimeHint=\(isAnimeHint) isAnimeContent=\(isAnimeContent) mediaInfo=\(mediaInfoLabel)", type: "Stream")
                pvc.modalPresentationStyle = .fullScreen
                
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = windowScene.windows.first?.rootViewController,
                   let topmostVC = rootVC.topmostViewController() as UIViewController? {
                    topmostVC.present(pvc, animated: true, completion: nil)
                } else {
                    Logger.shared.log("Failed to find root view controller to present MPV player", type: "Error")
                }
                return
            } else if inAppPlayer == "VLC" {
                // VLC uses same PlayerViewController as MPV
                let preset = PlayerPreset.presets.first
                let subtitleArray: [String]? = subtitle.map { [$0] }
                
                // Prepare mediaInfo before creating player
                var playerMediaInfo: MediaInfo? = nil
                let posterURL = posterPath.flatMap { "https://image.tmdb.org/t/p/w500\($0)" }
                if isMovie {
                    playerMediaInfo = .movie(id: tmdbId, title: mediaTitle, posterURL: posterURL, isAnime: isAnimeContent)
                } else if let episode = selectedEpisode {
                    playerMediaInfo = .episode(showId: tmdbId, seasonNumber: episode.seasonNumber, episodeNumber: episode.episodeNumber, showTitle: mediaTitle, showPosterURL: posterURL, isAnime: isAnimeContent)
                }
                
                let pvc = PlayerViewController(
                    url: streamURL,
                    preset: preset ?? PlayerPreset(id: .sdrRec709, title: "Default", summary: "", stream: nil, commands: []),
                    headers: finalHeaders,
                    subtitles: subtitleArray,
                    mediaInfo: playerMediaInfo
                )
                let isAnimeHint = isAnimeContent || animeSeasonTitle != nil || TrackerManager.shared.cachedAniListId(for: tmdbId) != nil
                pvc.isAnimeHint = isAnimeHint
                pvc.originalTMDBSeasonNumber = originalTMDBSeasonNumber
                pvc.originalTMDBEpisodeNumber = originalTMDBEpisodeNumber
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
                        return "episode showId=\(showId) s=\(seasonNumber) e=\(episodeNumber) title=\(showTitle) isAnime=\(isAnime)"
                    }
                }()
                Logger.shared.log("ServicesResultsSheet: presenting VLC isAnimeHint=\(isAnimeHint) isAnimeContent=\(isAnimeContent) mediaInfo=\(mediaInfoLabel)", type: "Stream")
                pvc.modalPresentationStyle = .fullScreen
                
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = windowScene.windows.first?.rootViewController,
                   let topmostVC = rootVC.topmostViewController() as UIViewController? {
                    topmostVC.present(pvc, animated: true, completion: nil)
                } else {
                    Logger.shared.log("Failed to find root view controller to present VLC player", type: "Error")
                }
                return
            } else {
                let playerVC = NormalPlayer()
                let asset = AVURLAsset(url: streamURL, options: ["AVURLAssetHTTPHeaderFieldsKey": finalHeaders])
                let item = AVPlayerItem(asset: asset)
                playerVC.player = AVPlayer(playerItem: item)
                if isMovie {
                    let posterURL = posterPath.flatMap { "https://image.tmdb.org/t/p/w500\($0)" }
                    playerVC.mediaInfo = .movie(id: tmdbId, title: mediaTitle, posterURL: posterURL, isAnime: isAnimeContent)
                } else if let episode = selectedEpisode {
                    let posterURL = posterPath.flatMap { "https://image.tmdb.org/t/p/w500\($0)" }
                    playerVC.mediaInfo = .episode(showId: tmdbId, seasonNumber: episode.seasonNumber, episodeNumber: episode.episodeNumber, showTitle: mediaTitle, showPosterURL: posterURL, isAnime: isAnimeContent)
                }
                playerVC.modalPresentationStyle = .fullScreen
                
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = windowScene.windows.first?.rootViewController,
                   let topmostVC = rootVC.topmostViewController() as UIViewController? {
                    topmostVC.present(playerVC, animated: true) {
                        playerVC.player?.play()
                    }
                } else {
                    Logger.shared.log("Failed to find root view controller to present player", type: "Error")
                    viewModel.streamError = "Failed to open player. Please try again."
                    viewModel.showingStreamError = true
                }
            }
        }
    }
    
    private func downloadStreamURL(_ url: String, service: Service, subtitle: String?, headers: [String: String]?) {
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
        
        let posterURL = posterPath.flatMap { "https://image.tmdb.org/t/p/w500\($0)" }
        
        let displayTitle: String
        if isMovie {
            displayTitle = mediaTitle
        } else if let ep = selectedEpisode {
            if specialTitleOnlySearch {
                displayTitle = animeSeasonTitle != nil ? animeEffectiveTitle : effectiveTitle
            } else if isAnimeContent || animeSeasonTitle != nil {
                displayTitle = "\(animeEffectiveTitle) E\(ep.episodeNumber)"
            } else {
                displayTitle = "\(effectiveTitle) S\(ep.seasonNumber)E\(ep.episodeNumber)"
            }
        } else {
            displayTitle = mediaTitle
        }
        
        DownloadManager.shared.enqueueDownload(
            tmdbId: tmdbId,
            isMovie: isMovie,
            title: mediaTitle,
            displayTitle: displayTitle,
            posterURL: posterURL,
            seasonNumber: selectedEpisode?.seasonNumber,
            episodeNumber: selectedEpisode?.episodeNumber,
            episodeName: selectedEpisode?.name,
            streamURL: url,
            headers: finalHeaders,
            subtitleURL: subtitle,
            serviceBaseURL: serviceURL,
            isAnime: isAnimeContent
        )
        
        Logger.shared.log("Download enqueued: \(displayTitle)", type: "Download")
        
        // Notify parent that download was enqueued (for Download All flow)
        onDownloadEnqueued?()
        
        // Dismiss the sheet after enqueuing
        presentationMode.wrappedValue.dismiss()
    }
    
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
