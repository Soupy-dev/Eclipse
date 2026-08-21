#if !os(tvOS)
import SwiftUI
import Kingfisher
#if canImport(UIKit)
import UIKit
#endif

/// Adapts provider-neutral Reader Extension chapters to Kanzen's established
/// reader, progress, and download pipeline without persisting executable state.
private struct ReaderExtensionDetailChapterCache {
    let displayChapters: [Chapter]
    let readerChapters: [Chapter]
    let latestChapterNumbers: [String]?

    static func make(
        sourceID: ReaderExtensionSourceID,
        mediaType: ReaderExtensionMediaType,
        item: ReaderExtensionItem,
        chapters: [ReaderExtensionChapter]
    ) -> Self {
        let bridged = chapters.enumerated().map { index, chapter in
            chapter.kanzenChapter(sourceID: sourceID, mediaType: mediaType, item: item, index: index)
        }
        let display = ChapterIdentityNormalizer.deduplicatedChapters(bridged)
        let chronological = display.sorted { lhs, rhs in
            let left = ChapterIdentityNormalizer.numericValue(in: lhs.chapterNumber)
            let right = ChapterIdentityNormalizer.numericValue(in: rhs.chapterNumber)
            switch (left, right) {
            case let (left?, right?):
                return left == right ? lhs.idx < rhs.idx : left < right
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return lhs.idx > rhs.idx
            }
        }
        let reader = ChapterIdentityNormalizer.deduplicatedChapters(chronological, reindex: false)
            .enumerated()
            .map { Chapter(chapterNumber: $0.element.chapterNumber, idx: $0.offset, chapterData: $0.element.chapterData) }
        let latest = ChapterIdentityNormalizer.deduplicatedNumbers(display.map(\.chapterNumber))
        return Self(displayChapters: display, readerChapters: reader, latestChapterNumbers: latest.isEmpty ? nil : latest)
    }

    static let empty = Self(displayChapters: [], readerChapters: [], latestChapterNumbers: nil)
}

private struct ReaderExtensionChapterProgressSnapshot {
    private let readKeys: Set<String>
    private let pagePositions: [String: Int]
    private let pageCounts: [String: Int]

    init(progress: MangaProgress?) {
        readKeys = Set((progress?.readChapterNumbers ?? []).map(ChapterIdentityNormalizer.key))
        pagePositions = (progress?.pagePositions ?? [:]).reduce(into: [:]) {
            $0[ChapterIdentityNormalizer.key(for: $1.key)] = $1.value
        }
        pageCounts = (progress?.pageCounts ?? [:]).reduce(into: [:]) {
            $0[ChapterIdentityNormalizer.key(for: $1.key)] = $1.value
        }
    }

    func isRead(_ chapterNumber: String) -> Bool {
        readKeys.contains(ChapterIdentityNormalizer.key(for: chapterNumber))
    }

    func pageProgressLabel(_ chapterNumber: String) -> String? {
        let key = ChapterIdentityNormalizer.key(for: chapterNumber)
        guard let position = pagePositions[key], let total = pageCounts[key], total > 0 else { return nil }
        return "Page \(min(max(position + 1, 1), total)) of \(total)"
    }
}

struct ReaderExtensionMangaRouteLoaderView: View {
    let sourceID: ReaderExtensionSourceID
    let itemKey: String
    let legacyStableKey: String?
    let title: String
    let coverURL: String?

    @State private var item: ReaderExtensionItem?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @StateObject private var sourceManager = ReaderExtensionManager.shared

    var body: some View {
        Group {
            if let item {
                ReaderExtensionMangaDetailView(
                    sourceID: sourceID,
                    initialItem: item,
                    legacyStableKey: legacyStableKey,
                    initialItemHasDetails: true
                )
            } else if let errorMessage {
                MangaSourceRepairView(title: title, message: errorMessage, actionTitle: "Reader Sources")
            } else if let source = source, !source.enabled {
                MangaSourceRepairView(
                    title: title,
                    message: "\(source.name) is disabled.",
                    actionTitle: "Enable Source"
                ) {
                    do {
                        try sourceManager.setEnabled(true, for: sourceID)
                        Task { await load() }
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            } else if isLoading {
                EclipseLoadingIndicator("Loading source...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task { await load() }
            }
        }
    }

    private var source: ReaderExtensionInstalledSource? {
        sourceManager.installedSources.first(where: { $0.id == sourceID })
    }

    @MainActor
    private func load() async {
        isLoading = true
        errorMessage = nil
        let owner = ProfileManager.shared.activeProfileID
        guard source != nil else {
            errorMessage = "This Reader Extension is missing. Reconnect the title or reinstall its source."
            isLoading = false
            return
        }
        do {
            let seed = ReaderExtensionItem(
                key: itemKey,
                title: title,
                coverURL: coverURL.flatMap(URL.init(string:)),
                maturity: source?.maturity ?? .unknown
            )
            let fetched = seed.mergingDetail(
                try await sourceManager.provider(for: sourceID).detail(itemKey: itemKey)
            )
            guard ReaderContentFilter.shared.allows(fetched) else {
                throw ReaderExtensionError.resultInvalid("Not available on this profile")
            }
            guard ProfileManager.shared.isStillActive(owner) else {
                isLoading = false
                return
            }
            item = fetched
        } catch {
            guard ProfileManager.shared.isStillActive(owner) else {
                isLoading = false
                return
            }
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct ReaderExtensionMangaDetailView: View {
    let sourceID: ReaderExtensionSourceID
    let initialItem: ReaderExtensionItem
    let legacyStableKey: String?
    private let initialItemHasDetails: Bool

    @ObservedObject private var libraryManager = MangaLibraryManager.shared
    @ObservedObject private var progressManager = MangaReadingProgressManager.shared
    @ObservedObject private var downloadManager = ReaderDownloadManager.shared
    @ObservedObject private var contentFilter = ReaderContentFilter.shared
    @StateObject private var sourceManager = ReaderExtensionManager.shared
    @StateObject private var kanzen = KanzenEngine()

    @State private var item: ReaderExtensionItem
    @State private var chapterCache = ReaderExtensionDetailChapterCache.empty
    @State private var selectedChapter: Chapter?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showAddToCollection = false
    @State private var shareItem: ReaderDetailShareItem?
    @State private var reverseChapterList = false
    @State private var expandedDescription = false
    @State private var ambientColor: Color = .black
    @AppStorage(ReaderDetailElement.orderStorageKey) private var readerDetailElementOrder = ReaderDetailElement.defaultOrderRawValue
    @AppStorage(ReaderDetailElement.hiddenStorageKey) private var readerDetailHiddenElements = ""

    init(
        sourceID: ReaderExtensionSourceID,
        initialItem: ReaderExtensionItem,
        legacyStableKey: String? = nil,
        initialItemHasDetails: Bool = false
    ) {
        self.sourceID = sourceID
        self.initialItem = initialItem
        self.legacyStableKey = legacyStableKey
        self.initialItemHasDetails = initialItemHasDetails
        _item = State(initialValue: initialItem)
    }

    private var source: ReaderExtensionInstalledSource? {
        sourceManager.installedSources.first(where: { $0.id == sourceID })
    }

    private var mediaType: ReaderExtensionMediaType { source?.mediaType ?? .manga }
    private var format: String { mediaType == .novel ? "NOVEL" : "MANGA" }
    private var coverURL: String { item.coverURL?.absoluteString ?? initialItem.coverURL?.absoluteString ?? "" }
    private var metadataCoverURL: String? {
        ReaderExtensionSafeMetadata.sanitizedURLString(item.coverURL ?? initialItem.coverURL)
    }
    private var route: MangaContentRoute {
        .readerExtension(source: sourceID, itemKey: item.key, legacyStableKey: legacyStableKey)
    }
    private var stableID: Int { route.stableNegativeId }
    private var latestChapterNumbers: [String]? { chapterCache.latestChapterNumbers }
    private var sourceName: String { source?.name ?? "Reader Extension" }
    private var contentRating: Int { ReaderContentFilter.shared.derivedReaderExtensionRating(for: item) }
    private var visibleReaderDetailElements: [ReaderDetailElement] {
        ReaderDetailElement.orderedElements(from: readerDetailElementOrder)
            .filter { ReaderDetailElement.isVisible($0, hiddenRawValue: readerDetailHiddenElements) }
            .filter(readerDetailElementHasContent)
    }
    private var libraryItem: MangaLibraryItem {
        .fromReaderExtension(
            sourceID: sourceID,
            itemKey: item.key,
            legacyStableKey: legacyStableKey,
            title: item.title,
            coverURL: metadataCoverURL,
            sourceName: sourceName,
            latestChapterNumbers: latestChapterNumbers,
            format: format,
            contentRating: contentRating
        )
    }

    var body: some View {
        Group {
            if contentFilter.isKidsProfileActive && !contentFilter.allows(item) {
                restrictedPlaceholder
            } else {
                detailContent
            }
        }
        // Reader detail always sits on Eclipse's dark atmosphere background.
        // Keep semantic primary/secondary labels and native controls legible even
        // when the device itself is using Light appearance.
        .preferredColorScheme(.dark)
        .onChangeComp(of: contentFilter.isKidsProfileActive) { _, isKids in
            if isKids { selectedChapter = nil }
        }
    }

    private var restrictedPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.system(size: 48)).foregroundColor(.secondary)
            Text("Not available on this profile").font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GlobalGradientBackground().ignoresSafeArea())
    }

    private var detailContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                actions
                ForEach(visibleReaderDetailElements) { element in
                    readerDetailElementView(element)
                }
            }
            .padding(.bottom, 28)
        }
        .task { await loadDetails(force: false) }
        .fullScreenCover(item: $selectedChapter) { chapter in
            let chapters = chapterCache.readerChapters
            let selected = chapters.first(where: { $0.chapterNumber == chapter.chapterNumber }) ?? chapter
            if mediaType == .novel {
                NovelReaderView(
                    kanzen: kanzen,
                    chapters: chapters,
                    initialChapter: selected,
                    mangaId: stableID,
                    mangaTitle: item.title,
                    mangaCoverURL: metadataCoverURL ?? "",
                    mangaRoute: route,
                    mangaFormat: format,
                    totalChapters: latestChapterNumbers?.count,
                    latestChapterNumbers: latestChapterNumbers
                )
            } else {
                readerManagerView(
                    chapters: chapters,
                    selectedChapter: selected,
                    kanzen: kanzen,
                    mangaId: stableID,
                    mangaTitle: item.title,
                    mangaCoverURL: metadataCoverURL ?? "",
                    mangaRoute: route,
                    mangaFormat: format,
                    totalChapters: latestChapterNumbers?.count,
                    latestChapterNumbers: latestChapterNumbers
                )
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .ignoresSafeArea(edges: .top)
        .background(GlobalGradientBackground().ignoresSafeArea())
        .sheet(isPresented: $showAddToCollection) {
            MangaAddToCollectionView(item: libraryItem).environmentObject(libraryManager)
        }
        .sheet(item: $shareItem) { ActivityView(items: $0.items) }
    }

    private var header: some View {
        let height: CGFloat = isIPad ? 620 : 500
        return GeometryReader { geometry in
            let viewportWidth = max(geometry.size.width, 0)
            ZStack(alignment: .bottomLeading) {
                ReaderScopedRemoteImage(
                    url: URL(string: coverURL),
                    readerExtensionSourceID: sourceID,
                    onImage: { ambientColor = Color.ambientColor(from: $0) }
                ) {
                    Color.black.opacity(0.2)
                }
                .scaledToFill()
                .frame(width: viewportWidth, height: height)
                .clipped()

                LinearGradient(
                    colors: [.clear, ambientColor.opacity(0.45), .black.opacity(0.95)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: viewportWidth, height: height)

                VStack(alignment: .leading, spacing: 7) {
                    Text(item.title)
                        .font(.system(size: isIPad ? 40 : 32, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(3)
                        .minimumScaleFactor(0.75)
                        .contextMenu {
                            Button { UIPasteboard.general.string = item.title } label: {
                                Label("Copy Title", systemImage: "doc.on.doc")
                            }
                        }
                    HStack(spacing: 8) {
                        if item.status != .unknown { Text(statusTitle(item.status)) }
                        if !creatorLine.isEmpty { Image(systemName: "person.fill"); Text(creatorLine).lineLimit(1) }
                    }
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.82))
                    Text(sourceName).font(.caption).foregroundColor(.white.opacity(0.7))
                }
                .padding(.horizontal, isIPad ? 32 : 16)
                .padding(.bottom, 20)
                .frame(width: viewportWidth, alignment: .leading)
            }
            .frame(width: viewportWidth, height: height, alignment: .bottomLeading)
            .clipped()
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
    }

    private var creatorLine: String {
        Array(Set([item.author, item.artist].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })).sorted().joined(separator: ", ")
    }

    private var actions: some View {
        HStack(spacing: 12) {
            readButton
            Button { showAddToCollection = true } label: {
                Image(systemName: libraryManager.isBookmarked(libraryItem) ? "bookmark.fill" : "bookmark")
            }.readerDetailIconButton()
            Button {
                shareItem = ReaderDetailShareItem(
                    title: item.title,
                    sourceName: sourceName,
                    sourceURLString: ReaderExtensionSafeMetadata.sanitizedURLString(item.url)
                )
            } label: { Image(systemName: "square.and.arrow.up") }
            .readerDetailIconButton()
            Button { Task { await loadDetails(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                .readerDetailIconButton().disabled(isLoading)
        }
        .padding(.horizontal, isIPad ? 32 : 16)
    }

    private var readButton: some View {
        let chapters = chapterCache.readerChapters
        let lastRead = progressManager.lastReadChapter(for: stableID)
        let read = progressManager.readChapters(for: stableID)
        let readKeys = Set(read.map(ChapterIdentityNormalizer.key))
        let hasProgress = lastRead != nil || !read.isEmpty
        let target: Chapter? = {
            if let lastRead {
                let lastReadKey = ChapterIdentityNormalizer.key(for: lastRead)
                if !readKeys.contains(lastReadKey),
                   let partiallyRead = chapters.first(where: {
                       $0.chapterNumber == lastRead ||
                           ChapterIdentityNormalizer.key(for: $0.chapterNumber) == lastReadKey
                   }) {
                    return partiallyRead
                }
            }
            return chapters.first {
                !readKeys.contains(ChapterIdentityNormalizer.key(for: $0.chapterNumber))
            } ?? chapters.first
        }()
        return Button { selectedChapter = target } label: {
            Label(hasProgress ? "Continue" : "Read Now", systemImage: "book.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundColor(.white)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor))
        }
        .buttonStyle(.plain)
        .disabled(target == nil)
    }

    private func overview(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Overview").font(.headline)
            Text(cleanedDescription(text))
                .foregroundColor(.secondary)
                .lineLimit(expandedDescription ? nil : 5)
                .onTapGesture { withAnimation { expandedDescription.toggle() } }
            if !expandedDescription { Button("More") { withAnimation { expandedDescription = true } }.font(.caption) }
        }
        .padding(.horizontal, isIPad ? 32 : 16)
    }

    private func readerDetailElementHasContent(_ element: ReaderDetailElement) -> Bool {
        switch element {
        case .overview:
            return !(item.description ?? "").isEmpty
        case .tags:
            return !item.tags.isEmpty
        case .ratingNotes, .chapters:
            return true
        }
    }

    @ViewBuilder
    private func readerDetailElementView(_ element: ReaderDetailElement) -> some View {
        switch element {
        case .overview:
            if let description = item.description, !description.isEmpty {
                overview(description)
            }
        case .tags:
            if !item.tags.isEmpty {
                tags
            }
        case .ratingNotes:
            ReaderRatingNotesView(
                itemId: stableID,
                title: item.title,
                routeKey: route.stableKey,
                knownAniListId: progressManager.progress(for: stableID)?.trackerAniListId,
                knownMALId: progressManager.progress(for: stableID)?.trackerMALId,
                totalChapters: latestChapterNumbers?.count,
                format: format
            )
        case .chapters:
            chaptersSection
        }
    }

    private var tags: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(item.tags, id: \.self) { tag in
                    Text(tag).font(.footnote).padding(.horizontal, 12).padding(.vertical, 6)
                        .overlay(Capsule().stroke(Color.secondary.opacity(0.5)))
                }
            }.padding(.horizontal, isIPad ? 32 : 16)
        }
    }

    @ViewBuilder
    private var chaptersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoading && chapterCache.displayChapters.isEmpty {
                HStack { EclipseLoadingIndicator(); Text("Loading chapters...").foregroundColor(.secondary) }
                    .frame(maxWidth: .infinity).padding()
            } else if let errorMessage, chapterCache.displayChapters.isEmpty {
                VStack(spacing: 10) {
                    Text(errorMessage).font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                    Button("Retry") { Task { await loadDetails(force: true) } }.buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity).padding()
            } else if chapterCache.displayChapters.isEmpty {
                Text("No chapters found").foregroundColor(.secondary).frame(maxWidth: .infinity).padding()
            } else {
                chapterHeader
                let displayed = reverseChapterList
                    ? Array(chapterCache.displayChapters.reversed())
                    : chapterCache.displayChapters
                let snapshot = ReaderExtensionChapterProgressSnapshot(progress: progressManager.progress(for: stableID))
                LazyVStack(spacing: 0) {
                    ForEach(Array(displayed.enumerated()), id: \.element.id) { index, chapter in
                        chapterRow(
                            chapter,
                            snapshot: snapshot,
                            displayedChapters: displayed,
                            displayIndex: index
                        )
                        Divider()
                    }
                }
            }
        }
        .padding(.horizontal, isIPad ? 32 : 16)
    }

    private var chapterHeader: some View {
        HStack {
            Text(sourceName).font(.headline).lineLimit(1)
            Spacer()
            Text("\(chapterCache.displayChapters.count) Chapters").font(.subheadline).foregroundColor(.secondary)
            Button {
                downloadManager.enqueueChapters(
                    route: route, mangaId: stableID, title: item.title, coverURL: metadataCoverURL,
                    sourceName: sourceName, format: format, chapters: chapterCache.displayChapters,
                    contentRating: contentRating, kanzen: kanzen
                )
            } label: { Image(systemName: "arrow.down.circle") }
            .accessibilityLabel("Download All")
            Button { reverseChapterList.toggle() } label: { Image(systemName: "arrow.up.arrow.down") }
        }
    }

    private func chapterRow(
        _ chapter: Chapter,
        snapshot: ReaderExtensionChapterProgressSnapshot,
        displayedChapters: [Chapter],
        displayIndex: Int
    ) -> some View {
        let isRead = snapshot.isRead(chapter.chapterNumber)
        let downloadID = ReaderDownloadManager.downloadId(route: route, chapterNumber: chapter.chapterNumber)
        let download = downloadManager.downloads.first(where: { $0.id == downloadID })
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(chapter.chapterNumber).font(.subheadline.weight(.semibold))
                if let group = chapter.chapterData?.first?.scanlationGroup, !group.isEmpty {
                    Text(group).font(.caption2).foregroundColor(.accentColor)
                }
                if !isRead, let label = snapshot.pageProgressLabel(chapter.chapterNumber) {
                    Text(label).font(.caption2).foregroundColor(.secondary)
                }
                if let download, [.queued, .downloading, .paused].contains(download.status) {
                    ProgressView(value: download.progress).frame(maxWidth: 180)
                }
            }
            Spacer()
            if download?.status == .completed { Image(systemName: "arrow.down.circle.fill").foregroundColor(.green) }
            if isRead { Text("Read").font(.caption2).foregroundColor(.secondary) }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .opacity(isRead ? 0.62 : 1)
        .onTapGesture { selectedChapter = chapter }
        .contextMenu {
            Button {
                if isRead {
                    progressManager.markChapterUnread(mangaId: stableID, chapterNumber: chapter.chapterNumber)
                } else {
                    progressManager.markChapterRead(
                        mangaId: stableID, chapterNumber: chapter.chapterNumber, mangaTitle: item.title,
                        coverURL: metadataCoverURL, format: format, totalChapters: latestChapterNumbers?.count,
                        latestChapterNumbers: latestChapterNumbers, route: route
                    )
                }
            } label: { Label(isRead ? "Mark as Unread" : "Mark as Read", systemImage: isRead ? "eye.slash" : "eye") }

            Divider()

            Button {
                markChaptersRead(Array(displayedChapters.prefix(displayIndex + 1)))
            } label: {
                Label("Mark Above as Read", systemImage: "arrow.up.circle")
            }

            Button {
                markChaptersRead(Array(displayedChapters.suffix(displayedChapters.count - displayIndex)))
            } label: {
                Label("Mark Below as Read", systemImage: "arrow.down.circle")
            }

            Button {
                markChaptersRead(chapterCache.readerChapters)
            } label: {
                Label("Mark All as Read", systemImage: "checkmark.circle.fill")
            }

            Button(role: .destructive) {
                progressManager.markAllUnread(mangaId: stableID)
            } label: {
                Label("Mark All as Unread", systemImage: "xmark.circle")
            }

            Divider()

            if download?.status == .completed {
                Button(role: .destructive) { downloadManager.removeDownload(id: downloadID) } label: {
                    Label("Remove Download", systemImage: "trash")
                }
            } else if download?.status == .queued || download?.status == .downloading || download?.status == .paused {
                Button(role: .destructive) { downloadManager.cancelDownload(id: downloadID) } label: {
                    Label("Cancel Download", systemImage: "xmark.circle")
                }
            } else {
                Button {
                    downloadManager.enqueueChapter(
                        route: route, mangaId: stableID, title: item.title, coverURL: metadataCoverURL,
                        sourceName: sourceName, format: format, chapter: chapter,
                        contentRating: contentRating, kanzen: kanzen
                    )
                } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
        }
    }

    private func markChaptersRead(_ chapters: [Chapter]) {
        progressManager.markAllRead(
            mangaId: stableID,
            chapterNumbers: chapters.map(\.chapterNumber),
            mangaTitle: item.title,
            coverURL: metadataCoverURL,
            format: format,
            totalChapters: latestChapterNumbers?.count,
            latestChapterNumbers: latestChapterNumbers,
            route: route
        )
    }

    @MainActor
    private func loadDetails(force: Bool) async {
        guard force || chapterCache.displayChapters.isEmpty else { return }
        guard let source, source.enabled else {
            errorMessage = source == nil ? "This Reader Extension is missing." : "This Reader Extension is disabled."
            return
        }
        isLoading = true
        errorMessage = nil
        let owner = ProfileManager.shared.activeProfileID
        do {
            let provider = try sourceManager.provider(for: sourceID)
            let updated: ReaderExtensionItem
            if force || !initialItemHasDetails {
                let detail = try await provider.detail(itemKey: item.key)
                guard ProfileManager.shared.isStillActive(owner) else {
                    isLoading = false
                    return
                }
                updated = item.mergingDetail(detail)
            } else {
                updated = item
            }
            let chapters = try await provider.chapters(itemKey: updated.key)
            guard ProfileManager.shared.isStillActive(owner) else {
                isLoading = false
                return
            }
            guard contentFilter.allows(updated) else {
                throw ReaderExtensionError.resultInvalid("Not available on this profile")
            }
            let cache = ReaderExtensionDetailChapterCache.make(
                sourceID: sourceID, mediaType: source.mediaType, item: updated, chapters: chapters
            )
            guard ProfileManager.shared.isStillActive(owner) else {
                isLoading = false
                return
            }
            item = updated
            chapterCache = cache
            libraryManager.updateSavedItem(libraryItem)
            progressManager.updateSourceMetadata(
                mangaId: stableID, title: updated.title,
                coverURL: ReaderExtensionSafeMetadata.sanitizedURLString(updated.coverURL),
                format: format, latestChapterNumbers: cache.latestChapterNumbers ?? [], route: route,
                sourceRefreshError: nil
            )
        } catch {
            guard ProfileManager.shared.isStillActive(owner) else {
                isLoading = false
                return
            }
            errorMessage = error.localizedDescription
            ReaderExtensionDiagnostics.recordFailure(
                context: ReaderExtensionDiagnosticContext(source: source),
                operation: "detail-screen",
                error: error,
                type: ReaderExtensionDiagnostics.runtimeType
            )
        }
        isLoading = false
    }

    private func statusTitle(_ status: ReaderExtensionPublicationStatus) -> String {
        switch status {
        case .ongoing: return "Ongoing"
        case .completed: return "Completed"
        case .hiatus: return "Hiatus"
        case .cancelled: return "Cancelled"
        case .finished: return "Completed"
        case .unknown: return "Unknown"
        }
    }

    private func cleanedDescription(_ value: String) -> String {
        value.replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}

/// Read-only landing page for permanently retained legacy Aidoku identities.
struct LegacyReaderSourceUnavailableView: View {
    let title: String
    let message: String

    var body: some View {
        MangaSourceRepairView(title: title, message: message, actionTitle: "Reader Sources")
    }
}

struct MangaSourceRepairView: View {
    let title: String
    let message: String
    let actionTitle: String
    var action: (() -> Void)?

    init(title: String, message: String, actionTitle: String = "Reader Sources", action: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox").font(.system(size: 42)).foregroundColor(.secondary)
            Text(title).font(.headline).multilineTextAlignment(.center)
            Text(message).font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
            if let action {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent)
            } else {
                NavigationLink(destination: ReaderExtensionsSettingsView()) {
                    Label(actionTitle, systemImage: "slider.horizontal.3")
                }.buttonStyle(.borderedProminent)
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
        if let raw = sourceURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            items = [url]
        } else {
            items = [[title, sourceName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")]
        }
    }
}

extension View {
    @ViewBuilder
    func readerDetailIconButton() -> some View {
        if ExperimentalFeatureState.isEnabledAtLaunch {
            self.buttonStyle(ReaderDetailIconButtonStyle())
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

private struct ReaderDetailIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(width: 48, height: 48)
            .foregroundColor(.primary)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(configuration.isPressed ? 0.18 : 0.10)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.14)))
    }
}
#endif
