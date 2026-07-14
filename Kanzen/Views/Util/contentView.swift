import SwiftUI
import Foundation
import Kingfisher
#if canImport(UIKit)
import UIKit
#endif

#if !os(tvOS)
struct contentView: View {
    @State var parentModule: ModuleDataContainer?
    @State  var title: String
    @State  var imageURL: String
    @State  var params: String
    @State var expandedDescription : Bool = false
    @State private var contentData: [String:Any]?
    @State private var contentChapters: [Chapters]?
    @EnvironmentObject var kanzen: KanzenEngine
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var favouriteManager : FavouriteManager
    @ObservedObject private var libraryManager = MangaLibraryManager.shared
    @ObservedObject private var progressManager = MangaReadingProgressManager.shared
    @ObservedObject private var downloadManager = ReaderDownloadManager.shared
    @ObservedObject private var theme = EclipseTheme.shared
    @State private var showAddToCollection: Bool = false
    @State private var shareItem: ReaderDetailShareItem?
    @State private var width: CGFloat = 150
    @State private var langaugeIdx: Int = 0
    @State private var showChaptersMenu: Bool = false
    @State private var selectedChapterData: Chapter? = nil
    @State private var selectedChapterIdx: Int?
    @State var reverseChapterlist: Bool = false
    @State var toggleFavourite: Bool = false
    @State var loadingState : Bool = true
    @State private var scrollOffset: CGFloat = 0
    @State private var headerAmbientColor: Color = .black
    @AppStorage(ReaderDetailElement.orderStorageKey) private var readerDetailElementOrder = ReaderDetailElement.defaultOrderRawValue
    @AppStorage(ReaderDetailElement.hiddenStorageKey) private var readerDetailHiddenElements = ""

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

    /// Stable numeric ID derived from module + content params for progress & library.
    private var stableId: Int {
        guard let module = parentModule else { return 0 }
        let combined = "\(module.id.uuidString):\(params)"
        let hash = combined.utf8.reduce(into: 5381) { h, c in h = ((h &<< 5) &+ h) &+ Int(c) }
        return hash < 0 ? hash : -hash - 1
    }

    private var libraryItem: MangaLibraryItem {
        MangaLibraryItem.fromModule(
            moduleId: parentModule?.id ?? UUID(),
            contentId: params,
            title: title,
            coverURL: imageURL,
            isNovel: parentModule?.moduleData.novel == true,
            sourceName: parentModule?.moduleData.sourceName,
            latestChapterNumbers: currentChapterNumbers
        )
    }

    private var currentChapterNumbers: [String]? {
        chapterNumbers(from: contentChapters)
    }

    private func chapterNumbers(from groups: [Chapters]?) -> [String]? {
        let numbers = groups?
            .max(by: { $0.chapters.count < $1.chapters.count })?
            .chapters
            .map(\.chapterNumber)
        return numbers.map(ChapterIdentityNormalizer.deduplicatedNumbers)
    }

    private var contentRoute: MangaContentRoute? {
        guard let parentModule else { return nil }
        return .legacyModule(
            moduleUUID: parentModule.id.uuidString,
            contentParams: params,
            isNovel: parentModule.moduleData.novel == true
        )
    }

    private var visibleReaderDetailElements: [ReaderDetailElement] {
        ReaderDetailElement.orderedElements(from: readerDetailElementOrder)
            .filter { ReaderDetailElement.isVisible($0, hiddenRawValue: readerDetailHiddenElements) }
            .filter(readerDetailElementHasContent)
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
                        value: -geo.frame(in: .named("moduleContentScroll")).origin.y
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
        .coordinateSpace(name: "moduleContentScroll")
        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { scrollOffset = $0 }
        .onAppear {
            getContentData()
            toggleFavourite = checkIfFavorited()
        }
        .fullScreenCover(item: $selectedChapterData) { chapter in
            if let contentChapters = self.contentChapters{
                let chapterList = contentChapters[langaugeIdx].chapters
                let readerChapterList = readerChapters(from: chapterList)
                let selectedReaderChapter = readerChapterList.first {
                    $0.chapterNumber == chapter.chapterNumber
                } ?? readerChapterList.first ?? chapter
                readerManagerView(
                    chapters: readerChapterList,
                    selectedChapter: selectedReaderChapter,
                    kanzen: kanzen,
                    mangaId: stableId,
                    mangaTitle: title,
                    mangaCoverURL: imageURL,
                    mangaRoute: contentRoute,
                    mangaFormat: parentModule?.moduleData.novel == true ? "NOVEL" : "MANGA",
                    totalChapters: currentChapterNumbers?.count,
                    latestChapterNumbers: currentChapterNumbers
                )
            }
            
        }
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
    }
    
    func checkIfFavorited() -> Bool {
        if let module = parentModule {
            return FavouriteManager.shared.isFavourite(moduleId: module.id, contentId: params)
        }
        return false
    }
    
    func getContentData() {
        kanzen.extractDetails(params: self.params) { result in
            DispatchQueue.main.async { self.contentData = result }
        }
        kanzen.extractChapters(params: self.params) { result in
            DispatchQueue.main.async {
                if let result = result {
                    var temp: [Chapters] = []

                    if let dictResult = result as? [String: Any] {
                        for (key, value) in dictResult {
                            var tempChapters: [Chapter] = []
                            if let chapters = value as? [Any?] {
                                for (idx, chapter) in chapters.enumerated() {
                                    if let chapter = chapter as? [Any?],
                                       chapter.count >= 2,
                                       let chapterName = chapter[0] as? String,
                                       let rawData = chapter[1] as? [[String: Any?]],
                                       let chapterData = rawData.compactMap({ ChapterData(dict: $0 as [String: Any]) }) as? [ChapterData] {
                                        tempChapters.append(Chapter(chapterNumber: chapterName, idx: idx, chapterData: chapterData))
                                    }
                                }
                            }
                            if !tempChapters.isEmpty {
                                temp.append(Chapters(language: key, chapters: tempChapters))
                            }
                        }
                    } else if let arrResult = result as? [[String: Any]] {
                        var tempChapters: [Chapter] = []
                        for (idx, chapterDict) in arrResult.enumerated() {
                            let name = (chapterDict["number"] as? Int).map { "Chapter \($0)" }
                                ?? (chapterDict["title"] as? String)
                                ?? "Chapter \(idx + 1)"
                            if let data = ChapterData(dict: chapterDict) {
                                tempChapters.append(Chapter(chapterNumber: name, idx: idx, chapterData: [data]))
                            }
                        }
                        if !tempChapters.isEmpty {
                            temp.append(Chapters(language: "default", chapters: tempChapters))
                        }
                    }

                    temp = temp.map {
                        Chapters(
                            language: $0.language,
                            chapters: ChapterIdentityNormalizer.deduplicatedChapters($0.chapters, reindex: true)
                        )
                    }

                    self.contentChapters = temp
                    if !temp.isEmpty {
                        let latestNumbers = chapterNumbers(from: temp) ?? []
                        libraryManager.updateSavedItem(libraryItem)
                        progressManager.updateSourceMetadata(
                            mangaId: stableId,
                            title: title,
                            coverURL: imageURL,
                            format: parentModule?.moduleData.novel == true ? "NOVEL" : "MANGA",
                            latestChapterNumbers: latestNumbers,
                            route: contentRoute,
                            sourceRefreshError: nil
                        )
                    }
                }
                self.loadingState = false
            }
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
                KFImage(URL(string: imageURL))
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
                    KFImage(URL(string: imageURL))
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
                    Text(title)
                        .font(.system(size: titleSize, weight: .bold))
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .lineLimit(3)
                        .minimumScaleFactor(0.72)
                        .multilineTextAlignment(experimental ? .center : .leading)
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = title
                            } label: {
                                Label("Copy Title", systemImage: "doc.on.doc")
                            }
                        }

                    HStack(spacing: 10) {
                        if let status = contentData?["status"] as? String {
                            Text(status)
                        }

                        if let authorArtist = contentData?["authorArtist"] as? [String], !authorArtist.isEmpty {
                            Image(systemName: "person.fill")
                            Text(authorArtist.joined(separator: ", "))
                                .lineLimit(1)
                        }

                        Text(parentModule?.moduleData.novel == true ? "Light Novel" : "Manga")
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
            readButton(chapters: chapters)

            Button {
                showAddToCollection = true
            } label: {
                Image(systemName: libraryManager.isBookmarked(libraryItem) ? "bookmark.fill" : "bookmark")
            }
            .readerDetailIconButton()

            Button {
                shareItem = ReaderDetailShareItem(
                    title: title,
                    sourceName: sourceDisplayName,
                    sourceURLString: params
                )
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .readerDetailIconButton()

            Button {
                loadingState = true
                getContentData()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .readerDetailIconButton()
        }
    }

    private var sourceDisplayName: String {
        parentModule?.moduleData.sourceName ?? "Source"
    }

    private func selectedChapterGroupForReading() -> [Chapter] {
        guard let contentChapters, !contentChapters.isEmpty else { return [] }
        let index = min(max(langaugeIdx, 0), contentChapters.count - 1)
        return contentChapters[index].chapters
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

    // MARK: - Tags

    @ViewBuilder
    private func tagsSection(_ tags: [String]) -> some View {
        let experimental = ExperimentalFeatureState.isEnabledAtLaunch
        ScrollView(.horizontal, showsIndicators: false) {
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
            return !(contentData?["description"] as? String ?? "").isEmpty
        case .tags:
            return !(contentData?["tags"] as? [String] ?? []).isEmpty
        case .ratingNotes, .chapters:
            return true
        }
    }

    @ViewBuilder
    private func readerDetailElementView(_ element: ReaderDetailElement) -> some View {
        switch element {
        case .overview:
            if let description = contentData?["description"] as? String, !description.isEmpty {
                descriptionSection(description)
            }
        case .tags:
            if let tags = contentData?["tags"] as? [String], !tags.isEmpty {
                tagsSection(tags)
            }
        case .ratingNotes:
            let progress = progressManager.progress(for: stableId)
            ReaderRatingNotesView(
                itemId: stableId,
                title: title,
                routeKey: contentRoute?.stableKey,
                knownAniListId: progress?.trackerAniListId,
                knownMALId: progress?.trackerMALId,
                totalChapters: currentChapterNumbers?.count,
                format: parentModule?.moduleData.novel == true ? "NOVEL" : "MANGA"
            )
        case .chapters:
            chaptersElementView()
        }
    }

    @ViewBuilder
    private func chaptersElementView() -> some View {
        if loadingState {
            HStack(spacing: 10) {
                EclipseLoadingIndicator()
                Text("Loading chapters...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else {
            chaptersView()
        }
    }

    // MARK: - Chapters

    @ViewBuilder
    func chaptersView() -> some View {
        if let chaptersData = self.contentChapters, !chaptersData.isEmpty {
            let selected = chaptersData[langaugeIdx]
            let displayed: [Chapter] = reverseChapterlist ? Array(selected.chapters.reversed()) : selected.chapters

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(sourceDisplayName)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer()
                    Text("\(selected.chapters.count) Chapters")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    if chaptersData.count > 1 {
                        Menu {
                            ForEach(Array(chaptersData.enumerated()), id: \.offset) { idx, lang in
                                Button(lang.language) { langaugeIdx = idx }
                            }
                        } label: {
                            Image(systemName: "globe")
                                .foregroundColor(.accentColor)
                        }
                    }

                    if let contentRoute {
                        Button {
                            downloadManager.enqueueChapters(
                                route: contentRoute,
                                mangaId: stableId,
                                title: title,
                                coverURL: imageURL,
                                sourceName: parentModule?.moduleData.sourceName,
                                format: parentModule?.moduleData.novel == true ? "NOVEL" : "MANGA",
                                chapters: selected.chapters,
                                kanzen: kanzen
                            )
                        } label: {
                            Image(systemName: "arrow.down.circle")
                                .foregroundColor(.accentColor)
                        }
                        .accessibilityLabel("Download All")
                    }

                    Button {
                        reverseChapterlist.toggle()
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .foregroundColor(.accentColor)
                    }
                }

                Divider().padding(.vertical, 4)

                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(displayed.enumerated()), id: \.element.id) { displayIndex, chapter in
                        let isRead = progressManager.isChapterRead(mangaId: stableId, chapterNumber: chapter.chapterNumber)
                        let chapterTitle = chapter.chapterData?.first?.title ?? ""
                        let downloadStatus = downloadManager.status(for: contentRoute, chapterNumber: chapter.chapterNumber)
                        let downloadProgress = downloadManager.progress(for: contentRoute, chapterNumber: chapter.chapterNumber)

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
                                    mangaTitle: title,
                                    coverURL: imageURL,
                                    format: parentModule?.moduleData.novel == true ? "NOVEL" : "MANGA",
                                    totalChapters: currentChapterNumbers?.count,
                                    latestChapterNumbers: currentChapterNumbers,
                                    moduleUUID: parentModule?.id.uuidString,
                                    contentParams: params,
                                    isNovel: parentModule?.moduleData.novel == true,
                                    route: contentRoute
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
                                mangaId: stableId,
                                chapterNumbers: allNums,
                                mangaTitle: title,
                                coverURL: imageURL,
                                format: parentModule?.moduleData.novel == true ? "NOVEL" : "MANGA",
                                totalChapters: currentChapterNumbers?.count,
                                latestChapterNumbers: currentChapterNumbers,
                                moduleUUID: parentModule?.id.uuidString,
                                contentParams: params,
                                isNovel: parentModule?.moduleData.novel == true,
                                route: contentRoute
                            )
                        } label: {
                            Label("Mark All as Read", systemImage: "checkmark.circle.fill")
                        }

                        Button(role: .destructive) {
                            progressManager.markAllUnread(mangaId: stableId)
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
        } else {
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
        if let route = contentRoute {
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
                        title: title,
                        coverURL: imageURL,
                        sourceName: parentModule?.moduleData.sourceName,
                        format: parentModule?.moduleData.novel == true ? "NOVEL" : "MANGA",
                        chapter: chapter,
                        kanzen: kanzen
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
            mangaId: stableId,
            chapterNumbers: chapters.map(\.chapterNumber),
            mangaTitle: title,
            coverURL: imageURL,
            format: parentModule?.moduleData.novel == true ? "NOVEL" : "MANGA",
            totalChapters: currentChapterNumbers?.count,
            latestChapterNumbers: currentChapterNumbers,
            moduleUUID: parentModule?.id.uuidString,
            contentParams: params,
            isNovel: parentModule?.moduleData.novel == true,
            route: contentRoute
        )
    }

    // MARK: - Read / Continue Button

    @ViewBuilder
    private func readButton(chapters: [Chapter]) -> some View {
        let lastRead = progressManager.lastReadChapter(for: stableId)
        let readChapters = progressManager.readChapters(for: stableId)
        let readKeys = Set(readChapters.map { ChapterIdentityNormalizer.key(for: $0) })
        let hasProgress = lastRead != nil || !readChapters.isEmpty
        let experimental = ExperimentalFeatureState.isEnabledAtLaunch

        let targetChapter: Chapter? = {
            if let lastRead = lastRead {
                let lastReadKey = ChapterIdentityNormalizer.key(for: lastRead)
                if !readKeys.contains(lastReadKey),
                   let ch = chapters.first(where: {
                    $0.chapterNumber == lastRead ||
                    ChapterIdentityNormalizer.key(for: $0.chapterNumber) == lastReadKey
                }) {
                    return ch
                }
            }
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
                        .font(experimental ? .headline : .subheadline)
                    Text(hasProgress ? "Continue Reading" : "Start Reading")
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
}

struct MangaModuleContentLoaderView: View {
    let module: ModuleDataContainer
    let title: String
    let imageURL: String
    let contentParams: String
    let isNovel: Bool

    @StateObject private var kanzen = KanzenEngine()
    @State private var moduleLoaded = false
    @State private var loadError: String?

    var body: some View {
        Group {
            if moduleLoaded {
                contentView(
                    parentModule: module,
                    title: title,
                    imageURL: imageURL,
                    params: contentParams
                )
                .environmentObject(kanzen)
            } else if let loadError {
                MangaModuleUnavailableView(
                    title: title,
                    message: loadError
                )
            } else {
                EclipseLoadingIndicator("Loading source...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task(id: "\(module.id.uuidString):\(contentParams)") {
                        loadModule()
                    }
            }
        }
    }

    private func loadModule() {
        do {
            let content = try ModuleManager.shared.getModuleScript(module: module)
            try kanzen.loadScript(content, isNovel: isNovel)
            moduleLoaded = true
        } catch {
            ReaderLogger.shared.log("Error loading module content: \(error.localizedDescription)", type: "Error")
            loadError = error.localizedDescription
        }
    }
}

struct MangaModuleUnavailableView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 42))
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
