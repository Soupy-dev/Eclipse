//
//  DownloadManager.swift
//  Luna
//
//  Created on 27/02/26.
//

import Foundation
import Combine

// MARK: - Download Item Model

enum DownloadStatus: String, Codable {
    case queued
    case downloading
    case paused
    case completed
    case failed
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
    let serviceBaseURL: String
    let episodePlaybackContext: EpisodePlaybackContext?
    var status: DownloadStatus
    var progress: Double
    var totalBytes: Int64
    var downloadedBytes: Int64
    var localFileName: String?
    var subtitleFileName: String?
    var error: String?
    var dateAdded: Date
    var dateCompleted: Date?
    let isAnime: Bool
    
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
    
    var mediaInfo: MediaInfo {
        if isMovie {
            return .movie(id: tmdbId, title: title, posterURL: posterURL, isAnime: isAnime)
        } else {
            return .episode(
                showId: tmdbId,
                seasonNumber: seasonNumber ?? 1,
                episodeNumber: episodeNumber ?? 1,
                showTitle: title,
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
    private var activeHLSDownloaders: [String: HLSDownloader] = [:]
    
    private let maxConcurrentDownloads = 2
    private let fileManager = FileManager.default
    private let accessQueue = DispatchQueue(label: "com.luna.download-manager", attributes: .concurrent)
    
    private var persistenceURL: URL {
        downloadsDirectory.appendingPathComponent(".downloads_metadata.json")
    }
    
    var downloadsDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Downloads")
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    
    /// Background session completion handler set by AppDelegate/SceneDelegate
    var backgroundCompletionHandler: (() -> Void)?
    
    private override init() {
        super.init()
        
        let config = URLSessionConfiguration.background(withIdentifier: "com.luna.downloads")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.httpMaximumConnectionsPerHost = 4
        backgroundSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        
        loadDownloads()
        
        // Clean up orphaned files that aren't tracked in metadata
        cleanOrphanedFiles()
        
        // Resume any downloads that were marked as downloading (app was killed)
        resumeInterruptedDownloads()
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
        serviceBaseURL: String,
        isAnime: Bool,
        episodePlaybackContext: EpisodePlaybackContext? = nil
    ) {
        let id: String
        if isMovie {
            id = "dl_movie_\(tmdbId)"
        } else {
            id = "dl_ep_\(tmdbId)_s\(seasonNumber ?? 0)_e\(episodeNumber ?? 0)"
        }
        
        // Check if already downloading or completed
        if let existing = downloads.first(where: { $0.id == id }) {
            if existing.status == .completed || existing.status == .downloading || existing.status == .queued {
                Logger.shared.log("Download already exists: \(id) status=\(existing.status.rawValue)", type: "Download")
                return
            }
            // If failed, remove and re-queue
            removeDownload(id: id, deleteFile: true)
        }
        
        let item = DownloadItem(
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
        
        DispatchQueue.main.async {
            self.downloads.append(item)
            self.saveDownloads()
            self.processQueue()
        }
        
        Logger.shared.log("Enqueued download: \(displayTitle) id=\(id)", type: "Download")
    }
    
    func pauseDownload(id: String) {
        guard let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].status == .downloading else { return }
        
        if let task = activeTasks[id] {
            task.cancel(byProducingResumeData: { [weak self] data in
                if let data = data {
                    self?.resumeDataStore[id] = data
                }
            })
            activeTasks.removeValue(forKey: id)
        } else if let downloader = activeHLSDownloaders[id] {
            // HLS downloads don't support resume — cancel and restart on resume
            downloader.cancel()
            activeHLSDownloaders.removeValue(forKey: id)
        }
        
        DispatchQueue.main.async {
            self.downloads[index].status = .paused
            self.saveDownloads()
            self.processQueue()
        }
        
        Logger.shared.log("Paused download: \(id)", type: "Download")
    }
    
    func resumeDownload(id: String) {
        guard let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].status == .paused || downloads[index].status == .failed else { return }
        
        DispatchQueue.main.async {
            self.downloads[index].status = .queued
            self.downloads[index].error = nil
            // HLS downloads restart from scratch since they don't support resume data
            if self.downloads[index].isHLS {
                self.downloads[index].progress = 0
                self.downloads[index].downloadedBytes = 0
            }
            self.saveDownloads()
            self.processQueue()
        }
        
        Logger.shared.log("Resumed download: \(id)", type: "Download")
    }
    
    func cancelDownload(id: String) {
        if let task = activeTasks[id] {
            task.cancel()
            activeTasks.removeValue(forKey: id)
        }
        if let downloader = activeHLSDownloaders[id] {
            downloader.cancel()
            activeHLSDownloaders.removeValue(forKey: id)
        }
        resumeDataStore.removeValue(forKey: id)
        removeDownload(id: id, deleteFile: true)
        processQueue()
        
        Logger.shared.log("Cancelled download: \(id)", type: "Download")
    }
    
    func removeDownload(id: String, deleteFile: Bool) {
        if let index = downloads.firstIndex(where: { $0.id == id }) {
            if deleteFile, let fileName = downloads[index].localFileName {
                let fileURL = downloadsDirectory.appendingPathComponent(fileName)
                try? fileManager.removeItem(at: fileURL)
            }
            if deleteFile, let subFile = downloads[index].subtitleFileName {
                let subURL = downloadsDirectory.appendingPathComponent(subFile)
                try? fileManager.removeItem(at: subURL)
            }
            DispatchQueue.main.async {
                self.downloads.remove(at: index)
                self.saveDownloads()
            }
        }
    }
    
    func deleteAllForShow(tmdbId: Int) {
        let matchingIds = Set(downloads.filter { $0.tmdbId == tmdbId && $0.status == .completed }.map { $0.id })
        guard !matchingIds.isEmpty else { return }

        for item in downloads where matchingIds.contains(item.id) {
            if let fileName = item.localFileName {
                let fileURL = downloadsDirectory.appendingPathComponent(fileName)
                try? fileManager.removeItem(at: fileURL)
            }
            if let subFile = item.subtitleFileName {
                let subURL = downloadsDirectory.appendingPathComponent(subFile)
                try? fileManager.removeItem(at: subURL)
            }
        }

        DispatchQueue.main.async {
            self.downloads.removeAll { matchingIds.contains($0.id) }
            self.saveDownloads()
        }
    }

    func deleteAllCompleted() {
        let completedIds = Set(downloads.filter { $0.status == .completed }.map { $0.id })
        guard !completedIds.isEmpty else { return }

        // Delete files first
        for item in downloads where completedIds.contains(item.id) {
            if let fileName = item.localFileName {
                let fileURL = downloadsDirectory.appendingPathComponent(fileName)
                try? fileManager.removeItem(at: fileURL)
            }
            if let subFile = item.subtitleFileName {
                let subURL = downloadsDirectory.appendingPathComponent(subFile)
                try? fileManager.removeItem(at: subURL)
            }
        }

        // Remove all completed items from the array in one pass
        DispatchQueue.main.async {
            self.downloads.removeAll { completedIds.contains($0.id) }
            self.saveDownloads()
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
                if let index = downloads.firstIndex(where: { $0.id == item.id }) {
                    DispatchQueue.main.async {
                        self.downloads[index].status = .paused
                    }
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
        let url = downloadsDirectory.appendingPathComponent(fileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }
    
    func localSubtitleURL(for item: DownloadItem) -> URL? {
        guard let fileName = item.subtitleFileName else { return nil }
        let url = downloadsDirectory.appendingPathComponent(fileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }
    
    func isDownloaded(tmdbId: Int, isMovie: Bool, seasonNumber: Int? = nil, episodeNumber: Int? = nil) -> Bool {
        let id: String
        if isMovie {
            id = "dl_movie_\(tmdbId)"
        } else {
            id = "dl_ep_\(tmdbId)_s\(seasonNumber ?? 0)_e\(episodeNumber ?? 0)"
        }
        return downloads.first(where: { $0.id == id && $0.status == .completed }) != nil
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
    
    /// Total storage used by downloads
    func calculateStorageUsed() -> Int64 {
        var total: Int64 = 0
        for item in downloads where item.status == .completed {
            if let fileName = item.localFileName {
                let url = downloadsDirectory.appendingPathComponent(fileName)
                if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? Int64 {
                    total += size
                }
            }
        }
        return total
    }
    
    // MARK: - Queue Processing
    
    private func processQueue() {
        let currentlyDownloading = downloads.filter { $0.status == .downloading }.count
        let slotsAvailable = maxConcurrentDownloads - currentlyDownloading
        
        guard slotsAvailable > 0 else { return }
        
        let queued = downloads.filter { $0.status == .queued }
        let toStart = Array(queued.prefix(slotsAvailable))
        
        for item in toStart {
            startDownload(item)
        }
    }
    
    private func startDownload(_ item: DownloadItem) {
        guard let url = URL(string: item.streamURL) else {
            markFailed(id: item.id, error: "Invalid stream URL")
            return
        }
        
        // Route HLS streams to AVAssetDownloadURLSession for proper segment downloading
        if item.isHLS {
            startHLSDownload(item)
            return
        }
        
        var request = URLRequest(url: url)
        for (key, value) in item.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        let task: URLSessionDownloadTask
        if let resumeData = resumeDataStore[item.id] {
            task = backgroundSession.downloadTask(withResumeData: resumeData)
            resumeDataStore.removeValue(forKey: item.id)
        } else {
            task = backgroundSession.downloadTask(with: request)
        }
        
        task.taskDescription = item.id
        activeTasks[item.id] = task
        
        if let index = downloads.firstIndex(where: { $0.id == item.id }) {
            DispatchQueue.main.async {
                self.downloads[index].status = .downloading
                self.saveDownloads()
            }
        }
        
        task.resume()
        
        // Also download subtitle if available
        if let subtitleURLString = item.subtitleURL, let subtitleURL = URL(string: subtitleURLString) {
            downloadSubtitle(for: item.id, from: subtitleURL)
        }
        
        Logger.shared.log("Started download: \(item.displayTitle)", type: "Download")
    }
    
    private func startHLSDownload(_ item: DownloadItem) {
        guard let url = URL(string: item.streamURL) else {
            markFailed(id: item.id, error: "Invalid stream URL")
            return
        }
        
        let fileName = "\(item.id).ts"
        let destURL = downloadsDirectory.appendingPathComponent(fileName)
        
        let downloader = HLSDownloader(
            streamURL: url,
            headers: item.headers,
            destinationURL: destURL,
            downloadId: item.id
        )
        
        downloader.onProgress = { [weak self] progress in
            guard let self = self else { return }
            if let index = self.downloads.firstIndex(where: { $0.id == item.id }) {
                self.downloads[index].progress = progress
            }
        }
        
        downloader.onCompletion = { [weak self] result in
            guard let self = self else { return }
            self.activeHLSDownloaders.removeValue(forKey: item.id)
            
            switch result {
            case .success(let fileURL):
                DispatchQueue.main.async {
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
                        
                        self.saveDownloads()
                        self.processQueue()
                    }
                }
                Logger.shared.log("HLS download completed: \(item.displayTitle) -> \(fileName)", type: "Download")
                
            case .failure(let error):
                self.markFailed(id: item.id, error: error.localizedDescription)
            }
        }
        
        activeHLSDownloaders[item.id] = downloader
        
        if let index = downloads.firstIndex(where: { $0.id == item.id }) {
            DispatchQueue.main.async {
                self.downloads[index].status = .downloading
                self.saveDownloads()
            }
        }
        
        downloader.start()
        
        // Also download subtitle if available
        if let subtitleURLString = item.subtitleURL, let subtitleURL = URL(string: subtitleURLString) {
            downloadSubtitle(for: item.id, from: subtitleURL)
        }
        
        Logger.shared.log("Started HLS download: \(item.displayTitle)", type: "Download")
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
    
    private func downloadSubtitle(for downloadId: String, from url: URL) {
        let subtitleTask = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            guard let self = self, let tempURL = tempURL, error == nil else { return }
            
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
            let fileName = "\(downloadId)_sub.\(ext)"
            let destURL = self.downloadsDirectory.appendingPathComponent(fileName)
            
            try? self.fileManager.removeItem(at: destURL)
            do {
                try self.fileManager.moveItem(at: tempURL, to: destURL)
                DispatchQueue.main.async {
                    if let index = self.downloads.firstIndex(where: { $0.id == downloadId }) {
                        self.downloads[index].subtitleFileName = fileName
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
    
    private func markFailed(id: String, error: String) {
        activeTasks.removeValue(forKey: id)
        DispatchQueue.main.async {
            if let index = self.downloads.firstIndex(where: { $0.id == id }) {
                self.downloads[index].status = .failed
                self.downloads[index].error = error
                self.saveDownloads()
                self.processQueue()
            }
        }
        Logger.shared.log("Download failed: \(id) - \(error)", type: "Download")
    }
    
    private func resumeInterruptedDownloads() {
        for (index, item) in downloads.enumerated() where item.status == .downloading {
            DispatchQueue.main.async {
                self.downloads[index].status = .queued
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.processQueue()
        }
    }
    
    // MARK: - Orphan Cleanup
    
    /// Removes any files in the downloads directory that are not referenced by a tracked download.
    /// This catches files left behind by interrupted deletions, crashes, or code bugs.
    private func cleanOrphanedFiles() {
        let dir = downloadsDirectory
        guard let contents = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return }
        
        // Build set of all file names currently tracked
        var trackedFileNames = Set<String>()
        trackedFileNames.insert(".downloads_metadata.json")
        for item in downloads {
            if let f = item.localFileName { trackedFileNames.insert(f) }
            if let s = item.subtitleFileName { trackedFileNames.insert(s) }
        }
        
        var removedCount = 0
        var freedBytes: Int64 = 0
        for fileURL in contents {
            let name = fileURL.lastPathComponent
            if !trackedFileNames.contains(name) {
                if let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
                   let size = attrs[.size] as? Int64 {
                    freedBytes += size
                }
                try? fileManager.removeItem(at: fileURL)
                removedCount += 1
            }
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

// MARK: - URLSession Delegate

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let downloadId = downloadTask.taskDescription else { return }
        
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
            // Generic binary — trust the URL extension if it's a known video format
            case "application/octet-stream":
                ext = Self.knownVideoExtensions.contains(urlExt) ? urlExt : (urlExt.isEmpty ? "mp4" : urlExt)
            default:
                // Unknown MIME — prefer URL extension if it's a known format
                ext = Self.knownVideoExtensions.contains(urlExt) ? urlExt : "mp4"
            }
        } else {
            ext = Self.knownVideoExtensions.contains(urlExt) ? urlExt : (urlExt.isEmpty ? "mp4" : urlExt)
        }
        
        let fileName = "\(downloadId).\(ext)"
        let destURL = downloadsDirectory.appendingPathComponent(fileName)
        
        try? fileManager.removeItem(at: destURL)
        
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
              let item = downloads.first(where: { $0.id == downloadId }),
              !item.headers.isEmpty else {
            completionHandler(request)
            return
        }
        
        var updatedRequest = request
        for (key, value) in item.headers {
            if updatedRequest.value(forHTTPHeaderField: key) == nil {
                updatedRequest.setValue(value, forHTTPHeaderField: key)
            }
        }
        completionHandler(updatedRequest)
    }
}


