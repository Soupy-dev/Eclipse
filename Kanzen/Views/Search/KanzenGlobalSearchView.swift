//
//  KanzenGlobalSearchView.swift
//  Kanzen
//
//  Created by Eclipse on 2025.
//

import SwiftUI
import Kingfisher

#if !os(tvOS)
private enum MangaSearchRecentStore {
    private static let key = "kanzenRecentSourceSearches"
    static let limit = 10

    static func load() -> [String] {
        ProfileSettingsStore.active.stringArray(forKey: key) ?? []
    }

    @discardableResult
    static func add(_ query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return load() }

        var searches = load().filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        searches.insert(trimmed, at: 0)
        searches = Array(searches.prefix(limit))
        ProfileSettingsStore.active.set(searches, forKey: key)
        return searches
    }

    static func clear() {
        ProfileSettingsStore.active.removeObject(forKey: key)
    }
}

private struct MangaModuleSearchSection: Identifiable, Equatable {
    let id: String
    let source: MangaHomeSource
    let items: [MangaHomeItem]
}

private struct MangaSourceSearchOutcome {
    let source: MangaHomeSource
    let items: [MangaHomeItem]
    let error: Error?
    let elapsedMs: Int
    let wasCancelled: Bool
    let timedOut: Bool

    static func success(source: MangaHomeSource, items: [MangaHomeItem], elapsedMs: Int) -> MangaSourceSearchOutcome {
        MangaSourceSearchOutcome(source: source, items: items, error: nil, elapsedMs: elapsedMs, wasCancelled: false, timedOut: false)
    }

    static func failure(source: MangaHomeSource, error: Error, elapsedMs: Int) -> MangaSourceSearchOutcome {
        MangaSourceSearchOutcome(source: source, items: [], error: error, elapsedMs: elapsedMs, wasCancelled: false, timedOut: false)
    }

    static func cancelled(source: MangaHomeSource, elapsedMs: Int) -> MangaSourceSearchOutcome {
        MangaSourceSearchOutcome(source: source, items: [], error: nil, elapsedMs: elapsedMs, wasCancelled: true, timedOut: false)
    }

    static func timedOut(source: MangaHomeSource, elapsedMs: Int) -> MangaSourceSearchOutcome {
        MangaSourceSearchOutcome(source: source, items: [], error: nil, elapsedMs: elapsedMs, wasCancelled: false, timedOut: true)
    }
}

@MainActor
private final class MangaGlobalModuleSearchViewModel: ObservableObject {
    @Published var sources: [MangaHomeSource] = []
    @Published var sections: [MangaModuleSearchSection] = []
    @Published var failedSourceNames: [String] = []
    @Published var isSearching = false
    @Published var hasSearched = false

    private static let maxConcurrentSourceSearches = 3
    private static let sourceTimeoutNanoseconds: UInt64 = 30_000_000_000
    private static let overallSearchTimeoutNanoseconds: UInt64 = 60_000_000_000
    private var searchToken = UUID()
    private var pendingSearchCount = 0
    private var searchStartedAt = Date.distantPast
    private var didLogFirstSourceResult = false
    private var queuedSources: [MangaHomeSource] = []
    private var nextSourceIndex = 0
    private var activeSourceIDs = Set<String>()
    private var sourceSearchTasks: [String: Task<Void, Never>] = [:]
    private var sourceTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var searchDeadlineTask: Task<Void, Never>?
    private var currentQuery: String?

    func refreshSources(from modules: [ModuleDataContainer], readerExtensionManager: ReaderExtensionManager) {
        MangaHomeSourceManager.shared.refreshSources(from: modules)
        let refreshedSources = MangaHomeSourceManager.shared.enabledSources(
            readerExtensionManager: readerExtensionManager,
            modules: modules
        )
        guard refreshedSources != sources else { return }
        sources = refreshedSources
        ReaderLogger.shared.log("Global search sources refreshed extensions=\(sources.filter(\.isReaderExtension).count) total=\(sources.count)", type: "ReaderSearch")
    }

    func isShowingResults(for query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && currentQuery == trimmed && hasSearched
    }

    func resetSearch() {
        cancelCurrentSearch(reason: "reset", clearResults: true)
    }

    func restrictForKidsProfile() {
        cancelCurrentSearch(reason: "kids-profile", clearResults: true)
        sources = []
    }

    func cancelSearch(keepResults: Bool = true) {
        cancelCurrentSearch(reason: "view-disappear", clearResults: !keepResults)
    }

    private func cancelCurrentSearch(reason: String, clearResults: Bool) {
        let wasSearching = isSearching
        searchToken = UUID()
        cancelOutstandingSearchTasks()
        pendingSearchCount = 0
        if clearResults {
            sections = []
            failedSourceNames = []
            hasSearched = false
            currentQuery = nil
        }
        isSearching = false
        if wasSearching {
            ReaderLogger.shared.log("Global search cancelled reason=\(reason)", type: "ReaderSearch")
        }
    }

    func searchAll(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            resetSearch()
            return
        }

        let activeSources = sources.filter(\.isReaderExtension)
        currentQuery = trimmed
        guard !activeSources.isEmpty else {
            sections = []
            failedSourceNames = []
            isSearching = false
            hasSearched = true
            ReaderLogger.shared.log("Global search skipped no Reader Extensions queryLength=\(trimmed.count)", type: "ReaderSearch")
            return
        }

        let token = UUID()
        cancelOutstandingSearchTasks()
        searchToken = token
        isSearching = true
        hasSearched = true
        sections = []
        failedSourceNames = []
        pendingSearchCount = activeSources.count
        searchStartedAt = Date()
        didLogFirstSourceResult = false
        ReaderLogger.shared.log(
            "Global search started queryLength=\(trimmed.count) sources=\(activeSources.count)",
            type: "ReaderSearch"
        )
        ReaderLogger.shared.log(
            "Global search concurrency limit=\(Self.maxConcurrentSourceSearches)",
            type: "ReaderSearch"
        )

        queuedSources = activeSources
        nextSourceIndex = 0
        searchDeadlineTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.overallSearchTimeoutNanoseconds)
            } catch {
                return
            }
            self?.searchDeadlineReached(token: token)
        }
        startQueuedSearches(query: trimmed, token: token)
    }

    private func startQueuedSearches(query: String, token: UUID) {
        guard searchToken == token, isSearching else { return }

        while activeSourceIDs.count < Self.maxConcurrentSourceSearches,
              nextSourceIndex < queuedSources.count {
            let source = queuedSources[nextSourceIndex]
            nextSourceIndex += 1
            activeSourceIDs.insert(source.id)

            let sourceStartedAt = Date()
            ReaderLogger.shared.log("Global search source started source=\(source.id)", type: "ReaderSearch")
            sourceSearchTasks[source.id] = Task { @MainActor [weak self] in
                let outcome = await Self.makeSearchOutcome(
                    source: source,
                    query: query,
                    startedAt: sourceStartedAt
                )
                self?.sourceSearchFinished(outcome, query: query, token: token)
            }
            sourceTimeoutTasks[source.id] = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: Self.sourceTimeoutNanoseconds)
                } catch {
                    return
                }
                self?.sourceSearchTimedOut(
                    source: source,
                    query: query,
                    token: token,
                    startedAt: sourceStartedAt
                )
            }
        }
    }

    private static func makeSearchOutcome(
        source: MangaHomeSource,
        query: String,
        startedAt: Date
    ) async -> MangaSourceSearchOutcome {
        do {
            try Task.checkCancellation()
            let items = try await searchSource(source, query: query, page: 1)
            try Task.checkCancellation()
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            return .success(source: source, items: items, elapsedMs: elapsed)
        } catch is CancellationError {
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            return .cancelled(source: source, elapsedMs: elapsed)
        } catch {
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            return .failure(source: source, error: error, elapsedMs: elapsed)
        }
    }

    private func sourceSearchFinished(
        _ outcome: MangaSourceSearchOutcome,
        query: String,
        token: UUID
    ) {
        guard searchToken == token, activeSourceIDs.remove(outcome.source.id) != nil else { return }
        sourceSearchTasks.removeValue(forKey: outcome.source.id)
        sourceTimeoutTasks.removeValue(forKey: outcome.source.id)?.cancel()
        pendingSearchCount = max(0, pendingSearchCount - 1)
        handleSearchOutcome(outcome, token: token)
        startQueuedSearches(query: query, token: token)
        finishSearchIfNeeded(token: token)
    }

    private func sourceSearchTimedOut(
        source: MangaHomeSource,
        query: String,
        token: UUID,
        startedAt: Date
    ) {
        guard searchToken == token, activeSourceIDs.remove(source.id) != nil else { return }
        sourceSearchTasks.removeValue(forKey: source.id)?.cancel()
        sourceTimeoutTasks.removeValue(forKey: source.id)
        pendingSearchCount = max(0, pendingSearchCount - 1)
        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
        handleSearchOutcome(.timedOut(source: source, elapsedMs: elapsed), token: token)
        startQueuedSearches(query: query, token: token)
        finishSearchIfNeeded(token: token)
    }

    private func searchDeadlineReached(token: UUID) {
        guard searchToken == token, isSearching else { return }
        let unfinishedNames = queuedSources.enumerated().compactMap { index, source in
            (activeSourceIDs.contains(source.id) || index >= nextSourceIndex) ? source.name : nil
        }
        failedSourceNames = Array(Set(failedSourceNames + unfinishedNames)).sorted()
        let unfinishedCount = pendingSearchCount
        cancelOutstandingSearchTasks()
        pendingSearchCount = 0
        ReaderLogger.shared.log(
            "Global search deadline reached unfinished=\(unfinishedCount)",
            type: "ReaderSearch"
        )
        completeSearch(token: token)
    }

    private func finishSearchIfNeeded(token: UUID) {
        guard pendingSearchCount == 0,
              activeSourceIDs.isEmpty,
              nextSourceIndex >= queuedSources.count else { return }
        completeSearch(token: token)
    }

    private func completeSearch(token: UUID) {
        guard searchToken == token else { return }
        searchDeadlineTask?.cancel()
        searchDeadlineTask = nil
        isSearching = false
        pendingSearchCount = 0
        let elapsed = Int(Date().timeIntervalSince(searchStartedAt) * 1000)
        ReaderLogger.shared.log(
            "Global search completed sections=\(sections.count) failures=\(failedSourceNames.count) elapsedMs=\(elapsed)",
            type: "ReaderSearch"
        )
    }

    private func cancelOutstandingSearchTasks() {
        searchDeadlineTask?.cancel()
        searchDeadlineTask = nil
        sourceSearchTasks.values.forEach { $0.cancel() }
        sourceSearchTasks.removeAll()
        sourceTimeoutTasks.values.forEach { $0.cancel() }
        sourceTimeoutTasks.removeAll()
        activeSourceIDs.removeAll()
        queuedSources = []
        nextSourceIndex = 0
    }

    private func handleSearchOutcome(_ outcome: MangaSourceSearchOutcome, token: UUID) {
        guard searchToken == token else { return }

        if outcome.wasCancelled {
            ReaderLogger.shared.log("Global search source cancelled source=\(outcome.source.id) elapsedMs=\(outcome.elapsedMs)", type: "ReaderSearch")
            return
        }

        if outcome.timedOut {
            failedSourceNames.append(outcome.source.name)
            failedSourceNames.sort()
            ReaderLogger.shared.log("Global search source timed out source=\(outcome.source.id) elapsedMs=\(outcome.elapsedMs)", type: "ReaderSearch")
            return
        }

        if let error = outcome.error {
            failedSourceNames.append(outcome.source.name)
            failedSourceNames.sort()
            ReaderLogger.shared.log("Global search source failed source=\(outcome.source.id) elapsedMs=\(outcome.elapsedMs) error=\(ReaderExtensionDiagnostics.errorCode(error))", type: "ReaderSearch")
            return
        }

        ReaderLogger.shared.log("Global search source finished source=\(outcome.source.id) count=\(outcome.items.count) elapsedMs=\(outcome.elapsedMs)", type: "ReaderSearch")
        guard !outcome.items.isEmpty else { return }

        if !didLogFirstSourceResult {
            didLogFirstSourceResult = true
            let firstElapsed = Int(Date().timeIntervalSince(searchStartedAt) * 1000)
            ReaderLogger.shared.log("Global search first visible section source=\(outcome.source.id) elapsedMs=\(firstElapsed)", type: "ReaderSearch")
        }
        sections.append(MangaModuleSearchSection(id: outcome.source.id, source: outcome.source, items: outcome.items))
    }

    static func searchSource(_ source: MangaHomeSource, query: String, page: Int, filters: [ReaderExtensionFilter] = []) async throws -> [MangaHomeItem] {
        ReaderContentFilter.shared.filterHomeItems(
            try await searchSourceUnfiltered(source, query: query, page: page, filters: filters)
        )
    }

    private static func searchSourceUnfiltered(
        _ source: MangaHomeSource,
        query: String,
        page: Int,
        filters: [ReaderExtensionFilter]
    ) async throws -> [MangaHomeItem] {
        try Task.checkCancellation()
        switch source.kind {
        case .readerExtension:
            guard let sourceID = source.sourceID else { throw ReaderExtensionError.sourceNotFound }
            let provider = try ReaderExtensionManager.shared.provider(
                for: sourceID,
                allowsAutomaticBrowserVerification: true
            )
            let result = try await provider.search(
                query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                page: max(page, 1),
                filters: filters
            )
            try Task.checkCancellation()
            return result.items
                .prefix(MangaHomeViewModel.maxRetainedItemsPerSection)
                .map { MangaHomeItem(sourceID: sourceID, item: $0) }

        case .aidoku:
            throw ReaderExtensionError.sourceNotFound

        case .legacyModule:
            guard let module = source.module else { return [] }
            let engine = KanzenEngine()
            let script = try ModuleManager.shared.getModuleScript(module: module)
            try await engine.loadScript(script, module: module)
            let rawItems = try await engine.searchInput(query, page: page)
            return (rawItems ?? [])
                .compactMap { MangaHomeItem(dict: $0, module: module, sectionKind: .custom) }
                .prefix(MangaHomeViewModel.maxRetainedItemsPerSection)
                .map { $0 }
        }
    }
}

struct KanzenGlobalSearchView: View {
    @EnvironmentObject private var moduleManager: ModuleManager
    @StateObject private var viewModel = MangaGlobalModuleSearchViewModel()
    @StateObject private var readerExtensionManager = ReaderExtensionManager.shared
    @StateObject private var contentFilter = ReaderContentFilter.shared
    @State private var searchText = ""
    @State private var recentSearches = MangaSearchRecentStore.load()
    @State private var liveSearchTask: Task<Void, Never>?

    var body: some View {
        NavigationView {
            Group {
                if contentFilter.isKidsProfileActive {
                    kidsRestrictedView
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            KanzenRootHeader("Search Everything")
                                .padding(.horizontal, -16)

                            KanzenModuleSearchBar(
                                text: $searchText,
                                placeholder: "Search",
                                onSearch: { performSearch(recordRecent: true) }
                            )
                            .padding(.top, 8)
                            .onChange(of: searchText) { newValue in
                                scheduleLiveSearch(newValue)
                            }

                            sourceCards
                            searchStateContent
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 32)
                    }
                }
            }
            .background(GlobalGradientBackground().ignoresSafeArea())
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear {
            syncSources()
        }
        .onChange(of: moduleManager.modules) { _ in
            syncSources()
        }
        .onChange(of: readerExtensionManager.installedSources) { _ in
            syncSources()
        }
        .onChange(of: readerExtensionManager.showMatureSources) { _ in
            syncSources()
        }
        .onDisappear {
            liveSearchTask?.cancel()
            viewModel.cancelSearch(keepResults: true)
        }

        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in
            liveSearchTask?.cancel()
            liveSearchTask = nil
            searchText = ""
            recentSearches = MangaSearchRecentStore.load()
            if ProfileManager.shared.isKidsModeActive {
                viewModel.restrictForKidsProfile()
            } else {
                viewModel.resetSearch()
                syncSources()
            }
        }
        .onChange(of: contentFilter.isKidsProfileActive) { isKids in
            liveSearchTask?.cancel()
            liveSearchTask = nil
            searchText = ""
            if isKids {
                viewModel.restrictForKidsProfile()
            } else {
                syncSources()
            }
        }
    }

    private var kidsRestrictedView: some View {
        VStack(spacing: 0) {
            KanzenRootHeader("Search Everything")
            VStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 42))
                    .foregroundColor(.secondary)
                Text("Reader Search Unavailable")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Text("Reader sources and search cannot be viewed from a kids profile. Switch to a grown-up profile to continue.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var sourceCards: some View {
        let extensionSources = viewModel.sources.filter(\.isReaderExtension)
        let experimental = ExperimentalFeatureState.isEnabledAtLaunch
        if extensionSources.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 34))
                    .foregroundColor(experimental ? .white.opacity(0.62) : .secondary)
                Text("No searchable Reader Extensions installed")
                    .font(.headline)
                    .foregroundColor(experimental ? .white.opacity(0.78) : .secondary)
                NavigationLink(destination: ReaderExtensionsSettingsView()) {
                    Label("Reader Extensions", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .background(
                RoundedRectangle(cornerRadius: experimental ? ExperimentalMediaDesignMetrics.current.cardRadius : 12, style: .continuous)
                    .fill(experimental ? Color.white.opacity(0.10) : EclipseTheme.shared.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: experimental ? ExperimentalMediaDesignMetrics.current.cardRadius : 12, style: .continuous)
                    .stroke(Color.white.opacity(experimental ? 0.14 : 0), lineWidth: 1)
            )
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 14)], alignment: .leading, spacing: 14) {
                ForEach(extensionSources) { source in
                    NavigationLink(destination: MangaReaderExtensionAdvancedSearchView(source: source)) {
                        MangaSearchSourceCard(source: source)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var searchStateContent: some View {
        if viewModel.hasSearched, !viewModel.sections.isEmpty {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(viewModel.sections) { section in
                    MangaModuleSearchSectionView(section: section)
                        .equatable()
                }

                if viewModel.isSearching {
                    HStack(spacing: 10) {
                        EclipseLoadingIndicator()
                        Text("Searching more sources...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }

                if !viewModel.failedSourceNames.isEmpty {
                    Text("Skipped unavailable sources: \(viewModel.failedSourceNames.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 2)
                }
            }
        } else if viewModel.isSearching {
            HStack(spacing: 10) {
                EclipseLoadingIndicator()
                Text("Searching sources...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        } else if viewModel.hasSearched {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("No results found")
                    .font(.headline)
                    .foregroundColor(.secondary)
                if !viewModel.failedSourceNames.isEmpty {
                    Text("Some sources did not respond: \(viewModel.failedSourceNames.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)
        } else {
            recentSearchesView
        }
    }

    @ViewBuilder
    private var recentSearchesView: some View {
        if !recentSearches.isEmpty {
            VStack(spacing: 0) {
                HStack {
                    Text("RECENT SEARCHES")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("CLEAR") {
                        MangaSearchRecentStore.clear()
                        recentSearches = []
                    }
                    .font(.subheadline)
                    .foregroundColor(.accentColor)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider()

                ForEach(recentSearches, id: \.self) { query in
                    Button {
                        searchText = query
                        performSearch(recordRecent: true)
                    } label: {
                        HStack {
                            Text(query)
                                .font(.title3)
                                .foregroundColor(.white)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)

                    if query != recentSearches.last {
                        Divider()
                    }
                }
            }
            .background(EclipseTheme.shared.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func performSearch(recordRecent: Bool) {
        guard !ProfileManager.shared.isKidsModeActive else {
            viewModel.restrictForKidsProfile()
            return
        }
        liveSearchTask?.cancel()
        liveSearchTask = nil
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            viewModel.resetSearch()
            return
        }

        if recordRecent {
            recentSearches = MangaSearchRecentStore.add(query)
        }

        syncSources()
        viewModel.searchAll(query)
    }

    private func scheduleLiveSearch(_ value: String) {
        guard !ProfileManager.shared.isKidsModeActive else {
            viewModel.restrictForKidsProfile()
            return
        }
        liveSearchTask?.cancel()
        let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            viewModel.resetSearch()
            return
        }
        guard !viewModel.isShowingResults(for: query) else { return }

        liveSearchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                liveSearchTask = nil
                guard searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                guard !viewModel.isShowingResults(for: query) else { return }
                syncSources()
                viewModel.searchAll(query)
            }
        }
    }

    private func syncSources() {
        guard !ProfileManager.shared.isKidsModeActive else {
            viewModel.restrictForKidsProfile()
            return
        }
        viewModel.refreshSources(
            from: moduleManager.modules,
            readerExtensionManager: readerExtensionManager
        )
    }
}

private struct MangaModuleSearchSectionView: View, Equatable {
    let section: MangaModuleSearchSection
    private var designMetrics: ExperimentalMediaDesignMetrics { .current }
    private var posterWidth: CGFloat {
        ExperimentalFeatureState.isEnabledAtLaunch ? designMetrics.posterCardSize(isIPad: isIPad).width : (isIPad ? 132 * iPadScaleSmall : 132)
    }

    var body: some View {
        let experimental = ExperimentalFeatureState.isEnabledAtLaunch
        VStack(alignment: .leading, spacing: experimental ? 14 : 12) {
            Text(section.source.name)
                .font(experimental ? Font.system(size: 34, weight: .bold) : Font.largeTitle)
                .foregroundColor(experimental ? .white : .primary)
                .lineLimit(1)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: experimental ? 16 : 12) {
                    ForEach(section.items.prefix(MangaHomeViewModel.maxVisibleItemsPerSection)) { item in
                        NavigationLink(destination: MangaSearchItemDestination(source: section.source, item: item)) {
                            MangaSearchPosterCard(item: item, width: posterWidth)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .modifier(KanzenScrollClipModifier())
        }
    }
}

private struct MangaSearchItemDestination: View {
    let source: MangaHomeSource
    let item: MangaHomeItem

    var body: some View {
        if let extensionItem = item.readerExtensionItem, let sourceID = source.sourceID {
            ReaderExtensionMangaDetailView(sourceID: sourceID, initialItem: extensionItem)
        } else if case .readerExtension(let sourceID, let itemKey, let legacyStableKey) = item.route {
            ReaderExtensionMangaRouteLoaderView(
                sourceID: sourceID,
                itemKey: itemKey,
                legacyStableKey: legacyStableKey,
                title: item.title,
                coverURL: item.imageURL
            )
        } else if let module = source.module {
            MangaModuleContentLoaderView(
                module: module,
                title: item.title,
                imageURL: item.imageURL,
                contentParams: item.params,
                isNovel: module.moduleData.novel == true
            )
        } else {
            MangaModuleUnavailableView(title: item.title, message: "This source is no longer available.")
        }
    }
}

private struct MangaSearchPosterCard: View {
    let item: MangaHomeItem
    let width: CGFloat
    private var designMetrics: ExperimentalMediaDesignMetrics { .current }

    var body: some View {
        let experimental = ExperimentalFeatureState.isEnabledAtLaunch
        VStack(alignment: .leading, spacing: experimental ? 8 : 4) {
            ReaderScopedRemoteImage(
                url: URL(string: item.imageURL),
                readerExtensionSourceID: item.route?.readerExtensionSourceID,
                maximumPixelSize: isIPad ? 900 : 640
            ) {
                    Rectangle().fill(Color.gray.opacity(0.22))
            }
                .scaledToFill()
                .frame(width: width, height: width * 1.45)
                .clipped()
                .cornerRadius(experimental ? designMetrics.cardRadius : 10)

            Text(item.title)
                .font(experimental ? .title3.weight(.semibold) : .headline)
                .lineLimit(1)
                .foregroundColor(experimental ? .white : .primary)
                .frame(width: width, alignment: .leading)

            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(experimental ? .white.opacity(0.62) : .secondary)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
        }
    }
}

private struct MangaSearchSourceCard: View {
    let source: MangaHomeSource
    private var designMetrics: ExperimentalMediaDesignMetrics { .current }

    var body: some View {
        let experimental = ExperimentalFeatureState.isEnabledAtLaunch
        VStack(alignment: .leading, spacing: experimental ? 10 : 8) {
            ZStack {
                RoundedRectangle(cornerRadius: experimental ? designMetrics.cardRadius : 12, style: .continuous)
                    .fill(experimental ? Color.white.opacity(0.10) : EclipseTheme.shared.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: experimental ? designMetrics.cardRadius : 12, style: .continuous)
                            .stroke(Color.white.opacity(experimental ? 0.14 : 0), lineWidth: 1)
                    )

                ReaderScopedRemoteImage(
                    url: URL(string: source.iconURL),
                    readerExtensionSourceID: source.sourceID,
                    maximumPixelSize: 512
                ) {
                        Image(systemName: "shippingbox")
                            .font(.title3)
                            .foregroundColor(.secondary)
                }
                    .scaledToFit()
                    .padding(24)
            }
            .aspectRatio(1, contentMode: .fit)

            Text(source.name)
                .font(.headline)
                .fontWeight(.bold)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundColor(experimental ? .white : .primary)
        }
    }
}

@MainActor
private final class MangaReaderExtensionAdvancedSearchViewModel: ObservableObject {
    @Published var items: [MangaHomeItem] = []
    @Published var isSearching = false
    @Published private(set) var isLoadingMore = false
    @Published var hasSearched = false
    @Published var errorMessage: String?
    @Published var paginationErrorMessage: String?
    @Published private(set) var currentPage = 0
    @Published private(set) var hasNextPage = false

    private struct AppliedSearchSnapshot {
        let query: String
        let filters: [ReaderExtensionFilter]
    }

    private struct SearchPage {
        let items: [MangaHomeItem]
        let hasNextPage: Bool
    }

    private static let maxRetainedResults = 120
    private static let maxPageCount = 10

    private var searchToken = UUID()
    private var searchTask: Task<Void, Never>?
    private var appliedSearchSnapshot: AppliedSearchSnapshot?

    /// A catalog may only be built from a search that actually ran, so the
    /// saved row is guaranteed to reproduce what the user just looked at.
    var appliedCatalogDraft: (query: String, filters: [ReaderExtensionFilter])? {
        guard hasSearched, !isSearching, errorMessage == nil, let appliedSearchSnapshot else { return nil }
        return (appliedSearchSnapshot.query, appliedSearchSnapshot.filters)
    }

    var canLoadMore: Bool {
        hasSearched
            && hasNextPage
            && currentPage > 0
            && currentPage < Self.maxPageCount
            && items.count < Self.maxRetainedResults
            && !isSearching
            && !isLoadingMore
            && appliedSearchSnapshot != nil
    }

    var didReachResultLimit: Bool {
        hasSearched
            && hasNextPage
            && (currentPage >= Self.maxPageCount || items.count >= Self.maxRetainedResults)
    }

    func search(source: MangaHomeSource, query: String, filters: [ReaderExtensionFilter]) {
        let token = UUID()
        searchTask?.cancel()
        searchToken = token
        let snapshot = AppliedSearchSnapshot(
            query: query.trimmingCharacters(in: .whitespacesAndNewlines),
            filters: filters
        )
        appliedSearchSnapshot = snapshot
        isSearching = true
        isLoadingMore = false
        hasSearched = true
        errorMessage = nil
        paginationErrorMessage = nil
        items = []
        currentPage = 0
        hasNextPage = false
        ReaderLogger.shared.log("Advanced search started source=\(source.id) queryLength=\(snapshot.query.count) filters=\(snapshot.filters.count)", type: "ReaderSearch")

        searchTask = Task { @MainActor in
            let started = Date()
            do {
                try Task.checkCancellation()
                let result = try await Self.searchPage(source: source, snapshot: snapshot, page: 1)
                try Task.checkCancellation()
                guard searchToken == token else { return }
                items = Self.merging([], with: result.items)
                currentPage = 1
                hasNextPage = result.hasNextPage
                isSearching = false
                searchTask = nil
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                ReaderLogger.shared.log("Advanced search finished source=\(source.id) page=1 count=\(items.count) hasNext=\(result.hasNextPage) elapsedMs=\(elapsed)", type: "ReaderSearch")
            } catch is CancellationError {
                guard searchToken == token else { return }
                isSearching = false
                searchTask = nil
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                ReaderLogger.shared.log("Advanced search cancelled source=\(source.id) elapsedMs=\(elapsed)", type: "ReaderSearch")
            } catch {
                guard searchToken == token else { return }
                items = []
                errorMessage = error.localizedDescription
                isSearching = false
                currentPage = 0
                hasNextPage = false
                searchTask = nil
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                ReaderLogger.shared.log("Advanced search failed source=\(source.id) elapsedMs=\(elapsed) error=\(ReaderExtensionDiagnostics.errorCode(error))", type: "ReaderSearch")
            }
        }
    }

    func loadMore(source: MangaHomeSource) {
        guard canLoadMore, let snapshot = appliedSearchSnapshot else { return }

        let token = searchToken
        let nextPage = currentPage + 1
        isLoadingMore = true
        paginationErrorMessage = nil
        ReaderLogger.shared.log("Advanced search load more started source=\(source.id) page=\(nextPage)", type: "ReaderSearch")

        searchTask = Task { @MainActor in
            let started = Date()
            do {
                try Task.checkCancellation()
                let result = try await Self.searchPage(source: source, snapshot: snapshot, page: nextPage)
                try Task.checkCancellation()
                guard searchToken == token, appliedSearchSnapshot != nil else { return }
                items = Self.merging(items, with: result.items)
                currentPage = nextPage
                hasNextPage = result.hasNextPage
                isLoadingMore = false
                searchTask = nil
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                ReaderLogger.shared.log("Advanced search load more finished source=\(source.id) page=\(nextPage) received=\(result.items.count) retained=\(items.count) hasNext=\(result.hasNextPage) elapsedMs=\(elapsed)", type: "ReaderSearch")
            } catch is CancellationError {
                guard searchToken == token else { return }
                isLoadingMore = false
                searchTask = nil
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                ReaderLogger.shared.log("Advanced search load more cancelled source=\(source.id) page=\(nextPage) elapsedMs=\(elapsed)", type: "ReaderSearch")
            } catch {
                guard searchToken == token else { return }
                paginationErrorMessage = error.localizedDescription
                isLoadingMore = false
                searchTask = nil
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                ReaderLogger.shared.log("Advanced search load more failed source=\(source.id) page=\(nextPage) elapsedMs=\(elapsed) error=\(ReaderExtensionDiagnostics.errorCode(error))", type: "ReaderSearch")
            }
        }
    }

    func cancel() {
        let wasSearching = isSearching || isLoadingMore
        searchToken = UUID()
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        isLoadingMore = false
        if wasSearching {
            ReaderLogger.shared.log("Advanced search cancelled reason=view-disappear", type: "ReaderSearch")
        }
    }

    private static func searchPage(
        source: MangaHomeSource,
        snapshot: AppliedSearchSnapshot,
        page: Int
    ) async throws -> SearchPage {
        guard let sourceID = source.sourceID else { throw ReaderExtensionError.sourceNotFound }
        try Task.checkCancellation()
        let provider = try ReaderExtensionManager.shared.provider(
            for: sourceID,
            allowsAutomaticBrowserVerification: true
        )
        let result = try await provider.search(
            query: snapshot.query,
            page: max(page, 1),
            filters: snapshot.filters
        )
        try Task.checkCancellation()
        let mappedItems = result.items
            .prefix(MangaHomeViewModel.maxRetainedItemsPerSection)
            .map { MangaHomeItem(sourceID: sourceID, item: $0) }
        return SearchPage(
            items: ReaderContentFilter.shared.filterHomeItems(mappedItems),
            hasNextPage: result.hasNextPage
        )
    }

    private static func merging(
        _ existingItems: [MangaHomeItem],
        with newItems: [MangaHomeItem]
    ) -> [MangaHomeItem] {
        var merged = Array(existingItems.prefix(Self.maxRetainedResults))
        var retainedIDs = Set(merged.map(\.id))
        for item in newItems where merged.count < Self.maxRetainedResults {
            guard retainedIDs.insert(item.id).inserted else { continue }
            merged.append(item)
        }
        return merged
    }
}

private struct MangaReaderExtensionAdvancedSearchView: View {
    let source: MangaHomeSource

    @StateObject private var viewModel = MangaReaderExtensionAdvancedSearchViewModel()
    @StateObject private var filterEditor = ReaderExtensionFilterEditorModel()
    @State private var searchText = ""
    @State private var hasPendingSearchChanges = false
    @State private var catalogDraft: KanzenCustomCatalog?
    @State private var savedCatalogTitle: String?
    @State private var catalogErrorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 116), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                KanzenModuleSearchBar(
                    text: $searchText,
                    placeholder: "Search \(source.name)",
                    onSearch: submitSearch
                )
                .onChange(of: searchText) { _ in markSearchPending() }

                Button(action: submitSearch) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                        Text(searchButtonTitle)
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isSearchBlocked)
                .opacity(isSearchBlocked ? 0.55 : 1)
                .accessibilityHint("Runs one search using the current title and every selected filter.")

                saveAsCatalogControls
                resultsContent
                filtersContent
            }
            .padding(16)
        }
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .kanzenGradientBackground()
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: submitSearch) {
                    Image(systemName: "magnifyingglass")
                }
                .disabled(isSearchBlocked)
                .tint(.white)
                .accessibilityLabel("Search with current filters")
            }
        }
        .task {
            loadFilters()
        }
        .onChange(of: filterEditor.successfulLoadRevision) { _ in
            if viewModel.hasSearched {
                markSearchPending()
            }
        }
        .onDisappear {
            viewModel.cancel()
            filterEditor.cancel()
        }
        .sheet(item: $catalogDraft) { draft in
            KanzenCustomCatalogEditorView(
                sourceName: source.name,
                draft: draft,
                isRenamingExistingCatalog: false,
                onSaved: { saved in
                    savedCatalogTitle = saved.displayTitle
                    catalogErrorMessage = nil
                }
            )
        }
    }

    @ViewBuilder
    private var saveAsCatalogControls: some View {
        if let draft = viewModel.appliedCatalogDraft, let sourceID = source.sourceID {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    presentCatalogEditor(sourceID: sourceID, draft: draft)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.stack.badge.plus")
                        Text("Save as Catalog")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.white.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Saves these filters as a row on Discover for \(source.name).")

                if let savedCatalogTitle {
                    Label("Saved \u{201C}\(savedCatalogTitle)\u{201D} to Discover", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundColor(.green.opacity(0.9))
                }
                if let catalogErrorMessage {
                    Label(catalogErrorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange.opacity(0.9))
                }
            }
        }
    }

    private func presentCatalogEditor(
        sourceID: ReaderExtensionSourceID,
        draft: (query: String, filters: [ReaderExtensionFilter])
    ) {
        savedCatalogTitle = nil
        guard KanzenCustomCatalogManager.shared.canAddCatalog(for: sourceID) else {
            catalogErrorMessage = KanzenCustomCatalogError
                .sourceLimitReached(KanzenCustomCatalogManager.maximumCatalogsPerSource)
                .localizedDescription
            return
        }
        catalogErrorMessage = nil
        catalogDraft = KanzenCustomCatalog(
            title: "",
            sourceID: sourceID,
            query: draft.query,
            filters: draft.filters
        )
    }

    @ViewBuilder
    private var filtersContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Filters")
                    .font(.headline)
                    .foregroundColor(.white)
                Text("\(filterEditor.displayRows.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.62))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
                Spacer(minLength: 4)
                filterResetButton
                filterRefreshButton
            }

            if let filterErrorMessage = filterEditor.errorMessage {
                Label(filterErrorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if filterEditor.isLoading {
                HStack(spacing: 10) {
                    EclipseLoadingIndicator()
                    Text("Loading filters...")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.62))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else if filterEditor.filters.isEmpty {
                Text("This source does not expose advanced filters.")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.62))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ReaderExtensionFilterEditorList(
                    filters: $filterEditor.filters,
                    onEdit: markSearchPending
                )
            }
        }
        .padding(14)
        .background(EclipseTheme.shared.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var resultsContent: some View {
        if viewModel.isSearching {
            HStack(spacing: 10) {
                EclipseLoadingIndicator()
                Text("Searching...")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.62))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else if let errorMessage = viewModel.errorMessage {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundColor(.orange.opacity(0.9))
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else if viewModel.hasSearched, viewModel.items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.largeTitle)
                    .foregroundColor(.white.opacity(0.62))
                Text(viewModel.hasNextPage ? "No visible results on this page" : "No results found")
                    .font(.headline)
                    .foregroundColor(.white)
                Text(viewModel.hasNextPage ? "Load another page or adjust the filters below." : "Try a different title or adjust the filters below.")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.62))
                    .multilineTextAlignment(.center)
                if viewModel.hasNextPage {
                    paginationControls
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else if viewModel.hasSearched {
            VStack(spacing: 14) {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(viewModel.items) { item in
                        NavigationLink(destination: MangaSearchItemDestination(source: source, item: item)) {
                            MangaSearchPosterCard(item: item, width: 116)
                        }
                        .buttonStyle(.plain)
                    }
                }

                paginationControls
            }
        }
    }

    private var filterResetButton: some View {
        Button {
            if filterEditor.reset() {
                markSearchPending()
            }
        } label: {
            Label("Reset", systemImage: "arrow.counterclockwise")
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!filterEditor.canReset)
        .opacity(filterEditor.canReset ? 1 : 0.42)
        .accessibilityHint("Restores the filter defaults loaded when this screen opened without searching.")
    }

    private var filterRefreshButton: some View {
        Button {
            refreshFilters()
        } label: {
            Label("Refresh Filters", systemImage: "arrow.clockwise")
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isFilterRefreshBlocked)
        .opacity(isFilterRefreshBlocked ? 0.42 : 1)
        .accessibilityHint("Reloads this source's filter choices without searching.")
    }

    @ViewBuilder
    private var paginationControls: some View {
        if let paginationErrorMessage = viewModel.paginationErrorMessage {
            Label(paginationErrorMessage, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundColor(.orange.opacity(0.9))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }

        if viewModel.isLoadingMore {
            HStack(spacing: 10) {
                EclipseLoadingIndicator()
                Text("Loading page \(viewModel.currentPage + 1)...")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.62))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        } else if canLoadMoreResults {
            Button {
                viewModel.loadMore(source: source)
            } label: {
                Label("Load More", systemImage: "chevron.down")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Loads one more page using the filters from the last applied search.")
        } else if viewModel.didReachResultLimit {
            Text("Result limit reached. Refine the title or filters to continue.")
                .font(.caption)
                .foregroundColor(.white.opacity(0.62))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }

        if viewModel.currentPage > 0 {
            Text("Page \(viewModel.currentPage) · \(viewModel.items.count) results")
                .font(.caption2.weight(.semibold))
                .foregroundColor(.white.opacity(0.50))
                .frame(maxWidth: .infinity)
        }
    }

    private var isSearchBlocked: Bool {
        filterEditor.isLoading || viewModel.isSearching
    }

    private var isFilterRefreshBlocked: Bool {
        filterEditor.isLoading || viewModel.isSearching || viewModel.isLoadingMore
    }

    private var canLoadMoreResults: Bool {
        viewModel.canLoadMore && !filterEditor.isLoading
    }

    private func loadFilters() {
        guard let sourceID = filterSourceID() else { return }
        filterEditor.load(sourceID: sourceID, label: source.id)
    }

    private func refreshFilters() {
        guard !viewModel.isSearching, !viewModel.isLoadingMore else { return }
        guard let sourceID = filterSourceID() else { return }
        filterEditor.reload(sourceID: sourceID, label: source.id)
    }

    private func filterSourceID() -> ReaderExtensionSourceID? {
        guard let sourceID = source.sourceID else {
            filterEditor.reportUnavailableSource()
            return nil
        }
        return sourceID
    }

    private func submitSearch() {
        guard !isSearchBlocked else { return }
        hasPendingSearchChanges = false
        viewModel.search(source: source, query: searchText, filters: filterEditor.filters)
    }

    private var searchButtonTitle: String {
        guard viewModel.hasSearched else { return "Apply & Search" }
        return hasPendingSearchChanges ? "Apply Changes & Search" : "Search Again"
    }

    private func markSearchPending() {
        hasPendingSearchChanges = true
    }
}

struct KanzenModuleSearchBar: View {
    @Binding var text: String
    let placeholder: String
    let onSearch: () -> Void

    var body: some View {
        let experimental = ExperimentalFeatureState.isEnabledAtLaunch
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundColor(.white.opacity(0.72))

            TextField(
                "",
                text: $text,
                prompt: Text(placeholder).foregroundColor(.white.opacity(0.42))
            )
                .font(.title2)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .foregroundColor(.white)
                .tint(.white)
                .onSubmit(onSearch)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.white.opacity(0.62))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: experimental ? ExperimentalMediaDesignMetrics.current.cardRadius : 12, style: .continuous)
                .fill(experimental ? Color.white.opacity(0.12) : EclipseTheme.shared.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: experimental ? ExperimentalMediaDesignMetrics.current.cardRadius : 12, style: .continuous)
                .stroke(Color.white.opacity(experimental ? 0.14 : 0), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
    }
}

#endif
