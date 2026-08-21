#if !os(tvOS)
import Combine
import Darwin
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
        case readerExtension
        /// Decode-only compatibility. AidokuRunner is never invoked.
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
    /// Device/profile scope whose approvals and authentication may be used by
    /// this queued Reader Extension request. Older rows decode as nil and are
    /// inert until the user explicitly resumes them in a profile.
    var authenticationProfileID: UUID? = nil
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

    var contentRating: Int?
    var provider: ReaderDownloadProvider
    var status: ReaderDownloadStatus
    var progress: Double
    var completedPages: Int
    var totalPages: Int
    var downloadedBytes: Int64
    var error: String?
    var dateAdded: Date
    var dateCompleted: Date?
    /// Original queue intent retained while an unresolved Aidoku source is inert.
    /// Cleared only after a unique replacement chapter has been verified and persisted.
    var legacyResumeStatus: ReaderDownloadStatus? = nil

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
    let contentRating: Int?
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

private struct ReaderVerifiedOfflineChapter {
    let manifest: ReaderDownloadedChapterManifest
    let downloadedBytes: Int64
}

private struct ReaderDownloadContext {
    let chapter: Chapter
    let kanzen: KanzenEngine?
}

private struct ReaderReconnectHydrationKey: Hashable, Sendable {
    let sourceID: ReaderExtensionSourceID
    let itemKey: String
    let authenticationProfileID: UUID
}

private struct ReaderReconnectHydrationResult: Sendable {
    let key: ReaderReconnectHydrationKey
    let chapters: [ReaderExtensionChapter]?
}

private enum ReaderDownloadPersistenceError: LocalizedError {
    case unsafeState
    case invalidIndex
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .unsafeState:
            return "Reader download storage is unavailable."
        case .invalidIndex:
            return "The Reader download index exceeded its safe limits."
        case .verificationFailed:
            return "The Reader download index could not be verified after writing."
        }
    }
}

final class ReaderDownloadManager: ObservableObject {
    static let shared = ReaderDownloadManager()

    private static let maxLegacyPageBytes = 12 * 1_024 * 1_024
    private static let maximumReadOnlyIndexBytes = 32 * 1_024 * 1_024
    private static let maximumReadOnlyManifestBytes = 2 * 1_024 * 1_024
    private static let maximumReadOnlyTextBytes = 8 * 1_024 * 1_024
    private static let maximumReadOnlyImageBytes = 32 * 1_024 * 1_024
    private static let maximumReadOnlyChapterBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    private static let maximumReadOnlyItems = 10_000
    private static let maximumReadOnlyPagesPerChapter = 5_000
    private static let maximumReconnectHydrationItems = 500
    private static let maximumReconnectDetailFetches = 64
    private static let maximumConcurrentReconnectDetailFetches = 4

    @Published private(set) var downloads: [ReaderDownloadItem] = []
    @Published private(set) var enqueueErrorMessage: String?

    private let fileManager = FileManager.default
    private var storesAreSafe: Bool
    private var persistedIndexAuthorityData: Data?
    private let indexPersistenceQueue = DispatchQueue(label: "app.eclipse.soupy.reader-download-index", qos: .utility)
    private let coalescedWriteLock = NSLock()
    private var coalescedWriteCandidate: [ReaderDownloadItem]?
    private var coalescedWriteScheduled = false
    private var indexWritesSuspended = false
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var queuedContexts: [String: ReaderDownloadContext] = [:]
    private var pausedIds = Set<String>()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private let progressPublishInterval: TimeInterval = 0.5

    private var maxConcurrentDownloads: Int {
        let raw = ProfileSettingsStore.active.integer(forKey: "readerDownloadsParallelLimit")
        return max(1, min(raw == 0 ? 2 : raw, 4))
    }

    private var backgroundDownloadsEnabled: Bool {
        if ProfileSettingsStore.active.object(forKey: "readerDownloadsBackgroundEnabled") == nil {
            return true
        }
        return ProfileSettingsStore.active.bool(forKey: "readerDownloadsBackgroundEnabled")
    }

    private var wifiOnlyEnabled: Bool {
        ProfileSettingsStore.active.bool(forKey: "readerDownloadsWifiOnly")
    }

    private var persistenceURL: URL {
        downloadsDirectory.appendingPathComponent(".reader_downloads.json")
    }

    var downloadsDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("KanzenDownloads", isDirectory: true)
        guard storesAreSafe else { return dir }
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
        guard storesAreSafe else {
            return downloads.reduce(into: Int64(0)) { total, item in
                let (next, overflow) = total.addingReportingOverflow(max(0, item.downloadedBytes))
                total = overflow ? Int64.max : next
            }
        }
        return directorySize(downloadsDirectory)
    }

    private init() {
        storesAreSafe = ReaderExtensionAidokuMigration.runAllKnownProfilesIfNeeded()
        guard storesAreSafe else {
            downloads = Self.verifiedCompletedDownloadsForReadOnlyFallback(
                indexURL: persistenceURL,
                downloadsRoot: downloadsDirectory,
                fileManager: fileManager
            )
            Logger.shared.log(
                "Reader downloads: loaded \(downloads.count) verified completed chapters read-only; queue and provider work remain inert until Reader storage is repaired",
                type: "Storage"
            )
            return
        }
        guard loadDownloads() else {
            storesAreSafe = false
            downloads = Self.verifiedCompletedDownloadsForReadOnlyFallback(
                indexURL: persistenceURL,
                downloadsRoot: downloadsDirectory,
                fileManager: fileManager
            )
            Logger.shared.log(
                "Reader downloads: quarantined an invalid index and loaded \(downloads.count) verified completed chapters read-only",
                type: "Storage"
            )
            return
        }
        guard recoverCompletedManifestsIfNeeded() else { return }
        normalizeInterruptedDownloads()
        normalizeReaderExtensionAuthenticationScopes()
        normalizeRemovedAidokuDownloads()
        observeLifecycle()
        if hasDownloadsNeedingReconnectHydration {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.hydrateReconnectedDownloads()
                self.processQueue()
            }
        } else {
            processQueue()
        }
    }

    @discardableResult
    func enqueueChapter(
        route: MangaContentRoute,
        mangaId: Int,
        title: String,
        coverURL: String?,
        sourceName: String?,
        format: String?,
        chapter: Chapter,
        contentRating: Int? = nil,
        kanzen: KanzenEngine? = nil
    ) -> Bool {
        guard storesAreSafe else { return false }
        guard let provider = provider(for: route, chapter: chapter) else {
            upsertFailedPlaceholder(
                route: route,
                mangaId: mangaId,
                title: title,
                coverURL: coverURL,
                sourceName: sourceName,
                format: format,
                chapter: chapter,
                contentRating: contentRating,
                message: "This chapter cannot be downloaded because the source did not provide persistable chapter data."
            )
            return false
        }

        let id = Self.downloadId(route: route, chapterNumber: chapter.chapterNumber)
        if let existing = downloads.first(where: { $0.id == id }),
           existing.status == .completed || existing.status == .queued || existing.status == .downloading {
            ReaderLogger.shared.log("Reader download already tracked id=\(id) status=\(existing.status.rawValue)", type: "ReaderDownload")
            return true
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
            contentRating: contentRating,
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

        var candidate = downloads
        if let index = candidate.firstIndex(where: { $0.id == id }) {
            candidate[index] = item
        } else {
            guard Self.downloadIndexCanAcceptNewItem(currentItemCount: candidate.count) else {
                publishEnqueueError(
                    "Reader Downloads can store up to \(Self.maximumReadOnlyItems.formatted()) chapters. Remove an existing download before adding another."
                )
                return false
            }
            candidate.append(item)
        }
        guard Self.persistedItemsAreWithinLimits(candidate) else {
            publishEnqueueError(
                "This chapter could not be queued because the Reader download index reached its safe storage limit. Remove an existing download and try again."
            )
            return false
        }
        guard commitDownloads(candidate) else { return false }
        queuedContexts[id] = ReaderDownloadContext(chapter: chapter, kanzen: kanzen)
        ReaderLogger.shared.log("Queued reader download id=\(id)", type: "ReaderDownload")
        processQueue()
        return true
    }

    func enqueueChapters(
        route: MangaContentRoute,
        mangaId: Int,
        title: String,
        coverURL: String?,
        sourceName: String?,
        format: String?,
        chapters: [Chapter],
        contentRating: Int? = nil,
        kanzen: KanzenEngine? = nil
    ) {
        guard storesAreSafe else { return }
        let unique = ChapterIdentityNormalizer.deduplicatedChapters(chapters, reindex: false)
        for chapter in unique {
            guard enqueueChapter(
                route: route,
                mangaId: mangaId,
                title: title,
                coverURL: coverURL,
                sourceName: sourceName,
                format: format,
                chapter: chapter,
                contentRating: contentRating,
                kanzen: kanzen
            ) else {
                if enqueueErrorMessage != nil { break }
                continue
            }
        }
    }

    func clearEnqueueError() {
        enqueueErrorMessage = nil
    }

    func pauseDownload(id: String) {
        guard storesAreSafe else { return }
        pausedIds.insert(id)
        activeTasks[id]?.cancel()
        updateItem(id) {
            $0.status = .paused
            $0.error = "Paused"
        }
    }

    func resumeDownload(id: String) {
        guard storesAreSafe else { return }
        pausedIds.remove(id)
        guard updateItem(id, mutate: {
            if $0.provider.kind == .readerExtension {
                $0.provider.authenticationProfileID = ProfileManager.shared.activeProfileID
            }
            if Self.needsReconnectHydration($0) {
                $0.status = .failed
                $0.error = "Verifying the replacement chapter before resuming…"
            } else {
                $0.status = .queued
                $0.error = nil
            }
        }) else { return }
        if downloads.first(where: { $0.id == id }).map(Self.needsReconnectHydration) == true {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.hydrateReconnectedDownloads(onlyIDs: [id])
                guard self.downloads.first(where: { $0.id == id })?
                    .provider.chapterParams != nil else { return }
                self.resumeDownload(id: id)
            }
            return
        }
        processQueue()
    }

    func retryDownload(id: String) {
        guard storesAreSafe else { return }
        guard updateItem(id, mutate: {
            if $0.provider.kind == .readerExtension {
                $0.provider.authenticationProfileID = ProfileManager.shared.activeProfileID
            }
        }) else { return }
        if let item = downloads.first(where: { $0.id == id }),
           Self.needsReconnectHydration(item) {
            guard updateItem(id, mutate: {
                $0.status = .failed
                $0.error = "Verifying the replacement chapter before retrying…"
            }) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.hydrateReconnectedDownloads(onlyIDs: [id])
                guard self.downloads.first(where: { $0.id == id })?
                    .provider.chapterParams != nil else { return }
                self.retryDownload(id: id)
            }
            return
        }
        pausedIds.remove(id)
        guard updateItem(id, mutate: {
            $0.status = .queued
            $0.progress = 0
            $0.completedPages = 0
            $0.totalPages = 0
            $0.error = nil
        }) else { return }
        processQueue()
    }

    func applyQueueSettingsChanged() {
        guard storesAreSafe else { return }
        processQueue()
    }

    func cancelDownload(id: String) {
        guard storesAreSafe else { return }
        let removedItem = downloads.first(where: { $0.id == id })
        let candidate = downloads.filter { $0.id != id }
        guard commitDownloads(candidate) else { return }
        pausedIds.remove(id)
        activeTasks[id]?.cancel()
        queuedContexts.removeValue(forKey: id)
        if let item = removedItem {
            try? fileManager.removeItem(at: chapterDirectory(for: item))
        }
        processQueue()
    }

    func removeDownload(id: String, deleteFiles: Bool = true) {
        guard storesAreSafe else { return }
        let removedItem = downloads.first(where: { $0.id == id })
        let candidate = downloads.filter { $0.id != id }
        guard commitDownloads(candidate) else { return }
        activeTasks[id]?.cancel()
        queuedContexts.removeValue(forKey: id)
        if deleteFiles, let item = removedItem {
            try? fileManager.removeItem(at: chapterDirectory(for: item))
        }
    }

    func deleteTitle(route: MangaContentRoute) {
        guard storesAreSafe else { return }
        let routeKey = route.stableKey
        let removedItems = downloads.filter { $0.routeKey == routeKey }
        let candidate = downloads.filter { $0.routeKey != routeKey }
        guard commitDownloads(candidate) else { return }
        for item in removedItems {
            activeTasks[item.id]?.cancel()
        }
        let removedIDs = Set(removedItems.map(\.id))
        queuedContexts = queuedContexts.filter { !removedIDs.contains($0.key) }
        pausedIds.subtract(removedIDs)
        try? fileManager.removeItem(at: titleDirectory(for: routeKey))
    }

    func deleteAll() {
        guard storesAreSafe else { return }
        guard commitDownloads([]) else { return }
        for task in activeTasks.values { task.cancel() }
        queuedContexts.removeAll()
        pausedIds.removeAll()
        try? fileManager.removeItem(at: downloadsDirectory)
        try? fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        indexPersistenceQueue.sync { persistedIndexAuthorityData = nil }
    }

    func deleteFailed() {
        guard storesAreSafe else { return }
        let removedItems = failedDownloads
        let candidate = downloads.filter { $0.status != .failed }
        guard commitDownloads(candidate) else { return }
        for item in removedItems {
            try? fileManager.removeItem(at: chapterDirectory(for: item))
        }
    }

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
        guard let item = downloads.first(where: { $0.id == id && $0.status == .completed }) else {
            return nil
        }
        if !storesAreSafe {
            return Self.verifiedReadOnlyPages(
                item,
                downloadsRoot: downloadsDirectory,
                fileManager: fileManager
            )
        }
        guard let manifest = loadManifest(for: item) else { return nil }

        var pages: [PageData] = []
        let chapterRoot = chapterDirectory(for: item)
        for page in manifest.pages.sorted(by: { $0.index < $1.index }) {
            let fileURL = chapterRoot.appendingPathComponent(page.fileName)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                if storesAreSafe {
                    markStale(item, reason: "Downloaded page files are missing.")
                }
                return nil
            }
            switch page.kind {
            case .image:
                pages.append(PageData(content: .url(fileURL.absoluteString)))
            case .text:
                guard let data = Self.verifiedRegularFileData(
                    fileURL,
                    inside: chapterRoot,
                    maximumBytes: Self.maximumReadOnlyTextBytes,
                    fileManager: fileManager
                ),
                let text = String(data: data, encoding: .utf8) else {
                    if storesAreSafe {
                        markStale(item, reason: "Downloaded text file is unreadable.")
                    }
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

    private func processQueue() {
        guard storesAreSafe else { return }
        let activeCount = downloads.filter { $0.status == .downloading }.count
        guard activeCount < maxConcurrentDownloads else { return }

        let slots = maxConcurrentDownloads - activeCount
        let nextItems = downloads
            .filter {
                $0.status == .queued
                    && activeTasks[$0.id] == nil
                    && Self.authenticationScopeAllowsExecution(
                        $0.provider,
                        activeProfileID: ProfileManager.shared.activeProfileID
                    )
            }
            .prefix(slots)

        for item in nextItems {
            start(item)
        }
    }

    private func start(_ item: ReaderDownloadItem) {
        guard Self.authenticationScopeAllowsExecution(
            item.provider,
            activeProfileID: ProfileManager.shared.activeProfileID
        ) else {
            updateItem(item.id) {
                $0.status = .paused
                $0.error = "Paused after a profile change. Resume to use the active profile's authentication."
            }
            return
        }
        guard updateItem(item.id, mutate: {
            $0.status = .downloading
            $0.error = nil
        }) else { return }

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
                    } else if !self.downloads.contains(where: { $0.id == item.id }) {
                        // A committed cancel/removal owns the durable index state. Clean
                        // any file that an already-running writer finished while unwinding.
                        try? self.fileManager.removeItem(at: self.chapterDirectory(for: item))
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
        try requireCurrentAuthenticationScope(item.provider)
        ReaderLogger.shared.log("Starting reader download id=\(itemId)", type: "ReaderDownload")

        let pages = try await extractPages(for: item, context: context)
        try Task.checkCancellation()
        guard !pages.isEmpty else {
            throw NSError(domain: "ReaderDownload", code: 1, userInfo: [NSLocalizedDescriptionKey: "No pages found for this chapter."])
        }
        guard pages.count <= Self.maximumReadOnlyPagesPerChapter else {
            throw downloadError(
                "This chapter has \(pages.count) pages, above the safe Reader download limit of \(Self.maximumReadOnlyPagesPerChapter)."
            )
        }

        let didPersistPreparation = await MainActor.run {
            self.updateItem(itemId) {
                $0.totalPages = pages.count
                $0.completedPages = 0
                $0.progress = 0
                $0.downloadedBytes = 0
            }
        }
        guard didPersistPreparation else {
            throw ReaderDownloadPersistenceError.verificationFailed
        }

        let directory = chapterDirectory(for: item)
        try? fileManager.removeItem(at: directory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var manifestPages: [ReaderDownloadedPageManifest] = []
        var downloadedBytes: Int64 = 0
        var lastProgressPublish = Date.distantPast
        let pinnedHTTPClient = SkyStreamPinnedHTTPClient(
            networkConstraint: wifiOnlyEnabled ? .wifi : .any
        )

        for (index, page) in pages.enumerated() {
            try Task.checkCancellation()
            let saved = try await save(
                page: page,
                at: index,
                item: item,
                directory: directory,
                pinnedHTTPClient: pinnedHTTPClient
            )
            try Task.checkCancellation()
            try requireCurrentAuthenticationScope(item.provider)
            guard Self.downloadPageBudgetAllows(
                pageCount: index + 1,
                accumulatedBytes: downloadedBytes,
                nextPageBytes: saved.bytes
            ) else {
                throw downloadError("This chapter exceeded the safe 2 GB Reader download limit.")
            }
            downloadedBytes += saved.bytes
            manifestPages.append(saved.page)

            let now = Date()
            let isFirstPage = index == 0
            let isLastPage = index == pages.count - 1
            if isFirstPage || isLastPage || now.timeIntervalSince(lastProgressPublish) >= progressPublishInterval {
                lastProgressPublish = now
                let publishedDownloadedBytes = downloadedBytes
                await MainActor.run {
                    self.publishItemProgress(itemId) {
                        $0.completedPages = index + 1
                        $0.totalPages = pages.count
                        $0.progress = Double(index + 1) / Double(max(pages.count, 1))
                        $0.downloadedBytes = publishedDownloadedBytes
                    }
                }
            }
        }

        try Task.checkCancellation()
        try requireCurrentAuthenticationScope(item.provider)

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
        guard Self.persistedChapterManifestSchemaIsValid(manifestData) else {
            throw downloadError("The downloaded chapter could not be stored safely.")
        }
        let manifestURL = directory.appendingPathComponent("chapter.json")
        try manifestData.write(to: manifestURL, options: .atomic)

        let completedDownloadedBytes = downloadedBytes
        item.status = .completed
        item.progress = 1
        item.completedPages = pages.count
        item.totalPages = pages.count
        item.downloadedBytes = completedDownloadedBytes
        item.dateCompleted = manifest.dateCompleted
        item.error = nil
        try makeCompletedChapterDurable(
            item: item,
            manifest: manifest,
            manifestData: manifestData,
            directory: directory
        )
        try Task.checkCancellation()

        let didPersistCompletion = await MainActor.run {
            self.updateItem(itemId) {
                $0.status = .completed
                $0.progress = 1
                $0.completedPages = pages.count
                $0.totalPages = pages.count
                $0.downloadedBytes = completedDownloadedBytes
                $0.dateCompleted = manifest.dateCompleted
                $0.error = nil
            }
        }
        guard didPersistCompletion else {
            let shouldRetainCompletedFiles = await MainActor.run {
                !self.storesAreSafe || self.downloads.contains(where: { $0.id == itemId })
            }
            guard shouldRetainCompletedFiles else {
                throw CancellationError()
            }
            await MainActor.run {
                self.enterReadOnlyRecovery(retaining: [item])
            }
            return
        }
        await MainActor.run {
            self.queuedContexts.removeValue(forKey: itemId)
            self.activeTasks.removeValue(forKey: itemId)
            ReaderLogger.shared.log("Completed reader download id=\(itemId) pages=\(pages.count)", type: "ReaderDownload")
            self.processQueue()
            self.endBackgroundTaskIfIdle()
        }
    }

    private func extractPages(for item: ReaderDownloadItem, context: ReaderDownloadContext?) async throws -> [PageData] {
        try requireCurrentAuthenticationScope(item.provider)
        if let chapter = context?.chapter, let params = chapter.chapterData?.first?.params {
            return try await extractPages(
                params: params,
                provider: item.provider,
                kanzen: context?.kanzen,
                itemId: item.id
            )
        }

        switch item.provider.kind {
        case .readerExtension:
            guard let sourceRaw = item.provider.sourceId,
                  let itemKey = item.provider.mangaKey,
                  let chapterKey = item.provider.chapterParams else {
                throw downloadError("Missing Reader Extension source metadata.")
            }
            let sourceID = ReaderExtensionSourceID(rawValue: sourceRaw)
            guard sourceID.isValid,
                  let installed = await ReaderExtensionManager.shared.installedSources.first(where: { $0.id == sourceID }),
                  installed.enabled else {
                throw downloadError("This Reader Extension is unavailable or disabled.")
            }
            let provider = try await ReaderExtensionManager.shared.provider(
                for: sourceID,
                readerDownloadProfileID: item.provider.authenticationProfileID
            )
            let itemDetail = try await provider.detail(itemKey: itemKey)
            await applyDerivedRating(itemId: item.id, item: itemDetail)
            if installed.mediaType == .novel {
                let html = try await provider.chapterHTML(chapterKey: chapterKey, chapterTitle: item.chapterTitle ?? item.chapterNumber)
                return [PageData(content: .text(try ReaderExtensionWebNovelSanitizer.plainText(from: html)))]
            }
            let remotePages = try await provider.pages(chapterKey: chapterKey)
            return try await ReaderExtensionManager.shared.pageResources(
                for: remotePages,
                sourceID: sourceID,
                readerDownloadProfileID: item.provider.authenticationProfileID
            ).map(\.pageData)

        case .aidoku:
            throw downloadError("The previous Reader source is unavailable. Reconnect this title to resume the download.")

        case .legacyModule:
            guard let params = item.provider.chapterParams else {
                throw downloadError("Open this source detail page to retry this legacy download.")
            }
            guard let kanzen = context?.kanzen else {
                throw downloadError("Open this source detail page to retry this legacy download.")
            }
            return try await extractPages(
                params: params,
                provider: item.provider,
                kanzen: kanzen,
                itemId: item.id
            )
        }
    }

    private func extractPages(
        params: Any,
        provider: ReaderDownloadProvider,
        kanzen: KanzenEngine?,
        itemId: String
    ) async throws -> [PageData] {
        try requireCurrentAuthenticationScope(provider)
        if let payload = params as? ReaderExtensionChapterPayload {
            let readerProvider = try await ReaderExtensionManager.shared.provider(
                for: payload.sourceID,
                readerDownloadProfileID: provider.authenticationProfileID
            )
            await applyDerivedRating(itemId: itemId, item: payload.item)
            if payload.mediaType == .novel {
                let html = try await readerProvider.chapterHTML(
                    chapterKey: payload.chapter.key,
                    chapterTitle: payload.chapter.title
                )
                return [PageData(content: .text(try ReaderExtensionWebNovelSanitizer.plainText(from: html)))]
            }
            let remotePages = try await readerProvider.pages(chapterKey: payload.chapter.key)
            return try await ReaderExtensionManager.shared.pageResources(
                for: remotePages,
                sourceID: payload.sourceID,
                readerDownloadProfileID: provider.authenticationProfileID
            ).map(\.pageData)
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

    private func applyDerivedRating(itemId: String, item: ReaderExtensionItem) async {
        let derived = ReaderContentFilter.shared.derivedReaderExtensionRating(for: item)
        await MainActor.run {
            self.updateItem(itemId) { item in
                guard let existing = item.contentRating else {
                    item.contentRating = derived
                    return
                }
                item.contentRating = max(existing, derived)
            }
        }
    }

    private func save(
        page: PageData,
        at index: Int,
        item: ReaderDownloadItem,
        directory: URL,
        pinnedHTTPClient: SkyStreamPinnedHTTPClient
    ) async throws -> (page: ReaderDownloadedPageManifest, bytes: Int64) {
        if let text = page.textContent {
            let fileName = String(format: "%04d.txt", index + 1)
            let fileURL = directory.appendingPathComponent(fileName)
            let data = Data(text.utf8)
            guard !data.isEmpty, data.count <= Self.maximumReadOnlyTextBytes else {
                throw downloadError("This text page exceeded the safe 8 MB Reader download limit.")
            }
            try data.write(to: fileURL, options: .atomic)
            guard (try? BoundedLocalStoreReader.read(
                from: fileURL,
                maximumBytes: Self.maximumReadOnlyTextBytes
            )) == data else {
                throw ReaderDownloadPersistenceError.verificationFailed
            }
            try synchronizeFile(fileURL)
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
        } else if let resource = page.readerExtensionResource {
            ReaderLogger.shared.log("Downloading Reader Extension page id=\(item.id) page=\(index + 1)", type: "ReaderDownloadNetwork")
            let response = try await ReaderExtensionManager.shared.fetchPage(resource)
            _ = try await Task.detached(priority: .utility) {
                try ReaderExtensionImageSafety.validate(response.body)
            }.value
            data = response.body
            let contentType = response.headers.first {
                $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
            }?.value
            preferredExtension = imageExtension(forMimeType: contentType)
                ?? imageExtension(for: response.body)
                ?? "jpg"
        } else if let urlString = page.urlString, let url = URL(string: urlString) {
            var requestHeaders = page.headers
            requestHeaders["DNT"] = "1"
            requestHeaders["Sec-GPC"] = "1"
            let sanitizedHeaders: SkyStreamSanitizedHeaders
            do {
                sanitizedHeaders = try SkyStreamHeaderSanitizer.sanitize(
                    requestHeaders,
                    purpose: .pluginRequest
                )
            } catch {
                throw downloadError("The reader source supplied unsafe page headers.")
            }

            ReaderLogger.shared.log("Downloading reader page id=\(item.id) page=\(index + 1)", type: "ReaderDownloadNetwork")
            let output: SkyStreamPinnedHTTPClient.Response
            do {
                output = try await pinnedHTTPClient.fetch(
                    url.absoluteString,
                    purpose: .pluginRequest,
                    headers: sanitizedHeaders,
                    allowsCookies: true,
                    maximumResponseBytes: Self.maxLegacyPageBytes,
                    timeout: 60
                )
            } catch SkyStreamSecurityError.responseTooLarge {
                ReaderLogger.shared.log(
                    "Reader page too large id=\(item.id) page=\(index + 1)",
                    type: "ReaderDownloadNetwork"
                )
                throw downloadError("This page exceeded the \(Self.maxLegacyPageBytes / (1024 * 1024))MB page limit.")
            } catch let error as SkyStreamSecurityError {
                ReaderLogger.shared.log(
                    "Reader page request blocked id=\(item.id) page=\(index + 1) reason=\(error)",
                    type: "ReaderDownloadNetwork"
                )
                throw downloadError("Blocked reader page request to \(url.host ?? "the source host").")
            }
            if !(200...299).contains(output.response.statusCode) {
                throw downloadError("Image request failed with HTTP \(output.response.statusCode).")
            }
            data = output.data
            preferredExtension = imageExtension(forMimeType: output.response.mimeType)
                ?? imageExtension(for: output.data)
                ?? url.pathExtension.nonEmpty
                ?? "jpg"
        } else {
            throw downloadError("Unsupported page type.")
        }

        guard !data.isEmpty else {
            throw downloadError("Downloaded page was empty.")
        }
        guard data.count <= Self.maximumReadOnlyImageBytes else {
            throw downloadError("This image exceeded the safe 32 MB Reader download limit.")
        }

        let ext = preferredExtension.lowercased().filter { $0.isLetter || $0.isNumber }.nonEmpty ?? "jpg"
        let fileName = String(format: "%04d.%@", index + 1, ext)
        let fileURL = directory.appendingPathComponent(fileName)
        try data.write(to: fileURL, options: .atomic)
        guard (try? BoundedLocalStoreReader.read(
            from: fileURL,
            maximumBytes: Self.maximumReadOnlyImageBytes
        )) == data else {
            throw ReaderDownloadPersistenceError.verificationFailed
        }
        try synchronizeFile(fileURL)
        return (
            ReaderDownloadedPageManifest(index: index, kind: .image, fileName: fileName),
            Int64(data.count)
        )
    }

    /// Recovery-only loader used when another Reader store is quarantined. It never
    /// normalizes, deletes, or writes the index. Each row is decoded independently so
    /// one corrupt download cannot hide unrelated self-contained chapters.
    static func verifiedCompletedDownloadsForReadOnlyFallback(
        indexURL: URL,
        downloadsRoot: URL,
        fileManager: FileManager = .default
    ) -> [ReaderDownloadItem] {
        guard verifiedDirectory(downloadsRoot, fileManager: fileManager),
              indexURL.deletingLastPathComponent().standardizedFileURL
                == downloadsRoot.standardizedFileURL,
              let indexData = verifiedRegularFileData(
                indexURL,
                inside: downloadsRoot,
                maximumBytes: maximumReadOnlyIndexBytes,
                fileManager: fileManager
              ),
              persistedIndexJSONIsStructurallyBounded(indexData),
              let rawItems = try? JSONSerialization.jsonObject(with: indexData) as? [Any],
              rawItems.count <= maximumReadOnlyItems else {
            return []
        }

        var accepted: [ReaderDownloadItem] = []
        var acceptedIDs = Set<String>()
        for rawItem in rawItems {
            guard JSONSerialization.isValidJSONObject(rawItem),
                  let itemData = try? JSONSerialization.data(withJSONObject: rawItem),
                  let item = try? JSONDecoder.readerDownloadDecoder.decode(
                    ReaderDownloadItem.self,
                    from: itemData
                  ),
                  item.status == .completed,
                  let verified = verifiedReadOnlyChapter(
                    item,
                    downloadsRoot: downloadsRoot,
                    fileManager: fileManager
                  ),
                  let safeItem = readOnlyCompletedCopy(item, verified: verified),
                  acceptedIDs.insert(safeItem.id).inserted else {
                continue
            }
            accepted.append(safeItem)
        }
        return accepted
    }

    private static func verifiedReadOnlyChapter(
        _ item: ReaderDownloadItem,
        downloadsRoot: URL,
        fileManager: FileManager
    ) -> ReaderVerifiedOfflineChapter? {
        guard item.status == .completed,
              boundedMetadataString(item.id, maximumBytes: 256),
              boundedMetadataString(item.routeKey, maximumBytes: 32 * 1_024),
              boundedMetadataString(item.mangaTitle, maximumBytes: 4 * 1_024),
              boundedMetadataString(item.chapterNumber, maximumBytes: 1_024),
              boundedMetadataString(item.chapterKey, maximumBytes: 1_024),
              boundedOptionalMetadataString(item.chapterTitle, maximumBytes: 4 * 1_024),
              boundedOptionalMetadataString(item.sourceName, maximumBytes: 1_024),
              boundedOptionalMetadataString(item.format, maximumBytes: 256),
              item.contentRating.map({ ReaderContentRating(rawValue: $0) != nil }) ?? true,
              verifiedOfflineRoute(item.route),
              item.routeKey == item.route.stableKey,
              item.chapterKey == ChapterIdentityNormalizer.key(for: item.chapterNumber),
              item.id == downloadId(route: item.route, chapterNumber: item.chapterNumber),
              verifiedOfflineProvider(item.provider, route: item.route) != nil else {
            return nil
        }

        let titleDirectory = downloadsRoot
            .appendingPathComponent(stableHash(item.routeKey), isDirectory: true)
        let chapterDirectory = titleDirectory
            .appendingPathComponent(stableHash(item.chapterKey), isDirectory: true)
        guard verifiedDirectory(titleDirectory, inside: downloadsRoot, fileManager: fileManager),
              verifiedDirectory(chapterDirectory, inside: downloadsRoot, fileManager: fileManager),
              let manifestData = verifiedRegularFileData(
                chapterDirectory.appendingPathComponent("chapter.json"),
                inside: chapterDirectory,
                maximumBytes: maximumReadOnlyManifestBytes,
                fileManager: fileManager
              ),
              let manifest = decodePersistedManifest(manifestData),
              manifest.version == 1,
              manifest.itemId == item.id,
              manifest.route == item.route,
              manifest.mangaTitle == item.mangaTitle,
              manifest.chapterNumber == item.chapterNumber,
              !manifest.pages.isEmpty,
              manifest.pages.count <= maximumReadOnlyPagesPerChapter,
              item.completedPages == manifest.pages.count,
              item.totalPages == manifest.pages.count,
              item.progress.isFinite,
              item.progress >= 0.999,
              item.progress <= 1.001,
              item.dateCompleted != nil else {
            return nil
        }

        let orderedPages = manifest.pages.sorted { $0.index < $1.index }
        guard orderedPages.map(\.index) == Array(0..<orderedPages.count) else { return nil }

        var totalBytes: Int64 = 0
        for page in orderedPages {
            guard let maximumBytes = verifiedGeneratedPageFileName(page) else { return nil }
            let fileURL = chapterDirectory.appendingPathComponent(page.fileName)
            guard let fileSize = verifiedRegularFileSize(
                fileURL,
                inside: chapterDirectory,
                maximumBytes: maximumBytes,
                fileManager: fileManager
            ) else { return nil }

            if page.kind == .text {
                guard let data = verifiedRegularFileData(
                    fileURL,
                    inside: chapterDirectory,
                    maximumBytes: maximumBytes,
                    fileManager: fileManager
                ),
                      data.count == fileSize,
                      String(data: data, encoding: .utf8) != nil else { return nil }
            } else {
                guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
                defer { try? handle.close() }
                let prefix: Data
                do {
                    guard let value = try handle.read(upToCount: 16) else { return nil }
                    prefix = value
                } catch {
                    return nil
                }
                guard !prefix.isEmpty else { return nil }
            }

            let (nextTotal, overflow) = totalBytes.addingReportingOverflow(Int64(fileSize))
            guard !overflow, nextTotal <= maximumReadOnlyChapterBytes else { return nil }
            totalBytes = nextTotal
        }
        return ReaderVerifiedOfflineChapter(manifest: manifest, downloadedBytes: totalBytes)
    }

    private static func readOnlyCompletedCopy(
        _ item: ReaderDownloadItem,
        verified: ReaderVerifiedOfflineChapter
    ) -> ReaderDownloadItem? {
        guard let provider = verifiedOfflineProvider(item.provider, route: item.route) else {
            return nil
        }
        let sanitizedCover = item.coverURL.flatMap(URL.init(string:)).flatMap {
            ReaderExtensionSafeMetadata.sanitizedURLString($0)
        }
        return ReaderDownloadItem(
            id: item.id,
            route: item.route,
            routeKey: item.routeKey,
            mangaId: item.mangaId,
            mangaTitle: item.mangaTitle,
            coverURL: sanitizedCover,
            sourceName: item.sourceName,
            format: item.format,
            chapterNumber: item.chapterNumber,
            chapterTitle: item.chapterTitle,
            chapterKey: item.chapterKey,
            contentRating: item.contentRating,
            provider: provider,
            status: .completed,
            progress: 1,
            completedPages: verified.manifest.pages.count,
            totalPages: verified.manifest.pages.count,
            downloadedBytes: verified.downloadedBytes,
            error: nil,
            dateAdded: item.dateAdded,
            dateCompleted: item.dateCompleted ?? verified.manifest.dateCompleted,
            legacyResumeStatus: nil
        )
    }

    static func recoverableCompletedCopy(
        _ item: ReaderDownloadItem,
        downloadsRoot: URL,
        fileManager: FileManager
    ) -> ReaderDownloadItem? {
        let chapterDirectory = downloadsRoot
            .appendingPathComponent(stableHash(item.routeKey), isDirectory: true)
            .appendingPathComponent(stableHash(item.chapterKey), isDirectory: true)
        guard let manifestData = verifiedRegularFileData(
            chapterDirectory.appendingPathComponent("chapter.json"),
            inside: chapterDirectory,
            maximumBytes: maximumReadOnlyManifestBytes,
            fileManager: fileManager
        ), let manifest = decodePersistedManifest(manifestData) else { return nil }

        var provisional = item
        provisional.status = .completed
        provisional.progress = 1
        provisional.completedPages = manifest.pages.count
        provisional.totalPages = manifest.pages.count
        provisional.dateCompleted = manifest.dateCompleted
        provisional.error = nil
        guard let verified = verifiedReadOnlyChapter(
            provisional,
            downloadsRoot: downloadsRoot,
            fileManager: fileManager
        ) else { return nil }
        provisional.downloadedBytes = verified.downloadedBytes
        return readOnlyCompletedCopy(provisional, verified: verified)
    }

    static func verifiedReadOnlyPages(
        _ item: ReaderDownloadItem,
        downloadsRoot: URL,
        fileManager: FileManager = .default
    ) -> [PageData]? {
        guard let verified = verifiedReadOnlyChapter(
            item,
            downloadsRoot: downloadsRoot,
            fileManager: fileManager
        ) else { return nil }
        let chapterDirectory = downloadsRoot
            .appendingPathComponent(stableHash(item.routeKey), isDirectory: true)
            .appendingPathComponent(stableHash(item.chapterKey), isDirectory: true)
        var result: [PageData] = []
        for page in verified.manifest.pages.sorted(by: { $0.index < $1.index }) {
            let fileURL = chapterDirectory.appendingPathComponent(page.fileName)
            switch page.kind {
            case .image:
                result.append(PageData(content: .url(fileURL.absoluteString)))
            case .text:
                guard let data = verifiedRegularFileData(
                    fileURL,
                    inside: chapterDirectory,
                    maximumBytes: maximumReadOnlyTextBytes,
                    fileManager: fileManager
                ),
                let text = String(data: data, encoding: .utf8) else {
                    return nil
                }
                result.append(PageData(content: .text(text)))
            }
        }
        return result.isEmpty ? nil : result
    }

    private static func verifiedOfflineRoute(_ route: MangaContentRoute) -> Bool {
        switch route {
        case .readerExtension(let source, let itemKey, let legacyStableKey):
            guard source.isValid,
                  ReaderExtensionSecurityPolicy.persistableProviderContentKey(itemKey) != nil else {
                return false
            }
            guard let legacyStableKey else { return true }
            return legacyStableKey.hasPrefix("aidoku:")
                && boundedMetadataString(legacyStableKey, maximumBytes: 32 * 1_024)

        case .aidoku(let sourceID, let mangaKey):
            return boundedMetadataString(sourceID, maximumBytes: 4 * 1_024)
                && boundedMetadataString(mangaKey, maximumBytes: 32 * 1_024)

        case .legacyModule(let moduleUUID, let contentParams, _):
            return boundedMetadataString(moduleUUID, maximumBytes: 4 * 1_024)
                && boundedMetadataString(contentParams, maximumBytes: 32 * 1_024)
        }
    }

    private static func isValidPersistedItem(_ item: ReaderDownloadItem) -> Bool {
        guard boundedMetadataString(item.id, maximumBytes: 256),
              boundedMetadataString(item.routeKey, maximumBytes: 32 * 1_024),
              boundedMetadataString(item.mangaTitle, maximumBytes: 4 * 1_024),
              boundedOptionalMetadataString(item.coverURL, maximumBytes: 32 * 1_024),
              boundedOptionalMetadataString(item.sourceName, maximumBytes: 1_024),
              boundedOptionalMetadataString(item.format, maximumBytes: 256),
              boundedMetadataString(item.chapterNumber, maximumBytes: 1_024),
              boundedOptionalMetadataString(item.chapterTitle, maximumBytes: 4 * 1_024),
              boundedMetadataString(item.chapterKey, maximumBytes: 1_024),
              boundedOptionalMetadataString(item.error, maximumBytes: 8 * 1_024),
              item.contentRating.map({ ReaderContentRating(rawValue: $0) != nil }) ?? true,
              item.progress.isFinite,
              (0...1).contains(item.progress),
              item.completedPages >= 0,
              item.completedPages <= maximumReadOnlyPagesPerChapter,
              item.totalPages >= 0,
              item.totalPages <= maximumReadOnlyPagesPerChapter,
              item.completedPages <= item.totalPages,
              item.downloadedBytes >= 0,
              item.downloadedBytes <= maximumReadOnlyChapterBytes,
              verifiedOfflineRoute(item.route),
              item.routeKey == item.route.stableKey,
              item.chapterKey == ChapterIdentityNormalizer.key(for: item.chapterNumber),
              item.id == downloadId(route: item.route, chapterNumber: item.chapterNumber) else {
            return false
        }

        switch (item.route, item.provider.kind) {
        case let (.readerExtension(source, itemKey, _), .readerExtension):
            guard item.provider.sourceId == source.rawValue,
                  item.provider.mangaKey == itemKey,
                  item.provider.moduleUUID == nil,
                  item.provider.contentParams == nil else { return false }
            if let chapterKey = item.provider.chapterParams,
               persistableReaderExtensionChapterKey(chapterKey) == nil {
                return false
            }
            return true

        case let (.aidoku(sourceID, mangaKey), .aidoku):
            return item.provider.sourceId == sourceID
                && item.provider.mangaKey == mangaKey
                && item.provider.moduleUUID == nil
                && item.provider.contentParams == nil

        case let (.legacyModule(moduleUUID, contentParams, isNovel), .legacyModule):
            guard item.provider.moduleUUID == moduleUUID,
                  item.provider.contentParams == contentParams,
                  item.provider.isNovel == isNovel,
                  boundedOptionalMetadataString(item.provider.chapterParams, maximumBytes: 32 * 1_024) else {
                return false
            }
            return true

        default:
            return false
        }
    }

    private static func verifiedOfflineProvider(
        _ provider: ReaderDownloadProvider,
        route: MangaContentRoute
    ) -> ReaderDownloadProvider? {
        switch (route, provider.kind) {
        case let (.readerExtension(source, itemKey, _), .readerExtension):
            guard provider.sourceId == source.rawValue,
                  provider.mangaKey == itemKey else { return nil }
            return ReaderDownloadProvider(
                kind: .readerExtension,
                sourceId: source.rawValue,
                mangaKey: itemKey,
                moduleUUID: nil,
                contentParams: nil,
                isNovel: provider.isNovel,
                chapterParams: nil
            )

        case let (.aidoku(sourceID, mangaKey), .aidoku):
            guard provider.sourceId == sourceID,
                  provider.mangaKey == mangaKey else { return nil }
            return ReaderDownloadProvider(
                kind: .aidoku,
                sourceId: sourceID,
                mangaKey: mangaKey,
                moduleUUID: nil,
                contentParams: nil,
                isNovel: provider.isNovel,
                chapterParams: nil
            )

        case let (.legacyModule(moduleUUID, contentParams, isNovel), .legacyModule):
            guard provider.moduleUUID == moduleUUID,
                  provider.contentParams == contentParams,
                  provider.isNovel == isNovel else { return nil }
            return ReaderDownloadProvider(
                kind: .legacyModule,
                sourceId: nil,
                mangaKey: nil,
                moduleUUID: moduleUUID,
                contentParams: contentParams,
                isNovel: isNovel,
                chapterParams: nil
            )

        default:
            return nil
        }
    }

    private static func verifiedGeneratedPageFileName(
        _ page: ReaderDownloadedPageManifest
    ) -> Int? {
        guard page.index >= 0,
              page.index < maximumReadOnlyPagesPerChapter,
              page.fileName == (page.fileName as NSString).lastPathComponent,
              !page.fileName.contains("\\"),
              !page.fileName.contains("..") else { return nil }
        let expectedStem = String(format: "%04d", page.index + 1)
        let fileURL = URL(fileURLWithPath: page.fileName)
        guard fileURL.deletingPathExtension().lastPathComponent == expectedStem else { return nil }
        switch page.kind {
        case .text:
            return fileURL.pathExtension == "txt" ? maximumReadOnlyTextBytes : nil
        case .image:
            let ext = fileURL.pathExtension
            guard !ext.isEmpty,
                  ext.utf8.count <= 8,
                  ext == ext.lowercased(),
                  ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
            return maximumReadOnlyImageBytes
        }
    }

    private static func boundedOptionalMetadataString(
        _ value: String?,
        maximumBytes: Int
    ) -> Bool {
        value.map { boundedMetadataString($0, maximumBytes: maximumBytes, allowsEmpty: true) } ?? true
    }

    private static func boundedMetadataString(
        _ value: String,
        maximumBytes: Int,
        allowsEmpty: Bool = false
    ) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (allowsEmpty || !trimmed.isEmpty),
              value.utf8.count <= maximumBytes else { return false }
        return !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func verifiedDirectory(
        _ url: URL,
        inside root: URL? = nil,
        fileManager: FileManager
    ) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ]),
              values.isDirectory == true,
              values.isSymbolicLink != true else { return false }
        guard let root else { return true }
        return resolvedPath(url, isInside: root)
    }

    private static func verifiedRegularFileData(
        _ url: URL,
        inside root: URL,
        maximumBytes: Int,
        fileManager: FileManager
    ) -> Data? {
        guard resolvedPath(url, isInside: root),
              let data = try? BoundedLocalStoreReader.read(
                from: url,
                maximumBytes: maximumBytes
              ),
              !data.isEmpty,
              data.count <= maximumBytes else { return nil }
        return data
    }

    private static func verifiedRegularFileSize(
        _ url: URL,
        inside root: URL,
        maximumBytes: Int,
        fileManager: FileManager
    ) -> Int? {
        guard resolvedPath(url, isInside: root),
              let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0,
              size <= maximumBytes else { return nil }
        return size
    }

    private static func resolvedPath(_ child: URL, isInside root: URL) -> Bool {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedChild = child.resolvingSymlinksInPath().standardizedFileURL.path
        return resolvedChild.hasPrefix(resolvedRoot + "/")
    }

    @discardableResult
    private func loadDownloads() -> Bool {
        guard storesAreSafe else { return false }
        discardCoalescedIndexWrite()
        indexPersistenceQueue.sync {}
        let storedState = Self.persistedIndexReadState(at: persistenceURL)
        guard case .readable(let data) = storedState else {
            if storedState == .missing {
                persistedIndexAuthorityData = nil
                downloads = []
                return true
            }
            quarantineUnreadableDownloadIndex()
            return false
        }
        guard Self.persistedIndexJSONIsStructurallyBounded(data),
              let rawItems = try? JSONSerialization.jsonObject(with: data) as? [Any],
              rawItems.count <= Self.maximumReadOnlyItems else {
            quarantineUnreadableDownloadIndex()
            return false
        }

        persistedIndexAuthorityData = data
        var decoded: [ReaderDownloadItem] = []
        var seenIDs = Set<String>()
        decoded.reserveCapacity(rawItems.count)
        for rawItem in rawItems {
            guard JSONSerialization.isValidJSONObject(rawItem),
                  let itemData = try? JSONSerialization.data(withJSONObject: rawItem),
                  let item = try? JSONDecoder.readerDownloadDecoder.decode(
                    ReaderDownloadItem.self,
                    from: itemData
                  ),
                  Self.isValidPersistedItem(item),
                  seenIDs.insert(item.id).inserted else {
                quarantineUnreadableDownloadIndex()
                return false
            }
            decoded.append(item)
        }
        downloads = decoded
        return true
    }

    enum PersistedIndexReadState: Equatable {
        case missing
        case readable(Data)
        case unreadable
    }

    static func persistedIndexReadState(at url: URL) -> PersistedIndexReadState {
        var metadata = stat()
        let status: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &metadata)
        }
        guard status == 0 else {
            return errno == ENOENT ? .missing : .unreadable
        }
        guard let data = try? BoundedLocalStoreReader.read(
            from: url,
            maximumBytes: maximumReadOnlyIndexBytes
        ) else {
            return .unreadable
        }
        return .readable(data)
    }

    static func persistedIndexAuthorityIsCurrent(
        expected: Data?,
        observed: PersistedIndexReadState
    ) -> Bool {
        switch (expected, observed) {
        case (nil, .missing):
            return true
        case (.some(let expected), .readable(let observed)):
            return expected == observed
        default:
            return false
        }
    }

    static func firstDownloadPerID(
        _ items: [ReaderDownloadItem]
    ) -> [String: ReaderDownloadItem] {
        var result: [String: ReaderDownloadItem] = [:]
        for item in items where result[item.id] == nil {
            result[item.id] = item
        }
        return result
    }

    static func persistedIndexSchemaIsValid(_ data: Data) -> Bool {
        guard !data.isEmpty,
              data.count <= maximumReadOnlyIndexBytes,
              persistedIndexJSONIsStructurallyBounded(data),
              let rawItems = try? JSONSerialization.jsonObject(with: data) as? [Any],
              rawItems.count <= maximumReadOnlyItems else { return false }
        var seenIDs = Set<String>()
        for rawItem in rawItems {
            guard JSONSerialization.isValidJSONObject(rawItem),
                  let itemData = try? JSONSerialization.data(withJSONObject: rawItem),
                  let item = try? JSONDecoder.readerDownloadDecoder.decode(
                    ReaderDownloadItem.self,
                    from: itemData
                  ),
                  isValidPersistedItem(item),
                  seenIDs.insert(item.id).inserted else { return false }
        }
        return true
    }

    static func persistedItemsAreWithinLimits(_ items: [ReaderDownloadItem]) -> Bool {
        guard items.count <= maximumReadOnlyItems,
              let data = try? JSONEncoder.readerDownloadEncoder.encode(items),
              data.count <= maximumReadOnlyIndexBytes else { return false }
        return persistedIndexSchemaIsValid(data)
    }

    static func downloadIndexCanAcceptNewItem(currentItemCount: Int) -> Bool {
        currentItemCount >= 0 && currentItemCount < maximumReadOnlyItems
    }

    static func downloadPageBudgetAllows(
        pageCount: Int,
        accumulatedBytes: Int64,
        nextPageBytes: Int64
    ) -> Bool {
        guard pageCount > 0,
              pageCount <= maximumReadOnlyPagesPerChapter,
              accumulatedBytes >= 0,
              nextPageBytes > 0 else { return false }
        let (total, overflow) = accumulatedBytes.addingReportingOverflow(nextPageBytes)
        return !overflow && total <= maximumReadOnlyChapterBytes
    }

    static func persistedChapterManifestSchemaIsValid(_ data: Data) -> Bool {
        guard !data.isEmpty,
              data.count <= maximumReadOnlyManifestBytes,
              let manifest = decodePersistedManifest(data),
              manifest.version == 1,
              boundedMetadataString(manifest.itemId, maximumBytes: 256),
              boundedMetadataString(manifest.mangaTitle, maximumBytes: 4 * 1_024),
              boundedMetadataString(manifest.chapterNumber, maximumBytes: 1_024),
              verifiedOfflineRoute(manifest.route),
              manifest.itemId == downloadId(
                route: manifest.route,
                chapterNumber: manifest.chapterNumber
              ),
              !manifest.pages.isEmpty,
              manifest.pages.count <= maximumReadOnlyPagesPerChapter else { return false }
        let pages = manifest.pages.sorted { $0.index < $1.index }
        guard pages.map(\.index) == Array(0..<pages.count) else { return false }
        return pages.allSatisfy { verifiedGeneratedPageFileName($0) != nil }
    }

    /// Foundation's JSON decoders build their complete object graph before
    /// model-level row/page checks run. Perform a cheap structural pass first
    /// so a dense but syntactically valid index or manifest cannot amplify a
    /// bounded file into millions of Foundation objects during app startup.
    private static func persistedIndexJSONIsStructurallyBounded(_ data: Data) -> Bool {
        (try? ReaderExtensionJSONPreflight.validate(data, limits: .init(
            maximumBytes: maximumReadOnlyIndexBytes,
            maximumDepth: 32,
            maximumContainerEntries: maximumReadOnlyItems,
            maximumTopLevelEntries: maximumReadOnlyItems,
            maximumTotalTokens: 1_000_000,
            maximumStringBytes: 64 * 1_024
        ))) != nil
    }

    private static func decodePersistedManifest(
        _ data: Data
    ) -> ReaderDownloadedChapterManifest? {
        guard (try? ReaderExtensionJSONPreflight.validate(data, limits: .init(
            maximumBytes: maximumReadOnlyManifestBytes,
            maximumDepth: 16,
            maximumContainerEntries: maximumReadOnlyPagesPerChapter,
            maximumTopLevelEntries: 64,
            maximumTotalTokens: 100_000,
            // Durable keys are bounded after decoding; JSON escaping can
            // approximately double an otherwise valid 32 KiB string.
            maximumStringBytes: 64 * 1_024
        ))) != nil else { return nil }
        return try? JSONDecoder.readerDownloadDecoder.decode(
            ReaderDownloadedChapterManifest.self,
            from: data
        )
    }

    private func quarantineUnreadableDownloadIndex() {
        let quarantineURL = downloadsDirectory
            .appendingPathComponent(".reader_downloads.quarantine.json")
        guard !fileManager.fileExists(atPath: quarantineURL.path),
              case .readable(let data) = Self.persistedIndexReadState(at: persistenceURL),
              !data.isEmpty else { return }
        do {
            try data.write(to: quarantineURL, options: .atomic)
            var resourceURL = quarantineURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try resourceURL.setResourceValues(values)
        } catch {
            // The original index remains untouched and the manager still fails
            // closed, even when a best-effort quarantine copy cannot be made.
        }
    }

    /// If page files and a complete manifest reached disk before the index's
    /// final status transition, recover that chapter instead of treating it as
    /// resumable and deleting the self-contained offline copy on the next run.
    @discardableResult
    private func recoverCompletedManifestsIfNeeded() -> Bool {
        var candidate = downloads
        var recovered: [ReaderDownloadItem] = []
        for index in candidate.indices where candidate[index].status != .completed {
            guard let completed = Self.recoverableCompletedCopy(
                candidate[index],
                downloadsRoot: downloadsDirectory,
                fileManager: fileManager
            ) else { continue }
            candidate[index] = completed
            recovered.append(completed)
        }
        guard !recovered.isEmpty else { return true }
        if commitDownloads(
            candidate,
            failureMessage: "A completed Reader chapter was recovered, but its index could not be made writable. It remains available read-only."
        ) {
            return true
        }
        enterReadOnlyRecovery(retaining: recovered)
        return false
    }

    private func enterReadOnlyRecovery(retaining additional: [ReaderDownloadItem]) {
        discardCoalescedIndexWrite()
        indexPersistenceQueue.sync { indexWritesSuspended = true }
        let root = downloadsDirectory
        storesAreSafe = false
        let recoveredFromIndex = Self.verifiedCompletedDownloadsForReadOnlyFallback(
            indexURL: persistenceURL,
            downloadsRoot: root,
            fileManager: fileManager
        )
        var byID = Self.firstDownloadPerID(recoveredFromIndex)
        for item in additional {
            if let recovered = Self.recoverableCompletedCopy(
                item,
                downloadsRoot: root,
                fileManager: fileManager
            ) {
                byID[recovered.id] = recovered
            }
        }
        activeTasks.values.forEach { $0.cancel() }
        activeTasks.removeAll()
        queuedContexts.removeAll()
        pausedIds.removeAll()
        downloads = byID.values.sorted {
            ($0.dateCompleted ?? $0.dateAdded) < ($1.dateCompleted ?? $1.dateAdded)
        }
        endBackgroundTaskIfIdle()
        Logger.shared.log(
            "Reader downloads: storage became read-only; verified completed chapters remain available",
            type: "Storage"
        )
    }

    private func persistCandidate(_ candidate: [ReaderDownloadItem]) throws -> Data {
        guard storesAreSafe else { throw ReaderDownloadPersistenceError.unsafeState }
        let data = try JSONEncoder.readerDownloadEncoder.encode(candidate)
        guard data.count <= Self.maximumReadOnlyIndexBytes,
              Self.persistedIndexSchemaIsValid(data) else {
            throw ReaderDownloadPersistenceError.invalidIndex
        }
        try data.write(to: persistenceURL, options: .atomic)

        let handle = try FileHandle(forWritingTo: persistenceURL)
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        let directoryDescriptor = Darwin.open(downloadsDirectory.path, O_RDONLY)
        guard directoryDescriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(directoryDescriptor) }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        try synchronizeDirectory(downloadsDirectory.deletingLastPathComponent())
        guard case .readable(let verification) = Self.persistedIndexReadState(at: persistenceURL),
              verification == data else {
            throw ReaderDownloadPersistenceError.verificationFailed
        }
        return data
    }

    /// A completed index row is published only after every chapter artifact and
    /// directory entry has been read back and checkpointed. This keeps the
    /// durable index from pointing at page/manifest renames that existed only in
    /// the filesystem cache at the time of a sudden reboot.
    private func makeCompletedChapterDurable(
        item: ReaderDownloadItem,
        manifest: ReaderDownloadedChapterManifest,
        manifestData: Data,
        directory: URL
    ) throws {
        let manifestURL = directory.appendingPathComponent("chapter.json")
        guard Self.verifiedRegularFileData(
            manifestURL,
            inside: directory,
            maximumBytes: Self.maximumReadOnlyManifestBytes,
            fileManager: fileManager
        ) == manifestData,
              let verified = Self.verifiedReadOnlyChapter(
                item,
                downloadsRoot: downloadsDirectory,
                fileManager: fileManager
              ),
              verified.downloadedBytes == item.downloadedBytes else {
            throw ReaderDownloadPersistenceError.verificationFailed
        }

        // Each page was exact-readback verified and fsynced immediately after
        // its atomic write. The complete verifier above rechecks the manifest,
        // generated filenames, page sizes, UTF-8 text, and aggregate byte cap.
        try synchronizeFile(manifestURL)

        let titleDirectory = directory.deletingLastPathComponent()
        let rootDirectory = titleDirectory.deletingLastPathComponent()
        try synchronizeDirectory(directory)
        try synchronizeDirectory(titleDirectory)
        try synchronizeDirectory(rootDirectory)
        try synchronizeDirectory(rootDirectory.deletingLastPathComponent())
    }

    private func synchronizeFile(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    private enum IndexWriteOutcome {
        case success
        case staleAuthority
        case writeFailed(storedStateChanged: Bool)
    }

    @discardableResult
    private func commitDownloads(
        _ candidate: [ReaderDownloadItem],
        failureMessage: String = "Reader Downloads could not save this change. Try again after freeing device storage."
    ) -> Bool {
        discardCoalescedIndexWrite()
        let outcome = indexPersistenceQueue.sync { performIndexWrite(candidate) }
        switch outcome {
        case .success:
            downloads = candidate
            return true
        case .staleAuthority:
            enterReadOnlyRecovery(retaining: [])
            publishEnqueueError(failureMessage)
            ReaderLogger.shared.log(
                "Refused to overwrite a Reader download index that changed or became unreadable",
                type: "ReaderDownloadStorage"
            )
            return false
        case .writeFailed(let storedStateChanged):
            if storedStateChanged {
                enterReadOnlyRecovery(retaining: [])
            }
            publishEnqueueError(failureMessage)
            ReaderLogger.shared.log(
                "Failed to persist reader download index; mutation was not published",
                type: "ReaderDownloadStorage"
            )
            return false
        }
    }

    private func performIndexWrite(_ candidate: [ReaderDownloadItem]) -> IndexWriteOutcome {
        let priorStoredState = Self.persistedIndexReadState(at: persistenceURL)
        guard Self.persistedIndexAuthorityIsCurrent(
            expected: persistedIndexAuthorityData,
            observed: priorStoredState
        ) else {
            return .staleAuthority
        }
        do {
            let persisted = try persistCandidate(candidate)
            persistedIndexAuthorityData = persisted
            return .success
        } catch {
            // If an atomic write reached disk but its fsync/readback proof failed,
            // freeze all mutation/provider work. Readback equality alone is not
            // treated as crash durability.
            let storedState = Self.persistedIndexReadState(at: persistenceURL)
            return .writeFailed(storedStateChanged: storedState != priorStoredState)
        }
    }

    private func publishItemProgress(
        _ id: String,
        mutate: (inout ReaderDownloadItem) -> Void
    ) {
        guard storesAreSafe else { return }
        var candidate = downloads
        guard let index = candidate.firstIndex(where: { $0.id == id }) else { return }
        mutate(&candidate[index])
        downloads = candidate
        scheduleCoalescedIndexWrite(candidate)
    }

    private func scheduleCoalescedIndexWrite(_ candidate: [ReaderDownloadItem]) {
        coalescedWriteLock.lock()
        coalescedWriteCandidate = candidate
        let needsFlush = !coalescedWriteScheduled
        coalescedWriteScheduled = true
        coalescedWriteLock.unlock()
        guard needsFlush else { return }
        indexPersistenceQueue.async { [weak self] in
            self?.flushCoalescedIndexWrite()
        }
    }

    private func takeCoalescedIndexWrite() -> [ReaderDownloadItem]? {
        coalescedWriteLock.lock()
        let candidate = coalescedWriteCandidate
        coalescedWriteCandidate = nil
        coalescedWriteScheduled = false
        coalescedWriteLock.unlock()
        return candidate
    }

    private func discardCoalescedIndexWrite() {
        coalescedWriteLock.lock()
        coalescedWriteCandidate = nil
        coalescedWriteLock.unlock()
    }

    private func flushCoalescedIndexWrite() {
        guard let candidate = takeCoalescedIndexWrite(), !indexWritesSuspended else { return }
        switch performIndexWrite(candidate) {
        case .success:
            break
        case .staleAuthority:
            DispatchQueue.main.async { [weak self] in
                guard let self, self.storesAreSafe else { return }
                self.enterReadOnlyRecovery(retaining: [])
                ReaderLogger.shared.log(
                    "Refused to overwrite a Reader download index that changed or became unreadable",
                    type: "ReaderDownloadStorage"
                )
            }
        case .writeFailed(let storedStateChanged):
            guard storedStateChanged else {
                ReaderLogger.shared.log(
                    "Failed to persist a reader download progress snapshot; the durable index is unchanged",
                    type: "ReaderDownloadStorage"
                )
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.storesAreSafe else { return }
                self.enterReadOnlyRecovery(retaining: [])
                ReaderLogger.shared.log(
                    "Failed to persist reader download index; mutation was not published",
                    type: "ReaderDownloadStorage"
                )
            }
        }
    }

    private func publishEnqueueError(_ message: String) {
        enqueueErrorMessage = message
        ReaderLogger.shared.log("Reader download request rejected by a storage limit", type: "ReaderDownloadStorage")
    }

    private func normalizeInterruptedDownloads() {
        var candidate = downloads
        var changed = false
        for index in candidate.indices where candidate[index].status == .downloading {
            candidate[index].status = .paused
            candidate[index].error = "Paused after app restart"
            changed = true
        }
        if changed { _ = commitDownloads(candidate) }
    }

    private func normalizeReaderExtensionAuthenticationScopes() {
        let activeProfileID = ProfileManager.shared.activeProfileID
        var candidate = downloads
        var changed = false
        for index in candidate.indices
        where candidate[index].provider.kind == .readerExtension
            && candidate[index].status != .completed
            && !Self.authenticationScopeAllowsExecution(
                candidate[index].provider,
                activeProfileID: activeProfileID
            ) {
            switch candidate[index].status {
            case .queued, .downloading, .paused:
                candidate[index].status = .paused
                candidate[index].error = "Resume this download to use the active profile's authentication."
                changed = true
            case .failed, .none, .completed:
                break
            }
        }
        if changed { _ = commitDownloads(candidate) }
    }

    static func authenticationScopeAllowsExecution(
        _ provider: ReaderDownloadProvider,
        activeProfileID: UUID
    ) -> Bool {
        provider.kind != .readerExtension
            || provider.authenticationProfileID == activeProfileID
    }

    private func requireCurrentAuthenticationScope(
        _ provider: ReaderDownloadProvider
    ) throws {
        guard Self.authenticationScopeAllowsExecution(
            provider,
            activeProfileID: ProfileManager.shared.activeProfileID
        ) else {
            throw downloadError(
                "This download is paused because the active Reader profile changed. Resume it to authorize this profile."
            )
        }
    }

    private func normalizeRemovedAidokuDownloads() {
        var candidate = downloads
        var changed = false
        for index in candidate.indices
        where candidate[index].provider.kind == .aidoku && candidate[index].status != .completed {
            if candidate[index].legacyResumeStatus == nil {
                switch candidate[index].status {
                case .queued:
                    candidate[index].legacyResumeStatus = .queued
                case .downloading, .paused:
                    candidate[index].legacyResumeStatus = .paused
                case .failed, .none:
                    candidate[index].legacyResumeStatus = .failed
                case .completed:
                    break
                }
            }
            candidate[index].status = .failed
            candidate[index].error = "Previous Reader source unavailable. Reconnect the title to resume."
            changed = true
        }
        if changed { _ = commitDownloads(candidate) }
    }

    private var hasDownloadsNeedingReconnectHydration: Bool {
        let activeProfileID = ProfileManager.shared.activeProfileID
        return downloads.contains {
            Self.needsReconnectHydration($0)
                && Self.authenticationScopeAllowsExecution(
                    $0.provider,
                    activeProfileID: activeProfileID
                )
        }
    }

    private static func needsReconnectHydration(_ item: ReaderDownloadItem) -> Bool {
        guard item.status != .completed,
              item.provider.kind == .readerExtension,
              item.provider.chapterParams == nil,
              let sourceRaw = item.provider.sourceId,
              ReaderExtensionSourceID(rawValue: sourceRaw).isValid,
              let itemKey = item.provider.mangaKey,
              !itemKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              case .readerExtension(let routeSource, let routeItemKey, let legacyStableKey) = item.route,
              legacyStableKey?.hasPrefix("aidoku:") == true,
              routeSource.rawValue == sourceRaw,
              routeItemKey == itemKey else { return false }
        return true
    }

    /// A replacement chapter is accepted only when the persisted chapter identity is
    /// internally consistent and exactly one chapter in the strongly verified replacement
    /// title has that normalized identity. A nonempty legacy chapter title must also agree
    /// with the replacement title after Unicode/case/punctuation normalization. Agreement
    /// allows the common split representation (`number = 12`, `title = The Beginning`)
    /// against `Chapter 12 - The Beginning`, but title text is never used to disambiguate
    /// duplicate chapter identities.
    static func verifiedReplacementChapterKey(
        for item: ReaderDownloadItem,
        candidates: [ReaderExtensionChapter]
    ) -> String? {
        guard item.status != .completed,
              candidates.count <= 5_000,
              !item.chapterKey.isEmpty,
              item.chapterKey == ChapterIdentityNormalizer.key(for: item.chapterNumber) else {
            return nil
        }
        let identityMatches = candidates.filter {
            ChapterIdentityNormalizer.key(for: $0.title) == item.chapterKey
        }
        guard identityMatches.count == 1, let match = identityMatches.first else {
            return nil
        }
        if let legacyTitle = item.chapterTitle?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !legacyTitle.isEmpty,
           !reconnectChapterTitlesAgree(
                legacy: legacyTitle,
                replacement: match.title
           ) {
            return nil
        }
        let key = match.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.utf8.count <= 8 * 1_024, !key.hasPrefix("aidoku:") else { return nil }
        return persistableReaderExtensionChapterKey(key)
    }

    @discardableResult
    static func applyVerifiedReplacementChapterKey(
        _ replacementKey: String,
        to item: inout ReaderDownloadItem
    ) -> Bool {
        let key = replacementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needsReconnectHydration(item), key.utf8.count <= 8 * 1_024,
              !key.hasPrefix("aidoku:"),
              let persistableKey = persistableReaderExtensionChapterKey(key) else {
            return false
        }
        let resumeStatus = item.legacyResumeStatus ?? item.status
        item.provider.chapterParams = persistableKey
        item.legacyResumeStatus = nil
        switch resumeStatus {
        case .queued:
            item.status = .queued
            item.error = nil
        case .downloading, .paused:
            item.status = .paused
            item.error = "Paused"
        case .failed, .none, .completed:
            item.status = .failed
            item.error = "Source reconnected. Retry this download when ready."
        }
        return true
    }

    private static func reconnectChapterTitlesAgree(
        legacy: String,
        replacement: String
    ) -> Bool {
        let legacyTokens = normalizedReconnectChapterTitleTokens(legacy)
        let replacementTokens = normalizedReconnectChapterTitleTokens(replacement)
        guard !legacyTokens.isEmpty, !replacementTokens.isEmpty else { return false }
        if legacyTokens == replacementTokens { return true }
        guard legacyTokens.count <= replacementTokens.count else { return false }

        // The unique normalized chapter identity was already established above.
        // This containment check validates descriptive metadata only; it never
        // chooses among two chapters with the same number.
        for start in 0...(replacementTokens.count - legacyTokens.count) {
            if Array(replacementTokens[start..<(start + legacyTokens.count)]) == legacyTokens {
                return true
            }
        }
        return false
    }

    private static func normalizedReconnectChapterTitleTokens(
        _ value: String
    ) -> [String] {
        let normalized = value.precomposedStringWithCanonicalMapping.lowercased()
        var words: [String] = []
        var current = ""
        for character in normalized {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                words.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    @MainActor
    private func hydrateReconnectedDownloads(onlyIDs: Set<String>? = nil) async {
        let candidates = downloads
            .filter { item in
                Self.needsReconnectHydration(item)
                    && Self.authenticationScopeAllowsExecution(
                        item.provider,
                        activeProfileID: ProfileManager.shared.activeProfileID
                    )
                    && (onlyIDs == nil || onlyIDs?.contains(item.id) == true)
            }
            .sorted { $0.id < $1.id }
            .prefix(Self.maximumReconnectHydrationItems)
        guard !candidates.isEmpty else { return }

        var itemIDsByKey: [ReaderReconnectHydrationKey: [String]] = [:]
        for item in candidates {
            guard let sourceRaw = item.provider.sourceId,
                  let itemKey = item.provider.mangaKey,
                  let authenticationProfileID = item.provider.authenticationProfileID else { continue }
            let key = ReaderReconnectHydrationKey(
                sourceID: ReaderExtensionSourceID(rawValue: sourceRaw),
                itemKey: itemKey,
                authenticationProfileID: authenticationProfileID
            )
            itemIDsByKey[key, default: []].append(item.id)
        }
        let keys = itemIDsByKey.keys.sorted {
            if $0.sourceID.rawValue != $1.sourceID.rawValue {
                return $0.sourceID.rawValue < $1.sourceID.rawValue
            }
            return $0.itemKey < $1.itemKey
        }.prefix(Self.maximumReconnectDetailFetches)

        var results: [ReaderReconnectHydrationResult] = []
        let boundedKeys = Array(keys)
        for start in stride(
            from: 0,
            to: boundedKeys.count,
            by: Self.maximumConcurrentReconnectDetailFetches
        ) {
            let end = min(
                start + Self.maximumConcurrentReconnectDetailFetches,
                boundedKeys.count
            )
            let batch = Array(boundedKeys[start..<end])
            let batchResults = await withTaskGroup(
                of: ReaderReconnectHydrationResult.self,
                returning: [ReaderReconnectHydrationResult].self
            ) { group in
                for key in batch {
                    group.addTask {
                        do {
                            let provider = try await ReaderExtensionManager.shared.provider(
                                for: key.sourceID,
                                readerDownloadProfileID: key.authenticationProfileID
                            )
                            return ReaderReconnectHydrationResult(
                                key: key,
                                chapters: try await provider.chapters(itemKey: key.itemKey)
                            )
                        } catch {
                            return ReaderReconnectHydrationResult(key: key, chapters: nil)
                        }
                    }
                }
                var values: [ReaderReconnectHydrationResult] = []
                for await value in group { values.append(value) }
                return values
            }
            results.append(contentsOf: batchResults)
        }

        var candidateDownloads = downloads
        var changed = false
        for result in results {
            guard let itemIDs = itemIDsByKey[result.key] else { continue }
            for id in itemIDs {
                guard let index = candidateDownloads.firstIndex(where: { $0.id == id }),
                      Self.needsReconnectHydration(candidateDownloads[index]) else { continue }
                guard let chapters = result.chapters,
                      let replacementKey = Self.verifiedReplacementChapterKey(
                        for: candidateDownloads[index],
                        candidates: chapters
                      ) else {
                    candidateDownloads[index].status = .failed
                    candidateDownloads[index].error = "Source unavailable: the replacement chapter could not be verified."
                    changed = true
                    continue
                }

                changed = Self.applyVerifiedReplacementChapterKey(
                    replacementKey,
                    to: &candidateDownloads[index]
                ) || changed
            }
        }
        if changed {
            _ = commitDownloads(candidateDownloads)
        }
    }

    private func loadManifest(for item: ReaderDownloadItem) -> ReaderDownloadedChapterManifest? {
        let directory = chapterDirectory(for: item)
        let url = directory.appendingPathComponent("chapter.json")
        guard let data = Self.verifiedRegularFileData(
            url,
            inside: directory,
            maximumBytes: Self.maximumReadOnlyManifestBytes,
            fileManager: fileManager
        ), Self.persistedChapterManifestSchemaIsValid(data),
           let manifest = Self.decodePersistedManifest(data),
           manifest.itemId == item.id,
           manifest.route == item.route,
           manifest.chapterNumber == item.chapterNumber else { return nil }
        return manifest
    }

    @discardableResult
    private func updateItem(
        _ id: String,
        mutate: (inout ReaderDownloadItem) -> Void
    ) -> Bool {
        var candidate = downloads
        guard let index = candidate.firstIndex(where: { $0.id == id }) else { return false }
        mutate(&candidate[index])
        return commitDownloads(candidate)
    }

    private func failItem(_ id: String, message: String) {
        guard updateItem(id, mutate: {
            $0.status = .failed
            $0.error = message
        }) else { return }
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
        contentRating: Int? = nil,
        message: String
    ) {
        let id = Self.downloadId(route: route, chapterNumber: chapter.chapterNumber)
        let provider: ReaderDownloadProvider
        switch route {
        case .readerExtension(let source, let itemKey, _):
            provider = ReaderDownloadProvider(
                kind: .readerExtension,
                sourceId: source.rawValue,
                mangaKey: itemKey,
                moduleUUID: nil,
                contentParams: nil,
                isNovel: false,
                chapterParams: nil,
                authenticationProfileID: ProfileManager.shared.activeProfileID
            )
        case .aidoku(let sourceID, let mangaKey):
            provider = ReaderDownloadProvider(
                kind: .aidoku,
                sourceId: sourceID,
                mangaKey: mangaKey,
                moduleUUID: nil,
                contentParams: nil,
                isNovel: false,
                chapterParams: nil
            )
        case .legacyModule(let moduleUUID, let contentParams, let isNovel):
            provider = ReaderDownloadProvider(
                kind: .legacyModule,
                sourceId: nil,
                mangaKey: nil,
                moduleUUID: moduleUUID,
                contentParams: contentParams,
                isNovel: isNovel,
                chapterParams: nil
            )
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
            contentRating: contentRating,
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
        var candidate = downloads
        if let index = candidate.firstIndex(where: { $0.id == id }) {
            candidate[index] = item
        } else {
            guard Self.downloadIndexCanAcceptNewItem(currentItemCount: candidate.count) else {
                publishEnqueueError(
                    "Reader Downloads can store up to \(Self.maximumReadOnlyItems.formatted()) chapters. Remove an existing download before adding another."
                )
                return
            }
            candidate.append(item)
        }
        guard Self.persistedItemsAreWithinLimits(candidate) else {
            publishEnqueueError(
                "This failed download could not be recorded because the Reader download index reached its safe storage limit."
            )
            return
        }
        guard commitDownloads(candidate) else { return }
        ReaderLogger.shared.log("Reader download unsupported id=\(id) reason=\(message)", type: "ReaderDownload")
    }

    private func provider(for route: MangaContentRoute, chapter: Chapter) -> ReaderDownloadProvider? {
        let params = chapter.chapterData?.first?.params
        switch route {
        case .readerExtension(let source, let itemKey, _):
            guard let payload = params as? ReaderExtensionChapterPayload,
                  ReaderExtensionSecurityPolicy.persistableProviderContentKey(itemKey) != nil,
                  let chapterKey = Self.persistableReaderExtensionChapterKey(payload.chapter.key) else { return nil }
            return ReaderDownloadProvider(
                kind: .readerExtension,
                sourceId: source.rawValue,
                mangaKey: itemKey,
                moduleUUID: nil,
                contentParams: nil,
                isNovel: payload.mediaType == .novel,
                chapterParams: chapterKey,
                authenticationProfileID: ProfileManager.shared.activeProfileID
            )
        case .aidoku(let sourceId, let mangaKey):
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

    static func persistableReaderExtensionChapterKey(_ rawValue: String) -> String? {
        ReaderExtensionSecurityPolicy.persistableProviderContentKey(rawValue)
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

                contentRating: group.allSatisfy { $0.contentRating != nil }
                    ? group.compactMap(\.contentRating).max()
                    : nil,
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
            forName: .activeProfileDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pauseReaderExtensionDownloadsForProfileChange()
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.processQueue() }
        }
        NotificationCenter.default.addObserver(
            forName: .readerExtensionLegacyRoutesDidReconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let legacyIDs = Set(
                    self.downloads
                        .filter { $0.provider.kind == .aidoku }
                        .map(\.id)
                )
                for id in legacyIDs {
                    self.activeTasks[id]?.cancel()
                    self.queuedContexts[id] = nil
                    self.pausedIds.remove(id)
                }
                guard self.loadDownloads() else {
                    self.storesAreSafe = false
                    self.downloads = Self.verifiedCompletedDownloadsForReadOnlyFallback(
                        indexURL: self.persistenceURL,
                        downloadsRoot: self.downloadsDirectory,
                        fileManager: self.fileManager
                    )
                    self.objectWillChange.send()
                    return
                }
                guard self.recoverCompletedManifestsIfNeeded() else { return }
                self.normalizeInterruptedDownloads()
                self.normalizeReaderExtensionAuthenticationScopes()
                self.normalizeRemovedAidokuDownloads()
                await self.hydrateReconnectedDownloads()
                self.objectWillChange.send()
                self.processQueue()
            }
        }
    }

    private func pauseReaderExtensionDownloadsForProfileChange() {
        guard storesAreSafe else { return }
        let activeProfileID = ProfileManager.shared.activeProfileID
        let affectedIDs = downloads.compactMap { item -> String? in
            guard item.provider.kind == .readerExtension,
                  item.status == .queued || item.status == .downloading,
                  !Self.authenticationScopeAllowsExecution(
                    item.provider,
                    activeProfileID: activeProfileID
                  ) else { return nil }
            return item.id
        }
        guard !affectedIDs.isEmpty else {
            processQueue()
            return
        }
        let affected = Set(affectedIDs)
        for id in affected {
            pausedIds.insert(id)
            activeTasks[id]?.cancel()
            queuedContexts[id] = nil
        }
        var candidate = downloads
        for index in candidate.indices where affected.contains(candidate[index].id) {
            candidate[index].status = .paused
            candidate[index].error = "Paused after a profile change. Resume to use the active profile's authentication."
        }
        _ = commitDownloads(candidate)
        endBackgroundTaskIfIdle()
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

}

@MainActor
private extension ReaderExtensionManager {
    func provider(
        for sourceID: ReaderExtensionSourceID,
        readerDownloadProfileID: UUID?
    ) throws -> any ReaderSourceProvider {
        guard let readerDownloadProfileID,
              ProfileManager.shared.activeProfileID == readerDownloadProfileID else {
            throw ReaderExtensionError.persistenceFailed(
                "Reader profile changed before the download provider was created"
            )
        }
        return try provider(for: sourceID)
    }

    func pageResources(
        for pages: [ReaderExtensionPage],
        sourceID: ReaderExtensionSourceID,
        readerDownloadProfileID: UUID?
    ) throws -> [ReaderExtensionPageResource] {
        guard let readerDownloadProfileID,
              ProfileManager.shared.activeProfileID == readerDownloadProfileID else {
            throw ReaderExtensionError.persistenceFailed(
                "Reader profile changed before download pages were authorized"
            )
        }
        return try pageResources(for: pages, sourceID: sourceID)
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
