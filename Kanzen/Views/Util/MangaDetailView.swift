import SwiftUI
import Kingfisher
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

    /// Full manga detail fetched from AniList (populated on appear if initial data is sparse)
    @State private var manga: AniListManga
    @State private var fetchedFullDetail = false

    init(manga: AniListManga) {
        self.initialManga = manga
        _manga = State(initialValue: manga)
    }

    // UI state
    @State private var expandedDescription: Bool = false
    @State private var showAddToCollection: Bool = false
    @State private var shareItem: ReaderDetailShareItem?
    @State private var scrollOffset: CGFloat = 0
    @State private var headerAmbientColor: Color = .black

    // Source / chapter state
    @State private var selectedSource: SourceMatch?
    @State private var chapterEngine = KanzenEngine()
    @State private var loadingChapters: Bool = false
    @State private var loadedChapters: [Chapters]?
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

    /// Banner blend color from the cover's extracted dominant (falling back to
    /// the backdrop tone for a dark/absent cover) - same behavior as a media hero.
    private var readerHeroBlendColor: Color {
        theme.heroBlendColor(dominant: headerAmbientColor, isReaderMode: true)
    }

    /// Cover dominant for the scroll-attached bleed; nil for a near-black cover
    /// so the app gradient stays clean.
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
                latestChapterNumbers: currentChapterNumbers
            )
        }

        return MangaLibraryItem(
            aniListId: manga.id,
            title: manga.displayTitle,
            coverURL: manga.coverURL,
            format: manga.format,
            totalChapters: manga.chapters,
            latestChapterNumbers: currentChapterNumbers
        )
    }

    private var currentChapterNumbers: [String]? {
        chapterNumbers(from: loadedChapters)
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

    var body: some View {
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
        .fullScreenCover(item: $selectedChapterData) { chapter in
            if let chapters = loadedChapters, chapterLanguageIdx < chapters.count {
                let chapterList = chapters[chapterLanguageIdx].chapters
                let readerChapterList = readerChapters(from: chapterList)
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
            // If opened from library (sparse data), fetch full detail from AniList
            if manga.description == nil, !fetchedFullDetail {
                fetchedFullDetail = true
                if let full = try? await AniListMangaService.shared.fetchMangaDetail(id: manga.id) {
                    manga = full
                }
            }
            guard !moduleManager.modules.isEmpty else { return }
            // Don't re-search if we already have results or are searching
            guard sourceFinder.matches.isEmpty, !sourceFinder.isSearching, !sourceFinder.hasFinished else { return }
            sourceFinder.searchAllModules(for: manga)
        }
    }

    // MARK: - Header

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

                // Modern: a sharp full-bleed cover banner whose extracted color
                // drives the gradient + bleed, exactly like a media hero. Legacy:
                // blurred fill behind a centered cover poster.
                KFImage(URL(string: coverURLString))
                    .placeholder { Color.black.opacity(0.18) }
                    .onSuccess { result in
                        headerAmbientColor = Color.ambientColor(from: result.image)
                    }
                    .resizable()
                    .aspectRatio(contentMode: isIPad && experimental ? .fit : .fill)
                    .frame(width: viewportWidth, height: stretchedHeight)
                    .clipped()
                    .blur(radius: experimental ? 0 : 18)
                    .overlay(Color.black.opacity(experimental ? 0.10 : 0.34))

                if !experimental {
                    KFImage(URL(string: coverURLString))
                        .placeholder { Color.clear }
                        .resizable()
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
                Button { } label: {
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
                    .foregroundColor(.white.opacity(experimental ? 0.56 : 0.6))
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
                .disabled(true)
            } else {
                readButton(chapters: chapters)
            }

            Button {
                showAddToCollection = true
            } label: {
                Image(systemName: libraryManager.isBookmarked(libraryItem) ? "bookmark.fill" : "bookmark")
            }
            .readerDetailIconButton()

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

    // MARK: - Description

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

    // MARK: - Genres

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

    // MARK: - Sources Section

    @ViewBuilder
    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sources")
                    .font(.headline)
                Spacer()
            }

            if moduleManager.modules.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("No modules installed. Add one from the Browse tab.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
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
                KFImage(iconURL)
                    .resizable()
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

    // MARK: - Chapters Section (inline after source selection)

    @ViewBuilder
    private var chaptersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Selected source header with change button
            if let source = selectedSource {
                HStack {
                    if let iconURL = URL(string: source.module.moduleData.iconURL) {
                        KFImage(iconURL)
                            .resizable()
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
        let selected = allChapters[chapterLanguageIdx]
        let displayed: [Chapter] = reverseChapters ? Array(selected.chapters.reversed()) : selected.chapters

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
                        // Chapter number + title
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

                        // Scanlation group
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

    // MARK: - Read / Continue Button

    @ViewBuilder
    private func readButton(chapters: [Chapter]) -> some View {
        let lastRead = progressManager.lastReadChapter(for: progressMangaId)
        let readChapters = progressManager.readChapters(for: progressMangaId)
        let readKeys = Set(readChapters.map { ChapterIdentityNormalizer.key(for: $0) })
        let hasProgress = lastRead != nil || !readChapters.isEmpty

        // Find the chapter to resume/start
        let targetChapter: Chapter? = {
            if let lastRead = lastRead {
                // Find the last-read chapter so we resume in it
                let lastReadKey = ChapterIdentityNormalizer.key(for: lastRead)
                if !readKeys.contains(lastReadKey),
                   let ch = chapters.first(where: {
                    $0.chapterNumber == lastRead ||
                    ChapterIdentityNormalizer.key(for: $0.chapterNumber) == lastReadKey
                }) {
                    return ch
                }
            }
            // No progress - start from first chapter
            if let unread = chronologicalChapters(chapters).first(where: {
                !readKeys.contains(ChapterIdentityNormalizer.key(for: $0.chapterNumber))
            }) {
                return unread
            }
            return chronologicalChapters(chapters).first
        }()

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

    private func chronologicalChapters(_ chapters: [Chapter]) -> [Chapter] {
        chapters.sorted { lhs, rhs in
            let lhsNumber = numericChapterValue(lhs.chapterNumber)
            let rhsNumber = numericChapterValue(rhs.chapterNumber)
            switch (lhsNumber, rhsNumber) {
            case let (lhsValue?, rhsValue?):
                if lhsValue != rhsValue { return lhsValue < rhsValue }
                return lhs.idx < rhs.idx
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.idx > rhs.idx
            }
        }
    }

    private func numericChapterValue(_ text: String) -> Double? {
        let pattern = #"(\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        guard let match = matches.last,
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[valueRange])
    }

    private func readerChapters(from chapters: [Chapter]) -> [Chapter] {
        ChapterIdentityNormalizer.deduplicatedChapters(chronologicalChapters(chapters), reindex: false).enumerated().map { index, chapter in
            Chapter(
                chapterNumber: chapter.chapterNumber,
                idx: index,
                chapterData: chapter.chapterData
            )
        }
    }

    // MARK: - Source Selection & Chapter Loading

    private func selectSource(_ match: SourceMatch) {
        selectedSource = match
        loadingChapters = true
        loadedChapters = nil
        chapterLoadError = nil
        chapterLanguageIdx = 0

        let engine = KanzenEngine()
        do {
            let script = try ModuleManager.shared.getModuleScript(module: match.module)
            let isNovel = match.module.moduleData.novel == true
            ReaderLogger.shared.log("MangaDetail.selectSource: loading module '\(match.module.moduleData.sourceName)', isNovel=\(isNovel)", type: "Debug")
            try engine.loadScript(script, isNovel: isNovel)
            ReaderLogger.shared.log("MangaDetail.selectSource: module loaded successfully", type: "Debug")
        } catch {
            loadingChapters = false
            chapterLoadError = "Failed to load module: \(error.localizedDescription)"
            return
        }

        // Store engine for the reader to use later
        chapterEngine = engine

        ReaderLogger.shared.log("MangaDetail.selectSource: calling extractChapters with mangaId='\(match.manga.mangaId)'", type: "Debug")
        engine.extractChapters(params: match.manga.mangaId) { result in
            DispatchQueue.main.async {
                ReaderLogger.shared.log("MangaDetail.selectSource: extractChapters returned type=\(type(of: result as Any)), isNil=\(result == nil)", type: "Debug")
                if let result = result {
                    var parsed: [Chapters] = []

                    if let dictResult = result as? [String: Any] {
                        ReaderLogger.shared.log("MangaDetail.selectSource: Kanzen format, keys=\(Array(dictResult.keys))", type: "Debug")
                        // Kanzen format: {language: [[chapterName, [{scanlation_group, id}]]]}
                        for (key, value) in dictResult {
                            var chapterList: [Chapter] = []
                            if let chapters = value as? [Any?] {
                                for (idx, chapter) in chapters.enumerated() {
                                    if let chapter = chapter as? [Any?],
                                       chapter.count >= 2,
                                       let name = chapter[0] as? String,
                                       let rawData = chapter[1] as? [[String: Any]],
                                       let data = rawData.compactMap({ ChapterData(dict: $0) }) as? [ChapterData] {
                                        chapterList.append(Chapter(chapterNumber: name, idx: idx, chapterData: data))
                                    }
                                }
                            }
                            if !chapterList.isEmpty {
                                parsed.append(Chapters(language: key, chapters: chapterList))
                            }
                        }
                    } else if let arrResult = result as? [[String: Any]] {
                        // Sora format: [{number, title, href}, ...]
                        ReaderLogger.shared.log("MangaDetail.selectSource: Sora format, \(arrResult.count) chapters", type: "Debug")
                        if let first = arrResult.first {
                            ReaderLogger.shared.log("MangaDetail.selectSource: first chapter keys=\(Array(first.keys)), values=\(first)", type: "Debug")
                        }
                        var chapterList: [Chapter] = []
                        for (idx, chapterDict) in arrResult.enumerated() {
                            let name = (chapterDict["number"] as? Int).map { String($0) }
                                ?? (chapterDict["title"] as? String)
                                ?? "Chapter \(idx + 1)"
                            if let data = ChapterData(dict: chapterDict) {
                                chapterList.append(Chapter(chapterNumber: name, idx: idx, chapterData: [data]))
                            }
                        }
                        if !chapterList.isEmpty {
                            parsed.append(Chapters(language: "default", chapters: chapterList))
                        }
                    }

                    parsed = parsed.map {
                        Chapters(
                            language: $0.language,
                            chapters: ChapterIdentityNormalizer.deduplicatedChapters($0.chapters, reindex: true)
                        )
                    }

                    ReaderLogger.shared.log("MangaDetail.selectSource: parsed \(parsed.count) language groups, total chapters=\(parsed.reduce(0) { $0 + $1.chapters.count })", type: "Debug")
                    self.loadedChapters = parsed
                    if !parsed.isEmpty {
                        let latestNumbers = self.chapterNumbers(from: parsed) ?? []
                        self.libraryManager.updateSavedItem(self.libraryItem)
                        self.progressManager.updateSourceMetadata(
                            mangaId: self.progressMangaId,
                            title: self.selectedSourceDisplayTitle,
                            coverURL: self.selectedSourceCoverURL,
                            format: self.selectedSourceFormat,
                            latestChapterNumbers: latestNumbers,
                            route: self.selectedContentRoute,
                            sourceRefreshError: nil
                        )
                    }
                } else {
                    ReaderLogger.shared.log("MangaDetail.selectSource: result is not dict or array, actual type=\(type(of: result))", type: "Error")
                    self.loadedChapters = []
                }
                self.loadingChapters = false
            }
        }
    }

    // MARK: - Helpers

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

// MARK: - Flow Layout

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
