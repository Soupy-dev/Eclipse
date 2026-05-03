//
//  MangaDetailView.swift
//  Kanzen
//
//  Created by Luna on 2025.
//

import SwiftUI
import Kingfisher

#if !os(tvOS)
struct MangaDetailView: View {
    let initialManga: AniListManga
    @EnvironmentObject var moduleManager: ModuleManager
    @StateObject private var sourceFinder = MangaSourceFinder()
    @ObservedObject private var libraryManager = MangaLibraryManager.shared
    @ObservedObject private var progressManager = MangaReadingProgressManager.shared
    @AppStorage("kanzenAutoMode") private var autoModeEnabled: Bool = false

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
    @State private var scrollOffset: CGFloat = 0

    // Source / chapter state
    @State private var selectedSource: SourceMatch?
    @State private var chapterEngine = KanzenEngine()
    @State private var loadingChapters: Bool = false
    @State private var loadedChapters: [Chapters]?
    @State private var chapterLanguageIdx: Int = 0
    @State private var reverseChapters: Bool = false
    @State private var selectedChapterData: Chapter?
    @State private var chapterLoadError: String?

    private let coverWidth: CGFloat = isIPad ? 150 * iPadScaleSmall : 150

    private var libraryItem: MangaLibraryItem {
        MangaLibraryItem(
            aniListId: manga.id,
            title: manga.displayTitle,
            coverURL: manga.coverURL,
            format: manga.format,
            totalChapters: manga.chapters
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection

                Divider()

                if let description = manga.description, !description.isEmpty {
                    descriptionSection(description)
                }

                Divider()

                if let genres = manga.genres, !genres.isEmpty {
                    genresSection(genres)
                }

                Divider()

                // Show chapters if a source was selected, otherwise show source picker
                if selectedSource != nil {
                    chaptersSection
                } else {
                    sourcesSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ScrollOffsetPreferenceKey.self,
                        value: -geo.frame(in: .named("mangaDetailScroll")).origin.y
                    )
                }
            )
        }
        .coordinateSpace(name: "mangaDetailScroll")
        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { scrollOffset = $0 }
        .navigationTitle(manga.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .kanzenGradientBackground(scrollOffset: scrollOffset)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showAddToCollection = true
                } label: {
                    Image(systemName: libraryManager.isBookmarked(libraryItem) ? "bookmark.fill" : "bookmark")
                }
            }
        }
        .sheet(isPresented: $showAddToCollection) {
            MangaAddToCollectionView(item: libraryItem)
                .environmentObject(libraryManager)
        }
        .fullScreenCover(item: $selectedChapterData, onDismiss: {
            // Mark the chapter that was just read
            if let chapter = selectedChapterData {
                progressManager.markChapterRead(
                    mangaId: manga.id,
                    chapterNumber: chapter.chapterNumber,
                    mangaTitle: manga.displayTitle,
                    coverURL: manga.coverURL
                )
            }
        }) { chapter in
            if let chapters = loadedChapters, chapterLanguageIdx < chapters.count {
                let chapterList = chapters[chapterLanguageIdx].chapters
                if selectedSource?.module.moduleData.novel == true {
                    NovelReaderView(
                        kanzen: chapterEngine,
                        chapters: chapterList,
                        initialChapter: chapter,
                        mangaId: manga.id,
                        mangaTitle: manga.displayTitle,
                        mangaCoverURL: manga.coverURL ?? ""
                    )
                } else {
                    readerManagerView(
                        chapters: chapterList,
                        selectedChapter: chapter,
                        kanzen: chapterEngine,
                        mangaId: manga.id,
                        mangaTitle: manga.displayTitle,
                        mangaCoverURL: manga.coverURL ?? ""
                    )
                }
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
        .onChange(of: sourceFinder.hasFinished) { finished in
            guard finished, autoModeEnabled else { return }
            sourceFinder.refineTopMatchesWithChapterCounts(for: manga)
        }
        .onChange(of: sourceFinder.autoPickedMatch?.id) { _ in
            guard autoModeEnabled, sourceFinder.hasFinished,
                  let pick = sourceFinder.autoPickedMatch else { return }
            // Auto mode: select the best source and load chapters inline
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                selectSource(pick)
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        HStack(alignment: .top, spacing: 14) {
            KFImage(URL(string: manga.coverURL ?? ""))
                .placeholder { ProgressView() }
                .resizable()
                .scaledToFill()
                .frame(width: coverWidth, height: coverWidth * 1.5)
                .clipped()
                .cornerRadius(16)

            VStack(alignment: .leading, spacing: 6) {
                Text(manga.displayTitle)
                    .font(.title2)
                    .fontWeight(.bold)
                    .lineLimit(3)

                if let format = manga.format {
                    Text(formatLabel(format))
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2))
                        .cornerRadius(4)
                }

                if let status = manga.status {
                    Label(statusLabel(status), systemImage: statusIcon(status))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                // Stats in a 2-column grid to avoid cramping
                statsGrid
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
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

        VStack(alignment: .leading, spacing: 4) {
            Text("Synopsis")
                .font(.headline)

            Text(cleaned)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(expandedDescription ? nil : 4)
                .onTapGesture {
                    withAnimation { expandedDescription.toggle() }
                }

            if !expandedDescription {
                Text("Show more")
                    .font(.caption)
                    .foregroundColor(.accentColor)
                    .onTapGesture {
                        withAnimation { expandedDescription.toggle() }
                    }
            }
        }
    }

    // MARK: - Genres

    @ViewBuilder
    private func genresSection(_ genres: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Genres")
                .font(.headline)

            if #available(iOS 16.0, macOS 13.0, *) {
                FlowLayout(spacing: 6) {
                    ForEach(genres, id: \.self) { genre in
                        genreTag(genre)
                    }
                }
            } else {
                wrappedGenres(genres)
            }
        }
    }

    @ViewBuilder
    private func genreTag(_ genre: String) -> some View {
        Text(genre)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.15))
            .cornerRadius(6)
    }

    @ViewBuilder
    private func wrappedGenres(_ genres: [String]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 6)], spacing: 6) {
            ForEach(genres, id: \.self) { genre in
                genreTag(genre)
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
                if autoModeEnabled {
                    Text("Auto Mode")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2))
                        .cornerRadius(4)
                }
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
                    ProgressView()
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
                    ProgressView()
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
        let displayed: [Chapter] = reverseChapters ? selected.chapters.reversed() : selected.chapters

        VStack(alignment: .leading, spacing: 0) {
            // Read / Continue button
            readButton(chapters: selected.chapters)
                .padding(.bottom, 8)

            HStack {
                Text("\(selected.chapters.count) Chapters")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(.accentColor)
                Spacer()

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

                Button {
                    reverseChapters.toggle()
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .foregroundColor(.accentColor)
                }
            }

            Divider().padding(.vertical, 4)

            ForEach(displayed) { chapter in
                let isRead = progressManager.isChapterRead(mangaId: manga.id, chapterNumber: chapter.chapterNumber)
                let chapterTitle = chapter.chapterData?.first?.title ?? ""

                Button {
                    selectedChapterData = chapter
                } label: {
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
                        }

                        Spacer(minLength: 8)

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
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if isRead {
                        Button {
                            progressManager.markChapterUnread(mangaId: manga.id, chapterNumber: chapter.chapterNumber)
                        } label: {
                            Label("Mark as Unread", systemImage: "eye.slash")
                        }
                    } else {
                        Button {
                            progressManager.markChapterRead(mangaId: manga.id, chapterNumber: chapter.chapterNumber, coverURL: manga.coverURL)
                        } label: {
                            Label("Mark as Read", systemImage: "eye")
                        }
                    }

                    Divider()

                    Button {
                        let allNums = selected.chapters.map { $0.chapterNumber }
                        if let idx = allNums.firstIndex(of: chapter.chapterNumber) {
                            let toMark = Array(allNums[...idx])
                            progressManager.markAllRead(mangaId: manga.id, chapterNumbers: toMark)
                        }
                    } label: {
                        Label("Mark This & Previous as Read", systemImage: "checkmark.circle")
                    }

                    Button {
                        let allNums = selected.chapters.map { $0.chapterNumber }
                        progressManager.markAllRead(mangaId: manga.id, chapterNumbers: allNums)
                    } label: {
                        Label("Mark All as Read", systemImage: "checkmark.circle.fill")
                    }

                    Button(role: .destructive) {
                        progressManager.markAllUnread(mangaId: manga.id)
                    } label: {
                        Label("Mark All as Unread", systemImage: "xmark.circle")
                    }
                }
                Divider()
            }
        }
    }

    // MARK: - Read / Continue Button

    @ViewBuilder
    private func readButton(chapters: [Chapter]) -> some View {
        let lastRead = progressManager.lastReadChapter(for: manga.id)
        let hasProgress = lastRead != nil

        // Find the chapter to resume/start
        let targetChapter: Chapter? = {
            if let lastRead = lastRead {
                // Find the last-read chapter so we resume in it
                if let ch = chapters.first(where: { $0.chapterNumber == lastRead }) {
                    return ch
                }
            }
            // No progress — start from first chapter
            return chapters.first
        }()

        if let target = targetChapter {
            Button {
                selectedChapterData = target
            } label: {
                HStack {
                    Image(systemName: hasProgress ? "book.fill" : "play.fill")
                        .font(.subheadline)
                    Text(hasProgress ? "Continue Reading" : "Start Reading")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundColor(.white)
                .background(Color.accentColor)
                .cornerRadius(16)
            }
            .buttonStyle(.plain)
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
            Logger.shared.log("MangaDetail.selectSource: loading module '\(match.module.moduleData.sourceName)', isNovel=\(isNovel)", type: "Debug")
            try engine.loadScript(script, isNovel: isNovel)
            Logger.shared.log("MangaDetail.selectSource: module loaded successfully", type: "Debug")
        } catch {
            loadingChapters = false
            chapterLoadError = "Failed to load module: \(error.localizedDescription)"
            return
        }

        // Store engine for the reader to use later
        chapterEngine = engine

        Logger.shared.log("MangaDetail.selectSource: calling extractChapters with mangaId='\(match.manga.mangaId)'", type: "Debug")
        engine.extractChapters(params: match.manga.mangaId) { result in
            DispatchQueue.main.async {
                Logger.shared.log("MangaDetail.selectSource: extractChapters returned type=\(type(of: result as Any)), isNil=\(result == nil)", type: "Debug")
                if let result = result {
                    var parsed: [Chapters] = []

                    if let dictResult = result as? [String: Any] {
                        Logger.shared.log("MangaDetail.selectSource: Kanzen format, keys=\(Array(dictResult.keys))", type: "Debug")
                        // Kanzen format: {language: [[chapterName, [{scanlation_group, id}]]]}
                        for (key, value) in dictResult {
                            var chapterList: [Chapter] = []
                            if let chapters = value as? [Any?] {
                                for (idx, chapter) in chapters.enumerated() {
                                    if let chapter = chapter as? [Any?],
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
                        Logger.shared.log("MangaDetail.selectSource: Sora format, \(arrResult.count) chapters", type: "Debug")
                        if let first = arrResult.first {
                            Logger.shared.log("MangaDetail.selectSource: first chapter keys=\(Array(first.keys)), values=\(first)", type: "Debug")
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

                    Logger.shared.log("MangaDetail.selectSource: parsed \(parsed.count) language groups, total chapters=\(parsed.reduce(0) { $0 + $1.chapters.count })", type: "Debug")
                    self.loadedChapters = parsed
                } else {
                    Logger.shared.log("MangaDetail.selectSource: result is not dict or array, actual type=\(type(of: result))", type: "Error")
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
