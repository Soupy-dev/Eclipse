//
//  MangaDetailView.swift
//  Kanzen
//
//  Created by Eclipse on 2025.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

#if !os(tvOS)
struct MangaDetailView: View {
    let initialManga: AniListManga
    @EnvironmentObject var moduleManager: ModuleManager
    @StateObject private var sourceFinder = MangaSourceFinder()
    @ObservedObject private var libraryManager = MangaLibraryManager.shared
    @ObservedObject private var progressManager = MangaReadingProgressManager.shared
    @ObservedObject private var downloadManager = ReaderDownloadManager.shared
    @ObservedObject private var theme = EclipseTheme.shared
    @ObservedObject private var contentFilter = ReaderContentFilter.shared

    @State private var manga: AniListManga
    @State private var fetchedFullDetail = false

    @State private var detailsResolution: LegacyDetailsResolution = .pending

    @State private var detailsFailedAt: Date?

    private static let detailsRetryCooldown: TimeInterval = 3

    init(manga: AniListManga) {
        self.initialManga = manga
        _manga = State(initialValue: manga)
    }

    @State private var expandedDescription: Bool = false
    @State private var showAddToCollection: Bool = false
    @State private var shareItem: ReaderDetailShareItem?
    @State private var scrollOffset: CGFloat = 0
    @State private var headerAmbientColor: Color = .black

    @State private var selectedSource: SourceMatch?
    @State private var showReaderSourcePicker = false
    @State private var linkedReaderItem: MangaLibraryItem?
    @State private var chapterEngine = KanzenEngine()
    @State private var loadingChapters: Bool = false
    @State private var loadedChapters: [Chapters]?
    @State private var chapterSnapshot: LegacyReaderChapterSnapshot?
    @State private var chapterLoadGeneration = UUID()
    @State private var chapterLanguageIdx: Int = 0
    @State private var reverseChapters: Bool = false
    @State private var selectedChapterData: Chapter?
    @State private var chapterLoadError: String?
    @AppStorage(ReaderDetailElement.orderStorageKey) private var readerDetailElementOrder = ReaderDetailElement.defaultOrderRawValue
    @AppStorage(ReaderDetailElement.hiddenStorageKey) private var readerDetailHiddenElements = ""

    private let coverWidth: CGFloat = isIPad ? 150 * iPadScaleSmall : 150
    private var designMetrics: ExperimentalMediaDesignMetrics { .current }

    private var heroHeight: CGFloat {
        if ExperimentalFeatureState.isEnabledAtLaunch {
            let measuredHeight = designMetrics.detailHeroHeight(
                screenHeight: UIScreen.main.bounds.height,
                isIPad: isIPad
            )
            return isIPad ? min(measuredHeight, 600) : measuredHeight
        }
        let mediaStyleHeight: CGFloat = isIPad ? 680 : 550
        let rotationSafeLimit = max(isIPad ? 520 : 360, UIScreen.main.bounds.height * 0.78)
        return min(mediaStyleHeight, rotationSafeLimit)
    }

    private var readerAtmosphereColor: Color {
        let base = theme.scopedGradientColor(isReaderMode: true)
        return theme.scopedAtmosphereColor(dominant: base, isReaderMode: true)
    }

    private var readerHeroBlendColor: Color {
        theme.heroBlendColor(dominant: headerAmbientColor, isReaderMode: true)
    }

    private var readerBleedColor: Color? {
        EclipseTheme.usableDominant(headerAmbientColor)
    }

    @ViewBuilder
    private var readerDetailBackground: some View {
        if ExperimentalFeatureState.isEnabledAtLaunch {
            AtmosphereBackdrop(
                input: theme.atmosphereInput(
                    dominant: readerHeroBlendColor,
                    hasHeroBleed: false,
                    heroHeight: heroHeight,
                    fadeDistance: heroHeight * 0.62,
                    isReaderMode: true
                ),
                scrollOffset: scrollOffset
            )
        } else {
            GlobalGradientBackground(scrollOffset: scrollOffset, allowsAnimatedBackground: false)
        }
    }

    private var libraryItem: MangaLibraryItem {
        if let selectedSource {
            return MangaLibraryItem.fromModule(
                moduleId: selectedSource.module.id,
                contentId: selectedSource.manga.mangaId,
                title: selectedSource.manga.title.isEmpty ? manga.displayTitle : selectedSource.manga.title,
                coverURL: selectedSource.manga.imageURL.isEmpty ? manga.coverURL : selectedSource.manga.imageURL,
                isNovel: selectedSource.module.moduleData.novel == true,
                sourceName: selectedSource.module.moduleData.sourceName,
                latestChapterNumbers: currentChapterNumbers,
                contentRating: derivedContentRating
            )
        }

        return MangaLibraryItem(
            aniListId: manga.id,
            title: manga.displayTitle,
            coverURL: manga.coverURL,
            format: manga.format,
            totalChapters: manga.chapters,
            latestChapterNumbers: currentChapterNumbers,
            contentRating: derivedContentRating
        )
    }

    private var derivedContentRating: Int? {
        contentFilter.derivedLegacyRating(
            tags: manga.genres,
            description: manga.description
        )
    }

    private var selectedChapterSnapshot: LegacyReaderChapterSnapshot.Group? {
        chapterSnapshot?.group(at: chapterLanguageIdx)
    }

    private var currentChapterNumbers: [String]? {
        chapterSnapshot?.latestChapterNumbers
    }

    private var selectedContentRoute: MangaContentRoute? {
        guard let selectedSource else { return nil }
        return .legacyModule(
            moduleUUID: selectedSource.module.id.uuidString,
            contentParams: selectedSource.manga.mangaId,
            isNovel: selectedSource.module.moduleData.novel == true
        )
    }

    private var progressMangaId: Int {
        libraryItem.aniListId
    }

    private var readerRatingId: Int {
        let key = selectedContentRoute?.stableKey ?? "anilist:\(manga.id)"
        let hash = key.utf8.reduce(into: 5381) { h, c in h = ((h &<< 5) &+ h) &+ Int(c) }
        return hash < 0 ? hash : -hash - 1
    }

    private var visibleReaderDetailElements: [ReaderDetailElement] {
        ReaderDetailElement.orderedElements(from: readerDetailElementOrder)
            .filter { ReaderDetailElement.isVisible($0, hiddenRawValue: readerDetailHiddenElements) }
            .filter(readerDetailElementHasContent)
    }

    private var knownTrackerAniListId: Int? {
        selectedSource == nil ? nil : manga.id
    }

    private func chapterNumbers(from groups: [Chapters]?) -> [String]? {
        let numbers = groups?
            .max(by: { $0.chapters.count < $1.chapters.count })?
            .chapters
            .map(\.chapterNumber)
        return numbers.map(ChapterIdentityNormalizer.deduplicatedNumbers)
    }

    private var selectedSourceIsNovel: Bool {
        selectedSource?.module.moduleData.novel == true
    }

    private var selectedSourceFormat: String? {
        selectedSourceIsNovel ? "NOVEL" : manga.format
    }

    private var selectedSourceChapterTotal: Int? {
        currentChapterNumbers?.count ?? manga.chapters
    }

    private var selectedSourceModuleUUID: String? {
        selectedSource?.module.id.uuidString
    }

    private var selectedSourceContentParams: String? {
        selectedSource?.manga.mangaId
    }

    private var selectedSourceDisplayTitle: String {
        guard let selectedSource, !selectedSource.manga.title.isEmpty else { return manga.displayTitle }
        return selectedSource.manga.title
    }

    private var selectedSourceCoverURL: String? {
        guard let selectedSource, !selectedSource.manga.imageURL.isEmpty else { return nil }
        return selectedSource.manga.imageURL
    }

    private var isRestrictedForActiveProfile: Bool {
        guard contentFilter.isKidsProfileActive else { return false }
        guard detailsResolution == .resolved else { return true }
        return !contentFilter.allowsLegacy(
            title: manga.displayTitle,
            tags: manga.genres,
            description: manga.description
        )
    }

    var body: some View {
        Group {
            if let linkedReaderItem,
               case .readerExtension(let sourceID, let itemKey, let legacyStableKey) = linkedReaderItem.route {
                ReaderExtensionMangaRouteLoaderView(
                    sourceID: sourceID, itemKey: itemKey, legacyStableKey: legacyStableKey,
                    title: linkedReaderItem.title, coverURL: linkedReaderItem.coverURL,
                    mangaID: linkedReaderItem.id
                )
            } else if isRestrictedForActiveProfile {
                if detailsResolution == .pending {
                    resolvingView
                } else {
                    restrictedView
                }
            } else {
                detailBody
            }
        }

        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in
            showReaderSourcePicker = false
            linkedReaderItem = nil
            selectedChapterData = nil
            chapterLoadGeneration = UUID()
            if loadingChapters, let selectedSource {
                selectSource(selectedSource)
            }
        }
        .task {
            await resolveDetailsIfNeeded()
            await retryDetailsIfStale()
        }
    }

    private func resolveDetailsIfNeeded() async {
        guard detailsResolution == .pending else { return }
        guard manga.description == nil, !fetchedFullDetail else {
            detailsResolution = .resolved
            return
        }
        fetchedFullDetail = true
        guard let full = try? await AniListMangaService.shared.fetchMangaDetail(id: manga.id) else {
            detailsResolution = .failed
            detailsFailedAt = Date()
            return
        }
        manga = full
        detailsResolution = .resolved
        detailsFailedAt = nil
    }

    private func retryDetailsIfStale() async {
        guard detailsResolution == .failed,
              let failedAt = detailsFailedAt,
              Date().timeIntervalSince(failedAt) >= Self.detailsRetryCooldown else { return }
        await retryDetailResolution()
    }

    private func retryDetailResolution() async {

        fetchedFullDetail = false
        detailsFailedAt = nil
        detailsResolution = .pending
        await resolveDetailsIfNeeded()
    }

    private var resolvingView: some View {
        EclipseLoadingIndicator("Checking this title...")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(readerDetailBackground.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
    }

    private var restrictedView: some View {
        let couldNotCheck = detailsResolution == .failed
        let heading: LocalizedStringKey = couldNotCheck
            ? "Couldn't check this title"
            : "Not available on this profile"
        let message: LocalizedStringKey = couldNotCheck
            ? "The details needed to check this title didn't load, so it stays hidden for now."
            : "This title is restricted for the profile you're using."
        return VStack(spacing: 12) {
            Image(systemName: couldNotCheck ? "exclamationmark.triangle.fill" : "lock.fill")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.7))
            Text(heading)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if couldNotCheck {
                Button("Try Again") {
                    Task { await retryDetailResolution() }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(readerDetailBackground.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var detailBody: some View {
        let experimental = ExperimentalFeatureState.isEnabledAtLaunch
        ScrollView {
            VStack(alignment: .leading, spacing: experimental ? designMetrics.sectionSpacing : 18) {
                headerSection
                primaryActionSection
                    .frame(maxWidth: isIPad ? 880 : .infinity)
                    .padding(.horizontal, isIPad ? 32 : 16)
                    .frame(maxWidth: .infinity)

                ForEach(visibleReaderDetailElements) { element in
                    readerDetailElementView(element)
                        .frame(maxWidth: isIPad ? 880 : .infinity)
                        .padding(.horizontal, isIPad ? 32 : 16)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, experimental ? 40 : 24)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ScrollOffsetPreferenceKey.self,
                        value: -geo.frame(in: .named("mangaDetailScroll")).origin.y
                    )
                }
            )
            .heroBannerBleed(
                color: experimental ? readerBleedColor : nil,
                heroHeight: heroHeight,
                tail: heroHeight * 0.62,
                strength: theme.scopedBleedStrength(isReaderMode: true)
            )
        }
        .coordinateSpace(name: "mangaDetailScroll")
        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { scrollOffset = $0 }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .ignoresSafeArea(edges: .top)
        .background(readerDetailBackground.ignoresSafeArea())
        .preferredColorScheme(isIPad ? .dark : nil)
        .sheet(isPresented: $showAddToCollection) {
            MangaAddToCollectionView(item: libraryItem)
                .environmentObject(libraryManager)
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: item.items)
        }
        .sheet(isPresented: $showReaderSourcePicker) {
            MangaReaderSourcePicker(item: MangaLibraryItem(
                aniListId: manga.id,
                title: manga.displayTitle,
                coverURL: manga.coverURL,
                format: manga.format,
                totalChapters: manga.chapters
            )) { linked in
                linkedReaderItem = linked
                showReaderSourcePicker = false
            }
        }

        .fullScreenCover(item: $selectedChapterData) { chapter in
            if let group = selectedChapterSnapshot {
                let readerChapterList = group.readerChapters
                let selectedReaderChapter = readerChapterList.first {
                    $0.chapterNumber == chapter.chapterNumber
                } ?? readerChapterList.first ?? chapter
                readerManagerView(
                    chapters: readerChapterList,
                    selectedChapter: selectedReaderChapter,
                    kanzen: chapterEngine,
                    mangaId: progressMangaId,
                    mangaTitle: selectedSourceDisplayTitle,
                    mangaCoverURL: selectedSourceCoverURL ?? "",
                    mangaRoute: selectedContentRoute,
                    mangaFormat: selectedSourceFormat,
                    totalChapters: selectedSourceChapterTotal,
                    latestChapterNumbers: currentChapterNumbers,
                    trackerAniListId: knownTrackerAniListId
                )
            }
        }
        .task {

            guard !moduleManager.modules.isEmpty else { return }

            guard sourceFinder.matches.isEmpty, !sourceFinder.isSearching, !sourceFinder.hasFinished else { return }
            sourceFinder.searchAllModules(for: manga)
        }
    }

    @ViewBuilder
    private var headerSection: some View {
        GeometryReader { geometry in
            let minY = geometry.frame(in: .global).minY
            let stretchedHeight = heroHeight + max(0, minY)
            let yOffset = min(0, -minY)
            let viewportWidth = geometry.size.width
            let coverURLString = selectedSourceCoverURL ?? manga.coverURL ?? ""
            let experimental = ExperimentalFeatureState.isEnabledAtLaunch
            let contentAlignment: Alignment = experimental ? .bottom : .bottomLeading
            let textAlignment: HorizontalAlignment = experimental ? .center : .leading
            let posterWidth = experimental ? min(viewportWidth * 0.84, heroHeight * 0.66) : max(viewportWidth - 20, 0)
            let posterHeight = experimental ? max(heroHeight * 0.74, 270) : max(heroHeight - 26, 260)
            let titleSize: CGFloat = experimental ? (isIPad ? 42 : 40) : (isIPad ? 40 : 32)
            let gradientColors: [Color] = experimental ? [
                Color.black.opacity(0.10),
                readerHeroBlendColor.opacity(0.36),
                readerHeroBlendColor.opacity(0.78),
                readerHeroBlendColor.opacity(1.0)
            ] : [
                Color.black.opacity(0.02),
                Color.black.opacity(0.28),
                Color.black.opacity(0.98)
            ]

            ZStack(alignment: contentAlignment) {
                if isIPad && experimental {
                    readerHeroBlendColor.opacity(0.58)
                }

                ReaderPinnedRemoteImage(
                    url: URL(string: coverURLString),
                    onImage: { image in
                        headerAmbientColor = Color.ambientColor(from: image)
                    }
                ) {
                    Color.black.opacity(0.18)
                }
                    .aspectRatio(contentMode: isIPad && experimental ? .fit : .fill)
                    .frame(width: viewportWidth, height: stretchedHeight)
                    .clipped()
                    .blur(radius: experimental ? 0 : 18)
                    .overlay(Color.black.opacity(experimental ? 0.10 : 0.34))

                if !experimental {
                    ReaderPinnedRemoteImage(url: URL(string: coverURLString)) {
                        Color.clear
                    }
                        .scaledToFit()
                        .frame(width: posterWidth, height: posterHeight, alignment: .center)
                        .frame(width: viewportWidth, alignment: .center)
                        .padding(.top, 10)
                }

                LinearGradient(
                    colors: gradientColors,
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: viewportWidth, height: stretchedHeight)

                VStack(alignment: textAlignment, spacing: experimental ? 10 : 8) {
                    Text(selectedSourceDisplayTitle)
                        .font(.system(size: titleSize, weight: .bold))
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .lineLimit(3)
                        .minimumScaleFactor(0.72)
                        .multilineTextAlignment(experimental ? .center : .leading)
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = selectedSourceDisplayTitle
                            } label: {
                                Label("Copy Title", systemImage: "doc.on.doc")
                            }
                        }

                    HStack(spacing: 10) {
                        if let status = manga.status {
                            Text(statusLabel(status))
                        }

                        if let format = selectedSourceFormat ?? manga.format {
                            Text(formatLabel(format))
                        }

                        if let score = manga.averageScore {
                            Image(systemName: "star.fill")
                            Text("\(score)%")
                        }
                    }
                    .font(.system(size: experimental ? (isIPad ? 24 : 20) : 15, weight: experimental ? .semibold : .regular))
                    .foregroundColor(.white.opacity(0.82))
                    .multilineTextAlignment(experimental ? .center : .leading)
                }
                .frame(maxWidth: experimental ? .infinity : nil, alignment: experimental ? .center : .leading)
                .padding(.horizontal, experimental ? 30 : 16)
                .padding(.bottom, experimental ? 36 : 18)
            }
            .frame(width: viewportWidth, height: stretchedHeight)
            .offset(y: yOffset)
        }
        .frame(height: heroHeight)
    }

    @ViewBuilder
    private var primaryActionSection: some View {
        let chapters = selectedChapterGroupForReading()
        let experimental = ExperimentalFeatureState.isEnabledAtLaunch
        HStack(spacing: experimental ? 14 : 12) {
            if chapters.isEmpty {
                Button { showReaderSourcePicker = true } label: {
                    HStack {
                        Image(systemName: "book.fill")
                            .font(experimental ? .headline : .subheadline)
                        Text(selectedSource == nil ? "Choose Source" : "Read Now")
                            .font(experimental ? .headline : .subheadline)
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: experimental ? 54 : nil)
                    .padding(.vertical, experimental ? 0 : 12)
                    .foregroundColor(.white)
                    .background(
                        RoundedRectangle(cornerRadius: experimental ? designMetrics.cardRadius : 12, style: .continuous)
                            .fill(experimental ? Color.white.opacity(0.12) : Color.accentColor.opacity(0.45))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: experimental ? designMetrics.cardRadius : 12, style: .continuous)
                            .stroke(Color.white.opacity(experimental ? 0.12 : 0), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(selectedSource != nil || contentFilter.isKidsProfileActive)
                .accessibilityIdentifier("reader.chooseSource")
            } else {
                readButton(chapters: chapters)
            }

            Button {
                showAddToCollection = true
            } label: {
                Image(systemName: libraryManager.isBookmarked(libraryItem) ? "bookmark.fill" : "bookmark")
            }
            .readerDetailIconButton()
            .accessibilityLabel("Add to Collection")
            .accessibilityIdentifier("reader.addToCollection")

            Button {
                shareItem = ReaderDetailShareItem(
                    title: selectedSourceDisplayTitle,
                    sourceName: selectedSourceDisplayName,
                    sourceURLString: selectedSource?.manga.mangaId
                )
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .readerDetailIconButton()

            Button {
                if let selectedSource {
                    selectSource(selectedSource)
                } else {
                    sourceFinder.searchAllModules(for: manga)
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .readerDetailIconButton()
            .disabled(loadingChapters || sourceFinder.isSearching)
        }
    }

    private func selectedChapterGroupForReading() -> [Chapter] {
        guard let loadedChapters, !loadedChapters.isEmpty else { return [] }
        let index = min(max(chapterLanguageIdx, 0), loadedChapters.count - 1)
        return loadedChapters[index].chapters
    }

    private var selectedSourceDisplayName: String? {
        selectedSource?.module.moduleData.sourceName
    }

    @ViewBuilder
    private var statsGrid: some View {
        let stats = buildStats()
        if !stats.isEmpty {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ], alignment: .leading, spacing: 4) {
                ForEach(stats, id: \.label) { stat in
                    Label(stat.label, systemImage: stat.icon)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private struct StatItem {
        let label: String
        let icon: String
    }

    private func buildStats() -> [StatItem] {
        var items: [StatItem] = []
        if let ch = manga.chapters { items.append(StatItem(label: "\(ch) ch", icon: "book.pages")) }
        if let vol = manga.volumes { items.append(StatItem(label: "\(vol) vol", icon: "books.vertical")) }
        if let score = manga.averageScore { items.append(StatItem(label: "\(score)%", icon: "star.fill")) }
        if let year = manga.startYear { items.append(StatItem(label: "\(year)", icon: "calendar")) }
        return items
    }

    @ViewBuilder
    private func descriptionSection(_ text: String) -> some View {
        let cleaned = text
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        if ExperimentalFeatureState.isEnabledAtLaunch {
            VStack(alignment: isIPad ? .leading : .center, spacing: 8) {
                Text(cleaned)
                    .font(isIPad ? .title3 : .body)
                    .lineSpacing(4)
                    .foregroundColor(.white.opacity(0.86))
                    .multilineTextAlignment(isIPad ? .leading : .center)
                    .lineLimit(expandedDescription ? nil : 5)
                    .onTapGesture {
                        withAnimation { expandedDescription.toggle() }
                    }

                if !expandedDescription {
                    Text("More")
                        .font(.callout.weight(.semibold))
                        .foregroundColor(.white.opacity(0.68))
                        .onTapGesture {
                            withAnimation { expandedDescription.toggle() }
                        }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .applyLiquidGlassBackground(cornerRadius: designMetrics.cardRadius)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(cleaned)
                    .font(isIPad ? .title3 : .body)
                    .lineSpacing(3)
                    .foregroundColor(.primary.opacity(0.92))
                    .lineLimit(expandedDescription ? nil : 5)
                    .onTapGesture {
                        withAnimation { expandedDescription.toggle() }
                    }

                if !expandedDescription {
                    HStack {
                        Spacer()
                        Text("More")
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .onTapGesture {
                                withAnimation { expandedDescription.toggle() }
                            }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func genresSection(_ genres: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(genres, id: \.self) { genre in
                    genreTag(genre)
                }
            }
        }
    }

    @ViewBuilder
    private func genreTag(_ genre: String) -> some View {
        let experimental = ExperimentalFeatureState.isEnabledAtLaunch
        Text(genre)
            .font(.footnote.weight(experimental ? .semibold : .regular))
            .foregroundColor(experimental ? .white.opacity(0.9) : .primary)
            .padding(.horizontal, experimental ? 14 : 12)
            .padding(.vertical, experimental ? 7 : 5)
            .background(
                Capsule()
                    .fill(experimental ? Color.white.opacity(0.11) : Color.clear)
            )
            .overlay(
                Capsule()
                    .stroke(experimental ? Color.white.opacity(0.16) : Color.primary.opacity(0.55), lineWidth: 1)
            )
    }

    @ViewBuilder
    private func wrappedGenres(_ genres: [String]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 6)], spacing: 6) {
            ForEach(genres, id: \.self) { genre in
                genreTag(genre)
            }
        }
    }

    private func readerDetailElementHasContent(_ element: ReaderDetailElement) -> Bool {
        switch element {
        case .overview:
            return !(manga.description ?? "").isEmpty
        case .tags:
            return !(manga.genres ?? []).isEmpty
        case .ratingNotes, .chapters:
            return true
        }
    }

    @ViewBuilder
    private func readerDetailElementView(_ element: ReaderDetailElement) -> some View {
        switch element {
        case .overview:
            if let description = manga.description, !description.isEmpty {
                descriptionSection(description)
            }
        case .tags:
            if let genres = manga.genres, !genres.isEmpty {
                genresSection(genres)
            }
        case .ratingNotes:
            let progress = progressManager.progress(for: progressMangaId)
            ReaderRatingNotesView(
                itemId: readerRatingId,
                title: manga.displayTitle,
                progressItemId: progressMangaId,
                routeKey: selectedContentRoute?.stableKey,
                knownAniListId: manga.id,
                knownMALId: progress?.trackerMALId,
                totalChapters: selectedSourceChapterTotal,
                format: selectedSourceFormat
            )
        case .chapters:
            if selectedSource != nil {
                chaptersSection
            } else {
                sourcesSection
            }
        }
    }

    @ViewBuilder
    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sources")
                    .font(.headline)
                Spacer()
            }

            Button { showReaderSourcePicker = true } label: {
                Label("Choose Reader Source", systemImage: "magnifyingglass")
            }
            .disabled(contentFilter.isKidsProfileActive)

            if moduleManager.modules.isEmpty {
                Text("Find this title in an installed Reader Extension to attach it and start reading.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if sourceFinder.isSearching {
                HStack(spacing: 10) {
                    EclipseLoadingIndicator()
                    Text("Searching modules…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else if sourceFinder.matches.isEmpty && sourceFinder.hasFinished {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("No matching sources found")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                ForEach(sourceFinder.matches) { match in
                    Button { selectSource(match) } label: {
                        sourceMatchRow(match)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func sourceMatchRow(_ match: SourceMatch) -> some View {
        HStack(spacing: 12) {
            if let iconURL = URL(string: match.module.moduleData.iconURL) {
                ReaderPinnedRemoteImage(
                    url: iconURL,
                    maximumPixelSize: 256
                ) {
                    Image(systemName: "puzzlepiece.extension")
                        .resizable()
                }
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .cornerRadius(8)
            } else {
                Image(systemName: "puzzlepiece.extension")
                    .frame(width: 36, height: 36)
                    .foregroundColor(.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(match.manga.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(match.module.moduleData.sourceName)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("·  \(Int(match.titleScore * 100))% match")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var chaptersSection: some View {
        VStack(alignment: .leading, spacing: 10) {

            if let source = selectedSource {
                HStack {
                    if let iconURL = URL(string: source.module.moduleData.iconURL) {
                        ReaderPinnedRemoteImage(
                            url: iconURL,
                            maximumPixelSize: 192
                        ) {
                            Image(systemName: "puzzlepiece.extension")
                                .resizable()
                        }
                            .scaledToFit()
                            .frame(width: 24, height: 24)
                            .cornerRadius(6)
                    }
                    Text(source.module.moduleData.sourceName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("· \(Int(source.titleScore * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        withAnimation {
                            selectedSource = nil
                            loadedChapters = nil
                            chapterSnapshot = nil
                            chapterLoadGeneration = UUID()
                            chapterLoadError = nil
                            loadingChapters = false
                            chapterLanguageIdx = 0
                        }
                    } label: {
                        Text("Change")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }
                }
            }

            Divider()

            if loadingChapters {
                HStack(spacing: 10) {
                    EclipseLoadingIndicator()
                    Text("Loading chapters…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else if let error = chapterLoadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else if let chapters = loadedChapters, !chapters.isEmpty {
                chapterListView(chapters)
            } else if loadedChapters != nil {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("No chapters found from this source")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        }
    }

    @ViewBuilder
    private func chapterListView(_ allChapters: [Chapters]) -> some View {
        let group = selectedChapterSnapshot
        let selected = group?.original ?? Chapters(language: "", chapters: [])
        let displayed = reverseChapters ? (group?.reversed ?? []) : selected.chapters

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(selectedSourceDisplayName ?? "Source")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer()
                Text("\(selected.chapters.count) Chapters")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                if allChapters.count > 1 {
                    Menu {
                        ForEach(Array(allChapters.enumerated()), id: \.offset) { idx, lang in
                            Button(lang.language) { chapterLanguageIdx = idx }
                        }
                    } label: {
                        Image(systemName: "globe")
                            .foregroundColor(.accentColor)
                    }
                }

                if let selectedContentRoute {
                    Button {
                        downloadManager.enqueueChapters(
                            route: selectedContentRoute,
                            mangaId: progressMangaId,
                            title: selectedSourceDisplayTitle,
                            coverURL: selectedSourceCoverURL,
                            sourceName: selectedSource?.module.moduleData.sourceName,
                            format: selectedSourceFormat,
                            chapters: selected.chapters,
                            contentRating: derivedContentRating,
                            kanzen: chapterEngine
                        )
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .foregroundColor(.accentColor)
                    }
                    .accessibilityLabel("Download All")
                }

                Button {
                    reverseChapters.toggle()
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .foregroundColor(.accentColor)
                }
            }

            Divider().padding(.vertical, 4)

            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(displayed.enumerated()), id: \.element.id) { displayIndex, chapter in
                    let isRead = progressManager.isChapterRead(mangaId: progressMangaId, chapterNumber: chapter.chapterNumber)
                    let chapterTitle = chapter.chapterData?.first?.title ?? ""
                    let downloadStatus = downloadManager.status(for: selectedContentRoute, chapterNumber: chapter.chapterNumber)
                    let downloadProgress = downloadManager.progress(for: selectedContentRoute, chapterNumber: chapter.chapterNumber)

                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {

                        if !chapterTitle.isEmpty {
                            Text(chapter.chapterNumber)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(isRead ? .secondary : .primary)
                                .lineLimit(1)
                            Text(chapterTitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        } else {
                            Text(chapter.chapterNumber)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(isRead ? .secondary : .primary)
                                .lineLimit(1)
                        }

                        if let data = chapter.chapterData, let first = data.first, !first.scanlationGroup.isEmpty {
                            Text(first.scanlationGroup)
                                .font(.caption2)
                                .foregroundColor(.accentColor.opacity(0.8))
                                .lineLimit(1)
                        }

                        if !isRead, let progressLabel = progressManager.pageProgressLabel(mangaId: progressMangaId, chapterNumber: chapter.chapterNumber) {
                            Text(progressLabel)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        if downloadStatus == .downloading || downloadStatus == .queued || downloadStatus == .paused {
                            ProgressView(value: downloadProgress)
                                .tint(downloadStatus == .paused ? .gray : .accentColor)
                                .frame(maxWidth: 180)
                        }
                    }

                    Spacer(minLength: 8)

                    downloadBadge(for: downloadStatus)

                    if isRead {
                        Text("Read")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12))
                            .cornerRadius(4)
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .opacity(isRead ? 0.6 : 1.0)
                .onTapGesture {
                    selectedChapterData = chapter
                }
                .contextMenu {
                    if isRead {
                        Button {
                            progressManager.markChapterUnread(mangaId: progressMangaId, chapterNumber: chapter.chapterNumber)
                        } label: {
                            Label("Mark as Unread", systemImage: "eye.slash")
                        }
                    } else {
                        Button {
                            progressManager.markChapterRead(
                                mangaId: progressMangaId,
                                chapterNumber: chapter.chapterNumber,
                                mangaTitle: selectedSourceDisplayTitle,
                                coverURL: selectedSourceCoverURL,
                                format: selectedSourceFormat,
                                totalChapters: selectedSourceChapterTotal,
                                latestChapterNumbers: currentChapterNumbers,
                                moduleUUID: selectedSourceModuleUUID,
                                contentParams: selectedSourceContentParams,
                                isNovel: selectedSourceIsNovel,
                                route: selectedContentRoute,
                                trackerAniListId: knownTrackerAniListId
                            )
                        } label: {
                            Label("Mark as Read", systemImage: "eye")
                        }
                    }

                    Divider()

                    Button {
                        markVisibleChaptersRead(Array(displayed.prefix(displayIndex + 1)))
                    } label: {
                        Label("Mark Above as Read", systemImage: "arrow.up.circle")
                    }

                    Button {
                        markVisibleChaptersRead(Array(displayed.suffix(displayed.count - displayIndex)))
                    } label: {
                        Label("Mark Below as Read", systemImage: "arrow.down.circle")
                    }

                    Button {
                        let allNums = selected.chapters.map { $0.chapterNumber }
                        progressManager.markAllRead(
                            mangaId: progressMangaId,
                            chapterNumbers: allNums,
                            mangaTitle: selectedSourceDisplayTitle,
                            coverURL: selectedSourceCoverURL,
                            format: selectedSourceFormat,
                            totalChapters: selectedSourceChapterTotal,
                            latestChapterNumbers: currentChapterNumbers,
                            moduleUUID: selectedSourceModuleUUID,
                            contentParams: selectedSourceContentParams,
                            isNovel: selectedSourceIsNovel,
                            route: selectedContentRoute,
                            trackerAniListId: knownTrackerAniListId
                        )
                    } label: {
                        Label("Mark All as Read", systemImage: "checkmark.circle.fill")
                    }

                    Button(role: .destructive) {
                        progressManager.markAllUnread(mangaId: progressMangaId)
                    } label: {
                        Label("Mark All as Unread", systemImage: "xmark.circle")
                    }

                    Divider()

                    downloadContextMenu(for: chapter, status: downloadStatus)
                }
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func downloadBadge(for status: ReaderDownloadStatus) -> some View {
        switch status {
        case .completed:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
        case .downloading, .queued, .paused:
            Image(systemName: status == .paused ? "pause.circle" : "arrow.down.circle")
                .foregroundColor(.secondary)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func downloadContextMenu(for chapter: Chapter, status: ReaderDownloadStatus) -> some View {
        if let route = selectedContentRoute {
            switch status {
            case .completed:
                Button(role: .destructive) {
                    downloadManager.removeDownload(id: ReaderDownloadManager.downloadId(route: route, chapterNumber: chapter.chapterNumber))
                } label: {
                    Label("Remove Download", systemImage: "trash")
                }
            case .queued, .downloading, .paused:
                Button(role: .destructive) {
                    downloadManager.cancelDownload(id: ReaderDownloadManager.downloadId(route: route, chapterNumber: chapter.chapterNumber))
                } label: {
                    Label("Cancel Download", systemImage: "xmark.circle")
                }
            case .failed, .none:
                Button {
                    downloadManager.enqueueChapter(
                        route: route,
                        mangaId: progressMangaId,
                        title: selectedSourceDisplayTitle,
                        coverURL: selectedSourceCoverURL,
                        sourceName: selectedSource?.module.moduleData.sourceName,
                        format: selectedSourceFormat,
                        chapter: chapter,
                        contentRating: derivedContentRating,
                        kanzen: chapterEngine
                    )
                } label: {
                    Label(status == .failed ? "Retry Download" : "Download", systemImage: "arrow.down.circle")
                }
            }
        } else {
            Button { } label: {
                Label("Download unavailable", systemImage: "exclamationmark.triangle")
            }
            .disabled(true)
        }
    }

    private func markVisibleChaptersRead(_ chapters: [Chapter]) {
        progressManager.markAllRead(
            mangaId: progressMangaId,
            chapterNumbers: chapters.map(\.chapterNumber),
            mangaTitle: selectedSourceDisplayTitle,
            coverURL: selectedSourceCoverURL,
            format: selectedSourceFormat,
            totalChapters: selectedSourceChapterTotal,
            latestChapterNumbers: currentChapterNumbers,
            moduleUUID: selectedSourceModuleUUID,
            contentParams: selectedSourceContentParams,
            isNovel: selectedSourceIsNovel,
            route: selectedContentRoute,
            trackerAniListId: knownTrackerAniListId
        )
    }

    @ViewBuilder
    private func readButton(chapters: [Chapter]) -> some View {
        let lastRead = progressManager.lastReadChapter(for: progressMangaId)
        let readChapters = progressManager.readChapters(for: progressMangaId)
        let readKeys = progressManager.normalizedReadChapterKeys(for: progressMangaId)
        let hasProgress = lastRead != nil || !readChapters.isEmpty

        let targetChapter = selectedChapterSnapshot?.readingTarget(lastRead: lastRead, readKeys: readKeys)

        if let target = targetChapter {
            Button {
                selectedChapterData = target
            } label: {
                HStack {
                    Image(systemName: hasProgress ? "book.fill" : "play.fill")
                        .font(ExperimentalFeatureState.isEnabledAtLaunch ? .headline : .subheadline)
                    Text(hasProgress ? "Continue" : "Read Now")
                        .font(ExperimentalFeatureState.isEnabledAtLaunch ? .headline : .subheadline)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: ExperimentalFeatureState.isEnabledAtLaunch ? 54 : nil)
                .padding(.vertical, ExperimentalFeatureState.isEnabledAtLaunch ? 0 : 12)
                .foregroundColor(.white)
                .background(
                    RoundedRectangle(cornerRadius: ExperimentalFeatureState.isEnabledAtLaunch ? designMetrics.cardRadius : 12, style: .continuous)
                        .fill(ExperimentalFeatureState.isEnabledAtLaunch ? Color.white.opacity(0.18) : Color.accentColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ExperimentalFeatureState.isEnabledAtLaunch ? designMetrics.cardRadius : 12, style: .continuous)
                        .stroke(Color.white.opacity(ExperimentalFeatureState.isEnabledAtLaunch ? 0.18 : 0), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }



    private func selectSource(_ match: SourceMatch) {
        selectedSource = match
        let owner = ProfileManager.shared.activeProfileID
        let generation = UUID()
        chapterLoadGeneration = generation
        loadingChapters = true
        loadedChapters = nil
        chapterSnapshot = nil
        chapterLoadError = nil
        chapterLanguageIdx = 0

        Task { @MainActor in
            do {
                let engine = KanzenEngine()
                let script = try ModuleManager.shared.getModuleScript(module: match.module)
                try await engine.loadScript(script, module: match.module)
                guard chapterLoadGeneration == generation,
                      selectedSource?.module.id == match.module.id,
                      selectedSource?.manga.mangaId == match.manga.mangaId else { return }
                chapterEngine = engine

                guard let result = try await engine.extractChapters(params: match.manga.mangaId) else {
                    guard chapterLoadGeneration == generation else { return }
                    loadedChapters = []
                    chapterSnapshot = nil
                    loadingChapters = false
                    return
                }
                guard chapterLoadGeneration == generation else { return }
                let parsed = parsedLegacyChapters(result)
                let snapshot = await LegacyReaderChapterSnapshot.prepare(parsed)
                guard chapterLoadGeneration == generation else { return }
                chapterSnapshot = snapshot
                loadedChapters = parsed
                loadingChapters = false
                if !parsed.isEmpty, ProfileManager.shared.isStillActive(owner) {
                    let latestNumbers = chapterNumbers(from: parsed) ?? []
                    libraryManager.updateSavedItem(libraryItem)
                    progressManager.updateSourceMetadata(
                        mangaId: progressMangaId,
                        title: selectedSourceDisplayTitle,
                        coverURL: selectedSourceCoverURL,
                        format: selectedSourceFormat,
                        latestChapterNumbers: latestNumbers,
                        route: selectedContentRoute,
                        sourceRefreshError: nil
                    )
                }
            } catch {
                guard chapterLoadGeneration == generation,
                      selectedSource?.module.id == match.module.id,
                      selectedSource?.manga.mangaId == match.manga.mangaId else { return }
                loadingChapters = false
                chapterLoadError = "Failed to load module: \(error.localizedDescription)"
            }
        }
    }

    private func parsedLegacyChapters(_ result: Any) -> [Chapters] {
        var parsed: [Chapters] = []
        if let dictResult = result as? [String: Any] {
            for (key, value) in dictResult {
                var chapterList: [Chapter] = []
                if let chapters = value as? [Any?] {
                    for (idx, chapter) in chapters.enumerated() {
                        if let chapter = chapter as? [Any?],
                           chapter.count >= 2,
                           let name = chapter[0] as? String,
                           let rawData = chapter[1] as? [[String: Any]] {
                            let data = rawData.compactMap(ChapterData.init(dict:))
                            chapterList.append(
                                Chapter(chapterNumber: name, idx: idx, chapterData: data)
                            )
                        }
                    }
                }
                if !chapterList.isEmpty {
                    parsed.append(Chapters(language: key, chapters: chapterList))
                }
            }
        } else if let arrResult = result as? [[String: Any]] {
            var chapterList: [Chapter] = []
            for (idx, chapterDict) in arrResult.enumerated() {
                let name = (chapterDict["number"] as? Int).map(String.init)
                    ?? (chapterDict["title"] as? String)
                    ?? "Chapter \(idx + 1)"
                if let data = ChapterData(dict: chapterDict) {
                    chapterList.append(
                        Chapter(chapterNumber: name, idx: idx, chapterData: [data])
                    )
                }
            }
            if !chapterList.isEmpty {
                parsed.append(Chapters(language: "default", chapters: chapterList))
            }
        }
        return parsed.map {
            Chapters(
                language: $0.language,
                chapters: ChapterIdentityNormalizer.deduplicatedChapters(
                    $0.chapters,
                    reindex: true
                )
            )
        }
    }

    private func formatLabel(_ format: String) -> String {
        switch format {
        case "MANGA": return "Manga"
        case "ONE_SHOT": return "One Shot"
        case "NOVEL": return "Light Novel"
        default: return format.capitalized
        }
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "RELEASING": return "Publishing"
        case "FINISHED": return "Completed"
        case "NOT_YET_RELEASED": return "Upcoming"
        case "CANCELLED": return "Cancelled"
        case "HIATUS": return "Hiatus"
        default: return status.capitalized
        }
    }

    private func statusIcon(_ status: String) -> String {
        switch status {
        case "RELEASING": return "clock.arrow.circlepath"
        case "FINISHED": return "checkmark.circle"
        case "NOT_YET_RELEASED": return "calendar"
        case "CANCELLED": return "xmark.circle"
        case "HIATUS": return "pause.circle"
        default: return "questionmark.circle"
        }
    }
}

private struct MangaReaderSourcePicker: View {
    let item: MangaLibraryItem
    let didAttach: (MangaLibraryItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sources = ReaderExtensionManager.shared
    @StateObject private var search = MangaGlobalModuleSearchViewModel()
    @State private var query = ""
    @State private var snapshot: MangaReadingProgressManager.ImportSnapshot?
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text(item.title).font(.headline)
                    TextField("Search title", text: $query)
                        .onSubmit { search.searchAll(query) }
                    Button("Search") { search.searchAll(query) }
                        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundColor(.secondary) }
                }
                if search.sources.isEmpty {
                    Section {
                        Text("Enable or install a compatible Reader Extension to attach this title.")
                        NavigationLink("Manage Reader Sources") { ReaderExtensionsSettingsView() }
                    }
                } else {
                    if search.isSearching {
                        HStack { ProgressView(); Text("Searching reader sources…") }
                    } else if search.hasSearched && search.sections.allSatisfy({ $0.items.isEmpty }) {
                        Text("No matches found. Try another title or enable a different source.")
                    }
                    ForEach(search.sections) { section in
                        Section(header: Text(section.source.name)) {
                            ForEach(section.items.filter { !$0.isContainer }) { result in
                                Button { attach(result, source: section.source) } label: {
                                    HStack(spacing: 12) {
                                        ReaderPinnedRemoteImage(url: URL(string: result.imageURL)) {
                                            Color.secondary.opacity(0.15)
                                        }
                                        .scaledToFit()
                                        .frame(width: 44, height: 64)
                                        Text(result.title).foregroundColor(.primary)
                                        Spacer()
                                        Image(systemName: "link")
                                    }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    if !search.failedSourceNames.isEmpty {
                        Section {
                            Text("Some sources could not be searched: \(search.failedSourceNames.joined(separator: ", ")). Try again or choose another source.")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Choose Reader Source")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .preferredColorScheme(.dark)
        .onAppear {
            if snapshot == nil {
                snapshot = try? MangaReadingProgressManager.shared.captureImport(
                    owner: ProfileManager.shared.activeProfileID, invalidation: nil
                )
                query = item.title
            }
            refreshSources()
        }
        .onChange(of: sources.installedSources) { _ in refreshSources() }
        .onChange(of: sources.showMatureSources) { _ in refreshSources() }
        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in
            snapshot = nil
            search.cancelSearch(keepResults: false)
            dismiss()
        }
        .onDisappear { search.cancelSearch(keepResults: true) }
    }

    private func refreshSources() {
        search.cancelSearch(keepResults: false)
        guard !ProfileManager.shared.isKidsModeActive else { return }
        search.refreshSources(from: ModuleManager.shared.modules, readerExtensionManager: sources)
        if let format = item.format {
            let isNovel = ["NOVEL", "LIGHT_NOVEL"].contains(format.uppercased())
            search.sources = search.sources.filter { ($0.readerExtensionSource?.mediaType == .novel) == isNovel }
        }
        search.searchAll(query)
    }

    private func attach(_ result: MangaHomeItem, source: MangaHomeSource) {
        guard !ProfileManager.shared.isKidsModeActive,
              let snapshot, let installed = source.readerExtensionSource,
              installed.enabled, sources.source(for: installed.id) == installed,
              let seed = result.readerExtensionItem,
              ReaderContentFilter.shared.allows(seed) else { return }
        let candidate = MangaLibraryItem.fromReaderExtension(
            sourceID: installed.id, itemKey: seed.key, title: seed.title,
            coverURL: ReaderExtensionSafeMetadata.sanitizedURLString(seed.coverURL),
            sourceName: installed.name, format: installed.mediaType == .novel ? "NOVEL" : "MANGA",
            contentRating: ReaderContentFilter.shared.derivedReaderExtensionRating(for: seed)
        )
        let saved = MangaLibraryManager.shared.collections.flatMap(\.items).first { $0.id == item.id } ?? item
        let linked = saved.attachingReaderSource(candidate)
        do {
            try MangaReadingProgressManager.shared.attachReaderSource(linked, snapshot: snapshot)
            MangaLibraryManager.shared.updateSavedItem(linked)
            didAttach(linked)
        } catch {
            errorMessage = "This library changed while choosing a source. Close this sheet and try again."
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
#endif
