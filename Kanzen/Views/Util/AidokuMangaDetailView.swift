#if !os(tvOS)
import SwiftUI
import Kingfisher
import AidokuRunner
#if canImport(UIKit)
import UIKit
#endif

struct AidokuMangaRouteLoaderView: View {
    let sourceId: String
    let mangaKey: String
    let title: String
    let coverURL: String?

    @State private var manga: AidokuRunner.Manga?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @StateObject private var sourceManager = AidokuSourceManager.shared

    var body: some View {
        Group {
            if let manga {
                AidokuMangaDetailView(sourceId: sourceId, initialManga: manga)
            } else if let metadata = sourceManager.metadata(id: sourceId), !metadata.isEnabled {
                MangaSourceRepairView(
                    title: title,
                    message: "\(metadata.name) is disabled.",
                    actionTitle: "Enable Source"
                ) {
                    sourceManager.toggle(metadata)
                    Task { await load() }
                }
            } else if let errorMessage {
                MangaSourceRepairView(
                    title: title,
                    message: errorMessage,
                    actionTitle: "Aidoku Sources"
                )
            } else if isLoading {
                EclipseLoadingIndicator("Loading source...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task {
                        await load()
                    }
            }
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        errorMessage = nil

        guard sourceManager.metadata(id: sourceId) != nil else {
            errorMessage = "The Aidoku source for this manga is missing. Reinstall the source to repair this item."
            isLoading = false
            return
        }

        do {
            let seed = AidokuRunner.Manga(
                sourceKey: sourceId,
                key: mangaKey,
                title: title,
                cover: coverURL
            )
            manga = try await sourceManager.mangaUpdate(
                sourceId: sourceId,
                manga: seed,
                needsDetails: true,
                needsChapters: true
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

struct AidokuMangaDetailView: View {
    let sourceId: String
    let initialManga: AidokuRunner.Manga

    @ObservedObject private var libraryManager = MangaLibraryManager.shared
    @ObservedObject private var progressManager = MangaReadingProgressManager.shared
    @ObservedObject private var downloadManager = ReaderDownloadManager.shared
    @ObservedObject private var theme = EclipseTheme.shared
    @StateObject private var sourceManager = AidokuSourceManager.shared
    @StateObject private var kanzen = KanzenEngine()
    @State private var manga: AidokuRunner.Manga
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedChapterData: Chapter?
    @State private var showAddToCollection = false
    @State private var shareItem: ReaderDetailShareItem?
    @State private var reverseChapterList = false
    @State private var expandedDescription = false
    @State private var scrollOffset: CGFloat = 0
    @State private var headerAmbientColor: Color = .black
    @AppStorage(ReaderDetailElement.orderStorageKey) private var readerDetailElementOrder = ReaderDetailElement.defaultOrderRawValue
    @AppStorage(ReaderDetailElement.hiddenStorageKey) private var readerDetailHiddenElements = ""

    private var designMetrics: ExperimentalMediaDesignMetrics { .current }

    private var heroHeight: CGFloat {
        if ExperimentalFeatureState.isEnabledAtLaunch {
            return designMetrics.detailHeroHeight(screenHeight: UIScreen.main.bounds.height, isIPad: isIPad)
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

    private var route: MangaContentRoute {
        .aidoku(sourceId: sourceId, mangaKey: manga.key)
    }

    private var stableId: Int {
        route.stableNegativeId
    }

    private var coverURL: String {
        manga.cover ?? initialManga.cover ?? ""
    }

    private var libraryItem: MangaLibraryItem {
        MangaLibraryItem.fromAidoku(
            sourceId: sourceId,
            mangaKey: manga.key,
            title: manga.title,
            coverURL: coverURL,
            sourceName: sourceManager.metadata(id: sourceId)?.name,
            latestChapterNumbers: latestChapterNumbers,
            format: viewerFormat(manga.viewer)
        )
    }

    private var latestChapterNumbers: [String]? {
        chapterNumbers(from: manga)
    }

    private var visibleReaderDetailElements: [ReaderDetailElement] {
        ReaderDetailElement.orderedElements(from: readerDetailElementOrder)
            .filter { ReaderDetailElement.isVisible($0, hiddenRawValue: readerDetailHiddenElements) }
            .filter(readerDetailElementHasContent)
    }

    init(sourceId: String, initialManga: AidokuRunner.Manga) {
        self.sourceId = sourceId
        self.initialManga = initialManga
        _manga = State(initialValue: initialManga)
    }

    var body: some View {
        let experimental = ExperimentalFeatureState.isEnabledAtLaunch
        ScrollView {
            VStack(alignment: .leading, spacing: experimental ? designMetrics.sectionSpacing : 18) {
                headerSection
                primaryActionSection
                    .padding(.horizontal, 16)

                ForEach(visibleReaderDetailElements) { element in
                    readerDetailElementView(element)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, experimental ? 40 : 24)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ScrollOffsetPreferenceKey.self,
                        value: -geo.frame(in: .named("aidokuContentScroll")).origin.y
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
        .coordinateSpace(name: "aidokuContentScroll")
        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { scrollOffset = $0 }
        .task {
            await loadDetails(force: false)
        }
        .fullScreenCover(item: $selectedChapterData) { chapter in
            let chapters = readerChapters(from: chapterModels())
            let selected = chapters.first { $0.chapterNumber == chapter.chapterNumber } ?? chapters.first ?? chapter
            readerManagerView(
                chapters: chapters,
                selectedChapter: selected,
                kanzen: kanzen,
                mangaId: stableId,
                mangaTitle: manga.title,
                mangaCoverURL: coverURL,
                mangaRoute: route,
                mangaFormat: viewerFormat(manga.viewer),
                totalChapters: latestChapterNumbers?.count,
                latestChapterNumbers: latestChapterNumbers
            )
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .ignoresSafeArea(edges: .top)
        .background(readerDetailBackground.ignoresSafeArea())
        .sheet(isPresented: $showAddToCollection) {
            MangaAddToCollectionView(item: libraryItem)
                .environmentObject(libraryManager)
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: item.items)
        }
    }

    @MainActor
    private func loadDetails(force: Bool) async {
        guard force || manga.description == nil || manga.chapters == nil else { return }
        guard sourceManager.metadata(id: sourceId) != nil else {
            errorMessage = "This Aidoku source is missing. Reinstall it from Aidoku Sources to repair the route."
            return
        }

        isLoading = true
        errorMessage = nil
        do {
            let updated = try await sourceManager.mangaUpdate(
                sourceId: sourceId,
                manga: manga,
                needsDetails: true,
                needsChapters: true
            )
            let latestNumbers = chapterNumbers(from: updated) ?? []
            manga = updated
            libraryManager.updateSavedItem(libraryItem)
            progressManager.updateSourceMetadata(
                mangaId: stableId,
                title: updated.title,
                coverURL: updated.cover ?? initialManga.cover,
                format: viewerFormat(updated.viewer),
                latestChapterNumbers: latestNumbers,
                route: route,
                sourceRefreshError: nil
            )
        } catch {
            errorMessage = error.localizedDescription
            ReaderLogger.shared.log("Aidoku detail failed source=\(sourceId) manga=\(manga.key): \(error.localizedDescription)", type: "AidokuDetails")
        }
        isLoading = false
    }

    @ViewBuilder
    private var headerSection: some View {
        GeometryReader { geometry in
            let minY = geometry.frame(in: .global).minY
            let stretchedHeight = heroHeight + max(0, minY)
            let yOffset = min(0, -minY)
            let viewportWidth = geometry.size.width
            let experimental = ExperimentalFeatureState.isEnabledAtLaunch
            let contentAlignment: Alignment = experimental ? .bottom : .bottomLeading
            let textAlignment: HorizontalAlignment = experimental ? .center : .leading
            let posterWidth = experimental ? min(viewportWidth * 0.84, heroHeight * 0.66) : max(viewportWidth - 20, 0)
            let posterHeight = experimental ? max(heroHeight * 0.74, 270) : max(heroHeight - 26, 260)
            let titleSize: CGFloat = experimental ? (isIPad ? 48 : 40) : (isIPad ? 40 : 32)
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
                // Modern: a sharp full-bleed cover banner whose extracted color
                // drives the gradient + bleed, exactly like a media hero. Legacy:
                // blurred fill behind a centered cover poster.
                KFImage(URL(string: coverURL))
                    .placeholder { Color.black.opacity(0.18) }
                    .onSuccess { result in
                        headerAmbientColor = Color.ambientColor(from: result.image)
                    }
                    .resizable()
                    .scaledToFill()
                    .frame(width: viewportWidth, height: stretchedHeight)
                    .clipped()
                    .blur(radius: experimental ? 0 : 18)
                    .overlay(Color.black.opacity(experimental ? 0.10 : 0.34))

                if !experimental {
                    KFImage(URL(string: coverURL))
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
                    Text(manga.title)
                        .font(.system(size: titleSize, weight: .bold))
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .lineLimit(3)
                        .minimumScaleFactor(0.72)
                        .multilineTextAlignment(experimental ? .center : .leading)
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = manga.title
                            } label: {
                                Label("Copy Title", systemImage: "doc.on.doc")
                            }
                        }

                    HStack(spacing: 10) {
                        if manga.status != .unknown {
                            Text(statusTitle(manga.status))
                        }

                        let creators = creatorLine
                        if !creators.isEmpty {
                            Image(systemName: "person.fill")
                            Text(creators)
                                .lineLimit(1)
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

    private var creatorLine: String {
        let creators = (manga.authors ?? []) + (manga.artists ?? [])
        return Array(Set(creators)).sorted().joined(separator: ", ")
    }

    @ViewBuilder
    private var primaryActionSection: some View {
        let chapters = chapterModels()
        let experimental = ExperimentalFeatureState.isEnabledAtLaunch
        HStack(spacing: experimental ? 14 : 12) {
            readButton(chapters: chapters)

            Button {
                showAddToCollection = true
            } label: {
                Image(systemName: libraryManager.isBookmarked(libraryItem) ? "bookmark.fill" : "bookmark")
            }
            .readerDetailIconButton()

            Button {
                shareItem = ReaderDetailShareItem(
                    title: manga.title,
                    sourceName: sourceDisplayName,
                    sourceURLString: manga.url?.absoluteString ?? manga.key
                )
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .readerDetailIconButton()

            Button {
                Task { await loadDetails(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .readerDetailIconButton()
            .disabled(isLoading)
        }
    }

    private var sourceDisplayName: String {
        sourceManager.metadata(id: sourceId)?.name ?? sourceId
    }

    private func descriptionSection(_ text: String) -> some View {
        return Group {
            if ExperimentalFeatureState.isEnabledAtLaunch {
                VStack(alignment: .center, spacing: 8) {
                    Text(cleanedDescription(text))
                        .font(isIPad ? .title3 : .body)
                        .lineSpacing(4)
                        .foregroundColor(.white.opacity(0.86))
                        .multilineTextAlignment(.center)
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
                    Text(cleanedDescription(text))
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
    }

    private func tagsSection(_ tags: [String]) -> some View {
        let experimental = ExperimentalFeatureState.isEnabledAtLaunch
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
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
            }
        }
    }

    private func readerDetailElementHasContent(_ element: ReaderDetailElement) -> Bool {
        switch element {
        case .overview:
            return !(manga.description ?? "").isEmpty
        case .tags:
            return !(manga.tags ?? []).isEmpty
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
            if let tags = manga.tags, !tags.isEmpty {
                tagsSection(tags)
            }
        case .ratingNotes:
            let progress = progressManager.progress(for: stableId)
            ReaderRatingNotesView(
                itemId: stableId,
                title: manga.title,
                routeKey: route.stableKey,
                knownAniListId: progress?.trackerAniListId,
                knownMALId: progress?.trackerMALId,
                totalChapters: latestChapterNumbers?.count,
                format: viewerFormat(manga.viewer)
            )
        case .chapters:
            chaptersElementView()
        }
    }

    @ViewBuilder
    private func chaptersElementView() -> some View {
        if isLoading && (manga.chapters?.isEmpty ?? true) {
            HStack(spacing: 10) {
                EclipseLoadingIndicator()
                Text("Loading chapters...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else if let errorMessage {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { await loadDetails(force: true) }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else {
            chaptersView()
        }
    }

    @ViewBuilder
    private func chaptersView() -> some View {
        let chapters = chapterModels()
        if chapters.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text("No chapters found")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else {
            let displayed = reverseChapterList ? Array(chapters.reversed()) : chapters
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(sourceDisplayName)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer()
                    Text("\(chapters.count) Chapters")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    Button {
                        downloadManager.enqueueChapters(
                            route: route,
                            mangaId: stableId,
                            title: manga.title,
                            coverURL: coverURL,
                            sourceName: sourceManager.metadata(id: sourceId)?.name,
                            format: viewerFormat(manga.viewer),
                            chapters: chapters,
                            kanzen: kanzen
                        )
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .foregroundColor(.accentColor)
                    }
                    .accessibilityLabel("Download All")

                    Button {
                        reverseChapterList.toggle()
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .foregroundColor(.accentColor)
                    }
                }

                Divider().padding(.vertical, 4)

                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(displayed.enumerated()), id: \.element.id) { index, chapter in
                        chapterRow(chapter, displayedChapters: displayed, displayIndex: index)
                        Divider()
                    }
                }
            }
        }
    }

    private func chapterRow(_ chapter: Chapter, displayedChapters: [Chapter], displayIndex: Int) -> some View {
        let isRead = progressManager.isChapterRead(mangaId: stableId, chapterNumber: chapter.chapterNumber)
        let chapterTitle = chapter.chapterData?.first?.title ?? ""
        let downloadStatus = downloadManager.status(for: route, chapterNumber: chapter.chapterNumber)
        let downloadProgress = downloadManager.progress(for: route, chapterNumber: chapter.chapterNumber)

        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(chapter.chapterNumber)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(isRead ? .secondary : .primary)
                    .lineLimit(1)

                if !chapterTitle.isEmpty {
                    Text(chapterTitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                if let group = chapter.chapterData?.first?.scanlationGroup, !group.isEmpty {
                    Text(group)
                        .font(.caption2)
                        .foregroundColor(.accentColor.opacity(0.8))
                        .lineLimit(1)
                }

                if !isRead, let progressLabel = progressManager.pageProgressLabel(mangaId: stableId, chapterNumber: chapter.chapterNumber) {
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
                    progressManager.markChapterUnread(mangaId: stableId, chapterNumber: chapter.chapterNumber)
                } label: {
                    Label("Mark as Unread", systemImage: "eye.slash")
                }
            } else {
                Button {
                    progressManager.markChapterRead(
                        mangaId: stableId,
                        chapterNumber: chapter.chapterNumber,
                        mangaTitle: manga.title,
                        coverURL: coverURL,
                        format: viewerFormat(manga.viewer),
                        totalChapters: latestChapterNumbers?.count,
                        latestChapterNumbers: latestChapterNumbers,
                        route: route
                    )
                } label: {
                    Label("Mark as Read", systemImage: "eye")
                }
            }

            Divider()

            markRangeMenu(displayedChapters: displayedChapters, displayIndex: displayIndex)

            Divider()

            downloadContextMenu(for: chapter, status: downloadStatus)
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
    private func markRangeMenu(displayedChapters: [Chapter], displayIndex: Int) -> some View {
        Button {
            let numbers = displayedChapters.prefix(displayIndex + 1).map(\.chapterNumber)
            markChaptersRead(numbers)
        } label: {
            Label("Mark Above as Read", systemImage: "arrow.up.circle")
        }

        Button {
            let numbers = displayedChapters.suffix(displayedChapters.count - displayIndex).map(\.chapterNumber)
            markChaptersRead(Array(numbers))
        } label: {
            Label("Mark Below as Read", systemImage: "arrow.down.circle")
        }
    }

    @ViewBuilder
    private func downloadContextMenu(for chapter: Chapter, status: ReaderDownloadStatus) -> some View {
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
                    mangaId: stableId,
                    title: manga.title,
                    coverURL: coverURL,
                    sourceName: sourceManager.metadata(id: sourceId)?.name,
                    format: viewerFormat(manga.viewer),
                    chapter: chapter,
                    kanzen: kanzen
                )
            } label: {
                Label(status == .failed ? "Retry Download" : "Download", systemImage: "arrow.down.circle")
            }
        }
    }

    private func markChaptersRead(_ chapterNumbers: [String]) {
        progressManager.markAllRead(
            mangaId: stableId,
            chapterNumbers: chapterNumbers,
            mangaTitle: manga.title,
            coverURL: coverURL,
            format: viewerFormat(manga.viewer),
            totalChapters: latestChapterNumbers?.count,
            latestChapterNumbers: latestChapterNumbers,
            route: route
        )
    }

    private func readButton(chapters: [Chapter]) -> some View {
        let lastRead = progressManager.lastReadChapter(for: stableId)
        let readChapters = progressManager.readChapters(for: stableId)
        let target = targetChapterForReading(chapters: chapters, lastRead: lastRead, readChapters: readChapters)
        let experimental = ExperimentalFeatureState.isEnabledAtLaunch

        return Button {
            selectedChapterData = target
        } label: {
            HStack {
                Image(systemName: "book.fill")
                    .font(experimental ? .headline : .subheadline)
                Text(lastRead == nil && readChapters.isEmpty ? "Read Now" : "Continue")
                    .font(experimental ? .headline : .subheadline)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .frame(height: experimental ? 54 : nil)
            .padding(.vertical, experimental ? 0 : 12)
            .foregroundColor(.white)
            .background(
                RoundedRectangle(cornerRadius: experimental ? designMetrics.cardRadius : 12, style: .continuous)
                    .fill(experimental ? Color.white.opacity(0.18) : Color.accentColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: experimental ? designMetrics.cardRadius : 12, style: .continuous)
                    .stroke(Color.white.opacity(experimental ? 0.18 : 0), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(target == nil)
    }

    private func targetChapterForReading(chapters: [Chapter], lastRead: String?, readChapters: Set<String>) -> Chapter? {
        let readKeys = Set(readChapters.map { ChapterIdentityNormalizer.key(for: $0) })
        if let lastRead,
           !readKeys.contains(ChapterIdentityNormalizer.key(for: lastRead)),
           let chapter = chapters.first(where: {
               $0.chapterNumber == lastRead ||
               ChapterIdentityNormalizer.key(for: $0.chapterNumber) == ChapterIdentityNormalizer.key(for: lastRead)
           }) {
            return chapter
        }

        let chronological = chronologicalChapters(chapters)
        if let unread = chronological.first(where: { !readKeys.contains(ChapterIdentityNormalizer.key(for: $0.chapterNumber)) }) {
            return unread
        }
        return chronological.first
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

    private func chapterModels() -> [Chapter] {
        let rawChapters = manga.chapters ?? []
        let chapters = rawChapters.enumerated().map { index, aidokuChapter in
            let title = aidokuChapter.title ?? ""
            let number = chapterNumberTitle(aidokuChapter, fallbackIndex: index)
            let payload = AidokuChapterPayload(sourceId: sourceId, manga: manga, chapter: aidokuChapter)
            let group = aidokuChapter.scanlators?.joined(separator: ", ") ?? ""
            return Chapter(
                chapterNumber: number,
                idx: index,
                chapterData: [ChapterData(params: payload, title: title, scanlationGroup: group)]
            )
        }
        return ChapterIdentityNormalizer.deduplicatedChapters(chapters)
    }

    private func chapterNumbers(from manga: AidokuRunner.Manga) -> [String]? {
        let numbers = (manga.chapters ?? []).enumerated().map { index, chapter in
            chapterNumberTitle(chapter, fallbackIndex: index)
        }
        let unique = ChapterIdentityNormalizer.deduplicatedNumbers(numbers)
        return unique.isEmpty ? nil : unique
    }

    private func chapterNumberTitle(_ chapter: AidokuRunner.Chapter, fallbackIndex: Int) -> String {
        if let volume = chapter.volumeNumber, let number = chapter.chapterNumber {
            return "Vol. \(formatNumber(volume)) Ch. \(formatNumber(number))"
        }
        if let number = chapter.chapterNumber {
            return "Chapter \(formatNumber(number))"
        }
        if let title = chapter.title, !title.isEmpty {
            return title
        }
        return "Chapter \(fallbackIndex + 1)"
    }

    private func viewerFormat(_ viewer: AidokuRunner.Viewer) -> String {
        switch viewer {
        case .vertical, .webtoon:
            return "WEBTOON"
        default:
            return "MANGA"
        }
    }

    private func statusTitle(_ status: AidokuRunner.PublishingStatus) -> String {
        switch status {
        case .ongoing:
            return "Ongoing"
        case .completed:
            return "Completed"
        case .cancelled:
            return "Cancelled"
        case .hiatus:
            return "Hiatus"
        default:
            return "Unknown"
        }
    }

    private func cleanedDescription(_ value: String) -> String {
        value
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private func formatNumber(_ value: Float) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(value)
    }
}

struct MangaSourceRepairView: View {
    let title: String
    let message: String
    let actionTitle: String
    var action: (() -> Void)?

    init(title: String, message: String, actionTitle: String = "Aidoku Sources", action: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox.and.arrow.backward")
                .font(.system(size: 42))
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            } else {
                NavigationLink(destination: AidokuSourcesSettingsView()) {
                    Label(actionTitle, systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ReaderDetailShareItem: Identifiable {
    let id = UUID()
    let items: [Any]

    init(title: String, sourceName: String?, sourceURLString: String?) {
        if let url = Self.url(from: sourceURLString) {
            items = [url]
        } else {
            let source = sourceName?.trimmingCharacters(in: .whitespacesAndNewlines)
            items = [[title, source].compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }.joined(separator: "\n")]
        }
    }

    private static func url(from value: String?) -> URL? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        if let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return url
        }

        if raw.lowercased().hasPrefix("www."),
           let url = URL(string: "https://\(raw)") {
            return url
        }

        return nil
    }
}

extension View {
    @ViewBuilder
    func readerDetailIconButton() -> some View {
        if ExperimentalFeatureState.isEnabledAtLaunch {
            self
                .font(.headline)
                .frame(width: 52, height: 52)
                .foregroundColor(.white)
                .applyLiquidGlassBackground(cornerRadius: 26)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
        } else {
            self
                .font(.subheadline)
                .frame(width: 52, height: 44)
                .foregroundColor(.accentColor)
                .background(Color.primary.opacity(0.08))
                .cornerRadius(12)
        }
    }
}
#endif
