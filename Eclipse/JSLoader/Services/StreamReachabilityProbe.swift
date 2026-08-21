import Foundation

enum StreamReachabilityDeadReason: Equatable {
    case notFound
    case gone
    case emptyBody
    case invalidPayload(String)

    var summary: String {
        switch self {
        case .notFound:
            return "not found"
        case .gone:
            return "gone"
        case .emptyBody:
            return "empty body"
        case .invalidPayload(let detail):
            return detail
        }
    }
}

enum StreamReachabilityIndeterminateReason: Equatable {
    case cloudflareChallenge(URL?)
    case methodUnsupported
    case rateLimited
    case forbidden
    case serverError(Int)
    case transport(String)
    case offline
    case unverifiableByEclipse(String)

    var summary: String {
        switch self {
        case .cloudflareChallenge:
            return "cloudflare-challenge"
        case .methodUnsupported:
            return "method-unsupported"
        case .rateLimited:
            return "rate-limited"
        case .forbidden:
            return "forbidden"
        case .serverError(let status):
            return "server-error-\(status)"
        case .transport(let detail):
            return detail
        case .offline:
            return "offline"
        case .unverifiableByEclipse(let detail):
            return "unverifiable-\(detail)"
        }
    }
}

enum StreamReachabilityVerdict: Equatable {
    case reachable
    case confidentlyDead(StreamReachabilityDeadReason)
    case indeterminate(StreamReachabilityIndeterminateReason)

    var allowsPlaybackAttempt: Bool {
        switch self {
        case .confidentlyDead:
            return false
        case .reachable, .indeterminate:
            return true
        }
    }

    var summary: String {
        switch self {
        case .reachable:
            return "reachable"
        case .confidentlyDead(let reason):
            return "dead:\(reason.summary)"
        case .indeterminate(let reason):
            return "indeterminate:\(reason.summary)"
        }
    }

    var blame: String {
        switch self {
        case .reachable:
            return "none"
        case .confidentlyDead:
            return "provider"
        case .indeterminate(let reason):
            switch reason {
            case .unverifiableByEclipse:
                return "eclipse-suspect"
            case .cloudflareChallenge, .forbidden, .rateLimited, .serverError, .methodUnsupported:
                return "provider-suspect"
            case .offline, .transport:
                return "none"
            }
        }
    }
}

struct StreamReachabilityReport {
    let verdict: StreamReachabilityVerdict
    let statusCode: Int?
    let contentType: String
    let byteCount: Int

    var logSummary: String {
        "verdict=\(verdict.summary) blame=\(verdict.blame)"
            + " status=\(statusCode.map(String.init) ?? "none")"
            + " contentType=\(contentType.isEmpty ? "none" : contentType)"
            + " bytes=\(byteCount)"
    }
}

enum StreamReachabilityProbe {
    static let defaultByteLimit = 8 * 1024
    static let defaultTimeout: TimeInterval = 6

    static func probe(
        url: URL,
        headers: [String: String],
        timeout: TimeInterval = defaultTimeout,
        byteLimit: Int = defaultByteLimit
    ) async -> StreamReachabilityReport {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return StreamReachabilityReport(
                verdict: .indeterminate(.unverifiableByEclipse("unsupported-scheme")),
                statusCode: nil,
                contentType: "",
                byteCount: 0
            )
        }

        let resolvedLimit = max(byteLimit, 1)
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let effectiveHeaders = CloudflareBypassManager.shared.headersByApplyingCachedBypass(headers, for: url)
        for (name, value) in effectiveHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("bytes=0-\(resolvedLimit - 1)", forHTTPHeaderField: "Range")

        let session = URLSession.fetchData(allowRedirects: true)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.boundedData(
                for: request,
                maximumResponseBytes: resolvedLimit
            )
            guard let http = response as? HTTPURLResponse else {
                return StreamReachabilityReport(
                    verdict: .indeterminate(.unverifiableByEclipse("non-http-response")),
                    statusCode: nil,
                    contentType: "",
                    byteCount: data.count
                )
            }

            let responseHeaders = CloudflareBypassManager.headersDictionary(from: http)
            let contentType = normalizedContentType(from: responseHeaders)
            let verdict = evaluate(
                status: http.statusCode,
                responseHeaders: responseHeaders,
                body: data,
                requestedURL: http.url ?? url
            )

            var resolved = verdict
            if case .confidentlyDead = verdict,
               let finalURL = http.url,
               !isSameOrigin(finalURL, url) {
                resolved = .indeterminate(.unverifiableByEclipse("cross-origin-redirect"))
            }

            return StreamReachabilityReport(
                verdict: resolved,
                statusCode: http.statusCode,
                contentType: contentType,
                byteCount: data.count
            )
        } catch is BoundedURLSessionError {
            return StreamReachabilityReport(
                verdict: .reachable,
                statusCode: nil,
                contentType: "",
                byteCount: resolvedLimit
            )
        } catch {
            return StreamReachabilityReport(
                verdict: transportVerdict(for: error),
                statusCode: nil,
                contentType: "",
                byteCount: 0
            )
        }
    }

    static func evaluate(
        status: Int,
        responseHeaders: [String: String],
        body: Data,
        requestedURL: URL
    ) -> StreamReachabilityVerdict {
        let bodyText = String(data: body, encoding: .utf8) ?? ""

        if CloudflareBypassManager.isChallengeResponse(
            status: status,
            body: bodyText,
            headers: responseHeaders
        ) {
            return .indeterminate(.cloudflareChallenge(requestedURL))
        }

        switch status {
        case 204:
            return .confidentlyDead(.emptyBody)
        case 400:
            return .indeterminate(.transport("http 400"))
        case 401, 403, 451:
            return .indeterminate(.forbidden)
        case 404:
            return .confidentlyDead(.notFound)
        case 405:
            return .indeterminate(.methodUnsupported)
        case 410:
            return .confidentlyDead(.gone)
        case 416:
            return .reachable
        case 429:
            return .indeterminate(.rateLimited)
        case 500...599:
            return .indeterminate(.serverError(status))
        default:
            break
        }

        guard (200...299).contains(status) else {
            if (300...399).contains(status) {
                return .indeterminate(.unverifiableByEclipse("redirect-not-followed"))
            }
            return .indeterminate(.transport("http-\(status)"))
        }

        return successPayloadVerdict(
            responseHeaders: responseHeaders,
            body: body,
            bodyText: bodyText
        )
    }

    private static func successPayloadVerdict(
        responseHeaders: [String: String],
        body: Data,
        bodyText: String
    ) -> StreamReachabilityVerdict {
        let contentType = normalizedContentType(from: responseHeaders)

        if isManifestContentType(contentType) || bodyLooksLikeManifest(bodyText) {
            return .reachable
        }

        if isMediaContentType(contentType) {
            return .reachable
        }

        if let detail = invalidPayloadDetail(
            contentType: contentType,
            body: body,
            bodyText: bodyText
        ) {
            return .confidentlyDead(.invalidPayload(detail))
        }

        if body.isEmpty, declaresEmptyBody(responseHeaders) {
            return .confidentlyDead(.emptyBody)
        }

        return .reachable
    }

    private static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              let lhsHost = lhs.host?.lowercased(),
              let rhsHost = rhs.host?.lowercased() else {
            return false
        }
        let lhsPort = lhs.port ?? (lhsScheme == "https" ? 443 : 80)
        let rhsPort = rhs.port ?? (rhsScheme == "https" ? 443 : 80)
        return lhsScheme == rhsScheme && lhsHost == rhsHost && lhsPort == rhsPort
    }

    private static func headerValue(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func normalizedContentType(from headers: [String: String]) -> String {
        let raw = headerValue("Content-Type", in: headers) ?? ""
        let head = raw.lowercased().split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
        return head.trimmingCharacters(in: .whitespaces)
    }

    private static func declaresEmptyBody(_ headers: [String: String]) -> Bool {
        guard let length = headerValue("Content-Length", in: headers) else { return false }
        return length.trimmingCharacters(in: .whitespaces) == "0"
    }

    private static func isManifestContentType(_ contentType: String) -> Bool {
        contentType.contains("mpegurl")
            || contentType.contains("dash+xml")
            || contentType.contains("application/dash")
    }

    private static func isMediaContentType(_ contentType: String) -> Bool {
        contentType.hasPrefix("video/")
            || contentType.hasPrefix("audio/")
            || contentType.contains("octet-stream")
    }

    private static func bodyLooksLikeManifest(_ bodyText: String) -> Bool {
        let trimmable = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}"))
        let trimmed = bodyText.trimmingCharacters(in: trimmable)
        return trimmed.hasPrefix("#EXTM3U") || bodyLooksLikeDashManifest(trimmed)
    }

    private static func bodyLooksLikeDashManifest(_ trimmedBody: String) -> Bool {
        guard let rootName = xmlRootElementName(trimmedBody) else { return false }
        return rootName == "MPD" || rootName.hasSuffix(":MPD")
    }

    private static func xmlRootElementName(_ trimmedBody: String) -> Substring? {
        var remainder = Substring(trimmedBody)
        while let open = remainder.firstIndex(of: "<") {
            let afterOpen = remainder.index(after: open)
            guard afterOpen < remainder.endIndex else { return nil }
            let marker = remainder[afterOpen]
            if marker == "?" || marker == "!" {
                guard let close = remainder[afterOpen...].firstIndex(of: ">") else { return nil }
                remainder = remainder[remainder.index(after: close)...]
                continue
            }
            return remainder[afterOpen...].prefix { $0.isLetter || $0.isNumber || $0 == ":" }
        }
        return nil
    }

    private static func invalidPayloadDetail(
        contentType: String,
        body: Data,
        bodyText: String
    ) -> String? {
        if contentType == "text/html"
            || contentType == "application/json"
            || contentType.hasSuffix("+json")
            || contentType == "application/xml"
            || contentType == "text/xml"
            || contentType.hasSuffix("+xml") {
            return "returned \(contentType)"
        }

        if contentType.hasPrefix("image/"), bodyLooksLikeImage(body) {
            return "returned \(contentType)"
        }

        let trimmed = bodyText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("<!doctype html")
            || trimmed.hasPrefix("<html")
            || trimmed.hasPrefix("<?xml")
            || trimmed.hasPrefix("{\"error\"")
            || trimmed.hasPrefix("{\"message\"") {
            return "returned an error document"
        }

        return nil
    }

    private static func bodyLooksLikeImage(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count >= 3 else { return false }

        if bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return true }

        if bytes.count >= 8, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47,
           bytes[4] == 0x0D, bytes[5] == 0x0A, bytes[6] == 0x1A, bytes[7] == 0x0A { return true }

        if bytes.count >= 4, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x38 { return true }

        if bytes[0] == 0x42, bytes[1] == 0x4D { return true }

        if bytes.count >= 12, bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 { return true }

        return false
    }

    private static func transportVerdict(for error: Error) -> StreamReachabilityVerdict {
        if error is CancellationError {
            return .indeterminate(.transport("cancelled"))
        }

        guard let urlError = error as? URLError else {
            return .indeterminate(.transport("transport failure"))
        }

        switch urlError.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .dataNotAllowed,
             .internationalRoamingOff:
            return .indeterminate(.offline)
        default:
            return .indeterminate(.transport("url error \(urlError.code.rawValue)"))
        }
    }
}
