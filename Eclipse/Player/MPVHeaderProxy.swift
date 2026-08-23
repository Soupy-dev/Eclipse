import Foundation
import Network
import Security
import zlib

private enum MPVHeaderProxyPlaylistMode {
    case preserveUpstream
    case normalizeRewrittenPlaylist
}

enum MPVHeaderProxyPlaylistRouting {
    static func effectiveResponseURL(originalRequestURL: URL, responseURL: URL?) -> URL {
        responseURL ?? originalRequestURL
    }

    static func resolve(_ reference: String, againstPlaylistURL playlistURL: URL) -> URL? {
        URL(string: reference, relativeTo: playlistURL.deletingLastPathComponent())?.absoluteURL
    }
}

enum MPVHeaderProxyPlaylistFramingPolicy {
    enum Action: Equatable {
        case continueBuffering
        case reject
    }

    static func action(bufferedByteCount: Int, maximumRewriteBytes: Int) -> Action {
        bufferedByteCount > maximumRewriteBytes ? .reject : .continueBuffering
    }

    static func mustRejectIdentifiedPlaylist(isUTF8Decodable: Bool) -> Bool {
        !isUTF8Decodable
    }
}

enum MPVHeaderProxyGenericBodyPolicy {
    enum InitialAction: Equatable {
        case bufferIdentifiedPlaylist
        case probeUnknownRoot
        case probeValidatedResource
        case streamTrustedResponse
        case streamVerifiedCachedMediaContinuation
    }

    enum ProbeAction: Equatable {
        case continueBuffering
        case identifiedPlaylist
        case streamNonPlaylist
        case rejectAmbiguousPrefix
    }

    static func initialAction(
        isPlaylistMetadata: Bool,
        declaredContentType: String?,
        pathExtension: String,
        expectedContentLength _: Int64,
        isInitialGenericRoot: Bool,
        isValidatedResource: Bool,
        hasVerifiedCachedMediaContinuation: Bool
    ) -> InitialAction {
        if isPlaylistMetadata {
            return .bufferIdentifiedPlaylist
        }
        if isValidatedResource {
            return .probeValidatedResource
        }
        if hasVerifiedCachedMediaContinuation {
            return .streamVerifiedCachedMediaContinuation
        }
        if isRecognizedMediaResponse(
            declaredContentType: declaredContentType,
            pathExtension: pathExtension
        ) {
            return .streamTrustedResponse
        }
        return isInitialGenericRoot ? .probeUnknownRoot : .streamTrustedResponse
    }

    private static func isRecognizedMediaResponse(
        declaredContentType: String?,
        pathExtension: String
    ) -> Bool {
        let normalizedExtension = pathExtension.lowercased()
        if ["ts", "m4s", "mp4", "m4v", "aac", "mp3", "webm", "mkv", "jpg", "jpeg", "png", "webp"].contains(normalizedExtension) {
            return true
        }

        let normalizedContentType = (declaredContentType ?? "").lowercased()
        return normalizedContentType.hasPrefix("video/")
            || normalizedContentType.hasPrefix("audio/")
            || normalizedContentType.hasPrefix("image/")
            || normalizedContentType.contains("octet-stream")
    }

    static func probeAction(
        bufferedData: Data,
        maximumProbeBytes: Int
    ) -> ProbeAction {
        let bytes = [UInt8](bufferedData)
        guard !bytes.isEmpty else { return .continueBuffering }

        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let signature = Array("#EXTM3U".utf8)
        var index = 0

        if bytes[0] == bom[0] {
            let availableBOMBytes = min(bytes.count, bom.count)
            if bytes.prefix(availableBOMBytes).elementsEqual(bom.prefix(availableBOMBytes)) {
                guard availableBOMBytes == bom.count else {
                    return bytes.count >= maximumProbeBytes
                        ? .rejectAmbiguousPrefix
                        : .continueBuffering
                }
                index = bom.count
            } else {
                return .streamNonPlaylist
            }
        }

        while index < bytes.count,
              bytes[index] == 0x20
                || bytes[index] == 0x09
                || bytes[index] == 0x0A
                || bytes[index] == 0x0D {
            index += 1
        }

        guard index < bytes.count else {
            return bytes.count >= maximumProbeBytes
                ? .rejectAmbiguousPrefix
                : .continueBuffering
        }

        let availableSignatureBytes = min(bytes.count - index, signature.count)
        guard bytes[index..<(index + availableSignatureBytes)]
            .elementsEqual(signature.prefix(availableSignatureBytes)) else {
            return .streamNonPlaylist
        }
        if availableSignatureBytes == signature.count {
            return .identifiedPlaylist
        }
        return bytes.count >= maximumProbeBytes
            ? .rejectAmbiguousPrefix
            : .continueBuffering
    }
}

enum MPVHeaderProxyValidatedRouteResponsePolicy {
    static func rejectsManifest(
        role: String?,
        contentType: String,
        responseURL _: URL?
    ) -> Bool {
        let lowerContentType = contentType.lowercased()
        return role == "manifest"
            || lowerContentType.contains("mpegurl")
            || lowerContentType.contains("dash+xml")
            || lowerContentType.contains("application/dash")
    }
}

enum MPVHeaderProxyCachedContinuationPolicy {
    static func validatedBodyByteCount(
        statusCode: Int,
        contentRange: String?,
        contentLength: String?,
        transferEncoding: String?,
        responseEntityTag: String?,
        contentEncoding: String?,
        expectedEntityTag: String,
        expectedStart: Int64,
        expectedEnd: Int64,
        expectedTotal: Int64
    ) -> Int64? {
        guard statusCode == 206,
              transferEncoding == nil,
              contentEncoding == nil
                || contentEncoding?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("identity") == .orderedSame,
              expectedStart >= 0,
              expectedEnd >= expectedStart,
              expectedTotal > expectedEnd,
              responseEntityTag?.trimmingCharacters(in: .whitespacesAndNewlines)
                == expectedEntityTag,
              let rawLength = contentLength?.trimmingCharacters(in: .whitespacesAndNewlines),
              let parsedLength = Int64(rawLength),
              parsedLength == expectedEnd - expectedStart + 1,
              let normalizedRange = contentRange?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
              normalizedRange == "bytes \(expectedStart)-\(expectedEnd)/\(expectedTotal)" else {
            return nil
        }
        return parsedLength
    }
}

enum MPVHeaderProxyLogSanitizer {
    static func summary(for url: URL) -> String {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host,
              !scheme.isEmpty,
              !host.isEmpty else {
            return "unknown-origin"
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if let port = url.port, !isDefault(port: port, for: scheme) {
            components.port = port
        }
        return components.string ?? "\(scheme)://redacted-host"
    }

    private static func isDefault(port: Int, for scheme: String) -> Bool {
        (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
    }
}

enum MPVHeaderProxyPinnedAddressPolicy {
    static func normalizeApprovedAddress(
        _ value: String,
        permitsPrivateApprovedAddresses: Bool
    ) -> String? {
        permitsPrivateApprovedAddresses
            ? SkyStreamRemoteURLPolicy.normalizedNumericAddressString(value)
            : SkyStreamRemoteURLPolicy.normalizedPublicAddressString(value)
    }
}

enum MPVHeaderProxyStremioTargetPolicy {
    static func permitsPrivateDispatch(
        to targetURL: URL,
        authority: SkyStreamPinnedOriginAuthority
    ) throws -> Bool {
        return authority.contains(targetURL)
    }

    static func scopedAuthority(
        for rootURL: URL,
        authority: SkyStreamPinnedOriginAuthority?
    ) throws -> SkyStreamPinnedOriginAuthority? {
        guard let authority else { return nil }
        return try permitsPrivateDispatch(to: rootURL, authority: authority)
            ? authority
            : nil
    }
}

struct MPVHeaderProxyRevokedOriginSet: Equatable {
    static let maximumTrackedOrigins = 16

    private(set) var originKeys: Set<String> = []
    private(set) var revokesAllCrossOriginDestinations = false

    static func originKey(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }

    static func requiresRevocation(
        from sourceURL: URL,
        to destinationURL: URL,
        credentialOriginURL: URL
    ) -> Bool {
        guard let sourceKey = originKey(for: sourceURL),
              let destinationKey = originKey(for: destinationURL) else { return true }
        if sourceKey == destinationKey { return false }
        if let credentialKey = originKey(for: credentialOriginURL),
           destinationKey == credentialKey {
            return false
        }
        return !isDefaultPortSchemeUpgrade(from: sourceURL, to: destinationURL)
    }

    private static func isDefaultPortSchemeUpgrade(
        from sourceURL: URL,
        to destinationURL: URL
    ) -> Bool {
        guard sourceURL.scheme?.lowercased() == "http",
              destinationURL.scheme?.lowercased() == "https",
              let sourceHost = sourceURL.host?.lowercased(),
              let destinationHost = destinationURL.host?.lowercased(),
              sourceHost == destinationHost else { return false }
        return (sourceURL.port ?? 80) == 80 && (destinationURL.port ?? 443) == 443
    }

    mutating func revoke(destinationURL: URL) {
        guard !revokesAllCrossOriginDestinations else { return }
        guard let key = Self.originKey(for: destinationURL) else {
            originKeys = []
            revokesAllCrossOriginDestinations = true
            return
        }
        originKeys.insert(key)
        if originKeys.count > Self.maximumTrackedOrigins {
            originKeys = []
            revokesAllCrossOriginDestinations = true
        }
    }

    func revokesCredentials(for targetURL: URL, credentialOriginURL: URL) -> Bool {
        guard let targetKey = Self.originKey(for: targetURL) else {
            return revokesAllCrossOriginDestinations
        }
        if let credentialKey = Self.originKey(for: credentialOriginURL),
           targetKey == credentialKey {
            return false
        }
        if revokesAllCrossOriginDestinations { return true }
        return originKeys.contains(targetKey)
    }
}

struct MPVHeaderProxyUpstreamHealth {
    let failureCount: Int
    let lastFailureAt: Date?
    let lastSuccessAt: Date?
}

private final class MPVHeaderProxyCore {

    private final class CloudflareChallengeReporter {
        private let lock = NSLock()
        private var didReport = false
        private var handler: (URL, String?, Bool, Int) -> Void

        init(handler: @escaping (URL, String?, Bool, Int) -> Void) {
            self.handler = handler
        }

        func replaceHandler(_ handler: @escaping (URL, String?, Bool, Int) -> Void) {
            lock.lock()
            self.handler = handler
            lock.unlock()
        }

        func report(
            url: URL,
            rejectedCookieHeader: String?,
            isInteractiveChallenge: Bool,
            statusCode: Int
        ) {
            lock.lock()
            guard !didReport else {
                lock.unlock()
                return
            }
            didReport = true
            let handler = handler
            lock.unlock()
            handler(url, rejectedCookieHeader, isInteractiveChallenge, statusCode)
        }
    }

    private enum ValidatedManifestKind {
        case hls
        case dash
    }

    private struct ValidatedAcceptedManifest {
        let bytes: Data
        let kind: ValidatedManifestKind
    }

    private struct ValidatedRouteResource {
        let routeID: String
        let targetURL: URL?
        let headers: [String: String]
        let role: String
        let acceptedManifest: ValidatedAcceptedManifest?
        let expectedFiniteContentLength: Int64?

        func replacingAcceptedManifest(_ manifest: ValidatedAcceptedManifest) -> Self {
            Self(
                routeID: routeID,
                targetURL: targetURL,
                headers: headers,
                role: role,
                acceptedManifest: manifest,
                expectedFiniteContentLength: expectedFiniteContentLength
            )
        }
    }

    private struct ValidatedRoutePolicy {
        let resourcesByID: [String: ValidatedRouteResource]
        let routeIDByURL: [String: String]
        let generatedRouteIDByBytes: [Data: String]
        let initialRouteID: String
        let descriptorIdentityKey: String
        let acceptedManifestByteCount: Int

        func resource(forRouteID routeID: String) -> ValidatedRouteResource? {
            resourcesByID[routeID]
        }

        func resource(forRemoteURL url: URL) -> ValidatedRouteResource? {
            guard let routeID = routeIDByURL[Self.canonicalURLKey(url)] else { return nil }
            return resourcesByID[routeID]
        }

        func resource(forGeneratedManifest bytes: Data) -> ValidatedRouteResource? {
            guard let routeID = generatedRouteIDByBytes[bytes] else { return nil }
            return resourcesByID[routeID]
        }

        static func canonicalURLKey(_ url: URL) -> String {
            var components = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: false)

            components?.fragment = nil
            return components?.url?.absoluteString ?? url.absoluteURL.absoluteString
        }
    }

    private final class ValidatedDASHBaseCollector: NSObject, XMLParserDelegate {
        private(set) var values: [String] = []
        private var collecting = false
        private var buffer = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let localName = (qName ?? elementName).split(separator: ":").last?.lowercased()
            if localName == "baseurl" {
                collecting = true
                buffer = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard collecting, buffer.utf8.count <= 16_384 else { return }
            buffer += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let localName = (qName ?? elementName).split(separator: ":").last?.lowercased()
            guard collecting, localName == "baseurl" else { return }
            values.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
            collecting = false
            buffer = ""
        }
    }

    private struct Session {
        let headers: [String: String]
        let credentialOriginURL: URL
        let createdAt: Date
        let lastAccessed: Date
        let logType: String
        let traceID: String
        let requestCount: Int
        let upstreamTransport: UpstreamTransport
        let cloudflareChallengeReporter: CloudflareChallengeReporter?
        let validatedRoutePolicy: ValidatedRoutePolicy?
        let stremioAuthority: SkyStreamPinnedOriginAuthority?
        let revokedDestinationOrigins: MPVHeaderProxyRevokedOriginSet
    }

    private enum UpstreamBodyMode {
        case stream
        case playlist
        case probe

        case rejectedResponseProbe
    }

    private struct CachedPrefixContinuation {
        let responseStatus: Int
        let responseHeaders: [String: String]
        let data: Data
        let upstreamRange: String
        let strongEntityTag: String
        let upstreamStart: Int64
        let upstreamEnd: Int64
        let expectedTotalLength: Int64
    }

    private enum CachedPrefixPlan {
        case handled
        case bridge(CachedPrefixContinuation)
    }

    private let queue = DispatchQueue(label: "mpv.header.proxy")
    private var listener: NWListener?
    private var port: UInt16?
    private let token = UUID().uuidString
    private var sessions: [String: Session] = [:]
    private let sessionLock = NSLock()

    private let maxSessions = 200
    private let sessionTTL: TimeInterval = 6 * 60 * 60
    private let maxHeaderBytes = 64 * 1024
    private let maxPlaylistBytes = 5 * 1024 * 1024
    private let maxRejectedResponseProbeBytes = 1 * 1024 * 1024
    private let playlistProbeBytes = 4 * 1024
    private let maxPendingStreamBytes = 8 * 1024 * 1024
    private let maxPendingStreamSends = 8
    private let maxValidatedManifestBytes = 5_000_000
    private let maxValidatedManifestTotalBytes = 32 * 1024 * 1024
    private let maxAggregateValidatedManifestBytes = 64 * 1024 * 1024
    private let maxValidatedRewrittenBodyBytes = 8 * 1024 * 1024
    private let maxValidatedRoutes = 10_000
    private let maxValidatedSubtitles = 32
    fileprivate let logPrefix: String
    private let playlistMode: MPVHeaderProxyPlaylistMode
    private let gracefulResponseClose: Bool
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

    fileprivate init(
        logPrefix: String = "MPVHeaderProxy",
        playlistMode: MPVHeaderProxyPlaylistMode = .preserveUpstream,
        gracefulResponseClose: Bool = false
    ) {
        self.logPrefix = logPrefix
        self.playlistMode = playlistMode
        self.gracefulResponseClose = gracefulResponseClose
    }

    private func withSessionsLock<T>(_ body: () -> T) -> T {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return body()
    }

    private func sessionCount() -> Int {
        withSessionsLock { sessions.count }
    }

    private func logURLSummary(_ url: URL) -> String {
        MPVHeaderProxyLogSanitizer.summary(for: url)
    }

    private static func sanitizedCredentialHeaders(_ headers: [String: String]) -> [String: String] {
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

    private static func credentialHeaders(
        _ headers: [String: String],
        for destinationURL: URL,
        originURL: URL
    ) -> [String: String] {
        let sanitized = sanitizedCredentialHeaders(headers)
        guard !sameOrigin(destinationURL, originURL) else { return sanitized }
        let safeCrossOriginHeaders: Set<String> = [
            "accept", "accept-language", "cache-control", "pragma", "user-agent"
        ]
        return sanitized.reduce(into: [:]) { result, pair in
            switch pair.key.lowercased() {
            case let name where safeCrossOriginHeaders.contains(name):
                result[pair.key] = pair.value
            case "referer":
                if let value = redactedCrossOriginReferer(pair.value) {
                    result[pair.key] = value
                }
            case "origin":
                if let value = sanitizedOrigin(pair.value) {
                    result[pair.key] = value
                }
            default:
                break
            }
        }
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func origin(_ url: URL) -> (scheme: String, host: String, port: Int)? {
            guard let scheme = url.scheme?.lowercased(),
                  let host = url.host?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            return (scheme, host, url.port ?? (scheme == "https" ? 443 : 80))
        }
        guard let lhsOrigin = origin(lhs), let rhsOrigin = origin(rhs) else { return false }
        return lhsOrigin == rhsOrigin
    }

    private static func redactedCrossOriginReferer(_ value: String) -> String? {
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

    private func isExpectedPlayerDisconnect(_ error: NWError) -> Bool {
        guard case .posix(let code) = error else { return false }
        return code == .ECONNRESET || code == .EPIPE || code == .ENOTCONN || code == .ECANCELED
    }

    private func setSession(_ session: Session, for id: String) {
        withSessionsLock {
            sessions[id] = session
        }
    }

    private func touchSession(for id: String) -> Session? {
        withSessionsLock {
            guard let session = sessions[id] else { return nil }
            let updated = Session(
                headers: session.headers,
                credentialOriginURL: session.credentialOriginURL,
                createdAt: session.createdAt,
                lastAccessed: Date(),
                logType: session.logType,
                traceID: session.traceID,
                requestCount: session.requestCount + 1,
                upstreamTransport: session.upstreamTransport,
                cloudflareChallengeReporter: session.cloudflareChallengeReporter,
                validatedRoutePolicy: session.validatedRoutePolicy,
                stremioAuthority: session.stremioAuthority,
                revokedDestinationOrigins: session.revokedDestinationOrigins
            )
            sessions[id] = updated
            return updated
        }
    }

    private func recordRevokedRedirectDestinationOrigin(
        for id: String,
        sourceURL: URL,
        destinationURL: URL
    ) {
        let logType: String? = withSessionsLock {
            guard let session = sessions[id],
                  session.validatedRoutePolicy == nil else { return nil }
            var revokedOrigins = session.revokedDestinationOrigins
            revokedOrigins.revoke(destinationURL: destinationURL)
            guard revokedOrigins != session.revokedDestinationOrigins else { return nil }
            sessions[id] = Session(
                headers: session.headers,
                credentialOriginURL: session.credentialOriginURL,
                createdAt: session.createdAt,
                lastAccessed: session.lastAccessed,
                logType: session.logType,
                traceID: session.traceID,
                requestCount: session.requestCount,
                upstreamTransport: session.upstreamTransport,
                cloudflareChallengeReporter: session.cloudflareChallengeReporter,
                validatedRoutePolicy: session.validatedRoutePolicy,
                stremioAuthority: session.stremioAuthority,
                revokedDestinationOrigins: revokedOrigins
            )
            return session.logType
        }
        guard let logType else { return }
        Logger.shared.log(
            "\(logPrefix): revoked cross-origin redirect destination session=\(String(id.prefix(8))) sourceHost=\(sourceURL.host?.lowercased() ?? "unknown") destinationHost=\(destinationURL.host?.lowercased() ?? "unknown")",
            type: logType
        )
    }

    func makeProxyURL(
        for targetURL: URL,
        headers: [String: String],
        logType: String = "Stream",
        traceID: String? = nil,
        stremioAuthority: SkyStreamPinnedOriginAuthority? = nil,
        onConfirmedCloudflareChallenge: ((URL, String?, Bool, Int) -> Void)? = nil
    ) -> URL? {
        guard ensureStarted() else { return nil }

        let scopedStremioAuthority: SkyStreamPinnedOriginAuthority?
        do {
            scopedStremioAuthority = try MPVHeaderProxyStremioTargetPolicy.scopedAuthority(
                for: targetURL,
                authority: stremioAuthority
            )
        } catch {
            Logger.shared.log(
                "\(logPrefix): rejected a target outside its configured Stremio authority",
                type: "Error"
            )
            return nil
        }

        var activePort = port
        if (activePort ?? 0) == 0 {
            activePort = waitForPort(timeout: 0.25)
        }

        guard let activePort, activePort > 0 else {
            Logger.shared.log("\(logPrefix): listener port unavailable", type: "Error")
            return nil
        }

        cleanupExpiredSessions()

        let activeSessionCount = sessionCount()

        if activeSessionCount >= maxSessions {
            cleanupOldestSessions()
        }

        let sessionId = UUID().uuidString
        let now = Date()
        let resolvedTraceID = traceID ?? String(sessionId.prefix(8))

        let minimumRequestStartInterval: TimeInterval = logType == "MPV" && isLikelyPlaylistURL(targetURL)
            ? 0.15
            : 0
        setSession(
            Session(
                headers: headers,
                credentialOriginURL: targetURL,
                createdAt: now,
                lastAccessed: now,
                logType: logType,
                traceID: resolvedTraceID,
                requestCount: 0,
                upstreamTransport: UpstreamTransport(
                    minimumRequestStartInterval: minimumRequestStartInterval,
                    pinsUpstreamAddresses: false
                ),
                cloudflareChallengeReporter: onConfirmedCloudflareChallenge.map {
                    CloudflareChallengeReporter(handler: $0)
                },
                validatedRoutePolicy: nil,
                stremioAuthority: scopedStremioAuthority,
                revokedDestinationOrigins: MPVHeaderProxyRevokedOriginSet()
            ),
            for: sessionId
        )
        let requestPaceMilliseconds = Int((minimumRequestStartInterval * 1_000).rounded())
        Logger.shared.log("[MPVProxyTrace \(resolvedTraceID)] stage=session-created session=\(String(sessionId.prefix(8))) target=\(logURLSummary(targetURL)) headerKeys=[\(headers.keys.sorted().joined(separator: ","))] requestPaceMs=\(requestPaceMilliseconds) activeSessions=\(sessionCount())", type: "PlaybackTrace")

        return buildProxyURL(port: activePort, sessionId: sessionId, targetURL: targetURL)
    }

#if os(iOS) && !targetEnvironment(macCatalyst)
    func makeSkyStreamProxyURL(
        for descriptor: SkyStreamValidatedPlaybackDescriptor,
        traceID: String?,
        onValidatedRouteRejection: ((URL, Int, Bool) -> Void)? = nil
    ) -> URL? {
        guard ensureStarted() else { return nil }

        var activePort = port
        if (activePort ?? 0) == 0 {
            activePort = waitForPort(timeout: 0.25)
        }
        guard let activePort, activePort > 0 else {
            Logger.shared.log("\(logPrefix): SkyStream listener port unavailable", type: "Error")
            return nil
        }

        guard descriptor.routes.count <= maxValidatedRoutes,
              descriptor.subtitles.count <= maxValidatedSubtitles,
              !descriptor.routes.isEmpty else {
            Logger.shared.log("\(logPrefix): rejected oversized SkyStream route graph", type: "Error")
            return nil
        }

        var resourcesByID: [String: ValidatedRouteResource] = [:]
        var routeIDByURL: [String: String] = [:]
        var subtitleRouteCount = 0

        for route in descriptor.routes {
            let targetURL = route.remoteURL.url
            var validatedHeaders = route.headers.values
            let routeProxyOptions = route.proxyOptions
                ?? (ValidatedRoutePolicy.canonicalURLKey(targetURL)
                    == ValidatedRoutePolicy.canonicalURLKey(descriptor.underlyingRemoteURL.url)
                    ? descriptor.proxyOptions
                    : nil)
            if let referer = routeProxyOptions?.referer?.url.absoluteString {

                validatedHeaders["referer"] = referer
            }
            guard let scheme = targetURL.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  targetURL.host != nil,
                  targetURL.user == nil,
                  targetURL.password == nil,
                  Self.headersAreValidForValidatedRoute(validatedHeaders) else {
                Logger.shared.log("\(logPrefix): rejected malformed SkyStream route", type: "Error")
                return nil
            }
            if route.role == .subtitle {
                subtitleRouteCount += 1
                guard subtitleRouteCount <= maxValidatedSubtitles else {
                    Logger.shared.log("\(logPrefix): rejected excess SkyStream subtitle routes", type: "Error")
                    return nil
                }
            }

            let key = ValidatedRoutePolicy.canonicalURLKey(targetURL)
            if let existingID = routeIDByURL[key], let existing = resourcesByID[existingID] {

                guard existing.headers == validatedHeaders else {
                    Logger.shared.log("\(logPrefix): rejected ambiguous SkyStream route credentials", type: "Error")
                    return nil
                }
                continue
            }

            let routeID = UUID().uuidString
            routeIDByURL[key] = routeID
            resourcesByID[routeID] = ValidatedRouteResource(
                routeID: routeID,
                targetURL: targetURL,
                headers: validatedHeaders,
                role: route.role.rawValue,
                acceptedManifest: nil,
                expectedFiniteContentLength: descriptor.mediaKind == .direct
                    && route.role == .streamRoot
                    && ValidatedRoutePolicy.canonicalURLKey(targetURL)
                        == ValidatedRoutePolicy.canonicalURLKey(descriptor.underlyingRemoteURL.url)
                    ? descriptor.finiteContentLength
                    : nil
            )
        }

        var generatedRouteIDByBytes: [Data: String] = [:]
        var firstGeneratedRouteID: String?
        var totalManifestBytes = 0
        for accepted in descriptor.acceptedManifests {
            guard !accepted.bytes.isEmpty,
                  accepted.bytes.count <= maxValidatedManifestBytes,
                  totalManifestBytes <= maxValidatedManifestTotalBytes - accepted.bytes.count else {
                Logger.shared.log("\(logPrefix): rejected oversized SkyStream accepted manifest set", type: "Error")
                return nil
            }
            totalManifestBytes += accepted.bytes.count

            let kind: ValidatedManifestKind
            switch accepted.mediaKind {
            case .hls: kind = .hls
            case .dash: kind = .dash
            case .direct:
                Logger.shared.log("\(logPrefix): rejected invalid SkyStream accepted manifest kind", type: "Error")
                return nil
            }
            let manifest = ValidatedAcceptedManifest(bytes: accepted.bytes, kind: kind)

            if let sourceURL = accepted.sourceURL?.url {
                let key = ValidatedRoutePolicy.canonicalURLKey(sourceURL)
                guard let routeID = routeIDByURL[key], let resource = resourcesByID[routeID] else {
                    Logger.shared.log("\(logPrefix): accepted SkyStream manifest has no validated route", type: "Error")
                    return nil
                }
                if let existing = resource.acceptedManifest {
                    guard existing.bytes == manifest.bytes, existing.kind == manifest.kind else {
                        Logger.shared.log("\(logPrefix): rejected conflicting SkyStream manifest bodies", type: "Error")
                        return nil
                    }
                } else {
                    resourcesByID[routeID] = resource.replacingAcceptedManifest(manifest)
                }
            } else if let existingID = generatedRouteIDByBytes[accepted.bytes] {
                if firstGeneratedRouteID == nil { firstGeneratedRouteID = existingID }
            } else {
                let routeID = UUID().uuidString
                generatedRouteIDByBytes[accepted.bytes] = routeID
                if firstGeneratedRouteID == nil { firstGeneratedRouteID = routeID }
                resourcesByID[routeID] = ValidatedRouteResource(
                    routeID: routeID,
                    targetURL: nil,
                    headers: [:],
                    role: "generated-manifest",
                    acceptedManifest: manifest,
                    expectedFiniteContentLength: nil
                )
            }
        }

        let initialRouteID: String?
        if let firstManifest = descriptor.acceptedManifests.first,
           firstManifest.sourceURL == nil {

            initialRouteID = firstGeneratedRouteID
        } else {
            initialRouteID = routeIDByURL[
                ValidatedRoutePolicy.canonicalURLKey(descriptor.underlyingRemoteURL.url)
            ]
        }
        guard let initialRouteID, resourcesByID[initialRouteID] != nil else {
            Logger.shared.log("\(logPrefix): SkyStream descriptor has no playable initial route", type: "Error")
            return nil
        }
        switch descriptor.mediaKind {
        case .direct:
            guard descriptor.acceptedManifests.isEmpty,
                  let length = descriptor.finiteContentLength, length > 0 else {
                Logger.shared.log("\(logPrefix): rejected unbounded SkyStream direct media", type: "Error")
                return nil
            }
        case .hls, .dash:
            guard resourcesByID[initialRouteID]?.acceptedManifest != nil else {
                Logger.shared.log("\(logPrefix): SkyStream initial manifest body is unavailable", type: "Error")
                return nil
            }
        }

        let policy = ValidatedRoutePolicy(
            resourcesByID: resourcesByID,
            routeIDByURL: routeIDByURL,
            generatedRouteIDByBytes: generatedRouteIDByBytes,
            initialRouteID: initialRouteID,
            descriptorIdentityKey: Self.skyDescriptorIdentityKey(descriptor),
            acceptedManifestByteCount: totalManifestBytes
        )

        cleanupExpiredSessions()
        if sessionCount() >= maxSessions { cleanupOldestSessions() }
        let sessionID = UUID().uuidString
        let now = Date()
        let resolvedTraceID = Self.sanitizedSkyTraceID(traceID) ?? String(sessionID.prefix(8))
        let minimumRequestStartInterval: TimeInterval = descriptor.mediaKind == .hls ? 0.15 : 0
        let typedSession = Session(
                headers: [:],
                credentialOriginURL: descriptor.underlyingRemoteURL.url,
                createdAt: now,
                lastAccessed: now,
                logType: "SkyStream",
                traceID: resolvedTraceID,
                requestCount: 0,
                upstreamTransport: UpstreamTransport(
                    minimumRequestStartInterval: minimumRequestStartInterval,
                    pinsUpstreamAddresses: false
                ),
                cloudflareChallengeReporter: onValidatedRouteRejection.map { callback in
                    CloudflareChallengeReporter { url, _, isInteractiveChallenge, statusCode in
                        callback(url, statusCode, isInteractiveChallenge)
                    }
                },
                validatedRoutePolicy: policy,
                stremioAuthority: nil,
                revokedDestinationOrigins: MPVHeaderProxyRevokedOriginSet()
            )
        guard setValidatedSession(typedSession, for: sessionID) else {
            typedSession.upstreamTransport.invalidateAndCancel()
            Logger.shared.log("\(logPrefix): SkyStream manifest session memory limit reached", type: "Error")
            return nil
        }
        Logger.shared.log(
            "[MPVProxyTrace \(resolvedTraceID)] stage=skystream-session-created session=\(String(sessionID.prefix(8))) routes=\(resourcesByID.count) manifests=\(descriptor.acceptedManifests.count)",
            type: "PlaybackTrace"
        )
        return buildValidatedProxyURL(port: activePort, sessionId: sessionID, routeID: initialRouteID)
    }

    private static func headersAreValidForValidatedRoute(_ headers: [String: String]) -> Bool {
        guard headers.count <= 64 else { return false }
        let forbidden: Set<String> = [
            "accept-encoding", "connection", "content-length", "host", "keep-alive",
            "proxy-authenticate", "proxy-authorization", "proxy-connection", "range", "te",
            "trailer", "transfer-encoding", "upgrade"
        ]
        let validNameCharacters = CharacterSet(
            charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyz"
        )
        var total = 0
        for (name, value) in headers {
            guard name == name.lowercased(),
                  !name.isEmpty,
                  name.utf8.count <= 128,
                  name.unicodeScalars.allSatisfy({
                    $0.value < 128 && validNameCharacters.contains($0)
                  }),
                  !forbidden.contains(name),
                  !name.hasPrefix("proxy-"),
                  value.utf8.count <= 8 * 1024,
                  value.unicodeScalars.allSatisfy({
                    $0.value == 9 || ($0.value >= 32 && $0.value != 127)
                  }) else { return false }
            total += name.utf8.count + value.utf8.count + 4
            guard total <= 32 * 1024 else { return false }
        }
        return true
    }

    private static func sanitizedSkyTraceID(_ value: String?) -> String? {
        guard let value else { return nil }
        let scalars = value.unicodeScalars.prefix(64)
        let result = String(String.UnicodeScalarView(scalars.filter {
            ($0.value >= 48 && $0.value <= 57)
                || ($0.value >= 65 && $0.value <= 90)
                || ($0.value >= 97 && $0.value <= 122)
                || $0.value == 45 || $0.value == 95
        }))
        return result.isEmpty ? nil : result
    }

    private static func skyDescriptorIdentityKey(
        _ descriptor: SkyStreamValidatedPlaybackDescriptor
    ) -> String {
        let identity = descriptor.identity
        return [
            identity.packageID,
            identity.providerID,
            identity.payloadSHA256,
            String(identity.generation)
        ].joined(separator: "\u{1f}")
    }

    private func parsedValidatedProxyURL(
        _ proxyURL: URL
    ) -> (sessionID: String, routeID: String, port: UInt16)? {
        guard let components = URLComponents(url: proxyURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "http",
              components.host == "127.0.0.1",
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              let urlPortValue = components.port,
              let urlPort = UInt16(exactly: urlPortValue),
              let listenerPort = port ?? listener?.port?.rawValue,
              urlPort == listenerPort else { return nil }

        let pathParts = components.path.split(separator: "/")
        let queryItems = components.queryItems ?? []
        guard pathParts.count == 2,
              pathParts[0] == "proxy",
              components.percentEncodedPath == "/proxy/\(pathParts[1])",
              queryItems.count == 2,
              queryItems.filter({ $0.name == "token" }).count == 1,
              queryItems.first(where: { $0.name == "token" })?.value == token,
              queryItems.filter({ $0.name == "route" }).count == 1,
              let routeID = queryItems.first(where: { $0.name == "route" })?.value,
              !routeID.isEmpty else { return nil }
        return (String(pathParts[1]), routeID, urlPort)
    }

    func isManagedSkyStreamSessionURL(_ streamProxyURL: URL) -> Bool {
        guard let reference = parsedValidatedProxyURL(streamProxyURL) else { return false }
        return withSessionsLock {
            guard let policy = sessions[reference.sessionID]?.validatedRoutePolicy else {
                return false
            }
            return policy.initialRouteID == reference.routeID
                && policy.resource(forRouteID: reference.routeID) != nil
        }
    }

    func skyStreamSubtitleProxyURLs(
        for descriptor: SkyStreamValidatedPlaybackDescriptor,
        streamProxyURL: URL
    ) -> [String: URL]? {
        guard descriptor.subtitles.count <= maxValidatedSubtitles,
              let reference = parsedValidatedProxyURL(streamProxyURL) else { return nil }
        guard let policy = withSessionsLock({ sessions[reference.sessionID]?.validatedRoutePolicy }),
              policy.initialRouteID == reference.routeID,
              policy.descriptorIdentityKey == Self.skyDescriptorIdentityKey(descriptor) else {
            return nil
        }

        var output: [String: URL] = [:]
        for subtitle in descriptor.subtitles {
            let remoteURL = subtitle.remoteURL.url
            guard let resource = policy.resource(forRemoteURL: remoteURL),
                  resource.headers == subtitle.headers.values,
                  let localURL = buildValidatedProxyURL(
                    port: reference.port,
                    sessionId: reference.sessionID,
                    routeID: resource.routeID
                  ) else { return nil }

            output[remoteURL.absoluteString] = localURL
        }
        return output
    }

    func setSkyStreamRouteRejectionHandler(
        for streamProxyURL: URL,
        handler: @escaping (URL, Int, Bool) -> Void
    ) -> Bool {
        guard let reference = parsedValidatedProxyURL(streamProxyURL) else { return false }

        return withSessionsLock {
            guard let session = sessions[reference.sessionID],
                  let policy = session.validatedRoutePolicy,
                  policy.initialRouteID == reference.routeID else { return false }

            let reporterHandler: (URL, String?, Bool, Int) -> Void = {
                url, _, isInteractiveChallenge, statusCode in
                handler(url, statusCode, isInteractiveChallenge)
            }
            if let reporter = session.cloudflareChallengeReporter {
                reporter.replaceHandler(reporterHandler)
            } else {
                sessions[reference.sessionID] = Session(
                    headers: session.headers,
                    credentialOriginURL: session.credentialOriginURL,
                    createdAt: session.createdAt,
                    lastAccessed: session.lastAccessed,
                    logType: session.logType,
                    traceID: session.traceID,
                    requestCount: session.requestCount,
                    upstreamTransport: session.upstreamTransport,
                    cloudflareChallengeReporter: CloudflareChallengeReporter(
                        handler: reporterHandler
                    ),
                    validatedRoutePolicy: policy,
                    stremioAuthority: session.stremioAuthority,
                    revokedDestinationOrigins: session.revokedDestinationOrigins
                )
            }
            return true
        }
    }
#endif

    private func ensureStarted() -> Bool {
        if listener != nil { return true }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            parameters.requiredInterfaceType = .loopback
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
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
                        Logger.shared.log("\(self.logPrefix): listener ready without a valid port", type: "Error")
                    }
                case .failed(let error):
                    Logger.shared.log("\(self.logPrefix): listener failed: \(error)", type: "Error")
                    self.listener = nil
                    self.port = nil
                case .cancelled:
                    Logger.shared.log("\(self.logPrefix): listener cancelled", type: "Stream")
                    self.listener = nil
                    self.port = nil
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            let initialPort = listener.port?.rawValue ?? 0
            if initialPort > 0 {
                self.port = initialPort
                Logger.shared.log("\(logPrefix): started on 127.0.0.1:\(initialPort)", type: "Info")
            } else {
                Logger.shared.log("\(logPrefix): started; awaiting port assignment", type: "Info")
            }
            return true
        } catch {
            Logger.shared.log("\(logPrefix): failed to start listener: \(error)", type: "Error")
            return false
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .ready = state,
               connection.currentPath?.usesInterfaceType(.loopback) != true {
                Logger.shared.log("\(self.logPrefix): rejected a non-loopback client path", type: "Error")
                connection.cancel()
            } else if case .failed(let error) = state {
                if !self.isExpectedPlayerDisconnect(error) {
                    Logger.shared.log("\(self.logPrefix): connection failed: \(error)", type: "Error")
                }
            }
        }
        connection.start(queue: queue)
        receiveHeaders(on: connection, buffer: Data())
    }

    private func receiveHeaders(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                if !self.isExpectedPlayerDisconnect(error) {
                    Logger.shared.log("\(self.logPrefix): receive error: \(error)", type: "Error")
                }
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

    private func refuseRequest(
        _ connection: NWConnection,
        statusCode: Int,
        body: String,
        reason: String,
        subsystem: String? = nil,
        detail: String = ""
    ) {
        let suffix = detail.isEmpty ? "" : " \(detail)"
        Logger.shared.log(
            "[MPVProxyTrace] stage=refused-by-eclipse status=\(statusCode) reason=\(reason) subsystem=\(subsystem ?? "unresolved")\(suffix); \(logPrefix) refused this request before contacting the source, so whatever failed here is Eclipse, not the source",
            type: "PlaybackTrace"
        )
        sendSimpleResponse(connection, statusCode: statusCode, body: body)
    }

    private func processRequest(headerData: Data, body: Data, connection: NWConnection) async {
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            refuseRequest(connection, statusCode: 400, body: "Invalid request", reason: "header-not-utf8", detail: "headerBytes=\(headerData.count)")
            return
        }

        let lines = headerText.split(separator: "\r\n")
        guard let requestLine = lines.first else {
            refuseRequest(connection, statusCode: 400, body: "Invalid request", reason: "empty-request-line")
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            refuseRequest(connection, statusCode: 400, body: "Invalid request", reason: "malformed-request-line", detail: "parts=\(parts.count)")
            return
        }

        let method = String(parts[0]).uppercased()
        let rawPath = String(parts[1])

        if method != "GET" && method != "HEAD" {
            refuseRequest(connection, statusCode: 405, body: "Method not allowed", reason: "method-not-allowed", detail: "methodBytes=\(method.utf8.count)")
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
            refuseRequest(connection, statusCode: 400, body: "Invalid URL", reason: "unparseable-request-path", detail: "pathBytes=\(rawPath.utf8.count)")
            return
        }

        let pathParts = urlComponents.path.split(separator: "/")
        guard pathParts.count >= 2, pathParts[0] == "proxy" else {
            refuseRequest(connection, statusCode: 404, body: "Not found", reason: "path-not-a-proxy-route", detail: "segments=\(pathParts.count)")
            return
        }

        let sessionId = String(pathParts[1])
        let rawQueryItems = urlComponents.queryItems ?? []
        var queryItems: [String: String] = [:]
        for item in rawQueryItems where queryItems[item.name] == nil {
            queryItems[item.name] = item.value ?? ""
        }

        guard queryItems["token"] == token else {
            refuseRequest(connection, statusCode: 403, body: "Forbidden", reason: "token-mismatch", detail: "session=\(String(sessionId.prefix(8))) tokenPresent=\(queryItems["token"] != nil)")
            return
        }

        let session = touchSession(for: sessionId)

        guard let session = session else {
            refuseRequest(connection, statusCode: 404, body: "Session not found", reason: "session-missing-or-expired", detail: "session=\(String(sessionId.prefix(8)))")
            return
        }

        let validatedResource: ValidatedRouteResource?
        let targetURL: URL
        if let policy = session.validatedRoutePolicy {
            let itemNames = rawQueryItems.map(\.name)
            guard body.isEmpty,
                  parts.count == 3,
                  pathParts.count == 2,
                  rawQueryItems.count == 2,
                  Set(itemNames) == Set(["route", "token"]),
                  itemNames.filter({ $0 == "route" }).count == 1,
                  itemNames.filter({ $0 == "token" }).count == 1,
                  let routeID = queryItems["route"],
                  let resource = policy.resource(forRouteID: routeID) else {
                refuseRequest(connection, statusCode: 403, body: "Forbidden", reason: "validated-route-shape-rejected", subsystem: session.logType, detail: "session=\(String(sessionId.prefix(8))) queryItems=\(rawQueryItems.count) bodyBytes=\(body.count)")
                return
            }
            validatedResource = resource
            if resource.acceptedManifest != nil {
                serveValidatedManifest(
                    resource,
                    policy: policy,
                    sessionId: sessionId,
                    method: method,
                    connection: connection
                )
                return
            }
            guard let remoteURL = resource.targetURL else {
                refuseRequest(connection, statusCode: 404, body: "Route unavailable", reason: "validated-route-has-no-target", subsystem: session.logType, detail: "session=\(String(sessionId.prefix(8))) role=\(resource.role)")
                return
            }
            targetURL = remoteURL
        } else {
            validatedResource = nil
            guard let encoded = queryItems["url"], let decoded = decodeTargetURL(encoded) else {
                refuseRequest(connection, statusCode: 400, body: "Invalid target", reason: "target-url-undecodable", subsystem: session.logType, detail: "session=\(String(sessionId.prefix(8))) encodedPresent=\(queryItems["url"] != nil)")
                return
            }
            targetURL = decoded
        }

        guard let targetScheme = targetURL.scheme?.lowercased(),
              targetScheme == "http" || targetScheme == "https" else {
            refuseRequest(connection, statusCode: 400, body: "Unsupported scheme", reason: "target-scheme-unsupported", subsystem: session.logType, detail: "session=\(String(sessionId.prefix(8))) schemeBytes=\(targetURL.scheme?.utf8.count ?? 0)")
            return
        }

        let requestId = String(UUID().uuidString.prefix(8))
        let logType = session.logType
        let requestSequence = session.requestCount
        let shouldLogLifecycle = requestSequence == 1 || requestSequence.isMultiple(of: 25)
        let incomingRange = headers.first { $0.key.caseInsensitiveCompare("Range") == .orderedSame }?.value ?? "nil"
        if shouldLogLifecycle {
            let targetSummary = validatedResource.map { "validated-route:\($0.role)" }
                ?? logURLSummary(targetURL)
            Logger.shared.log("[MPVProxyTrace \(session.traceID)] stage=request session=\(String(sessionId.prefix(8))) req=\(requestSequence) id=\(requestId) method=\(method) target=\(targetSummary) range=\(incomingRange)", type: "PlaybackTrace")
        }

        var request = URLRequest(url: targetURL)
        request.httpMethod = method
        // Classification and byte-range accounting operate on the exact wire
        // representation; compressed provider bodies could otherwise be
        // decoded after the response headers were framed.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let effectiveSessionHeaders = validatedResource?.headers ?? session.headers
        let credentialHeaderNames = Set(
            Self.sanitizedCredentialHeaders(effectiveSessionHeaders).keys.map { $0.lowercased() }
        ).union(["authorization", "cookie", "cookie2", "proxy-authorization"])
        let safeIncomingHeaderNames: Set<String> = [
            "accept", "accept-language", "cache-control", "dnt", "icy-metadata",
            "if-match", "if-modified-since", "if-none-match", "if-range",
            "if-unmodified-since", "pragma", "range", "user-agent"
        ]
        for (key, value) in headers {
            let lower = key.lowercased()
            if lower == "host"
                || hopByHopRequestHeaders.contains(lower)
                || credentialHeaderNames.contains(lower)
                || !safeIncomingHeaderNames.contains(lower) {
                continue
            }
            request.setValue(value, forHTTPHeaderField: key)
        }

        var scopedSessionHeaders: [String: String]
        if let validatedHeaders = validatedResource?.headers {
            scopedSessionHeaders = validatedHeaders
        } else {
            scopedSessionHeaders = Self.credentialHeaders(
                session.headers,
                for: targetURL,
                originURL: session.credentialOriginURL
            )
            if session.revokedDestinationOrigins.revokesCredentials(
                for: targetURL,
                credentialOriginURL: session.credentialOriginURL
            ) {
                for name in ["Authorization", "Cookie", "Cookie2", "Proxy-Authorization"] {
                    scopedSessionHeaders.keys
                        .filter { $0.caseInsensitiveCompare(name) == .orderedSame }
                        .forEach { scopedSessionHeaders.removeValue(forKey: $0) }
                }
            }
        }
        for (key, value) in scopedSessionHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if validatedResource == nil {
            CloudflareBypassManager.shared.applyCachedBypass(to: &request, for: targetURL)
        }

        if playlistMode == .normalizeRewrittenPlaylist {
            let normalizedRange = request.value(forHTTPHeaderField: "Range")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if isLikelyPlaylistURL(targetURL), normalizedRange == "bytes=0-" {
                request.setValue(nil, forHTTPHeaderField: "Range")
            }
        }

        let cachedPrefixPlan = validatedResource == nil
            ? await cachedPrefixPlanIfAvailable(
                targetURL: targetURL,
                headers: scopedSessionHeaders,
                method: method,
                rangeHeader: request.value(forHTTPHeaderField: "Range"),
                requestId: requestId,
                logType: logType,
                connection: connection
            )
            : nil
        let cachedPrefix: CachedPrefixContinuation?
        switch cachedPrefixPlan {
        case .handled:
            return
        case .bridge(let continuation):
            cachedPrefix = continuation
            request.setValue(continuation.upstreamRange, forHTTPHeaderField: "Range")
            request.setValue(continuation.strongEntityTag, forHTTPHeaderField: "If-Range")
        case nil:
            cachedPrefix = nil
        }

        let upstreamRange = request.value(forHTTPHeaderField: "Range") ?? "nil"
        if shouldLogLifecycle {
            Logger.shared.log("[MPVProxyTrace \(session.traceID)] stage=upstream-start session=\(String(sessionId.prefix(8))) req=\(requestSequence) range=\(upstreamRange)", type: "PlaybackTrace")
        }
        let bridge = UpstreamBridge(
            proxy: self,
            request: request,
            requestId: requestId,
            method: method,
            targetURL: targetURL,
            sessionId: sessionId,
            traceID: session.traceID,
            requestSequence: requestSequence,
            shouldLogLifecycle: shouldLogLifecycle,
            logType: logType,
            credentialHeaders: effectiveSessionHeaders,
            credentialOriginURL: validatedResource?.targetURL ?? session.credentialOriginURL,
            upstreamTransport: session.upstreamTransport,
            cloudflareChallengeReporter: session.cloudflareChallengeReporter,
            validatedRoutePolicy: session.validatedRoutePolicy,
            validatedRouteRole: validatedResource?.role,
            validatedExpectedFiniteContentLength: validatedResource?.expectedFiniteContentLength,
            stremioAuthority: session.stremioAuthority,
            revokedDestinationOrigins: session.revokedDestinationOrigins,
            connection: connection,
            cachedPrefix: cachedPrefix
        )
        await bridge.start()
    }

    private func cachedPrefixPlanIfAvailable(
        targetURL: URL,
        headers: [String: String],
        method: String,
        rangeHeader: String?,
        requestId: String,
        logType: String,
        connection: NWConnection
    ) async -> CachedPrefixPlan? {
#if os(tvOS)
        return nil
#else
        guard method == "GET" else {
            Logger.shared.log("\(logPrefix)[\(requestId)]: MPV warmup cache skipped reason=method-\(method) target=\(logURLSummary(targetURL))", type: logType)
            return nil
        }

        if let reason = ExperimentalMPVPreloadManager.shared.playbackProxySkipReason(for: targetURL) {
            if !reason.hasPrefix("unsupported-extension") {
                Logger.shared.log("\(logPrefix)[\(requestId)]: MPV warmup cache skipped reason=\(reason) target=\(logURLSummary(targetURL))", type: logType)
            }
            return nil
        }

        let targetExtension = targetURL.pathExtension.lowercased()
        if targetExtension == "m3u8" || targetExtension == "m3u" {
            Logger.shared.log("\(logPrefix)[\(requestId)]: MPV warmup cache skipped reason=playlist-prefix-replay-disabled target=\(logURLSummary(targetURL))", type: logType)
            return nil
        }

        let parsedRange: (start: Int64, end: Int64?)?
        if let rangeHeader {
            guard let supportedRange = parseByteRange(rangeHeader) else {
                Logger.shared.log("\(logPrefix)[\(requestId)]: MPV warmup cache skipped reason=unsupported-request-range range=\(rangeHeader) target=\(logURLSummary(targetURL))", type: logType)
                return nil
            }
            parsedRange = supportedRange
        } else {
            parsedRange = nil
        }
        let requestedStart = parsedRange?.start ?? 0
        guard requestedStart == 0 else {

            Logger.shared.log("\(logPrefix)[\(requestId)]: MPV warmup cache skipped reason=nonzero-request-range range=\(rangeHeader ?? "nil") target=\(logURLSummary(targetURL))", type: logType)
            return nil
        }

        guard let starter = await ExperimentalMPVPreloadManager.shared.cachedStarter(
            for: targetURL,
            headers: headers,
            waitForActiveWarmupUpTo: 0.35
        ) else {
            Logger.shared.log("\(logPrefix)[\(requestId)]: MPV warmup cache miss target=\(logURLSummary(targetURL)) range=\(rangeHeader ?? "nil")", type: logType)
            return nil
        }

        guard !starter.isPlaylist else {
            Logger.shared.log("\(logPrefix)[\(requestId)]: MPV warmup cache skipped reason=cached-starter-is-playlist target=\(logURLSummary(targetURL))", type: logType)
            return nil
        }

        guard let totalLength = starter.totalLength, totalLength > 0 else {
            Logger.shared.log("\(logPrefix)[\(requestId)]: MPV warmup cache skipped reason=unknown-total-length bytes=\(starter.data.count) target=\(logURLSummary(targetURL))", type: logType)
            return nil
        }

        guard !starter.data.isEmpty else {
            Logger.shared.log("\(logPrefix)[\(requestId)]: MPV warmup cache skipped reason=empty-starter target=\(logURLSummary(targetURL))", type: logType)
            return nil
        }

        let cachedByteCount = Int64(starter.data.count)
        guard cachedByteCount > 0 else { return nil }

        let requestedEnd = min(parsedRange?.end ?? (totalLength - 1), totalLength - 1)
        guard requestedEnd >= 0 else { return nil }

        let cachedEnd = min(cachedByteCount - 1, requestedEnd)
        guard cachedEnd >= 0 else { return nil }

        if requestedEnd < cachedByteCount {
            let responseData = starter.data.prefix(Int(requestedEnd + 1))
            let headers = cachedResponseHeaders(
                contentType: starter.contentType,
                contentLength: Int64(responseData.count),
                contentRange: rangeHeader == nil ? nil : "bytes 0-\(requestedEnd)/\(totalLength)"
            )
            Logger.shared.log("\(logPrefix)[\(requestId)]: MPV warmup cache served full request bytes=\(responseData.count) range=\(rangeHeader ?? "nil") target=\(logURLSummary(targetURL))", type: logType)
            sendResponse(connection, statusCode: rangeHeader == nil ? 200 : 206, headers: headers, body: Data(responseData))
            return .handled
        }

        guard cachedByteCount < totalLength else {
            let responseData = starter.data.prefix(Int(min(cachedByteCount, requestedEnd + 1)))
            let headers = cachedResponseHeaders(
                contentType: starter.contentType,
                contentLength: Int64(responseData.count),
                contentRange: rangeHeader == nil ? nil : "bytes 0-\(Int64(responseData.count) - 1)/\(totalLength)"
            )
            Logger.shared.log("\(logPrefix)[\(requestId)]: MPV warmup cache served complete media bytes=\(responseData.count) target=\(logURLSummary(targetURL))", type: logType)
            sendResponse(connection, statusCode: rangeHeader == nil ? 200 : 206, headers: headers, body: Data(responseData))
            return .handled
        }

        guard let strongEntityTag = starter.strongEntityTag else {
            Logger.shared.log("\(logPrefix)[\(requestId)]: MPV warmup cache skipped reason=missing-strong-entity-validator target=\(logURLSummary(targetURL))", type: logType)
            return nil
        }

        let upstreamRange = "bytes=\(cachedByteCount)-\(requestedEnd)"

        let responseHeaders = cachedResponseHeaders(
            contentType: starter.contentType,
            contentLength: requestedEnd + 1,
            contentRange: rangeHeader == nil ? nil : "bytes 0-\(requestedEnd)/\(totalLength)"
        )
        Logger.shared.log("\(logPrefix)[\(requestId)]: MPV warmup cache hit prefixBytes=\(starter.data.count) upstreamRange=\(upstreamRange) responseRange=\(rangeHeader ?? "nil") target=\(logURLSummary(targetURL))", type: logType)
        return .bridge(CachedPrefixContinuation(
            responseStatus: rangeHeader == nil ? 200 : 206,
            responseHeaders: responseHeaders,
            data: starter.data,
            upstreamRange: upstreamRange,
            strongEntityTag: strongEntityTag,
            upstreamStart: cachedByteCount,
            upstreamEnd: requestedEnd,
            expectedTotalLength: totalLength
        ))
#endif
    }

    private func parseByteRange(_ value: String?) -> (start: Int64, end: Int64?)? {
        guard let value else { return nil }
        let lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lower.hasPrefix("bytes=") else { return nil }
        let body = lower.dropFirst("bytes=".count)
        guard !body.contains(",") else { return nil }
        let parts = body.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2,
              !parts[0].isEmpty,
              parts[0].utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let start = Int64(parts[0]),
              start >= 0 else {
            return nil
        }
        let end: Int64?
        if parts[1].isEmpty {
            end = nil
        } else {
            guard parts[1].utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let parsedEnd = Int64(parts[1]),
                  parsedEnd >= start else {
                return nil
            }
            end = parsedEnd
        }
        return (start, end)
    }

    private func cachedResponseHeaders(contentType: String?, contentLength: Int64, contentRange: String?) -> [String: String] {
        var headers: [String: String] = [
            "Content-Length": String(max(0, contentLength)),
            "Accept-Ranges": "bytes"
        ]
        if let contentType, !contentType.isEmpty {
            headers["Content-Type"] = contentType
        } else {
            headers["Content-Type"] = "application/octet-stream"
        }
        if let contentRange {
            headers["Content-Range"] = contentRange
        }
        return headers
    }

    private func upstreamBodyMode(
        for http: HTTPURLResponse,
        targetURL: URL,
        isInitialGenericRoot: Bool,
        isValidatedResource: Bool,
        hasVerifiedCachedMediaContinuation: Bool
    ) -> UpstreamBodyMode {
        switch MPVHeaderProxyGenericBodyPolicy.initialAction(
            isPlaylistMetadata: isPlaylistMetadata(http: http, targetURL: targetURL),
            declaredContentType: http.value(forHTTPHeaderField: "Content-Type"),
            pathExtension: targetURL.pathExtension,
            expectedContentLength: http.expectedContentLength,
            isInitialGenericRoot: isInitialGenericRoot,
            isValidatedResource: isValidatedResource,
            hasVerifiedCachedMediaContinuation: hasVerifiedCachedMediaContinuation
        ) {
        case .bufferIdentifiedPlaylist:
            return .playlist
        case .probeUnknownRoot, .probeValidatedResource:
            return .probe
        case .streamTrustedResponse, .streamVerifiedCachedMediaContinuation:
            return .stream
        }
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

    private func isLikelyPlaylistURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "m3u8" || ext == "m3u"
    }

    private func isPlaylistData(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return trimmedPlaylistProbeText(text).hasPrefix("#EXTM3U")
    }

    private func trimmedPlaylistProbeText(_ text: String) -> String {
        let characters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}"))
        return text.trimmingCharacters(in: characters)
    }

    private func rewrittenPlaylistResponse(
        http: HTTPURLResponse,
        data: Data,
        targetURL: URL,
        sessionId: String,
        logType: String,
        requiresValidEncoding: Bool
    ) -> (Data, [String: String], Bool, Int) {
        var headers: [String: String] = filteredResponseHeaders(from: http)

        let identifiedAsPlaylist = isPlaylistData(data)
            || isPlaylistMetadata(http: http, targetURL: targetURL)
        if identifiedAsPlaylist,
           requiresValidEncoding,
           MPVHeaderProxyPlaylistFramingPolicy.mustRejectIdentifiedPlaylist(
            isUTF8Decodable: String(data: data, encoding: .utf8) != nil
           ) {
            let body = Data("Invalid playlist encoding".utf8)
            setHeader("Content-Type", value: "text/plain; charset=utf-8", in: &headers)
            setHeader("Content-Length", value: String(body.count), in: &headers)
            removeHeader("Content-Encoding", from: &headers)
            removeHeader("Content-Range", from: &headers)
            removeHeader("Accept-Ranges", from: &headers)
            return (body, headers, false, 502)
        }

        if identifiedAsPlaylist, let text = String(data: data, encoding: .utf8) {
            let rewritten = rewritePlaylist(text: text, baseURL: targetURL, sessionId: sessionId, logType: logType)
            let outData = Data(rewritten.utf8)
            setHeader("Content-Type", value: "application/vnd.apple.mpegurl", in: &headers)
            setHeader("Content-Length", value: String(outData.count), in: &headers)
            removeHeader("Content-Encoding", from: &headers)
            if playlistMode == .normalizeRewrittenPlaylist {
                removeHeader("Content-Range", from: &headers)
                removeHeader("Accept-Ranges", from: &headers)
                return (outData, headers, true, 200)
            }
            return (outData, headers, true, http.statusCode)
        }

        setHeader("Content-Length", value: String(data.count), in: &headers)
        removeHeader("Content-Encoding", from: &headers)
        return (data, headers, false, http.statusCode)
    }

    private func rewritePlaylist(text: String, baseURL: URL, sessionId: String, logType: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var mediaLineRewriteCount = 0
        var attributeRewriteCount = 0
        var segmentDurations: [Double] = []
        var discontinuityCount = 0
        var gapCount = 0
        var programDateTimeCount = 0
        var mapCount = 0
        var variantCount = 0
        var mediaSequence = "none"
        var discontinuitySequence = "none"
        var targetDuration = "none"
        var hasEndList = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let upper = trimmed.uppercased()
            if upper.hasPrefix("#EXTINF:"),
               let colon = trimmed.firstIndex(of: ":") {
                let value = trimmed[trimmed.index(after: colon)...]
                    .split(separator: ",", maxSplits: 1)
                    .first
                    .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if let value, value.isFinite, value >= 0 {
                    segmentDurations.append(value)
                }
            } else if upper == "#EXT-X-DISCONTINUITY" {
                discontinuityCount += 1
            } else if upper == "#EXT-X-GAP" {
                gapCount += 1
            } else if upper.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
                programDateTimeCount += 1
            } else if upper.hasPrefix("#EXT-X-MAP:") {
                mapCount += 1
            } else if upper.hasPrefix("#EXT-X-STREAM-INF:") {
                variantCount += 1
            } else if upper.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSequence = trimmed.split(separator: ":", maxSplits: 1).last
                    .flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
                    .map(String.init) ?? "invalid"
            } else if upper.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE:") {
                discontinuitySequence = trimmed.split(separator: ":", maxSplits: 1).last
                    .flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
                    .map(String.init) ?? "invalid"
            } else if upper.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetDuration = trimmed.split(separator: ":", maxSplits: 1).last
                    .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    .map { String(format: "%.3f", $0) } ?? "invalid"
            } else if upper == "#EXT-X-ENDLIST" {
                hasEndList = true
            }
        }

        let rewritten = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return line
            }

            if trimmed.hasPrefix("#") {
                return rewritePlaylistTagLine(line, playlistURL: baseURL, sessionId: sessionId, rewrittenCount: &attributeRewriteCount)
            }

            if let proxied = proxiedPlaylistURLString(for: trimmed, playlistURL: baseURL, sessionId: sessionId) {
                mediaLineRewriteCount += 1
                return proxied.absoluteString
            }

            return line
        }

        Logger.shared.log("\(logPrefix): playlist rewrite target=\(logURLSummary(baseURL)) lines=\(lines.count) mediaLines=\(mediaLineRewriteCount) attributes=\(attributeRewriteCount) session=\(String(sessionId.prefix(8)))", type: logType)
        let totalDuration = segmentDurations.reduce(0, +)
        let minimumDuration = segmentDurations.min() ?? 0
        let maximumDuration = segmentDurations.max() ?? 0
        Logger.shared.log(
            "[MPVPlaylistTrace] session=\(String(sessionId.prefix(8))) lines=\(lines.count) segments=\(segmentDurations.count) durationTotal=\(String(format: "%.3f", totalDuration)) durationMin=\(String(format: "%.3f", minimumDuration)) durationMax=\(String(format: "%.3f", maximumDuration)) targetDuration=\(targetDuration) mediaSequence=\(mediaSequence) discontinuitySequence=\(discontinuitySequence) discontinuities=\(discontinuityCount) gaps=\(gapCount) programDateTimes=\(programDateTimeCount) maps=\(mapCount) variants=\(variantCount) endList=\(hasEndList)",
            type: "PlaybackTrace"
        )
        return rewritten.joined(separator: "\n")
    }

    private func rewritePlaylistTagLine(_ line: String, playlistURL: URL, sessionId: String, rewrittenCount: inout Int) -> String {
        var output = line
        rewriteQuotedURIAttributes(in: &output, playlistURL: playlistURL, sessionId: sessionId, rewrittenCount: &rewrittenCount)
        rewriteUnquotedURIAttributes(in: &output, playlistURL: playlistURL, sessionId: sessionId, rewrittenCount: &rewrittenCount)
        return output
    }

    private func rewriteQuotedURIAttributes(in line: inout String, playlistURL: URL, sessionId: String, rewrittenCount: inout Int) {
        var searchStart = line.startIndex
        while let keyRange = line.range(of: "URI=\"", options: [.caseInsensitive], range: searchStart..<line.endIndex) {
            let valueStart = keyRange.upperBound
            guard let valueEnd = line[valueStart...].firstIndex(of: "\"") else {
                break
            }

            let original = String(line[valueStart..<valueEnd])
            guard let proxied = proxiedPlaylistURLString(for: original, playlistURL: playlistURL, sessionId: sessionId) else {
                searchStart = valueEnd
                continue
            }

            line.replaceSubrange(valueStart..<valueEnd, with: proxied.absoluteString)
            rewrittenCount += 1
            searchStart = line.index(valueStart, offsetBy: proxied.absoluteString.count)
        }
    }

    private func rewriteUnquotedURIAttributes(in line: inout String, playlistURL: URL, sessionId: String, rewrittenCount: inout Int) {
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
                  let proxied = proxiedPlaylistURLString(for: original, playlistURL: playlistURL, sessionId: sessionId) else {
                searchStart = valueEnd
                continue
            }

            line.replaceSubrange(valueStart..<valueEnd, with: proxied.absoluteString)
            rewrittenCount += 1
            searchStart = line.index(valueStart, offsetBy: proxied.absoluteString.count)
        }
    }

    private func proxiedPlaylistURLString(for reference: String, playlistURL: URL, sessionId: String) -> URL? {
        guard let resolved = MPVHeaderProxyPlaylistRouting.resolve(
            reference,
            againstPlaylistURL: playlistURL
        ), let scheme = resolved.scheme?.lowercased(),
           scheme == "http" || scheme == "https" else {
            return nil
        }

        return buildProxyURL(port: port, sessionId: sessionId, targetURL: resolved)
    }

    private func serveValidatedManifest(
        _ resource: ValidatedRouteResource,
        policy: ValidatedRoutePolicy,
        sessionId: String,
        method: String,
        connection: NWConnection
    ) {
#if os(iOS)
        guard let accepted = resource.acceptedManifest else {
            refuseRequest(connection, statusCode: 404, body: "Route unavailable", reason: "validated-manifest-absent")
            return
        }

        let rewritten: Data?
        let contentType: String
        switch accepted.kind {
        case .hls:
            rewritten = rewriteValidatedHLS(
                accepted.bytes,
                sourceURL: resource.targetURL,
                policy: policy,
                sessionId: sessionId
            )
            contentType = "application/vnd.apple.mpegurl"
        case .dash:
            rewritten = rewriteValidatedDASH(
                accepted.bytes,
                sourceURL: resource.targetURL,
                policy: policy,
                sessionId: sessionId
            )
            contentType = "application/dash+xml"
        }

        guard let rewritten, rewritten.count <= maxValidatedRewrittenBodyBytes else {
            refuseRequest(connection, statusCode: 502, body: "Validated manifest unavailable", reason: "validated-manifest-unrewritable", detail: "cap=\(maxValidatedRewrittenBodyBytes)")
            return
        }
        let headers = [
            "Content-Type": contentType,
            "Content-Length": String(rewritten.count),
            "Cache-Control": "no-store"
        ]
        sendResponse(
            connection,
            statusCode: 200,
            headers: headers,
            body: method == "HEAD" ? Data() : rewritten
        )
#else
        sendSimpleResponse(connection, statusCode: 404, body: "Route unavailable")
#endif
    }

#if os(iOS)
    private func rewriteValidatedHLS(
        _ data: Data,
        sourceURL: URL?,
        policy: ValidatedRoutePolicy,
        sessionId: String
    ) -> Data? {
        guard data.count <= maxValidatedManifestBytes,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard lines.count <= 20_000 else { return nil }

        var output: [String] = []
        output.reserveCapacity(lines.count)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.utf8.count <= 16_384 else { return nil }
            if trimmed.isEmpty {
                output.append(line)
            } else if trimmed.hasPrefix("#") {
                guard let rewritten = rewriteValidatedHLSAttributes(
                    in: line,
                    sourceURL: sourceURL,
                    policy: policy,
                    sessionId: sessionId
                ) else { return nil }
                output.append(rewritten)
            } else {
                guard let localURL = validatedProxyURL(
                    forHLSReference: trimmed,
                    relativeTo: sourceURL,
                    policy: policy,
                    sessionId: sessionId
                ) else { return nil }
                output.append(localURL.absoluteString)
            }
        }
        let bytes = Data(output.joined(separator: "\n").utf8)
        return bytes.count <= maxValidatedRewrittenBodyBytes ? bytes : nil
    }

    private func rewriteValidatedHLSAttributes(
        in line: String,
        sourceURL: URL?,
        policy: ValidatedRoutePolicy,
        sessionId: String
    ) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return line }
        var replacements: [(Range<String.Index>, String)] = []
        var cursor = line.index(after: colon)

        while cursor < line.endIndex {
            while cursor < line.endIndex,
                  line[cursor].isWhitespace || line[cursor] == "," {
                cursor = line.index(after: cursor)
            }
            guard cursor < line.endIndex else { break }

            let keyStart = cursor
            while cursor < line.endIndex,
                  !line[cursor].isWhitespace,
                  line[cursor] != "=",
                  line[cursor] != "," {
                cursor = line.index(after: cursor)
            }
            let key = String(line[keyStart..<cursor]).uppercased()
            while cursor < line.endIndex, line[cursor].isWhitespace {
                cursor = line.index(after: cursor)
            }
            guard cursor < line.endIndex, line[cursor] == "=" else {
                while cursor < line.endIndex, line[cursor] != "," {
                    cursor = line.index(after: cursor)
                }
                continue
            }
            cursor = line.index(after: cursor)
            while cursor < line.endIndex, line[cursor].isWhitespace {
                cursor = line.index(after: cursor)
            }
            guard cursor < line.endIndex else { return nil }

            let valueStart: String.Index
            let valueEnd: String.Index
            if line[cursor] == "\"" {
                valueStart = line.index(after: cursor)
                guard let closingQuote = line[valueStart...].firstIndex(of: "\"") else { return nil }
                valueEnd = closingQuote
                cursor = line.index(after: closingQuote)
            } else {
                valueStart = cursor
                valueEnd = line[cursor...].firstIndex(of: ",") ?? line.endIndex
                cursor = valueEnd
            }

            if key == "URI" {
                let reference = String(line[valueStart..<valueEnd])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !reference.isEmpty,
                      let localURL = validatedProxyURL(
                        forHLSReference: reference,
                        relativeTo: sourceURL,
                        policy: policy,
                        sessionId: sessionId
                      ) else { return nil }
                replacements.append((valueStart..<valueEnd, localURL.absoluteString))
            }
        }

        var output = line
        for replacement in replacements.reversed() {
            output.replaceSubrange(replacement.0, with: replacement.1)
        }
        return output
    }

    private func validatedProxyURL(
        forHLSReference reference: String,
        relativeTo sourceURL: URL?,
        policy: ValidatedRoutePolicy,
        sessionId: String
    ) -> URL? {
        let decoded: SkyStreamDecodedStreamPayload
        do {
            decoded = try SkyStreamMagicProxyDecoder.decode(reference)
        } catch {
            return nil
        }

        let resource: ValidatedRouteResource?
        switch decoded {
        case .generatedHLS(let bytes, _, _):
            resource = policy.resource(forGeneratedManifest: bytes)
        case .remote(let rawURL, _, _):
            guard let resolved = validatedRemoteReference(
                rawURL,
                relativeTo: sourceURL,
                policy: policy
            ) else { return nil }
            resource = policy.resource(forRemoteURL: resolved)
        }
        guard let resource else { return nil }
        return buildValidatedProxyURL(port: port, sessionId: sessionId, routeID: resource.routeID)
    }

    private func rewriteValidatedDASH(
        _ data: Data,
        sourceURL: URL?,
        policy: ValidatedRoutePolicy,
        sessionId: String
    ) -> Data? {
        guard data.count <= maxValidatedManifestBytes,
              let sourceURL,
              let text = String(data: data, encoding: .utf8) else { return nil }

        let collector = ValidatedDASHBaseCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), parser.parserError == nil, collector.values.count <= 8 else { return nil }

        let validatedBases = collector.values.compactMap {
            validatedRemoteReference($0, relativeTo: sourceURL, policy: policy)
        }
        guard validatedBases.count == collector.values.filter({ !$0.isEmpty }).count else { return nil }
        let referenceBases = validatedBases + [sourceURL]

        var output = ""
        output.reserveCapacity(min(maxValidatedRewrittenBodyBytes, text.utf8.count + 16_384))
        var cursor = text.startIndex
        var insideBaseURL = false

        while cursor < text.endIndex {
            guard let opening = text[cursor...].firstIndex(of: "<") else {
                let tail = String(text[cursor...])
                if insideBaseURL {
                    guard let rewritten = rewriteValidatedDASHBaseText(
                        tail,
                        sourceURL: sourceURL,
                        policy: policy,
                        sessionId: sessionId
                    ) else { return nil }
                    output += rewritten
                } else {
                    output += tail
                }
                break
            }

            let plainText = String(text[cursor..<opening])
            if insideBaseURL {
                guard let rewritten = rewriteValidatedDASHBaseText(
                    plainText,
                    sourceURL: sourceURL,
                    policy: policy,
                    sessionId: sessionId
                ) else { return nil }
                output += rewritten
            } else {
                output += plainText
            }

            if text[opening...].hasPrefix("<!--") {
                guard !insideBaseURL,
                      let end = text.range(of: "-->", range: opening..<text.endIndex)?.upperBound else {
                    return nil
                }
                output += String(text[opening..<end])
                cursor = end
                continue
            }
            if text[opening...].hasPrefix("<![CDATA[") {

                guard !insideBaseURL,
                      let end = text.range(of: "]]>", range: opening..<text.endIndex)?.upperBound else {
                    return nil
                }
                output += String(text[opening..<end])
                cursor = end
                continue
            }

            guard let tagEnd = endOfXMLTag(in: text, startingAt: opening) else { return nil }
            let afterTag = text.index(after: tagEnd)
            let originalTag = String(text[opening..<afterTag])
            let tagInfo = xmlTagInfo(originalTag)
            guard let tagInfo else { return nil }

            if tagInfo.isClosing {
                output += originalTag
                if tagInfo.localName == "baseurl" { insideBaseURL = false }
            } else {
                guard let rewrittenTag = rewriteValidatedDASHAttributes(
                    in: originalTag,
                    localElementName: tagInfo.localName,
                    referenceBases: referenceBases,
                    policy: policy,
                    sessionId: sessionId
                ) else { return nil }
                output += rewrittenTag
                if tagInfo.localName == "baseurl", !tagInfo.isSelfClosing {
                    guard !insideBaseURL else { return nil }
                    insideBaseURL = true
                }
            }
            guard output.utf8.count <= maxValidatedRewrittenBodyBytes else { return nil }
            cursor = afterTag
        }

        guard !insideBaseURL else { return nil }
        let bytes = Data(output.utf8)
        return bytes.count <= maxValidatedRewrittenBodyBytes ? bytes : nil
    }

    private func rewriteValidatedDASHBaseText(
        _ text: String,
        sourceURL: URL,
        policy: ValidatedRoutePolicy,
        sessionId: String
    ) -> String? {
        let leading = text.prefix { $0.isWhitespace }
        let trailing = text.reversed().prefix { $0.isWhitespace }.reversed()
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty,
              let decoded = decodeXMLReference(raw),
              let remoteURL = validatedRemoteReference(decoded, relativeTo: sourceURL, policy: policy),
              let resource = policy.resource(forRemoteURL: remoteURL),
              let localURL = buildValidatedProxyURL(
                port: port,
                sessionId: sessionId,
                routeID: resource.routeID
              ) else { return nil }
        return String(leading) + escapeXMLText(localURL.absoluteString) + String(trailing)
    }

    private struct XMLTagInfo {
        let localName: String
        let isClosing: Bool
        let isSelfClosing: Bool
    }

    private func xmlTagInfo(_ tag: String) -> XMLTagInfo? {
        guard tag.first == "<", tag.last == ">" else { return nil }
        if tag.hasPrefix("<?") || tag.hasPrefix("<!") {
            return XMLTagInfo(localName: "", isClosing: false, isSelfClosing: true)
        }
        var body = tag.dropFirst().dropLast()
        let isClosing = body.first == "/"
        if isClosing { body = body.dropFirst() }
        body = body.drop(while: { $0.isWhitespace })
        guard let nameEnd = body.firstIndex(where: { $0.isWhitespace || $0 == "/" }),
              nameEnd > body.startIndex else {
            let name = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return XMLTagInfo(
                localName: name.split(separator: ":").last?.lowercased() ?? "",
                isClosing: isClosing,
                isSelfClosing: body.hasSuffix("/")
            )
        }
        let name = String(body[..<nameEnd])
        return XMLTagInfo(
            localName: name.split(separator: ":").last?.lowercased() ?? "",
            isClosing: isClosing,
            isSelfClosing: body.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/")
        )
    }

    private func endOfXMLTag(in text: String, startingAt start: String.Index) -> String.Index? {
        var index = text.index(after: start)
        var quote: Character?
        while index < text.endIndex {
            let character = text[index]
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    private func rewriteValidatedDASHAttributes(
        in tag: String,
        localElementName: String,
        referenceBases: [URL],
        policy: ValidatedRoutePolicy,
        sessionId: String
    ) -> String? {
        guard !localElementName.isEmpty else { return tag }
        var replacements: [(Range<String.Index>, String)] = []
        var index = tag.index(after: tag.startIndex)
        while index < tag.endIndex {
            while index < tag.endIndex, tag[index].isWhitespace { index = tag.index(after: index) }
            if index >= tag.endIndex || tag[index] == ">" || tag[index] == "/" { break }
            let nameStart = index
            while index < tag.endIndex,
                  !tag[index].isWhitespace,
                  tag[index] != "=",
                  tag[index] != ">" {
                index = tag.index(after: index)
            }
            let rawName = String(tag[nameStart..<index])
            while index < tag.endIndex, tag[index].isWhitespace { index = tag.index(after: index) }
            guard index < tag.endIndex, tag[index] == "=" else {

                continue
            }
            index = tag.index(after: index)
            while index < tag.endIndex, tag[index].isWhitespace { index = tag.index(after: index) }
            guard index < tag.endIndex, tag[index] == "\"" || tag[index] == "'" else { return nil }
            let quote = tag[index]
            let valueStart = tag.index(after: index)
            guard let valueEnd = tag[valueStart...].firstIndex(of: quote) else { return nil }
            let localAttributeName = rawName.split(separator: ":").last?.lowercased() ?? ""
            let isReference: Bool
            if localAttributeName == "href" {

                isReference = true
            } else {
                switch localElementName {
                case "segmenturl":
                    isReference = localAttributeName == "media" || localAttributeName == "index"
                case "initialization":
                    isReference = localAttributeName == "sourceurl"
                case "segmenttemplate":
                    isReference = localAttributeName == "media"
                        || localAttributeName == "initialization"
                        || localAttributeName == "index"
                default: isReference = false
                }
            }
            if isReference {
                let encoded = String(tag[valueStart..<valueEnd])
                guard let decoded = decodeXMLReference(encoded), !decoded.contains("$"),
                      let remoteURL = referenceBases.lazy.compactMap({ base in
                        self.validatedRemoteReference(decoded, relativeTo: base, policy: policy)
                      }).first,
                      let resource = policy.resource(forRemoteURL: remoteURL),
                      let localURL = buildValidatedProxyURL(
                        port: port,
                        sessionId: sessionId,
                        routeID: resource.routeID
                      ) else { return nil }
                replacements.append((valueStart..<valueEnd, escapeXMLAttribute(localURL.absoluteString, quote: quote)))
            }
            index = tag.index(after: valueEnd)
        }

        var output = tag
        for replacement in replacements.reversed() {
            output.replaceSubrange(replacement.0, with: replacement.1)
        }
        return output
    }

    private func validatedRemoteReference(
        _ rawValue: String,
        relativeTo baseURL: URL?,
        policy: ValidatedRoutePolicy
    ) -> URL? {
        guard let resolved = URL(string: rawValue, relativeTo: baseURL)?.absoluteURL,
              let scheme = resolved.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              resolved.user == nil,
              resolved.password == nil else { return nil }
        if baseURL?.scheme?.lowercased() == "https", scheme != "https" { return nil }
        var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        guard let canonical = components?.url,
              policy.resource(forRemoteURL: canonical) != nil else { return nil }
        return canonical
    }

    private func decodeXMLReference(_ value: String) -> String? {
        var output = ""
        var cursor = value.startIndex
        while cursor < value.endIndex {
            guard value[cursor] == "&" else {
                output.append(value[cursor])
                cursor = value.index(after: cursor)
                continue
            }
            guard let semicolon = value[cursor...].firstIndex(of: ";") else { return nil }
            let entityStart = value.index(after: cursor)
            let entity = String(value[entityStart..<semicolon])
            let scalar: UnicodeScalar?
            switch entity {
            case "amp": scalar = "&"
            case "quot": scalar = "\""
            case "apos": scalar = "'"
            case "lt": scalar = "<"
            case "gt": scalar = ">"
            default:
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    scalar = UInt32(entity.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init)
                } else if entity.hasPrefix("#") {
                    scalar = UInt32(entity.dropFirst()).flatMap(UnicodeScalar.init)
                } else {
                    scalar = nil
                }
            }
            guard let scalar,
                  scalar.value >= 32,
                  scalar.value != 127 else { return nil }
            output.unicodeScalars.append(scalar)
            cursor = value.index(after: semicolon)
        }
        return output
    }

    private func escapeXMLText(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func escapeXMLAttribute(_ value: String, quote: Character) -> String {
        var escaped = escapeXMLText(value)
        if quote == "\"" {
            escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
        } else {
            escaped = escaped.replacingOccurrences(of: "'", with: "&apos;")
        }
        return escaped
    }
#endif

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

    private func emptyResponseHeaders(from http: HTTPURLResponse) -> [String: String] {
        var headers = filteredResponseHeaders(from: http)
        removeHeader("Content-Length", from: &headers)
        removeHeader("Content-Encoding", from: &headers)
        headers["Content-Length"] = "0"
        return headers
    }

    private func sendResponse(_ connection: NWConnection, statusCode: Int, headers: [String: String], body: Data) {
        let headerData = responseHeaderData(statusCode: statusCode, headers: headers)
        let responseData = headerData + body

        if gracefulResponseClose {
            connection.send(content: responseData, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } else {
            connection.send(content: responseData, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func sendResponseHeaders(_ connection: NWConnection, statusCode: Int, headers: [String: String], completion: @escaping (NWError?) -> Void) {
        sendData(responseHeaderData(statusCode: statusCode, headers: headers), on: connection, completion: completion)
    }

    private func sendResponseStart(_ connection: NWConnection, statusCode: Int, headers: [String: String], body: Data, completion: @escaping (NWError?) -> Void) {
        sendData(responseHeaderData(statusCode: statusCode, headers: headers) + body, on: connection, completion: completion)
    }

    private func sendData(_ data: Data, on connection: NWConnection, completion: @escaping (NWError?) -> Void) {
        guard !data.isEmpty else {
            completion(nil)
            return
        }
        connection.send(content: data, completion: .contentProcessed(completion))
    }

    private func finishResponse(on connection: NWConnection) {
        if gracefulResponseClose {
            connection.send(content: nil, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } else {
            connection.cancel()
        }
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
        case 429: return "Too Many Requests"
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

    private func buildValidatedProxyURL(port: UInt16?, sessionId: String, routeID: String) -> URL? {
        guard let port, port > 0,
              !sessionId.isEmpty,
              !routeID.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/proxy/\(sessionId)"
        components.queryItems = [
            URLQueryItem(name: "route", value: routeID),
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

    func invalidateSession(for proxyURL: URL) {
        guard let sessionID = managedSessionID(from: proxyURL) else { return }
        let removed = withSessionsLock {
            sessions.removeValue(forKey: sessionID)
        }
        removed?.upstreamTransport.invalidateAndCancel()
    }

    func originalTargetURL(for proxyURL: URL) -> URL? {
        guard let sessionID = managedSessionID(from: proxyURL),
              withSessionsLock({ sessions[sessionID] != nil }),
              let components = URLComponents(url: proxyURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let pathParts = components.path.split(separator: "/")
        let queryItems = components.queryItems ?? []
        guard pathParts.count == 2,
              queryItems.filter({ $0.name == "url" }).count == 1,
              queryItems.filter({ $0.name == "token" }).count == 1,
              queryItems.allSatisfy({ $0.name == "url" || $0.name == "token" }),
              let encoded = queryItems.first(where: { $0.name == "url" })?.value else {
            return nil
        }
        return decodeTargetURL(encoded)
    }

    func upstreamHealth(for proxyURL: URL) -> MPVHeaderProxyUpstreamHealth? {
        guard let sessionID = managedSessionID(from: proxyURL) else { return nil }
        let transport = withSessionsLock { sessions[sessionID]?.upstreamTransport }
        return transport?.upstreamHealthSnapshot()
    }

    func upstreamProbeTarget(for proxyURL: URL) -> (url: URL, headers: [String: String])? {
        guard let target = originalTargetURL(for: proxyURL),
              let sessionID = managedSessionID(from: proxyURL),
              let headers = withSessionsLock({ sessions[sessionID]?.headers }) else {
            return nil
        }
        return (target, headers)
    }

    private func managedSessionID(from proxyURL: URL) -> String? {
        guard let components = URLComponents(url: proxyURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "http",
              components.host == "127.0.0.1" else {
            return nil
        }

        let pathParts = components.path.split(separator: "/")
        guard pathParts.count >= 2,
              pathParts[0] == "proxy",
              components.queryItems?.first(where: { $0.name == "token" })?.value == token else {
            return nil
        }
        return String(pathParts[1])
    }

    private func cleanupExpiredSessions() {
        let now = Date()
        let expired = withSessionsLock {
            let expiredIDs = sessions.compactMap { id, session in
                now.timeIntervalSince(session.lastAccessed) >= sessionTTL ? id : nil
            }
            return expiredIDs.compactMap { sessions.removeValue(forKey: $0) }
        }
        for session in expired {
            session.upstreamTransport.invalidateAndCancel()
        }
    }

    private func cleanupOldestSessions() {
        let removed = withSessionsLock {
            let sorted = sessions.sorted { $0.value.lastAccessed < $1.value.lastAccessed }
            let removeCount = max(0, sessions.count - maxSessions + 1)
            if removeCount == 0 {
                return [Session]()
            }

            return (0..<removeCount).compactMap { idx in
                sessions.removeValue(forKey: sorted[idx].key)
            }
        }
        for session in removed {
            session.upstreamTransport.invalidateAndCancel()
        }
    }

    private func setValidatedSession(_ newSession: Session, for sessionID: String) -> Bool {
        let incomingBytes = newSession.validatedRoutePolicy?.acceptedManifestByteCount ?? 0
        guard incomingBytes >= 0, incomingBytes <= maxAggregateValidatedManifestBytes else {
            return false
        }
        var removed: [Session] = []
        let fits = withSessionsLock { () -> Bool in
            var total = sessions.values.reduce(0) {
                $0 + ($1.validatedRoutePolicy?.acceptedManifestByteCount ?? 0)
            }
            guard total <= maxAggregateValidatedManifestBytes else { return false }
            if total + incomingBytes <= maxAggregateValidatedManifestBytes {
                sessions[sessionID] = newSession
                return true
            }

            let candidates = sessions
                .filter { $0.value.validatedRoutePolicy != nil }
                .sorted { $0.value.lastAccessed < $1.value.lastAccessed }
            for candidate in candidates {
                guard total + incomingBytes > maxAggregateValidatedManifestBytes else { break }
                if let session = sessions.removeValue(forKey: candidate.key) {
                    total -= session.validatedRoutePolicy?.acceptedManifestByteCount ?? 0
                    removed.append(session)
                }
            }
            guard total + incomingBytes <= maxAggregateValidatedManifestBytes else { return false }
            sessions[sessionID] = newSession
            return true
        }
        for session in removed {
            session.upstreamTransport.invalidateAndCancel()
        }
        return fits
    }

    private final class PinnedAddressURLProtocol: URLProtocol {
        private static let approvedAddressesKey = "app.eclipse.mpv-proxy.approved-addresses.v1"
        private static let poolNamespaceKey = "app.eclipse.mpv-proxy.pool-namespace.v1"
        private static let permitsPrivateApprovedAddressesKey =
            "app.eclipse.mpv-proxy.permits-private-approved-addresses.v1"
        private static let maximumResponseHeaderBytes = 128 * 1_024
        private static let maximumChunkMetadataBytes = 64 * 1_024
        private static let connectionSetupTimeout: TimeInterval = 15
        private static let waitingConnectionTimeout: TimeInterval = 3
        private static let reuseIdleTimeout: TimeInterval = 30
        private static let maximumParkedConnections = 8
        private static let headerTerminator = Data([13, 10, 13, 10])
        private static let lineTerminator = Data([13, 10])

        private enum BodyFraming {
            case none
            case contentLength(Int64)
            case chunked
            case untilClose
        }

        private struct ParkedConnection {
            let connection: NWConnection
            let key: String
            let parkedAt: Date
            let parkingID: UUID
        }

        private static let poolQueue = DispatchQueue(label: "app.eclipse.mpv-proxy.pinned-http.pool")
        private static var parkedConnections: [ParkedConnection] = []

        private static func poolKey(
            namespace: String,
            scheme: String,
            address: String,
            port: UInt16,
            host: String
        ) -> String {
            "\(namespace)|\(scheme)|\(host.lowercased())|\(address)|\(port)"
        }

        private static func checkOutParkedConnection(forKey key: String) -> NWConnection? {
            poolQueue.sync {
                while let index = parkedConnections.lastIndex(where: { $0.key == key }) {
                    let parked = parkedConnections.remove(at: index)
                    let isFresh = Date().timeIntervalSince(parked.parkedAt) < reuseIdleTimeout
                    if isFresh, case .ready = parked.connection.state {
                        return parked.connection
                    }
                    parked.connection.cancel()
                }
                return nil
            }
        }

        private static func park(_ connection: NWConnection, forKey key: String) {
            poolQueue.async {
                let parkingID = UUID()
                parkedConnections.append(
                    ParkedConnection(
                        connection: connection,
                        key: key,
                        parkedAt: Date(),
                        parkingID: parkingID
                    )
                )
                if parkedConnections.count > maximumParkedConnections {
                    parkedConnections.removeFirst().connection.cancel()
                }
                poolQueue.asyncAfter(deadline: .now() + reuseIdleTimeout) { [weak connection] in
                    guard let connection,
                          let index = parkedConnections.firstIndex(where: {
                              $0.connection === connection && $0.parkingID == parkingID
                          }) else {
                        return
                    }
                    parkedConnections.remove(at: index)
                    connection.cancel()
                }
            }
        }

        private final class BodyInflater {
            private enum Coding {
                case gzip
                case deflate
            }

            private let coding: Coding
            private var stream = z_stream()
            private var streamActive = false
            private var streamEnded = false
            private var deflateSniffBuffer = Data()
            private let maximumOutputBytesPerOperation = 8 * 1_024 * 1_024
            private let maximumExpansionRatio = 256
            private let expansionAllowanceBytes = 1 * 1_024 * 1_024
            private var totalInputBytes = 0
            private var totalOutputBytes = 0

            init?(contentCoding: String) {
                switch contentCoding {
                case "gzip", "x-gzip":
                    coding = .gzip
                case "deflate":
                    coding = .deflate
                default:
                    return nil
                }
            }

            deinit {
                if streamActive {
                    inflateEnd(&stream)
                }
            }

            func feed(_ data: Data) -> Data? {
                guard !streamEnded else { return data.isEmpty ? Data() : nil }
                guard recordInputBytes(data.count) else { return nil }
                var input = data
                if !streamActive {
                    if coding == .deflate {
                        deflateSniffBuffer.append(input)
                        guard deflateSniffBuffer.count >= 2 else { return Data() }
                        input = deflateSniffBuffer
                        deflateSniffBuffer = Data()
                    }
                    guard beginStream(firstBytes: input) else { return nil }
                }
                guard !input.isEmpty else { return Data() }
                var output = Data()
                let succeeded = input.withUnsafeBytes { rawBuffer -> Bool in
                    guard let baseAddress = rawBuffer.bindMemory(to: Bytef.self).baseAddress else {
                        return false
                    }
                    stream.next_in = UnsafeMutablePointer<Bytef>(mutating: baseAddress)
                    stream.avail_in = uInt(input.count)
                    let chunkSize = 64 * 1_024
                    var chunk = [UInt8](repeating: 0, count: chunkSize)
                    while stream.avail_in > 0, !streamEnded {
                        var status: Int32 = Z_OK
                        chunk.withUnsafeMutableBufferPointer { buffer in
                            stream.next_out = buffer.baseAddress
                            stream.avail_out = uInt(chunkSize)
                            status = inflate(&stream, Z_NO_FLUSH)
                            let written = chunkSize - Int(stream.avail_out)
                            if let outputBase = buffer.baseAddress, written > 0 {
                                guard output.count <= maximumOutputBytesPerOperation - written,
                                      recordOutputBytes(written) else {
                                    status = Z_MEM_ERROR
                                    return
                                }
                                output.append(outputBase, count: written)
                            }
                        }
                        if status == Z_STREAM_END {
                            guard stream.avail_in == 0 else { return false }
                            streamEnded = true
                            break
                        }
                        if status == Z_BUF_ERROR, stream.avail_in == 0 {
                            break
                        }
                        guard status == Z_OK else { return false }
                    }
                    return true
                }
                return succeeded ? output : nil
            }

            func finish() -> Data? {
                guard streamActive, !streamEnded else {
                    return streamEnded ? Data() : nil
                }

                var output = Data()
                let chunkSize = 64 * 1_024
                var chunk = [UInt8](repeating: 0, count: chunkSize)
                while !streamEnded {
                    var status: Int32 = Z_OK
                    chunk.withUnsafeMutableBufferPointer { buffer in
                        stream.next_in = nil
                        stream.avail_in = 0
                        stream.next_out = buffer.baseAddress
                        stream.avail_out = uInt(chunkSize)
                        status = inflate(&stream, Z_FINISH)
                        let written = chunkSize - Int(stream.avail_out)
                        if let outputBase = buffer.baseAddress, written > 0 {
                            guard output.count <= maximumOutputBytesPerOperation - written,
                                  recordOutputBytes(written) else {
                                status = Z_MEM_ERROR
                                return
                            }
                            output.append(outputBase, count: written)
                        }
                    }
                    if status == Z_STREAM_END {
                        streamEnded = true
                        break
                    }
                    guard status == Z_OK else { return nil }
                }
                return output
            }

            private func recordInputBytes(_ count: Int) -> Bool {
                let (next, overflow) = totalInputBytes.addingReportingOverflow(count)
                guard !overflow else { return false }
                totalInputBytes = next
                return true
            }

            private func recordOutputBytes(_ count: Int) -> Bool {
                let (nextOutput, outputOverflow) = totalOutputBytes.addingReportingOverflow(count)
                let (scaledInput, ratioOverflow) = totalInputBytes.multipliedReportingOverflow(
                    by: maximumExpansionRatio
                )
                let (limit, allowanceOverflow) = scaledInput.addingReportingOverflow(
                    expansionAllowanceBytes
                )
                guard !outputOverflow, !ratioOverflow, !allowanceOverflow,
                      nextOutput <= limit else { return false }
                totalOutputBytes = nextOutput
                return true
            }

            private func beginStream(firstBytes: Data) -> Bool {
                let windowBits: Int32
                switch coding {
                case .gzip:
                    windowBits = 15 + 16
                case .deflate:
                    let bytes = [UInt8](firstBytes.prefix(2))
                    let looksLikeZlib = bytes.count >= 2
                        && (Int(bytes[0]) & 0x0F) == 8
                        && ((Int(bytes[0]) << 8) | Int(bytes[1])) % 31 == 0
                    windowBits = looksLikeZlib ? 15 : -15
                }
                let status = inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
                guard status == Z_OK else { return false }
                streamActive = true
                return true
            }
        }

        private let stateQueue = DispatchQueue(
            label: "app.eclipse.mpv-proxy.pinned-http.connection.\(UUID().uuidString)",
            qos: .userInitiated
        )
        private var approvedAddresses: [String] = []
        private var poolNamespace = ""
        private var nextAddressIndex = 0
        private var connection: NWConnection?
        private var connectionReachedReady = false
        private var connectionWaitingDeadlineScheduled = false
        private var receiveBuffer = Data()
        private var responseDelivered = false
        private var bodyFraming: BodyFraming = .untilClose
        private var chunkBytesRemaining: Int?
        private var awaitingChunkTerminator = false
        private var readingChunkTrailers = false
        private var stopped = false
        private var finished = false
        private var reusedConnection = false
        private var currentPoolKey: String?
        private var responseAllowsReuse = false
        private var anyBytesReceived = false
        private var bodyInflater: BodyInflater?

        static func requestByPinning(
            _ request: URLRequest,
            to rawAddresses: [String],
            poolNamespace: String,
            permitsPrivateApprovedAddresses: Bool
        ) -> URLRequest? {
            var seen = Set<String>()
            let addresses = rawAddresses.compactMap {
                MPVHeaderProxyPinnedAddressPolicy.normalizeApprovedAddress(
                    $0,
                    permitsPrivateApprovedAddresses: permitsPrivateApprovedAddresses
                )
            }
                .filter { seen.insert($0).inserted }
            guard !addresses.isEmpty, !poolNamespace.isEmpty,
                  let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
                return nil
            }
            URLProtocol.setProperty(addresses, forKey: approvedAddressesKey, in: mutable)
            URLProtocol.setProperty(poolNamespace, forKey: poolNamespaceKey, in: mutable)
            URLProtocol.setProperty(
                permitsPrivateApprovedAddresses,
                forKey: permitsPrivateApprovedAddressesKey,
                in: mutable
            )
            return mutable as URLRequest
        }

        override class func canInit(with request: URLRequest) -> Bool {

            guard let scheme = request.url?.scheme?.lowercased() else { return false }
            return scheme == "http" || scheme == "https"
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            stateQueue.async { [weak self] in
                self?.startLoadingOnQueue()
            }
        }

        override func stopLoading() {
            stateQueue.async { [weak self] in
                guard let self else { return }
                self.stopped = true
                self.tearDownConnection()
            }
        }

        private func startLoadingOnQueue() {
            guard !stopped, !finished,
                  let url = request.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = url.host,
                  let rawAddresses = URLProtocol.property(
                    forKey: Self.approvedAddressesKey,
                    in: request
                  ) as? [String],
                  let requestPoolNamespace = URLProtocol.property(
                    forKey: Self.poolNamespaceKey,
                    in: request
                  ) as? String,
                  !requestPoolNamespace.isEmpty else {
                fail(.unsupportedURL)
                return
            }
            guard request.httpBody == nil, request.httpBodyStream == nil else {
                fail(.dataLengthExceedsMaximum)
                return
            }

            var seen = Set<String>()
            let permitsPrivateApprovedAddresses = URLProtocol.property(
                forKey: Self.permitsPrivateApprovedAddressesKey,
                in: request
            ) as? Bool ?? false
            approvedAddresses = rawAddresses.compactMap {
                MPVHeaderProxyPinnedAddressPolicy.normalizeApprovedAddress(
                    $0,
                    permitsPrivateApprovedAddresses: permitsPrivateApprovedAddresses
                )
            }
                .filter { seen.insert($0).inserted }
            poolNamespace = requestPoolNamespace
            guard !approvedAddresses.isEmpty,
                  !host.isEmpty,
                  serializedRequest(for: url) != nil else {
                fail(.badURL)
                return
            }
            if let parked = checkOutPooledConnection() {
                adoptReusedConnection(parked)
                return
            }
            startNextConnection()
        }

        private func checkOutPooledConnection() -> NWConnection? {
            guard let url = request.url,
                  let scheme = url.scheme?.lowercased(),
                  let host = url.host,
                  let port = Self.port(for: url, scheme: scheme) else {
                return nil
            }
            for address in approvedAddresses {
                let key = Self.poolKey(
                    namespace: poolNamespace,
                    scheme: scheme,
                    address: address,
                    port: port.rawValue,
                    host: host
                )
                if let parked = Self.checkOutParkedConnection(forKey: key) {
                    currentPoolKey = key
                    return parked
                }
            }
            return nil
        }

        private func adoptReusedConnection(_ connection: NWConnection) {
            reusedConnection = true
            connectionReachedReady = true
            self.connection = connection
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection else { return }
                self.stateQueue.async { [weak self, weak connection] in
                    guard let self, let connection, self.connection === connection,
                          !self.stopped, !self.finished else { return }
                    if case .failed = state {
                        self.handleTransportFailure()
                    }
                }
            }
            sendRequest(on: connection)
        }

        private var canRetryWithFreshConnection: Bool {
            reusedConnection && !anyBytesReceived && !stopped && !finished
        }

        private func handleTransportFailure() {
            if canRetryWithFreshConnection {
                retryWithFreshConnection()
            } else {
                fail(.networkConnectionLost)
            }
        }

        private func retryWithFreshConnection() {
            reusedConnection = false
            responseAllowsReuse = false
            currentPoolKey = nil
            tearDownConnection()
            receiveBuffer.removeAll(keepingCapacity: false)
            startNextConnection()
        }

        private func startNextConnection() {
            guard !stopped, !finished, nextAddressIndex < approvedAddresses.count,
                  let url = request.url,
                  let scheme = url.scheme?.lowercased(),
                  let host = url.host else {
                fail(.cannotConnectToHost)
                return
            }
            let address = approvedAddresses[nextAddressIndex]
            nextAddressIndex += 1
            guard let endpointHost = Self.numericEndpointHost(address),
                  let port = Self.port(for: url, scheme: scheme) else {
                startNextConnection()
                return
            }
            reusedConnection = false
            currentPoolKey = Self.poolKey(
                namespace: poolNamespace,
                scheme: scheme,
                address: address,
                port: port.rawValue,
                host: host
            )

            let parameters: NWParameters
            if scheme == "https" {
                let tls = NWProtocolTLS.Options()
                sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
                sec_protocol_options_add_tls_application_protocol(
                    tls.securityProtocolOptions,
                    "http/1.1"
                )
                let trustQueue = stateQueue
                sec_protocol_options_set_verify_block(
                    tls.securityProtocolOptions,
                    { _, trust, complete in
                        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                        let policy = SecPolicyCreateSSL(true, host as CFString)
                        guard SecTrustSetPolicies(secTrust, policy) == errSecSuccess else {
                            complete(false)
                            return
                        }
                        complete(SecTrustEvaluateWithError(secTrust, nil))
                    },
                    trustQueue
                )
                parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            } else {
                parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
            }

            connectionReachedReady = false
            connectionWaitingDeadlineScheduled = false
            let connection = NWConnection(host: endpointHost, port: port, using: parameters)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection else { return }
                self.stateQueue.async { [weak self, weak connection] in
                    guard let self, let connection, self.connection === connection,
                          !self.stopped, !self.finished else { return }
                    switch state {
                    case .ready:
                        self.connectionReachedReady = true
                        self.sendRequest(on: connection)
                    case .failed:
                        self.handleConnectionFailure()
                    case .waiting:

                        guard !self.connectionWaitingDeadlineScheduled,
                              !self.connectionReachedReady,
                              self.nextAddressIndex < self.approvedAddresses.count else { break }
                        self.connectionWaitingDeadlineScheduled = true
                        self.scheduleSetupDeadline(
                            for: connection,
                            after: Self.waitingConnectionTimeout
                        )
                    case .cancelled:
                        break
                    default:
                        break
                    }
                }
            }
            scheduleSetupDeadline(for: connection, after: Self.connectionSetupTimeout)
            connection.start(queue: stateQueue)
        }

        private func handleConnectionFailure() {
            if !connectionReachedReady, nextAddressIndex < approvedAddresses.count {
                tearDownConnection()
                startNextConnection()
            } else {
                fail(.cannotConnectToHost)
            }
        }

        private func scheduleSetupDeadline(for connection: NWConnection, after interval: TimeInterval) {
            stateQueue.asyncAfter(deadline: .now() + interval) { [weak self, weak connection] in
                guard let self, let connection, self.connection === connection,
                      !self.stopped, !self.finished, !self.connectionReachedReady else { return }
                self.handleConnectionFailure()
            }
        }

        private func sendRequest(on connection: NWConnection) {
            guard let url = request.url, let bytes = serializedRequest(for: url) else {
                fail(.badURL)
                return
            }
            connection.send(content: bytes, completion: .contentProcessed { [weak self, weak connection] error in
                guard let self, let connection else { return }
                self.stateQueue.async { [weak self, weak connection] in
                    guard let self, let connection, self.connection === connection,
                          !self.stopped, !self.finished else { return }
                    if error != nil {
                        self.handleTransportFailure()
                    } else {
                        self.receiveNext(on: connection)
                    }
                }
            })
        }

        private func receiveNext(on connection: NWConnection) {
            guard !stopped, !finished, self.connection === connection else { return }
            if task?.state == .suspended {
                stateQueue.asyncAfter(deadline: .now() + 0.05) { [weak self, weak connection] in
                    guard let self, let connection else { return }
                    self.receiveNext(on: connection)
                }
                return
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
                [weak self, weak connection] content, _, isComplete, error in
                guard let self, let connection else { return }
                self.stateQueue.async { [weak self, weak connection] in
                    guard let self, let connection, self.connection === connection,
                          !self.stopped, !self.finished else { return }
                    if let content, !content.isEmpty {
                        self.anyBytesReceived = true
                        self.receiveBuffer.append(content)
                        guard self.consumeAvailableBytes() else { return }
                    }
                    if error != nil {
                        self.handleTransportFailure()
                        return
                    }
                    if isComplete {
                        self.handleEndOfStream()
                    } else {
                        self.receiveNext(on: connection)
                    }
                }
            }
        }

        private func consumeAvailableBytes() -> Bool {
            if !responseDelivered {
                while true {
                    guard let headerRange = receiveBuffer.range(of: Self.headerTerminator) else {
                        if receiveBuffer.count > Self.maximumResponseHeaderBytes {
                            fail(.badServerResponse)
                            return false
                        }
                        return true
                    }
                    let headerData = receiveBuffer[..<headerRange.lowerBound]
                    receiveBuffer.removeSubrange(..<headerRange.upperBound)
                    guard let parsed = parseResponseHeader(Data(headerData)) else {
                        fail(.badServerResponse)
                        return false
                    }
                    if (100...199).contains(parsed.response.statusCode) {
                        continue
                    }

                    if Self.redirectStatusCodes.contains(parsed.response.statusCode),
                       let location = parsed.location,
                       let baseURL = request.url,
                       let destination = URL(string: location, relativeTo: baseURL)?.absoluteURL,
                       let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest {
                        mutable.url = destination
                        URLProtocol.removeProperty(
                            forKey: Self.approvedAddressesKey,
                            in: mutable
                        )
                        URLProtocol.removeProperty(
                            forKey: Self.permitsPrivateApprovedAddressesKey,
                            in: mutable
                        )
                        signalRedirect(to: mutable as URLRequest, response: parsed.response)
                        return false
                    }

                    responseDelivered = true
                    bodyFraming = parsed.framing
                    responseAllowsReuse = parsed.connectionAllowsReuse
                    if case .none = parsed.framing {
                        bodyInflater = nil
                    } else if let coding = parsed.contentCoding {
                        guard let inflater = BodyInflater(contentCoding: coding) else {
                            fail(.cannotDecodeContentData)
                            return false
                        }
                        bodyInflater = inflater
                    } else {
                        bodyInflater = nil
                    }
                    client?.urlProtocol(
                        self,
                        didReceive: parsed.response,
                        cacheStoragePolicy: .notAllowed
                    )
                    if case .none = bodyFraming {
                        succeed()
                        return false
                    }
                    break
                }
            }

            switch bodyFraming {
            case .none:
                succeed()
                return false
            case .untilClose:
                if !receiveBuffer.isEmpty {
                    let bytes = receiveBuffer
                    receiveBuffer.removeAll(keepingCapacity: true)
                    guard deliverBodyBytes(bytes) else { return false }
                }
                return true
            case .contentLength(let initialRemaining):
                var remaining = initialRemaining
                guard remaining >= 0 else {
                    fail(.badServerResponse)
                    return false
                }
                if remaining == 0 {
                    guard receiveBuffer.isEmpty else {
                        fail(.badServerResponse)
                        return false
                    }
                    succeed()
                    return false
                }
                guard !receiveBuffer.isEmpty else { return true }
                let count = min(Int64(receiveBuffer.count), remaining)
                let bytes = Data(receiveBuffer.prefix(Int(count)))
                receiveBuffer.removeFirst(Int(count))
                remaining -= count
                bodyFraming = .contentLength(remaining)
                guard deliverBodyBytes(bytes) else { return false }
                if remaining == 0 {
                    guard receiveBuffer.isEmpty else {
                        fail(.badServerResponse)
                        return false
                    }
                    succeed()
                    return false
                }
                return true
            case .chunked:
                return consumeChunkedBody()
            }
        }

        private func consumeChunkedBody() -> Bool {
            while !finished {
                if readingChunkTrailers {
                    if receiveBuffer.starts(with: Self.lineTerminator) {
                        receiveBuffer.removeFirst(Self.lineTerminator.count)
                        guard receiveBuffer.isEmpty else {
                            fail(.badServerResponse)
                            return false
                        }
                        succeed()
                        return false
                    }
                    guard let trailerEnd = receiveBuffer.range(of: Self.headerTerminator) else {
                        if receiveBuffer.count > Self.maximumChunkMetadataBytes {
                            fail(.badServerResponse)
                            return false
                        }
                        return true
                    }
                    receiveBuffer.removeSubrange(..<trailerEnd.upperBound)
                    guard receiveBuffer.isEmpty else {
                        fail(.badServerResponse)
                        return false
                    }
                    succeed()
                    return false
                }

                if awaitingChunkTerminator {
                    guard receiveBuffer.count >= 2 else { return true }
                    guard receiveBuffer.prefix(2).elementsEqual(Self.lineTerminator) else {
                        fail(.badServerResponse)
                        return false
                    }
                    receiveBuffer.removeFirst(2)
                    awaitingChunkTerminator = false
                    continue
                }

                if let remaining = chunkBytesRemaining {
                    guard !receiveBuffer.isEmpty else { return true }
                    let count = min(remaining, receiveBuffer.count)
                    let bytes = Data(receiveBuffer.prefix(count))
                    receiveBuffer.removeFirst(count)
                    let nextRemaining = remaining - count
                    if nextRemaining == 0 {
                        chunkBytesRemaining = nil
                        awaitingChunkTerminator = true
                    } else {
                        chunkBytesRemaining = nextRemaining
                    }
                    if !bytes.isEmpty {
                        guard deliverBodyBytes(bytes) else { return false }
                    }
                    continue
                }

                guard let lineEnd = receiveBuffer.range(of: Self.lineTerminator) else {
                    if receiveBuffer.count > Self.maximumChunkMetadataBytes {
                        fail(.badServerResponse)
                        return false
                    }
                    return true
                }
                guard let line = String(
                    data: receiveBuffer[..<lineEnd.lowerBound],
                    encoding: .ascii
                ) else {
                    fail(.badServerResponse)
                    return false
                }
                receiveBuffer.removeSubrange(..<lineEnd.upperBound)
                let sizeText = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sizeText.isEmpty,
                      let size = UInt64(sizeText, radix: 16),
                      size <= UInt64(Int.max) else {
                    fail(.badServerResponse)
                    return false
                }
                if size == 0 {
                    readingChunkTrailers = true
                } else {
                    chunkBytesRemaining = Int(size)
                }
            }
            return false
        }

        private func handleEndOfStream() {
            guard !finished else { return }
            if canRetryWithFreshConnection {
                retryWithFreshConnection()
                return
            }
            guard responseDelivered else {
                fail(.badServerResponse)
                return
            }
            switch bodyFraming {
            case .untilClose:
                if !receiveBuffer.isEmpty {
                    let bytes = receiveBuffer
                    receiveBuffer.removeAll()
                    guard deliverBodyBytes(bytes) else { return }
                }
                succeed()
            case .none:
                succeed()
            case .contentLength(let remaining):
                if remaining == 0 {
                    succeed()
                } else {
                    fail(.networkConnectionLost)
                }
            case .chunked:
                fail(.networkConnectionLost)
            }
        }

        private func parseResponseHeader(
            _ data: Data
        ) -> (
            response: HTTPURLResponse,
            framing: BodyFraming,
            location: String?,
            connectionAllowsReuse: Bool,
            contentCoding: String?
        )? {
            guard let text = String(data: data, encoding: .isoLatin1) else { return nil }
            let lines = text.components(separatedBy: "\r\n")
            guard let statusLine = lines.first else { return nil }
            let statusParts = statusLine.split(separator: " ", maxSplits: 2)
            guard statusParts.count >= 2,
                  statusParts[0].hasPrefix("HTTP/1."),
                  let statusCode = Int(statusParts[1]),
                  (100...599).contains(statusCode),
                  let url = request.url else { return nil }

            var valuesByLowerName: [String: [String]] = [:]
            var originalNameByLowerName: [String: String] = [:]
            for line in lines.dropFirst() {
                guard !line.isEmpty,
                      line.first != " ", line.first != "\t",
                      let separator = line.firstIndex(of: ":") else { return nil }
                let name = String(line[..<separator])
                let value = String(line[line.index(after: separator)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard Self.isValidHeaderName(name),
                      !value.contains("\r"), !value.contains("\n") else { return nil }
                let lower = name.lowercased()
                originalNameByLowerName[lower] = originalNameByLowerName[lower] ?? name
                valuesByLowerName[lower, default: []].append(value)
            }

            var responseHeaders: [String: String] = [:]
            for (lower, values) in valuesByLowerName {
                guard let name = originalNameByLowerName[lower] else { continue }
                responseHeaders[name] = values.joined(separator: ", ")
            }
            let contentCodings = (valuesByLowerName["content-encoding"] ?? [])
                .flatMap { $0.split(separator: ",") }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }

            let contentCoding: String?
            if contentCodings.isEmpty || contentCodings == ["identity"] {
                contentCoding = nil
            } else if contentCodings.count == 1,
                      let single = contentCodings.first,
                      single == "gzip" || single == "x-gzip" || single == "deflate" {
                contentCoding = single
            } else {
                return nil
            }
            if contentCoding != nil {
                responseHeaders = responseHeaders.filter { name, _ in
                    let lower = name.lowercased()
                    return lower != "content-encoding" && lower != "content-length"
                }
            }

            let connectionTokens = (valuesByLowerName["connection"] ?? [])
                .flatMap { $0.split(separator: ",") }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            let connectionAllowsReuse = statusParts[0] == "HTTP/1.1"
                && !connectionTokens.contains("close")

            guard let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: responseHeaders
            ) else { return nil }

            let method = request.httpMethod?.uppercased() ?? "GET"
            let framing: BodyFraming
            if method == "HEAD" || statusCode == 204 || statusCode == 304 {
                framing = .none
            } else {
                let transferCodings = (valuesByLowerName["transfer-encoding"] ?? [])
                    .flatMap { $0.split(separator: ",") }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
                if !transferCodings.isEmpty {
                    guard transferCodings == ["chunked"] else { return nil }
                    framing = .chunked
                } else if let rawLengths = valuesByLowerName["content-length"] {
                    let lengths = rawLengths.flatMap { $0.split(separator: ",") }
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    guard let first = lengths.first,
                          lengths.allSatisfy({ $0 == first }),
                          let length = Int64(first), length >= 0 else { return nil }
                    framing = .contentLength(length)
                } else {
                    framing = .untilClose
                }
            }
            return (
                response,
                framing,
                valuesByLowerName["location"]?.first,
                connectionAllowsReuse,
                contentCoding
            )
        }

        private func serializedRequest(for url: URL) -> Data? {
            let method = request.httpMethod?.uppercased() ?? "GET"
            guard method == "GET" || method == "HEAD",
                  let scheme = url.scheme?.lowercased(),
                  let host = url.host,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return nil
            }
            var target = components.percentEncodedPath
            if target.isEmpty { target = "/" }
            if let query = components.percentEncodedQuery {
                target += "?\(query)"
            }
            guard !target.contains("\r"), !target.contains("\n") else { return nil }

            let hostForHeader = host.contains(":") ? "[\(host)]" : host
            let defaultPort = scheme == "https" ? 443 : 80
            let authority = url.port.map { $0 == defaultPort ? hostForHeader : "\(hostForHeader):\($0)" }
                ?? hostForHeader
            var headers: [String: String] = [:]
            for (name, value) in request.allHTTPHeaderFields ?? [:] {
                let lower = name.lowercased()
                guard lower != "host", lower != "connection", lower != "proxy-connection",
                      lower != "transfer-encoding", lower != "content-length",
                      lower != "accept-encoding",
                      Self.isValidHeaderName(name),
                      !value.contains("\r"), !value.contains("\n") else { continue }
                headers[name] = value
            }

            headers["Accept-Encoding"] = "identity"

            var lines = ["\(method) \(target) HTTP/1.1", "Host: \(authority)"]
            for name in headers.keys.sorted(by: { $0.lowercased() < $1.lowercased() }) {
                guard let value = headers[name] else { continue }
                lines.append("\(name): \(value)")
            }
            lines.append("")
            lines.append("")
            return Data(lines.joined(separator: "\r\n").utf8)
        }

        private static func numericEndpointHost(_ address: String) -> NWEndpoint.Host? {
            if IPv4Address(address) != nil || IPv6Address(address) != nil {

                return NWEndpoint.Host(address)
            }
            return nil
        }

        private static func port(for url: URL, scheme: String) -> NWEndpoint.Port? {
            let rawPort = url.port ?? (scheme == "https" ? 443 : 80)
            guard rawPort > 0, rawPort <= Int(UInt16.max) else { return nil }
            return NWEndpoint.Port(rawValue: UInt16(rawPort))
        }

        private static func isValidHeaderName(_ value: String) -> Bool {
            guard !value.isEmpty else { return false }
            let allowed = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
            return value.unicodeScalars.allSatisfy { allowed.contains($0) }
        }

        private static let redirectStatusCodes: Set<Int> = [301, 302, 303, 307, 308]

        private func deliverBodyBytes(_ bytes: Data) -> Bool {
            guard !bytes.isEmpty else { return true }
            guard let inflater = bodyInflater else {
                client?.urlProtocol(self, didLoad: bytes)
                return true
            }
            guard let inflated = inflater.feed(bytes) else {
                fail(.cannotDecodeContentData)
                return false
            }
            if !inflated.isEmpty {
                client?.urlProtocol(self, didLoad: inflated)
            }
            return true
        }

        private func succeed() {
            guard !finished, !stopped else { return }
            if let inflater = bodyInflater {
                guard let finalBytes = inflater.finish() else {
                    fail(.cannotDecodeContentData)
                    return
                }
                if !finalBytes.isEmpty {
                    client?.urlProtocol(self, didLoad: finalBytes)
                }
                bodyInflater = nil
            }
            finished = true
            client?.urlProtocolDidFinishLoading(self)
            parkOrTearDownConnection()
        }

        private func parkOrTearDownConnection() {
            let framingIsDelimited: Bool
            switch bodyFraming {
            case .untilClose:
                framingIsDelimited = false
            default:
                framingIsDelimited = true
            }
            guard responseAllowsReuse,
                  framingIsDelimited,
                  receiveBuffer.isEmpty,
                  let connection,
                  let key = currentPoolKey else {
                tearDownConnection()
                return
            }
            connection.stateUpdateHandler = nil
            self.connection = nil
            Self.park(connection, forKey: key)
        }

        private func fail(_ code: URLError.Code) {
            guard !finished, !stopped else { return }
            finished = true
            client?.urlProtocol(self, didFailWithError: URLError(code))
            tearDownConnection()
        }

        private func signalRedirect(to redirect: URLRequest, response: HTTPURLResponse) {
            guard !finished, !stopped else { return }
            finished = true
            client?.urlProtocol(self, wasRedirectedTo: redirect, redirectResponse: response)
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            tearDownConnection()
        }

        private func tearDownConnection() {
            connection?.stateUpdateHandler = nil
            connection?.cancel()
            connection = nil
        }
    }

    private final class UpstreamTransport: NSObject, URLSessionDataDelegate {
        private let lock = NSLock()
        private let delegateQueue: OperationQueue
        private let requestStartQueue = DispatchQueue(label: "mpv.header.proxy.request-start")
        private let connectionPoolNamespace = UUID().uuidString
        private let minimumRequestStartInterval: TimeInterval
        private let pinsUpstreamAddresses: Bool
        private var urlSession: URLSession!
        private var bridges: [Int: UpstreamBridge] = [:]
        private var nextRequestStartByHost: [String: TimeInterval] = [:]
        private var rateLimitedUntilByHost: [String: TimeInterval] = [:]
        private var rateLimitCountByHost: [String: Int] = [:]
        private var isInvalidated = false
        private var upstreamFailureCount = 0
        private var lastUpstreamFailureAt: Date?
        private var lastUpstreamSuccessAt: Date?

        init(minimumRequestStartInterval: TimeInterval, pinsUpstreamAddresses: Bool) {
            self.minimumRequestStartInterval = max(0, minimumRequestStartInterval)
            self.pinsUpstreamAddresses = pinsUpstreamAddresses
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            delegateQueue.qualityOfService = .userInitiated
            self.delegateQueue = delegateQueue
            super.init()

            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 6 * 60 * 60

            if pinsUpstreamAddresses {
                configuration.protocolClasses = [PinnedAddressURLProtocol.self]
            }
            if minimumRequestStartInterval > 0 {
                configuration.httpMaximumConnectionsPerHost = 4
            }
            urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        }

        func start(
            _ bridge: UpstreamBridge,
            request: URLRequest,
            approvedAddresses: [String],
            permitsPrivateApprovedAddresses: Bool
        ) -> URLSessionDataTask? {
            lock.lock()
            guard !isInvalidated else {
                lock.unlock()
                return nil
            }
            guard let pinnedRequest = pinnedRequest(
                request,
                to: approvedAddresses,
                permitsPrivateApprovedAddresses: permitsPrivateApprovedAddresses
            ) else {
                lock.unlock()
                return nil
            }
            let task = urlSession.dataTask(with: pinnedRequest)
            bridges[task.taskIdentifier] = bridge
            let hostKey = request.url?.host?.lowercased() ?? "unknown"
            let now = ProcessInfo.processInfo.systemUptime
            let scheduledStart = max(
                now,
                max(
                    nextRequestStartByHost[hostKey] ?? now,
                    rateLimitedUntilByHost[hostKey] ?? now
                )
            )
            let pacingInterval = rateLimitCountByHost[hostKey] == nil
                ? minimumRequestStartInterval
                : max(minimumRequestStartInterval, 0.15)
            nextRequestStartByHost[hostKey] = scheduledStart + pacingInterval
            lock.unlock()
            resume(task, forHost: hostKey, noEarlierThan: scheduledStart)
            return task
        }

        func pinnedRequest(
            _ request: URLRequest,
            to approvedAddresses: [String],
            permitsPrivateApprovedAddresses: Bool = false
        ) -> URLRequest? {
            guard pinsUpstreamAddresses else { return request }
            return PinnedAddressURLProtocol.requestByPinning(
                request,
                to: approvedAddresses,
                poolNamespace: connectionPoolNamespace,
                permitsPrivateApprovedAddresses: permitsPrivateApprovedAddresses
            )
        }

        func recordRateLimit(for url: URL, retryAfter: TimeInterval?) -> TimeInterval {
            let hostKey = url.host?.lowercased() ?? "unknown"
            lock.lock()
            let count = min((rateLimitCountByHost[hostKey] ?? 0) + 1, 4)
            rateLimitCountByHost[hostKey] = count
            let exponentialDelay = pow(2.0, Double(count - 1))
            let serverDelay = retryAfter.flatMap { value in
                value.isFinite ? min(max(value, 0), 30) : nil
            } ?? 0
            let delay = max(exponentialDelay, serverDelay)
            let until = ProcessInfo.processInfo.systemUptime + delay
            rateLimitedUntilByHost[hostKey] = max(rateLimitedUntilByHost[hostKey] ?? 0, until)
            lock.unlock()
            return delay
        }

        private func resume(
            _ task: URLSessionDataTask,
            forHost hostKey: String,
            noEarlierThan scheduledStart: TimeInterval
        ) {
            let delay = max(0, scheduledStart - ProcessInfo.processInfo.systemUptime)
            requestStartQueue.asyncAfter(deadline: .now() + delay) { [weak self, task] in
                guard let self else {
                    task.cancel()
                    return
                }

                self.lock.lock()
                if self.isInvalidated {
                    self.lock.unlock()
                    task.cancel()
                    return
                }

                let now = ProcessInfo.processInfo.systemUptime
                let rateLimitedUntil = self.rateLimitedUntilByHost[hostKey] ?? 0
                if rateLimitedUntil > now {

                    let rescheduledStart = max(
                        rateLimitedUntil,
                        self.nextRequestStartByHost[hostKey] ?? rateLimitedUntil
                    )
                    let pacingInterval = self.rateLimitCountByHost[hostKey] == nil
                        ? self.minimumRequestStartInterval
                        : max(self.minimumRequestStartInterval, 0.15)
                    self.nextRequestStartByHost[hostKey] = rescheduledStart
                        + pacingInterval
                    self.lock.unlock()
                    self.resume(task, forHost: hostKey, noEarlierThan: rescheduledStart)
                    return
                }
                self.lock.unlock()
                task.resume()
            }
        }

        func invalidateAndCancel() {
            lock.lock()
            guard !isInvalidated else {
                lock.unlock()
                return
            }
            isInvalidated = true
            nextRequestStartByHost.removeAll()
            rateLimitedUntilByHost.removeAll()
            rateLimitCountByHost.removeAll()
            lock.unlock()
            urlSession.invalidateAndCancel()
        }

        func upstreamHealthSnapshot() -> MPVHeaderProxyUpstreamHealth {
            lock.lock()
            defer { lock.unlock() }
            return MPVHeaderProxyUpstreamHealth(
                failureCount: upstreamFailureCount,
                lastFailureAt: lastUpstreamFailureAt,
                lastSuccessAt: lastUpstreamSuccessAt
            )
        }

        private func recordUpstreamSuccess() {
            lock.lock()
            lastUpstreamSuccessAt = Date()
            lock.unlock()
        }

        private func recordUpstreamFailure() {
            lock.lock()
            upstreamFailureCount += 1
            lastUpstreamFailureAt = Date()
            lock.unlock()
        }

        private func bridge(for task: URLSessionTask) -> UpstreamBridge? {
            lock.lock()
            defer { lock.unlock() }
            return bridges[task.taskIdentifier]
        }

        private func removeBridge(for task: URLSessionTask) {
            lock.lock()
            bridges.removeValue(forKey: task.taskIdentifier)
            lock.unlock()
        }

        private var transportIsInvalidated: Bool {
            lock.lock()
            defer { lock.unlock() }
            return isInvalidated
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let bridge = bridge(for: dataTask) else {
                completionHandler(.cancel)
                return
            }
            bridge.enqueue {
                bridge.handleResponse(
                    dataTask: dataTask,
                    response: response,
                    completionHandler: completionHandler
                )
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard let bridge = bridge(for: dataTask) else { return }
            recordUpstreamSuccess()
            bridge.enqueue {
                bridge.handleData(dataTask: dataTask, data: data)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            guard let bridge = bridge(for: task) else { return }
            bridge.enqueue {
                bridge.handleMetrics(metrics, task: task)
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let bridge = bridge(for: task) else {
                completionHandler(nil)
                return
            }
            bridge.enqueue {
                bridge.handleRedirection(
                    response: response,
                    request: request,
                    completionHandler: completionHandler
                )
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let bridge = bridge(for: task) else { return }
            let transportWasInvalidated = transportIsInvalidated
            if !transportWasInvalidated {
                if let error {
                    let nsError = error as NSError
                    if nsError.domain == NSURLErrorDomain, nsError.code != NSURLErrorCancelled {
                        recordUpstreamFailure()
                    }
                } else {
                    recordUpstreamSuccess()
                }
            }
            removeBridge(for: task)
            bridge.enqueue {
                bridge.handleCompletion(
                    error: error,
                    transportWasInvalidated: transportWasInvalidated
                )
            }
        }
    }

    private final class UpstreamBridge {
        private weak var proxy: MPVHeaderProxyCore?
        private let request: URLRequest
        private let requestId: String
        private let method: String
        private let targetURL: URL
        private let sessionId: String
        private let traceID: String
        private let requestSequence: Int
        private let shouldLogLifecycle: Bool
        private let logType: String
        private let credentialHeaders: [String: String]
        private let credentialOriginURL: URL
        private let upstreamTransport: UpstreamTransport
        private let cloudflareChallengeReporter: CloudflareChallengeReporter?
        private let validatedRoutePolicy: ValidatedRoutePolicy?
        private let validatedRouteRole: String?
        private let validatedExpectedFiniteContentLength: Int64?
        private let stremioAuthority: SkyStreamPinnedOriginAuthority?
        private let connection: NWConnection
        private let cachedPrefix: CachedPrefixContinuation?
        private let callbackQueue: OperationQueue

        private var continuation: CheckedContinuation<Void, Never>?
        private var httpResponse: HTTPURLResponse?
        private var mode: UpstreamBodyMode = .stream
        private var bufferedData = Data()
        private var responseHeadersSent = false
        private var finished = false
        private var streamedByteCount = 0
        private let requestStartedAt = CFAbsoluteTimeGetCurrent()
        private var responseReceivedAt: CFTimeInterval?
        private var firstDataReceivedAt: CFTimeInterval?
        private var upstreamCompletedAt: CFTimeInterval?
        private var transportTaskMilliseconds: Double?
        private var maximumPendingDownstreamSends = 0
        private var maximumPendingDownstreamBytes = 0
        private var maximumDownstreamSendMilliseconds: Double = 0
        private var lastSlowSendLogAt: CFTimeInterval = 0
        private var pendingDownstreamSends = 0
        private var pendingDownstreamBytes = 0
        private var pendingStreamCompletionStatusCode: Int?
        private var rejectedCookieHeader: String?
        private var revokedDestinationOrigins: MPVHeaderProxyRevokedOriginSet
        private let configuredPrivateAuthorityRemainsAuthorized: Bool
        private var rateLimitRetryCount = 0
        private let maximumRateLimitRetries = 2
        private var expectedResponseByteCount: Int64?
        private weak var activeDataTask: URLSessionDataTask?

        private var initialApprovedAddresses: [String] = []

        init(
            proxy: MPVHeaderProxyCore,
            request: URLRequest,
            requestId: String,
            method: String,
            targetURL: URL,
            sessionId: String,
            traceID: String,
            requestSequence: Int,
            shouldLogLifecycle: Bool,
            logType: String,
            credentialHeaders: [String: String],
            credentialOriginURL: URL,
            upstreamTransport: UpstreamTransport,
            cloudflareChallengeReporter: CloudflareChallengeReporter?,
            validatedRoutePolicy: ValidatedRoutePolicy?,
            validatedRouteRole: String?,
            validatedExpectedFiniteContentLength: Int64?,
            stremioAuthority: SkyStreamPinnedOriginAuthority?,
            revokedDestinationOrigins: MPVHeaderProxyRevokedOriginSet,
            connection: NWConnection,
            cachedPrefix: CachedPrefixContinuation? = nil
        ) {
            self.proxy = proxy
            self.request = request
            self.requestId = requestId
            self.method = method
            self.targetURL = targetURL
            self.sessionId = sessionId
            self.traceID = traceID
            self.requestSequence = requestSequence
            self.shouldLogLifecycle = shouldLogLifecycle
            self.logType = logType
            self.credentialHeaders = credentialHeaders
            self.credentialOriginURL = credentialOriginURL
            self.upstreamTransport = upstreamTransport
            self.cloudflareChallengeReporter = cloudflareChallengeReporter
            self.validatedRoutePolicy = validatedRoutePolicy
            self.validatedRouteRole = validatedRouteRole
            self.validatedExpectedFiniteContentLength = validatedExpectedFiniteContentLength
            self.stremioAuthority = stremioAuthority
            self.revokedDestinationOrigins = revokedDestinationOrigins
            self.configuredPrivateAuthorityRemainsAuthorized = stremioAuthority?.contains(targetURL) == true
            self.connection = connection
            self.cachedPrefix = cachedPrefix
            self.rejectedCookieHeader = request.value(forHTTPHeaderField: "Cookie")
            let callbackQueue = OperationQueue()
            callbackQueue.maxConcurrentOperationCount = 1
            callbackQueue.qualityOfService = .userInitiated
            self.callbackQueue = callbackQueue
        }

        private var errorLogType: String {
            logType == "MPV" ? "MPV" : "Error"
        }

        private func logTarget(_ url: URL? = nil) -> String {
            if validatedRoutePolicy != nil { return "validated-route" }
            guard let proxy else { return "nil" }
            return proxy.logURLSummary(url ?? targetURL)
        }

        func start() async {
            if validatedRoutePolicy != nil {
                do {
                    let checked = try await SkyStreamRemoteURLPolicy.shared
                        .validateForNetworkDispatch(
                            targetURL.absoluteString,
                            purpose: Self.skyNetworkPurpose(for: validatedRouteRole)
                        )
                    guard ValidatedRoutePolicy.canonicalURLKey(checked.url)
                            == ValidatedRoutePolicy.canonicalURLKey(targetURL),
                          let addresses = approvedAddresses(from: checked) else {
                        throw SkyStreamSecurityError.invalidResponse
                    }
                    initialApprovedAddresses = addresses
                } catch {
                    Logger.shared.log(
                        "\(proxy?.logPrefix ?? "MPVHeaderProxy")[\(requestId)]: rejected stale or unsafe SkyStream route before dispatch",
                        type: "Error"
                    )
                    self.logEclipseRefusal("upstream-route-rejected", phase: "pre-contact")
                    proxy?.sendSimpleResponse(connection, statusCode: 502, body: "Upstream route rejected")
                    finish()
                    return
                }
            }

            await withCheckedContinuation { continuation in
                self.continuation = continuation
                guard let dataTask = upstreamTransport.start(
                    self,
                    request: request,
                    approvedAddresses: initialApprovedAddresses,
                    permitsPrivateApprovedAddresses: permitsPrivateApprovedAddresses(for: targetURL)
                ) else {
                    self.logEclipseRefusal("upstream-session-unavailable", phase: "pre-contact")
                    proxy?.sendSimpleResponse(connection, statusCode: 502, body: "Upstream session unavailable")
                    finish()
                    return
                }
                activeDataTask = dataTask
                monitorDownstreamClosure()
            }
        }

        func enqueue(_ operation: @escaping () -> Void) {
            callbackQueue.addOperation(operation)
        }

        private func monitorDownstreamClosure() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, isComplete, error in
                guard let self else { return }
                self.enqueue { [weak self] in
                    guard let self, !self.finished else { return }
                    if isComplete || error != nil {
                        Logger.shared.log(
                            "[MPVProxyTrace \(self.traceID)] stage=downstream-client-closed req=\(self.requestSequence) afterBytes=\(self.streamedByteCount) pending=\(self.pendingDownstreamSends) pendingBytes=\(self.pendingDownstreamBytes) target=\(self.logTarget())",
                            type: "PlaybackTrace"
                        )
                        self.activeDataTask?.cancel()
                        self.connection.cancel()
                        self.finish()
                    } else {
                        self.monitorDownstreamClosure()
                    }
                }
            }
        }

        private static func skyNetworkPurpose(for routeRole: String?) -> SkyStreamNetworkPurpose {
            switch routeRole {
            case "manifest":
                return .manifest
            case "encryptionKey":
                return .encryptionKey
            case "subtitle":
                return .subtitle
            case "streamRoot":
                return .streamRoot
            case "mediaSegment", "initialization", "dashResource":
                return .mediaSegment
            default:
                return .streamRoot
            }
        }

        private func genericNetworkPurpose(for url: URL) -> SkyStreamNetworkPurpose {
            ValidatedRoutePolicy.canonicalURLKey(url)
                == ValidatedRoutePolicy.canonicalURLKey(credentialOriginURL)
                ? .streamRoot
                : .mediaSegment
        }

        private func approvedAddresses(
            from checked: SkyStreamValidatedRemoteURL
        ) -> [String]? {
            var seen = Set<String>()
            let permitsPrivate = permitsPrivateApprovedAddresses(for: checked.url)
            let addresses = checked.checkedAddresses.compactMap {
                MPVHeaderProxyPinnedAddressPolicy.normalizeApprovedAddress(
                    $0,
                    permitsPrivateApprovedAddresses: permitsPrivate
                )
            }
                .filter { seen.insert($0).inserted }
            return addresses.isEmpty ? nil : addresses
        }

        private func permitsPrivateApprovedAddresses(for url: URL) -> Bool {
            configuredPrivateAuthorityRemainsAuthorized
                && stremioAuthority?.contains(url) == true
        }

        func handleResponse(
            dataTask: URLSessionDataTask,
            response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let proxy else {
                completionHandler(.cancel)
                finish()
                return
            }

            guard let http = response as? HTTPURLResponse else {
                Logger.shared.log("\(proxy.logPrefix)[\(requestId)]: upstream response was not HTTP target=\(logTarget())", type: errorLogType)
                proxy.sendSimpleResponse(connection, statusCode: 502, body: "Bad gateway")
                completionHandler(.cancel)
                finish()
                return
            }

            httpResponse = http
            responseReceivedAt = CFAbsoluteTimeGetCurrent()
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "nil"
            let contentLength = http.value(forHTTPHeaderField: "Content-Length") ?? "nil"
            let contentRange = http.value(forHTTPHeaderField: "Content-Range") ?? "nil"
            if shouldLogLifecycle || !(200...299).contains(http.statusCode) {
                Logger.shared.log("[MPVProxyTrace \(traceID)] stage=upstream-response req=\(requestSequence) status=\(http.statusCode) contentLength=\(contentLength) contentRange=\(contentRange) contentType=\(contentType) target=\(logTarget())", type: shouldLogLifecycle ? "PlaybackTrace" : errorLogType)
            }

            guard (200...299).contains(http.statusCode) else {
                if validatedRoutePolicy != nil,
                   http.statusCode == 401 || http.statusCode == 410 {

                    let rejectedURL = http.url ?? targetURL
                    Logger.shared.log(
                        "\(proxy.logPrefix)[\(requestId)]: validated media route expired status=\(http.statusCode) target=\(logTarget(rejectedURL))",
                        type: errorLogType
                    )
                    cloudflareChallengeReporter?.report(
                        url: rejectedURL,
                        rejectedCookieHeader: nil,
                        isInteractiveChallenge: false,
                        statusCode: http.statusCode
                    )
                    proxy.sendResponse(
                        connection,
                        statusCode: http.statusCode,
                        headers: proxy.emptyResponseHeaders(from: http),
                        body: Data()
                    )
                    completionHandler(.cancel)
                    finish()
                    return
                }

                if [403, 429, 503].contains(http.statusCode), method != "HEAD" {

                    mode = .rejectedResponseProbe
                    completionHandler(.allow)
                    return
                }

                let backoffDescription: String
                if http.statusCode == 429 {
                    let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                        .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    let backoff = upstreamTransport.recordRateLimit(
                        for: targetURL,
                        retryAfter: retryAfter
                    )
                    backoffDescription = " backoff=\(String(format: "%.1f", backoff))s"
                } else {
                    backoffDescription = ""
                }
                Logger.shared.log("\(proxy.logPrefix)[\(requestId)]: refusing upstream error body status=\(http.statusCode)\(backoffDescription) target=\(logTarget())", type: errorLogType)
                proxy.sendResponse(connection, statusCode: http.statusCode, headers: proxy.emptyResponseHeaders(from: http), body: Data())
                completionHandler(.cancel)
                finish()
                return
            }

            if let expectedFiniteLength = validatedExpectedFiniteContentLength {
                guard let responseByteCount = Self.validatedDirectResponseByteCount(
                    http,
                    expectedTotal: expectedFiniteLength
                ) else {
                    Logger.shared.log(
                        "\(proxy.logPrefix)[\(requestId)]: rejected changed or unbounded SkyStream direct response",
                        type: "Error"
                    )
                    logEclipseRefusal("direct-media-bounds-changed", phase: "post-response")
                    proxy.sendSimpleResponse(connection, statusCode: 502, body: "Direct media bounds changed")
                    completionHandler(.cancel)
                    finish()
                    return
                }
                expectedResponseByteCount = method == "HEAD" ? 0 : responseByteCount
            }

            if validatedRoutePolicy != nil {
                guard !MPVHeaderProxyValidatedRouteResponsePolicy.rejectsManifest(
                    role: validatedRouteRole,
                    contentType: contentType,
                    responseURL: http.url
                ) else {
                    Logger.shared.log(
                        "\(proxy.logPrefix)[\(requestId)]: rejected a refetched SkyStream manifest",
                        type: "Error"
                    )
                    logEclipseRefusal("manifest-refetch-rejected", phase: "post-response")
                    proxy.sendSimpleResponse(connection, statusCode: 502, body: "Manifest refetch rejected")
                    completionHandler(.cancel)
                    finish()
                    return
                }
            }

            let responseHeaders = proxy.filteredResponseHeaders(from: http)
            if method == "HEAD" {
                proxy.sendResponse(connection, statusCode: http.statusCode, headers: responseHeaders, body: Data())
                completionHandler(.cancel)
                finish()
                return
            }

            let effectiveResponseURL = MPVHeaderProxyPlaylistRouting.effectiveResponseURL(
                originalRequestURL: targetURL,
                responseURL: http.url
            )
            let verifiedCachedMediaContinuation: Bool
            if let cachedPrefix, http.statusCode == 206 {
                guard let continuationBodyByteCount = MPVHeaderProxyCachedContinuationPolicy
                    .validatedBodyByteCount(
                        statusCode: http.statusCode,
                        contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                        contentLength: http.value(forHTTPHeaderField: "Content-Length"),
                        transferEncoding: http.value(forHTTPHeaderField: "Transfer-Encoding"),
                        responseEntityTag: http.value(forHTTPHeaderField: "ETag"),
                        contentEncoding: http.value(forHTTPHeaderField: "Content-Encoding"),
                        expectedEntityTag: cachedPrefix.strongEntityTag,
                        expectedStart: cachedPrefix.upstreamStart,
                        expectedEnd: cachedPrefix.upstreamEnd,
                        expectedTotal: cachedPrefix.expectedTotalLength
                    ) else {
                    Logger.shared.log(
                        "\(proxy.logPrefix)[\(requestId)]: rejected changed or malformed cached media continuation",
                        type: errorLogType
                    )
                    self.logEclipseRefusal("cached-media-identity-changed", phase: "post-response")
                    proxy.sendSimpleResponse(
                        connection,
                        statusCode: 502,
                        body: "Cached media identity changed"
                    )
                    completionHandler(.cancel)
                    finish()
                    return
                }
                expectedResponseByteCount = Int64(cachedPrefix.data.count)
                    + continuationBodyByteCount
                verifiedCachedMediaContinuation = true
            } else {
                verifiedCachedMediaContinuation = false
            }
            mode = proxy.upstreamBodyMode(
                for: http,
                targetURL: effectiveResponseURL,
                isInitialGenericRoot: validatedRoutePolicy == nil
                    && ValidatedRoutePolicy.canonicalURLKey(targetURL)
                        == ValidatedRoutePolicy.canonicalURLKey(credentialOriginURL),
                isValidatedResource: validatedRoutePolicy != nil,
                hasVerifiedCachedMediaContinuation: verifiedCachedMediaContinuation
            )
            switch mode {
            case .playlist, .probe:
                completionHandler(.allow)
            case .rejectedResponseProbe:
                completionHandler(.allow)
            case .stream:
                if let cachedPrefix, verifiedCachedMediaContinuation {
                    proxy.sendResponseHeaders(connection, statusCode: cachedPrefix.responseStatus, headers: cachedPrefix.responseHeaders) { [weak self] error in
                        guard let self else { return }
                        if let error {
                            Logger.shared.log("\(self.proxy?.logPrefix ?? "MPVHeaderProxy")[\(self.requestId)]: failed to send cached response headers: \(error)", type: self.errorLogType)
                            completionHandler(.cancel)
                            self.finish()
                            return
                        }

                        self.responseHeadersSent = true
                        self.sendCachedPrefixBeforeUpstream(cachedPrefix, dataTask: dataTask, completionHandler: completionHandler)
                    }
                    return
                }
                if cachedPrefix != nil {
                    Logger.shared.log("\(proxy.logPrefix)[\(requestId)]: MPV warmup cache bypassed because continuation status=\(http.statusCode) target=\(logTarget())", type: logType)
                }

                proxy.sendResponseHeaders(connection, statusCode: http.statusCode, headers: responseHeaders) { [weak self] error in
                    guard let self else { return }
                    if let error {
                        Logger.shared.log("\(self.proxy?.logPrefix ?? "MPVHeaderProxy")[\(self.requestId)]: failed to send response headers: \(error)", type: self.errorLogType)
                        completionHandler(.cancel)
                        self.finish()
                        return
                    }

                    self.responseHeadersSent = true
                    completionHandler(.allow)
                }
            }
        }

        func handleData(dataTask: URLSessionDataTask, data: Data) {
            guard let proxy, !finished else { return }
            guard method != "HEAD" else { return }
            if firstDataReceivedAt == nil {
                firstDataReceivedAt = CFAbsoluteTimeGetCurrent()
            }

            if let expectedResponseByteCount,
               Int64(streamedByteCount + pendingDownstreamBytes + data.count) > expectedResponseByteCount {
                Logger.shared.log(
                    "\(proxy.logPrefix)[\(requestId)]: rejected oversized SkyStream direct response body",
                    type: "Error"
                )
                dataTask.cancel()
                connection.cancel()
                finish()
                return
            }

            switch mode {
            case .playlist:
                bufferedData.append(data)
                if MPVHeaderProxyPlaylistFramingPolicy.action(
                    bufferedByteCount: bufferedData.count,
                    maximumRewriteBytes: proxy.maxPlaylistBytes
                ) == .reject {
                    rejectOversizedPlaylist(dataTask: dataTask)
                }
            case .probe:
                bufferedData.append(data)
                switch MPVHeaderProxyGenericBodyPolicy.probeAction(
                    bufferedData: bufferedData,
                    maximumProbeBytes: proxy.playlistProbeBytes
                ) {
                case .identifiedPlaylist:
                    if validatedRoutePolicy != nil {
                        rejectUnexpectedValidatedPlaylist(dataTask: dataTask)
                        return
                    }
                    mode = .playlist
                    if MPVHeaderProxyPlaylistFramingPolicy.action(
                        bufferedByteCount: bufferedData.count,
                        maximumRewriteBytes: proxy.maxPlaylistBytes
                    ) == .reject {
                        rejectOversizedPlaylist(dataTask: dataTask)
                    }
                case .streamNonPlaylist:
                    startStreamingBufferedData(dataTask: dataTask)
                case .rejectAmbiguousPrefix:
                    rejectAmbiguousProbe(dataTask: dataTask)
                case .continueBuffering:
                    break
                }
            case .stream:
                streamChunk(data, dataTask: dataTask)
            case .rejectedResponseProbe:
                let remaining = max(proxy.maxRejectedResponseProbeBytes - bufferedData.count, 0)
                if remaining > 0 {
                    bufferedData.append(data.prefix(remaining))
                }

                let confirmedChallenge = confirmedCloudflareChallenge()

                if confirmedChallenge
                    || (bufferedData.count >= proxy.maxRejectedResponseProbeBytes
                        && httpResponse?.statusCode != 429) {
                    completeRejectedResponse(dataTask: dataTask)
                }
            }
        }

        func handleRedirection(
            response: HTTPURLResponse,
            request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            if let policy = validatedRoutePolicy {
                guard let proxy,
                      let sourceURL = response.url,
                      let destinationURL = request.url,
                      policy.resource(forRemoteURL: sourceURL) != nil,
                      let destination = policy.resource(forRemoteURL: destinationURL),
                      destination.targetURL != nil,
                      !(sourceURL.scheme?.lowercased() == "https"
                        && destinationURL.scheme?.lowercased() != "https") else {
                    Logger.shared.log(
                        "\(proxy?.logPrefix ?? "MPVHeaderProxy")[\(requestId)]: rejected unvalidated SkyStream redirect",
                        type: "Error"
                    )
                    completionHandler(nil)
                    self.logEclipseRefusal("redirect-rejected", phase: "post-response")
                    proxy?.sendSimpleResponse(connection, statusCode: 502, body: "Redirect rejected")
                    finish()
                    return
                }

                if destination.acceptedManifest != nil {
                    completionHandler(nil)
                    proxy.serveValidatedManifest(
                        destination,
                        policy: policy,
                        sessionId: sessionId,
                        method: self.request.httpMethod ?? method,
                        connection: connection
                    )
                    finish()
                    return
                }

                Task { [weak self] in
                    guard let self else {
                        completionHandler(nil)
                        return
                    }
                    do {
                        let checked = try await SkyStreamRemoteURLPolicy.shared
                            .validateForNetworkDispatch(
                                destinationURL.absoluteString,
                                purpose: Self.skyNetworkPurpose(for: destination.role)
                            )
                        guard ValidatedRoutePolicy.canonicalURLKey(checked.url)
                                == ValidatedRoutePolicy.canonicalURLKey(destinationURL),
                              let approvedAddresses = self.approvedAddresses(from: checked) else {
                            throw SkyStreamSecurityError.invalidResponse
                        }
                        self.enqueue { [weak self] in
                            guard let self, !self.finished else {
                                completionHandler(nil)
                                return
                            }
                            var redirected = request
                            redirected.httpMethod = self.request.httpMethod
                            let safeNames: Set<String> = [
                                "accept", "accept-language", "cache-control", "dnt", "icy-metadata",
                                "if-match", "if-modified-since", "if-none-match", "if-range",
                                "if-unmodified-since", "pragma", "range", "user-agent"
                            ]
                            let safeForwarded = (redirected.allHTTPHeaderFields ?? [:]).filter {
                                safeNames.contains($0.key.lowercased())
                            }
                            for key in (redirected.allHTTPHeaderFields ?? [:]).keys {
                                redirected.setValue(nil, forHTTPHeaderField: key)
                            }
                            for (key, value) in safeForwarded {
                                redirected.setValue(value, forHTTPHeaderField: key)
                            }
                            for (key, value) in destination.headers {
                                redirected.setValue(value, forHTTPHeaderField: key)
                            }
                            self.rejectedCookieHeader = nil
                            Logger.shared.log(
                                "\(proxy.logPrefix)[\(self.requestId)]: following validated SkyStream redirect",
                                type: self.logType
                            )
                            completionHandler(
                                self.upstreamTransport.pinnedRequest(
                                    redirected,
                                    to: approvedAddresses
                                )
                            )
                        }
                    } catch {
                        self.enqueue { [weak self] in
                            guard let self, !self.finished else {
                                completionHandler(nil)
                                return
                            }
                            Logger.shared.log(
                                "\(proxy.logPrefix)[\(self.requestId)]: rejected stale or unsafe SkyStream redirect",
                                type: "Error"
                            )
                            completionHandler(nil)
                            self.logEclipseRefusal("skystream-redirect-rejected", phase: "post-response")
                            proxy.sendSimpleResponse(
                                self.connection,
                                statusCode: 502,
                                body: "Redirect rejected"
                            )
                            self.finish()
                        }
                    }
                }
                return
            }

            guard let destinationURL = request.url else {
                completionHandler(nil)
                return
            }
            let sourceURL = response.url ?? targetURL
            if MPVHeaderProxyRevokedOriginSet.requiresRevocation(
                from: sourceURL,
                to: destinationURL,
                credentialOriginURL: credentialOriginURL
            ) {
                revokedDestinationOrigins.revoke(destinationURL: destinationURL)
                proxy?.recordRevokedRedirectDestinationOrigin(
                    for: sessionId,
                    sourceURL: sourceURL,
                    destinationURL: destinationURL
                )
            }
            followRedirect(
                response: response,
                request: request,
                approvedAddresses: [],
                completionHandler: completionHandler
            )
        }

        private func followRedirect(
            response: HTTPURLResponse,
            request: URLRequest,
            approvedAddresses: [String],
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            var redirected = request
            redirected.httpMethod = self.request.httpMethod

            let credentialHeaderNames = Set(
                MPVHeaderProxyCore.sanitizedCredentialHeaders(credentialHeaders)
                    .keys
                    .map { $0.lowercased() }
            ).union(["authorization", "cookie", "cookie2", "proxy-authorization"])
            for key in (redirected.allHTTPHeaderFields ?? [:]).keys
            where credentialHeaderNames.contains(key.lowercased()) {
                redirected.setValue(nil, forHTTPHeaderField: key)
            }
            let destinationURL = request.url ?? targetURL
            let destinationOriginIsRevoked = revokedDestinationOrigins.revokesCredentials(
                for: destinationURL,
                credentialOriginURL: credentialOriginURL
            )
            var scopedHeaders = MPVHeaderProxyCore.credentialHeaders(
                credentialHeaders,
                for: destinationURL,
                originURL: credentialOriginURL
            )
            if destinationOriginIsRevoked {
                for name in ["Authorization", "Cookie", "Cookie2", "Proxy-Authorization"] {
                    scopedHeaders.keys
                        .filter { $0.caseInsensitiveCompare(name) == .orderedSame }
                        .forEach { scopedHeaders.removeValue(forKey: $0) }
                }
            }
            for (key, value) in scopedHeaders {
                redirected.setValue(value, forHTTPHeaderField: key)
            }
            CloudflareBypassManager.shared.applyCachedBypass(
                to: &redirected,
                for: destinationURL
            )
            rejectedCookieHeader = redirected.value(forHTTPHeaderField: "Cookie")

            let redirectTarget = validatedRoutePolicy != nil
                ? "validated-route"
                : (redirected.url.flatMap { proxy?.logURLSummary($0) } ?? "nil")
            Logger.shared.log("\(proxy?.logPrefix ?? "MPVHeaderProxy")[\(requestId)]: following redirect status=\(response.statusCode) target=\(redirectTarget)", type: logType)
            completionHandler(
                upstreamTransport.pinnedRequest(
                    redirected,
                    to: approvedAddresses,
                    permitsPrivateApprovedAddresses: permitsPrivateApprovedAddresses(
                        for: redirected.url ?? targetURL
                    )
                )
            )
        }

        func handleMetrics(_ metrics: URLSessionTaskMetrics, task: URLSessionTask) {
            let transactions = metrics.transactionMetrics
            let reusedTransactions = transactions.filter(\.isReusedConnection).count
            let protocols = Set(transactions.compactMap(\.networkProtocolName)).sorted().joined(separator: ",")
            let taskMs = metrics.taskInterval.duration * 1_000
            transportTaskMilliseconds = taskMs
            guard shouldLogLifecycle else { return }
            Logger.shared.log(
                "[MPVProxyTrace \(traceID)] stage=transport-metrics req=\(requestSequence) reused=\(reusedTransactions)/\(transactions.count) protocols=\(protocols.isEmpty ? "unknown" : protocols) taskMs=\(String(format: "%.0f", taskMs))",
                type: "PlaybackTrace"
            )
        }

        func handleCompletion(error: Error?, transportWasInvalidated: Bool) {
            guard !finished else { return }
            upstreamCompletedAt = CFAbsoluteTimeGetCurrent()
            if transportWasInvalidated {
                connection.cancel()
                finish()
                return
            }
            guard let proxy else {
                finish()
                return
            }

            if let error {
                let nsError = error as NSError
                Logger.shared.log(
                    "\(proxy.logPrefix)[\(requestId)]: upstream error target=\(logTarget()) errorType=\(String(reflecting: type(of: error))) domain=\(Self.safeErrorDomain(nsError.domain)) code=\(nsError.code)",
                    type: errorLogType
                )
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

            if case .probe = mode, !bufferedData.isEmpty {
                switch MPVHeaderProxyGenericBodyPolicy.probeAction(
                    bufferedData: bufferedData,
                    maximumProbeBytes: proxy.playlistProbeBytes
                ) {
                case .identifiedPlaylist:
                    if validatedRoutePolicy != nil {
                        self.logEclipseRefusal("unexpected-nested-playlist", phase: "post-response")
                        proxy.sendSimpleResponse(
                            connection,
                            statusCode: 502,
                            body: "Unexpected nested playlist"
                        )
                        finish()
                        return
                    }
                    mode = .playlist
                case .continueBuffering, .rejectAmbiguousPrefix:
                    if validatedRoutePolicy != nil {
                        self.logEclipseRefusal("incomplete-protected-media-classification", phase: "post-response")
                        proxy.sendSimpleResponse(
                            connection,
                            statusCode: 502,
                            body: "Incomplete protected media classification"
                        )
                        finish()
                        return
                    }
                case .streamNonPlaylist:
                    break
                }
            }

            switch mode {
            case .playlist, .probe:
                let effectiveResponseURL = MPVHeaderProxyPlaylistRouting.effectiveResponseURL(
                    originalRequestURL: targetURL,
                    responseURL: http.url
                )
                let (body, headers, rewritten, responseStatus) = proxy.rewrittenPlaylistResponse(
                    http: http,
                    data: bufferedData,
                    targetURL: effectiveResponseURL,
                    sessionId: sessionId,
                    logType: logType,
                    requiresValidEncoding: validatedRoutePolicy != nil
                )
                if shouldLogLifecycle {
                    Logger.shared.log("[MPVProxyTrace \(traceID)] stage=playlist-complete req=\(requestSequence) status=\(http.statusCode) responseStatus=\(responseStatus) bytes=\(bufferedData.count) responseBytes=\(body.count) rewritten=\(rewritten)", type: "PlaybackTrace")
                }
                proxy.sendResponse(connection, statusCode: responseStatus, headers: headers, body: body)
            case .stream:
                let expected = http.expectedContentLength >= 0 ? String(http.expectedContentLength) : "unknown"
                pendingStreamCompletionStatusCode = http.statusCode
                if shouldLogLifecycle, pendingDownstreamSends > 0 {
                    Logger.shared.log("[MPVProxyTrace \(traceID)] stage=upstream-complete-waiting req=\(requestSequence) pending=\(pendingDownstreamSends) pendingBytes=\(pendingDownstreamBytes) bytes=\(streamedByteCount) expected=\(expected)", type: "PlaybackTrace")
                }
                finishStreamIfReady(expected: expected)
            case .rejectedResponseProbe:
                completeRejectedResponse()
                return
            }

            if mode != .stream {
                finish()
            }
        }

        private func confirmedCloudflareChallenge() -> Bool {
            guard let http = httpResponse else { return false }
            let body = String(data: bufferedData, encoding: .utf8) ?? ""
            return CloudflareBypassManager.isChallengeResponse(
                status: http.statusCode,
                body: body,
                headers: CloudflareBypassManager.headersDictionary(from: http)
            )
        }

        private func completeRejectedResponse(dataTask: URLSessionDataTask? = nil) {
            guard let proxy, let http = httpResponse, !finished else { return }
            let confirmedChallenge = confirmedCloudflareChallenge()
            let backoffDescription: String
            if http.statusCode == 429, !confirmedChallenge {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                    .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .flatMap { $0.isFinite ? $0 : nil }
                let backoff = upstreamTransport.recordRateLimit(
                    for: targetURL,
                    retryAfter: retryAfter
                )
                backoffDescription = " backoff=\(String(format: "%.1f", backoff))s"

                if rateLimitRetryCount < maximumRateLimitRetries {
                    rateLimitRetryCount += 1
                    httpResponse = nil
                    mode = .stream
                    bufferedData.removeAll(keepingCapacity: true)
                    Logger.shared.log(
                        "\(proxy.logPrefix)[\(requestId)]: retrying rate-limited media request attempt=\(rateLimitRetryCount)/\(maximumRateLimitRetries)\(backoffDescription) target=\(logTarget())",
                        type: errorLogType
                    )
                    if let retryTask = upstreamTransport.start(
                        self,
                        request: request,
                        approvedAddresses: initialApprovedAddresses,
                        permitsPrivateApprovedAddresses: permitsPrivateApprovedAddresses(
                            for: targetURL
                        )
                    ) {
                        activeDataTask = retryTask
                        return
                    }

                    rateLimitRetryCount = maximumRateLimitRetries
                }
            } else {
                backoffDescription = ""
            }

            if confirmedChallenge
                || http.statusCode != 429
                || rateLimitRetryCount >= maximumRateLimitRetries {
                let rejectedURL = http.url ?? targetURL
                Logger.shared.log(
                    "\(proxy.logPrefix)[\(requestId)]: media access rejected status=\(http.statusCode) interactiveChallenge=\(confirmedChallenge) target=\(logTarget(rejectedURL))",
                    type: errorLogType
                )
                cloudflareChallengeReporter?.report(
                    url: rejectedURL,
                    rejectedCookieHeader: rejectedCookieHeader,
                    isInteractiveChallenge: confirmedChallenge,
                    statusCode: http.statusCode
                )
            }

            Logger.shared.log(
                "\(proxy.logPrefix)[\(requestId)]: refusing upstream error body status=\(http.statusCode) confirmedCloudflare=\(confirmedChallenge)\(backoffDescription) target=\(logTarget())",
                type: errorLogType
            )
            proxy.sendResponse(
                connection,
                statusCode: http.statusCode,
                headers: proxy.emptyResponseHeaders(from: http),
                body: Data()
            )
            dataTask?.cancel()
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
            responseHeadersSent = true
            pendingDownstreamSends += 1
            pendingDownstreamBytes += initialData.count
            maximumPendingDownstreamSends = max(maximumPendingDownstreamSends, pendingDownstreamSends)
            maximumPendingDownstreamBytes = max(maximumPendingDownstreamBytes, pendingDownstreamBytes)
            let sendStartedAt = CFAbsoluteTimeGetCurrent()
            let shouldThrottle = pendingDownstreamBytes >= proxy.maxPendingStreamBytes
                || pendingDownstreamSends >= proxy.maxPendingStreamSends

            proxy.sendResponseStart(
                connection,
                statusCode: http.statusCode,
                headers: responseHeaders,
                body: initialData
            ) { [weak self] error in
                self?.callbackQueue.addOperation { [weak self] in
                    self?.handleStreamSendCompletion(
                        data: initialData,
                        dataTask: dataTask,
                        sendStartedAt: sendStartedAt,
                        resumeDataTask: shouldThrottle,
                        error: error
                    )
                }
            }

            if !shouldThrottle {
                dataTask.resume()
            }
        }

        private func rejectOversizedPlaylist(dataTask: URLSessionDataTask) {
            guard let proxy else {
                dataTask.cancel()
                connection.cancel()
                finish()
                return
            }
            if validatedRoutePolicy == nil {
                Logger.shared.log(
                    "\(proxy.logPrefix)[\(requestId)]: playlist exceeded rewrite limit; streaming original target=\(logTarget()) bytes=\(bufferedData.count)",
                    type: errorLogType
                )
                startStreamingBufferedData(dataTask: dataTask)
                return
            }
            Logger.shared.log(
                "\(proxy.logPrefix)[\(requestId)]: rejected playlist above rewrite limit bytes=\(bufferedData.count)",
                type: errorLogType
            )
            dataTask.cancel()
            self.logEclipseRefusal("playlist-above-rewrite-limit", phase: "post-response")
            proxy.sendSimpleResponse(
                connection,
                statusCode: 502,
                body: "Playlist exceeds protected rewrite limit"
            )
            finish()
        }

        private func rejectAmbiguousProbe(dataTask: URLSessionDataTask) {
            guard let proxy else {
                dataTask.cancel()
                connection.cancel()
                finish()
                return
            }
            if validatedRoutePolicy == nil {
                Logger.shared.log(
                    "\(proxy.logPrefix)[\(requestId)]: media prefix remained ambiguous; streaming original target=\(logTarget()) bytes=\(bufferedData.count)",
                    type: errorLogType
                )
                startStreamingBufferedData(dataTask: dataTask)
                return
            }
            Logger.shared.log(
                "\(proxy.logPrefix)[\(requestId)]: rejected ambiguous media prefix bytes=\(bufferedData.count)",
                type: errorLogType
            )
            dataTask.cancel()
            self.logEclipseRefusal("unclassifiable-protected-media", phase: "post-response")
            proxy.sendSimpleResponse(
                connection,
                statusCode: 502,
                body: "Unable to classify protected media response"
            )
            finish()
        }

        private func rejectUnexpectedValidatedPlaylist(dataTask: URLSessionDataTask) {
            guard let proxy else {
                dataTask.cancel()
                connection.cancel()
                finish()
                return
            }
            Logger.shared.log(
                "\(proxy.logPrefix)[\(requestId)]: rejected nested playlist body on validated route",
                type: errorLogType
            )
            dataTask.cancel()
            self.logEclipseRefusal("unexpected-nested-playlist", phase: "post-response")
            proxy.sendSimpleResponse(
                connection,
                statusCode: 502,
                body: "Unexpected nested playlist"
            )
            finish()
        }

        private func sendCachedPrefixBeforeUpstream(
            _ cachedPrefix: CachedPrefixContinuation,
            dataTask: URLSessionDataTask,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let proxy else {
                completionHandler(.cancel)
                dataTask.cancel()
                finish()
                return
            }

            pendingDownstreamSends += 1
            pendingDownstreamBytes += cachedPrefix.data.count
            maximumPendingDownstreamSends = max(maximumPendingDownstreamSends, pendingDownstreamSends)
            maximumPendingDownstreamBytes = max(maximumPendingDownstreamBytes, pendingDownstreamBytes)
            let sendStartedAt = CFAbsoluteTimeGetCurrent()
            proxy.sendData(cachedPrefix.data, on: connection) { [weak self] error in
                self?.callbackQueue.addOperation { [weak self] in
                    guard let self, let proxy = self.proxy else {
                        completionHandler(.cancel)
                        dataTask.cancel()
                        return
                    }

                    self.pendingDownstreamSends = max(0, self.pendingDownstreamSends - 1)
                    self.pendingDownstreamBytes = max(0, self.pendingDownstreamBytes - cachedPrefix.data.count)
                    if let error {
                        Logger.shared.log("\(proxy.logPrefix)[\(self.requestId)]: cached prefix send failed bytes=\(cachedPrefix.data.count) error=\(error)", type: self.errorLogType)
                        completionHandler(.cancel)
                        dataTask.cancel()
                        self.connection.cancel()
                        self.finish()
                        return
                    }

                    self.streamedByteCount += cachedPrefix.data.count
                    let sendMs = (CFAbsoluteTimeGetCurrent() - sendStartedAt) * 1000.0
                    self.maximumDownstreamSendMilliseconds = max(
                        self.maximumDownstreamSendMilliseconds,
                        sendMs
                    )
                    Logger.shared.log("\(proxy.logPrefix)[\(self.requestId)]: sent MPV warmup cached prefix bytes=\(cachedPrefix.data.count) sendMs=\(String(format: "%.0f", sendMs)) upstreamRange=\(cachedPrefix.upstreamRange)", type: self.logType)
                    completionHandler(.allow)
                }
            }
        }

        private func logEclipseRefusal(_ reason: String, phase: String) {
            Logger.shared.log(
                "[MPVProxyTrace \(traceID)] stage=refused-by-eclipse phase=\(phase) req=\(requestSequence) reason=\(reason) session=\(String(sessionId.prefix(8))) target=\(logTarget()); Eclipse's own proxy refused this request, so a playback failure here is an Eclipse bound, not a dead source",
                type: "PlaybackTrace"
            )
        }

        private func streamChunk(_ data: Data, dataTask: URLSessionDataTask, suspendBeforeSend: Bool = true) {
            guard let proxy else {
                dataTask.cancel()
                finish()
                return
            }

            guard !data.isEmpty else {
                dataTask.resume()
                return
            }

            if suspendBeforeSend {
                dataTask.suspend()
            }
            pendingDownstreamSends += 1
            pendingDownstreamBytes += data.count
            maximumPendingDownstreamSends = max(maximumPendingDownstreamSends, pendingDownstreamSends)
            maximumPendingDownstreamBytes = max(maximumPendingDownstreamBytes, pendingDownstreamBytes)
            let sendStartedAt = CFAbsoluteTimeGetCurrent()
            let shouldThrottle = pendingDownstreamBytes >= proxy.maxPendingStreamBytes
                || pendingDownstreamSends >= proxy.maxPendingStreamSends

            proxy.sendData(data, on: connection) { [weak self] error in
                self?.callbackQueue.addOperation { [weak self] in
                    self?.handleStreamSendCompletion(
                        data: data,
                        dataTask: dataTask,
                        sendStartedAt: sendStartedAt,
                        resumeDataTask: shouldThrottle,
                        error: error
                    )
                }
            }

            if !shouldThrottle {
                dataTask.resume()
            }
        }

        private func handleStreamSendCompletion(
            data: Data,
            dataTask: URLSessionDataTask,
            sendStartedAt: CFTimeInterval,
            resumeDataTask: Bool,
            error: NWError?
        ) {
            guard proxy != nil else {
                dataTask.cancel()
                finish()
                return
            }
            guard !finished else { return }

            pendingDownstreamSends = max(0, pendingDownstreamSends - 1)
            pendingDownstreamBytes = max(0, pendingDownstreamBytes - data.count)
            if let error {
                Logger.shared.log("[MPVProxyTrace \(traceID)] stage=downstream-closed req=\(requestSequence) afterBytes=\(streamedByteCount) pending=\(pendingDownstreamSends) pendingBytes=\(pendingDownstreamBytes) error=\(error)", type: logType)
                dataTask.cancel()
                connection.cancel()
                finish()
                return
            }

            streamedByteCount += data.count
            let sendMs = (CFAbsoluteTimeGetCurrent() - sendStartedAt) * 1000.0
            maximumDownstreamSendMilliseconds = max(maximumDownstreamSendMilliseconds, sendMs)
            let now = CFAbsoluteTimeGetCurrent()
            if sendMs > 250, now - lastSlowSendLogAt > 2.0 {
                lastSlowSendLogAt = now
                Logger.shared.log("[MPVProxyTrace \(traceID)] stage=slow-downstream req=\(requestSequence) chunkBytes=\(data.count) sendMs=\(String(format: "%.0f", sendMs)) streamedBytes=\(streamedByteCount) pending=\(pendingDownstreamSends) pendingBytes=\(pendingDownstreamBytes) target=\(logTarget())", type: "PlaybackTrace")
            }

            if pendingStreamCompletionStatusCode == nil, resumeDataTask, !finished {
                dataTask.resume()
            }

            let expected = httpResponse.flatMap { http -> String? in
                http.expectedContentLength >= 0 ? String(http.expectedContentLength) : "unknown"
            } ?? "unknown"
            finishStreamIfReady(expected: expected)
        }

        private func finishStreamIfReady(expected: String) {
            guard let proxy,
                  pendingStreamCompletionStatusCode != nil,
                  pendingDownstreamSends == 0,
                  !finished else {
                return
            }

            pendingStreamCompletionStatusCode = nil
            if let expectedResponseByteCount,
               Int64(streamedByteCount) != expectedResponseByteCount {
                Logger.shared.log(
                    "\(proxy.logPrefix)[\(requestId)]: rejected truncated SkyStream direct response body",
                    type: "Error"
                )
                connection.cancel()
                finish()
                return
            }
            if shouldLogLifecycle {
                Logger.shared.log("[MPVProxyTrace \(traceID)] stage=request-complete req=\(requestSequence) bytes=\(streamedByteCount) expected=\(expected)", type: "PlaybackTrace")
            }
            proxy.finishResponse(on: connection)
            finish()
        }

        private static func validatedDirectResponseByteCount(
            _ response: HTTPURLResponse,
            expectedTotal: Int64
        ) -> Int64? {
            guard expectedTotal > 0,
                  response.value(forHTTPHeaderField: "Transfer-Encoding") == nil,
                  let rawLength = response.value(forHTTPHeaderField: "Content-Length")?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  let contentLength = Int64(rawLength),
                  contentLength >= 0 else { return nil }
            if response.statusCode == 200 {
                return contentLength == expectedTotal ? contentLength : nil
            }
            guard response.statusCode == 206,
                  let rawRange = response.value(forHTTPHeaderField: "Content-Range")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased(),
                  rawRange.hasPrefix("bytes ") else { return nil }
            let pieces = rawRange.dropFirst("bytes ".count).split(separator: "/", maxSplits: 1)
            guard pieces.count == 2,
                  let total = Int64(pieces[1]), total == expectedTotal else { return nil }
            let bounds = pieces[0].split(separator: "-", maxSplits: 1)
            guard bounds.count == 2,
                  let start = Int64(bounds[0]),
                  let end = Int64(bounds[1]),
                  start >= 0, end >= start, end < total,
                  contentLength == end - start + 1 else { return nil }
            return contentLength
        }

        private static func safeErrorDomain(_ value: String) -> String {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
            let scalars = value.unicodeScalars.prefix(96).filter { allowed.contains($0) }
            let sanitized = String(String.UnicodeScalarView(scalars))
            return sanitized.isEmpty ? "unknown" : sanitized
        }

        private func finish() {
            guard !finished else { return }
            let now = CFAbsoluteTimeGetCurrent()
            func milliseconds(_ endpoint: CFTimeInterval?) -> String {
                guard let endpoint else { return "na" }
                return String(format: "%.0f", max(0, endpoint - requestStartedAt) * 1_000)
            }
            let modeName: String
            switch mode {
            case .playlist:
                modeName = "playlist"
            case .probe:
                modeName = "probe"
            case .stream:
                modeName = "stream"
            case .rejectedResponseProbe:
                modeName = "rejected-probe"
            }
            let drainMilliseconds = upstreamCompletedAt.map {
                String(format: "%.0f", max(0, now - $0) * 1_000)
            } ?? "na"
            let taskMilliseconds = transportTaskMilliseconds.map {
                String(format: "%.0f", $0)
            } ?? "na"
            let status = httpResponse.map { String($0.statusCode) } ?? "none"
            let observedBytes = max(bufferedData.count, streamedByteCount + pendingDownstreamBytes)
            Logger.shared.log(
                "[MPVProxyTrace \(traceID)] stage=request-summary req=\(requestSequence) status=\(status) mode=\(modeName) responseMs=\(milliseconds(responseReceivedAt)) firstDataMs=\(milliseconds(firstDataReceivedAt)) upstreamDoneMs=\(milliseconds(upstreamCompletedAt)) drainMs=\(drainMilliseconds) taskMs=\(taskMilliseconds) totalMs=\(String(format: "%.0f", max(0, now - requestStartedAt) * 1_000)) bytes=\(observedBytes) streamed=\(streamedByteCount) peakPending=\(maximumPendingDownstreamSends)/\(maximumPendingDownstreamBytes) maxSendMs=\(String(format: "%.0f", maximumDownstreamSendMilliseconds)) responseHeaders=\(responseHeadersSent)",
                type: "PlaybackTrace"
            )
            finished = true
            continuation?.resume()
            continuation = nil
        }
    }
}

final class MPVHeaderProxy {
    static let shared = MPVHeaderProxy()

    private let proxy = MPVHeaderProxyCore(
        logPrefix: "MPVHeaderProxy",
        playlistMode: .normalizeRewrittenPlaylist,
        gracefulResponseClose: true
    )

    private init() {}

    func makeProxyURL(
        for targetURL: URL,
        headers: [String: String],
        logType: String = "MPV",
        traceID: String? = nil,
        stremioAuthority: SkyStreamPinnedOriginAuthority? = nil,
        onConfirmedCloudflareChallenge: ((URL, String?, Bool, Int) -> Void)? = nil
    ) -> URL? {
        proxy.makeProxyURL(
            for: targetURL,
            headers: headers,
            logType: logType,
            traceID: traceID,
            stremioAuthority: stremioAuthority,
            onConfirmedCloudflareChallenge: onConfirmedCloudflareChallenge
        )
    }

#if os(iOS) && !targetEnvironment(macCatalyst)

    func isManagedSkyStreamSessionURL(_ streamProxyURL: URL) -> Bool {
        proxy.isManagedSkyStreamSessionURL(streamProxyURL)
    }

    func makeSkyStreamProxyURL(
        for descriptor: SkyStreamValidatedPlaybackDescriptor,
        traceID: String? = nil,
        onValidatedRouteRejection: ((URL, Int, Bool) -> Void)? = nil
    ) -> URL? {
        proxy.makeSkyStreamProxyURL(
            for: descriptor,
            traceID: traceID,
            onValidatedRouteRejection: onValidatedRouteRejection
        )
    }

    func skyStreamSubtitleProxyURLs(
        for descriptor: SkyStreamValidatedPlaybackDescriptor,
        streamProxyURL: URL
    ) -> [String: URL]? {
        proxy.skyStreamSubtitleProxyURLs(for: descriptor, streamProxyURL: streamProxyURL)
    }

    @discardableResult
    func setSkyStreamRouteRejectionHandler(
        for streamProxyURL: URL,
        handler: @escaping (URL, Int, Bool) -> Void
    ) -> Bool {
        proxy.setSkyStreamRouteRejectionHandler(for: streamProxyURL, handler: handler)
    }
#endif

    func invalidateSession(for proxyURL: URL) {
        proxy.invalidateSession(for: proxyURL)
    }

    func originalTargetURL(for proxyURL: URL) -> URL? {
        proxy.originalTargetURL(for: proxyURL)
    }

    func upstreamHealth(for proxyURL: URL) -> MPVHeaderProxyUpstreamHealth? {
        proxy.upstreamHealth(for: proxyURL)
    }

    func upstreamProbeTarget(for proxyURL: URL) -> (url: URL, headers: [String: String])? {
        proxy.upstreamProbeTarget(for: proxyURL)
    }
}
