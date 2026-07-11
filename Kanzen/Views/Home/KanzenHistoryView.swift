import SwiftUI
import Kingfisher

#if !os(tvOS)
import AidokuRunner

struct KanzenHistoryView: View {
    @ObservedObject private var progressManager = MangaReadingProgressManager.shared
    @State private var scrollOffset: CGFloat = 0
    @State private var showClearHistoryConfirmation = false
    @State private var contextDetailItem: MangaLibraryItem?
    @State private var showContextDetail = false
    @State private var resumeRequest: KanzenHistoryResumeRequest?
    private var designMetrics: ExperimentalMediaDesignMetrics { .current }

    private var historyItems: [(id: Int, progress: MangaProgress)] {
        progressManager.recentlyReadMangaIds()
    }

    var body: some View {
        let experimental = ExperimentalFeatureState.isEnabledAtLaunch
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: experimental ? designMetrics.sectionSpacing : 12) {
                    KanzenRootHeader("History") {
                        if !historyItems.isEmpty {
                            Button("Clear History") {
                                showClearHistoryConfirmation = true
                            }
                            .font(.subheadline)
                            .foregroundColor(.red)
                            .accessibilityLabel("Clear History")
                        }
                    }
                        .padding(.horizontal, -16)

                    contextDetailLink

                    if historyItems.isEmpty {
                        emptyState
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 420)
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(historyItems, id: \.id) { item in
                                Button {
                                    resumeRequest = resumeRequest(for: item)
                                } label: {
                                    historyRow(for: item)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        contextDetailItem = libraryItem(for: item)
                                        showContextDetail = true
                                    } label: {
                                        Label("Open Details", systemImage: "info.circle")
                                    }

                                    Button(role: .destructive) {
                                        progressManager.removeFromHistory(mangaId: item.id)
                                    } label: {
                                        Label("Remove from History", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ScrollOffsetPreferenceKey.self,
                            value: -geo.frame(in: .named("kanzenHistoryScroll")).origin.y
                        )
                    }
                )
            }
            .coordinateSpace(name: "kanzenHistoryScroll")
            .onPreferenceChange(ScrollOffsetPreferenceKey.self) { scrollOffset = $0 }
            .background(GlobalGradientBackground(scrollOffset: scrollOffset).ignoresSafeArea())
            .alert("Clear History?", isPresented: $showClearHistoryConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Clear History", role: .destructive) {
                    progressManager.clearHistory()
                }
            } message: {
                Text("This removes entries from History without clearing read chapters or library items.")
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .fullScreenCover(item: $resumeRequest) { request in
            KanzenHistoryResumeDestination(
                mangaId: request.id,
                item: request.item,
                progress: request.progress
            )
        }
    }

    private var contextDetailLink: some View {
        NavigationLink(isActive: $showContextDetail) {
            if let contextDetailItem {
                MangaLibraryDestinationView(item: contextDetailItem)
            } else {
                EmptyView()
            }
        } label: {
            EmptyView()
        }
        .hidden()
        .frame(width: 0, height: 0)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No reading history")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Manga you read will appear here.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private func historyRow(for item: (id: Int, progress: MangaProgress)) -> some View {
        let experimental = ExperimentalFeatureState.isEnabledAtLaunch
        return HStack(spacing: experimental ? 14 : 12) {
            KFImage(URL(string: item.progress.coverURL ?? ""))
                .placeholder { Rectangle().fill(Color.gray.opacity(0.2)) }
                .resizable()
                .scaledToFill()
                .frame(width: experimental ? 62 : 50, height: experimental ? 92 : 75)
                .clipped()
                .cornerRadius(experimental ? min(designMetrics.cardRadius, 16) : 12)
                .overlay(alignment: .topTrailing) {
                    if ReaderDownloadManager.shared.isDownloaded(route: item.progress.route) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.white)
                            .padding(4)
                            .background(Color.black.opacity(0.65))
                            .clipShape(Circle())
                            .padding(3)
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.progress.title ?? "Unknown Manga")
                    .font(experimental ? .title3.weight(.semibold) : .headline)
                    .foregroundColor(experimental ? .white : .primary)
                    .lineLimit(2)

                if let lastCh = item.progress.lastReadChapter {
                    Text("Ch. \(lastCh)")
                        .font(.subheadline)
                        .foregroundColor(experimental ? .white.opacity(0.62) : .secondary)
                }

                if let date = item.progress.lastReadDate {
                    Text(date, style: .relative)
                        .font(.caption)
                        .foregroundColor(experimental ? .white.opacity(0.54) : .secondary)
                }
            }

            Spacer()
        }
        .padding(experimental ? 14 : 12)
        .background(
            RoundedRectangle(cornerRadius: experimental ? designMetrics.cardRadius : 12, style: .continuous)
                .fill(experimental ? Color.white.opacity(0.10) : EclipseTheme.shared.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: experimental ? designMetrics.cardRadius : 12, style: .continuous)
                .stroke(Color.white.opacity(experimental ? 0.14 : 0), lineWidth: 1)
        )
    }

    private func resumeRequest(for item: (id: Int, progress: MangaProgress)) -> KanzenHistoryResumeRequest {
        KanzenHistoryResumeRequest(
            id: item.id,
            item: libraryItem(for: item),
            progress: item.progress
        )
    }

    private func libraryItem(for item: (id: Int, progress: MangaProgress)) -> MangaLibraryItem {
        MangaLibraryItem(
            aniListId: item.id,
            title: item.progress.title ?? "Unknown Manga",
            coverURL: item.progress.coverURL,
            format: item.progress.format,
            totalChapters: item.progress.totalChapters,
            moduleUUID: item.progress.moduleUUID,
            contentParams: item.progress.contentParams,
            isNovel: item.progress.isNovel,
            route: item.progress.route,
            latestChapterNumbers: item.progress.latestChapterNumbers,
            lastSourceRefresh: item.progress.lastSourceRefresh,
            sourceRefreshError: item.progress.sourceRefreshError,
            trackerAniListId: item.progress.trackerAniListId,
            trackerMALId: item.progress.trackerMALId,
            trackerMatchConfidence: item.progress.trackerMatchConfidence,
            trackerResolvedAt: item.progress.trackerResolvedAt
        )
    }
}

private struct KanzenHistoryResumeRequest: Identifiable {
    let id: Int
    let item: MangaLibraryItem
    let progress: MangaProgress
}

private struct KanzenHistoryResumeDestination: View {
    @Environment(\.dismiss) private var dismiss

    let mangaId: Int
    let item: MangaLibraryItem
    let progress: MangaProgress

    @StateObject private var kanzen = KanzenEngine()
    @StateObject private var sourceManager = AidokuSourceManager.shared
    @State private var loadedReader: LoadedHistoryReader?
    @State private var downloadedFallback: ReaderDownloadedTitle?
    @State private var errorMessage: String?
    @State private var didStartLoading = false

    var body: some View {
        Group {
            if let loadedReader {
                readerManagerView(
                    chapters: loadedReader.chapters,
                    selectedChapter: loadedReader.selectedChapter,
                    kanzen: kanzen,
                    mangaId: mangaId,
                    mangaTitle: loadedReader.title,
                    mangaCoverURL: loadedReader.coverURL,
                    mangaRoute: loadedReader.route,
                    mangaFormat: loadedReader.format,
                    totalChapters: loadedReader.latestChapterNumbers?.count ?? item.totalChapters,
                    latestChapterNumbers: loadedReader.latestChapterNumbers,
                    trackerAniListId: progress.trackerAniListId ?? item.trackerAniListId,
                    trackerMALId: progress.trackerMALId ?? item.trackerMALId
                )
                .ignoresSafeArea()
                .navigationBarHidden(true)
            } else if let downloadedFallback {
                fallbackNavigation {
                    ReaderDownloadedTitleDetailView(title: downloadedFallback)
                }
            } else if let errorMessage {
                fallbackNavigation {
                    VStack(spacing: 14) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text(item.title)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        NavigationLink {
                            MangaLibraryDestinationView(item: item)
                        } label: {
                            Label("Open Details", systemImage: "info.circle")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                fallbackNavigation {
                    EclipseLoadingIndicator("Opening reader...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .task {
                            await load()
                        }
                }
            }
        }
    }

    @MainActor
    private func load() async {
        guard !didStartLoading else { return }
        didStartLoading = true

        guard let route = item.route ?? progress.route else {
            errorMessage = "This history item is missing its source route. Open details to repair it."
            return
        }

        if let downloaded = ReaderDownloadManager.shared.downloadedTitle(for: route),
           sourceUnavailable(for: route) {
            downloadedFallback = downloaded
            return
        }

        do {
            switch route {
            case .aidoku(let sourceId, let mangaKey):
                loadedReader = try await loadAidokuReader(sourceId: sourceId, mangaKey: mangaKey, route: route)
            case .legacyModule(let moduleUUID, let contentParams, let isNovel):
                loadedReader = try await loadLegacyReader(
                    moduleUUID: moduleUUID,
                    contentParams: contentParams,
                    isNovel: isNovel,
                    route: route
                )
            }
        } catch {
            if let downloaded = ReaderDownloadManager.shared.downloadedTitle(for: route) {
                downloadedFallback = downloaded
            } else {
                errorMessage = error.localizedDescription
                ReaderLogger.shared.log("History resume failed route=\(route.stableKey): \(error.localizedDescription)", type: "History")
            }
        }
    }

    @ViewBuilder
    private func fallbackNavigation<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NavigationView {
            content()
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Close") {
                            dismiss()
                        }
                    }
                }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    @MainActor
    private func loadAidokuReader(sourceId: String, mangaKey: String, route: MangaContentRoute) async throws -> LoadedHistoryReader {
        guard let metadata = sourceManager.metadata(id: sourceId) else {
            throw NSError(domain: "KanzenHistory", code: 1, userInfo: [NSLocalizedDescriptionKey: "This Aidoku source is missing."])
        }
        guard metadata.isEnabled else {
            throw NSError(domain: "KanzenHistory", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(metadata.name) is disabled."])
        }

        let seed = AidokuRunner.Manga(
            sourceKey: sourceId,
            key: mangaKey,
            title: item.title,
            cover: item.coverURL
        )
        let manga = try await sourceManager.mangaUpdate(
            sourceId: sourceId,
            manga: seed,
            needsDetails: true,
            needsChapters: true
        )
        let chapters = readerChapters(from: aidokuChapterModels(from: manga, sourceId: sourceId))
        guard !chapters.isEmpty else {
            throw NSError(domain: "KanzenHistory", code: 3, userInfo: [NSLocalizedDescriptionKey: "No chapters were found for this history item."])
        }

        let latestNumbers = ChapterIdentityNormalizer.deduplicatedNumbers(chapters.map(\.chapterNumber))
        return LoadedHistoryReader(
            title: manga.title,
            coverURL: manga.cover ?? item.coverURL ?? "",
            route: route,
            format: viewerFormat(manga.viewer),
            chapters: chapters,
            selectedChapter: selectedChapter(from: chapters),
            latestChapterNumbers: latestNumbers
        )
    }

    @MainActor
    private func loadLegacyReader(
        moduleUUID: String,
        contentParams: String,
        isNovel: Bool,
        route: MangaContentRoute
    ) async throws -> LoadedHistoryReader {
        guard let uuid = UUID(uuidString: moduleUUID),
              let module = ModuleManager.shared.getModule(uuid) else {
            throw NSError(domain: "KanzenHistory", code: 4, userInfo: [NSLocalizedDescriptionKey: "The legacy source module may have been removed."])
        }

        let content = try ModuleManager.shared.getModuleScript(module: module)
        try kanzen.loadScript(content, isNovel: isNovel)
        let result = try await extractLegacyChapters(params: contentParams)
        let groups = legacyChapterGroups(from: result)
        guard let selectedGroup = bestLegacyGroup(from: groups) else {
            throw NSError(domain: "KanzenHistory", code: 5, userInfo: [NSLocalizedDescriptionKey: "No chapters were found for this history item."])
        }

        let chapters = readerChapters(from: selectedGroup.chapters)
        guard !chapters.isEmpty else {
            throw NSError(domain: "KanzenHistory", code: 6, userInfo: [NSLocalizedDescriptionKey: "No readable chapters were found for this history item."])
        }

        let latestNumbers = ChapterIdentityNormalizer.deduplicatedNumbers(chapters.map(\.chapterNumber))
        return LoadedHistoryReader(
            title: item.title,
            coverURL: item.coverURL ?? "",
            route: route,
            format: isNovel ? "NOVEL" : (item.format ?? "MANGA"),
            chapters: chapters,
            selectedChapter: selectedChapter(from: chapters),
            latestChapterNumbers: latestNumbers
        )
    }

    private func sourceUnavailable(for route: MangaContentRoute) -> Bool {
        switch route {
        case .aidoku(let sourceId, _):
            guard let metadata = sourceManager.metadata(id: sourceId) else { return true }
            return !metadata.isEnabled
        case .legacyModule(let moduleUUID, _, _):
            guard let uuid = UUID(uuidString: moduleUUID) else { return true }
            return ModuleManager.shared.getModule(uuid) == nil
        }
    }

    private func selectedChapter(from chapters: [Chapter]) -> Chapter {
        guard let lastReadChapter = progress.lastReadChapter else {
            return chapters.first ?? Chapter(chapterNumber: "", idx: 0, chapterData: nil)
        }
        return chapters.first {
            $0.chapterNumber == lastReadChapter ||
            ChapterIdentityNormalizer.key(for: $0.chapterNumber) == ChapterIdentityNormalizer.key(for: lastReadChapter)
        } ?? chapters.first ?? Chapter(chapterNumber: lastReadChapter, idx: 0, chapterData: nil)
    }

    private func aidokuChapterModels(from manga: AidokuRunner.Manga, sourceId: String) -> [Chapter] {
        let chapters = (manga.chapters ?? []).enumerated().map { index, aidokuChapter in
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

    private func formatNumber(_ value: Float) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(value)
    }

    private func viewerFormat(_ viewer: AidokuRunner.Viewer) -> String {
        switch viewer {
        case .vertical, .webtoon:
            return "WEBTOON"
        default:
            return "MANGA"
        }
    }

    private func extractLegacyChapters(params: String) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            kanzen.extractChapters(params: params) { result in
                if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(
                        throwing: NSError(domain: "KanzenHistory", code: 7, userInfo: [NSLocalizedDescriptionKey: "The source did not return chapters."])
                    )
                }
            }
        }
    }

    private func legacyChapterGroups(from result: Any) -> [Chapters] {
        var groups: [Chapters] = []

        if let dictResult = result as? [String: Any] {
            for (key, value) in dictResult {
                var chapters: [Chapter] = []
                if let rawChapters = value as? [Any?] {
                    for (idx, rawChapter) in rawChapters.enumerated() {
                        guard let chapter = rawChapter as? [Any?],
                              let chapterName = chapter.first as? String,
                              chapter.count > 1,
                              let rawData = chapter[1] as? [[String: Any?]] else { continue }
                        let chapterData = rawData.compactMap { ChapterData(dict: $0 as [String: Any]) }
                        if !chapterData.isEmpty {
                            chapters.append(Chapter(chapterNumber: chapterName, idx: idx, chapterData: chapterData))
                        }
                    }
                }
                if !chapters.isEmpty {
                    groups.append(
                        Chapters(
                            language: key,
                            chapters: ChapterIdentityNormalizer.deduplicatedChapters(chapters, reindex: true)
                        )
                    )
                }
            }
        } else if let arrResult = result as? [[String: Any]] {
            var chapters: [Chapter] = []
            for (idx, chapterDict) in arrResult.enumerated() {
                let name = (chapterDict["number"] as? Int).map { "Chapter \($0)" }
                    ?? (chapterDict["title"] as? String)
                    ?? "Chapter \(idx + 1)"
                if let data = ChapterData(dict: chapterDict) {
                    chapters.append(Chapter(chapterNumber: name, idx: idx, chapterData: [data]))
                }
            }
            if !chapters.isEmpty {
                groups.append(
                    Chapters(
                        language: "default",
                        chapters: ChapterIdentityNormalizer.deduplicatedChapters(chapters, reindex: true)
                    )
                )
            }
        }

        return groups
    }

    private func bestLegacyGroup(from groups: [Chapters]) -> Chapters? {
        guard let lastReadChapter = progress.lastReadChapter else {
            return groups.max(by: { $0.chapters.count < $1.chapters.count })
        }
        return groups.first {
            $0.chapters.contains {
                $0.chapterNumber == lastReadChapter ||
                ChapterIdentityNormalizer.key(for: $0.chapterNumber) == ChapterIdentityNormalizer.key(for: lastReadChapter)
            }
        } ?? groups.max(by: { $0.chapters.count < $1.chapters.count })
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
}

private struct LoadedHistoryReader {
    let title: String
    let coverURL: String
    let route: MangaContentRoute
    let format: String?
    let chapters: [Chapter]
    let selectedChapter: Chapter
    let latestChapterNumbers: [String]?
}
#endif
