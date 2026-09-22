#if os(macOS)
import AppKit
import SwiftUI

struct MacReaderDetailView: View {
    @State var item: MangaLibraryItem
    let seed: ReaderExtensionItem?
    @ObservedObject var session: MacReaderSession
    let back: () -> Void
    var trackerReaderMatch: TrackerReaderMatch? = nil
    @Environment(\.macReaderIsActive) private var isActive
    @StateObject private var engine = KanzenEngine()
    @StateObject private var sourceFinder = MangaSourceFinder()
    @ObservedObject private var library = MangaLibraryManager.shared
    @ObservedObject private var progress = MangaReadingProgressManager.shared
    @ObservedObject private var downloads = ReaderDownloadManager.shared
    @State private var groups: [Chapters] = []
    @State private var language = ""
    @State private var reverse = true
    @State private var unreadOnly = false
    @State private var summary = ""
    @State private var tags: [String] = []
    @State private var creators = ""
    @State private var sourceURL: URL?
    @State private var selectedChapters = Set<String>()
    @State private var selecting = false
    @AppStorage(ReaderDetailElement.orderStorageKey) private var elementOrder = ReaderDetailElement.defaultOrderRawValue
    @AppStorage(ReaderDetailElement.hiddenStorageKey) private var hiddenElements = ""
    @State private var error: String?
    @State private var showingCollections = false
    @State private var loading = true
    @State private var reload = UUID()
    @State private var needsLoad = true
    @State private var detailsAuthority: ProgressManager.ProfileMutationAuthority?
    private var chapters: [Chapter] { groups.first(where: { $0.language == language })?.chapters ?? groups.first?.chapters ?? [] }
    private var readKeys: Set<String> { progress.normalizedReadChapterKeys(for: item.id) }
    private var visible: [Chapter] {
        let values = unreadOnly ? chapters.filter { !readKeys.contains(ChapterIdentityNormalizer.key(for: $0.chapterNumber)) } : chapters
        return reverse ? values.reversed() : values
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: back) { Label("Back", systemImage: "chevron.left") }
                Spacer()
                if let sourceURL { ShareLink(item: sourceURL) } else { ShareLink(item: [item.title, item.sourceName].compactMap { $0 }.joined(separator: "\n")) }
                Button { needsLoad = true; reload = UUID() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh title")
                Button { library.toggleBookmark(item) } label: { Image(systemName: library.isBookmarked(item) ? "bookmark.fill" : "bookmark") }.help("Bookmark title")
                Button("Collections") { showingCollections = true }
            }.padding()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 24) {
                        MacReaderPoster(title: "", url: item.coverURL, sourceID: item.route?.readerExtensionSourceID)
                        VStack(alignment: .leading, spacing: 14) {
                            Text(item.title).font(.largeTitle.bold()).textSelection(.enabled)
                            Text(item.sourceName ?? item.format ?? "Reader").foregroundStyle(.secondary)
                            if !creators.isEmpty { Text(creators).foregroundStyle(.secondary) }
                            if let chapter = resumeChapter {
                                Button { session.open(item: item, chapters: chapters, selected: chapter, engine: engine) } label: { Label("Continue Reading", systemImage: "book.pages") }.buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    if loading { ProgressView("Loading chapters…") }
                    if let error { Text(error).foregroundStyle(.secondary) }
                    if item.route == nil, item.id >= 0 {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Available Sources").font(.title2.bold())
                            if sourceFinder.isSearching { ProgressView("Searching installed modules…") }
                            else if sourceFinder.hasFinished, sourceFinder.matches.isEmpty { Text("No matching installed source was found.").foregroundStyle(.secondary) }
                            ForEach(sourceFinder.matches) { match in
                                Button { selectSource(match) } label: {
                                    HStack { VStack(alignment: .leading) { Text(match.manga.title).font(.headline); Text(match.module.moduleData.sourceName).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right") }.padding(12).contentShape(Rectangle())
                                }.buttonStyle(.plain).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                    ForEach(ReaderDetailElement.orderedElements(from: elementOrder).filter { ReaderDetailElement.isVisible($0, hiddenRawValue: hiddenElements) }) { element in
                        switch element {
                        case .overview: if !summary.isEmpty { Text(summary).textSelection(.enabled) }
                        case .tags: if !tags.isEmpty { ScrollView(.horizontal) { HStack { ForEach(tags, id: \.self) { Text($0).font(.caption).padding(8).background(.quaternary, in: Capsule()) } } } }
                        case .ratingNotes: ReaderRatingNotesView(itemId: item.id, title: item.title, routeKey: item.route?.stableKey, knownAniListId: item.trackerAniListId ?? progress.progress(for: item.id)?.trackerAniListId, knownMALId: item.trackerMALId ?? progress.progress(for: item.id)?.trackerMALId, totalChapters: item.totalChapters, format: item.format)
                        case .chapters: chapterSection
                        }
                    }
                }.padding(24).frame(maxWidth: 1300, alignment: .leading).frame(maxWidth: .infinity)
            }
        }.task(id: "\(isActive):\(reload)") {
            guard isActive else { return }
            if needsLoad {
                await load()
                if !Task.isCancelled { needsLoad = false }
            } else { detailsAuthority = ProgressManager.shared.profileMutationAuthority(requiredOwner: session.owner) }
        }
        .sheet(isPresented: $showingCollections) { MacReaderCollectionSheet(item: item) }
        .onChange(of: language) { _ in selectedChapters = [] }
        .onDisappear { needsLoad = needsLoad || loading || sourceFinder.isSearching; sourceFinder.cancel(keepResults: true); detailsAuthority = nil }
        .onChange(of: isActive) { active in
            if !active {
                needsLoad = needsLoad || loading || sourceFinder.isSearching
                sourceFinder.cancel(keepResults: true)
                detailsAuthority = nil
                loading = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in sourceFinder.cancel(); detailsAuthority = nil }
        .alert("Reader Downloads", isPresented: Binding(get: { downloads.enqueueErrorMessage != nil }, set: { if !$0 { downloads.clearEnqueueError() } })) { Button("OK") { downloads.clearEnqueueError() } } message: { Text(downloads.enqueueErrorMessage ?? "") }
    }

    private var chapterSection: some View {
        VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Chapters · \(chapters.count)").font(.title2.bold())
                        if groups.count > 1 { Picker("Language", selection: $language) { ForEach(groups) { Text($0.language).tag($0.language) } }.frame(width: 180) }
                        Spacer()
                        Toggle("Select", isOn: $selecting).toggleStyle(.checkbox)
                        Toggle("Unread", isOn: $unreadOnly).toggleStyle(.checkbox)
                        Button { reverse.toggle() } label: { Image(systemName: "arrow.up.arrow.down") }.help("Reverse chapter order")
                        Menu("Manage") {
                            if !selectedChapters.isEmpty {
                                Button("Download Selected") { download(chapters.filter { selectedChapters.contains($0.chapterNumber) }) }
                                Button("Mark Selected Read") { for chapter in chapters where selectedChapters.contains(chapter.chapterNumber) { progress.markChapterRead(mangaId: item.id, chapterNumber: chapter.chapterNumber, mangaTitle: item.title, coverURL: item.coverURL, format: item.format, totalChapters: chapters.count, route: item.route) } }
                                Button("Mark Selected Unread") { for chapter in chapters where selectedChapters.contains(chapter.chapterNumber) { progress.markChapterUnread(mangaId: item.id, chapterNumber: chapter.chapterNumber) } }
                                Divider()
                            }
                            Button("Download Next 5 Unread") { download(Array(chapters.filter { !readKeys.contains(ChapterIdentityNormalizer.key(for: $0.chapterNumber)) }.prefix(5))) }
                            Button("Mark All Read") { progress.markAllRead(mangaId: item.id, chapterNumbers: chapters.map(\.chapterNumber), mangaTitle: item.title, coverURL: item.coverURL, format: item.format, totalChapters: chapters.count, latestChapterNumbers: chapters.map(\.chapterNumber), route: item.route, trackerAniListId: item.trackerAniListId, trackerMALId: item.trackerMALId) }
                            Button("Mark All Unread") { progress.markAllUnread(mangaId: item.id) }
                            Divider()
                            Button("Download Unread Chapters") { download(chapters.filter { !readKeys.contains(ChapterIdentityNormalizer.key(for: $0.chapterNumber)) }) }
                            Button("Download All Chapters") { download(chapters) }
                        }.disabled(chapters.isEmpty)
                    }
                    LazyVStack(spacing: 1) {
                        ForEach(visible) { chapter in
                            HStack {
                                if selecting { Toggle("Select \(chapter.chapterNumber)", isOn: Binding(get: { selectedChapters.contains(chapter.chapterNumber) }, set: { value in if value { selectedChapters.insert(chapter.chapterNumber) } else { selectedChapters.remove(chapter.chapterNumber) } })).labelsHidden().toggleStyle(.checkbox).padding(.leading, 10) }
                                Button { session.open(item: item, chapters: chapters, selected: chapter, engine: engine) } label: {
                                    HStack { Image(systemName: readKeys.contains(ChapterIdentityNormalizer.key(for: chapter.chapterNumber)) ? "checkmark.circle.fill" : "circle"); Text(chapter.chapterNumber); Spacer(); if let group = chapter.chapterData?.first?.scanlationGroup, !group.isEmpty { Text(group).foregroundStyle(.secondary) } }.padding(12).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                if let route = item.route, let downloaded = downloads.chapters(for: route).first(where: { $0.chapterKey == ChapterIdentityNormalizer.key(for: chapter.chapterNumber) }) {
                                    Image(systemName: downloaded.status == .completed ? "arrow.down.circle.fill" : "arrow.down.circle").help(downloaded.status.rawValue)
                                }
                                Button { download([chapter]) } label: { Image(systemName: "arrow.down") }.buttonStyle(.borderless).help("Download chapter")
                            }
                            .background(Color.primary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 8))
                            .contextMenu {
                                Button("Read") { session.open(item: item, chapters: chapters, selected: chapter, engine: engine) }
                                if readKeys.contains(ChapterIdentityNormalizer.key(for: chapter.chapterNumber)) { Button("Mark Unread") { progress.markChapterUnread(mangaId: item.id, chapterNumber: chapter.chapterNumber) } }
                                else { Button("Mark Read") { progress.markChapterRead(mangaId: item.id, chapterNumber: chapter.chapterNumber, mangaTitle: item.title, coverURL: item.coverURL, format: item.format, totalChapters: chapters.count, latestChapterNumbers: chapters.map(\.chapterNumber), route: item.route, trackerAniListId: item.trackerAniListId, trackerMALId: item.trackerMALId) } }
                                Button("Mark Above as Read") { markRead(MacReaderChapterRangePolicy.chapters(in: visible, including: chapter, direction: .above)) }
                                Button("Mark Below as Read") { markRead(MacReaderChapterRangePolicy.chapters(in: visible, including: chapter, direction: .below)) }
                                Button("Download") { download([chapter]) }
                            }
                        }
                    }
        }
    }

    private var resumeChapter: Chapter? {
        let saved = progress.lastReadChapter(for: item.id)
        return chapters.first(where: { ChapterIdentityNormalizer.key(for: $0.chapterNumber) == ChapterIdentityNormalizer.key(for: saved ?? "") && !readKeys.contains(ChapterIdentityNormalizer.key(for: $0.chapterNumber)) }) ?? chapters.first(where: { !readKeys.contains(ChapterIdentityNormalizer.key(for: $0.chapterNumber)) }) ?? chapters.first
    }

    private func markRead(_ values: [Chapter]) {
        let owner = ProfileManager.shared.activeProfileID
        guard isActive, !MacLaunchProfileAccess.requiresUnlock, !MacLaunchProfileAccess.isTerminating,
              let authority = ProgressManager.shared.profileMutationAuthority(requiredOwner: owner),
              ProgressManager.shared.profileMutationAuthorityIsCurrent(authority) else { return }
        for chapter in values {
            progress.markChapterRead(mangaId: item.id, chapterNumber: chapter.chapterNumber, mangaTitle: item.title, coverURL: item.coverURL, format: item.format, totalChapters: chapters.count, latestChapterNumbers: chapters.map(\.chapterNumber), route: item.route, trackerAniListId: item.trackerAniListId, trackerMALId: item.trackerMALId, forProfile: owner)
        }
    }

    private func download(_ values: [Chapter]) {
        guard isActive, let route = item.route else { return }
        downloads.enqueueChapters(route: route, mangaId: item.id, title: item.title, coverURL: item.coverURL, sourceName: item.sourceName, format: item.format, chapters: values, contentRating: item.contentRating, kanzen: engine)
    }

    @MainActor
    private func load() async {
        guard isActive else { return }
        loading = true
        error = nil
        let owner = ProfileManager.shared.activeProfileID
        guard let authority = ProgressManager.shared.profileMutationAuthority(requiredOwner: owner) else { loading = false; return }
        detailsAuthority = authority
        defer { if !Task.isCancelled { loading = false } }
        if item.route == nil, let moduleID = item.moduleUUID, let params = item.contentParams { item.route = .legacyModule(moduleUUID: moduleID, contentParams: params, isNovel: item.isNovel ?? false) }
        if item.route == nil, item.id >= 0 {
            await loadMetadata(authority: authority)
            return
        }
        guard ReaderContentFilter.shared.allows(libraryItem: item), let route = item.route else { error = "This title is unavailable in this profile."; return }
        if let trackerReaderMatch, trackerReaderMatch.isCurrent, groups.isEmpty,
           let preloadedGroups = trackerReaderMatch.preloadedChapterGroups {
            if let module = trackerReaderMatch.source.module {
                do {
                    let script = try ModuleManager.shared.getModuleScript(module: module)
                    try await engine.loadScript(script, module: module)
                    try Task.checkCancellation()
                    guard trackerReaderMatch.isCurrent else { return }
                } catch {
                    self.error = "The Reader source could not be loaded. Try refreshing this title."
                    return
                }
            }
            groups = preloadedGroups
            language = groups.first?.language ?? ""
            item.latestChapterNumbers = ChapterIdentityNormalizer.deduplicatedNumbers(groups.first?.chapters.map(\.chapterNumber) ?? [])
            summary = trackerReaderMatch.seed?.description ?? trackerReaderMatch.legacyDetails?["description"] as? String ?? ""
            tags = trackerReaderMatch.seed?.tags ?? trackerReaderMatch.legacyDetails?["tags"] as? [String] ?? []
            creators = [trackerReaderMatch.seed?.author, trackerReaderMatch.seed?.artist].compactMap { $0 }.joined(separator: ", ")
            sourceURL = ReaderExtensionSafeMetadata.sanitizedURL(trackerReaderMatch.seed?.url)
            return
        }
        do {
            var next: [Chapters]
            switch route {
            case .readerExtension(let sourceID, let key, _):
                let provider = try ReaderExtensionManager.shared.provider(for: sourceID, allowsAutomaticBrowserVerification: true)
                let detail = try await provider.detail(itemKey: key).merging(seed: seed)
                try Task.checkCancellation()
                guard ReaderContentFilter.shared.allows(detail) else { throw ReaderExtensionError.resultInvalid("This title is unavailable in this profile.") }
                let sourceChapters = try await provider.chapters(itemKey: key)
                let chapterCache = ReaderExtensionDetailChapterCache.make(sourceID: sourceID, mediaType: provider.source.mediaType, item: detail, chapters: sourceChapters)
                next = [Chapters(language: provider.source.language, chapters: chapterCache.readerChapters)]
                try Task.checkCancellation()
                guard ProgressManager.shared.profileMutationAuthorityIsCurrent(authority) else { return }
                item.title = detail.title
                item.coverURL = detail.coverURL?.absoluteString ?? item.coverURL
                item.contentRating = ReaderContentFilter.shared.derivedReaderExtensionRating(for: detail)
                item.format = provider.source.mediaType == .novel ? "NOVEL" : "MANGA"
                summary = detail.description ?? ""
                tags = detail.tags
                creators = Array(Set([detail.author, detail.artist].compactMap { $0 }.filter { !$0.isEmpty })).sorted().joined(separator: ", ")
                sourceURL = ReaderExtensionSafeMetadata.sanitizedURL(detail.url)
            case .legacyModule(let moduleID, let params, _):
                guard let uuid = UUID(uuidString: moduleID), let module = ModuleManager.shared.getModule(uuid) else { throw ReaderExtensionError.resultInvalid("The original source is unavailable.") }
                let script = try ModuleManager.shared.getModuleScript(module: module)
                try await engine.loadScript(script, module: module)
                try Task.checkCancellation()
                let result = try await engine.extractChapters(params: params)
                let snapshot = await LegacyReaderChapterSnapshot.prepare(Self.legacyChapters(result))
                try Task.checkCancellation()
                next = snapshot.groups.map { Chapters(language: $0.original.language, chapters: $0.readerChapters) }
                if let detail = try await engine.extractDetails(params: params) {
                    try Task.checkCancellation()
                    guard ProgressManager.shared.profileMutationAuthorityIsCurrent(authority) else { return }
                    summary = detail["description"] as? String ?? detail["synopsis"] as? String ?? ""
                    tags = detail["tags"] as? [String] ?? []
                }
            case .aidoku:
                next = []
                error = "The original Aidoku source is unavailable. Completed downloads remain readable."
            }
            try Task.checkCancellation()
            guard ProgressManager.shared.profileMutationAuthorityIsCurrent(authority) else { return }
            if next.allSatisfy({ $0.chapters.isEmpty }) { next = offlineGroups(route) }
            groups = next
            language = next.first?.language ?? ""
            if !next.isEmpty {
                item.latestChapterNumbers = ChapterIdentityNormalizer.deduplicatedNumbers(next.flatMap { $0.chapters.map(\.chapterNumber) })
                item.totalChapters = item.latestChapterNumbers?.count
                library.updateSavedItem(item)
                progress.updateSourceMetadata(mangaId: item.id, title: item.title, coverURL: item.coverURL, format: item.format, latestChapterNumbers: item.latestChapterNumbers ?? [], route: route, sourceRefreshError: nil, forProfile: owner)
            }
        } catch {
            guard !Task.isCancelled, ProgressManager.shared.profileMutationAuthorityIsCurrent(authority) else { return }
            self.error = error.localizedDescription
            groups = offlineGroups(route)
            language = groups.first?.language ?? ""
        }
    }

    @MainActor
    private func loadMetadata(authority: ProgressManager.ProfileMutationAuthority) async {
        guard ReaderContentFilter.shared.allows(libraryItem: item) else { error = "This title is unavailable in this profile."; return }
        let fallback = AniListManga(id: item.id, title: .init(romaji: item.title, english: nil, native: nil), chapters: item.totalChapters, volumes: nil, status: nil, coverImage: item.coverURL.map { .init(large: $0, medium: nil) }, format: item.format, description: nil, genres: nil, averageScore: nil, countryOfOrigin: nil, startDate: nil)
        let manga = (try? await AniListMangaService.shared.fetchMangaDetail(id: item.id)) ?? fallback
        guard !Task.isCancelled, ProgressManager.shared.profileMutationAuthorityIsCurrent(authority) else { return }
        guard ReaderContentFilter.shared.allowsLegacy(title: manga.displayTitle, tags: manga.genres, description: manga.description) else { error = "This title is unavailable in this profile."; return }
        item.title = manga.displayTitle
        item.coverURL = manga.coverURL ?? item.coverURL
        item.contentRating = ReaderContentFilter.shared.derivedLegacyRating(tags: manga.genres, description: manga.description)
        summary = manga.description ?? ""
        tags = manga.genres ?? []
        sourceURL = URL(string: "https://anilist.co/manga/\(manga.id)")
        sourceFinder.searchAllModules(for: manga)
    }

    private func selectSource(_ match: SourceMatch) {
        guard isActive, let detailsAuthority, ProgressManager.shared.profileMutationAuthorityIsCurrent(detailsAuthority) else { return }
        let trackerID = item.trackerAniListId ?? (item.id > 0 ? item.id : nil)
        var replacement = MangaLibraryItem.fromModule(moduleId: match.module.id, contentId: match.manga.mangaId, title: match.manga.title.isEmpty ? item.title : match.manga.title, coverURL: match.manga.imageURL.isEmpty ? item.coverURL : match.manga.imageURL, isNovel: match.module.moduleData.novel == true, sourceName: match.module.moduleData.sourceName, contentRating: item.contentRating)
        replacement.trackerAniListId = trackerID
        replacement.trackerMALId = item.trackerMALId
        item = replacement
        sourceFinder.cancel()
        needsLoad = true
        reload = UUID()
    }

    private func offlineGroups(_ route: MangaContentRoute) -> [Chapters] {
        let items = downloads.downloads.filter { $0.routeKey == route.stableKey && $0.status == .completed }.sorted { ChapterIdentityNormalizer.numericValue(in: $0.chapterNumber) ?? 0 < ChapterIdentityNormalizer.numericValue(in: $1.chapterNumber) ?? 0 }
        guard !items.isEmpty else { return [] }
        return [Chapters(language: "Downloaded", chapters: items.enumerated().map { Chapter(chapterNumber: $0.element.chapterNumber, idx: $0.offset, chapterData: nil) })]
    }

    private static func legacyChapters(_ result: Any?) -> [Chapters] {
        if let dictionary = result as? [String: Any] {
            return dictionary.keys.sorted().compactMap { key in
                guard let rows = dictionary[key] as? [Any] else { return nil }
                let chapters = rows.enumerated().compactMap { index, value -> Chapter? in
                    guard let row = value as? [Any], row.count >= 2, let number = row[0] as? String, let data = row[1] as? [[String: Any]] else { return nil }
                    return Chapter(chapterNumber: number, idx: index, chapterData: data.compactMap(ChapterData.init(dict:)))
                }
                return Chapters(language: key, chapters: ChapterIdentityNormalizer.deduplicatedChapters(chapters, reindex: true))
            }
        }
        guard let rows = result as? [[String: Any]] else { return [] }
        let chapters = rows.enumerated().compactMap { index, row -> Chapter? in
            guard let data = ChapterData(dict: row) else { return nil }
            let name = (row["number"] as? Int).map { "Chapter \($0)" } ?? row["title"] as? String ?? "Chapter \(index + 1)"
            return Chapter(chapterNumber: name, idx: index, chapterData: [data])
        }
        return [Chapters(language: "default", chapters: ChapterIdentityNormalizer.deduplicatedChapters(chapters, reindex: true))]
    }
}
#endif
