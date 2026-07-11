// Created on 27/02/26.

import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Download Item Model

enum DownloadStatus: String, Codable {
    case queued
    case downloading
    case paused
    case completed
    case failed
}

enum DownloadEnqueueResult {
    case enqueued
    case alreadyExists
    case adoptedExistingFile
}

enum AutoModeDownloadValidationResult: Equatable {
    case valid
    case invalid(reason: String)
    case cancelled
}

enum AutoModeDownloadEnqueueResult {
    case accepted(DownloadEnqueueResult)
    case invalid(reason: String)
    case cancelled
}

struct DownloadItem: Codable, Identifiable {
    let id: String
    let tmdbId: Int
    let isMovie: Bool
    let title: String
    let displayTitle: String
    let posterURL: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let episodeName: String?
    let streamURL: String
    let headers: [String: String]
    let subtitleURL: String?
    let subtitleHeaders: [String: String]?
    let serviceBaseURL: String
    let episodePlaybackContext: EpisodePlaybackContext?
    var status: DownloadStatus
    var progress: Double
    var totalBytes: Int64
    var downloadedBytes: Int64
    var localFileName: String?
    var subtitleFileName: String?
    /// Stable destinations reserved before a transfer starts. These remain optional so
    /// metadata written by older Eclipse builds continues to decode without migration.
    var reservedVideoFileName: String? = nil
    var reservedSubtitleFileName: String? = nil
    var error: String?
    var dateAdded: Date
    var dateCompleted: Date?
    let isAnime: Bool

    // HLS resume checkpoint (nil for non-HLS or downloads with no progress yet).
    var hlsResumeSegmentIndex: Int?   // segments fully written to the partial file
    var hlsResumeByteCount: Int64?    // partial byte length at that checkpoint
    var hlsVariantURL: String?        // pinned variant playlist for an identical resume
    var hlsTotalSegments: Int?        // segment count, used to validate a resume
    
    var isHLS: Bool {
        streamURL.lowercased().contains(".m3u8")
    }
    
    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        if totalBytes > 0 {
            return "\(formatter.string(fromByteCount: downloadedBytes)) / \(formatter.string(fromByteCount: totalBytes))"
        } else if downloadedBytes > 0 {
            return formatter.string(fromByteCount: downloadedBytes)
        }
        return ""
    }

    var playerTitleBase: String {
        guard isAnime else { return title }
        guard !isMovie else { return nonEmptyTrimmed(displayTitle) ?? title }
        return animeDisplayTitleWithoutEpisodeSuffix
    }

    private var animeDisplayTitleWithoutEpisodeSuffix: String {
        var base = nonEmptyTrimmed(displayTitle) ?? title
        let suffixPatterns = [
            #"(?i)\s*-\s*S\d{1,2}E\d{1,4}$"#,
            #"(?i)\s*S\d{1,2}E\d{1,4}$"#,
            #"(?i)\s*-\s*E\d{1,4}$"#,
            #"(?i)\s*E\d{1,4}$"#,
            #"(?i)\s*Episode\s+\d{1,4}$"#
        ]

        for pattern in suffixPatterns {
            if let range = base.range(of: pattern, options: .regularExpression) {
                base.removeSubrange(range)
                break
            }
        }

        return nonEmptyTrimmed(base) ?? title
    }

    private func nonEmptyTrimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
    
    var mediaInfo: MediaInfo {
        if isMovie {
            return .movie(id: tmdbId, title: playerTitleBase, posterURL: posterURL, isAnime: isAnime)
        } else {
            return .episode(
                showId: tmdbId,
                seasonNumber: seasonNumber ?? 1,
                episodeNumber: episodeNumber ?? 1,
                showTitle: playerTitleBase,
                showPosterURL: posterURL,
                isAnime: isAnime
            )
        }
    }
}

// MARK: - Download Manager

final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()
    
    @Published private(set) var downloads: [DownloadItem] = []
    
    private var backgroundSession: URLSession!
    private var activeTasks: [String: URLSessionDownloadTask] = [:]
    private var resumeDataStore: [String: Data] = [:]
    private var lastProgressUpdate: [String: Date] = [:]
    private var lastHLSCheckpointSave: [String: Date] = [:]
    private var activeHLSDownloaders: [String: HLSDownloader] = [:]
    #if canImport(UIKit)
    private var lifecycleObservers: [NSObjectProtocol] = []
    #endif
    
    private let maxConcurrentDownloads = 2
    private let maxConcurrentHLSDownloads = 1
    private let minimumFreeBytesForHLS: Int64 = 750 * 1024 * 1024
    private let autoModeDirectProbeMinimumBytes = 256 * 1024
    private let autoModeHLSSegmentProbeMinimumBytes = 8 * 1024
    private let autoModePlaylistProbeLimit = 1024 * 1024
    private let fileManager = FileManager.default
    private let accessQueue = DispatchQueue(label: "app.eclipse.soupy.download-manager", attributes: .concurrent)
    private var backgroundHLSPipelineEnabled: Bool {
        UserDefaults.standard.bool(forKey: "backgroundHLSPipelineEnabled")
    }
    
    private var persistenceURL: URL {
        downloadsDirectory.appendingPathComponent(".downloads_metadata.json")
    }

    private var legacyDownloadsDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads")
    }
    
    var downloadsDirectory: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = documents.appendingPathComponent("Downloads", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    
    /// Background session completion handler set by AppDelegate/SceneDelegate
    var backgroundCompletionHandler: (() -> Void)?
    
    private override init() {
        super.init()

        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
        
        let config = URLSessionConfiguration.background(withIdentifier: "app.eclipse.soupy.downloads")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.httpMaximumConnectionsPerHost = 4
        backgroundSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        
        migrateLegacyDownloadsDirectoryIfNeeded()
        loadDownloads()
        ensureDownloadPathReservations()
        migrateTrackedDownloadsToPublicLayout()
        observeAppLifecycle()
        
        // Keep user-visible imports intact; only stale hidden partials are pruned.
        cleanOrphanedFiles()
        
        // Resume any downloads that were marked as downloading (app was killed)
        resumeInterruptedDownloads()
    }

    deinit {
        #if canImport(UIKit)
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        #endif
    }

    private func observeAppLifecycle() {
        #if canImport(UIKit) && !os(watchOS)
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.processQueue()
            }
        )
        #endif
    }

    private func performOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
    
    // MARK: - Public API
    
    var activeDownloads: [DownloadItem] {
        downloads.filter { $0.status == .downloading || $0.status == .queued }
    }
    
    var completedDownloads: [DownloadItem] {
        downloads.filter { $0.status == .completed }
    }
    
    var failedDownloads: [DownloadItem] {
        downloads.filter { $0.status == .failed }
    }
    
    var activeDownloadCount: Int {
        downloads.filter { $0.status == .downloading }.count
    }

    /// Performs a bounded network preflight for Auto Mode before an item is enqueued.
    /// Direct files must deliver enough real bytes to rule out tiny error payloads. HLS
    /// streams are checked as a playlist plus one media segment because playlists are
    /// legitimately small. Nothing from the probe is persisted to the downloads folder.
    func validateAutoModeDownload(
        streamURL: String,
        headers: [String: String]
    ) async -> AutoModeDownloadValidationResult {
        guard let url = URL(string: streamURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .invalid(reason: "The source returned an invalid download URL.")
        }

        let isHLS = streamURL.lowercased().contains(".m3u8")
        let host = url.host ?? "unknown host"
        let maximumAttempts = 2

        for attempt in 1...maximumAttempts {
            do {
                try Task.checkCancellation()
                if isHLS {
                    try await validateAutoModeHLSDownload(url: url, headers: headers)
                } else {
                    try await validateAutoModeDirectDownload(url: url, headers: headers)
                }
                try Task.checkCancellation()

                Logger.shared.log(
                    "Auto Mode download validation passed host=\(host) kind=\(isHLS ? "hls" : "direct") attempt=\(attempt)",
                    type: "Download"
                )
                return .valid
            } catch {
                if Task.isCancelled || error is CancellationError {
                    Logger.shared.log("Auto Mode download validation cancelled host=\(host)", type: "Download")
                    return .cancelled
                }

                let failure = autoModeValidationFailure(from: error)
                if attempt < maximumAttempts && failure.isRetryable {
                    Logger.shared.log(
                        "Auto Mode download validation retry host=\(host) reason=\(failure.message)",
                        type: "Download"
                    )
                    do {
                        try await Task.sleep(nanoseconds: 350_000_000)
                    } catch {
                        return .cancelled
                    }
                    continue
                }

                Logger.shared.log(
                    "Auto Mode download validation failed host=\(host) reason=\(failure.message)",
                    type: "Download"
                )
                return .invalid(reason: failure.message)
            }
        }

        return .invalid(reason: "The download stream could not be verified.")
    }

    /// Auto Mode's authoritative enqueue path. Existing/adoptable files are resolved
    /// before touching the network; new downloads are only enqueued after validation.
    @MainActor
    func enqueueValidatedAutoModeDownload(
        tmdbId: Int,
        isMovie: Bool,
        title: String,
        displayTitle: String,
        posterURL: String?,
        seasonNumber: Int?,
        episodeNumber: Int?,
        episodeName: String?,
        streamURL: String,
        headers: [String: String],
        subtitleURL: String?,
        subtitleHeaders: [String: String]? = nil,
        serviceBaseURL: String,
        isAnime: Bool,
        episodePlaybackContext: EpisodePlaybackContext? = nil,
        cancellationRequested: @escaping @MainActor () -> Bool = { false }
    ) async -> AutoModeDownloadEnqueueResult {
        guard !cancellationRequested() else { return .cancelled }

        let id = isMovie
            ? "dl_movie_\(tmdbId)"
            : "dl_ep_\(tmdbId)_s\(seasonNumber ?? 0)_e\(episodeNumber ?? 0)"
        let candidate = DownloadItem(
            id: id,
            tmdbId: tmdbId,
            isMovie: isMovie,
            title: title,
            displayTitle: displayTitle,
            posterURL: posterURL,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            episodeName: episodeName,
            streamURL: streamURL,
            headers: headers,
            subtitleURL: subtitleURL,
            subtitleHeaders: subtitleHeaders,
            serviceBaseURL: serviceBaseURL,
            episodePlaybackContext: episodePlaybackContext,
            status: .queued,
            progress: 0,
            totalBytes: 0,
            downloadedBytes: 0,
            localFileName: nil,
            subtitleFileName: nil,
            error: nil,
            dateAdded: Date(),
            dateCompleted: nil,
            isAnime: isAnime
        )

        if let existingResult = existingAutoModeDownloadOutcome(for: candidate) {
            return .accepted(existingResult)
        }

        let validation = await validateAutoModeDownload(streamURL: streamURL, headers: headers)
        guard !cancellationRequested() else { return .cancelled }

        switch validation {
        case .valid:
            let result = enqueueDownload(
                tmdbId: tmdbId,
                isMovie: isMovie,
                title: title,
                displayTitle: displayTitle,
                posterURL: posterURL,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber,
                episodeName: episodeName,
                streamURL: streamURL,
                headers: headers,
                subtitleURL: subtitleURL,
                subtitleHeaders: subtitleHeaders,
                serviceBaseURL: serviceBaseURL,
                isAnime: isAnime,
                episodePlaybackContext: episodePlaybackContext
            )
            return .accepted(result)
        case .invalid(let reason):
            return .invalid(reason: reason)
        case .cancelled:
            return .cancelled
        }
    }

    @MainActor
    private func existingAutoModeDownloadOutcome(for candidate: DownloadItem) -> DownloadEnqueueResult? {
        if let existing = downloads.first(where: { $0.id == candidate.id }) {
            switch existing.status {
            case .completed:
                if localFileURL(for: existing) != nil {
                    Logger.shared.log("Auto Mode download already exists: \(candidate.id)", type: "Download")
                    return .alreadyExists
                }
                if adoptExistingDownloadedFileIfPresent(for: candidate) {
                    Logger.shared.log("Auto Mode adopted existing file: \(candidate.displayTitle)", type: "Download")
                    return .adoptedExistingFile
                }
            case .downloading, .queued, .paused:
                Logger.shared.log("Auto Mode download already active: \(candidate.id)", type: "Download")
                return .alreadyExists
            case .failed:
                if adoptExistingDownloadedFileIfPresent(for: candidate) {
                    Logger.shared.log("Auto Mode adopted existing file: \(candidate.displayTitle)", type: "Download")
                    return .adoptedExistingFile
                }
            }
        } else if adoptExistingDownloadedFileIfPresent(for: candidate) {
            Logger.shared.log("Auto Mode adopted existing file: \(candidate.displayTitle)", type: "Download")
            return .adoptedExistingFile
        }

        return nil
    }
    
    @discardableResult
    @MainActor
    func enqueueDownload(
        tmdbId: Int,
        isMovie: Bool,
        title: String,
        displayTitle: String,
        posterURL: String?,
        seasonNumber: Int?,
        episodeNumber: Int?,
        episodeName: String?,
        streamURL: String,
        headers: [String: String],
        subtitleURL: String?,
        subtitleHeaders: [String: String]? = nil,
        serviceBaseURL: String,
        isAnime: Bool,
        episodePlaybackContext: EpisodePlaybackContext? = nil
    ) -> DownloadEnqueueResult {
        let id: String
        if isMovie {
            id = "dl_movie_\(tmdbId)"
        } else {
            id = "dl_ep_\(tmdbId)_s\(seasonNumber ?? 0)_e\(episodeNumber ?? 0)"
        }

        var item = DownloadItem(
            id: id,
            tmdbId: tmdbId,
            isMovie: isMovie,
            title: title,
            displayTitle: displayTitle,
            posterURL: posterURL,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            episodeName: episodeName,
            streamURL: streamURL,
            headers: headers,
            subtitleURL: subtitleURL,
            subtitleHeaders: subtitleHeaders,
            serviceBaseURL: serviceBaseURL,
            episodePlaybackContext: episodePlaybackContext,
            status: .queued,
            progress: 0,
            totalBytes: 0,
            downloadedBytes: 0,
            localFileName: nil,
            subtitleFileName: nil,
            error: nil,
            dateAdded: Date(),
            dateCompleted: nil,
            isAnime: isAnime
        )

        // Check if already downloading, paused, completed, or manually present in Files.
        if let existing = downloads.first(where: { $0.id == id }) {
            switch existing.status {
            case .completed:
                if localFileURL(for: existing) != nil {
                    Logger.shared.log("Download already exists: \(id) status=\(existing.status.rawValue)", type: "Download")
                    return .alreadyExists
                }
                if adoptExistingDownloadedFileIfPresent(for: item) {
                    Logger.shared.log("Adopted existing download file for missing metadata path: \(displayTitle)", type: "Download")
                    return .adoptedExistingFile
                }
                downloads.removeAll { $0.id == id }
            case .downloading, .queued, .paused:
                Logger.shared.log("Download already exists: \(id) status=\(existing.status.rawValue)", type: "Download")
                return .alreadyExists
            case .failed:
                if adoptExistingDownloadedFileIfPresent(for: item) {
                    Logger.shared.log("Skipped download by adopting existing file: \(displayTitle)", type: "Download")
                    return .adoptedExistingFile
                }
                deleteDownloadFiles(for: existing, includePartial: true, removingIDs: Set([id]))
                downloads.removeAll { $0.id == id }
            }
        } else if adoptExistingDownloadedFileIfPresent(for: item) {
            Logger.shared.log("Skipped download by adopting existing file: \(displayTitle)", type: "Download")
            return .adoptedExistingFile
        }

        item = itemByReservingVideoDestination(item)
        downloads.append(item)
        saveDownloads()
        processQueue()
        
        Logger.shared.log("Enqueued download: \(displayTitle) id=\(id)", type: "Download")
        return .enqueued
    }
    
    func pauseDownload(id: String) {
        performOnMain { [weak self] in
            guard let self,
                  let index = downloads.firstIndex(where: { $0.id == id }),
                  downloads[index].status == .downloading else { return }

            if let task = activeTasks[id] {
                task.cancel(byProducingResumeData: { [weak self] data in
                    guard let data else { return }
                    self?.performOnMain {
                        self?.resumeDataStore[id] = data
                    }
                })
                activeTasks.removeValue(forKey: id)
            } else if let downloader = activeHLSDownloaders[id] {
                // HLS downloads do not support resume; cancel and restart on resume.
                // Keep the HLS lane occupied until cancellation is confirmed.
                downloader.cancel()
            }

            guard let currentIndex = downloads.firstIndex(where: { $0.id == id }) else {
                return
            }
            downloads[currentIndex].status = .paused
            saveDownloads()
            processQueue()
            Logger.shared.log("Paused download: \(id)", type: "Download")
        }
    }

    func resumeDownload(id: String) {
        performOnMain { [weak self] in
            guard let self,
                  let index = downloads.firstIndex(where: { $0.id == id }),
                  downloads[index].status == .paused || downloads[index].status == .failed else {
                return
            }

            downloads[index].status = .queued
            downloads[index].error = nil
            // HLS downloads resume from the last checkpointed segment when one exists;
            // otherwise they restart from scratch.
            if downloads[index].isHLS && downloads[index].hlsResumeSegmentIndex == nil {
                downloads[index].progress = 0
                downloads[index].downloadedBytes = 0
                downloads[index].totalBytes = 0
            }
            saveDownloads()
            processQueue()
            Logger.shared.log("Resumed download: \(id)", type: "Download")
        }
    }

    func cancelDownload(id: String) {
        performOnMain { [weak self] in
            guard let self else { return }
            if let task = activeTasks[id] {
                task.cancel()
                activeTasks.removeValue(forKey: id)
            }
            if let downloader = activeHLSDownloaders[id] {
                downloader.cancel()
                activeHLSDownloaders.removeValue(forKey: id)
            }
            resumeDataStore.removeValue(forKey: id)
            lastHLSCheckpointSave.removeValue(forKey: id)
            removeDownload(id: id, deleteFile: true)
            processQueue()

            Logger.shared.log("Cancelled download: \(id)", type: "Download")
        }
    }
    
    func removeDownload(id: String, deleteFile: Bool) {
        let removal = {
            if let item = self.downloads.first(where: { $0.id == id }) {
                if deleteFile {
                    self.deleteDownloadFiles(for: item, includePartial: true, removingIDs: Set([id]))
                }
                self.downloads.removeAll { $0.id == id }
                self.saveDownloads()
            }
        }
        if Thread.isMainThread {
            removal()
        } else {
            DispatchQueue.main.sync(execute: removal)
        }
    }
    
    func deleteAllForShow(tmdbId: Int) {
        let removal = {
            let matchingIds = Set(self.downloads.filter {
                $0.tmdbId == tmdbId && $0.status == .completed
            }.map { $0.id })
            guard !matchingIds.isEmpty else { return }
            for item in self.downloads where matchingIds.contains(item.id) {
                self.deleteDownloadFiles(for: item, includePartial: false, removingIDs: matchingIds)
            }
            self.downloads.removeAll { matchingIds.contains($0.id) }
            self.saveDownloads()
        }
        if Thread.isMainThread {
            removal()
        } else {
            DispatchQueue.main.sync(execute: removal)
        }
    }

    func deleteAllCompleted() {
        let removal = {
            let completedIds = Set(self.downloads.filter { $0.status == .completed }.map { $0.id })
            guard !completedIds.isEmpty else { return }
            for item in self.downloads where completedIds.contains(item.id) {
                self.deleteDownloadFiles(for: item, includePartial: false, removingIDs: completedIds)
            }
            self.downloads.removeAll { completedIds.contains($0.id) }
            self.saveDownloads()
        }
        if Thread.isMainThread {
            removal()
        } else {
            DispatchQueue.main.sync(execute: removal)
        }
    }
    
    func deleteAll() {
        // Cancel all active tasks
        for (_, task) in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()
        for (_, downloader) in activeHLSDownloaders {
            downloader.cancel()
        }
        activeHLSDownloaders.removeAll()
        resumeDataStore.removeAll()
        
        // Wipe the entire downloads directory to guarantee no orphans remain
        let dir = downloadsDirectory
        if let contents = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for fileURL in contents {
                // Preserve the metadata JSON itself; it gets overwritten below
                if fileURL.lastPathComponent == ".downloads_metadata.json" { continue }
                try? fileManager.removeItem(at: fileURL)
            }
        }
        
        DispatchQueue.main.async {
            self.downloads.removeAll()
            self.saveDownloads()
        }
    }
    
    func pauseAll() {
        let active = downloads.filter { $0.status == .downloading || $0.status == .queued }
        for item in active {
            if item.status == .downloading {
                pauseDownload(id: item.id)
            } else {
                if let index = downloads.firstIndex(where: { $0.id == item.id }),
                   downloads[index].status == .queued {
                    downloads[index].status = .paused
                }
            }
        }
        saveDownloads()
    }
    
    func resumeAll() {
        let paused = downloads.filter { $0.status == .paused }
        for item in paused {
            resumeDownload(id: item.id)
        }
    }
    
    func retryAllFailed() {
        let failed = downloads.filter { $0.status == .failed }
        for item in failed {
            resumeDownload(id: item.id)
        }
    }
    
    func cancelAllActive() {
        let active = downloads.filter { $0.status == .downloading || $0.status == .queued || $0.status == .paused }
        for item in active {
            cancelDownload(id: item.id)
        }
    }
    
    func localFileURL(for item: DownloadItem) -> URL? {
        guard let fileName = item.localFileName else { return nil }
        return existingDownloadFileURL(relativePath: fileName)
    }
    
    func localSubtitleURL(for item: DownloadItem) -> URL? {
        guard let fileName = item.subtitleFileName else { return nil }
        return existingDownloadFileURL(relativePath: fileName)
    }
    
    func isDownloaded(tmdbId: Int, isMovie: Bool, seasonNumber: Int? = nil, episodeNumber: Int? = nil) -> Bool {
        let id: String
        if isMovie {
            id = "dl_movie_\(tmdbId)"
        } else {
            id = "dl_ep_\(tmdbId)_s\(seasonNumber ?? 0)_e\(episodeNumber ?? 0)"
        }
        return downloads.first(where: {
            $0.id == id && $0.status == .completed && localFileURL(for: $0) != nil
        }) != nil
    }

    func isDownloading(tmdbId: Int, isMovie: Bool, seasonNumber: Int? = nil, episodeNumber: Int? = nil) -> Bool {
        let id: String
        if isMovie {
            id = "dl_movie_\(tmdbId)"
        } else {
            id = "dl_ep_\(tmdbId)_s\(seasonNumber ?? 0)_e\(episodeNumber ?? 0)"
        }
        return downloads.first(where: { $0.id == id && ($0.status == .downloading || $0.status == .queued) }) != nil
    }

    func downloadItem(tmdbId: Int, isMovie: Bool, seasonNumber: Int? = nil, episodeNumber: Int? = nil) -> DownloadItem? {
        let id: String
        if isMovie {
            id = "dl_movie_\(tmdbId)"
        } else {
            id = "dl_ep_\(tmdbId)_s\(seasonNumber ?? 0)_e\(episodeNumber ?? 0)"
        }
        return downloads.first(where: { $0.id == id })
    }

    func completedDownloadItem(tmdbId: Int, isMovie: Bool, seasonNumber: Int? = nil, episodeNumber: Int? = nil) -> DownloadItem? {
        guard let item = downloadItem(
            tmdbId: tmdbId,
            isMovie: isMovie,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber
        ),
              item.status == .completed,
              localFileURL(for: item) != nil else {
            return nil
        }
        return item
    }

#if os(iOS)
    /// Resolves an episode download across both Eclipse's local anime numbering and the
    /// original TMDB coordinates used by Home/Trakt rows.
    func completedEpisodeDownloadItem(
        tmdbId: Int,
        seasonNumber: Int,
        episodeNumber: Int,
        playbackContext: EpisodePlaybackContext?
    ) -> DownloadItem? {
        if let exact = completedDownloadItem(
            tmdbId: tmdbId,
            isMovie: false,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber
        ) {
            return exact
        }

        let requestedTMDBSeason = playbackContext?.resolvedTMDBSeasonNumber ?? seasonNumber
        let requestedTMDBEpisode = playbackContext?.resolvedTMDBEpisodeNumber ?? episodeNumber

        return completedDownloads.first { candidate in
            guard !candidate.isMovie,
                  candidate.tmdbId == tmdbId,
                  localFileURL(for: candidate) != nil else {
                return false
            }

            if let candidateContext = candidate.episodePlaybackContext,
               candidateContext.resolvedTMDBSeasonNumber == requestedTMDBSeason,
               candidateContext.resolvedTMDBEpisodeNumber == requestedTMDBEpisode {
                return true
            }

            guard let playbackContext,
                  let candidateContext = candidate.episodePlaybackContext else {
                return false
            }

            let sameAniListEntry = playbackContext.anilistMediaId != nil &&
                playbackContext.anilistMediaId == candidateContext.anilistMediaId
            let sameKitsuEntry = playbackContext.kitsuMediaId != nil &&
                playbackContext.kitsuMediaId == candidateContext.kitsuMediaId
            return (sameAniListEntry || sameKitsuEntry) &&
                candidateContext.localEpisodeNumber == playbackContext.localEpisodeNumber
        }
    }
#endif

    /// Total storage used by downloads
    func calculateStorageUsed() -> Int64 {
        var total: Int64 = 0
        for item in downloads where item.status == .completed {
            if let url = localFileURL(for: item) {
                if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? Int64 {
                    total += size
                }
            }
        }
        return total
    }

    private func downloadFileCandidates(relativePath: String) -> [URL] {
        guard let cleanedPath = normalizedDownloadRelativePath(relativePath) else { return [] }

        return uniqueURLs([
            downloadsDirectory.appendingPathComponent(cleanedPath),
            legacyDownloadsDirectory.appendingPathComponent(cleanedPath)
        ])
    }

    private func existingDownloadFileURL(relativePath: String) -> URL? {
        downloadFileCandidates(relativePath: relativePath).first { isRegularFile(at: $0) }
    }

    private func isRegularFile(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return !isDirectory.boolValue
    }

    private func ensureParentDirectoryExists(for url: URL) {
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func deleteFileIfExists(
        relativePath: String,
        removingIDs: Set<String>,
        removeEmptyParents: Bool = true
    ) {
        guard !isRelativePathReferenced(relativePath, excludingIDs: removingIDs) else {
            Logger.shared.log(
                "Kept shared download path while removing \(removingIDs.count) item(s): \(relativePath)",
                type: "Download"
            )
            return
        }

        for url in downloadFileCandidates(relativePath: relativePath) where isRegularFile(at: url) {
            try? fileManager.removeItem(at: url)
            if removeEmptyParents {
                removeEmptyDownloadDirectories(startingAt: url.deletingLastPathComponent())
            }
        }
    }

    private func deleteDownloadFiles(
        for item: DownloadItem,
        includePartial: Bool,
        removingIDs: Set<String>
    ) {
        if let fileName = item.localFileName {
            deleteFileIfExists(relativePath: fileName, removingIDs: removingIDs)
        }
        if let subFile = item.subtitleFileName {
            deleteFileIfExists(relativePath: subFile, removingIDs: removingIDs)
        }
        if includePartial {
            for partialURL in hlsPartialFileCandidates(for: item) where isRegularFile(at: partialURL) {
                guard !isPartialPathReferenced(partialURL, excludingIDs: removingIDs) else { continue }
                try? fileManager.removeItem(at: partialURL)
                removeEmptyDownloadDirectories(startingAt: partialURL.deletingLastPathComponent())
            }
        }
    }

    private func removeEmptyDownloadDirectories(startingAt startDirectory: URL) {
        let rootPath = downloadsDirectory.standardizedFileURL.path
        var directory = startDirectory.standardizedFileURL

        while directory.path.hasPrefix(rootPath + "/") {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: directory.path),
                  contents.isEmpty else {
                return
            }
            try? fileManager.removeItem(at: directory)
            directory = directory.deletingLastPathComponent()
        }
    }

    private func migrateLegacyDownloadsDirectoryIfNeeded() {
        let legacyDir = legacyDownloadsDirectory
        let currentDir = downloadsDirectory
        guard legacyDir.standardizedFileURL.path != currentDir.standardizedFileURL.path,
              fileManager.fileExists(atPath: legacyDir.path),
              let contents = try? fileManager.contentsOfDirectory(at: legacyDir, includingPropertiesForKeys: nil) else {
            return
        }

        for sourceURL in contents {
            let targetURL = currentDir.appendingPathComponent(sourceURL.lastPathComponent)
            if fileManager.fileExists(atPath: targetURL.path) { continue }

            do {
                try fileManager.moveItem(at: sourceURL, to: targetURL)
            } catch {
                do {
                    try fileManager.copyItem(at: sourceURL, to: targetURL)
                } catch {
                    Logger.shared.log("Failed migrating legacy download \(sourceURL.lastPathComponent): \(error.localizedDescription)", type: "Download")
                }
            }
        }

        if let remaining = try? fileManager.contentsOfDirectory(atPath: legacyDir.path), remaining.isEmpty {
            try? fileManager.removeItem(at: legacyDir)
        }
    }

    /// Backfills stable destinations without changing paths already tracked by older
    /// metadata. Existing local/subtitle paths always win; queued legacy items are then
    /// assigned in metadata order so the first claimant keeps the friendly name.
    private func ensureDownloadPathReservations() {
        guard !downloads.isEmpty else { return }

        let priorVideoReservations = downloads.map(\.reservedVideoFileName)
        let priorSubtitleReservations = downloads.map(\.reservedSubtitleFileName)
        var changed = false

        for index in downloads.indices {
            let trackedVideo = downloads[index].localFileName.flatMap(normalizedDownloadRelativePath)
            let trackedSubtitle = downloads[index].subtitleFileName.flatMap(normalizedDownloadRelativePath)
            if downloads[index].reservedVideoFileName != trackedVideo {
                downloads[index].reservedVideoFileName = trackedVideo
                changed = true
            }
            if downloads[index].reservedSubtitleFileName != trackedSubtitle {
                downloads[index].reservedSubtitleFileName = trackedSubtitle
                changed = true
            }
        }

        for index in downloads.indices {
            var item = downloads[index]
            if item.localFileName == nil {
                let prior = priorVideoReservations[index].flatMap(normalizedDownloadRelativePath)
                if let prior, isVideoReservationAvailable(prior, for: item) {
                    item.reservedVideoFileName = prior
                } else {
                    item = itemByReservingVideoDestination(item)
                }
            }
            if item.subtitleFileName == nil,
               let prior = priorSubtitleReservations[index].flatMap(normalizedDownloadRelativePath),
               isExactRelativePathAvailable(prior, for: item.id) {
                item.reservedSubtitleFileName = prior
            }

            if downloads[index].reservedVideoFileName != item.reservedVideoFileName ||
                downloads[index].reservedSubtitleFileName != item.reservedSubtitleFileName {
                downloads[index] = item
                changed = true
            }
        }

        if changed {
            saveDownloads()
        }
    }

    private func migrateTrackedDownloadsToPublicLayout() {
        guard !downloads.isEmpty else { return }
        var changed = false
        var claimedSourcePaths = Set<String>()

        for index in downloads.indices {
            var item = downloads[index]
            guard item.status == .completed else { continue }

            if let trackedPath = item.localFileName,
               let fileURL = migrationSourceURL(
                    relativePath: trackedPath,
                    claimedSourcePaths: &claimedSourcePaths
               ),
               let migratedPath = migrateVideoFileToPublicLayout(fileURL, for: item) {
                downloads[index].localFileName = migratedPath
                downloads[index].reservedVideoFileName = migratedPath
                if let attrs = try? fileManager.attributesOfItem(atPath: downloadFileURL(relativePath: migratedPath).path),
                   let size = attrs[.size] as? Int64 {
                    downloads[index].totalBytes = size
                    downloads[index].downloadedBytes = size
                }
                changed = true
            }

            item = downloads[index]
            if let trackedSubtitlePath = item.subtitleFileName,
               let subtitleURL = migrationSourceURL(
                    relativePath: trackedSubtitlePath,
                    claimedSourcePaths: &claimedSourcePaths
               ),
               let migratedSubtitlePath = migrateSubtitleFileToPublicLayout(subtitleURL, for: item) {
                downloads[index].subtitleFileName = migratedSubtitlePath
                downloads[index].reservedSubtitleFileName = migratedSubtitlePath
                changed = true
            }
        }

        if changed {
            saveDownloads()
        }
    }

    private func migrationSourceURL(
        relativePath: String,
        claimedSourcePaths: inout Set<String>
    ) -> URL? {
        let candidates = downloadFileCandidates(relativePath: relativePath).filter(isRegularFile)
        guard let source = candidates.first(where: {
            !claimedSourcePaths.contains(canonicalAbsolutePath($0))
        }) ?? candidates.first else {
            return nil
        }
        claimedSourcePaths.insert(canonicalAbsolutePath(source))
        return source
    }

    private func migrateVideoFileToPublicLayout(_ fileURL: URL, for item: DownloadItem) -> String? {
        if isInsidePublicDownloadsDirectory(fileURL), let tracked = item.localFileName {
            return normalizedDownloadRelativePath(tracked) ?? relativePathForDownloadFile(fileURL)
        }

        let ext = sanitizedFileExtension(fileURL.pathExtension, fallback: item.isHLS ? "ts" : "mp4")
        let trackedPath = item.localFileName.flatMap(normalizedDownloadRelativePath)
        let targetRelativePath: String
        if let trackedPath,
           safeToCreateVideoDestination(trackedPath, for: item, sourceURL: fileURL) {
            targetRelativePath = trackedPath
        } else {
            targetRelativePath = allocatedVideoRelativePath(
                for: item,
                fileExtension: ext,
                forceIdentitySuffix: true,
                avoidExistingFiles: true
            )
        }
        return moveFileIntoDownloadsIfNeeded(fileURL, targetRelativePath: targetRelativePath)
    }

    private func migrateSubtitleFileToPublicLayout(_ fileURL: URL, for item: DownloadItem) -> String? {
        if isInsidePublicDownloadsDirectory(fileURL), let tracked = item.subtitleFileName {
            return normalizedDownloadRelativePath(tracked) ?? relativePathForDownloadFile(fileURL)
        }

        let ext = sanitizedFileExtension(fileURL.pathExtension, fallback: "srt")
        let trackedPath = item.subtitleFileName.flatMap(normalizedDownloadRelativePath)
        let targetRelativePath: String
        if let trackedPath,
           safeToCreateDestination(trackedPath, for: item.id, sourceURL: fileURL) {
            targetRelativePath = trackedPath
        } else {
            targetRelativePath = allocatedSubtitleRelativePath(
                for: item,
                fileExtension: ext,
                avoidExistingFiles: true
            )
        }
        return moveFileIntoDownloadsIfNeeded(fileURL, targetRelativePath: targetRelativePath)
    }

    private func moveFileIntoDownloadsIfNeeded(_ sourceURL: URL, targetRelativePath: String) -> String? {
        let targetURL = downloadFileURL(relativePath: targetRelativePath)
        if sourceURL.standardizedFileURL.path == targetURL.standardizedFileURL.path {
            return targetRelativePath
        }

        if fileManager.fileExists(atPath: targetURL.path) {
            // A destination appearing between reservation and migration belongs to
            // somebody else. Keep the source intact rather than adopting/replacing it.
            return relativePathForDownloadFile(sourceURL)
        }

        ensureParentDirectoryExists(for: targetURL)
        do {
            try fileManager.moveItem(at: sourceURL, to: targetURL)
            removeEmptyDownloadDirectories(startingAt: sourceURL.deletingLastPathComponent())
            return targetRelativePath
        } catch {
            do {
                try fileManager.copyItem(at: sourceURL, to: targetURL)
                return targetRelativePath
            } catch {
                Logger.shared.log("Failed moving download into public layout: \(error.localizedDescription)", type: "Download")
                return relativePathForDownloadFile(sourceURL)
            }
        }
    }

    private func adoptExistingDownloadedFileIfPresent(for item: DownloadItem) -> Bool {
        guard let videoURL = findExistingVideoFile(for: item) else { return false }

        var adoptedItem = item
        let adoptedVideoPath = relativePathForDownloadFile(videoURL)
        guard isExactRelativePathAvailable(adoptedVideoPath, for: item.id) else { return false }
        adoptedItem.status = .completed
        adoptedItem.progress = 1.0
        adoptedItem.localFileName = adoptedVideoPath
        adoptedItem.reservedVideoFileName = adoptedVideoPath
        adoptedItem.error = nil

        if let attrs = try? fileManager.attributesOfItem(atPath: videoURL.path) {
            if let size = attrs[.size] as? Int64 {
                adoptedItem.totalBytes = size
                adoptedItem.downloadedBytes = size
            }
            adoptedItem.dateCompleted = (attrs[.modificationDate] as? Date) ?? Date()
        } else {
            adoptedItem.dateCompleted = Date()
        }

        if let subtitleURL = findExistingSubtitleFile(for: adoptedItem, videoURL: videoURL) {
            let subtitlePath = relativePathForDownloadFile(subtitleURL)
            if isExactRelativePathAvailable(subtitlePath, for: item.id) {
                adoptedItem.subtitleFileName = subtitlePath
                adoptedItem.reservedSubtitleFileName = subtitlePath
            }
        }

        let update = {
            if let index = self.downloads.firstIndex(where: { $0.id == item.id }) {
                self.downloads[index] = adoptedItem
            } else {
                self.downloads.append(adoptedItem)
            }
            self.saveDownloads()
        }

        if Thread.isMainThread {
            update()
        } else {
            // Claim before returning so a concurrent enqueue cannot adopt the same
            // previously-unowned file in the gap before metadata is updated.
            DispatchQueue.main.sync(execute: update)
        }

        return true
    }

    private func findExistingVideoFile(for item: DownloadItem) -> URL? {
        // An item's own tracked paths are authoritative, including paths that are still
        // in the legacy Application Support directory. Never let a friendly-name scan
        // steal another item's file before checking these.
        if let tracked = downloads.first(where: { $0.id == item.id }) {
            for path in uniqueStrings([tracked.localFileName, tracked.reservedVideoFileName].compactMap { $0 }) {
                if let url = existingDownloadFileURL(relativePath: path) {
                    return url
                }
            }
        }

        let extensions = candidateVideoExtensions(for: item)
        let reservedItem = itemByReservingVideoDestination(item)
        let exactPaths = candidateVideoRelativePaths(for: reservedItem, extensions: extensions)

        for path in exactPaths {
            if isExactRelativePathAvailable(path, for: item.id),
               let url = existingDownloadFileURL(relativePath: path) {
                return url
            }
        }

        if reservedItem.isMovie {
            let stem = videoRelativePath(for: reservedItem, fileExtension: "mp4")
                .components(separatedBy: ".")
                .dropLast()
                .joined(separator: ".")
            return findMatchingFile(
                in: downloadsDirectory,
                stemMatches: [stem],
                extensions: extensions,
                claimantID: item.id
            )
        }

        let reservedPath = videoRelativePath(for: reservedItem, fileExtension: "mp4")
        let showFolder = reservedPath.split(separator: "/").first.map(String.init) ?? showFolderName(for: item)
        let showDirectory = downloadsDirectory.appendingPathComponent(showFolder, isDirectory: true)
        let episodeCode = episodeCode(for: item)
        return findMatchingFile(
            in: showDirectory,
            stemMatches: [episodeCode],
            stemPrefixes: ["\(episodeCode) - "],
            extensions: extensions,
            claimantID: item.id
        )
    }

    private func findExistingSubtitleFile(for item: DownloadItem, videoURL: URL) -> URL? {
        let subtitleExtensions = Array(Self.knownSubtitleExtensions).sorted()
        if let tracked = downloads.first(where: { $0.id == item.id }) {
            for path in uniqueStrings([tracked.subtitleFileName, tracked.reservedSubtitleFileName].compactMap { $0 }) {
                if let url = existingDownloadFileURL(relativePath: path) {
                    return url
                }
            }
        }

        let exactPaths = subtitleExtensions.map { subtitleRelativePath(for: item, fileExtension: $0) }
        for path in exactPaths {
            if isExactRelativePathAvailable(path, for: item.id),
               let url = existingDownloadFileURL(relativePath: path) {
                return url
            }
        }

        let videoStem = videoURL.deletingPathExtension().lastPathComponent
        return findMatchingFile(
            in: videoURL.deletingLastPathComponent(),
            stemPrefixes: ["\(videoStem).sub", "\(videoStem) - subtitles", "\(videoStem) subtitles"],
            extensions: subtitleExtensions,
            claimantID: item.id
        )
    }

    private func candidateVideoRelativePaths(for item: DownloadItem, extensions: [String]) -> [String] {
        var paths: [String] = []
        for ext in extensions {
            paths.append(videoRelativePath(for: item, fileExtension: ext, includeEpisodeName: true))
            if !item.isMovie {
                paths.append(videoRelativePath(for: item, fileExtension: ext, includeEpisodeName: false))
            }
            paths.append("\(item.id).\(ext)")
        }
        return uniqueStrings(paths)
    }

    private func candidateVideoExtensions(for item: DownloadItem) -> [String] {
        var extensions: [String] = []
        if let url = URL(string: item.streamURL) {
            let urlExt = sanitizedFileExtension(url.pathExtension, fallback: "")
            if Self.knownVideoExtensions.contains(urlExt) {
                extensions.append(urlExt)
            }
        }
        if item.isHLS {
            extensions.append("ts")
        }
        extensions.append(contentsOf: Self.knownVideoExtensions.sorted())
        return uniqueStrings(extensions)
    }

    private func findMatchingFile(
        in directory: URL,
        stemMatches: [String] = [],
        stemPrefixes: [String] = [],
        extensions: [String],
        claimantID: String
    ) -> URL? {
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return nil
        }

        let extensionSet = Set(extensions.map { $0.lowercased() })
        let exactStems = Set(stemMatches.map { $0.lowercased() })
        let lowercasedPrefixes = stemPrefixes.map { $0.lowercased() }

        return contents.sorted { canonicalAbsolutePath($0) < canonicalAbsolutePath($1) }.first { url in
            guard isRegularFile(at: url),
                  extensionSet.contains(url.pathExtension.lowercased()) else {
                return false
            }

            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            let relativePath = relativePathForDownloadFile(url)
            return isExactRelativePathAvailable(relativePath, for: claimantID) &&
                (exactStems.contains(stem) || lowercasedPrefixes.contains { stem.hasPrefix($0) })
        }
    }

    private func videoRelativePath(for item: DownloadItem, fileExtension: String, includeEpisodeName: Bool = true) -> String {
        let ext = sanitizedFileExtension(fileExtension, fallback: item.isHLS ? "ts" : "mp4")
        if let reservedPath = item.reservedVideoFileName.flatMap(normalizedDownloadRelativePath) {
            let components = reservedPath.split(separator: "/").map(String.init)
            if item.isMovie, let fileName = components.last {
                let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
                return "\(stem).\(ext)"
            }
            if !item.isMovie, let folder = components.first {
                let fileStem: String
                if includeEpisodeName, let fileName = components.last {
                    fileStem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
                } else {
                    fileStem = episodeCode(for: item)
                }
                return "\(folder)/\(fileStem).\(ext)"
            }
        }

        return unreservedVideoRelativePath(for: item, fileExtension: ext, includeEpisodeName: includeEpisodeName)
    }

    private func unreservedVideoRelativePath(
        for item: DownloadItem,
        fileExtension: String,
        includeEpisodeName: Bool = true,
        identitySuffix: String? = nil
    ) -> String {
        let ext = sanitizedFileExtension(fileExtension, fallback: item.isHLS ? "ts" : "mp4")
        if item.isMovie {
            return "\(fileComponent(movieFileStem(for: item), appending: identitySuffix)).\(ext)"
        }

        let folder = fileComponent(showFolderName(for: item), appending: identitySuffix)
        return "\(folder)/\(episodeFileStem(for: item, includeEpisodeName: includeEpisodeName)).\(ext)"
    }

    private func subtitleRelativePath(for item: DownloadItem, fileExtension: String) -> String {
        let ext = sanitizedFileExtension(fileExtension, fallback: "srt")
        if let reservedPath = item.reservedSubtitleFileName.flatMap(normalizedDownloadRelativePath) {
            return "\((reservedPath as NSString).deletingPathExtension).\(ext)"
        }

        let videoPath = videoRelativePath(for: item, fileExtension: "mp4")
        return "\((videoPath as NSString).deletingPathExtension).sub.\(ext)"
    }

    private func showFolderName(for item: DownloadItem) -> String {
        sanitizeFileComponent(item.playerTitleBase, fallback: "Show \(item.tmdbId)")
    }

    private func movieFileStem(for item: DownloadItem) -> String {
        sanitizeFileComponent(item.playerTitleBase, fallback: "Movie \(item.tmdbId)")
    }

    private func episodeFileStem(for item: DownloadItem, includeEpisodeName: Bool = true) -> String {
        let code = episodeCode(for: item)
        guard includeEpisodeName,
              let episodeName = item.episodeName,
              !episodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return code
        }

        return sanitizeFileComponent("\(code) - \(episodeName)", fallback: code)
    }

    private func episodeCode(for item: DownloadItem) -> String {
        String(format: "S%02dE%02d", max(item.seasonNumber ?? 0, 0), max(item.episodeNumber ?? 0, 0))
    }

    private func sanitizeFileComponent(_ value: String, fallback: String) -> String {
        var sanitized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:\n\r\t").union(.controlCharacters)
        sanitized = sanitized.components(separatedBy: invalidCharacters).joined(separator: " ")
        sanitized = sanitized.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "."))

        if sanitized.isEmpty {
            sanitized = fallback
        }
        if sanitized.count > 80 {
            sanitized = String(sanitized.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return sanitized
    }

    private func fileComponent(_ base: String, appending suffix: String?) -> String {
        let cleanBase = sanitizeFileComponent(base, fallback: "download")
        return DownloadPathIdentityPolicy.fileComponent(cleanBase, appending: suffix)
    }

    private func itemByReservingVideoDestination(_ item: DownloadItem) -> DownloadItem {
        var reservedItem = item
        if let reservation = item.reservedVideoFileName.flatMap(normalizedDownloadRelativePath),
           isVideoReservationAvailable(reservation, for: item) {
            reservedItem.reservedVideoFileName = reservation
            return reservedItem
        }

        reservedItem.reservedVideoFileName = allocatedVideoRelativePath(
            for: item,
            fileExtension: preferredReservationExtension(for: item)
        )
        return reservedItem
    }

    private func itemBySecuringFinalVideoDestination(
        _ item: DownloadItem,
        fileExtension: String
    ) -> DownloadItem {
        var securedItem = itemByReservingVideoDestination(item)
        let candidate = videoRelativePath(for: securedItem, fileExtension: fileExtension)
        let destinationExists = existingDownloadFileURL(relativePath: candidate) != nil
        let currentLocalPath = item.localFileName.map(canonicalRelativePath)
        let currentOwnsExistingFile = currentLocalPath == canonicalRelativePath(candidate)

        if isVideoReservationAvailable(candidate, for: item) &&
            (!destinationExists || currentOwnsExistingFile) {
            securedItem.reservedVideoFileName = candidate
            return securedItem
        }

        securedItem.reservedVideoFileName = allocatedVideoRelativePath(
            for: item,
            fileExtension: fileExtension,
            forceIdentitySuffix: true,
            avoidExistingFiles: true,
            blockedCanonicalPaths: [canonicalRelativePath(candidate)]
        )
        return securedItem
    }

    private func reserveFinalVideoFileName(downloadID: String, fileExtension: String) -> String {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                reserveFinalVideoFileName(downloadID: downloadID, fileExtension: fileExtension)
            }
        }
        guard let index = downloads.firstIndex(where: { $0.id == downloadID }) else {
            return "\(downloadID).\(sanitizedFileExtension(fileExtension, fallback: "mp4"))"
        }
        let securedItem = itemBySecuringFinalVideoDestination(downloads[index], fileExtension: fileExtension)
        let fileName = videoRelativePath(for: securedItem, fileExtension: fileExtension)
        downloads[index].reservedVideoFileName = fileName
        saveDownloads()
        return fileName
    }

    private func reserveFinalSubtitleFileName(downloadID: String, fileExtension: String) -> String {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                reserveFinalSubtitleFileName(downloadID: downloadID, fileExtension: fileExtension)
            }
        }
        guard let index = downloads.firstIndex(where: { $0.id == downloadID }) else {
            return "\(downloadID)_sub.\(sanitizedFileExtension(fileExtension, fallback: "srt"))"
        }
        let item = downloads[index]
        let fileName = allocatedSubtitleRelativePath(
            for: item,
            fileExtension: fileExtension,
            avoidExistingFiles: item.subtitleFileName == nil
        )
        downloads[index].reservedSubtitleFileName = fileName
        saveDownloads()
        return fileName
    }

    private func downloadOwnsTrackedPath(
        downloadID: String,
        relativePath: String,
        subtitle: Bool
    ) -> Bool {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                downloadOwnsTrackedPath(
                    downloadID: downloadID,
                    relativePath: relativePath,
                    subtitle: subtitle
                )
            }
        }
        guard let item = downloads.first(where: { $0.id == downloadID }) else { return false }
        let trackedPath = subtitle ? item.subtitleFileName : item.localFileName
        return trackedPath.map(canonicalRelativePath) == canonicalRelativePath(relativePath)
    }

    private func preferredReservationExtension(for item: DownloadItem) -> String {
        if item.isHLS { return "ts" }
        if let url = URL(string: item.streamURL) {
            let ext = sanitizedFileExtension(url.pathExtension, fallback: "")
            if Self.knownVideoExtensions.contains(ext) {
                return ext
            }
        }
        return "mp4"
    }

    private func allocatedVideoRelativePath(
        for item: DownloadItem,
        fileExtension: String,
        forceIdentitySuffix: Bool = false,
        avoidExistingFiles: Bool = false,
        blockedCanonicalPaths: Set<String> = []
    ) -> String {
        let ext = sanitizedFileExtension(fileExtension, fallback: item.isHLS ? "ts" : "mp4")
        return DownloadPathIdentityPolicy.allocateVideoRelativePath(
            request: pathIdentityRequest(for: item),
            owners: pathIdentityOwners,
            fileExtension: ext,
            forceIdentitySuffix: forceIdentitySuffix
        ) { candidate in
            blockedCanonicalPaths.contains(canonicalRelativePath(candidate)) ||
                (avoidExistingFiles && existingDownloadFileURL(relativePath: candidate) != nil)
        }
    }

    private func pathIdentityRequest(for item: DownloadItem) -> DownloadPathIdentityRequest {
        DownloadPathIdentityRequest(
            itemID: item.id,
            mediaIdentity: mediaIdentity(for: item),
            tmdbID: item.tmdbId,
            isMovie: item.isMovie,
            baseComponent: item.isMovie ? movieFileStem(for: item) : showFolderName(for: item),
            episodeComponent: episodeFileStem(for: item)
        )
    }

    private var pathIdentityOwners: [DownloadPathIdentityOwner] {
        downloads.map { item in
            DownloadPathIdentityOwner(
                id: item.id,
                mediaIdentity: mediaIdentity(for: item),
                isMovie: item.isMovie,
                relativePaths: ownedRelativePaths(for: item)
            )
        }
    }

    private func allocatedSubtitleRelativePath(
        for item: DownloadItem,
        fileExtension: String,
        avoidExistingFiles: Bool = false
    ) -> String {
        let ext = sanitizedFileExtension(fileExtension, fallback: "srt")
        let reservedCandidate = subtitleRelativePath(for: item, fileExtension: ext)
        if isExactRelativePathAvailable(reservedCandidate, for: item.id),
           (!avoidExistingFiles || existingDownloadFileURL(relativePath: reservedCandidate) == nil) {
            return reservedCandidate
        }

        for suffix in identitySuffixCandidates(for: item) {
            let videoPath = unreservedVideoRelativePath(
                for: item,
                fileExtension: "mp4",
                identitySuffix: suffix
            )
            let candidate = "\((videoPath as NSString).deletingPathExtension).sub.\(ext)"
            guard isExactRelativePathAvailable(candidate, for: item.id) else { continue }
            if !avoidExistingFiles || existingDownloadFileURL(relativePath: candidate) == nil {
                return candidate
            }
        }

        let stable = stableIdentityToken(for: item)
        for ordinal in 2...999 {
            let suffix = "[ID \(stable)-\(ordinal)]"
            let videoPath = unreservedVideoRelativePath(
                for: item,
                fileExtension: "mp4",
                identitySuffix: suffix
            )
            let candidate = "\((videoPath as NSString).deletingPathExtension).sub.\(ext)"
            if isExactRelativePathAvailable(candidate, for: item.id),
               (!avoidExistingFiles || existingDownloadFileURL(relativePath: candidate) == nil) {
                return candidate
            }
        }
        return reservedCandidate
    }

    private func identitySuffixCandidates(for item: DownloadItem) -> [String] {
        DownloadPathIdentityPolicy.identitySuffixCandidates(request: pathIdentityRequest(for: item))
    }

    private func stableIdentityToken(for item: DownloadItem) -> String {
        DownloadPathIdentityPolicy.stableIdentityToken(mediaIdentity: mediaIdentity(for: item))
    }

    private func mediaIdentity(for item: DownloadItem) -> String {
        if item.tmdbId > 0 {
            return "\(item.isMovie ? "movie" : "show"):tmdb:\(item.tmdbId)"
        }
        if item.isMovie {
            return "movie:id:\(item.id)"
        }
        let showID = item.id.replacingOccurrences(
            of: #"(?i)_s\d+_e\d+$"#,
            with: "",
            options: .regularExpression
        )
        return "show:id:\(showID)"
    }

    private func isVideoReservationAvailable(_ relativePath: String, for item: DownloadItem) -> Bool {
        DownloadPathIdentityPolicy.videoReservationIsAvailable(
            relativePath,
            request: pathIdentityRequest(for: item),
            owners: pathIdentityOwners
        )
    }

    private func ownedRelativePaths(for item: DownloadItem) -> [String] {
        uniqueStrings([
            item.localFileName,
            item.subtitleFileName,
            item.reservedVideoFileName,
            item.reservedSubtitleFileName
        ].compactMap { $0 }.compactMap(normalizedDownloadRelativePath))
    }

    private func isExactRelativePathAvailable(_ relativePath: String, for claimantID: String) -> Bool {
        DownloadPathIdentityPolicy.exactPathIsAvailable(
            relativePath,
            claimantID: claimantID,
            owners: pathIdentityOwners
        )
    }

    private func isRelativePathReferenced(_ relativePath: String, excludingIDs: Set<String>) -> Bool {
        DownloadPathIdentityPolicy.pathIsReferenced(
            relativePath,
            excludingIDs: excludingIDs,
            owners: pathIdentityOwners
        )
    }

    private func isPartialPathReferenced(_ partialURL: URL, excludingIDs: Set<String>) -> Bool {
        let key = canonicalAbsolutePath(partialURL)
        return downloads.contains { item in
            !excludingIDs.contains(item.id) && item.isHLS &&
                hlsPartialFileCandidates(for: item).contains {
                    canonicalAbsolutePath($0) == key
                }
        }
    }

    private func safeToCreateVideoDestination(
        _ relativePath: String,
        for item: DownloadItem,
        sourceURL: URL
    ) -> Bool {
        isVideoReservationAvailable(relativePath, for: item) &&
            safeToCreateDestination(relativePath, for: item.id, sourceURL: sourceURL)
    }

    private func safeToCreateDestination(
        _ relativePath: String,
        for itemID: String,
        sourceURL: URL
    ) -> Bool {
        guard isExactRelativePathAvailable(relativePath, for: itemID) else { return false }
        let destination = downloadFileURL(relativePath: relativePath)
        return !fileManager.fileExists(atPath: destination.path) ||
            canonicalAbsolutePath(destination) == canonicalAbsolutePath(sourceURL)
    }

    private func isInsidePublicDownloadsDirectory(_ url: URL) -> Bool {
        let root = downloadsDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }

    private func canonicalRelativePath(_ relativePath: String) -> String {
        DownloadPathIdentityPolicy.canonicalRelativePath(relativePath)
    }

    private func canonicalAbsolutePath(_ url: URL) -> String {
        canonicalPathComponent(url.standardizedFileURL.path)
    }

    private func canonicalPathComponent(_ value: String) -> String {
        DownloadPathIdentityPolicy.canonicalString(value)
    }

    private func sanitizedFileExtension(_ value: String, fallback: String) -> String {
        let cleaned = value.trimmingCharacters(in: CharacterSet(charactersIn: ". /\\")).lowercased()
        return cleaned.isEmpty ? fallback : cleaned
    }

    private func normalizedDownloadRelativePath(_ relativePath: String) -> String? {
        DownloadPathIdentityPolicy.normalizedRelativePath(relativePath)
    }

    private func downloadFileURL(relativePath: String) -> URL {
        if let cleanedPath = normalizedDownloadRelativePath(relativePath) {
            return downloadsDirectory.appendingPathComponent(cleanedPath)
        }

        let fallbackName = sanitizeFileComponent(
            URL(fileURLWithPath: relativePath).lastPathComponent,
            fallback: "download"
        )
        return downloadsDirectory.appendingPathComponent(fallbackName)
    }

    private func relativePathForDownloadFile(_ fileURL: URL) -> String {
        let filePath = fileURL.standardizedFileURL.path
        for directory in [downloadsDirectory, legacyDownloadsDirectory] {
            let basePath = directory.standardizedFileURL.path
            if filePath.hasPrefix(basePath + "/") {
                return String(filePath.dropFirst(basePath.count + 1))
            }
        }
        return fileURL.lastPathComponent
    }

    private func hlsPartialFileCandidates(for item: DownloadItem) -> [URL] {
        var candidates: [URL] = []

        let expectedDestination = downloadFileURL(relativePath: videoRelativePath(for: item, fileExtension: "ts"))
        candidates.append(hlsPartialURL(forDestinationURL: expectedDestination))

        if let localFileName = item.localFileName {
            let localDestination = downloadFileURL(relativePath: localFileName)
            candidates.append(hlsPartialURL(forDestinationURL: localDestination))
        }

        candidates.append(downloadsDirectory.appendingPathComponent(".\(item.id).ts.partial"))
        candidates.append(legacyDownloadsDirectory.appendingPathComponent(".\(item.id).ts.partial"))

        return uniqueURLs(candidates)
    }

    private func hlsPartialURL(forDestinationURL destinationURL: URL) -> URL {
        destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).partial")
    }

    private func migrateLegacyHLSPartialIfNeeded(
        for item: DownloadItem,
        previousReservationItem: DownloadItem? = nil,
        destinationURL: URL
    ) {
        let targetPartialURL = hlsPartialURL(forDestinationURL: destinationURL)
        guard !isRegularFile(at: targetPartialURL) else { return }

        var sourceCandidates = hlsPartialFileCandidates(for: item)
        if let previousReservationItem {
            sourceCandidates.append(contentsOf: hlsPartialFileCandidates(for: previousReservationItem))
        }
        for partialURL in uniqueURLs(sourceCandidates)
            where canonicalAbsolutePath(partialURL) != canonicalAbsolutePath(targetPartialURL) && isRegularFile(at: partialURL) {
            ensureParentDirectoryExists(for: targetPartialURL)
            do {
                try fileManager.moveItem(at: partialURL, to: targetPartialURL)
            } catch {
                try? fileManager.copyItem(at: partialURL, to: targetPartialURL)
            }
            return
        }
    }

    private func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func uniqueURLs(_ values: [URL]) -> [URL] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func effectiveHeaders(_ headers: [String: String], for url: URL) -> [String: String] {
        CloudflareBypassManager.shared.headersByApplyingCachedBypass(headers, for: url)
    }

    private func headerValue(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func cloudflareHeaderRefreshChanged(base: [String: String], effective: [String: String]) -> Bool {
        headerValue("Cookie", in: base) != headerValue("Cookie", in: effective)
            || headerValue("User-Agent", in: base) != headerValue("User-Agent", in: effective)
    }

    private func effectiveSubtitleHeaders(for item: DownloadItem, subtitleURL: URL, streamURL: URL) -> [String: String] {
        let streamHost = streamURL.host?.lowercased()
        let subtitleHost = subtitleURL.host?.lowercased()
        let baseHeaders: [String: String]

        if let subtitleHeaders = item.subtitleHeaders {
            baseHeaders = subtitleHeaders
        } else if streamHost != nil, streamHost == subtitleHost {
            baseHeaders = item.headers
        } else {
            baseHeaders = [:]
        }

        return effectiveHeaders(baseHeaders, for: subtitleURL)
    }

    private func downloadBodyPreview(from location: URL, maxBytes: Int = 1_000_000) -> String {
        guard let handle = try? FileHandle(forReadingFrom: location) else { return "" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func challengeFailureMessage(for response: HTTPURLResponse, body: String) -> String? {
        let headers = CloudflareBypassManager.headersDictionary(from: response)
        if CloudflareBypassManager.isChallengeResponse(status: response.statusCode, body: body, headers: headers) {
            return "Cloudflare verification required. Open the source once and try again."
        }

        if !(200...299).contains(response.statusCode) {
            return "HTTP \(response.statusCode) while downloading"
        }

        return nil
    }

    private func validateAutoModeDirectDownload(url: URL, headers: [String: String]) async throws {
        let probe = try await autoModeProbe(
            url: url,
            headers: headers,
            byteLimit: autoModeDirectProbeMinimumBytes + 1,
            requestsByteRange: true
        )
        try validateAutoModeProbeResponse(probe)

        if let invalidPayload = obviousInvalidMediaPayload(in: probe) {
            throw AutoModeDownloadValidationFailure(message: invalidPayload, isRetryable: false)
        }

        if autoModePlaylistText(from: probe.data) != nil {
            throw AutoModeDownloadValidationFailure(
                message: "The source returned an HLS playlist where a direct media file was expected.",
                isRetryable: false
            )
        }

        if let advertisedLength = advertisedFullPayloadLength(from: probe.response),
           advertisedLength <= Int64(autoModeDirectProbeMinimumBytes) {
            throw AutoModeDownloadValidationFailure(
                message: "The source advertised only \(formattedValidationByteCount(advertisedLength)), which is too small to be a full media download.",
                isRetryable: false
            )
        }

        guard probe.data.count > autoModeDirectProbeMinimumBytes else {
            throw AutoModeDownloadValidationFailure(
                message: "The source returned only \(formattedValidationByteCount(Int64(probe.data.count))) before ending. Trying another source is safer.",
                isRetryable: true
            )
        }
    }

    private func validateAutoModeHLSDownload(url: URL, headers: [String: String]) async throws {
        var playlistURL = url
        var playlistText = try await fetchAutoModePlaylist(url: playlistURL, headers: headers)

        // Resolve nested master playlists the same way the downloader does: highest
        // advertised bandwidth wins. Bound the depth so malformed loops fail quickly.
        for _ in 0..<3 where playlistText.contains("#EXT-X-STREAM-INF") {
            let variants = autoModeHLSVariants(in: playlistText, baseURL: playlistURL)
            guard let selected = variants.max(by: { $0.bandwidth < $1.bandwidth }) else {
                throw AutoModeDownloadValidationFailure(
                    message: "The HLS master playlist did not contain a usable variant.",
                    isRetryable: false
                )
            }
            playlistURL = selected.url
            playlistText = try await fetchAutoModePlaylist(url: playlistURL, headers: headers)
        }

        guard !playlistText.contains("#EXT-X-STREAM-INF") else {
            throw AutoModeDownloadValidationFailure(
                message: "The HLS playlist redirected through too many nested master playlists.",
                isRetryable: false
            )
        }

        let segments = autoModeHLSSegmentURLs(in: playlistText, baseURL: playlistURL)
        guard let firstSegmentURL = segments.first else {
            throw AutoModeDownloadValidationFailure(
                message: "The HLS playlist did not contain any downloadable media segments.",
                isRetryable: false
            )
        }

        let segmentProbe = try await autoModeProbe(
            url: firstSegmentURL,
            headers: headers,
            byteLimit: autoModeHLSSegmentProbeMinimumBytes + 1,
            requestsByteRange: true
        )
        try validateAutoModeProbeResponse(segmentProbe)

        if let invalidPayload = obviousInvalidMediaPayload(in: segmentProbe) {
            throw AutoModeDownloadValidationFailure(message: invalidPayload, isRetryable: false)
        }
        if autoModePlaylistText(from: segmentProbe.data) != nil {
            throw AutoModeDownloadValidationFailure(
                message: "The HLS media segment resolved to another playlist instead of media data.",
                isRetryable: false
            )
        }

        guard segmentProbe.data.count > autoModeHLSSegmentProbeMinimumBytes else {
            throw AutoModeDownloadValidationFailure(
                message: "The first HLS media segment ended after only \(formattedValidationByteCount(Int64(segmentProbe.data.count))).",
                isRetryable: true
            )
        }
    }

    private func fetchAutoModePlaylist(url: URL, headers: [String: String]) async throws -> String {
        let probe = try await autoModeProbe(
            url: url,
            headers: headers,
            byteLimit: autoModePlaylistProbeLimit,
            requestsByteRange: false
        )
        try validateAutoModeProbeResponse(probe)

        guard !probe.reachedByteLimit else {
            throw AutoModeDownloadValidationFailure(
                message: "The HLS playlist was unexpectedly large and could not be safely verified.",
                isRetryable: false
            )
        }
        guard let playlist = autoModePlaylistText(from: probe.data) else {
            throw AutoModeDownloadValidationFailure(
                message: "The source did not return a valid HLS playlist.",
                isRetryable: false
            )
        }
        return playlist
    }

    private func autoModeProbe(
        url: URL,
        headers: [String: String],
        byteLimit: Int,
        requestsByteRange: Bool
    ) async throws -> DownloadStreamProbeResult {
        let refreshedHeaders = effectiveHeaders(headers, for: url)
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (key, value) in refreshedHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if requestsByteRange {
            request.setValue("bytes=0-\(max(byteLimit - 1, 0))", forHTTPHeaderField: "Range")
        }

        let probe = DownloadStreamProbe(byteLimit: byteLimit, redirectHeaders: refreshedHeaders)
        return try await probe.run(request)
    }

    private func validateAutoModeProbeResponse(_ probe: DownloadStreamProbeResult) throws {
        let response = probe.response
        let body = String(data: probe.data.prefix(1_000_000), encoding: .utf8) ?? ""
        let responseHeaders = CloudflareBypassManager.headersDictionary(from: response)

        if CloudflareBypassManager.isChallengeResponse(
            status: response.statusCode,
            body: body,
            headers: responseHeaders
        ) {
            throw AutoModeDownloadValidationFailure(
                message: "Cloudflare verification is required before this source can download.",
                isRetryable: false
            )
        }

        guard (200...299).contains(response.statusCode) else {
            let retryable = response.statusCode == 408
                || response.statusCode == 425
                || response.statusCode == 429
                || (500...599).contains(response.statusCode)
            throw AutoModeDownloadValidationFailure(
                message: "The download source returned HTTP \(response.statusCode).",
                isRetryable: retryable
            )
        }
    }

    private func obviousInvalidMediaPayload(in probe: DownloadStreamProbeResult) -> String? {
        let contentType = (probe.response.value(forHTTPHeaderField: "Content-Type") ?? "")
            .lowercased()
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init) ?? ""

        if contentType == "text/html"
            || contentType == "application/json"
            || contentType.hasSuffix("+json")
            || contentType == "application/xml"
            || contentType == "text/xml"
            || contentType.hasSuffix("+xml")
            || contentType.hasPrefix("image/") {
            return "The source returned \(contentType.isEmpty ? "an error page" : contentType) instead of media data."
        }

        guard let preview = String(data: probe.data.prefix(64 * 1024), encoding: .utf8) else {
            return nil
        }
        let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("<!doctype html")
            || trimmed.hasPrefix("<html")
            || trimmed.hasPrefix("<?xml")
            || trimmed.hasPrefix("{\"error\"")
            || trimmed.hasPrefix("{\"message\"") {
            return "The source returned an error document instead of media data."
        }
        return nil
    }

    private func advertisedFullPayloadLength(from response: HTTPURLResponse) -> Int64? {
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let slash = contentRange.lastIndex(of: "/") {
            let totalText = contentRange[contentRange.index(after: slash)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if totalText != "*", let total = Int64(totalText) {
                return total
            }
        }

        // A 206 Content-Length describes only the sampled range, not the full file.
        guard response.statusCode != 206, response.expectedContentLength >= 0 else { return nil }
        return response.expectedContentLength
    }

    private func autoModePlaylistText(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let normalized = text
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
        guard normalized.hasPrefix("#EXTM3U") else { return nil }
        return normalized
    }

    private func autoModeHLSVariants(in playlist: String, baseURL: URL) -> [(url: URL, bandwidth: Int)] {
        let lines = playlist.components(separatedBy: .newlines)
        var variants: [(url: URL, bandwidth: Int)] = []
        var index = 0

        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("#EXT-X-STREAM-INF:") else {
                index += 1
                continue
            }

            let attributes = line.dropFirst("#EXT-X-STREAM-INF:".count)
            let bandwidth = attributes
                .split(separator: ",")
                .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("BANDWIDTH=") })
                .flatMap { attribute -> Int? in
                    let value = attribute.split(separator: "=", maxSplits: 1).last
                    return value.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                } ?? 0

            index += 1
            while index < lines.count {
                let uri = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                if !uri.isEmpty && !uri.hasPrefix("#") {
                    if let resolved = resolveAutoModeHLSURL(uri, relativeTo: baseURL) {
                        variants.append((resolved, bandwidth))
                    }
                    break
                }
                index += 1
            }
            index += 1
        }

        return variants
    }

    private func autoModeHLSSegmentURLs(in playlist: String, baseURL: URL) -> [URL] {
        playlist.components(separatedBy: .newlines).compactMap { line in
            let uri = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !uri.isEmpty, !uri.hasPrefix("#") else { return nil }
            return resolveAutoModeHLSURL(uri, relativeTo: baseURL)
        }
    }

    private func resolveAutoModeHLSURL(_ value: String, relativeTo baseURL: URL) -> URL? {
        if let absolute = URL(string: value), absolute.scheme != nil {
            return absolute
        }
        return URL(string: value, relativeTo: baseURL)?.absoluteURL
    }

    private func formattedValidationByteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(bytes, 0))
    }

    private func autoModeValidationFailure(from error: Error) -> AutoModeDownloadValidationFailure {
        if let failure = error as? AutoModeDownloadValidationFailure {
            return failure
        }
        if let urlError = error as? URLError {
            let retryableCodes: Set<URLError.Code> = [
                .timedOut,
                .cannotFindHost,
                .cannotConnectToHost,
                .networkConnectionLost,
                .dnsLookupFailed,
                .notConnectedToInternet,
                .resourceUnavailable
            ]
            return AutoModeDownloadValidationFailure(
                message: "The download stream could not be reached: \(urlError.localizedDescription)",
                isRetryable: retryableCodes.contains(urlError.code)
            )
        }
        return AutoModeDownloadValidationFailure(
            message: "The download stream could not be verified: \(error.localizedDescription)",
            isRetryable: true
        )
    }
    
    // MARK: - Queue Processing
    
    private func processQueue() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.processQueue()
            }
            return
        }

        let currentlyDownloading = downloads.filter { $0.status == .downloading }.count
        var slotsAvailable = maxConcurrentDownloads - currentlyDownloading
        
        guard slotsAvailable > 0 else { return }
        
        let queued = downloads.filter { $0.status == .queued }

        for item in queued {
            guard slotsAvailable > 0 else { break }

            if item.isHLS {
                if activeHLSDownloaders.count >= maxConcurrentHLSDownloads {
                    setQueuedMessage(id: item.id, message: "Waiting to package HLS")
                    continue
                }

                if let delayReason = hlsStartDelayReason() {
                    setQueuedMessage(id: item.id, message: delayReason)
                    Logger.shared.log("Delaying HLS packaging for \(item.displayTitle): \(delayReason)", type: "Download")
                    continue
                }
            }

            clearQueuedMessage(id: item.id)
            startDownload(item)
            slotsAvailable -= 1
        }
    }
    
    private func startDownload(_ item: DownloadItem) {
        guard let url = URL(string: item.streamURL) else {
            markFailed(id: item.id, error: "Invalid stream URL")
            return
        }
        
        // Route HLS streams to the guarded TS packager so VLC/mpv playback stays compatible.
        if item.isHLS {
            if let delayReason = hlsStartDelayReason() {
                setQueuedMessage(id: item.id, message: delayReason)
                Logger.shared.log("HLS queued instead of starting: \(delayReason)", type: "Download")
                return
            }
            startHLSDownload(item)
            return
        }
        
        let effectiveHeaders = effectiveHeaders(item.headers, for: url)
        let refreshedCloudflareHeaders = cloudflareHeaderRefreshChanged(base: item.headers, effective: effectiveHeaders)

        var request = URLRequest(url: url)
        for (key, value) in effectiveHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        let task: URLSessionDownloadTask
        if let resumeData = resumeDataStore[item.id], !refreshedCloudflareHeaders {
            task = backgroundSession.downloadTask(withResumeData: resumeData)
            resumeDataStore.removeValue(forKey: item.id)
        } else {
            if resumeDataStore.removeValue(forKey: item.id) != nil, refreshedCloudflareHeaders {
                Logger.shared.log("Restarting download with refreshed Cloudflare headers: \(item.displayTitle)", type: "Download")
            }
            task = backgroundSession.downloadTask(with: request)
        }
        
        task.taskDescription = item.id
        activeTasks[item.id] = task
        
        if let index = downloads.firstIndex(where: { $0.id == item.id }) {
            downloads[index].status = .downloading
            if refreshedCloudflareHeaders {
                downloads[index].progress = 0
                downloads[index].downloadedBytes = 0
                downloads[index].totalBytes = 0
            }
            saveDownloads()
        }
        
        task.resume()
        
        // Also download subtitle if available
        if let subtitleURLString = item.subtitleURL, let subtitleURL = URL(string: subtitleURLString) {
            let subtitleHeaders = effectiveSubtitleHeaders(for: item, subtitleURL: subtitleURL, streamURL: url)
            downloadSubtitle(for: item.id, from: subtitleURL, headers: subtitleHeaders)
        }
        
        Logger.shared.log("Started download: \(item.displayTitle)", type: "Download")
    }
    
    private func startHLSDownload(_ item: DownloadItem) {
        guard let url = URL(string: item.streamURL) else {
            markFailed(id: item.id, error: "Invalid stream URL")
            return
        }

        if backgroundHLSPipelineEnabled {
            Logger.shared.log("Background HLS experiment enabled; using guarded single-lane TS packager", type: "Download")
        }
        
        let securedItem = itemBySecuringFinalVideoDestination(item, fileExtension: "ts")
        let fileName = videoRelativePath(for: securedItem, fileExtension: "ts")
        if let index = downloads.firstIndex(where: { $0.id == item.id }),
           downloads[index].reservedVideoFileName != securedItem.reservedVideoFileName {
            downloads[index].reservedVideoFileName = securedItem.reservedVideoFileName
            saveDownloads()
        }
        let destURL = downloadFileURL(relativePath: fileName)
        ensureParentDirectoryExists(for: destURL)
        migrateLegacyHLSPartialIfNeeded(
            for: securedItem,
            previousReservationItem: item,
            destinationURL: destURL
        )

        let resumeSegment = item.hlsResumeSegmentIndex ?? 0
        let resumeBytes = item.hlsResumeByteCount ?? 0
        let pinnedVariant = item.hlsVariantURL.flatMap { URL(string: $0) }
        let expectedTotal = item.hlsTotalSegments ?? 0
        let refreshedHeaders = effectiveHeaders(item.headers, for: url)

        let downloader = HLSDownloader(
            streamURL: url,
            headers: refreshedHeaders,
            destinationURL: destURL,
            downloadId: item.id,
            resumeFromSegment: resumeSegment,
            resumeByteCount: resumeBytes,
            pinnedVariantURL: pinnedVariant,
            expectedTotalSegments: expectedTotal
        )

        downloader.onVariantResolved = { [weak self] variantURL, totalSegments in
            guard let self = self else { return }
            if let index = self.downloads.firstIndex(where: { $0.id == item.id }) {
                self.downloads[index].hlsVariantURL = variantURL.absoluteString
                self.downloads[index].hlsTotalSegments = totalSegments
                self.saveDownloads()
            }
        }

        downloader.onCheckpoint = { [weak self] segmentsWritten, byteCount in
            guard let self = self else { return }
            guard let index = self.downloads.firstIndex(where: { $0.id == item.id }),
                  self.downloads[index].status == .downloading else { return }
            self.downloads[index].hlsResumeSegmentIndex = segmentsWritten
            self.downloads[index].hlsResumeByteCount = byteCount
            self.downloads[index].downloadedBytes = byteCount
            // In-memory state is always current for instant pause/resume; throttle the
            // disk write to a couple of seconds. On a hard kill we lose at most the last
            // throttle window, and the partial is truncated back to the saved checkpoint.
            let now = Date()
            if let last = self.lastHLSCheckpointSave[item.id], now.timeIntervalSince(last) < 2.0 {
                return
            }
            self.lastHLSCheckpointSave[item.id] = now
            self.saveDownloads()
        }

        downloader.onProgress = { [weak self] progress in
            guard let self = self else { return }
            if let index = self.downloads.firstIndex(where: { $0.id == item.id }),
               self.downloads[index].status == .downloading {
                self.downloads[index].progress = progress
            }
        }
        
        downloader.onCompletion = { [weak self] result in
            guard let self = self else { return }

            DispatchQueue.main.async {
                self.activeHLSDownloaders.removeValue(forKey: item.id)

                switch result {
                case .success(let fileURL):
                    if let index = self.downloads.firstIndex(where: { $0.id == item.id }) {
                        self.downloads[index].status = .completed
                        self.downloads[index].progress = 1.0
                        self.downloads[index].localFileName = fileName
                        self.downloads[index].dateCompleted = Date()
                        
                        if let attrs = try? self.fileManager.attributesOfItem(atPath: fileURL.path),
                           let size = attrs[.size] as? Int64 {
                            self.downloads[index].totalBytes = size
                            self.downloads[index].downloadedBytes = size
                        }

                        // Checkpoint no longer needed once the file is finalized.
                        self.downloads[index].hlsResumeSegmentIndex = nil
                        self.downloads[index].hlsResumeByteCount = nil

                        self.saveDownloads()
                    }
                    self.lastHLSCheckpointSave.removeValue(forKey: item.id)
                    self.processQueue()
                    Logger.shared.log("HLS download completed: \(item.displayTitle) -> \(fileName)", type: "Download")

                case .failure(let error):
                    if let hlsError = error as? HLSError {
                        switch hlsError {
                        case .cancelled:
                            self.handleCancelledHLSDownload(id: item.id)
                            Logger.shared.log("HLS download cancelled: \(item.displayTitle)", type: "Download")
                        case .backgroundTimeExpired:
                            self.requeueInterruptedHLSDownload(id: item.id, message: "Waiting for app to reopen")
                            Logger.shared.log("HLS background time expired for \(item.displayTitle)", type: "Download")
                        case .systemBackoff(let reason):
                            self.requeueInterruptedHLSDownload(id: item.id, message: reason)
                            Logger.shared.log("HLS packaging paused for \(item.displayTitle): \(reason)", type: "Download")
                        default:
                            self.markFailed(id: item.id, error: error.localizedDescription)
                        }
                    } else {
                        self.markFailed(id: item.id, error: error.localizedDescription)
                    }
                }
            }
        }
        
        activeHLSDownloaders[item.id] = downloader
        
        if let index = downloads.firstIndex(where: { $0.id == item.id }) {
            downloads[index].status = .downloading
            // Only zero progress on a genuine fresh start. When resuming we keep the
            // checkpointed progress/bytes so the bar doesn't snap back to zero.
            if resumeSegment == 0 {
                downloads[index].progress = 0
                downloads[index].downloadedBytes = 0
                downloads[index].totalBytes = 0
            }
            saveDownloads()
        }

        downloader.start()
        
        // Also download subtitle if available
        if let subtitleURLString = item.subtitleURL, let subtitleURL = URL(string: subtitleURLString) {
            let subtitleHeaders = effectiveSubtitleHeaders(for: item, subtitleURL: subtitleURL, streamURL: url)
            downloadSubtitle(for: item.id, from: subtitleURL, headers: subtitleHeaders)
        }
        
        Logger.shared.log("Started HLS download: \(item.displayTitle)", type: "Download")
    }

    private func hlsStartDelayReason() -> String? {
        #if canImport(UIKit)
        if !backgroundHLSPipelineEnabled && UIApplication.shared.applicationState != .active {
            return "Waiting for app to reopen"
        }

        let thermalState = ProcessInfo.processInfo.thermalState
        if thermalState == .serious || thermalState == .critical {
            return "Paused for thermal state"
        }

        let device = UIDevice.current
        if device.batteryState == .unplugged && device.batteryLevel >= 0 && device.batteryLevel < 0.15 {
            return "Paused for low battery"
        }
        #endif

        if let freeBytes = availableDownloadCapacity(), freeBytes < minimumFreeBytesForHLS {
            return "Paused for low disk space"
        }

        return nil
    }

    private func availableDownloadCapacity() -> Int64? {
        do {
            let values = try downloadsDirectory.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey
            ])

            if let importantUsage = values.volumeAvailableCapacityForImportantUsage {
                return importantUsage
            }
            if let capacity = values.volumeAvailableCapacity {
                return Int64(capacity)
            }
        } catch {
            Logger.shared.log("Could not read free disk space for HLS: \(error.localizedDescription)", type: "Download")
        }

        return nil
    }

    private func setQueuedMessage(id: String, message: String) {
        DispatchQueue.main.async {
            guard let index = self.downloads.firstIndex(where: { $0.id == id }),
                  self.downloads[index].status == .queued,
                  self.downloads[index].error != message else { return }
            self.downloads[index].error = message
            self.saveDownloads()
        }
    }

    private func clearQueuedMessage(id: String) {
        DispatchQueue.main.async {
            guard let index = self.downloads.firstIndex(where: { $0.id == id }),
                  self.downloads[index].error != nil else { return }
            self.downloads[index].error = nil
            self.saveDownloads()
        }
    }
    
    /// Known video file extensions that VLC/mpv can play
    private static let knownVideoExtensions: Set<String> = [
        "mp4", "mkv", "webm", "mov", "avi", "wmv", "flv", "ts", "m2ts",
        "mpg", "mpeg", "ogv", "3gp", "m4v", "vob", "divx", "asf", "rm",
        "rmvb", "f4v", "mts"
    ]
    
    /// Known subtitle file extensions supported by the players
    private static let knownSubtitleExtensions: Set<String> = [
        "srt", "vtt", "ass", "ssa", "sub", "idx", "sup", "smi", "mks", "dfxp", "ttml"
    ]
    
    private func downloadSubtitle(for downloadId: String, from url: URL, headers: [String: String]) {
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let subtitleTask = URLSession.shared.downloadTask(with: request) { [weak self] tempURL, response, error in
            guard let self = self, let tempURL = tempURL, error == nil else { return }

            if let httpResponse = response as? HTTPURLResponse {
                let body = self.downloadBodyPreview(from: tempURL)
                if let message = self.challengeFailureMessage(for: httpResponse, body: body) {
                    Logger.shared.log("Subtitle download skipped for \(downloadId): \(message)", type: "Download")
                    return
                }
            }
            
            // Determine subtitle extension from URL, Content-Type, or default to srt
            var ext = url.pathExtension.lowercased()
            if ext.isEmpty || !Self.knownSubtitleExtensions.contains(ext) {
                // Try Content-Type header
                if let httpResp = response as? HTTPURLResponse,
                   let contentType = httpResp.value(forHTTPHeaderField: "Content-Type")?.lowercased() {
                    if contentType.contains("vtt") || contentType.contains("webvtt") {
                        ext = "vtt"
                    } else if contentType.contains("ass") || contentType.contains("ssa") {
                        ext = "ass"
                    } else if contentType.contains("subrip") {
                        ext = "srt"
                    } else {
                        ext = "srt"
                    }
                } else {
                    ext = "srt"
                }
            }
            let fileName = self.reserveFinalSubtitleFileName(
                downloadID: downloadId,
                fileExtension: ext
            )
            let destURL = self.downloadFileURL(relativePath: fileName)
            self.ensureParentDirectoryExists(for: destURL)

            if self.isRegularFile(at: destURL) {
                let currentOwnsDestination = self.downloadOwnsTrackedPath(
                    downloadID: downloadId,
                    relativePath: fileName,
                    subtitle: true
                )
                guard currentOwnsDestination else {
                    Logger.shared.log(
                        "Subtitle destination became occupied before save for \(downloadId)",
                        type: "Download"
                    )
                    return
                }
                try? self.fileManager.removeItem(at: destURL)
            }
            do {
                try self.fileManager.moveItem(at: tempURL, to: destURL)
                DispatchQueue.main.async {
                    if let index = self.downloads.firstIndex(where: { $0.id == downloadId }) {
                        self.downloads[index].subtitleFileName = fileName
                        self.downloads[index].reservedSubtitleFileName = fileName
                        self.saveDownloads()
                    }
                }
                Logger.shared.log("Downloaded subtitle for \(downloadId)", type: "Download")
            } catch {
                Logger.shared.log("Failed to save subtitle for \(downloadId): \(error)", type: "Download")
            }
        }
        subtitleTask.resume()
    }

    private func handleCancelledHLSDownload(id: String) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else {
            processQueue()
            return
        }

        if downloads[index].status == .downloading {
            downloads[index].status = .paused
        }

        saveDownloads()
        processQueue()
    }

    private func requeueInterruptedHLSDownload(id: String, message: String) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else {
            processQueue()
            return
        }

        if downloads[index].status == .downloading || downloads[index].status == .queued {
            downloads[index].status = .queued
            downloads[index].error = message
        }

        saveDownloads()
        processQueue()
    }
    
    private func markFailed(id: String, error: String) {
        performOnMain { [weak self] in
            guard let self else { return }
            activeTasks.removeValue(forKey: id)
            if let index = downloads.firstIndex(where: { $0.id == id }) {
                downloads[index].status = .failed
                downloads[index].error = error
                saveDownloads()
                processQueue()
            }
            Logger.shared.log("Download failed: \(id) - \(error)", type: "Download")
        }
    }
    
    private func resumeInterruptedDownloads() {
        let interruptedIDs = downloads.filter { $0.status == .downloading }.map(\.id)
        performOnMain { [weak self] in
            guard let self else { return }
            for id in interruptedIDs {
                guard let index = downloads.firstIndex(where: { $0.id == id }),
                      downloads[index].status == .downloading else { continue }
                downloads[index].status = .queued
            }
            saveDownloads()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.processQueue()
        }
    }
    
    // MARK: - Orphan Cleanup
    
    /// Finds stale hidden partials off the launch-critical main thread, then
    /// rechecks current download state immediately before removing anything.
    /// The public Downloads tree can be large, so recursive enumeration must
    /// not delay the first app frame.
    private func cleanOrphanedFiles() {
        let directory = downloadsDirectory
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let candidates = self.orphanedPartialCandidates(in: directory)
            guard !candidates.isEmpty else { return }

            DispatchQueue.main.async { [weak self] in
                self?.removeOrphanedPartialCandidates(candidates)
            }
        }
    }

    private struct OrphanedPartialCandidate {
        let url: URL
        let size: Int64
    }

    private func orphanedPartialCandidates(in directory: URL) -> [OrphanedPartialCandidate] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        var candidates: [OrphanedPartialCandidate] = []
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            guard name.hasPrefix("."), name.hasSuffix(".partial") else { continue }
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile != false else { continue }
            candidates.append(
                OrphanedPartialCandidate(
                    url: fileURL,
                    size: Int64(values?.fileSize ?? 0)
                )
            )
        }
        return candidates
    }

    private func removeOrphanedPartialCandidates(_ candidates: [OrphanedPartialCandidate]) {
        let activePartialPaths = Set(
            downloads
                .filter { $0.isHLS && $0.status != .completed }
                .flatMap { hlsPartialFileCandidates(for: $0).map(canonicalAbsolutePath) }
        )
        
        var removedCount = 0
        var freedBytes: Int64 = 0
        for candidate in candidates where !activePartialPaths.contains(canonicalAbsolutePath(candidate.url)) {
            guard fileManager.fileExists(atPath: candidate.url.path) else { continue }
            do {
                try fileManager.removeItem(at: candidate.url)
            } catch {
                continue
            }
            freedBytes += candidate.size
            removeEmptyDownloadDirectories(startingAt: candidate.url.deletingLastPathComponent())
            removedCount += 1
        }
        
        if removedCount > 0 {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            Logger.shared.log("Cleaned \(removedCount) orphaned file(s), freed \(formatter.string(fromByteCount: freedBytes))", type: "Download")
        }
    }
    
    // MARK: - Persistence
    
    private func saveDownloads() {
        // Capture the current downloads array on the calling thread (main) to avoid
        // a data race when encoding on the background write queue.
        let snapshot = self.downloads
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: self.persistenceURL, options: .atomic)
            } catch {
                Logger.shared.log("Failed to save downloads: \(error)", type: "Download")
            }
        }
    }
    
    private func loadDownloads() {
        guard fileManager.fileExists(atPath: persistenceURL.path) else { return }
        do {
            let data = try Data(contentsOf: persistenceURL)
            let loaded = try JSONDecoder().decode([DownloadItem].self, from: data)
            // Set synchronously so that cleanOrphanedFiles() and resumeInterruptedDownloads()
            // see the correct data immediately after this call.
            self.downloads = loaded
        } catch {
            Logger.shared.log("Failed to load downloads: \(error)", type: "Download")
        }
    }

}

private struct AutoModeDownloadValidationFailure: Error {
    let message: String
    let isRetryable: Bool
}

private struct DownloadStreamProbeResult {
    let response: HTTPURLResponse
    let data: Data
    let reachedByteLimit: Bool
}

/// A small streaming probe that never writes to disk and stops as soon as the caller's
/// byte limit is reached. This also protects against servers that ignore Range and try to
/// send the entire movie during validation.
private final class DownloadStreamProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let byteLimit: Int
    private let redirectHeaders: [String: String]
    private let stateLock = NSLock()

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<DownloadStreamProbeResult, Error>?
    private var response: HTTPURLResponse?
    private var receivedData = Data()
    private var didFinish = false

    init(byteLimit: Int, redirectHeaders: [String: String]) {
        self.byteLimit = max(byteLimit, 1)
        self.redirectHeaders = redirectHeaders
        super.init()
    }

    func run(_ request: URLRequest) async throws -> DownloadStreamProbeResult {
        try Task.checkCancellation()

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.begin(request, continuation: continuation)
            }
        }, onCancel: {
            self.complete(.failure(CancellationError()))
        })
    }

    private func begin(
        _ request: URLRequest,
        continuation: CheckedContinuation<DownloadStreamProbeResult, Error>
    ) {
        stateLock.lock()
        if didFinish {
            stateLock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil

        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .userInitiated

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        let task = session.dataTask(with: request)
        self.session = session
        self.task = task
        self.continuation = continuation
        receivedData.reserveCapacity(byteLimit)
        stateLock.unlock()

        task.resume()
    }

    private func complete(_ result: Result<DownloadStreamProbeResult, Error>) {
        let continuation: CheckedContinuation<DownloadStreamProbeResult, Error>?
        let session: URLSession?

        stateLock.lock()
        guard !didFinish else {
            stateLock.unlock()
            return
        }
        didFinish = true
        continuation = self.continuation
        session = self.session
        self.continuation = nil
        self.task = nil
        self.session = nil
        stateLock.unlock()

        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            complete(.failure(URLError(.badServerResponse)))
            return
        }

        stateLock.lock()
        self.response = httpResponse
        stateLock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var completedResult: DownloadStreamProbeResult?

        stateLock.lock()
        guard !didFinish else {
            stateLock.unlock()
            return
        }

        let remaining = max(byteLimit - receivedData.count, 0)
        if remaining > 0 {
            receivedData.append(data.prefix(remaining))
        }
        if receivedData.count >= byteLimit, let response {
            completedResult = DownloadStreamProbeResult(
                response: response,
                data: receivedData,
                reachedByteLimit: true
            )
        }
        stateLock.unlock()

        if let completedResult {
            complete(.success(completedResult))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            complete(.failure(error))
            return
        }

        stateLock.lock()
        let response = self.response
        let data = receivedData
        stateLock.unlock()

        guard let response else {
            complete(.failure(URLError(.badServerResponse)))
            return
        }
        complete(.success(DownloadStreamProbeResult(
            response: response,
            data: data,
            reachedByteLimit: false
        )))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var redirectedRequest = request
        for (key, value) in redirectHeaders {
            let lowercasedKey = key.lowercased()
            if lowercasedKey == "cookie" || lowercasedKey == "user-agent" {
                redirectedRequest.setValue(value, forHTTPHeaderField: key)
            } else if redirectedRequest.value(forHTTPHeaderField: key) == nil {
                redirectedRequest.setValue(value, forHTTPHeaderField: key)
            }
        }
        completionHandler(redirectedRequest)
    }
}

// MARK: - URLSession Delegate

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let downloadId = downloadTask.taskDescription else { return }

        if let httpResponse = downloadTask.response as? HTTPURLResponse {
            let body = downloadBodyPreview(from: location)
            if let message = challengeFailureMessage(for: httpResponse, body: body) {
                markFailed(id: downloadId, error: message)
                return
            }
        }
        
        // Determine file extension from response MIME type or URL
        let ext: String
        let urlExt = (downloadTask.currentRequest?.url?.pathExtension ?? downloadTask.originalRequest?.url?.pathExtension ?? "").lowercased()
        if let mimeType = downloadTask.response?.mimeType?.lowercased() {
            switch mimeType {
            // Video formats
            case "video/mp4":                                       ext = "mp4"
            case "video/x-matroska":                                ext = "mkv"
            case "video/webm":                                      ext = "webm"
            case "video/quicktime":                                  ext = "mov"
            case "video/x-msvideo":                                  ext = "avi"
            case "video/x-ms-wmv":                                   ext = "wmv"
            case "video/x-flv", "video/flv":                         ext = "flv"
            case "video/mp2t", "video/m2ts", "video/vnd.dlna.mpeg-tts": ext = "ts"
            case "video/3gpp":                                       ext = "3gp"
            case "video/ogg":                                        ext = "ogv"
            case "video/mpeg":                                       ext = "mpg"
            // HLS manifests
            case "application/x-mpegurl", "application/vnd.apple.mpegurl": ext = "m3u8"
            // Generic binary - trust the URL extension if it's a known video format
            case "application/octet-stream":
                ext = Self.knownVideoExtensions.contains(urlExt) ? urlExt : (urlExt.isEmpty ? "mp4" : urlExt)
            default:
                // Unknown MIME - prefer URL extension if it's a known format
                ext = Self.knownVideoExtensions.contains(urlExt) ? urlExt : "mp4"
            }
        } else {
            ext = Self.knownVideoExtensions.contains(urlExt) ? urlExt : (urlExt.isEmpty ? "mp4" : urlExt)
        }
        
        let fileName = reserveFinalVideoFileName(downloadID: downloadId, fileExtension: ext)
        let destURL = downloadFileURL(relativePath: fileName)
        ensureParentDirectoryExists(for: destURL)

        if isRegularFile(at: destURL) {
            let currentOwnsDestination = downloadOwnsTrackedPath(
                downloadID: downloadId,
                relativePath: fileName,
                subtitle: false
            )
            guard currentOwnsDestination else {
                markFailed(id: downloadId, error: "The reserved destination became occupied before the download completed.")
                return
            }
            try? fileManager.removeItem(at: destURL)
        }
        
        do {
            try fileManager.moveItem(at: location, to: destURL)
            
            DispatchQueue.main.async {
                if let index = self.downloads.firstIndex(where: { $0.id == downloadId }) {
                    self.downloads[index].status = .completed
                    self.downloads[index].progress = 1.0
                    self.downloads[index].localFileName = fileName
                    self.downloads[index].dateCompleted = Date()
                    
                    // Get final file size
                    if let attrs = try? self.fileManager.attributesOfItem(atPath: destURL.path),
                       let size = attrs[.size] as? Int64 {
                        self.downloads[index].totalBytes = size
                        self.downloads[index].downloadedBytes = size
                    }
                    
                    self.saveDownloads()
                    self.activeTasks.removeValue(forKey: downloadId)
                    self.processQueue()
                }
            }
            
            Logger.shared.log("Download completed: \(downloadId) -> \(fileName)", type: "Download")
        } catch {
            markFailed(id: downloadId, error: "Failed to save file: \(error.localizedDescription)")
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let downloadId = downloadTask.taskDescription else { return }
        
        // Throttle progress updates to max every 0.5 seconds to reduce UI churn
        let now = Date()
        if let lastUpdate = lastProgressUpdate[downloadId],
           now.timeIntervalSince(lastUpdate) < 0.5 {
            return
        }
        lastProgressUpdate[downloadId] = now
        
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        
        DispatchQueue.main.async {
            if let index = self.downloads.firstIndex(where: { $0.id == downloadId }) {
                self.downloads[index].progress = progress
                self.downloads[index].downloadedBytes = totalBytesWritten
                self.downloads[index].totalBytes = totalBytesExpectedToWrite
            }
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let downloadId = task.taskDescription else { return }
        
        if let error = error as NSError? {
            // Don't mark as failed if user cancelled
            if error.code == NSURLErrorCancelled {
                return
            }
            markFailed(id: downloadId, error: error.localizedDescription)
        }
    }
    
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Re-attach custom headers that get stripped on redirect by background sessions
        guard let downloadId = task.taskDescription,
              let item = downloads.first(where: { $0.id == downloadId }) else {
            completionHandler(request)
            return
        }
        
        var updatedRequest = request
        let targetURL = updatedRequest.url ?? URL(string: item.streamURL)
        let refreshedHeaders = targetURL.map { effectiveHeaders(item.headers, for: $0) } ?? item.headers
        for (key, value) in refreshedHeaders {
            let lowerKey = key.lowercased()
            if lowerKey == "cookie" || lowerKey == "user-agent" {
                updatedRequest.setValue(value, forHTTPHeaderField: key)
            } else if updatedRequest.value(forHTTPHeaderField: key) == nil {
                updatedRequest.setValue(value, forHTTPHeaderField: key)
            }
        }
        completionHandler(updatedRequest)
    }
}
