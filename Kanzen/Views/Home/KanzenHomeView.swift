import SwiftUI
import Kingfisher

#if !os(tvOS)
struct KanzenHomeView: View {
    private let onStartupReady: () -> Void

    @EnvironmentObject private var moduleManager: ModuleManager
    @StateObject private var homeViewModel = MangaHomeViewModel()
    @StateObject private var sourceManager = MangaHomeSourceManager.shared
    @StateObject private var aidokuManager = AidokuSourceManager.shared
    @State private var scrollOffset: CGFloat = 0
    @State private var didReportStartupReady = false
    private var metrics: ExperimentalMediaDesignMetrics { .current }

    init(onStartupReady: @escaping () -> Void = {}) {
        self.onStartupReady = onStartupReady
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                KanzenRootHeader("Discover")
                sourceTabs
                Divider()
                    .opacity(ExperimentalFeatureState.isEnabledAtLaunch || homeViewModel.sources.isEmpty ? 0 : 1)
                content
            }
            .background(GlobalGradientBackground(scrollOffset: scrollOffset).ignoresSafeArea())
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .task {
            syncSourcesAndLoad()
        }
        .onAppear {
            reportStartupReadyIfNeeded()
        }
        .onChange(of: moduleManager.modules) { _ in
            syncSourcesAndLoad()
        }
        .onReceive(sourceManager.objectWillChange) { _ in
            DispatchQueue.main.async {
                syncSourcesAndLoad()
            }
        }
        .onReceive(aidokuManager.objectWillChange) { _ in
            DispatchQueue.main.async {
                syncSourcesAndLoad()
            }
        }
    }

    @ViewBuilder
    private var sourceTabs: some View {
        if !homeViewModel.sources.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 28) {
                    ForEach(homeViewModel.sources) { source in
                        Button {
                            homeViewModel.selectSource(source)
                        } label: {
                            VStack(spacing: 8) {
                                Text(source.name)
                                    .font(ExperimentalFeatureState.isEnabledAtLaunch ? .system(size: 17, weight: .bold) : .headline)
                                    .fontWeight(source.id == homeViewModel.selectedSourceID ? .bold : .semibold)
                                    .foregroundColor(ExperimentalFeatureState.isEnabledAtLaunch ? .white.opacity(source.id == homeViewModel.selectedSourceID ? 0.96 : 0.62) : (source.id == homeViewModel.selectedSourceID ? .primary : .primary.opacity(0.72)))
                                    .lineLimit(1)

                                Capsule()
                                    .fill(source.id == homeViewModel.selectedSourceID ? (ExperimentalFeatureState.isEnabledAtLaunch ? Color.white.opacity(0.82) : Color.primary.opacity(0.82)) : Color.clear)
                                    .frame(height: 3)
                            }
                            .padding(.horizontal, ExperimentalFeatureState.isEnabledAtLaunch ? 4 : 0)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
            }
            .frame(height: ExperimentalFeatureState.isEnabledAtLaunch ? 62 : 58)
            .modifier(KanzenScrollClipModifier())
        }
    }

    @ViewBuilder
    private var content: some View {
        if sourceManager.allSources(aidokuManager: aidokuManager, modules: moduleManager.modules).isEmpty {
            emptyModulesView
        } else if homeViewModel.sources.isEmpty {
            disabledSourcesView
        } else if let source = homeViewModel.selectedSource {
            if source.isAidoku && !aidokuManager.isRuntimeReady {
                preparingSourceView(source)
            } else {
                sourceContent(source)
            }
        } else {
            EclipseLoadingIndicator()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func sourceContent(_ source: MangaHomeSource) -> some View {
        let state = homeViewModel.loadStates[source.id] ?? .idle
        let sections = homeViewModel.sectionsBySource[source.id] ?? []

        switch state {
        case .idle, .loading:
            VStack(spacing: 10) {
                EclipseLoadingIndicator()
                Text("Loading \(source.name)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                homeViewModel.loadHome(for: source)
            }

        case .unsupported:
            unsupportedSourceView(source)

        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    homeViewModel.loadHome(for: source, force: true)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded:
            if sections.isEmpty {
                unsupportedSourceView(source)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(sections) { section in
                            MangaHomeSectionView(source: source, section: section)
                        }
                    }
                    .padding(.top, ExperimentalFeatureState.isEnabledAtLaunch ? max(18, metrics.sectionSpacing * 0.55) : 18)
                    .padding(.bottom, 30)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ScrollOffsetPreferenceKey.self,
                                value: -geo.frame(in: .named("kanzenHomeScroll")).origin.y
                            )
                        }
                    )
                }
                .coordinateSpace(name: "kanzenHomeScroll")
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { scrollOffset = $0 }
                .refreshable {
                    homeViewModel.loadHome(for: source, force: true)
                }
            }
        }
    }

    private var emptyModulesView: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 42))
                .foregroundColor(.secondary)
            Text("No Aidoku home sources installed")
                .font(.headline)
                .foregroundColor(.secondary)
            NavigationLink(destination: AidokuSourcesSettingsView()) {
                Label("Aidoku Sources", systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var disabledSourcesView: some View {
        VStack(spacing: 12) {
            Image(systemName: "eye.slash")
                .font(.system(size: 42))
                .foregroundColor(.secondary)
            Text("No home sources enabled")
                .font(.headline)
                .foregroundColor(.secondary)
            NavigationLink(destination: MangaCatalogSettingsView().environmentObject(moduleManager)) {
                Label("Home Sources", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func unsupportedSourceView(_ source: MangaHomeSource) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.minus")
                .font(.system(size: 42))
                .foregroundColor(.secondary)
            Text("\(source.name) has no home feed")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Use Search Everything to search across all enabled sources.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func preparingSourceView(_ source: MangaHomeSource) -> some View {
        VStack(spacing: 10) {
            EclipseLoadingIndicator()
            Text("Preparing \(source.name)")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await aidokuManager.ensureRuntimeReady()
            await MainActor.run {
                syncSourcesAndLoad()
            }
        }
    }

    private func syncSourcesAndLoad() {
        sourceManager.refreshSources(from: moduleManager.modules)
        let sources = sourceManager.enabledSources(aidokuManager: aidokuManager, modules: moduleManager.modules)
        homeViewModel.updateSources(sources)
        if homeViewModel.selectedSource?.isAidoku == true, !aidokuManager.isRuntimeReady {
            Task {
                await aidokuManager.ensureRuntimeReady()
                await MainActor.run {
                    syncSourcesAndLoad()
                }
            }
            return
        }
        homeViewModel.loadSelectedSource(force: false)
    }

    private func reportStartupReadyIfNeeded() {
        guard !didReportStartupReady else { return }
        didReportStartupReady = true
        onStartupReady()
    }
}

private struct MangaHomeSectionView: View {
    let source: MangaHomeSource
    let section: MangaHomeSection

    private var metrics: ExperimentalMediaDesignMetrics { .current }

    private var posterWidth: CGFloat {
        if ExperimentalFeatureState.isEnabledAtLaunch {
            return metrics.posterCardSize(isIPad: isIPad).width
        }
        return isIPad ? 132 * iPadScaleSmall : 132
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ExperimentalFeatureState.isEnabledAtLaunch ? 16 : 12) {
            HStack(alignment: .center) {
                Text(section.title)
                    .font(ExperimentalFeatureState.isEnabledAtLaunch ? .system(size: isIPad ? 36 : 29, weight: .heavy) : .largeTitle)
                    .fontWeight(ExperimentalFeatureState.isEnabledAtLaunch ? .heavy : .regular)
                    .foregroundColor(ExperimentalFeatureState.isEnabledAtLaunch ? .white : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Spacer()

                NavigationLink(destination: MangaHomeSectionDetailView(source: source, section: section)) {
                    Image(systemName: ExperimentalFeatureState.isEnabledAtLaunch ? "chevron.right" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: ExperimentalFeatureState.isEnabledAtLaunch ? (isIPad ? 26 : 22) : 17, weight: .semibold))
                        .foregroundColor(ExperimentalFeatureState.isEnabledAtLaunch ? .white.opacity(0.46) : .white)
                        .frame(width: ExperimentalFeatureState.isEnabledAtLaunch ? 34 : 48, height: ExperimentalFeatureState.isEnabledAtLaunch ? 34 : 48)
                        .background(
                            Group {
                                if ExperimentalFeatureState.isEnabledAtLaunch {
                                    Color.clear
                                } else {
                                    Color.accentColor.opacity(0.34)
                                }
                            }
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, isIPad ? 24 : 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: ExperimentalFeatureState.isEnabledAtLaunch ? (isIPad ? 22 : 18) : 12) {
                    ForEach(Array(section.items.prefix(MangaHomeViewModel.maxVisibleItemsPerSection))) { item in
                        NavigationLink(destination: MangaHomeItemDestination(source: source, section: section, item: item)) {
                            if section.kind == .genres || item.isContainer {
                                MangaHomeGenreCard(title: item.title)
                            } else {
                                MangaHomePosterCard(item: item, width: posterWidth)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, isIPad ? 24 : 16)
            }
            .modifier(KanzenScrollClipModifier())
        }
    }
}

private struct MangaHomePosterCard: View {
    let item: MangaHomeItem
    let width: CGFloat
    private var metrics: ExperimentalMediaDesignMetrics { .current }
    private var radius: CGFloat {
        ExperimentalFeatureState.isEnabledAtLaunch ? metrics.cardRadius : 10
    }
    private var imageHeight: CGFloat {
        ExperimentalFeatureState.isEnabledAtLaunch ? width * 1.5 : width * 1.45
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ExperimentalFeatureState.isEnabledAtLaunch ? 8 : 4) {
            KFImage(URL(string: item.imageURL))
                .placeholder {
                    if ExperimentalFeatureState.isEnabledAtLaunch {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                            .overlay(
                                Image(systemName: "book.closed")
                                    .foregroundColor(.white.opacity(0.42))
                            )
                    } else {
                        Rectangle().fill(Color.gray.opacity(0.22))
                    }
                }
                .resizable()
                .setProcessor(DownsamplingImageProcessor(size: CGSize(width: width, height: imageHeight)))
                .scaledToFill()
                .frame(width: width, height: imageHeight)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(Color.white.opacity(ExperimentalFeatureState.isEnabledAtLaunch ? 0.08 : 0), lineWidth: 1)
                )
                .shadow(color: .black.opacity(ExperimentalFeatureState.isEnabledAtLaunch ? 0.28 : 0), radius: 14, x: 0, y: 8)

            Text(item.title)
                .font(ExperimentalFeatureState.isEnabledAtLaunch ? .system(size: isIPad ? 19 : 17, weight: .medium) : .headline)
                .lineLimit(1)
                .foregroundColor(ExperimentalFeatureState.isEnabledAtLaunch ? .white : .primary)
                .frame(width: width, alignment: .leading)

            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(ExperimentalFeatureState.isEnabledAtLaunch ? .system(size: isIPad ? 16 : 15) : .subheadline)
                    .foregroundColor(ExperimentalFeatureState.isEnabledAtLaunch ? .white.opacity(0.56) : .secondary)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
        }
    }
}

private struct MangaHomeGenreCard: View {
    let title: String
    private var metrics: ExperimentalMediaDesignMetrics { .current }

    var body: some View {
        if ExperimentalFeatureState.isEnabledAtLaunch {
            HStack {
                Text(title)
                    .font(.system(size: isIPad ? 22 : 19, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Spacer()

                Image(systemName: "arrow.right")
                    .font(.headline.weight(.semibold))
                    .foregroundColor(.white.opacity(0.64))
            }
            .padding(.horizontal, 16)
            .frame(width: isIPad ? 230 : 184, height: isIPad ? 112 : 92)
            .applyLiquidGlassBackground(cornerRadius: metrics.cardRadius)
        } else {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.82))

                Circle()
                    .fill(Color.white.opacity(0.94))
                    .frame(width: 92, height: 92)
                    .offset(x: 72, y: -54)

                Image(systemName: "arrow.right")
                    .font(.title.weight(.semibold))
                    .foregroundColor(.accentColor)
                    .offset(x: 118, y: -70)

                Text(title)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .padding(14)
            }
            .frame(width: 132, height: 86)
            .clipped()
        }
    }
}

private struct MangaHomeItemDestination: View {
    let source: MangaHomeSource
    let section: MangaHomeSection
    let item: MangaHomeItem

    var body: some View {
        if section.kind == .genres || item.isContainer {
            MangaHomeSectionDetailView(
                source: source,
                section: .section(
                    title: item.title,
                    id: "\(source.id):section:\(item.params)",
                    kind: .custom,
                    items: [],
                    aidokuListing: item.aidokuListing,
                    aidokuFilterValues: item.aidokuFilterValues
                )
            )
        } else if let manga = item.aidokuManga, let sourceId = source.sourceId {
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

private struct MangaHomeSectionDetailView: View {
    let source: MangaHomeSource
    let section: MangaHomeSection

    @State private var items: [MangaHomeItem]
    @State private var page = 0
    @State private var isLoading = false
    @State private var endOfPage = false
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 116), spacing: 12)]

    init(source: MangaHomeSource, section: MangaHomeSection) {
        self.source = source
        self.section = section
        _items = State(initialValue: section.items)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(items) { item in
                    NavigationLink(destination: MangaHomeItemDestination(source: source, section: section, item: item)) {
                        if item.isContainer {
                            MangaHomeGenreCard(title: item.title)
                        } else {
                            MangaHomePosterCard(item: item, width: 116)
                        }
                    }
                    .buttonStyle(.plain)
                }

                if isLoading {
                    EclipseLoadingIndicator()
                        .frame(width: 116, height: 40)
                        .padding(.vertical, 20)
                } else if !endOfPage {
                    Color.clear
                        .frame(height: 1)
                        .onAppear {
                            loadNextPage()
                        }
                }
            }
            .padding(16)
        }
        .overlay {
            if let errorMessage, items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        loadNextPage(reset: true)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else if endOfPage && items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No items found")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
            }
        }
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.inline)
        .kanzenGradientBackground()
        .task {
            if items.isEmpty {
                loadNextPage(reset: true)
            }
        }
    }

    private func loadNextPage(reset: Bool = false) {
        guard !isLoading else { return }
        if endOfPage && !reset { return }

        isLoading = true
        errorMessage = nil
        if reset {
            page = 0
            endOfPage = false
            items = []
        }

        let loadPage = page
        Task {
            do {
                let newItems = try await MangaHomeViewModel.loadSectionItems(source: source, section: section, page: loadPage)
                await MainActor.run {
                if newItems.isEmpty {
                    self.endOfPage = true
                } else {
                    let existing = Set(self.items.map(\.id))
                    self.items.append(contentsOf: newItems.filter { !existing.contains($0.id) })
                    self.page += 1
                }

                self.isLoading = false
            }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}

struct KanzenScrollClipModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.scrollClipDisabled()
        } else {
            content
        }
    }
}
#endif
