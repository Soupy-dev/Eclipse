//
//  VLCHeaderProxy.swift
//  Luna
//
//  Local loopback proxy to inject headers for VLC playback.
//

import Foundation
import Network

#if !os(tvOS)
final class VLCHeaderProxy {
    static let shared = VLCHeaderProxy()

    private struct Session {
        let headers: [String: String]
        let createdAt: Date
        let lastAccessed: Date
    }

    private enum UpstreamBodyMode {
        case stream
        case playlist
        case probe

        var logName: String {
            switch self {
            case .stream: return "stream"
            case .playlist: return "playlist"
            case .probe: return "probe"
            }
        }
    }

    private let queue = DispatchQueue(label: "vlc.header.proxy")
    private var listener: NWListener?
    private var port: UInt16?
    private let token = UUID().uuidString
    private var sessions: [String: Session] = [:]
    private let sessionLock = NSLock()
    private let requestStatsLock = NSLock()
    private var activeRequestCount = 0
    private var completedRequestCount = 0
    private var lastRequestSummary = "none"

    private let maxSessions = 200
    private let sessionTTL: TimeInterval = 6 * 60 * 60
    private let maxHeaderBytes = 64 * 1024
    private let maxPlaylistBytes = 5 * 1024 * 1024
    private let playlistProbeBytes = 4 * 1024
    private let hopByHopRequestHeaders: Set<String> = [
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "proxy-connection",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade"
    ]

    private init() {}

    private func withSessionsLock<T>(_ body: () -> T) -> T {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return body()
    }

    private func sessionCount() -> Int {
        withSessionsLock { sessions.count }
    }

    private func beginRequest(id: String, kind: String, targetURL: URL) -> Int {
        requestStatsLock.lock()
        defer { requestStatsLock.unlock() }
        activeRequestCount += 1
        lastRequestSummary = "start id=\(id) kind=\(kind) target=\(logURLSummary(targetURL))"
        return activeRequestCount
    }

    private func finishRequest(id: String, kind: String, targetURL: URL) -> Int {
        requestStatsLock.lock()
        defer { requestStatsLock.unlock() }
        activeRequestCount = max(0, activeRequestCount - 1)
        completedRequestCount += 1
        lastRequestSummary = "finish id=\(id) kind=\(kind) target=\(logURLSummary(targetURL))"
        return activeRequestCount
    }

    private func activeRequestCountSnapshot() -> Int {
        requestStatsLock.lock()
        defer { requestStatsLock.unlock() }
        return activeRequestCount
    }

    func diagnosticsSnapshot() -> String {
        requestStatsLock.lock()
        let active = activeRequestCount
        let completed = completedRequestCount
        let last = lastRequestSummary
        requestStatsLock.unlock()

        let portText = port.map { String($0) } ?? "nil"
        return "listener=\(listener != nil) port=\(portText) sessions=\(sessionCount()) activeRequests=\(active) completedRequests=\(completed) lastRequest={\(last)}"
    }

    private func logURLSummary(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return components?.string ?? "\(url.scheme ?? "unknown")://\(url.host ?? "unknown")\(url.path)"
    }

    private func requestKind(for url: URL, contentType: String? = nil) -> String {
        let ext = url.pathExtension.lowercased()
        let lowerContentType = contentType?.lowercased() ?? ""
        if ext == "m3u8" || ext == "m3u" || lowerContentType.contains("mpegurl") {
            return "playlist"
        }
        if ["ts", "m4s", "mp4", "m4v", "aac", "mp3", "webm", "mkv"].contains(ext) {
            return "media-\(ext)"
        }
        if ["jpg", "jpeg", "png", "webp"].contains(ext) {
            return "media-image-\(ext)"
        }
        if ["vtt", "srt", "ass", "ssa"].contains(ext) {
            return "subtitle-\(ext)"
        }
        if ext == "key" || lowerContentType.contains("octet-stream") {
            return "key-or-binary"
        }
        return ext.isEmpty ? "unknown" : "other-\(ext)"
    }

    private func elapsedMilliseconds(since start: CFTimeInterval) -> String {
        String(format: "%.0f", max(0, (CFAbsoluteTimeGetCurrent() - start) * 1000.0))
    }

    private func setSession(_ session: Session, for id: String) {
        _ = withSessionsLock {
            sessions[id] = session
        }
    }

    private func touchSession(for id: String) -> Session? {
        withSessionsLock {
            guard let session = sessions[id] else { return nil }
            let updated = Session(headers: session.headers, createdAt: session.createdAt, lastAccessed: Date())
            sessions[id] = updated
            return updated
        }
    }

    func refreshedProxyURL(from proxyURL: URL, restartListener: Bool, reason: String) -> URL? {
        guard let components = URLComponents(url: proxyURL, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost" || host == "::1" else {
            return nil
        }

        let pathParts = components.path.split(separator: "/")
        guard pathParts.count >= 2, pathParts[0] == "proxy" else {
            return nil
        }

        let sessionId = String(pathParts[1])
        let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard queryItems["token"] == token,
              let encoded = queryItems["url"],
              let targetURL = decodeTargetURL(encoded),
              let session = touchSession(for: sessionId) else {
            Logger.shared.log("VLCHeaderProxy: could not refresh stale proxy URL reason=\(reason) session=\(String(sessionId.prefix(8)))", type: "Error")
            return nil
        }

        return makeProxyURL(
            for: targetURL,
            headers: session.headers,
            restartListener: restartListener,
            reason: reason
        )
    }

    func makeProxyURL(
        for targetURL: URL,
        headers: [String: String],
        restartListener: Bool = false,
        reason: String = "new-session"
    ) -> URL? {
        if restartListener {
            restartListenerForRecovery(reason: reason)
        }

        guard ensureStarted() else { return nil }

        var activePort = port
        if (activePort ?? 0) == 0 {
            activePort = waitForPort(timeout: 0.25)
        }

        guard let activePort, activePort > 0 else {
            Logger.shared.log("VLCHeaderProxy: listener port unavailable", type: "Error")
            return nil
        }

        cleanupExpiredSessions()

        let activeSessionCount = sessionCount()

        if activeSessionCount >= maxSessions {
            cleanupOldestSessions()
        }

        let sessionId = UUID().uuidString
        let now = Date()
        setSession(Session(headers: headers, createdAt: now, lastAccessed: now), for: sessionId)
        Logger.shared.log("VLCHeaderProxy: created session=\(String(sessionId.prefix(8))) target=\(logURLSummary(targetURL)) headerKeys=[\(headers.keys.sorted().joined(separator: ","))] activeSessions=\(sessionCount())", type: "Stream")

        return buildProxyURL(port: activePort, sessionId: sessionId, targetURL: targetURL)
    }

    private func ensureStarted() -> Bool {
        if listener != nil { return true }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port.any)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                guard self.listener === listener else { return }
                switch state {
                case .ready:
                    let readyPort = listener.port?.rawValue ?? 0
                    if readyPort > 0 {
                        self.port = readyPort
                    } else {
                        Logger.shared.log("VLCHeaderProxy: listener ready without a valid port", type: "Error")
                    }
                case .failed(let error):
                    Logger.shared.log("VLCHeaderProxy: listener failed: \(error)", type: "Error")
                    self.listener = nil
                    self.port = nil
                case .cancelled:
                    Logger.shared.log("VLCHeaderProxy: listener cancelled", type: "Stream")
                    self.listener = nil
                    self.port = nil
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
            let initialPort = listener.port?.rawValue ?? 0
            if initialPort > 0 {
                self.port = initialPort
                Logger.shared.log("VLCHeaderProxy: started on 127.0.0.1:\(initialPort)", type: "Info")
            } else {
                Logger.shared.log("VLCHeaderProxy: started; awaiting port assignment", type: "Info")
            }
            return true
        } catch {
            Logger.shared.log("VLCHeaderProxy: failed to start listener: \(error)", type: "Error")
            return false
        }
    }

    private func restartListenerForRecovery(reason: String) {
        guard let listener else { return }
        let oldPort = port.map { String($0) } ?? "nil"
        Logger.shared.log("VLCHeaderProxy: restarting listener for recovery reason=\(reason) oldPort=\(oldPort)", type: "Stream")
        listener.cancel()
        self.listener = nil
        self.port = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                Logger.shared.log("VLCHeaderProxy: connection failed: \(error)", type: "Error")
            }
        }
        connection.start(queue: queue)
        receiveHeaders(on: connection, buffer: Data())
    }

    private func receiveHeaders(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                Logger.shared.log("VLCHeaderProxy: receive error: \(error)", type: "Error")
                connection.cancel()
                return
            }

            var combined = buffer
            if let data { combined.append(data) }

            if combined.count > self.maxHeaderBytes {
                self.sendSimpleResponse(connection, statusCode: 431, body: "Request headers too large")
                return
            }

            if let range = combined.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = combined.subdata(in: 0..<range.lowerBound)
                let requestBody = combined.subdata(in: range.upperBound..<combined.count)
                Task { [weak self] in
                    await self?.processRequest(headerData: headerData, body: requestBody, connection: connection)
                }
                return
            }

            if isComplete {
                self.sendSimpleResponse(connection, statusCode: 400, body: "Invalid request")
                return
            }

            self.receiveHeaders(on: connection, buffer: combined)
        }
    }

    private func processRequest(headerData: Data, body: Data, connection: NWConnection) async {
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            sendSimpleResponse(connection, statusCode: 400, body: "Invalid request")
            return
        }

        let lines = headerText.split(separator: "\r\n")
        guard let requestLine = lines.first else {
            sendSimpleResponse(connection, statusCode: 400, body: "Invalid request")
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendSimpleResponse(connection, statusCode: 400, body: "Invalid request")
            return
        }

        let method = String(parts[0]).uppercased()
        let rawPath = String(parts[1])

        if method != "GET" && method != "HEAD" {
            sendSimpleResponse(connection, statusCode: 405, body: "Method not allowed")
            return
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let idx = line.firstIndex(of: ":") {
                let key = line[..<idx].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        guard let urlComponents = URLComponents(string: "http://127.0.0.1" + rawPath) else {
            sendSimpleResponse(connection, statusCode: 400, body: "Invalid URL")
            return
        }

        let pathParts = urlComponents.path.split(separator: "/")
        guard pathParts.count >= 2, pathParts[0] == "proxy" else {
            sendSimpleResponse(connection, statusCode: 404, body: "Not found")
            return
        }

        let sessionId = String(pathParts[1])
        let queryItems = Dictionary(uniqueKeysWithValues: (urlComponents.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        guard queryItems["token"] == token else {
            sendSimpleResponse(connection, statusCode: 403, body: "Forbidden")
            return
        }

        let session = touchSession(for: sessionId)

        guard let session = session else {
            sendSimpleResponse(connection, statusCode: 404, body: "Session not found")
            return
        }

        guard let encoded = queryItems["url"], let targetURL = decodeTargetURL(encoded) else {
            sendSimpleResponse(connection, statusCode: 400, body: "Invalid target")
            return
        }

        guard let targetScheme = targetURL.scheme?.lowercased(),
              targetScheme == "http" || targetScheme == "https" else {
            sendSimpleResponse(connection, statusCode: 400, body: "Unsupported scheme")
            return
        }

        let requestId = String(UUID().uuidString.prefix(8))
        let incomingRange = headers.first { $0.key.caseInsensitiveCompare("Range") == .orderedSame }?.value ?? "nil"
        let kind = requestKind(for: targetURL)
        let activeRequests = beginRequest(id: requestId, kind: kind, targetURL: targetURL)
        defer { _ = finishRequest(id: requestId, kind: kind, targetURL: targetURL) }
        Logger.shared.log("VLCHeaderProxy[\(requestId)]: request method=\(method) kind=\(kind) activeRequests=\(activeRequests) target=\(logURLSummary(targetURL)) incomingRange=\(incomingRange) incomingHeaderKeys=[\(headers.keys.sorted().joined(separator: ","))] sessionHeaderKeys=[\(session.headers.keys.sorted().joined(separator: ","))]", type: "VLCProxy")

        var request = URLRequest(url: targetURL)
        request.httpMethod = method

        for (key, value) in headers {
            let lower = key.lowercased()
            if lower == "host" || hopByHopRequestHeaders.contains(lower) {
                continue
            }
            request.setValue(value, forHTTPHeaderField: key)
        }

        for (key, value) in session.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let upstreamRange = request.value(forHTTPHeaderField: "Range") ?? "nil"
        Logger.shared.log("VLCHeaderProxy[\(requestId)]: upstream start kind=\(kind) activeRequests=\(activeRequestCountSnapshot()) range=\(upstreamRange) target=\(logURLSummary(targetURL))", type: "VLCProxy")
        let bridge = UpstreamBridge(
            proxy: self,
            request: request,
            requestId: requestId,
            method: method,
            targetURL: targetURL,
            sessionId: sessionId,
            connection: connection
        )
        await bridge.start()
    }

    private func upstreamBodyMode(for http: HTTPURLResponse, targetURL: URL) -> UpstreamBodyMode {
        if isPlaylistMetadata(http: http, targetURL: targetURL) {
            return .playlist
        }

        if isDefinitelyMediaResponse(http: http, targetURL: targetURL) {
            return .stream
        }

        let expected = http.expectedContentLength
        if expected >= 0 && expected <= Int64(maxPlaylistBytes) {
            return .probe
        }

        return .stream
    }

    private func isDefinitelyMediaResponse(http: HTTPURLResponse, targetURL: URL) -> Bool {
        let ext = targetURL.pathExtension.lowercased()
        if ["ts", "m4s", "mp4", "m4v", "aac", "mp3", "webm", "mkv", "jpg", "jpeg", "png", "webp"].contains(ext) {
            return true
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.hasPrefix("video/")
            || contentType.hasPrefix("audio/")
            || contentType.hasPrefix("image/")
            || contentType.contains("octet-stream") {
            return true
        }

        return false
    }

    private func isPlaylistMetadata(http: HTTPURLResponse, targetURL: URL) -> Bool {
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let lowerContentType = contentType.lowercased()
        if lowerContentType.contains("application/vnd.apple.mpegurl")
            || lowerContentType.contains("application/x-mpegurl")
            || lowerContentType.contains("audio/mpegurl")
            || lowerContentType.contains("vnd.apple.mpegurl") {
            return true
        }

        let ext = targetURL.pathExtension.lowercased()
        return ext == "m3u8" || ext == "m3u"
    }

    private func isPlaylistData(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return trimmedPlaylistProbeText(text).hasPrefix("#EXTM3U")
    }

    private func shouldStopPlaylistProbe(_ data: Data) -> Bool {
        if data.count >= playlistProbeBytes {
            return true
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return data.count >= 16
        }

        let trimmed = trimmedPlaylistProbeText(text)
        if trimmed.isEmpty {
            return false
        }

        if "#EXTM3U".hasPrefix(trimmed) {
            return false
        }

        return !trimmed.hasPrefix("#EXTM3U")
    }

    private func trimmedPlaylistProbeText(_ text: String) -> String {
        let characters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}"))
        return text.trimmingCharacters(in: characters)
    }

    private func rewrittenPlaylistResponse(
        http: HTTPURLResponse,
        data: Data,
        targetURL: URL,
        sessionId: String
    ) -> (Data, [String: String], Bool) {
        var headers: [String: String] = filteredResponseHeaders(from: http)

        if let text = String(data: data, encoding: .utf8), isPlaylistData(data) || isPlaylistMetadata(http: http, targetURL: targetURL) {
            let rewritten = rewritePlaylist(text: text, baseURL: targetURL, sessionId: sessionId)
            let outData = Data(rewritten.utf8)
            setHeader("Content-Type", value: "application/vnd.apple.mpegurl", in: &headers)
            setHeader("Content-Length", value: String(outData.count), in: &headers)
            removeHeader("Content-Encoding", from: &headers)
            return (outData, headers, true)
        }

        setHeader("Content-Length", value: String(data.count), in: &headers)
        removeHeader("Content-Encoding", from: &headers)
        return (data, headers, false)
    }

    private func rewritePlaylist(text: String, baseURL: URL, sessionId: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let base = baseURL.deletingLastPathComponent()
        var mediaLineRewriteCount = 0
        var attributeRewriteCount = 0

        let rewritten = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return line
            }

            if trimmed.hasPrefix("#") {
                return rewritePlaylistTagLine(line, baseURL: base, sessionId: sessionId, rewrittenCount: &attributeRewriteCount)
            }

            if let proxied = proxiedPlaylistURLString(for: trimmed, baseURL: base, sessionId: sessionId) {
                mediaLineRewriteCount += 1
                return proxied.absoluteString
            }

            return line
        }

        Logger.shared.log("VLCHeaderProxy: playlist rewrite target=\(logURLSummary(baseURL)) lines=\(lines.count) mediaLines=\(mediaLineRewriteCount) attributes=\(attributeRewriteCount) session=\(String(sessionId.prefix(8)))", type: "VLCProxy")
        return rewritten.joined(separator: "\n")
    }

    private func rewritePlaylistTagLine(_ line: String, baseURL: URL, sessionId: String, rewrittenCount: inout Int) -> String {
        var output = line
        rewriteQuotedURIAttributes(in: &output, baseURL: baseURL, sessionId: sessionId, rewrittenCount: &rewrittenCount)
        rewriteUnquotedURIAttributes(in: &output, baseURL: baseURL, sessionId: sessionId, rewrittenCount: &rewrittenCount)
        return output
    }

    private func rewriteQuotedURIAttributes(in line: inout String, baseURL: URL, sessionId: String, rewrittenCount: inout Int) {
        var searchStart = line.startIndex
        while let keyRange = line.range(of: "URI=\"", options: [.caseInsensitive], range: searchStart..<line.endIndex) {
            let valueStart = keyRange.upperBound
            guard let valueEnd = line[valueStart...].firstIndex(of: "\"") else {
                break
            }

            let original = String(line[valueStart..<valueEnd])
            guard let proxied = proxiedPlaylistURLString(for: original, baseURL: baseURL, sessionId: sessionId) else {
                searchStart = valueEnd
                continue
            }

            line.replaceSubrange(valueStart..<valueEnd, with: proxied.absoluteString)
            rewrittenCount += 1
            searchStart = line.index(valueStart, offsetBy: proxied.absoluteString.count)
        }
    }

    private func rewriteUnquotedURIAttributes(in line: inout String, baseURL: URL, sessionId: String, rewrittenCount: inout Int) {
        var searchStart = line.startIndex
        while let keyRange = line.range(of: "URI=", options: [.caseInsensitive], range: searchStart..<line.endIndex) {
            let valueStart = keyRange.upperBound
            if valueStart < line.endIndex, line[valueStart] == "\"" {
                searchStart = line.index(after: valueStart)
                continue
            }

            let valueEnd = line[valueStart...].firstIndex(of: ",") ?? line.endIndex
            let original = String(line[valueStart..<valueEnd]).trimmingCharacters(in: .whitespaces)
            guard !original.isEmpty,
                  let proxied = proxiedPlaylistURLString(for: original, baseURL: baseURL, sessionId: sessionId) else {
                searchStart = valueEnd
                continue
            }

            line.replaceSubrange(valueStart..<valueEnd, with: proxied.absoluteString)
            rewrittenCount += 1
            searchStart = line.index(valueStart, offsetBy: proxied.absoluteString.count)
        }
    }

    private func proxiedPlaylistURLString(for reference: String, baseURL: URL, sessionId: String) -> URL? {
        guard let resolved = URL(string: reference, relativeTo: baseURL)?.absoluteURL,
              let scheme = resolved.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        return buildProxyURL(port: port, sessionId: sessionId, targetURL: resolved)
    }

    private func filteredResponseHeaders(from http: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let key = key as? String else { continue }
            let lower = key.lowercased()
            if lower == "connection" || lower == "transfer-encoding" || lower == "proxy-connection" || lower == "keep-alive" {
                continue
            }
            headers[key] = "\(value)"
        }
        return headers
    }

    private func removeHeader(_ name: String, from headers: inout [String: String]) {
        guard let key = headers.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            return
        }
        headers.removeValue(forKey: key)
    }

    private func setHeader(_ name: String, value: String, in headers: inout [String: String]) {
        removeHeader(name, from: &headers)
        headers[name] = value
    }

    private func sendSimpleResponse(_ connection: NWConnection, statusCode: Int, body: String) {
        let data = Data(body.utf8)
        let headers = [
            "Content-Type": "text/plain; charset=utf-8",
            "Content-Length": String(data.count)
        ]
        sendResponse(connection, statusCode: statusCode, headers: headers, body: data)
    }

    private func sendResponse(_ connection: NWConnection, statusCode: Int, headers: [String: String], body: Data) {
        let headerData = responseHeaderData(statusCode: statusCode, headers: headers)
        let responseData = headerData + body

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendResponseHeaders(_ connection: NWConnection, statusCode: Int, headers: [String: String], completion: @escaping (NWError?) -> Void) {
        sendData(responseHeaderData(statusCode: statusCode, headers: headers), on: connection, completion: completion)
    }

    private func sendData(_ data: Data, on connection: NWConnection, completion: @escaping (NWError?) -> Void) {
        guard !data.isEmpty else {
            completion(nil)
            return
        }
        connection.send(content: data, completion: .contentProcessed(completion))
    }

    private func responseHeaderData(statusCode: Int, headers: [String: String]) -> Data {
        var lines: [String] = []
        let statusText = httpStatusText(statusCode)
        lines.append("HTTP/1.1 \(statusCode) \(statusText)")
        lines.append("Connection: close")

        for (key, value) in headers {
            lines.append("\(key): \(value)")
        }

        lines.append("")
        lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private func httpStatusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 416: return "Range Not Satisfiable"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "OK"
        }
    }

    private func buildProxyURL(port: UInt16?, sessionId: String, targetURL: URL) -> URL? {
        guard let port, port > 0 else { return nil }
        let encoded = encodeTargetURL(targetURL)
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/proxy/\(sessionId)"
        components.queryItems = [
            URLQueryItem(name: "url", value: encoded),
            URLQueryItem(name: "token", value: token)
        ]
        return components.url
    }

    private func encodeTargetURL(_ url: URL) -> String {
        let data = Data(url.absoluteString.utf8)
        let base64 = data.base64EncodedString()
        return base64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func decodeTargetURL(_ encoded: String) -> URL? {
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padding = 4 - (base64.count % 4)
        if padding < 4 {
            base64 += String(repeating: "=", count: padding)
        }

        guard let data = Data(base64Encoded: base64) else { return nil }
        guard let string = String(data: data, encoding: .utf8) else { return nil }
        return URL(string: string)
    }

    private func waitForPort(timeout: TimeInterval) -> UInt16? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let readyPort = listener?.port?.rawValue, readyPort > 0 {
                port = readyPort
                return readyPort
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    private func cleanupExpiredSessions() {
        let now = Date()
        _ = withSessionsLock {
            sessions = sessions.filter { now.timeIntervalSince($0.value.lastAccessed) < sessionTTL }
        }
    }

    private func cleanupOldestSessions() {
        _ = withSessionsLock {
            let sorted = sessions.sorted { $0.value.lastAccessed < $1.value.lastAccessed }
            let removeCount = max(0, sessions.count - maxSessions + 1)
            if removeCount == 0 {
                return
            }

            for idx in 0..<removeCount {
                sessions.removeValue(forKey: sorted[idx].key)
            }
        }
    }

    private final class UpstreamBridge: NSObject, URLSessionDataDelegate {
        private weak var proxy: VLCHeaderProxy?
        private let request: URLRequest
        private let requestId: String
        private let method: String
        private let targetURL: URL
        private let sessionId: String
        private let connection: NWConnection
        private let callbackQueue: OperationQueue

        private var urlSession: URLSession?
        private var task: URLSessionDataTask?
        private var continuation: CheckedContinuation<Void, Never>?
        private var httpResponse: HTTPURLResponse?
        private var mode: UpstreamBodyMode = .stream
        private var bufferedData = Data()
        private var responseHeadersSent = false
        private var finished = false
        private let finishLock = NSLock()
        private let startedAt = CFAbsoluteTimeGetCurrent()
        private var responseAt: CFTimeInterval?
        private var firstDataAt: CFTimeInterval?
        private var upstreamBytes = 0
        private var downstreamBytes = 0
        private var lastSlowSendLogAt: CFTimeInterval = 0

        init(
            proxy: VLCHeaderProxy,
            request: URLRequest,
            requestId: String,
            method: String,
            targetURL: URL,
            sessionId: String,
            connection: NWConnection
        ) {
            self.proxy = proxy
            self.request = request
            self.requestId = requestId
            self.method = method
            self.targetURL = targetURL
            self.sessionId = sessionId
            self.connection = connection
            let callbackQueue = OperationQueue()
            callbackQueue.maxConcurrentOperationCount = 1
            callbackQueue.qualityOfService = .userInitiated
            self.callbackQueue = callbackQueue
            super.init()
        }

        func start() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation

                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpShouldSetCookies = false
                configuration.httpCookieAcceptPolicy = .never
                configuration.httpCookieStorage = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = 30
                configuration.timeoutIntervalForResource = 6 * 60 * 60

                let urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: callbackQueue)
                self.urlSession = urlSession
                let task = urlSession.dataTask(with: request)
                self.task = task
                task.resume()
            }
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let proxy else {
                completionHandler(.cancel)
                finish()
                return
            }

            guard let http = response as? HTTPURLResponse else {
                Logger.shared.log("VLCHeaderProxy[\(requestId)]: upstream response was not HTTP target=\(proxy.logURLSummary(targetURL))", type: "Error")
                proxy.sendSimpleResponse(connection, statusCode: 502, body: "Bad gateway")
                completionHandler(.cancel)
                finish()
                return
            }

            httpResponse = http
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "nil"
            let contentLength = http.value(forHTTPHeaderField: "Content-Length") ?? "nil"
            let contentRange = http.value(forHTTPHeaderField: "Content-Range") ?? "nil"
            responseAt = CFAbsoluteTimeGetCurrent()
            mode = proxy.upstreamBodyMode(for: http, targetURL: targetURL)
            let kind = proxy.requestKind(for: targetURL, contentType: contentType)
            Logger.shared.log("VLCHeaderProxy[\(requestId)]: upstream response status=\(http.statusCode) kind=\(kind) mode=\(mode.logName) activeRequests=\(proxy.activeRequestCountSnapshot()) headerMs=\(proxy.elapsedMilliseconds(since: startedAt)) target=\(proxy.logURLSummary(targetURL)) contentLength=\(contentLength) contentRange=\(contentRange) contentType=\(contentType)", type: "VLCProxy")

            let responseHeaders = proxy.filteredResponseHeaders(from: http)
            if method == "HEAD" {
                proxy.sendResponse(connection, statusCode: http.statusCode, headers: responseHeaders, body: Data())
                completionHandler(.cancel)
                finish()
                return
            }

            switch mode {
            case .playlist, .probe:
                completionHandler(.allow)
            case .stream:
                proxy.sendResponseHeaders(connection, statusCode: http.statusCode, headers: responseHeaders) { [weak self] error in
                    guard let self else { return }
                    if let error {
                        Logger.shared.log("VLCHeaderProxy[\(self.requestId)]: failed to send response headers: \(error)", type: "Error")
                        completionHandler(.cancel)
                        self.finish()
                        return
                    }

                    self.responseHeadersSent = true
                    completionHandler(.allow)
                }
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard let proxy, !isFinished else { return }
            guard method != "HEAD" else { return }
            upstreamBytes += data.count
            if firstDataAt == nil {
                firstDataAt = CFAbsoluteTimeGetCurrent()
                let firstByteMs = proxy.elapsedMilliseconds(since: startedAt)
                if (Double(firstByteMs) ?? 0) > 750 || proxy.requestKind(for: targetURL).contains("playlist") {
                    Logger.shared.log("VLCHeaderProxy[\(requestId)]: first upstream bytes kind=\(proxy.requestKind(for: targetURL)) firstByteMs=\(firstByteMs) bytes=\(data.count) target=\(proxy.logURLSummary(targetURL))", type: "VLCProxy")
                }
            }

            switch mode {
            case .playlist:
                bufferedData.append(data)
                if bufferedData.count > proxy.maxPlaylistBytes {
                    Logger.shared.log("VLCHeaderProxy[\(requestId)]: playlist exceeded rewrite limit; streaming original target=\(proxy.logURLSummary(targetURL)) bytes=\(bufferedData.count)", type: "Error")
                    startStreamingBufferedData(dataTask: dataTask)
                }
            case .probe:
                bufferedData.append(data)
                if proxy.isPlaylistData(bufferedData) {
                    mode = .playlist
                    if bufferedData.count > proxy.maxPlaylistBytes {
                        Logger.shared.log("VLCHeaderProxy[\(requestId)]: playlist exceeded rewrite limit during probe; streaming original target=\(proxy.logURLSummary(targetURL)) bytes=\(bufferedData.count)", type: "Error")
                        startStreamingBufferedData(dataTask: dataTask)
                    }
                } else if proxy.shouldStopPlaylistProbe(bufferedData) {
                    startStreamingBufferedData(dataTask: dataTask)
                }
            case .stream:
                streamChunk(data, dataTask: dataTask)
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            var redirected = request
            redirected.httpMethod = self.request.httpMethod
            for (key, value) in self.request.allHTTPHeaderFields ?? [:] {
                redirected.setValue(value, forHTTPHeaderField: key)
            }
            let redirectTarget = redirected.url.flatMap { proxy?.logURLSummary($0) } ?? "nil"
            Logger.shared.log("VLCHeaderProxy[\(requestId)]: following redirect status=\(response.statusCode) target=\(redirectTarget)", type: "Stream")
            completionHandler(redirected)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let proxy, !isFinished else { return }

            if let error {
                Logger.shared.log("VLCHeaderProxy[\(requestId)]: upstream error kind=\(proxy.requestKind(for: targetURL)) recvBytes=\(upstreamBytes) sentBytes=\(downstreamBytes) elapsedMs=\(proxy.elapsedMilliseconds(since: startedAt)) target=\(proxy.logURLSummary(targetURL)) error=\(error)", type: "Error")
                if responseHeadersSent {
                    connection.cancel()
                } else {
                    proxy.sendSimpleResponse(connection, statusCode: 502, body: "Upstream error")
                }
                finish()
                return
            }

            guard let http = httpResponse else {
                proxy.sendSimpleResponse(connection, statusCode: 502, body: "Bad gateway")
                finish()
                return
            }

            switch mode {
            case .playlist, .probe:
                let (body, headers, rewritten) = proxy.rewrittenPlaylistResponse(
                    http: http,
                    data: bufferedData,
                    targetURL: targetURL,
                    sessionId: sessionId
                )
                downstreamBytes += body.count
                Logger.shared.log("VLCHeaderProxy[\(requestId)]: upstream done status=\(http.statusCode) kind=\(proxy.requestKind(for: targetURL)) mode=\(mode.logName) activeRequests=\(proxy.activeRequestCountSnapshot()) recvBytes=\(bufferedData.count) sentBytes=\(downstreamBytes) responseBytes=\(body.count) rewritten=\(rewritten) firstByteMs=\(firstDataAt.map { String(format: "%.0f", max(0, ($0 - startedAt) * 1000.0)) } ?? "nil") totalMs=\(proxy.elapsedMilliseconds(since: startedAt)) target=\(proxy.logURLSummary(targetURL))", type: "VLCProxy")
                proxy.sendResponse(connection, statusCode: http.statusCode, headers: headers, body: body)
            case .stream:
                Logger.shared.log("VLCHeaderProxy[\(requestId)]: upstream stream complete status=\(http.statusCode) kind=\(proxy.requestKind(for: targetURL)) activeRequests=\(proxy.activeRequestCountSnapshot()) recvBytes=\(upstreamBytes) sentBytes=\(downstreamBytes) firstByteMs=\(firstDataAt.map { String(format: "%.0f", max(0, ($0 - startedAt) * 1000.0)) } ?? "nil") totalMs=\(proxy.elapsedMilliseconds(since: startedAt)) target=\(proxy.logURLSummary(targetURL))", type: "VLCProxy")
                connection.cancel()
            }

            finish()
        }

        private func startStreamingBufferedData(dataTask: URLSessionDataTask) {
            guard let proxy, let http = httpResponse else {
                dataTask.cancel()
                finish()
                return
            }

            let initialData = bufferedData
            bufferedData.removeAll(keepingCapacity: false)
            mode = .stream
            dataTask.suspend()

            let responseHeaders = proxy.filteredResponseHeaders(from: http)
            proxy.sendResponseHeaders(connection, statusCode: http.statusCode, headers: responseHeaders) { [weak self] error in
                guard let self else { return }
                if let error {
                    Logger.shared.log("VLCHeaderProxy[\(self.requestId)]: failed to send response headers: \(error)", type: "Error")
                    dataTask.cancel()
                    self.finish()
                    return
                }

                self.responseHeadersSent = true
                self.streamChunk(initialData, dataTask: dataTask, suspendBeforeSend: false)
            }
        }

        private func streamChunk(_ data: Data, dataTask: URLSessionDataTask, suspendBeforeSend: Bool = true) {
            guard let proxy else {
                dataTask.cancel()
                finish()
                return
            }

            guard !isFinished else { return }

            guard !data.isEmpty else {
                if !isFinished {
                    dataTask.resume()
                }
                return
            }

            if suspendBeforeSend {
                dataTask.suspend()
            }
            let sendStartedAt = CFAbsoluteTimeGetCurrent()
            proxy.sendData(data, on: connection) { [weak self] error in
                guard let self else { return }
                if let error {
                    Logger.shared.log("VLCHeaderProxy[\(self.requestId)]: downstream send failed kind=\(proxy.requestKind(for: self.targetURL)) chunkBytes=\(data.count) recvBytes=\(self.upstreamBytes) sentBytes=\(self.downstreamBytes) elapsedMs=\(proxy.elapsedMilliseconds(since: self.startedAt)): \(error)", type: "Error")
                    dataTask.cancel()
                    self.finish()
                    return
                }
                self.downstreamBytes += data.count
                let sendMs = (CFAbsoluteTimeGetCurrent() - sendStartedAt) * 1000.0
                let now = CFAbsoluteTimeGetCurrent()
                if sendMs > 250, now - self.lastSlowSendLogAt > 2.0 {
                    self.lastSlowSendLogAt = now
                    Logger.shared.log("VLCHeaderProxy[\(self.requestId)]: downstream slow send kind=\(proxy.requestKind(for: self.targetURL)) chunkBytes=\(data.count) sendMs=\(String(format: "%.0f", sendMs)) recvBytes=\(self.upstreamBytes) sentBytes=\(self.downstreamBytes) target=\(proxy.logURLSummary(self.targetURL))", type: "VLCProxy")
                }
                if !self.isFinished {
                    dataTask.resume()
                }
            }
        }

        private var isFinished: Bool {
            finishLock.lock()
            defer { finishLock.unlock() }
            return finished
        }

        private func finish() {
            finishLock.lock()
            guard !finished else {
                finishLock.unlock()
                return
            }
            finished = true
            let sessionToInvalidate = urlSession
            let continuationToResume = continuation
            urlSession = nil
            continuation = nil
            finishLock.unlock()

            sessionToInvalidate?.invalidateAndCancel()
            continuationToResume?.resume()
        }
    }
}
#endif
