//
//  KanzenHomeView.swift
//  Kanzen
//
//  Created by Eclipse on 2025.
//

import SwiftUI
import Kingfisher

#if !os(tvOS)
struct KanzenHomeView: View {
    private let onStartupReady: () -> Void

    @EnvironmentObject private var moduleManager: ModuleManager
    @StateObject private var homeViewModel = MangaHomeViewModel()
    @StateObject private var sourceManager = MangaHomeSourceManager.shared
    @StateObject private var readerExtensionManager = ReaderExtensionManager.shared
    @StateObject private var contentFilter = ReaderContentFilter.shared
    @StateObject private var customCatalogManager = KanzenCustomCatalogManager.shared
    @State private var scrollOffset: CGFloat = 0
    @State private var didReportStartupReady = false
    private var metrics: ExperimentalMediaDesignMetrics { .current }

    init(onStartupReady: @escaping () -> Void = {}) {
        self.onStartupReady = onStartupReady
    }

    var body: some View {
        NavigationView {
            Group {
                if contentFilter.isKidsProfileActive {
                    kidsRestrictedView
                } else {
                    VStack(spacing: 0) {
                        KanzenRootHeader("Discover")
                        sourceTabs
                        Divider()
                            .opacity(ExperimentalFeatureState.isEnabledAtLaunch || homeViewModel.sources.isEmpty ? 0 : 1)
                        content
                    }
                }
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
        .onReceive(readerExtensionManager.objectWillChange) { _ in
            DispatchQueue.main.async {
                syncSourcesAndLoad()
            }
        }
        .onReceive(customCatalogManager.$catalogs.dropFirst().removeDuplicates()) { _ in
            guard !ProfileManager.shared.isKidsModeActive else { return }
            homeViewModel.reloadForCatalogChange()
        }

        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in
            DispatchQueue.main.async {
                if ProfileManager.shared.isKidsModeActive {
                    restrictHomeForKidsProfile()
                    return
                }
                sourceManager.refreshSources(from: moduleManager.modules)
                let sources = sourceManager.enabledSources(
                    readerExtensionManager: readerExtensionManager,
                    modules: moduleManager.modules
                )

                homeViewModel.discardCachedSections()
                homeViewModel.updateSources(sources)
                homeViewModel.loadSelectedSource(force: true)
            }
        }
        .onChange(of: contentFilter.isKidsProfileActive) { isKids in
            if isKids {
                restrictHomeForKidsProfile()
            } else {
                syncSourcesAndLoad()
            }
        }
    }

    private var kidsRestrictedView: some View {
        VStack(spacing: 0) {
            KanzenRootHeader("Discover")
            VStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 42))
                    .foregroundColor(.secondary)
                Text("Reader Discovery Unavailable")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Text("Reader sources and discovery cannot be viewed from a kids profile. Switch to a grown-up profile to continue.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        if sourceManager.allSources(
            readerExtensionManager: readerExtensionManager,
            modules: moduleManager.modules
        ).isEmpty {
            emptyModulesView
        } else if homeViewModel.sources.isEmpty {
            disabledSourcesView
        } else if let source = homeViewModel.selectedSource {
            sourceContent(source)
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
                if source.isReaderExtension {
                    NavigationLink(destination: ReaderExtensionsSettingsView()) {
                        Label("Reader Source Settings", systemImage: "shield.lefthalf.filled")
                    }
                    .buttonStyle(.bordered)
                }
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
            Text("No Reader Extensions installed")
                .font(.headline)
                .foregroundColor(.secondary)
            NavigationLink(destination: ReaderExtensionsSettingsView()) {
                Label("Reader Extensions", systemImage: "plus.circle")
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

    private func syncSourcesAndLoad() {
        guard !ProfileManager.shared.isKidsModeActive else {
            restrictHomeForKidsProfile()
            return
        }
        sourceManager.refreshSources(from: moduleManager.modules)
        let sources = sourceManager.enabledSources(
            readerExtensionManager: readerExtensionManager,
            modules: moduleManager.modules
        )
        homeViewModel.updateSources(sources)
        homeViewModel.loadSelectedSource(force: false)
    }

    private func restrictHomeForKidsProfile() {
        homeViewModel.discardCachedSections()
        homeViewModel.updateSources([])
        scrollOffset = 0
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

    private var featuredWidth: CGFloat {
        if ExperimentalFeatureState.isEnabledAtLaunch {
            return metrics.posterCardSize(isIPad: isIPad).width * (isIPad ? 2.3 : 2.6)
        }
        return isIPad ? 320 * iPadScaleSmall : 292
    }

    private var visibleItemLimit: Int {
        section.displayStyle == .genres
            ? KanzenCatalogPresetResolver.maximumGenreIndexOptions
            : MangaHomeViewModel.maxVisibleItemsPerSection
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

            if section.items.isEmpty, let placeholderMessage = section.placeholderMessage {
                MangaHomeSectionPlaceholder(message: placeholderMessage)
                    .padding(.horizontal, isIPad ? 24 : 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: ExperimentalFeatureState.isEnabledAtLaunch ? (isIPad ? 22 : 18) : 12) {
                        ForEach(Array(section.items.prefix(visibleItemLimit))) { item in
                            NavigationLink(destination: MangaHomeItemDestination(source: source, section: section, item: item)) {
                                card(for: item)
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

    @ViewBuilder
    private func card(for item: MangaHomeItem) -> some View {
        if section.kind == .genres || item.isContainer {
            MangaHomeGenreCard(title: item.title)
        } else if section.displayStyle == .featured {
            MangaHomeFeaturedCard(item: item, width: featuredWidth)
        } else {
            MangaHomePosterCard(item: item, width: posterWidth)
        }
    }
}

private struct MangaHomeSectionPlaceholder: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "tray")
                .font(.headline)
                .foregroundColor(.white.opacity(0.5))
            Text(message)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.62))
                .multilineTextAlignment(.leading)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            ReaderScopedRemoteImage(
                url: URL(string: item.imageURL),
                readerExtensionSourceID: item.route?.readerExtensionSourceID,
                maximumPixelSize: isIPad ? 900 : 640
            ) {
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

private struct MangaHomeFeaturedCard: View {
    let item: MangaHomeItem
    let width: CGFloat
    private var metrics: ExperimentalMediaDesignMetrics { .current }
    private var radius: CGFloat {
        ExperimentalFeatureState.isEnabledAtLaunch ? metrics.cardRadius : 10
    }
    private var height: CGFloat { width * 0.62 }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ReaderScopedRemoteImage(
                url: URL(string: item.imageURL),
                readerExtensionSourceID: item.route?.readerExtensionSourceID,
                maximumPixelSize: isIPad ? 1_200 : 900
            ) {
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
            .scaledToFill()
            .frame(width: width, height: height)
            .clipped()

            LinearGradient(
                colors: [
                    Color.black.opacity(0),
                    Color.black.opacity(0.42),
                    Color.black.opacity(0.86)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: width, height: height)

            VStack(alignment: .leading, spacing: isIPad ? 12 : 10) {
                Text(item.title)
                    .font(ExperimentalFeatureState.isEnabledAtLaunch ? .system(size: isIPad ? 24 : 20, weight: .bold) : .title3)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .minimumScaleFactor(0.82)

                HStack(spacing: 6) {
                    Image(systemName: "book.fill")
                        .font(.system(size: isIPad ? 14 : 12, weight: .semibold))
                    Text("Read Now")
                        .font(.system(size: isIPad ? 17 : 15, weight: .semibold))
                }
                .foregroundColor(.black)
                .padding(.horizontal, isIPad ? 18 : 15)
                .padding(.vertical, isIPad ? 10 : 8)
                .background(Capsule().fill(Color.white.opacity(0.94)))
            }
            .padding(isIPad ? 20 : 15)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.white.opacity(ExperimentalFeatureState.isEnabledAtLaunch ? 0.08 : 0), lineWidth: 1)
        )
        .shadow(color: .black.opacity(ExperimentalFeatureState.isEnabledAtLaunch ? 0.28 : 0), radius: 14, x: 0, y: 8)
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
                    .foregroundColor(.white.opacity(0.78))
            }
            .padding(.horizontal, 16)
            .frame(width: isIPad ? 230 : 184, height: isIPad ? 112 : 92)
            .background(
                RoundedRectangle(cornerRadius: metrics.cardRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.32))
                    .overlay(
                        RoundedRectangle(cornerRadius: metrics.cardRadius, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.44), lineWidth: 1)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: metrics.cardRadius, style: .continuous))
            .contentShape(Rectangle())
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
                    readerExtensionQuery: item.readerExtensionQuery ?? section.readerExtensionQuery
                )
            )
        } else if let extensionItem = item.readerExtensionItem, let sourceID = source.sourceID {
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

private struct MangaHomeSectionDetailView: View {
    let source: MangaHomeSource
    let section: MangaHomeSection

    @State private var items: [MangaHomeItem]
    @State private var page = 0
    @State private var isLoading = false
    @State private var endOfPage = false
    @State private var errorMessage: String?

    private var columns: [GridItem] {
        guard section.displayStyle == .genres else {
            return [GridItem(.adaptive(minimum: 116), spacing: 12)]
        }
        if ExperimentalFeatureState.isEnabledAtLaunch {
            return [GridItem(.adaptive(minimum: isIPad ? 230 : 184), spacing: 12)]
        }
        return [GridItem(.adaptive(minimum: 132), spacing: 12)]
    }

    init(source: MangaHomeSource, section: MangaHomeSection) {
        self.source = source
        self.section = section
        _items = State(initialValue: section.items)
        // Home already seeds Reader Extension sections with provider page 1.
        // Continue at page 2 instead of requesting page 1 again under a
        // different presentation identity.
        _page = State(initialValue: section.items.isEmpty ? 0 : (source.isReaderExtension ? 2 : 1))
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

                let maximumFilteredPagesPerRequest = 3
                var pageToLoad = loadPage
                var collected: [MangaHomeItem] = []
                var sourceExhausted = false

                for _ in 0..<maximumFilteredPagesPerRequest {
                    let result = try await MangaHomeViewModel.loadSectionItems(
                        source: source,
                        section: section,
                        page: pageToLoad
                    )
                    pageToLoad += 1
                    collected.append(contentsOf: result.items)
                    if !result.sourceHasMore {
                        sourceExhausted = true
                        break
                    }
                    if !result.items.isEmpty { break }
                }

                let advancedTo = pageToLoad
                await MainActor.run {
                if collected.isEmpty && sourceExhausted {
                    self.endOfPage = true
                } else {
                    var existing = Set(self.items.map(\.id))
                    self.items.append(contentsOf: collected.filter { existing.insert($0.id).inserted })
                    self.page = advancedTo
                    self.endOfPage = sourceExhausted
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
