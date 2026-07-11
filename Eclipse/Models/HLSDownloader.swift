// Manual M3U8 parser + segment downloader.
// Parses master/variant playlists, downloads .ts segments, and concatenates
// them into a single .ts file that VLC/mpv can play natively.

import Foundation
import CommonCrypto
#if canImport(UIKit)
import UIKit
#endif

// MARK: - HLS Models

/// Represents a variant stream from a master playlist
struct HLSVariant {
    let url: URL
    let bandwidth: Int
    let resolution: String? // e.g. "1920x1080"
}

/// Represents the encryption method for segments
struct HLSEncryptionKey {
    let method: String        // "AES-128" or "NONE"
    let keyURL: URL
    let iv: Data?
}

// MARK: - HLS Downloader

final class HLSDownloader: @unchecked Sendable {
    
    private let streamURL: URL
    private let headers: [String: String]
    private let destinationURL: URL
    private let downloadId: String

    /// Number of segments already written to the partial file from a prior run.
    private let resumeFromSegment: Int
    /// Byte length of the partial file at the last checkpoint; the partial is
    /// truncated back to this before appending (discards a torn segment).
    private let resumeByteCount: Int64
    /// Variant playlist chosen on the first run, reused on resume so the segment
    /// list is identical. When nil, the variant is selected fresh.
    private let pinnedVariantURL: URL?
    /// Segment count recorded on the first run, used to validate a resume.
    private let expectedTotalSegments: Int

    private var isCancelled = false
    private var cancellationError: HLSError = .cancelled
    private var workerTask: Task<Void, Never>?
    private var didFinish = false
    private let stateLock = NSLock()
    private let session: URLSession
    #if canImport(UIKit)
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    #endif
    
    /// Progress callback: (fractionCompleted)
    var onProgress: ((Double) -> Void)?
    /// Completion callback: (Result<URL, Error>)
    var onCompletion: ((Result<URL, Error>) -> Void)?
    /// Reports the resolved variant playlist URL and its segment count once per run,
    /// so the caller can pin the same variant when resuming. Called on the main queue.
    var onVariantResolved: ((URL, Int) -> Void)?
    /// Checkpoint after each segment write: (segmentsWritten, partialByteCount).
    /// Called on the main queue.
    var onCheckpoint: ((Int, Int64) -> Void)?

    init(streamURL: URL, headers: [String: String], destinationURL: URL, downloadId: String,
         resumeFromSegment: Int = 0, resumeByteCount: Int64 = 0,
         pinnedVariantURL: URL? = nil, expectedTotalSegments: Int = 0) {
        self.streamURL = streamURL
        self.headers = headers
        self.destinationURL = destinationURL
        self.downloadId = downloadId
        self.resumeFromSegment = resumeFromSegment
        self.resumeByteCount = resumeByteCount
        self.pinnedVariantURL = pinnedVariantURL
        self.expectedTotalSegments = expectedTotalSegments

        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }
    
    // MARK: - Public API
    
    func start() {
        stateLock.lock()
        guard workerTask == nil else {
            stateLock.unlock()
            return
        }
        isCancelled = false
        cancellationError = .cancelled
        didFinish = false
        stateLock.unlock()

        beginBackgroundTask()
        
        let task = Task { [weak self] in
            guard let self = self else { return }
            defer {
                self.clearWorkerTask()
                self.endBackgroundTask()
            }

            do {
                // Step 1: Fetch the M3U8 playlist
                try self.checkCancelled()
                let playlistContent = try await self.fetchPlaylist(url: self.streamURL)
                
                try self.checkCancelled()
                
                // Step 2: Determine if master or media playlist
                let mediaPlaylistURL: URL
                let mediaPlaylistContent: String
                
                if let pinned = self.pinnedVariantURL {
                    // Resuming: reuse the exact variant chosen on the first run so the
                    // segment list is byte-for-byte identical to what we already wrote.
                    mediaPlaylistContent = try await self.fetchPlaylist(url: pinned)
                    mediaPlaylistURL = pinned
                } else if self.isMasterPlaylist(playlistContent) {
                    // Parse master playlist and select best variant
                    let variants = self.parseMasterPlaylist(playlistContent, baseURL: self.streamURL)
                    guard let best = self.selectBestVariant(variants) else {
                        throw HLSError.noVariantsFound
                    }
                    Logger.shared.log("HLS: Selected variant \(best.resolution ?? "unknown") @ \(best.bandwidth)bps", type: "Download")

                    mediaPlaylistContent = try await self.fetchPlaylist(url: best.url)
                    mediaPlaylistURL = best.url
                } else {
                    // Already a media playlist
                    mediaPlaylistContent = playlistContent
                    mediaPlaylistURL = self.streamURL
                }
                
                try self.checkCancelled()
                
                // Step 3: Parse media playlist for segments
                let segments = self.parseMediaPlaylist(mediaPlaylistContent, baseURL: mediaPlaylistURL)
                guard !segments.isEmpty else {
                    throw HLSError.noSegmentsFound
                }

                Logger.shared.log("HLS: Found \(segments.count) segments to download", type: "Download")

                // Pin the resolved variant + segment count so a later resume can reuse
                // the identical playlist and validate the partial against it.
                let resolvedVariant = mediaPlaylistURL
                let totalSegmentCount = segments.count
                DispatchQueue.main.async { [weak self] in
                    self?.onVariantResolved?(resolvedVariant, totalSegmentCount)
                }

                // If the playlist no longer matches what we checkpointed (token expired,
                // different ABR rendition, re-encoded source), restart from scratch
                // rather than appending mismatched segments onto the partial.
                var effectiveResumeSegment = self.resumeFromSegment
                if effectiveResumeSegment > 0,
                   self.expectedTotalSegments > 0,
                   segments.count != self.expectedTotalSegments {
                    Logger.shared.log("HLS: resume mismatch (playlist has \(segments.count) segments, expected \(self.expectedTotalSegments)); restarting from scratch", type: "Download")
                    effectiveResumeSegment = 0
                }
                
                // Step 4: Parse encryption info if present
                let encryptionKey = self.parseEncryptionKey(from: mediaPlaylistContent, baseURL: mediaPlaylistURL)
                var keyData: Data? = nil
                if let encKey = encryptionKey, encKey.method == "AES-128" {
                    keyData = try await self.fetchData(
                        url: encKey.keyURL,
                        maximumResponseBytes: Self.maximumEncryptionKeyBytes
                    )
                    try self.checkCancelled()
                    Logger.shared.log("HLS: Downloaded AES-128 encryption key", type: "Download")
                }
                
                // Step 5: Check for initialization segment (#EXT-X-MAP)
                let initSegmentURL = self.parseInitSegment(from: mediaPlaylistContent, baseURL: mediaPlaylistURL)
                
                try self.checkCancelled()
                
                // Step 6: Download and concatenate segments
                try await self.downloadAndConcatenateSegments(
                    segments: segments,
                    initSegmentURL: initSegmentURL,
                    encryptionKey: encryptionKey,
                    keyData: keyData,
                    to: self.destinationURL,
                    resumeFromSegment: effectiveResumeSegment,
                    resumeByteCount: self.resumeByteCount
                )
                
                try self.checkCancelled()
                
                Logger.shared.log("HLS: Download complete -> \(self.destinationURL.lastPathComponent)", type: "Download")
                self.finish(.success(self.destinationURL))
                
            } catch {
                if self.isCancellationError(error) {
                    self.finish(.failure(self.currentCancellationError()))
                } else {
                    Logger.shared.log("HLS download failed: \(error.localizedDescription)", type: "Download")
                    self.finish(.failure(error))
                }
            }
        }

        stateLock.lock()
        workerTask = task
        stateLock.unlock()
    }
    
    func cancel(reason: HLSError = .cancelled) {
        let task: Task<Void, Never>?
        stateLock.lock()
        isCancelled = true
        cancellationError = reason
        task = workerTask
        stateLock.unlock()

        task?.cancel()
        session.invalidateAndCancel()
        endBackgroundTask()
    }
    
    // MARK: - Background Task Management
    
    private func beginBackgroundTask() {
        #if canImport(UIKit) && !os(watchOS)
        guard backgroundTaskId == .invalid else { return }
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "HLSDownload-\(downloadId)") { [weak self] in
            // System is about to expire the task; let the manager requeue it.
            self?.cancel(reason: .backgroundTimeExpired)
        }
        #endif
    }
    
    private func endBackgroundTask() {
        #if canImport(UIKit) && !os(watchOS)
        guard backgroundTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskId)
        backgroundTaskId = .invalid
        #endif
    }
    
    // MARK: - Playlist Fetching

    private static let maximumPlaylistBytes = 5 * 1024 * 1024
    private static let maximumEncryptionKeyBytes = 64 * 1024
    private static let maximumMediaObjectBytes = 128 * 1024 * 1024
    
    private func fetchPlaylist(url: URL) async throws -> String {
        let data = try await fetchData(
            url: url,
            maximumResponseBytes: Self.maximumPlaylistBytes
        )
        guard let content = String(data: data, encoding: .utf8) else {
            throw HLSError.invalidPlaylistData
        }
        return content
    }
    
    private func fetchData(
        url: URL,
        maximumResponseBytes: Int = HLSDownloader.maximumMediaObjectBytes
    ) async throws -> Data {
        try checkCancelled()

        let effectiveHeaders = CloudflareBypassManager.shared.headersByApplyingCachedBypass(headers, for: url)
        var request = URLRequest(url: url)
        for (key, value) in effectiveHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        let (data, response) = try await session.boundedData(
            for: request,
            maximumResponseBytes: maximumResponseBytes
        )
        try checkCancelled()
        
        if let httpResponse = response as? HTTPURLResponse {
            let bodyPreview = String(data: data.prefix(1_000_000), encoding: .utf8) ?? ""
            if CloudflareBypassManager.isChallengeResponse(
                status: httpResponse.statusCode,
                body: bodyPreview,
                headers: CloudflareBypassManager.headersDictionary(from: httpResponse)
            ) {
                throw HLSError.cloudflareVerificationRequired
            }
            if !(200...299).contains(httpResponse.statusCode) {
                throw HLSError.httpError(statusCode: httpResponse.statusCode)
            }
        }
        
        return data
    }
    
    // MARK: - Playlist Parsing
    
    private func isMasterPlaylist(_ content: String) -> Bool {
        return content.contains("#EXT-X-STREAM-INF")
    }
    
    func parseMasterPlaylist(_ content: String, baseURL: URL) -> [HLSVariant] {
        var variants: [HLSVariant] = []
        let lines = content.components(separatedBy: .newlines)
        
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attributes = line.replacingOccurrences(of: "#EXT-X-STREAM-INF:", with: "")
                let bandwidth = parseAttribute(attributes, key: "BANDWIDTH").flatMap { Int($0) } ?? 0
                let resolution = parseAttribute(attributes, key: "RESOLUTION")
                
                // Next non-empty, non-comment line is the URI
                i += 1
                while i < lines.count {
                    let uri = lines[i].trimmingCharacters(in: .whitespaces)
                    if !uri.isEmpty && !uri.hasPrefix("#") {
                        if let variantURL = resolveURL(uri, baseURL: baseURL) {
                            variants.append(HLSVariant(url: variantURL, bandwidth: bandwidth, resolution: resolution))
                        }
                        break
                    }
                    i += 1
                }
            }
            i += 1
        }
        
        return variants
    }
    
    func selectBestVariant(_ variants: [HLSVariant]) -> HLSVariant? {
        // Select highest bandwidth variant (best quality)
        return variants.max(by: { $0.bandwidth < $1.bandwidth })
    }
    
    func parseMediaPlaylist(_ content: String, baseURL: URL) -> [URL] {
        var segments: [URL] = []
        let lines = content.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip empty lines and tags
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            
            // This should be a segment URI
            if let segmentURL = resolveURL(trimmed, baseURL: baseURL) {
                segments.append(segmentURL)
            }
        }
        
        return segments
    }
    
    private func parseEncryptionKey(from content: String, baseURL: URL) -> HLSEncryptionKey? {
        let lines = content.components(separatedBy: .newlines)
        
        // Find the last #EXT-X-KEY (it applies to subsequent segments)
        var lastKey: HLSEncryptionKey? = nil
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#EXT-X-KEY:") else { continue }
            
            let attributes = trimmed.replacingOccurrences(of: "#EXT-X-KEY:", with: "")
            let method = parseAttribute(attributes, key: "METHOD") ?? "NONE"
            
            if method == "NONE" {
                lastKey = nil
                continue
            }
            
            guard let uriString = parseAttribute(attributes, key: "URI"),
                  let keyURL = resolveURL(uriString, baseURL: baseURL) else { continue }
            
            var ivData: Data? = nil
            if let ivString = parseAttribute(attributes, key: "IV") {
                ivData = hexStringToData(ivString)
            }
            
            lastKey = HLSEncryptionKey(method: method, keyURL: keyURL, iv: ivData)
        }
        
        return lastKey
    }
    
    private func parseInitSegment(from content: String, baseURL: URL) -> URL? {
        let lines = content.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#EXT-X-MAP:") else { continue }
            
            let attributes = trimmed.replacingOccurrences(of: "#EXT-X-MAP:", with: "")
            if let uriString = parseAttribute(attributes, key: "URI"),
               let initURL = resolveURL(uriString, baseURL: baseURL) {
                return initURL
            }
        }
        
        return nil
    }
    
    // MARK: - Segment Download & Concatenation
    
    private func downloadAndConcatenateSegments(
        segments: [URL],
        initSegmentURL: URL?,
        encryptionKey: HLSEncryptionKey?,
        keyData: Data?,
        to outputURL: URL,
        resumeFromSegment: Int,
        resumeByteCount: Int64
    ) async throws {
        try checkSystemBackoff()

        let partialURL = outputURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).partial")
        var completed = false
        var preservePartial = false

        // Resume only when we have a checkpoint AND the on-disk partial is at least as long as that checkpoint.
        let partialSize = Self.fileSize(at: partialURL)
        let isResuming = resumeFromSegment > 0
            && resumeByteCount > 0
            && partialSize >= resumeByteCount

        let fileHandle: FileHandle
        if isResuming {
            fileHandle = try FileHandle(forWritingTo: partialURL)
            try fileHandle.truncate(atOffset: UInt64(resumeByteCount))
            try fileHandle.seekToEnd()
            Logger.shared.log("HLS: resuming from segment \(resumeFromSegment) (\(resumeByteCount) bytes on disk)", type: "Download")
        } else {
            try? FileManager.default.removeItem(at: partialURL)
            guard FileManager.default.createFile(atPath: partialURL.path, contents: nil) else {
                throw HLSError.couldNotCreateOutput
            }
            fileHandle = try FileHandle(forWritingTo: partialURL)
        }

        defer {
            try? fileHandle.close()
            // Keep the partial when the stop is resumable (pause / background expiry /
            // thermal backoff); discard it only after a successful move or a hard failure.
            if !completed && !preservePartial {
                try? FileManager.default.removeItem(at: partialURL)
            }
        }

        do {
            // Initialization segment (fMP4 #EXT-X-MAP) is written exactly once, on a
            // fresh run - never re-appended on resume.
            if !isResuming, let initURL = initSegmentURL {
                try checkSystemBackoff()
                let initData = try await fetchData(url: initURL)
                try checkCancelled()
                let decrypted = try decryptIfNeeded(data: initData, key: encryptionKey, keyData: keyData, segmentIndex: -1)
                fileHandle.write(decrypted)
            }

            let totalSegments = segments.count
            let startIndex = isResuming ? resumeFromSegment : 0

            for index in startIndex..<totalSegments {
                try checkCancelled()
                try checkSystemBackoff()

                let segmentData = try await fetchSegmentWithRetry(url: segments[index], maxRetries: 3)
                try checkCancelled()
                let decrypted = try decryptIfNeeded(data: segmentData, key: encryptionKey, keyData: keyData, segmentIndex: index)

                fileHandle.write(decrypted)

                // Checkpoint AFTER the write lands so the recorded byte count never
                // exceeds what is actually on disk.
                let writtenSegments = index + 1
                let byteOffset = (try? fileHandle.offset()).map(Int64.init) ?? resumeByteCount
                let progress = Double(writtenSegments) / Double(totalSegments)
                DispatchQueue.main.async { [weak self] in
                    self?.onProgress?(progress)
                    self?.onCheckpoint?(writtenSegments, byteOffset)
                }
            }

            try? FileManager.default.removeItem(at: outputURL)
            try FileManager.default.moveItem(at: partialURL, to: outputURL)
            completed = true
        } catch {
            preservePartial = isResumableInterruption(error)
            throw error
        }
    }
    
    private func fetchSegmentWithRetry(url: URL, maxRetries: Int) async throws -> Data {
        var lastError: Error = HLSError.unknownError
        
        for attempt in 0..<maxRetries {
            do {
                return try await fetchData(url: url)
            } catch {
                lastError = error
                if isCancellationError(error) { throw currentCancellationError() }
                
                // Wait before retrying (exponential backoff)
                if attempt < maxRetries - 1 {
                    let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                    try await Task.sleep(nanoseconds: delay)
                    try checkCancelled()
                }
            }
        }
        
        throw lastError
    }
    
    // MARK: - AES-128 Decryption
    
    private func decryptIfNeeded(data: Data, key: HLSEncryptionKey?, keyData: Data?, segmentIndex: Int) throws -> Data {
        guard let encKey = key, encKey.method == "AES-128", let keyBytes = keyData else {
            return data
        }
        
        // IV: use explicit IV if provided, otherwise use segment sequence number as IV
        let iv: Data
        if let explicitIV = encKey.iv {
            iv = explicitIV
        } else {
            // Default IV is the segment sequence number as a 16-byte big-endian value
            var ivBytes = [UInt8](repeating: 0, count: 16)
            let seqNum = UInt32(max(segmentIndex, 0))
            ivBytes[12] = UInt8((seqNum >> 24) & 0xFF)
            ivBytes[13] = UInt8((seqNum >> 16) & 0xFF)
            ivBytes[14] = UInt8((seqNum >> 8) & 0xFF)
            ivBytes[15] = UInt8(seqNum & 0xFF)
            iv = Data(ivBytes)
        }
        
        return try aes128Decrypt(data: data, key: keyBytes, iv: iv)
    }
    
    private func aes128Decrypt(data: Data, key: Data, iv: Data) throws -> Data {
        let keyLength = kCCKeySizeAES128
        let bufferSize = data.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var numBytesDecrypted = 0
        
        let status = buffer.withUnsafeMutableBytes { bufferPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, keyLength,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress, data.count,
                            bufferPtr.baseAddress, bufferSize,
                            &numBytesDecrypted
                        )
                    }
                }
            }
        }
        
        guard status == kCCSuccess else {
            throw HLSError.decryptionFailed(status: Int(status))
        }
        
        return buffer.prefix(numBytesDecrypted)
    }
    
    // MARK: - Helpers
    
    private func parseAttribute(_ attributes: String, key: String) -> String? {
        // Handle quoted and unquoted attribute values
        // Pattern: KEY="value" or KEY=value
        let pattern = "\(key)=(?:\"([^\"]*)\"|([^,\\s]*))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        
        let range = NSRange(attributes.startIndex..., in: attributes)
        guard let match = regex.firstMatch(in: attributes, range: range) else { return nil }
        
        // Check quoted value first (group 1), then unquoted (group 2)
        if match.range(at: 1).location != NSNotFound,
           let valueRange = Range(match.range(at: 1), in: attributes) {
            return String(attributes[valueRange])
        }
        if match.range(at: 2).location != NSNotFound,
           let valueRange = Range(match.range(at: 2), in: attributes) {
            return String(attributes[valueRange])
        }
        
        return nil
    }
    
    private func resolveURL(_ urlString: String, baseURL: URL) -> URL? {
        // Handle absolute URLs
        if urlString.lowercased().hasPrefix("http://") || urlString.lowercased().hasPrefix("https://") {
            return URL(string: urlString)
        }
        
        // Handle relative URLs
        let baseDir = baseURL.deletingLastPathComponent()
        return baseDir.appendingPathComponent(urlString)
    }

    private func checkCancelled() throws {
        if Task.isCancelled {
            throw currentCancellationError()
        }

        stateLock.lock()
        let cancelled = isCancelled
        let error = cancellationError
        stateLock.unlock()

        if cancelled {
            throw error
        }
    }

    private func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let hlsError = error as? HLSError {
            switch hlsError {
            case .cancelled, .backgroundTimeExpired:
                return true
            default:
                return false
            }
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func currentCancellationError() -> HLSError {
        stateLock.lock()
        let error = cancellationError
        stateLock.unlock()
        return error
    }

    /// Whether an interruption should preserve the partial file for a later resume,
    /// as opposed to discarding it (genuine failure).
    private func isResumableInterruption(_ error: Error) -> Bool {
        if let hlsError = error as? HLSError {
            switch hlsError {
            case .cancelled, .backgroundTimeExpired, .systemBackoff:
                return true
            default:
                return false
            }
        }
        return isCancellationError(error)
    }

    private static func fileSize(at url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return 0 }
        return size
    }

    private func clearWorkerTask() {
        stateLock.lock()
        workerTask = nil
        stateLock.unlock()
    }

    private func finish(_ result: Result<URL, Error>) {
        stateLock.lock()
        guard !didFinish else {
            stateLock.unlock()
            return
        }
        didFinish = true
        stateLock.unlock()

        onCompletion?(result)
    }

    private func checkSystemBackoff() throws {
        #if canImport(UIKit)
        let thermalState = ProcessInfo.processInfo.thermalState
        if thermalState == .serious || thermalState == .critical {
            throw HLSError.systemBackoff(reason: "Paused for thermal state")
        }
        #endif
    }
    
    private func hexStringToData(_ hex: String) -> Data? {
        var hexStr = hex
        if hexStr.hasPrefix("0x") || hexStr.hasPrefix("0X") {
            hexStr = String(hexStr.dropFirst(2))
        }
        
        var data = Data()
        var i = hexStr.startIndex
        while i < hexStr.endIndex {
            guard let next = hexStr.index(i, offsetBy: 2, limitedBy: hexStr.endIndex) else { break }
            let byteString = hexStr[i..<next]
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            data.append(byte)
            i = next
        }
        
        return data
    }
}

// MARK: - Errors

enum HLSError: LocalizedError {
    case noVariantsFound
    case noSegmentsFound
    case invalidPlaylistData
    case httpError(statusCode: Int)
    case decryptionFailed(status: Int)
    case cloudflareVerificationRequired
    case cancelled
    case backgroundTimeExpired
    case couldNotCreateOutput
    case systemBackoff(reason: String)
    case unknownError
    
    var errorDescription: String? {
        switch self {
        case .noVariantsFound:
            return "No video variants found in HLS playlist"
        case .noSegmentsFound:
            return "No segments found in HLS media playlist"
        case .invalidPlaylistData:
            return "Could not read HLS playlist data"
        case .httpError(let code):
            return "HTTP error \(code) while downloading HLS content"
        case .decryptionFailed(let status):
            return "AES-128 decryption failed (status: \(status))"
        case .cloudflareVerificationRequired:
            return "Cloudflare verification required. Open the source once and try again."
        case .cancelled:
            return "Download was cancelled"
        case .backgroundTimeExpired:
            return "HLS download paused after iOS background time expired"
        case .couldNotCreateOutput:
            return "Could not create HLS output file"
        case .systemBackoff(let reason):
            return reason
        case .unknownError:
            return "An unknown error occurred"
        }
    }
}
