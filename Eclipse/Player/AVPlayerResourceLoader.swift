import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// A public-API AVPlayer transport for streams that require HTTP headers.
///
/// AVFoundation doesn't expose arbitrary per-asset HTTP headers. This loader gives the asset a
/// private URL scheme, handles every resulting resource request through URLSession, and rewrites
/// HLS child URIs back through the same scheme. The delegate is intentionally retained alongside
/// the player item because `AVAssetResourceLoader.delegate` is weak.
final class AVPlayerResourceLoader: NSObject, @unchecked Sendable {
    struct BackedItem {
        let item: AVPlayerItem
        let loader: AVPlayerResourceLoader?
    }

    private static let httpScheme = "eclipse-av-http"
    private static let httpsScheme = "eclipse-av-https"
    private static let maximumManifestBytes = 8 * 1_024 * 1_024

    private final class LoadingContext {
        let loadingRequest: AVAssetResourceLoadingRequest
        let identifier: ObjectIdentifier
        let requestedOffset: Int64
        let requestedLength: Int64?
        var task: URLSessionDataTask?
        var finalURL: URL
        var responseBodyOffset: Int64 = 0
        var receivedBodyBytes: Int64 = 0
        var manifestData = Data()
        var isManifest = false
        let expectsManifest: Bool
        var requestedHTTPRange = false
        var retriedWithoutRange = false
        var redirectCount = 0

        init(
            loadingRequest: AVAssetResourceLoadingRequest,
            originalURL: URL,
            requestedOffset: Int64,
            requestedLength: Int64?
        ) {
            self.loadingRequest = loadingRequest
            identifier = ObjectIdentifier(loadingRequest)
            self.finalURL = originalURL
            self.requestedOffset = requestedOffset
            self.requestedLength = requestedLength
            expectsManifest = originalURL.pathExtension.lowercased() == "m3u8"
        }

        var requestedEndOffset: Int64? {
            guard let requestedLength else { return nil }
            let (end, overflow) = requestedOffset.addingReportingOverflow(requestedLength)
            return overflow ? Int64.max : end
        }
    }

    private let headers: [String: String]
    private let credentialOriginURL: URL
    private let workQueue = DispatchQueue(label: "app.eclipse.avplayer-resource-loader")
    private lazy var sessionDelegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.eclipse.avplayer-resource-loader.url-session"
        queue.maxConcurrentOperationCount = 1
        queue.underlyingQueue = workQueue
        return queue
    }()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 12 * 60 * 60
        configuration.waitsForConnectivity = true
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: configuration, delegate: self, delegateQueue: sessionDelegateQueue)
    }()
    private var contextsByRequest: [ObjectIdentifier: LoadingContext] = [:]
    private var contextsByTask: [Int: LoadingContext] = [:]
    private var isInvalidated = false

    init(headers: [String: String], credentialOriginURL: URL) {
        self.headers = Self.sanitizedHTTPHeaders(headers)
        self.credentialOriginURL = credentialOriginURL
        super.init()
    }

    deinit {
        session.invalidateAndCancel()
    }

    static func makeItem(url: URL, headers: [String: String]) -> BackedItem {
        let sanitizedHeaders = sanitizedHTTPHeaders(headers)
        guard !sanitizedHeaders.isEmpty,
              let proxiedURL = proxiedURL(for: url) else {
            return BackedItem(item: AVPlayerItem(asset: AVURLAsset(url: url)), loader: nil)
        }

        let loader = AVPlayerResourceLoader(headers: sanitizedHeaders, credentialOriginURL: url)
        let asset = AVURLAsset(url: proxiedURL)
        asset.resourceLoader.setDelegate(loader, queue: loader.workQueue)
        return BackedItem(item: AVPlayerItem(asset: asset), loader: loader)
    }

    func invalidate() {
        workQueue.async { [self] in
            guard !isInvalidated else { return }
            isInvalidated = true
            let contexts = Array(contextsByRequest.values)
            contextsByRequest.removeAll()
            contextsByTask.removeAll()
            contexts.forEach { context in
                context.task?.cancel()
                context.loadingRequest.finishLoading(with: URLError(.cancelled))
            }
            session.invalidateAndCancel()
        }
    }

    // MARK: - Pure request and manifest helpers

    static func sanitizedHTTPHeaders(_ headers: [String: String]) -> [String: String] {
        let managedOrHopByHopHeaders: Set<String> = [
            "accept-encoding", "connection", "content-length", "host", "keep-alive",
            "proxy-authenticate", "proxy-authorization", "proxy-connection", "range", "te",
            "trailer", "transfer-encoding", "upgrade"
        ]
        let validNameCharacters = CharacterSet(
            charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        )

        return headers.reduce(into: [:]) { result, pair in
            let name = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasValidName = !name.isEmpty && name.unicodeScalars.allSatisfy {
                $0.value < 128 && validNameCharacters.contains($0)
            }
            let hasValidValue = value.unicodeScalars.allSatisfy {
                $0.value == 9 || $0.value >= 32 && $0.value != 127
            }
            guard hasValidName,
                  !value.isEmpty,
                  name.utf8.count <= 128,
                  value.utf8.count <= 16 * 1_024,
                  hasValidValue,
                  !managedOrHopByHopHeaders.contains(name.lowercased()) else { return }
            result[name] = value
        }
    }

    static func proxiedURL(for originalURL: URL) -> URL? {
        guard var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "http": components.scheme = httpScheme
        case "https": components.scheme = httpsScheme
        default: return nil
        }
        return components.url
    }

    static func originalURL(for proxiedURL: URL) -> URL? {
        guard var components = URLComponents(url: proxiedURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case httpScheme: components.scheme = "http"
        case httpsScheme: components.scheme = "https"
        default: return nil
        }
        return components.url
    }

    /// URLSession normally strips credential headers on a cross-origin redirect. Because this
    /// loader reconstructs requests itself, enforce the same boundary for redirects and for HLS
    /// children hosted by a different origin. Domain-scoped cookies managed by URLSession still
    /// work; only caller-supplied credentials are withheld.
    static func httpHeaders(
        _ headers: [String: String],
        for destinationURL: URL,
        credentialOriginURL: URL
    ) -> [String: String] {
        let sanitized = sanitizedHTTPHeaders(headers)
        guard !sameOrigin(destinationURL, credentialOriginURL) else { return sanitized }
        let safeCrossOriginHeaders: Set<String> = [
            "accept", "accept-language", "cache-control", "pragma", "user-agent"
        ]
        return sanitized.reduce(into: [:]) { result, pair in
            switch pair.key.lowercased() {
            case let name where safeCrossOriginHeaders.contains(name):
                result[pair.key] = pair.value
            case "referer":
                if let safeReferer = sanitizedCrossOriginReferer(pair.value) {
                    result[pair.key] = safeReferer
                }
            case "origin":
                if let safeOrigin = sanitizedOrigin(pair.value) {
                    result[pair.key] = safeOrigin
                }
            default:
                // Unknown/custom headers are origin-bound by default. This
                // includes X-Api-Key, X-Auth-Token and provider-specific token
                // names that cannot be enumerated safely.
                break
            }
        }
    }

    private static func sanitizedCrossOriginReferer(_ value: String) -> String? {
        guard var components = URLComponents(string: value),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil,
              components.user == nil,
              components.password == nil else { return nil }
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString
    }

    private static func sanitizedOrigin(_ value: String) -> String? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              ["http", "https"].contains(scheme),
              url.user == nil,
              url.password == nil else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func origin(_ url: URL) -> (scheme: String, host: String, port: Int)? {
            guard let scheme = url.scheme?.lowercased(),
                  let host = url.host?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            let port = url.port ?? (scheme == "https" ? 443 : 80)
            return (scheme, host, port)
        }
        guard let lhsOrigin = origin(lhs), let rhsOrigin = origin(rhs) else { return false }
        return lhsOrigin == rhsOrigin
    }

    static func rewriteHLSManifest(_ manifest: String, relativeTo baseURL: URL) -> String {
        manifest
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { rawLine -> String in
                var line = String(rawLine)
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return line }
                if !trimmed.hasPrefix("#") {
                    guard let range = line.range(of: trimmed),
                          let rewritten = rewrittenManifestURI(trimmed, relativeTo: baseURL) else {
                        return line
                    }
                    line.replaceSubrange(range, with: rewritten)
                    return line
                }
                return rewriteURIAttributes(in: line, relativeTo: baseURL)
            }
            .joined(separator: "\n")
    }

    private static func rewriteURIAttributes(in line: String, relativeTo baseURL: URL) -> String {
        var result = line
        for pattern in [#"(?i)\bURI\s*=\s*\"([^\"]*)\""#, #"(?i)\bURI\s*=\s*'([^']*)'"#] {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = expression.matches(
                in: result,
                range: NSRange(result.startIndex..<result.endIndex, in: result)
            )
            for match in matches.reversed() where match.numberOfRanges > 1 {
                guard let valueRange = Range(match.range(at: 1), in: result) else { continue }
                let value = String(result[valueRange])
                guard let rewritten = rewrittenManifestURI(value, relativeTo: baseURL) else { continue }
                result.replaceSubrange(valueRange, with: rewritten)
            }
        }
        return result
    }

    private static func rewrittenManifestURI(_ value: String, relativeTo baseURL: URL) -> String? {
        guard !value.isEmpty, !value.contains("{$") else { return nil }
        if let alreadyProxied = URL(string: value), originalURL(for: alreadyProxied) != nil {
            return value
        }

        let resolvedURL: URL?
        let isRelativeReference: Bool
        if value.hasPrefix("//"), let scheme = baseURL.scheme {
            resolvedURL = URL(string: "\(scheme):\(value)")
            isRelativeReference = false
        } else {
            resolvedURL = URL(string: value, relativeTo: baseURL)?.absoluteURL
            isRelativeReference = URLComponents(string: value)?.scheme == nil
        }
        guard var resolvedURL else { return nil }

        // Signed HLS endpoints commonly put a token on the playlist URL and return bare relative
        // segment paths. Preserve that query only when the child did not provide one of its own.
        if isRelativeReference,
           URLComponents(string: value)?.percentEncodedQuery == nil,
           let baseQuery = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
           var resolvedComponents = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: false) {
            resolvedComponents.percentEncodedQuery = baseQuery
            if let updatedURL = resolvedComponents.url {
                resolvedURL = updatedURL
            }
        }

        guard let proxiedURL = proxiedURL(for: resolvedURL) else { return nil }
        return proxiedURL.absoluteString
    }

    // MARK: - Loading lifecycle

    private func beginLoading(_ loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard !isInvalidated,
              let proxiedURL = loadingRequest.request.url,
              let originalURL = Self.originalURL(for: proxiedURL) else { return false }

        let dataRequest = loadingRequest.dataRequest
        let requestedOffset = max(
            dataRequest.map { max($0.currentOffset, $0.requestedOffset) } ?? 0,
            0
        )
        let requestedLength: Int64?
        if let dataRequest, !dataRequest.requestsAllDataToEndOfResource {
            requestedLength = Int64(max(dataRequest.requestedLength, 0))
        } else {
            requestedLength = nil
        }

        let context = LoadingContext(
            loadingRequest: loadingRequest,
            originalURL: originalURL,
            requestedOffset: requestedOffset,
            requestedLength: requestedLength
        )
        contextsByRequest[context.identifier] = context
        startTask(for: context, includeRange: !context.expectsManifest)
        return true
    }

    private func startTask(for context: LoadingContext, includeRange: Bool) {
        guard !isInvalidated else {
            finish(context, error: URLError(.cancelled))
            return
        }
        var request = URLRequest(
            url: context.finalURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        request.httpMethod = "GET"
        Self.httpHeaders(
            headers,
            for: context.finalURL,
            credentialOriginURL: credentialOriginURL
        ).forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        context.requestedHTTPRange = includeRange && context.loadingRequest.dataRequest != nil
        if context.requestedHTTPRange {
            let rangeValue: String
            if let endOffset = context.requestedEndOffset, endOffset > context.requestedOffset {
                rangeValue = "bytes=\(context.requestedOffset)-\(endOffset - 1)"
            } else {
                rangeValue = "bytes=\(context.requestedOffset)-"
            }
            request.setValue(rangeValue, forHTTPHeaderField: "Range")
        }

        let task = session.dataTask(with: request)
        context.task = task
        contextsByTask[task.taskIdentifier] = context
        task.resume()
    }

    private func restartManifestRequestWithoutRange(_ context: LoadingContext, replacing task: URLSessionTask) {
        contextsByTask.removeValue(forKey: task.taskIdentifier)
        context.task = nil
        context.retriedWithoutRange = true
        context.receivedBodyBytes = 0
        context.responseBodyOffset = 0
        context.manifestData.removeAll(keepingCapacity: true)
        startTask(for: context, includeRange: false)
    }

    private func configureContentInformation(
        for context: LoadingContext,
        response: HTTPURLResponse,
        totalLength: Int64,
        isManifest: Bool
    ) {
        guard let information = context.loadingRequest.contentInformationRequest else { return }
        let mimeType = response.mimeType?.lowercased()
        let contentType: String?
        if isManifest {
            contentType = UTType(filenameExtension: "m3u8")?.identifier
        } else if let mimeType {
            contentType = UTType(mimeType: mimeType)?.identifier
        } else if let responseURL = response.url {
            contentType = UTType(filenameExtension: responseURL.pathExtension)?.identifier
        } else {
            contentType = nil
        }
        if let contentType,
           information.allowedContentTypes?.isEmpty != false || information.allowedContentTypes?.contains(contentType) == true {
            information.contentType = contentType
        }
        information.contentLength = max(totalLength, 0)
        let acceptsRanges = response.statusCode == 206
            || (response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") == true)
        information.isByteRangeAccessSupported = acceptsRanges || isManifest
    }

    private func respondWithDirectData(_ data: Data, for context: LoadingContext) {
        guard let dataRequest = context.loadingRequest.dataRequest else { return }
        let chunkStart = context.responseBodyOffset + context.receivedBodyBytes
        let chunkEnd = chunkStart + Int64(data.count)
        context.receivedBodyBytes += Int64(data.count)

        let wantedStart = max(context.requestedOffset, dataRequest.currentOffset)
        let wantedEnd = context.requestedEndOffset ?? Int64.max
        let responseStart = max(chunkStart, wantedStart)
        let responseEnd = min(chunkEnd, wantedEnd)
        guard responseStart < responseEnd else { return }

        let lowerBound = Int(responseStart - chunkStart)
        let upperBound = Int(responseEnd - chunkStart)
        dataRequest.respond(with: data.subdata(in: lowerBound..<upperBound))

        if let requestedEndOffset = context.requestedEndOffset,
           dataRequest.currentOffset >= requestedEndOffset {
            finish(context)
        }
    }

    private func finishManifest(_ context: LoadingContext) {
        guard let manifest = String(data: context.manifestData, encoding: .utf8) else {
            finish(context, error: LoaderError.invalidManifest)
            return
        }
        let rewritten = Self.rewriteHLSManifest(manifest, relativeTo: context.finalURL)
        let data = Data(rewritten.utf8)
        if let information = context.loadingRequest.contentInformationRequest {
            information.contentType = UTType(filenameExtension: "m3u8")?.identifier
            information.contentLength = Int64(data.count)
            information.isByteRangeAccessSupported = true
        }
        if let dataRequest = context.loadingRequest.dataRequest {
            let start = Int(min(max(dataRequest.currentOffset, 0), Int64(data.count)))
            let end: Int
            if dataRequest.requestsAllDataToEndOfResource {
                end = data.count
            } else {
                end = min(start + max(dataRequest.requestedLength, 0), data.count)
            }
            if start < end {
                dataRequest.respond(with: data.subdata(in: start..<end))
            }
        }
        finish(context)
    }

    private func finish(_ context: LoadingContext, error: Error? = nil) {
        guard contextsByRequest.removeValue(forKey: context.identifier) != nil else { return }
        if let task = context.task {
            contextsByTask.removeValue(forKey: task.taskIdentifier)
            context.task = nil
            task.cancel()
        }
        if let error {
            context.loadingRequest.finishLoading(with: error)
        } else {
            context.loadingRequest.finishLoading()
        }
    }

    private static func isManifest(response: HTTPURLResponse, url: URL) -> Bool {
        if url.pathExtension.lowercased() == "m3u8" { return true }
        switch response.mimeType?.lowercased() {
        case "application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl":
            return true
        default:
            return false
        }
    }

    private static func contentRange(_ response: HTTPURLResponse) -> (start: Int64, total: Int64?)? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range")?.lowercased(),
              value.hasPrefix("bytes ") else { return nil }
        let payload = value.dropFirst("bytes ".count)
        let components = payload.split(separator: "/", maxSplits: 1).map(String.init)
        guard components.count == 2 else { return nil }
        let total = components[1] == "*" ? nil : Int64(components[1])
        let range = components[0].split(separator: "-", maxSplits: 1).map(String.init)
        guard range.count == 2, let start = Int64(range[0]) else { return nil }
        return (start, total)
    }
}

extension AVPlayerResourceLoader: AVAssetResourceLoaderDelegate {
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        beginLoading(loadingRequest)
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let identifier = ObjectIdentifier(loadingRequest)
        guard let context = contextsByRequest.removeValue(forKey: identifier) else { return }
        if let task = context.task {
            contextsByTask.removeValue(forKey: task.taskIdentifier)
            task.cancel()
        }
    }
}

extension AVPlayerResourceLoader: URLSessionDataDelegate, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let context = contextsByTask[dataTask.taskIdentifier],
              let response = response as? HTTPURLResponse,
              let responseURL = response.url else {
            completionHandler(.cancel)
            return
        }
        guard (200...299).contains(response.statusCode) else {
            completionHandler(.cancel)
            finish(context, error: LoaderError.httpStatus(response.statusCode))
            return
        }

        context.finalURL = responseURL
        let isManifest = context.expectsManifest || Self.isManifest(response: response, url: responseURL)
        if isManifest, response.statusCode == 206, context.requestedHTTPRange, !context.retriedWithoutRange {
            completionHandler(.cancel)
            restartManifestRequestWithoutRange(context, replacing: dataTask)
            return
        }

        context.isManifest = isManifest
        let contentRange = Self.contentRange(response)
        context.responseBodyOffset = contentRange?.start
            ?? (response.statusCode == 206 ? context.requestedOffset : 0)
        let expectedLength = max(response.expectedContentLength, 0)
        let totalLength = contentRange?.total
            ?? (response.statusCode == 206 ? context.responseBodyOffset + expectedLength : expectedLength)
        configureContentInformation(
            for: context,
            response: response,
            totalLength: totalLength,
            isManifest: isManifest
        )
        if context.loadingRequest.dataRequest == nil, !isManifest {
            completionHandler(.cancel)
            finish(context)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let context = contextsByTask[dataTask.taskIdentifier] else { return }
        if context.isManifest {
            guard context.manifestData.count + data.count <= Self.maximumManifestBytes else {
                finish(context, error: LoaderError.manifestTooLarge)
                return
            }
            context.manifestData.append(data)
        } else {
            respondWithDirectData(data, for: context)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let context = contextsByTask[task.taskIdentifier],
              let redirectURL = request.url,
              ["http", "https"].contains(redirectURL.scheme?.lowercased() ?? ""),
              context.redirectCount < 10 else {
            completionHandler(nil)
            if let context = contextsByTask[task.taskIdentifier] {
                finish(context, error: LoaderError.invalidRedirect)
            }
            return
        }

        context.redirectCount += 1
        context.finalURL = redirectURL
        var redirectedRequest = URLRequest(
            url: redirectURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        redirectedRequest.httpMethod = "GET"
        Self.httpHeaders(
            headers,
            for: redirectURL,
            credentialOriginURL: credentialOriginURL
        ).forEach { redirectedRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
        redirectedRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if context.requestedHTTPRange {
            let rangeValue: String
            if let endOffset = context.requestedEndOffset, endOffset > context.requestedOffset {
                rangeValue = "bytes=\(context.requestedOffset)-\(endOffset - 1)"
            } else {
                rangeValue = "bytes=\(context.requestedOffset)-"
            }
            redirectedRequest.setValue(rangeValue, forHTTPHeaderField: "Range")
        } else {
            redirectedRequest.setValue(nil, forHTTPHeaderField: "Range")
        }
        completionHandler(redirectedRequest)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let context = contextsByTask[task.taskIdentifier] else { return }
        if let error {
            finish(context, error: error)
        } else if context.isManifest {
            finishManifest(context)
        } else {
            finish(context)
        }
    }
}

private enum LoaderError: LocalizedError {
    case httpStatus(Int)
    case invalidManifest
    case manifestTooLarge
    case invalidRedirect

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status): return "The media server returned HTTP \(status)."
        case .invalidManifest: return "The HLS playlist is not valid UTF-8."
        case .manifestTooLarge: return "The HLS playlist exceeded the safe response limit."
        case .invalidRedirect: return "The media server returned an unsafe or excessive redirect."
        }
    }
}
