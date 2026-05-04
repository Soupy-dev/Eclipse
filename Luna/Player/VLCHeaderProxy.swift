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
    }

    private let queue = DispatchQueue(label: "vlc.header.proxy")
    private var listener: NWListener?
    private var port: UInt16?
    private let token = UUID().uuidString
    private var sessions: [String: Session] = [:]
    private let sessionLock = NSLock()

    private let maxSessions = 200
    private let sessionTTL: TimeInterval = 20 * 60
    private let maxHeaderBytes = 64 * 1024

    private init() {}

    private func withSessionsLock<T>(_ body: () -> T) -> T {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return body()
    }

    private func sessionCount() -> Int {
        withSessionsLock { sessions.count }
    }

    private func setSession(_ session: Session, for id: String) {
        _ = withSessionsLock {
            sessions[id] = session
        }
    }

    private func session(for id: String) -> Session? {
        withSessionsLock { sessions[id] }
    }

    func makeProxyURL(for targetURL: URL, headers: [String: String]) -> URL? {
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

        let sessionCount = sessionCount()

        if sessionCount >= maxSessions {
            cleanupOldestSessions()
        }

        let sessionId = UUID().uuidString
        setSession(Session(headers: headers, createdAt: Date()), for: sessionId)

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
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
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

        let session = session(for: sessionId)

        guard let session = session else {
            sendSimpleResponse(connection, statusCode: 404, body: "Session not found")
            return
        }

        guard let encoded = queryItems["url"], let targetURL = decodeTargetURL(encoded) else {
            sendSimpleResponse(connection, statusCode: 400, body: "Invalid target")
            return
        }

        guard targetURL.scheme == "http" || targetURL.scheme == "https" else {
            sendSimpleResponse(connection, statusCode: 400, body: "Unsupported scheme")
            return
        }

        var request = URLRequest(url: targetURL)
        request.httpMethod = method

        for (key, value) in headers {
            let lower = key.lowercased()
            if lower == "host" || lower == "connection" || lower == "proxy-connection" {
                continue
            }
            request.setValue(value, forHTTPHeaderField: key)
        }

        for (key, value) in session.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                sendSimpleResponse(connection, statusCode: 502, body: "Bad gateway")
                return
            }

            let isHead = method == "HEAD"
            let (responseData, responseHeaders) = rewriteIfNeeded(http: http, data: data, targetURL: targetURL, sessionId: sessionId)

            sendResponse(
                connection,
                statusCode: http.statusCode,
                headers: responseHeaders,
                body: isHead ? Data() : responseData
            )
        } catch {
            sendSimpleResponse(connection, statusCode: 502, body: "Upstream error")
        }
    }

    private func rewriteIfNeeded(
        http: HTTPURLResponse,
        data: Data,
        targetURL: URL,
        sessionId: String
    ) -> (Data, [String: String]) {
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let isPlaylist = contentType.lowercased().contains("application/vnd.apple.mpegurl")
            || contentType.lowercased().contains("application/x-mpegurl")
            || (String(data: data, encoding: .utf8)?.hasPrefix("#EXTM3U") ?? false)

        var headers: [String: String] = filteredResponseHeaders(from: http)

        if isPlaylist, let text = String(data: data, encoding: .utf8) {
            let rewritten = rewritePlaylist(text: text, baseURL: targetURL, sessionId: sessionId)
            let outData = Data(rewritten.utf8)
            headers["Content-Type"] = "application/vnd.apple.mpegurl"
            headers["Content-Length"] = String(outData.count)
            headers.removeValue(forKey: "Content-Encoding")
            return (outData, headers)
        }

        headers["Content-Length"] = String(data.count)
        headers.removeValue(forKey: "Content-Encoding")
        return (data, headers)
    }

    private func rewritePlaylist(text: String, baseURL: URL, sessionId: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let base = baseURL.deletingLastPathComponent()

        let rewritten = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                return line
            }

            guard let resolved = URL(string: trimmed, relativeTo: base)?.absoluteURL else {
                return line
            }

            if let proxied = buildProxyURL(port: port, sessionId: sessionId, targetURL: resolved) {
                return proxied.absoluteString
            }

            return line
        }

        return rewritten.joined(separator: "\n")
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

    private func sendSimpleResponse(_ connection: NWConnection, statusCode: Int, body: String) {
        let data = Data(body.utf8)
        let headers = [
            "Content-Type": "text/plain; charset=utf-8",
            "Content-Length": String(data.count)
        ]
        sendResponse(connection, statusCode: statusCode, headers: headers, body: data)
    }

    private func sendResponse(_ connection: NWConnection, statusCode: Int, headers: [String: String], body: Data) {
        var lines: [String] = []
        let statusText = httpStatusText(statusCode)
        lines.append("HTTP/1.1 \(statusCode) \(statusText)")
        lines.append("Connection: close")

        for (key, value) in headers {
            lines.append("\(key): \(value)")
        }

        lines.append("\r\n")
        let headerData = Data(lines.joined(separator: "\r\n").utf8)
        let responseData = headerData + body

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
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
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
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
            sessions = sessions.filter { now.timeIntervalSince($0.value.createdAt) < sessionTTL }
        }
    }

    private func cleanupOldestSessions() {
        _ = withSessionsLock {
            let sorted = sessions.sorted { $0.value.createdAt < $1.value.createdAt }
            let removeCount = max(0, sessions.count - maxSessions + 1)
            if removeCount == 0 {
                return
            }

            for idx in 0..<removeCount {
                sessions.removeValue(forKey: sorted[idx].key)
            }
        }
    }
}
#endif
