import Foundation
import CommonCrypto
#if canImport(UIKit)
import UIKit
#endif

struct HLSVariant {
    let url: URL
    let bandwidth: Int
    let resolution: String?
}

struct HLSEncryptionKey {
    let method: String
    let keyURL: URL
    let iv: Data?
}

final class HLSDownloader: @unchecked Sendable {

    private let streamURL: URL
    private let headers: [String: String]
    private let destinationURL: URL
    private let downloadId: String

    private let resumeFromSegment: Int

    private let resumeByteCount: Int64

    private let pinnedVariantURL: URL?

    private let expectedTotalSegments: Int

    private let enforcesConservativeDiskCapacityReserve: Bool

    private var isCancelled = false
    private var cancellationError: HLSError = .cancelled
    private var workerTask: Task<Void, Never>?
    private var didFinish = false
    private let stateLock = NSLock()
    private let transportStateLock = NSLock()
    private var nextRequestStartByHost: [String: TimeInterval] = [:]
    private var rateLimitedUntilByHost: [String: TimeInterval] = [:]
    private var rateLimitCountByHost: [String: Int] = [:]
    private let requestStartInterval: TimeInterval
    private let session: URLSession
    #if canImport(UIKit)
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    #endif

    var onProgress: ((Double) -> Void)?

    var onCompletion: ((Result<URL, Error>) -> Void)?

    var onVariantResolved: ((URL, Int) -> Void)?

    var onCheckpoint: ((Int, Int64) -> Void)?

    init(streamURL: URL, headers: [String: String], destinationURL: URL, downloadId: String,
         resumeFromSegment: Int = 0, resumeByteCount: Int64 = 0,
         pinnedVariantURL: URL? = nil, expectedTotalSegments: Int = 0,
         minimumRequestStartInterval: TimeInterval? = nil,
         enforcesConservativeDiskCapacityReserve: Bool = false) {
        self.streamURL = streamURL
        self.headers = headers
        self.destinationURL = destinationURL
        self.downloadId = downloadId
        self.resumeFromSegment = resumeFromSegment
        self.resumeByteCount = resumeByteCount
        self.pinnedVariantURL = pinnedVariantURL
        self.expectedTotalSegments = expectedTotalSegments
        self.enforcesConservativeDiskCapacityReserve = enforcesConservativeDiskCapacityReserve
        self.requestStartInterval = max(
            minimumRequestStartInterval ?? Self.minimumRequestStartInterval,
            0
        )

        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

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

                try self.checkCancelled()
                let playlistContent = try await self.fetchPlaylist(url: self.streamURL)

                try self.checkCancelled()

                let mediaPlaylistURL: URL
                let mediaPlaylistContent: String

                if let pinned = self.pinnedVariantURL {

                    mediaPlaylistContent = try await self.fetchPlaylist(url: pinned)
                    mediaPlaylistURL = pinned
                } else if self.isMasterPlaylist(playlistContent) {

                    let variants = self.parseMasterPlaylist(playlistContent, baseURL: self.streamURL)
                    guard let best = self.selectBestVariant(variants) else {
                        throw HLSError.noVariantsFound
                    }
                    Logger.shared.log("HLS: Selected variant \(best.resolution ?? "unknown") @ \(best.bandwidth)bps", type: "Download")

                    mediaPlaylistContent = try await self.fetchPlaylist(url: best.url)
                    mediaPlaylistURL = best.url
                } else {

                    mediaPlaylistContent = playlistContent
                    mediaPlaylistURL = self.streamURL
                }

                try self.checkCancelled()

                let segments = self.parseMediaPlaylist(mediaPlaylistContent, baseURL: mediaPlaylistURL)
                guard !segments.isEmpty else {
                    throw HLSError.noSegmentsFound
                }

                Logger.shared.log("HLS: Found \(segments.count) segments to download", type: "Download")

                let resolvedVariant = mediaPlaylistURL
                let totalSegmentCount = segments.count
                DispatchQueue.main.async { [weak self] in
                    self?.onVariantResolved?(resolvedVariant, totalSegmentCount)
                }

                var effectiveResumeSegment = self.resumeFromSegment
                if effectiveResumeSegment > 0,
                   self.expectedTotalSegments > 0,
                   segments.count != self.expectedTotalSegments {
                    Logger.shared.log("HLS: resume mismatch (playlist has \(segments.count) segments, expected \(self.expectedTotalSegments)); restarting from scratch", type: "Download")
                    effectiveResumeSegment = 0
                }

                let encryptionKey = self.parseEncryptionKey(from: mediaPlaylistContent, baseURL: mediaPlaylistURL)
                var keyData: Data? = nil
                if let encKey = encryptionKey, encKey.method == "AES-128" {
                    keyData = try await self.fetchDataWithRetry(
                        url: encKey.keyURL,
                        maximumResponseBytes: Self.maximumEncryptionKeyBytes
                    )
                    try self.checkCancelled()
                    Logger.shared.log("HLS: Downloaded AES-128 encryption key", type: "Download")
                }

                let initSegmentURL = self.parseInitSegment(from: mediaPlaylistContent, baseURL: mediaPlaylistURL)

                try self.checkCancelled()

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
                    let nsError = error as NSError
                    Logger.shared.log(
                        "HLS download failed domain=\(Self.safeErrorDomain(nsError.domain))"
                            + " code=\(nsError.code)",
                        type: "Download"
                    )
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

    private func beginBackgroundTask() {
        #if canImport(UIKit) && !os(watchOS)
        guard backgroundTaskId == .invalid else { return }
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "HLSDownload-\(downloadId)") { [weak self] in

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

    private static let maximumPlaylistBytes = 5 * 1024 * 1024
    private static let maximumEncryptionKeyBytes = 64 * 1024
    private static let maximumMediaObjectBytes = 128 * 1024 * 1024
    private static let minimumRequestStartInterval: TimeInterval = 0.15
    private static let maximumRetryAfterSeconds: TimeInterval = 30
    private static let minimumFreeCapacityReserve: Int64 = 512 * 1024 * 1024

    private func fetchPlaylist(url: URL) async throws -> String {
        let data = try await fetchDataWithRetry(
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
        try await waitForRequestStartSlot(for: url)

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
                let rejectedCookieHeader = effectiveHeaders.first {
                    $0.key.caseInsensitiveCompare("Cookie") == .orderedSame
                }?.value
                throw HLSError.cloudflareVerificationRequired(
                    url: httpResponse.url ?? url,
                    rejectedCookieHeader: rejectedCookieHeader
                )
            }
            if httpResponse.statusCode == 429 {
                throw HLSError.rateLimited(
                    retryAfterSeconds: Self.retryAfterSeconds(from: httpResponse)
                )
            }
            if !(200...299).contains(httpResponse.statusCode) {
                throw HLSError.httpError(statusCode: httpResponse.statusCode)
            }
            clearRateLimitState(for: url)
        }

        return data
    }

    private func fetchDataWithRetry(
        url: URL,
        maximumResponseBytes: Int = HLSDownloader.maximumMediaObjectBytes,
        maxRetries: Int = 3
    ) async throws -> Data {
        let attemptCount = max(maxRetries, 1)
        var lastError: Error = HLSError.unknownError

        for attempt in 0..<attemptCount {
            do {
                return try await fetchData(url: url, maximumResponseBytes: maximumResponseBytes)
            } catch {
                lastError = error
                if isCancellationError(error) { throw currentCancellationError() }

                if let hlsError = error as? HLSError {
                    switch hlsError {
                    case .cloudflareVerificationRequired:

                        throw hlsError
                    case .rateLimited(let retryAfterSeconds):
                        let delay = recordRateLimit(for: url, retryAfterSeconds: retryAfterSeconds)
                        if attempt < attemptCount - 1 {
                            Logger.shared.log(
                                "HLS: CDN rate limit host=\(url.host?.lowercased() ?? "unknown") retryIn=\(String(format: "%.1f", delay))s attempt=\(attempt + 1)/\(attemptCount)",
                                type: "Download"
                            )
                        }

                        continue
                    default:
                        break
                    }
                }

                if attempt < attemptCount - 1 {
                    let delay = min(pow(2.0, Double(attempt)), 8)
                    try await Task.sleep(nanoseconds: Self.nanoseconds(for: delay))
                    try checkCancelled()
                }
            }
        }

        throw lastError
    }

    private func waitForRequestStartSlot(for url: URL) async throws {
        let scheduledStart = reserveRequestStart(for: url)
        let delay = max(0, scheduledStart - ProcessInfo.processInfo.systemUptime)
        if delay > 0 {
            try await Task.sleep(nanoseconds: Self.nanoseconds(for: delay))
            try checkCancelled()
        }
    }

    private func reserveRequestStart(for url: URL) -> TimeInterval {
        let host = url.host?.lowercased() ?? "unknown"
        let now = ProcessInfo.processInfo.systemUptime
        transportStateLock.lock()
        defer { transportStateLock.unlock() }
        let scheduledStart = max(
            now,
            max(
                nextRequestStartByHost[host] ?? now,
                rateLimitedUntilByHost[host] ?? now
            )
        )
        nextRequestStartByHost[host] = scheduledStart + requestStartInterval
        return scheduledStart
    }

    private func recordRateLimit(for url: URL, retryAfterSeconds: TimeInterval?) -> TimeInterval {
        let host = url.host?.lowercased() ?? "unknown"
        let now = ProcessInfo.processInfo.systemUptime

        transportStateLock.lock()
        let count = min((rateLimitCountByHost[host] ?? 0) + 1, 4)
        rateLimitCountByHost[host] = count
        let exponentialDelay = pow(2.0, Double(count - 1))
        let finiteRetryAfter = retryAfterSeconds.flatMap { $0.isFinite ? $0 : nil }
        let serverDelay = min(max(finiteRetryAfter ?? 0, 0), Self.maximumRetryAfterSeconds)
        let delay = max(exponentialDelay, serverDelay)
        let limitedUntil = now + delay
        rateLimitedUntilByHost[host] = max(rateLimitedUntilByHost[host] ?? 0, limitedUntil)
        nextRequestStartByHost[host] = max(nextRequestStartByHost[host] ?? 0, limitedUntil)
        transportStateLock.unlock()

        return delay
    }

    private func clearRateLimitState(for url: URL) {
        let host = url.host?.lowercased() ?? "unknown"
        transportStateLock.lock()
        rateLimitedUntilByHost.removeValue(forKey: host)
        rateLimitCountByHost.removeValue(forKey: host)
        transportStateLock.unlock()
    }

    static func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let rawValue = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else { return nil }

        if let seconds = TimeInterval(rawValue), seconds.isFinite {
            return min(max(seconds, 0), maximumRetryAfterSeconds)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in [
            "EEE',' dd MMM yyyy HH':'mm':'ss z",
            "EEEE',' dd-MMM-yy HH':'mm':'ss z",
            "EEE MMM d HH':'mm':'ss yyyy"
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: rawValue) {
                let seconds = date.timeIntervalSinceNow
                guard seconds.isFinite else { return nil }
                return min(max(seconds, 0), maximumRetryAfterSeconds)
            }
        }
        return nil
    }

    static func nanoseconds(for seconds: TimeInterval) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let rounded = (seconds * 1_000_000_000).rounded(.up)
        guard rounded.isFinite else { return UInt64.max }
        guard rounded > 0 else { return 0 }
        return UInt64(exactly: rounded) ?? UInt64.max
    }

    private static func safeErrorDomain(_ value: String) -> String {
        let filtered = value.unicodeScalars.filter { scalar in
            scalar.isASCII && (
                CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "." || scalar == "-" || scalar == "_"
            )
        }
        let bounded = String(filtered.prefix(64))
        return bounded.isEmpty ? "network" : bounded
    }

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

        return variants.max(by: { $0.bandwidth < $1.bandwidth })
    }

    func parseMediaPlaylist(_ content: String, baseURL: URL) -> [URL] {
        var segments: [URL] = []
        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if let segmentURL = resolveURL(trimmed, baseURL: baseURL) {
                segments.append(segmentURL)
            }
        }

        return segments
    }

    private func parseEncryptionKey(from content: String, baseURL: URL) -> HLSEncryptionKey? {
        let lines = content.components(separatedBy: .newlines)

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

            if !completed && !preservePartial {
                try? FileManager.default.removeItem(at: partialURL)
            }
        }

        do {
            try ensureDiskCapacity()

            if !isResuming, let initURL = initSegmentURL {
                try checkSystemBackoff()
                try ensureDiskCapacity()
                let initData = try await fetchDataWithRetry(url: initURL)
                try checkCancelled()
                let decrypted = try decryptIfNeeded(data: initData, key: encryptionKey, keyData: keyData, segmentIndex: -1)
                try ensureDiskCapacity(additionalBytes: Int64(decrypted.count))
                fileHandle.write(decrypted)
            }

            let totalSegments = segments.count
            let startIndex = isResuming ? resumeFromSegment : 0

            for index in startIndex..<totalSegments {
                try checkCancelled()
                try checkSystemBackoff()
                try ensureDiskCapacity()

                let segmentData = try await fetchSegmentWithRetry(url: segments[index], maxRetries: 3)
                try checkCancelled()
                let decrypted = try decryptIfNeeded(data: segmentData, key: encryptionKey, keyData: keyData, segmentIndex: index)
                try ensureDiskCapacity(additionalBytes: Int64(decrypted.count))

                fileHandle.write(decrypted)

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
        try await fetchDataWithRetry(url: url, maxRetries: maxRetries)
    }

    private func decryptIfNeeded(data: Data, key: HLSEncryptionKey?, keyData: Data?, segmentIndex: Int) throws -> Data {
        guard let encKey = key, encKey.method == "AES-128", let keyBytes = keyData else {
            return data
        }

        let iv: Data
        if let explicitIV = encKey.iv {
            iv = explicitIV
        } else {

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

    private func parseAttribute(_ attributes: String, key: String) -> String? {

        let pattern = "\(key)=(?:\"([^\"]*)\"|([^,\\s]*))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }

        let range = NSRange(attributes.startIndex..., in: attributes)
        guard let match = regex.firstMatch(in: attributes, range: range) else { return nil }

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

        if urlString.lowercased().hasPrefix("http://") || urlString.lowercased().hasPrefix("https://") {
            return URL(string: urlString)
        }

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

    private func isResumableInterruption(_ error: Error) -> Bool {
        if let hlsError = error as? HLSError {
            switch hlsError {
            case .cancelled, .backgroundTimeExpired, .systemBackoff, .rateLimited:
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

    private func ensureDiskCapacity(additionalBytes: Int64 = 0) throws {
        guard enforcesConservativeDiskCapacityReserve else { return }
        let directory = destinationURL.deletingLastPathComponent()
        guard let values = try? directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]) else {
            throw HLSError.systemBackoff(reason: "Waiting for disk capacity check")
        }
        let available = values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map(Int64.init)
        guard let available,
              additionalBytes >= 0,
              available >= Self.minimumFreeCapacityReserve + additionalBytes else {
            throw HLSError.systemBackoff(reason: "Paused for low disk space")
        }
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

enum HLSError: LocalizedError {
    case noVariantsFound
    case noSegmentsFound
    case invalidPlaylistData
    case httpError(statusCode: Int)
    case rateLimited(retryAfterSeconds: TimeInterval?)
    case decryptionFailed(status: Int)
    case cloudflareVerificationRequired(url: URL, rejectedCookieHeader: String?)
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
        case .rateLimited(let retryAfterSeconds):
            if let retryAfterSeconds,
               retryAfterSeconds.isFinite,
               retryAfterSeconds >= 0,
               let displaySeconds = Int(exactly: ceil(retryAfterSeconds)) {
                return "HLS source rate limited requests (retry after \(displaySeconds) seconds)"
            }
            return "HLS source rate limited requests"
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
