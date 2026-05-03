//
//  HLSDownloader.swift
//  Luna
//
//  Manual M3U8 parser + segment downloader.
//  Parses master/variant playlists, downloads .ts segments, and concatenates
//  them into a single .ts file that VLC/mpv can play natively.
//

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
    
    private var isCancelled = false
    private var currentTask: URLSessionDataTask?
    private let session: URLSession
    #if canImport(UIKit)
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    #endif
    
    /// Progress callback: (fractionCompleted)
    var onProgress: ((Double) -> Void)?
    /// Completion callback: (Result<URL, Error>)
    var onCompletion: ((Result<URL, Error>) -> Void)?
    
    init(streamURL: URL, headers: [String: String], destinationURL: URL, downloadId: String) {
        self.streamURL = streamURL
        self.headers = headers
        self.destinationURL = destinationURL
        self.downloadId = downloadId
        
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }
    
    // MARK: - Public API
    
    func start() {
        isCancelled = false
        beginBackgroundTask()
        
        Task {
            do {
                // Step 1: Fetch the M3U8 playlist
                let playlistContent = try await fetchPlaylist(url: streamURL)
                
                guard !isCancelled else { return }
                
                // Step 2: Determine if master or media playlist
                let mediaPlaylistURL: URL
                let mediaPlaylistContent: String
                
                if isMasterPlaylist(playlistContent) {
                    // Parse master playlist and select best variant
                    let variants = parseMasterPlaylist(playlistContent, baseURL: streamURL)
                    guard let best = selectBestVariant(variants) else {
                        throw HLSError.noVariantsFound
                    }
                    Logger.shared.log("HLS: Selected variant \(best.resolution ?? "unknown") @ \(best.bandwidth)bps", type: "Download")
                    
                    mediaPlaylistContent = try await fetchPlaylist(url: best.url)
                    mediaPlaylistURL = best.url
                } else {
                    // Already a media playlist
                    mediaPlaylistContent = playlistContent
                    mediaPlaylistURL = streamURL
                }
                
                guard !isCancelled else { return }
                
                // Step 3: Parse media playlist for segments
                let segments = parseMediaPlaylist(mediaPlaylistContent, baseURL: mediaPlaylistURL)
                guard !segments.isEmpty else {
                    throw HLSError.noSegmentsFound
                }
                
                Logger.shared.log("HLS: Found \(segments.count) segments to download", type: "Download")
                
                // Step 4: Parse encryption info if present
                let encryptionKey = parseEncryptionKey(from: mediaPlaylistContent, baseURL: mediaPlaylistURL)
                var keyData: Data? = nil
                if let encKey = encryptionKey, encKey.method == "AES-128" {
                    keyData = try await fetchData(url: encKey.keyURL)
                    Logger.shared.log("HLS: Downloaded AES-128 encryption key", type: "Download")
                }
                
                // Step 5: Check for initialization segment (#EXT-X-MAP)
                let initSegmentURL = parseInitSegment(from: mediaPlaylistContent, baseURL: mediaPlaylistURL)
                
                guard !isCancelled else { return }
                
                // Step 6: Download and concatenate segments
                try await downloadAndConcatenateSegments(
                    segments: segments,
                    initSegmentURL: initSegmentURL,
                    encryptionKey: encryptionKey,
                    keyData: keyData,
                    to: destinationURL
                )
                
                guard !isCancelled else {
                    try? FileManager.default.removeItem(at: destinationURL)
                    return
                }
                
                Logger.shared.log("HLS: Download complete -> \(destinationURL.lastPathComponent)", type: "Download")
                onCompletion?(.success(destinationURL))
                endBackgroundTask()
                
            } catch {
                if !isCancelled {
                    Logger.shared.log("HLS download failed: \(error.localizedDescription)", type: "Download")
                    onCompletion?(.failure(error))
                }
                endBackgroundTask()
            }
        }
    }
    
    func cancel() {
        isCancelled = true
        currentTask?.cancel()
        endBackgroundTask()
    }
    
    // MARK: - Background Task Management
    
    private func beginBackgroundTask() {
        #if canImport(UIKit) && !os(watchOS)
        guard backgroundTaskId == .invalid else { return }
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "HLSDownload-\(downloadId)") { [weak self] in
            // System is about to expire the task — cancel gracefully
            self?.cancel()
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
    
    private func fetchPlaylist(url: URL) async throws -> String {
        let data = try await fetchData(url: url)
        guard let content = String(data: data, encoding: .utf8) else {
            throw HLSError.invalidPlaylistData
        }
        return content
    }
    
    private func fetchData(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        let (data, response) = try await session.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw HLSError.httpError(statusCode: httpResponse.statusCode)
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
        to outputURL: URL
    ) async throws {
        try checkSystemBackoff()

        let partialURL = outputURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).partial")
        var completed = false

        try? FileManager.default.removeItem(at: partialURL)
        guard FileManager.default.createFile(atPath: partialURL.path, contents: nil) else {
            throw HLSError.couldNotCreateOutput
        }

        let fileHandle = try FileHandle(forWritingTo: partialURL)
        defer {
            try? fileHandle.close()
            if !completed {
                try? FileManager.default.removeItem(at: partialURL)
            }
        }
        
        // Write initialization segment first if present
        if let initURL = initSegmentURL {
            try checkSystemBackoff()
            let initData = try await fetchData(url: initURL)
            let decrypted = try decryptIfNeeded(data: initData, key: encryptionKey, keyData: keyData, segmentIndex: -1)
            fileHandle.write(decrypted)
        }
        
        // Download segments sequentially and append
        let totalSegments = segments.count
        
        for (index, segmentURL) in segments.enumerated() {
            guard !isCancelled else {
                throw HLSError.cancelled
            }

            try checkSystemBackoff()
            
            let segmentData = try await fetchSegmentWithRetry(url: segmentURL, maxRetries: 3)
            let decrypted = try decryptIfNeeded(data: segmentData, key: encryptionKey, keyData: keyData, segmentIndex: index)
            
            fileHandle.write(decrypted)
            
            // Report progress
            let progress = Double(index + 1) / Double(totalSegments)
            DispatchQueue.main.async { [weak self] in
                self?.onProgress?(progress)
            }
        }

        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.moveItem(at: partialURL, to: outputURL)
        completed = true
    }
    
    private func fetchSegmentWithRetry(url: URL, maxRetries: Int) async throws -> Data {
        var lastError: Error = HLSError.unknownError
        
        for attempt in 0..<maxRetries {
            do {
                return try await fetchData(url: url)
            } catch {
                lastError = error
                if isCancelled { throw HLSError.cancelled }
                
                // Wait before retrying (exponential backoff)
                if attempt < maxRetries - 1 {
                    let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                    try await Task.sleep(nanoseconds: delay)
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
    case cancelled
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
        case .cancelled:
            return "Download was cancelled"
        case .couldNotCreateOutput:
            return "Could not create HLS output file"
        case .systemBackoff(let reason):
            return reason
        case .unknownError:
            return "An unknown error occurred"
        }
    }
}
