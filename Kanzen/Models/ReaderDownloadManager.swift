// Reader-only download queue and offline page store. This intentionally stays
// separate from media downloads so Kanzen state, logs, and storage do not mix.

#if !os(tvOS)
import AidokuRunner
import Combine
import Foundation
import SwiftUI
import UIKit

enum ReaderDownloadStatus: String, Codable {
    case none
    case queued
    case downloading
    case paused
    case completed
    case failed
}

struct ReaderDownloadProvider: Codable, Equatable {
    enum Kind: String, Codable {
        case aidoku
        case legacyModule
    }

    var kind: Kind
    var sourceId: String?
    var mangaKey: String?
    var moduleUUID: String?
    var contentParams: String?
    var isNovel: Bool
    var chapterParams: String?
}

struct ReaderDownloadItem: Codable, Identifiable, Equatable {
    let id: String
    let route: MangaContentRoute
    let routeKey: String
    let mangaId: Int
    let mangaTitle: String
    let coverURL: String?
    let sourceName: String?
    let format: String?
    let chapterNumber: String
    let chapterTitle: String?
    let chapterKey: String
    var provider: ReaderDownloadProvider
    var status: ReaderDownloadStatus
    var progress: Double
    var completedPages: Int
    var totalPages: Int
    var downloadedBytes: Int64
    var error: String?
    var dateAdded: Date
    var dateCompleted: Date?

    var isActive: Bool {
        status == .queued || status == .downloading || status == .paused
    }

    var displayChapterTitle: String {
        if let chapterTitle, !chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(chapterNumber) - \(chapterTitle)"
        }
        return chapterNumber
    }
}

struct ReaderDownloadedTitle: Identifiable, Equatable {
    let id: String
    let route: MangaContentRoute
    let mangaId: Int
    let title: String
    let coverURL: String?
    let sourceName: String?
    let format: String?
    let completedCount: Int
    let activeCount: Int
    let failedCount: Int
    let downloadedBytes: Int64
    let latestCompleted: Date?

    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: downloadedBytes)
    }
}

struct ReaderDownloadedChapterPayload {
    let route: MangaContentRoute
    let chapterNumber: String
}

private struct ReaderDownloadedPageManifest: Codable {
    enum PageKind: String, Codable {
        case image
        case text
    }

    let index: Int
    let kind: PageKind
    let fileName: String
}

private struct ReaderDownloadedChapterManifest: Codable {
    let version: Int
    let itemId: String
    let route: MangaContentRoute
    let mangaTitle: String
    let chapterNumber: String
    let pages: [ReaderDownloadedPageManifest]
    let dateCompleted: Date
}

private struct ReaderDownloadContext {
    let chapter: Chapter
    let kanzen: KanzenEngine?
}

final class ReaderDownloadManager: ObservableObject {
    static let shared = ReaderDownloadManager()

    @Published private(set) var downloads: [ReaderDownloadItem] = []

    private let fileManager = FileManager.default
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var queuedContexts: [String: ReaderDownloadContext] = [:]
    private var pausedIds = Set<String>()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private let progressPublishInterval: TimeInterval = 0.5

    private var maxConcurrentDownloads: Int {
        let raw = UserDefaults.standard.integer(forKey: "readerDownloadsParallelLimit")
        return max(1, min(raw == 0 ? 2 : raw, 4))
    }

    private var backgroundDownloadsEnabled: Bool {
        if UserDefaults.standard.object(forKey: "readerDownloadsBackgroundEnabled") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "readerDownloadsBackgroundEnabled")
    }

    private var wifiOnlyEnabled: Bool {
        UserDefaults.standard.bool(forKey: "readerDownloadsWifiOnly")
    }

    private var persistenceURL: URL {
        downloadsDirectory.appendingPathComponent(".reader_downloads.json")
    }

    var downloadsDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("KanzenDownloads", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var resourceURL = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? resourceURL.setResourceValues(values)
        return dir
    }

    var activeDownloads: [ReaderDownloadItem] {
        downloads.filter { $0.status == .queued || $0.status == .downloading || $0.status == .paused }
    }

    var failedDownloads: [ReaderDownloadItem] {
        downloads.filter { $0.status == .failed }
    }

    var completedDownloads: [ReaderDownloadItem] {
        downloads.filter { $0.status == .completed }
    }

    var downloadedTitles: [ReaderDownloadedTitle] {
        groupedTitles(from: downloads)
    }

    var totalDownloadedBytes: Int64 {
        directorySize(downloadsDirectory)
    }

    private init() {
        loadDownloads()
        normalizeInterruptedDownloads()
        observeLifecycle()
        processQueue()
    }

    // MARK: - Public Queue API

    func enqueueChapter(
        route: MangaContentRoute,
        mangaId: Int,
        title: String,
        coverURL: String?,
        sourceName: String?,
        format: String?,
        chapter: Chapter,
        kanzen: KanzenEngine? = nil
    ) {
        guard let provider = provider(for: route, chapter: chapter) else {
            upsertFailedPlaceholder(
                route: route,
                mangaId: mangaId,
                title: title,
                coverURL: coverURL,
                sourceName: sourceName,
                format: format,
                chapter: chapter,
                message: "This chapter cannot be downloaded because the source did not provide persistable chapter data."
            )
            return
        }

        let id = Self.downloadId(route: route, chapterNumber: chapter.chapterNumber)
        if let existing = downloads.first(where: { $0.id == id }),
           existing.status == .completed || existing.status == .queued || existing.status == .downloading {
            ReaderLogger.shared.log("Reader download already tracked id=\(id) status=\(existing.status.rawValue)", type: "ReaderDownload")
            return
        }

        let item = ReaderDownloadItem(
            id: id,
            route: route,
            routeKey: route.stableKey,
            mangaId: mangaId,
            mangaTitle: title,
            coverURL: coverURL,
            sourceName: sourceName,
            format: format,
            chapterNumber: chapter.chapterNumber,
            chapterTitle: chapter.chapterData?.first?.title,
            chapterKey: ChapterIdentityNormalizer.key(for: chapter.chapterNumber),
            provider: provider,
            status: .queued,
            progress: 0,
            completedPages: 0,
            totalPages: 0,
            downloadedBytes: 0,
            error: nil,
            dateAdded: Date(),
            dateCompleted: nil
        )

        if let index = downloads.firstIndex(where: { $0.id == id }) {
            downloads[index] = item
        } else {
            downloads.append(item)
        }
        queuedContexts[id] = ReaderDownloadContext(chapter: chapter, kanzen: kanzen)
        persist()
        ReaderLogger.shared.log("Queued reader download title='\(title)' chapter='\(chapter.chapterNumber)'", type: "ReaderDownload")
        processQueue()
    }

    func enqueueChapters(
        route: MangaContentRoute,
        mangaId: Int,
        title: String,
        coverURL: String?,
        sourceName: String?,
        format: String?,
        chapters: [Chapter],
        kanzen: KanzenEngine? = nil
    ) {
        let unique = ChapterIdentityNormalizer.deduplicatedChapters(chapters, reindex: false)
        for chapter in unique {
            enqueueChapter(
                route: route,
                mangaId: mangaId,
                title: title,
                coverURL: coverURL,
                sourceName: sourceName,
                format: format,
                chapter: chapter,
                kanzen: kanzen
            )
        }
    }

    func pauseDownload(id: String) {
        pausedIds.insert(id)
        activeTasks[id]?.cancel()
        updateItem(id) {
            $0.status = .paused
            $0.error = "Paused"
        }
    }

    func resumeDownload(id: String) {
        pausedIds.remove(id)
        updateItem(id) {
            $0.status = .queued
            $0.error = nil
        }
        processQueue()
    }

    func retryDownload(id: String) {
        pausedIds.remove(id)
        updateItem(id) {
            $0.status = .queued
            $0.progress = 0
            $0.completedPages = 0
            $0.totalPages = 0
            $0.error = nil
        }
        processQueue()
    }

    func applyQueueSettingsChanged() {
        processQueue()
    }

    func cancelDownload(id: String) {
        pausedIds.remove(id)
        activeTasks[id]?.cancel()
        activeTasks.removeValue(forKey: id)
        queuedContexts.removeValue(forKey: id)
        if let item = downloads.first(where: { $0.id == id }) {
            try? fileManager.removeItem(at: chapterDirectory(for: item))
        }
        downloads.removeAll { $0.id == id }
        persist()
        processQueue()
    }

    func removeDownload(id: String, deleteFiles: Bool = true) {
        activeTasks[id]?.cancel()
        activeTasks.removeValue(forKey: id)
        queuedContexts.removeValue(forKey: id)
        if deleteFiles, let item = downloads.first(where: { $0.id == id }) {
            try? fileManager.removeItem(at: chapterDirectory(for: item))
        }
        downloads.removeAll { $0.id == id }
        persist()
    }

    func deleteTitle(route: MangaContentRoute) {
        let routeKey = route.stableKey
        for item in downloads where item.routeKey == routeKey {
            activeTasks[item.id]?.cancel()
        }
        activeTasks = activeTasks.filter { id, _ in
            !downloads.contains { $0.id == id && $0.routeKey == routeKey }
        }
        queuedContexts = queuedContexts.filter { id, _ in
            !downloads.contains { $0.id == id && $0.routeKey == routeKey }
        }
        try? fileManager.removeItem(at: titleDirectory(for: routeKey))
        downloads.removeAll { $0.routeKey == routeKey }
        persist()
    }

    func deleteAll() {
        for task in activeTasks.values { task.cancel() }
        activeTasks.removeAll()
        queuedContexts.removeAll()
        try? fileManager.removeItem(at: downloadsDirectory)
        try? fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        downloads.removeAll()
        persist()
    }

    func deleteFailed() {
        for item in failedDownloads {
            try? fileManager.removeItem(at: chapterDirectory(for: item))
        }
        downloads.removeAll { $0.status == .failed }
        persist()
    }

    // MARK: - Offline Reader Lookup

    func status(for route: MangaContentRoute?, chapterNumber: String) -> ReaderDownloadStatus {
        guard let route else { return .none }
        return downloads.first { $0.id == Self.downloadId(route: route, chapterNumber: chapterNumber) }?.status ?? .none
    }

    func progress(for route: MangaContentRoute?, chapterNumber: String) -> Double {
        guard let route else { return 0 }
        return downloads.first { $0.id == Self.downloadId(route: route, chapterNumber: chapterNumber) }?.progress ?? 0
    }

    func isDownloaded(route: MangaContentRoute?, chapterNumber: String? = nil) -> Bool {
        guard let route else { return false }
        if let chapterNumber {
            return status(for: route, chapterNumber: chapterNumber) == .completed
        }
        return downloads.contains { $0.routeKey == route.stableKey && $0.status == .completed }
    }

    func downloadedTitle(for route: MangaContentRoute) -> ReaderDownloadedTitle? {
        downloadedTitles.first { $0.route.stableKey == route.stableKey }
    }

    func chapters(for route: MangaContentRoute) -> [ReaderDownloadItem] {
        downloads
            .filter { $0.routeKey == route.stableKey && $0.status == .completed }
            .sorted { lhs, rhs in
                let lhsValue = numericChapterValue(lhs.chapterNumber)
                let rhsValue = numericChapterValue(rhs.chapterNumber)
                switch (lhsValue, rhsValue) {
                case let (l?, r?):
                    return l < r
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    return (lhs.dateCompleted ?? lhs.dateAdded) < (rhs.dateCompleted ?? rhs.dateAdded)
                }
            }
    }

    func pages(for route: MangaContentRoute, chapterNumber: String) -> [PageData]? {
        let id = Self.downloadId(route: route, chapterNumber: chapterNumber)
        guard let item = downloads.first(where: { $0.id == id && $0.status == .completed }),
              let manifest = loadManifest(for: item) else { return nil }

        var pages: [PageData] = []
        for page in manifest.pages.sorted(by: { $0.index < $1.index }) {
            let fileURL = chapterDirectory(for: item).appendingPathComponent(page.fileName)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                markStale(item, reason: "Downloaded page files are missing.")
                return nil
            }
            switch page.kind {
            case .image:
                pages.append(PageData(content: .url(fileURL.absoluteString)))
            case .text:
                guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
                    markStale(item, reason: "Downloaded text file is unreadable.")
                    return nil
                }
                pages.append(PageData(content: .text(text)))
            }
        }
        return pages.isEmpty ? nil : pages
    }

    func text(for route: MangaContentRoute, chapterNumber: String) -> String? {
        guard let pages = pages(for: route, chapterNumber: chapterNumber) else { return nil }
        let textPages = pages.compactMap(\.textContent)
        guard !textPages.isEmpty else { return nil }
        return textPages.joined(separator: "\n\n")
    }

    // MARK: - Queue Processing

    private func processQueue() {
        let activeCount = downloads.filter { $0.status == .downloading }.count
        guard activeCount < maxConcurrentDownloads else { return }

        let slots = maxConcurrentDownloads - activeCount
        let nextItems = downloads
            .filter { $0.status == .queued && activeTasks[$0.id] == nil }
            .prefix(slots)

        for item in nextItems {
            start(item)
        }
    }

    private func start(_ item: ReaderDownloadItem) {
        updateItem(item.id) {
            $0.status = .downloading
            $0.error = nil
        }

        if backgroundDownloadsEnabled {
            beginBackgroundTaskIfNeeded()
        }

        let context = queuedContexts[item.id]
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.performDownload(itemId: item.id, context: context)
            } catch is CancellationError {
                await MainActor.run {
                    if self.pausedIds.contains(item.id) {
                        self.updateItem(item.id) {
                            $0.status = .paused
                            $0.error = "Paused"
                        }
                    }
                    self.activeTasks.removeValue(forKey: item.id)
                    self.processQueue()
                    self.endBackgroundTaskIfIdle()
                }
            } catch {
                await MainActor.run {
                    self.failItem(item.id, message: error.localizedDescription)
                    self.activeTasks.removeValue(forKey: item.id)
                    self.processQueue()
                    self.endBackgroundTaskIfIdle()
                }
            }
        }

        activeTasks[item.id] = task
    }

    private func performDownload(itemId: String, context: ReaderDownloadContext?) async throws {
        guard var item = downloads.first(where: { $0.id == itemId }) else { return }
        ReaderLogger.shared.log("Starting reader download id=\(itemId) chapter='\(item.chapterNumber)'", type: "ReaderDownload")

        let pages = try await extractPages(for: item, context: context)
        try Task.checkCancellation()
        guard !pages.isEmpty else {
            throw NSError(domain: "ReaderDownload", code: 1, userInfo: [NSLocalizedDescriptionKey: "No pages found for this chapter."])
        }

        await MainActor.run {
            self.updateItem(itemId) {
                $0.totalPages = pages.count
                $0.completedPages = 0
                $0.progress = 0
                $0.downloadedBytes = 0
            }
        }

        let directory = chapterDirectory(for: item)
        try? fileManager.removeItem(at: directory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var manifestPages: [ReaderDownloadedPageManifest] = []
        var downloadedBytes: Int64 = 0
        var lastProgressPublish = Date.distantPast
        let session = makeDownloadSession()
        defer { session.invalidateAndCancel() }

        for (index, page) in pages.enumerated() {
            try Task.checkCancellation()
            let saved = try await save(page: page, at: index, item: item, directory: directory, session: session)
            downloadedBytes += saved.bytes
            manifestPages.append(saved.page)

            let now = Date()
            let isFirstPage = index == 0
            let isLastPage = index == pages.count - 1
            if isFirstPage || isLastPage || now.timeIntervalSince(lastProgressPublish) >= progressPublishInterval {
                lastProgressPublish = now
                let publishedDownloadedBytes = downloadedBytes
                await MainActor.run {
                    self.updateItem(itemId) {
                        $0.completedPages = index + 1
                        $0.totalPages = pages.count
                        $0.progress = Double(index + 1) / Double(max(pages.count, 1))
                        $0.downloadedBytes = publishedDownloadedBytes
                    }
                }
            }
        }

        let manifest = ReaderDownloadedChapterManifest(
            version: 1,
            itemId: item.id,
            route: item.route,
            mangaTitle: item.mangaTitle,
            chapterNumber: item.chapterNumber,
            pages: manifestPages,
            dateCompleted: Date()
        )
        let manifestData = try JSONEncoder.readerDownloadEncoder.encode(manifest)
        try manifestData.write(to: directory.appendingPathComponent("chapter.json"), options: .atomic)

        item.downloadedBytes = downloadedBytes
        let completedDownloadedBytes = downloadedBytes
        await MainActor.run {
            self.queuedContexts.removeValue(forKey: itemId)
            self.updateItem(itemId) {
                $0.status = .completed
                $0.progress = 1
                $0.completedPages = pages.count
                $0.totalPages = pages.count
                $0.downloadedBytes = completedDownloadedBytes
                $0.dateCompleted = Date()
                $0.error = nil
            }
            self.activeTasks.removeValue(forKey: itemId)
            ReaderLogger.shared.log("Completed reader download id=\(itemId) pages=\(pages.count)", type: "ReaderDownload")
            self.processQueue()
            self.endBackgroundTaskIfIdle()
        }
    }

    private func extractPages(for item: ReaderDownloadItem, context: ReaderDownloadContext?) async throws -> [PageData] {
        if let chapter = context?.chapter, let params = chapter.chapterData?.first?.params {
            return try await extractPages(params: params, provider: item.provider, kanzen: context?.kanzen)
        }

        switch item.provider.kind {
        case .aidoku:
            guard let sourceId = item.provider.sourceId,
                  let mangaKey = item.provider.mangaKey else {
                throw downloadError("Missing Aidoku source metadata.")
            }
            guard await AidokuSourceManager.shared.metadata(id: sourceId)?.isEnabled != false else {
                throw downloadError("This Aidoku source is disabled.")
            }
            let seed = AidokuRunner.Manga(
                sourceKey: sourceId,
                key: mangaKey,
                title: item.mangaTitle,
                cover: item.coverURL
            )
            let manga = try await AidokuSourceManager.shared.mangaUpdate(
                sourceId: sourceId,
                manga: seed,
                needsDetails: true,
                needsChapters: true
            )
            guard let chapter = (manga.chapters ?? []).first(where: {
                let title = Self.aidokuChapterNumber($0, fallbackIndex: 0)
                return ChapterIdentityNormalizer.key(for: title) == item.chapterKey
            }) else {
                throw downloadError("Could not recover this chapter from the source.")
            }
            return try await AidokuSourceManager.shared.pageList(sourceId: sourceId, manga: manga, chapter: chapter, nativePages: false)

        case .legacyModule:
            guard let params = item.provider.chapterParams else {
                throw downloadError("Open this source detail page to retry this legacy download.")
            }
            guard let kanzen = context?.kanzen else {
                throw downloadError("Open this source detail page to retry this legacy download.")
            }
            return try await extractPages(params: params, provider: item.provider, kanzen: kanzen)
        }
    }

    private func extractPages(params: Any, provider: ReaderDownloadProvider, kanzen: KanzenEngine?) async throws -> [PageData] {
        if let payload = params as? AidokuChapterPayload {
            return try await AidokuSourceManager.shared.pageList(
                sourceId: payload.sourceId,
                manga: payload.manga,
                chapter: payload.chapter,
                nativePages: false
            )
        }

        guard let kanzen else {
            throw downloadError("This source needs to be open before the chapter can be downloaded.")
        }

        if provider.isNovel {
            let text = await withCheckedContinuation { continuation in
                kanzen.extractText(params: params) { result in
                    continuation.resume(returning: result)
                }
            }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text != "undefined" else {
                throw downloadError("Failed to extract text content.")
            }
            return [PageData(content: .text(text))]
        }

        let urls = await withCheckedContinuation { continuation in
            kanzen.extractImages(params: params) { result in
                continuation.resume(returning: result)
            }
        } ?? []
        return urls.map { PageData(content: $0) }
    }

    private func save(
        page: PageData,
        at index: Int,
        item: ReaderDownloadItem,
        directory: URL,
        session: URLSession
    ) async throws -> (page: ReaderDownloadedPageManifest, bytes: Int64) {
        if let text = page.textContent {
            let fileName = String(format: "%04d.txt", index + 1)
            let fileURL = directory.appendingPathComponent(fileName)
            let data = Data(text.utf8)
            try data.write(to: fileURL, options: .atomic)
            return (
                ReaderDownloadedPageManifest(index: index, kind: .text, fileName: fileName),
                Int64(data.count)
            )
        }

        let data: Data
        let preferredExtension: String
        if let imageData = page.imageData {
            data = imageData
            preferredExtension = imageExtension(for: imageData) ?? "jpg"
        } else if let urlString = page.urlString, let url = URL(string: urlString) {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 60
            for (field, value) in page.headers where !field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                request.setValue(value, forHTTPHeaderField: field)
            }
            request.setValue("1", forHTTPHeaderField: "DNT")
            request.setValue("1", forHTTPHeaderField: "Sec-GPC")

            ReaderLogger.shared.log("Downloading reader page id=\(item.id) page=\(index + 1)", type: "ReaderDownloadNetwork")
            let (downloadData, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw downloadError("Image request failed with HTTP \(http.statusCode).")
            }
            data = downloadData
            preferredExtension = imageExtension(forMimeType: response.mimeType)
                ?? imageExtension(for: downloadData)
                ?? url.pathExtension.nonEmpty
                ?? "jpg"
        } else {
            throw downloadError("Unsupported page type.")
        }

        guard !data.isEmpty else {
            throw downloadError("Downloaded page was empty.")
        }

        let ext = preferredExtension.lowercased().filter { $0.isLetter || $0.isNumber }.nonEmpty ?? "jpg"
        let fileName = String(format: "%04d.%@", index + 1, ext)
        let fileURL = directory.appendingPathComponent(fileName)
        try data.write(to: fileURL, options: .atomic)
        return (
            ReaderDownloadedPageManifest(index: index, kind: .image, fileName: fileName),
            Int64(data.count)
        )
    }

    // MARK: - Persistence

    private func loadDownloads() {
        guard let data = try? Data(contentsOf: persistenceURL) else { return }
        downloads = (try? JSONDecoder.readerDownloadDecoder.decode([ReaderDownloadItem].self, from: data)) ?? []
    }

    private func persist() {
        do {
            let data = try JSONEncoder.readerDownloadEncoder.encode(downloads)
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            ReaderLogger.shared.log("Failed to persist reader downloads: \(error.localizedDescription)", type: "ReaderDownloadStorage")
        }
    }

    private func normalizeInterruptedDownloads() {
        var changed = false
        for index in downloads.indices where downloads[index].status == .downloading {
            downloads[index].status = .paused
            downloads[index].error = "Paused after app restart"
            changed = true
        }
        if changed { persist() }
    }

    private func loadManifest(for item: ReaderDownloadItem) -> ReaderDownloadedChapterManifest? {
        let url = chapterDirectory(for: item).appendingPathComponent("chapter.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.readerDownloadDecoder.decode(ReaderDownloadedChapterManifest.self, from: data)
    }

    private func updateItem(_ id: String, mutate: (inout ReaderDownloadItem) -> Void) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        mutate(&downloads[index])
        persist()
    }

    private func failItem(_ id: String, message: String) {
        updateItem(id) {
            $0.status = .failed
            $0.error = message
        }
        if let item = downloads.first(where: { $0.id == id }) {
            try? fileManager.removeItem(at: chapterDirectory(for: item))
        }
        ReaderLogger.shared.log("Reader download failed id=\(id) error=\(message)", type: "ReaderDownload")
    }

    private func markStale(_ item: ReaderDownloadItem, reason: String) {
        updateItem(item.id) {
            $0.status = .failed
            $0.error = reason
        }
        ReaderLogger.shared.log("Reader download stale id=\(item.id) reason=\(reason)", type: "ReaderDownloadStorage")
    }

    private func upsertFailedPlaceholder(
        route: MangaContentRoute,
        mangaId: Int,
        title: String,
        coverURL: String?,
        sourceName: String?,
        format: String?,
        chapter: Chapter,
        message: String
    ) {
        let id = Self.downloadId(route: route, chapterNumber: chapter.chapterNumber)
        let provider = ReaderDownloadProvider(
            kind: .legacyModule,
            sourceId: nil,
            mangaKey: nil,
            moduleUUID: nil,
            contentParams: nil,
            isNovel: false,
            chapterParams: nil
        )
        let item = ReaderDownloadItem(
            id: id,
            route: route,
            routeKey: route.stableKey,
            mangaId: mangaId,
            mangaTitle: title,
            coverURL: coverURL,
            sourceName: sourceName,
            format: format,
            chapterNumber: chapter.chapterNumber,
            chapterTitle: chapter.chapterData?.first?.title,
            chapterKey: ChapterIdentityNormalizer.key(for: chapter.chapterNumber),
            provider: provider,
            status: .failed,
            progress: 0,
            completedPages: 0,
            totalPages: 0,
            downloadedBytes: 0,
            error: message,
            dateAdded: Date(),
            dateCompleted: nil
        )
        if let index = downloads.firstIndex(where: { $0.id == id }) {
            downloads[index] = item
        } else {
            downloads.append(item)
        }
        persist()
        ReaderLogger.shared.log("Reader download unsupported id=\(id) reason=\(message)", type: "ReaderDownload")
    }

    // MARK: - Helpers

    private func provider(for route: MangaContentRoute, chapter: Chapter) -> ReaderDownloadProvider? {
        let params = chapter.chapterData?.first?.params
        switch route {
        case .aidoku(let sourceId, let mangaKey):
            if let payload = params as? AidokuChapterPayload {
                return ReaderDownloadProvider(
                    kind: .aidoku,
                    sourceId: payload.sourceId,
                    mangaKey: payload.manga.key,
                    moduleUUID: nil,
                    contentParams: nil,
                    isNovel: false,
                    chapterParams: nil
                )
            }
            return ReaderDownloadProvider(
                kind: .aidoku,
                sourceId: sourceId,
                mangaKey: mangaKey,
                moduleUUID: nil,
                contentParams: nil,
                isNovel: false,
                chapterParams: nil
            )
        case .legacyModule(let moduleUUID, let contentParams, let isNovel):
            guard let value = persistableString(from: params) else { return nil }
            return ReaderDownloadProvider(
                kind: .legacyModule,
                sourceId: nil,
                mangaKey: nil,
                moduleUUID: moduleUUID,
                contentParams: contentParams,
                isNovel: isNovel,
                chapterParams: value
            )
        }
    }

    private func persistableString(from value: Any?) -> String? {
        if let value = value as? String { return value }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func makeDownloadSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = [
            "DNT": "1",
            "Sec-GPC": "1"
        ]
        config.allowsCellularAccess = !wifiOnlyEnabled
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }

    private func titleDirectory(for routeKey: String) -> URL {
        downloadsDirectory.appendingPathComponent(Self.stableHash(routeKey), isDirectory: true)
    }

    private func chapterDirectory(for item: ReaderDownloadItem) -> URL {
        titleDirectory(for: item.routeKey)
            .appendingPathComponent(Self.stableHash(item.chapterKey), isDirectory: true)
    }

    private func groupedTitles(from items: [ReaderDownloadItem]) -> [ReaderDownloadedTitle] {
        let groups = Dictionary(grouping: items, by: \.routeKey)
        return groups.compactMap { _, group -> ReaderDownloadedTitle? in
            guard let first = group.first else { return nil }
            let completed = group.filter { $0.status == .completed }
            let active = group.filter(\.isActive)
            let failed = group.filter { $0.status == .failed }
            guard !completed.isEmpty || !active.isEmpty || !failed.isEmpty else { return nil }
            return ReaderDownloadedTitle(
                id: first.routeKey,
                route: first.route,
                mangaId: first.mangaId,
                title: first.mangaTitle,
                coverURL: first.coverURL,
                sourceName: first.sourceName,
                format: first.format,
                completedCount: completed.count,
                activeCount: active.count,
                failedCount: failed.count,
                downloadedBytes: completed.reduce(0) { $0 + $1.downloadedBytes },
                latestCompleted: completed.compactMap(\.dateCompleted).max()
            )
        }
        .sorted {
            ($0.latestCompleted ?? .distantPast) > ($1.latestCompleted ?? .distantPast)
        }
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private func imageExtension(forMimeType mimeType: String?) -> String? {
        guard let mimeType = mimeType?.lowercased() else { return nil }
        if mimeType.contains("jpeg") || mimeType.contains("jpg") { return "jpg" }
        if mimeType.contains("png") { return "png" }
        if mimeType.contains("webp") { return "webp" }
        if mimeType.contains("gif") { return "gif" }
        return nil
    }

    private func imageExtension(for data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8]) { return "jpg" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if Array(bytes[0...3]) == [0x52, 0x49, 0x46, 0x46],
           Array(bytes[8...11]) == [0x57, 0x45, 0x42, 0x50] {
            return "webp"
        }
        return nil
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

    private func downloadError(_ message: String) -> NSError {
        NSError(domain: "ReaderDownload", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func observeLifecycle() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.processQueue() }
        }
    }

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ReaderDownloads") { [weak self] in
            Task { @MainActor in
                self?.pauseAllActiveForBackgroundExpiration()
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTaskIfIdle() {
        guard activeTasks.isEmpty else { return }
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func pauseAllActiveForBackgroundExpiration() {
        for item in downloads where item.status == .downloading {
            pausedIds.insert(item.id)
            activeTasks[item.id]?.cancel()
            updateItem(item.id) {
                $0.status = .paused
                $0.error = "Paused when iOS ended background time"
            }
        }
    }

    static func downloadId(route: MangaContentRoute, chapterNumber: String) -> String {
        "\(stableHash(route.stableKey))-\(stableHash(ChapterIdentityNormalizer.key(for: chapterNumber)))"
    }

    static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 5381
        for byte in value.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }

    static func aidokuChapterNumber(_ chapter: AidokuRunner.Chapter, fallbackIndex: Int) -> String {
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

    private static func formatNumber(_ value: Float) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(value))
        }
        return String(value)
    }
}

private extension JSONEncoder {
    static var readerDownloadEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var readerDownloadDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
