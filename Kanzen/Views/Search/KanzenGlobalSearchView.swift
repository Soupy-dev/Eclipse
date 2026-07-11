import SwiftUI
import Kingfisher
import AidokuRunner

#if !os(tvOS)
private enum MangaSearchRecentStore {
    private static let key = "kanzenRecentSourceSearches"
    static let limit = 10

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    @discardableResult
    static func add(_ query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return load() }

        var searches = load().filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        searches.insert(trimmed, at: 0)
        searches = Array(searches.prefix(limit))
        UserDefaults.standard.set(searches, forKey: key)
        return searches
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
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

    static func success(source: MangaHomeSource, items: [MangaHomeItem], elapsedMs: Int) -> MangaSourceSearchOutcome {
        MangaSourceSearchOutcome(source: source, items: items, error: nil, elapsedMs: elapsedMs, wasCancelled: false)
    }

    static func failure(source: MangaHomeSource, error: Error, elapsedMs: Int) -> MangaSourceSearchOutcome {
        MangaSourceSearchOutcome(source: source, items: [], error: error, elapsedMs: elapsedMs, wasCancelled: false)
    }

    static func cancelled(source: MangaHomeSource, elapsedMs: Int) -> MangaSourceSearchOutcome {
        MangaSourceSearchOutcome(source: source, items: [], error: nil, elapsedMs: elapsedMs, wasCancelled: true)
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
    private var searchToken = UUID()
    private var pendingSearchCount = 0
    private var searchStartedAt = Date.distantPast
    private var didLogFirstSourceResult = false
    private var activeSearchTask: Task<Void, Never>?

    func refreshSources(from modules: [ModuleDataContainer], aidokuManager: AidokuSourceManager) {
        MangaHomeSourceManager.shared.refreshSources(from: modules)
        sources = MangaHomeSourceManager.shared.enabledSources(aidokuManager: aidokuManager, modules: modules)
        ReaderLogger.shared.log("Global search sources refreshed aidoku=\(sources.filter(\.isAidoku).count) total=\(sources.count)", type: "ReaderSearch")
    }

    func resetSearch() {
        cancelCurrentSearch(reason: "reset", clearResults: true)
    }

    func cancelSearch(keepResults: Bool = true) {
        cancelCurrentSearch(reason: "view-disappear", clearResults: !keepResults)
    }

    private func cancelCurrentSearch(reason: String, clearResults: Bool) {
        let wasSearching = isSearching
        searchToken = UUID()
        activeSearchTask?.cancel()
        activeSearchTask = nil
        pendingSearchCount = 0
        if clearResults {
            sections = []
            failedSourceNames = []
            hasSearched = false
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

        let activeSources = sources.filter(\.isAidoku)
        guard !activeSources.isEmpty else {
            sections = []
            failedSourceNames = []
            isSearching = false
            hasSearched = true
            ReaderLogger.shared.log("Global search skipped no Aidoku sources queryLength=\(trimmed.count)", type: "ReaderSearch")
            return
        }

        let token = UUID()
        activeSearchTask?.cancel()
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

        activeSearchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runSearch(activeSources: activeSources, query: trimmed, token: token)
        }
    }

    private func runSearch(activeSources: [MangaHomeSource], query: String, token: UUID) async {
        await withTaskGroup(of: MangaSourceSearchOutcome.self) { group in
            var nextIndex = 0

            func enqueue(_ source: MangaHomeSource) {
                group.addTask {
                    let sourceStartedAt = Date()
                    ReaderLogger.shared.log("Global search source started source=\(source.id)", type: "ReaderSearch")
                    do {
                        try Task.checkCancellation()
                        let items = try await Self.searchSource(source, query: query, page: 1)
                        try Task.checkCancellation()
                        let elapsed = Int(Date().timeIntervalSince(sourceStartedAt) * 1000)
                        return .success(source: source, items: items, elapsedMs: elapsed)
                    } catch is CancellationError {
                        let elapsed = Int(Date().timeIntervalSince(sourceStartedAt) * 1000)
                        return .cancelled(source: source, elapsedMs: elapsed)
                    } catch {
                        let elapsed = Int(Date().timeIntervalSince(sourceStartedAt) * 1000)
                        return .failure(source: source, error: error, elapsedMs: elapsed)
                    }
                }
            }

            let initialCount = min(Self.maxConcurrentSourceSearches, activeSources.count)
            while nextIndex < initialCount {
                enqueue(activeSources[nextIndex])
                nextIndex += 1
            }

            while let outcome = await group.next() {
                guard searchToken == token, !Task.isCancelled else {
                    group.cancelAll()
                    break
                }

                pendingSearchCount = max(0, pendingSearchCount - 1)
                handleSearchOutcome(outcome, token: token)

                if nextIndex < activeSources.count {
                    enqueue(activeSources[nextIndex])
                    nextIndex += 1
                }
            }
        }

        guard searchToken == token else { return }
        isSearching = false
        pendingSearchCount = 0
        activeSearchTask = nil
        let elapsed = Int(Date().timeIntervalSince(searchStartedAt) * 1000)
        ReaderLogger.shared.log(
            "Global search completed sections=\(sections.count) failures=\(failedSourceNames.count) elapsedMs=\(elapsed)",
            type: "ReaderSearch"
        )
    }

    private func handleSearchOutcome(_ outcome: MangaSourceSearchOutcome, token: UUID) {
        guard searchToken == token else { return }

        if outcome.wasCancelled {
            ReaderLogger.shared.log("Global search source cancelled source=\(outcome.source.id) elapsedMs=\(outcome.elapsedMs)", type: "ReaderSearch")
            return
        }

        if let error = outcome.error {
            failedSourceNames.append(outcome.source.name)
            failedSourceNames.sort()
            ReaderLogger.shared.log("Global search source failed source=\(outcome.source.id) elapsedMs=\(outcome.elapsedMs): \(error.localizedDescription)", type: "ReaderSearch")
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

    static func searchSource(_ source: MangaHomeSource, query: String, page: Int, filters: [AidokuRunner.FilterValue] = []) async throws -> [MangaHomeItem] {
        try Task.checkCancellation()
        switch source.kind {
        case .aidoku:
            guard let sourceId = source.sourceId else { throw AidokuSourceError.sourceNotInstalled }
            let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try await AidokuSourceManager.shared.search(
                sourceId: sourceId,
                query: normalizedQuery.isEmpty ? nil : normalizedQuery,
                page: page,
                filters: filters
            )
            try Task.checkCancellation()
            return result.entries
                .prefix(MangaHomeViewModel.maxRetainedItemsPerSection)
                .map { MangaHomeItem(sourceId: sourceId, manga: $0) }

        case .legacyModule:
            guard let module = source.module else { return [] }
            return try await withCheckedThrowingContinuation { continuation in
                let engine = KanzenEngine()
                do {
                    let script = try ModuleManager.shared.getModuleScript(module: module)
                    try engine.loadScript(script, isNovel: module.moduleData.novel == true)
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                engine.searchInput(query, page: page) { rawItems in
                    let items = (rawItems ?? [])
                        .compactMap { MangaHomeItem(dict: $0, module: module, sectionKind: .custom) }
                        .prefix(MangaHomeViewModel.maxRetainedItemsPerSection)
                        .map { $0 }
                    continuation.resume(returning: items)
                }
            }
        }
    }
}

struct KanzenGlobalSearchView: View {
    @EnvironmentObject private var moduleManager: ModuleManager
    @StateObject private var viewModel = MangaGlobalModuleSearchViewModel()
    @StateObject private var sourceManager = MangaHomeSourceManager.shared
    @StateObject private var aidokuManager = AidokuSourceManager.shared
    @State private var searchText = ""
    @State private var recentSearches = MangaSearchRecentStore.load()
    @State private var scrollOffset: CGFloat = 0
    @State private var liveSearchTask: Task<Void, Never>?

    var body: some View {
        NavigationView {
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
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ScrollOffsetPreferenceKey.self,
                            value: -geo.frame(in: .named("kanzenSearchScroll")).origin.y
                        )
                    }
                )
            }
            .coordinateSpace(name: "kanzenSearchScroll")
            .onPreferenceChange(ScrollOffsetPreferenceKey.self) { scrollOffset = $0 }
            .background(GlobalGradientBackground(scrollOffset: scrollOffset).ignoresSafeArea())
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear {
            syncSources()
        }
        .onChange(of: moduleManager.modules) { _ in
            syncSources()
        }
        .onReceive(sourceManager.objectWillChange) { _ in
            DispatchQueue.main.async { syncSources() }
        }
        .onReceive(aidokuManager.objectWillChange) { _ in
            DispatchQueue.main.async { syncSources() }
        }
        .onDisappear {
            liveSearchTask?.cancel()
            viewModel.cancelSearch(keepResults: true)
        }
    }

    @ViewBuilder
    private var sourceCards: some View {
        let aidokuSources = viewModel.sources.filter(\.isAidoku)
        let experimental = ExperimentalFeatureState.isEnabledAtLaunch
        if aidokuSources.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 34))
                    .foregroundColor(experimental ? .white.opacity(0.62) : .secondary)
                Text("No searchable Aidoku sources installed")
                    .font(.headline)
                    .foregroundColor(experimental ? .white.opacity(0.78) : .secondary)
                NavigationLink(destination: AidokuSourcesSettingsView()) {
                    Label("Aidoku Sources", systemImage: "plus.circle")
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
                ForEach(aidokuSources) { source in
                    NavigationLink(destination: MangaAidokuAdvancedSearchView(source: source)) {
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
                                .foregroundColor(.primary)
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
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            viewModel.resetSearch()
            return
        }

        if recordRecent {
            recentSearches = MangaSearchRecentStore.add(query)
        }
        viewModel.searchAll(query)
    }

    private func scheduleLiveSearch(_ value: String) {
        liveSearchTask?.cancel()
        let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            viewModel.resetSearch()
            return
        }

        liveSearchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                viewModel.searchAll(query)
            }
        }
    }

    private func syncSources() {
        viewModel.refreshSources(from: moduleManager.modules, aidokuManager: aidokuManager)
    }
}

private struct MangaModuleSearchSectionView: View {
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
                    ForEach(Array(section.items.prefix(MangaHomeViewModel.maxVisibleItemsPerSection))) { item in
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
        if let manga = item.aidokuManga, let sourceId = source.sourceId {
            AidokuMangaDetailView(sourceId: sourceId, initialManga: manga)
        } else if case .aidoku(let sourceId, let mangaKey) = item.route {
            AidokuMangaRouteLoaderView(sourceId: sourceId, mangaKey: mangaKey, title: item.title, coverURL: item.imageURL)
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
            KFImage(URL(string: item.imageURL))
                .placeholder {
                    Rectangle().fill(Color.gray.opacity(0.22))
                }
                .resizable()
                .setProcessor(DownsamplingImageProcessor(size: CGSize(width: width, height: width * 1.45)))
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

                KFImage(URL(string: source.iconURL))
                    .placeholder {
                        Image(systemName: "shippingbox")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                    .resizable()
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
private final class MangaAidokuAdvancedSearchViewModel: ObservableObject {
    @Published var filters: [AidokuRunner.Filter] = []
    @Published var items: [MangaHomeItem] = []
    @Published var isLoadingFilters = false
    @Published var isSearching = false
    @Published var errorMessage: String?

    private var searchToken = UUID()
    private var filterTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    func loadFilters(source: MangaHomeSource) {
        guard let sourceId = source.sourceId, filters.isEmpty, !isLoadingFilters else { return }
        filterTask?.cancel()
        isLoadingFilters = true
        errorMessage = nil
        ReaderLogger.shared.log("Advanced search filters started source=\(source.id)", type: "ReaderSearch")

        filterTask = Task { @MainActor in
            let started = Date()
            do {
                try Task.checkCancellation()
                filters = try await AidokuSourceManager.shared.filters(sourceId: sourceId)
                try Task.checkCancellation()
                isLoadingFilters = false
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                ReaderLogger.shared.log("Advanced search filters loaded source=\(source.id) count=\(filters.count) elapsedMs=\(elapsed)", type: "ReaderSearch")
            } catch is CancellationError {
                isLoadingFilters = false
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                ReaderLogger.shared.log("Advanced search filters cancelled source=\(source.id) elapsedMs=\(elapsed)", type: "ReaderSearch")
            } catch {
                errorMessage = error.localizedDescription
                isLoadingFilters = false
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                ReaderLogger.shared.log("Advanced search filters failed source=\(source.id) elapsedMs=\(elapsed): \(error.localizedDescription)", type: "ReaderSearch")
            }
        }
    }

    func search(source: MangaHomeSource, query: String, filters: [AidokuRunner.FilterValue]) {
        let token = UUID()
        searchTask?.cancel()
        searchToken = token
        isSearching = true
        errorMessage = nil
        ReaderLogger.shared.log("Advanced search started source=\(source.id) queryLength=\(query.trimmingCharacters(in: .whitespacesAndNewlines).count) filters=\(filters.count)", type: "ReaderSearch")

        searchTask = Task { @MainActor in
            let started = Date()
            do {
                try Task.checkCancellation()
                let results = try await MangaGlobalModuleSearchViewModel.searchSource(source, query: query, page: 1, filters: filters)
                try Task.checkCancellation()
                guard searchToken == token else { return }
                items = results
                isSearching = false
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                ReaderLogger.shared.log("Advanced search finished source=\(source.id) count=\(results.count) elapsedMs=\(elapsed)", type: "ReaderSearch")
            } catch is CancellationError {
                guard searchToken == token else { return }
                isSearching = false
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                ReaderLogger.shared.log("Advanced search cancelled source=\(source.id) elapsedMs=\(elapsed)", type: "ReaderSearch")
            } catch {
                guard searchToken == token else { return }
                items = []
                errorMessage = error.localizedDescription
                isSearching = false
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                ReaderLogger.shared.log("Advanced search failed source=\(source.id) elapsedMs=\(elapsed): \(error.localizedDescription)", type: "ReaderSearch")
            }
        }
    }

    func cancel() {
        let wasSearching = isSearching || isLoadingFilters
        searchToken = UUID()
        filterTask?.cancel()
        searchTask?.cancel()
        filterTask = nil
        searchTask = nil
        isLoadingFilters = false
        isSearching = false
        if wasSearching {
            ReaderLogger.shared.log("Advanced search cancelled reason=view-disappear", type: "ReaderSearch")
        }
    }
}

private struct MangaAidokuAdvancedSearchView: View {
    let source: MangaHomeSource

    @StateObject private var viewModel = MangaAidokuAdvancedSearchViewModel()
    @State private var searchText = ""
    @State private var textValues: [String: String] = [:]
    @State private var checkValues: [String: Int] = [:]
    @State private var selectValues: [String: String] = [:]
    @State private var sortIndexValues: [String: Int] = [:]
    @State private var sortAscendingValues: [String: Bool] = [:]
    @State private var multiIncludedValues: [String: Set<String>] = [:]
    @State private var debounceTask: Task<Void, Never>?

    private let columns = [GridItem(.adaptive(minimum: 116), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                KanzenModuleSearchBar(
                    text: $searchText,
                    placeholder: "Search \(source.name)",
                    onSearch: performSearch
                )
                .onChange(of: searchText) { _ in scheduleSearch() }

                filtersContent
                resultsContent
            }
            .padding(16)
        }
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .kanzenGradientBackground()
        .task {
            viewModel.loadFilters(source: source)
        }
        .onDisappear {
            debounceTask?.cancel()
            viewModel.cancel()
        }
    }

    @ViewBuilder
    private var filtersContent: some View {
        if viewModel.isLoadingFilters {
            HStack(spacing: 10) {
                EclipseLoadingIndicator()
                Text("Loading filters...")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        } else if viewModel.filters.isEmpty {
            Text("This source does not expose advanced filters.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(EclipseTheme.shared.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(viewModel.filters.indices, id: \.self) { index in
                    filterRow(viewModel.filters[index])
                }
            }
            .padding(14)
            .background(EclipseTheme.shared.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    @ViewBuilder
    private var resultsContent: some View {
        if viewModel.isSearching {
            HStack(spacing: 10) {
                EclipseLoadingIndicator()
                Text("Searching...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else if let errorMessage = viewModel.errorMessage {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else if viewModel.items.isEmpty {
            EmptyView()
        } else {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(viewModel.items) { item in
                    NavigationLink(destination: MangaSearchItemDestination(source: source, item: item)) {
                        MangaSearchPosterCard(item: item, width: 116)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func filterRow(_ filter: AidokuRunner.Filter) -> some View {
        switch filter.value {
        case let .text(placeholder):
            VStack(alignment: .leading, spacing: 6) {
                Text(filter.title ?? "Text")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                TextField(placeholder ?? "", text: binding(forTextFilter: filter.id))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
            }
            .onChange(of: textValues[filter.id] ?? "") { _ in scheduleSearch() }

        case let .check(name, canExclude, defaultValue):
            let defaultState = defaultValue.map { $0 ? 1 : 2 } ?? 0
            Button {
                cycleCheck(filterId: filter.id, canExclude: canExclude, defaultState: defaultState)
                scheduleSearch()
            } label: {
                HStack {
                    Image(systemName: checkIcon(for: checkValues[filter.id] ?? defaultState))
                        .frame(width: 24)
                    Text(name ?? filter.title ?? "Option")
                    Spacer()
                }
                .foregroundColor(.primary)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

        case let .select(selectFilter):
            Picker(filter.title ?? "Select", selection: binding(forSelectFilter: filter.id, defaultValue: selectFilter.resolvedDefaultValue)) {
                ForEach(Array(selectFilter.options.enumerated()), id: \.offset) { offset, option in
                    Text(option).tag(selectFilter.ids?[safe: offset] ?? option)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: selectValues[filter.id] ?? selectFilter.resolvedDefaultValue) { _ in scheduleSearch() }

        case let .sort(canAscend, options, defaultValue):
            VStack(alignment: .leading, spacing: 8) {
                Picker(filter.title ?? "Sort", selection: binding(forSortIndex: filter.id, defaultValue: defaultValue?.index ?? 0)) {
                    ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                        Text(option).tag(index)
                    }
                }
                .pickerStyle(.menu)

                if canAscend {
                    Toggle("Ascending", isOn: binding(forSortAscending: filter.id, defaultValue: defaultValue?.ascending ?? false))
                }
            }
            .onChange(of: sortIndexValues[filter.id] ?? Int(defaultValue?.index ?? 0)) { _ in scheduleSearch() }
            .onChange(of: sortAscendingValues[filter.id] ?? (defaultValue?.ascending ?? false)) { _ in scheduleSearch() }

        case let .multiselect(multiSelect):
            VStack(alignment: .leading, spacing: 10) {
                Text(filter.title ?? "Tags")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(Array(multiSelect.options.enumerated()), id: \.offset) { offset, option in
                        let value = multiSelect.ids?[safe: offset] ?? option
                        let defaultValues = Set(multiSelect.defaultIncluded ?? [])
                        let selected = (multiIncludedValues[filter.id] ?? defaultValues).contains(value)
                        Button {
                            toggleMulti(filterId: filter.id, value: value, defaultValues: defaultValues)
                            scheduleSearch()
                        } label: {
                            Text(option)
                                .font(.subheadline)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .foregroundColor(.primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity)
                                .background(selected ? Color.primary.opacity(0.18) : Color.black.opacity(0.35))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(selected ? Color.primary.opacity(0.35) : Color.clear, lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

        case let .note(text):
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .range:
            HStack {
                Text(filter.title ?? "Range")
                Spacer()
                Text("Unsupported")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .opacity(0.55)
        }
    }

    private func performSearch() {
        viewModel.search(source: source, query: searchText, filters: enabledFilters())
    }

    private func scheduleSearch() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                performSearch()
            }
        }
    }

    private func enabledFilters() -> [AidokuRunner.FilterValue] {
        var values: [AidokuRunner.FilterValue] = []

        for (id, value) in textValues where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            values.append(.text(id: id, value: value))
        }
        for filter in viewModel.filters {
            switch filter.value {
            case let .check(_, _, defaultValue):
                let defaultState = defaultValue.map { $0 ? 1 : 2 } ?? 0
                let value = checkValues[filter.id] ?? defaultState
                if value != defaultState {
                    values.append(.check(id: filter.id, value: value))
                }
            case let .select(selectFilter):
                let selected = selectValues[filter.id] ?? selectFilter.resolvedDefaultValue
                if selected != selectFilter.resolvedDefaultValue {
                    values.append(.select(id: filter.id, value: selected))
                }
            case let .sort(_, _, defaultValue):
                let selectedIndex = sortIndexValues[filter.id] ?? Int(defaultValue?.index ?? 0)
                let ascending = sortAscendingValues[filter.id] ?? (defaultValue?.ascending ?? false)
                if selectedIndex != Int(defaultValue?.index ?? 0) || ascending != (defaultValue?.ascending ?? false) {
                    values.append(.sort(.init(id: filter.id, index: selectedIndex, ascending: ascending)))
                }
            case let .multiselect(multiSelect):
                let defaultIncluded = multiSelect.defaultIncluded ?? []
                let defaultExcluded = multiSelect.defaultExcluded ?? []
                let included = Array(multiIncludedValues[filter.id] ?? Set(defaultIncluded)).sorted()
                let excluded = defaultExcluded.sorted()
                if included != defaultIncluded || excluded != defaultExcluded {
                    values.append(.multiselect(id: filter.id, included: included, excluded: excluded))
                }
            default:
                break
            }
        }

        return values
    }

    private func binding(forTextFilter id: String) -> Binding<String> {
        Binding(
            get: { textValues[id] ?? "" },
            set: { textValues[id] = $0 }
        )
    }

    private func binding(forSelectFilter id: String, defaultValue: String) -> Binding<String> {
        Binding(
            get: { selectValues[id] ?? defaultValue },
            set: { selectValues[id] = $0 }
        )
    }

    private func binding(forSortIndex id: String, defaultValue: Int) -> Binding<Int> {
        Binding(
            get: { sortIndexValues[id] ?? defaultValue },
            set: { sortIndexValues[id] = $0 }
        )
    }

    private func binding(forSortAscending id: String, defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: { sortAscendingValues[id] ?? defaultValue },
            set: { sortAscendingValues[id] = $0 }
        )
    }

    private func cycleCheck(filterId: String, canExclude: Bool, defaultState: Int) {
        let current = checkValues[filterId] ?? defaultState
        switch current {
        case 0:
            checkValues[filterId] = 1
        case 1:
            checkValues[filterId] = canExclude ? 2 : 0
        default:
            checkValues[filterId] = 0
        }
    }

    private func checkIcon(for state: Int) -> String {
        switch state {
        case 1:
            return "checkmark.square.fill"
        case 2:
            return "xmark.square.fill"
        default:
            return "square"
        }
    }

    private func toggleMulti(filterId: String, value: String, defaultValues: Set<String>) {
        var values = multiIncludedValues[filterId] ?? defaultValues
        if values.contains(value) {
            values.remove(value)
        } else {
            values.insert(value)
        }
        multiIncludedValues[filterId] = values
    }
}

private struct KanzenModuleSearchBar: View {
    @Binding var text: String
    let placeholder: String
    let onSearch: () -> Void

    var body: some View {
        let experimental = ExperimentalFeatureState.isEnabledAtLaunch
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundColor(experimental ? .white.opacity(0.72) : .secondary)

            TextField(placeholder, text: $text, onCommit: onSearch)
                .font(.title2)
                .autocapitalization(.none)
                .disableAutocorrection(true)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(experimental ? .white.opacity(0.62) : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: experimental ? ExperimentalMediaDesignMetrics.current.cardRadius : 12, style: .continuous)
                .fill(experimental ? Color.white.opacity(0.12) : Color(.secondarySystemBackground).opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: experimental ? ExperimentalMediaDesignMetrics.current.cardRadius : 12, style: .continuous)
                .stroke(Color.white.opacity(experimental ? 0.14 : 0), lineWidth: 1)
        )
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension AidokuRunner.SelectFilter {
    var resolvedDefaultValue: String {
        defaultValue ?? ids?.first ?? options.first ?? ""
    }
}
#endif
