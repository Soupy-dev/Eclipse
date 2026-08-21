// Copyright 2026 Eclipse contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Compression
import CryptoKit
import Combine
import Darwin
import Foundation
import Network
import Security

struct ReaderExtensionDomainConsentRequest: Identifiable, Equatable, Sendable {
    var id: String { "\(scopeID):\(sourceID.rawValue):\(host)" }
    let scopeID: String
    let sourceID: ReaderExtensionSourceID
    let host: String

    init(scopeID: String, sourceID: ReaderExtensionSourceID, host: String) {
        self.scopeID = scopeID
        self.sourceID = sourceID
        self.host = ReaderExtensionSecurityPolicy.canonicalHost(host) ?? ""
    }
}

@MainActor
final class ReaderExtensionDomainConsentCoordinator: ObservableObject {
    static let shared = ReaderExtensionDomainConsentCoordinator()
    /// Only unclaimed requests are published here for the global fallback UI.
    @Published private(set) var pendingRequest: ReaderExtensionDomainConsentRequest?
    private struct QueuedRequest {
        let request: ReaderExtensionDomainConsentRequest
        let receivedAt: TimeInterval
    }
    private var queue: [QueuedRequest] = []
    private var claimedRequestIDs: [String: TimeInterval] = [:]
    private var promotionTask: Task<Void, Never>?
    private let claimWindow: TimeInterval
    private let requestLifetime: TimeInterval
    private let claimLifetime: TimeInterval
    private let maximumPendingRequests: Int
    private let maximumPendingRequestsPerSource: Int
    private let uptime: () -> TimeInterval

    init(
        claimWindow: TimeInterval = 0.25,
        requestLifetime: TimeInterval = 5 * 60,
        claimLifetime: TimeInterval = 5 * 60,
        maximumPendingRequests: Int = 64,
        maximumPendingRequestsPerSource: Int = 8,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.claimWindow = max(0, claimWindow)
        self.requestLifetime = max(0.05, requestLifetime)
        self.claimLifetime = max(0.02, claimLifetime)
        self.maximumPendingRequests = min(max(1, maximumPendingRequests), 256)
        self.maximumPendingRequestsPerSource = min(
            max(1, maximumPendingRequestsPerSource),
            self.maximumPendingRequests
        )
        self.uptime = uptime
    }

    var queuedRequestCount: Int { queue.count }
    var claimedRequestCount: Int { claimedRequestIDs.count }

    nonisolated static func emit(sourceID: ReaderExtensionSourceID, host: String, scopeID: String) {
        let request = ReaderExtensionDomainConsentRequest(
            scopeID: scopeID,
            sourceID: sourceID,
            host: host
        )
        guard !request.host.isEmpty else { return }
        Task { @MainActor in shared.enqueue(request) }
    }

    func resolve(sourceID: ReaderExtensionSourceID, host: String, scopeID: String) {
        guard let host = ReaderExtensionSecurityPolicy.canonicalHost(host) else { return }
        let id = "\(scopeID):\(sourceID.rawValue):\(host)"
        queue.removeAll { $0.request.id == id }
        claimedRequestIDs.removeValue(forKey: id)
        if pendingRequest?.id == id { pendingRequest = nil }
        scheduleGlobalPromotion()
    }

    func deferCurrentRequest() {
        guard let current = pendingRequest else { return }
        queue.removeAll { $0.request.id == current.id }
        claimedRequestIDs.removeValue(forKey: current.id)
        pendingRequest = nil
        scheduleGlobalPromotion()
    }

    func `defer`(_ request: ReaderExtensionDomainConsentRequest) {
        queue.removeAll { $0.request.id == request.id }
        claimedRequestIDs.removeValue(forKey: request.id)
        if pendingRequest?.id == request.id { pendingRequest = nil }
        scheduleGlobalPromotion()
    }

    /// Contextual reader/settings UI claims the exact request it will present.
    /// A duplicate claimant loses, and the global fallback never presents the
    /// same request during the short claim window.
    @discardableResult
    func claim(_ request: ReaderExtensionDomainConsentRequest) -> Bool {
        let now = uptime()
        pruneExpired(now: now)
        guard requestIsBounded(request),
              claimedRequestIDs[request.id] == nil,
              pendingRequest?.id != request.id else { return false }
        if !queue.contains(where: { $0.request.id == request.id }) {
            guard canEnqueue(request) else { return false }
            queue.append(QueuedRequest(request: request, receivedAt: now))
        }
        claimedRequestIDs[request.id] = now
        if pendingRequest?.id == request.id { pendingRequest = nil }
        scheduleGlobalPromotion()
        return true
    }

    func resetForScopeChange() {
        promotionTask?.cancel()
        promotionTask = nil
        queue.removeAll()
        claimedRequestIDs.removeAll()
        pendingRequest = nil
    }

    func enqueue(_ request: ReaderExtensionDomainConsentRequest) {
        let now = uptime()
        pruneExpired(now: now)
        guard requestIsBounded(request) else { return }
        guard pendingRequest?.id != request.id,
              !queue.contains(where: { $0.request.id == request.id }) else { return }
        guard canEnqueue(request) else { return }
        queue.append(QueuedRequest(
            request: request,
            receivedAt: now
        ))
        scheduleGlobalPromotion()
    }

    private func scheduleGlobalPromotion() {
        promotionTask?.cancel()
        promotionTask = nil
        let now = uptime()
        pruneExpired(now: now)
        let delay: TimeInterval
        if let pendingRequest,
           let pending = queue.first(where: { $0.request.id == pendingRequest.id }) {
            delay = max(0, requestLifetime - (now - pending.receivedAt))
        } else if let candidate = queue.first(where: {
            claimedRequestIDs[$0.request.id] == nil
        }) {
            delay = max(0, claimWindow - (now - candidate.receivedAt))
        } else if let nextClaimExpiry = claimedRequestIDs.values.min() {
            delay = max(0, claimLifetime - (now - nextClaimExpiry))
        } else {
            return
        }
        promotionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.promoteNextUnclaimedRequest()
        }
    }

    private func promoteNextUnclaimedRequest() {
        let now = uptime()
        pruneExpired(now: now)
        if pendingRequest == nil,
           let candidate = queue.first(where: {
               claimedRequestIDs[$0.request.id] == nil
           }), now - candidate.receivedAt >= claimWindow {
            pendingRequest = candidate.request
        }
        scheduleGlobalPromotion()
    }

    private func canEnqueue(_ request: ReaderExtensionDomainConsentRequest) -> Bool {
        guard queue.count < maximumPendingRequests else { return false }
        return queue.lazy.filter { $0.request.sourceID == request.sourceID }.count
            < maximumPendingRequestsPerSource
    }

    private func requestIsBounded(_ request: ReaderExtensionDomainConsentRequest) -> Bool {
        !request.host.isEmpty
            && request.host.utf8.count <= 253
            && !request.scopeID.isEmpty
            && request.scopeID.utf8.count <= 128
            && !request.sourceID.rawValue.isEmpty
            && request.sourceID.rawValue.utf8.count <= 64
    }

    private func pruneExpired(now: TimeInterval) {
        let expiredIDs = Set(queue.compactMap { queued -> String? in
            now - queued.receivedAt >= requestLifetime ? queued.request.id : nil
        })
        if !expiredIDs.isEmpty {
            queue.removeAll { expiredIDs.contains($0.request.id) }
            expiredIDs.forEach { claimedRequestIDs.removeValue(forKey: $0) }
            if let pendingRequest, expiredIDs.contains(pendingRequest.id) {
                self.pendingRequest = nil
            }
        }
        let queuedIDs = Set(queue.map { $0.request.id })
        claimedRequestIDs = claimedRequestIDs.filter { id, claimedAt in
            queuedIDs.contains(id) && now - claimedAt < claimLifetime
        }
    }
}

enum ReaderExtensionJSONPreflight {
    struct Limits: Sendable {
        var maximumBytes: Int
        var maximumDepth: Int
        var maximumContainerEntries: Int
        var maximumTopLevelEntries: Int?
        var maximumTotalTokens: Int
        var maximumStringBytes: Int

        init(
            maximumBytes: Int,
            maximumDepth: Int = 32,
            maximumContainerEntries: Int,
            maximumTopLevelEntries: Int? = nil,
            maximumTotalTokens: Int,
            maximumStringBytes: Int? = nil
        ) {
            self.maximumBytes = maximumBytes
            self.maximumDepth = maximumDepth
            self.maximumContainerEntries = maximumContainerEntries
            self.maximumTopLevelEntries = maximumTopLevelEntries
            self.maximumTotalTokens = maximumTotalTokens
            self.maximumStringBytes = maximumStringBytes ?? maximumBytes
        }
    }

    private struct Container {
        var closingByte: UInt8
        var separators = 0
        var hasContent = false
    }

    /// Performs a string/escape-aware structural pass before Foundation builds
    /// an object graph. Foundation remains the JSON grammar authority; this
    /// pass exists only to bound depth and allocation-amplifying structure.
    static func validate(_ data: Data, limits: Limits) throws {
        guard data.count <= limits.maximumBytes,
              limits.maximumDepth > 0,
              limits.maximumContainerEntries > 0,
              limits.maximumTopLevelEntries.map({ $0 > 0 }) ?? true,
              limits.maximumTotalTokens > 0,
              limits.maximumStringBytes >= 0 else {
            throw ReaderExtensionError.contentTooLarge
        }
        let bytes = [UInt8](data)
        var stack: [Container] = []
        stack.reserveCapacity(min(limits.maximumDepth, 32))
        var cursor = 0
        var totalTokens = 0

        func consumeToken() throws {
            guard totalTokens < limits.maximumTotalTokens else {
                throw ReaderExtensionError.contentTooLarge
            }
            totalTokens += 1
        }
        func markParentContent() {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].hasContent = true
        }

        while cursor < bytes.count {
            let byte = bytes[cursor]
            if isWhitespace(byte) { cursor += 1; continue }
            switch byte {
            case 0x7b, 0x5b: // { [
                try consumeToken()
                markParentContent()
                stack.append(Container(closingByte: byte == 0x7b ? 0x7d : 0x5d))
                guard stack.count <= limits.maximumDepth else {
                    throw ReaderExtensionError.contentTooLarge
                }
                cursor += 1
            case 0x7d, 0x5d: // } ]
                guard let container = stack.last, container.closingByte == byte else {
                    throw ReaderExtensionError.resultInvalid("JSON container structure is invalid")
                }
                let entries = container.hasContent ? container.separators + 1 : 0
                let maximumEntries = stack.count == 1
                    ? (limits.maximumTopLevelEntries ?? limits.maximumContainerEntries)
                    : limits.maximumContainerEntries
                guard entries <= maximumEntries else {
                    throw ReaderExtensionError.contentTooLarge
                }
                stack.removeLast()
                cursor += 1
            case 0x2c: // ,
                guard !stack.isEmpty else {
                    throw ReaderExtensionError.resultInvalid("JSON separator is outside a container")
                }
                stack[stack.count - 1].separators += 1
                let maximumEntries = stack.count == 1
                    ? (limits.maximumTopLevelEntries ?? limits.maximumContainerEntries)
                    : limits.maximumContainerEntries
                guard stack[stack.count - 1].separators < maximumEntries else {
                    throw ReaderExtensionError.contentTooLarge
                }
                cursor += 1
            case 0x3a: // :
                cursor += 1
            case 0x22: // string
                try consumeToken()
                markParentContent()
                cursor += 1
                var stringBytes = 0
                var terminated = false
                while cursor < bytes.count {
                    let value = bytes[cursor]
                    if value == 0x22 {
                        cursor += 1
                        terminated = true
                        break
                    }
                    if value == 0x5c { // escaped byte (including escaped quote/backslash)
                        cursor += 1
                        guard cursor < bytes.count else {
                            throw ReaderExtensionError.resultInvalid("JSON string escape is incomplete")
                        }
                        stringBytes += 2
                    } else {
                        stringBytes += 1
                    }
                    guard stringBytes <= limits.maximumStringBytes else {
                        throw ReaderExtensionError.contentTooLarge
                    }
                    cursor += 1
                }
                guard terminated else {
                    throw ReaderExtensionError.resultInvalid("JSON string is unterminated")
                }
            default:
                try consumeToken()
                markParentContent()
                let start = cursor
                while cursor < bytes.count,
                      !isWhitespace(bytes[cursor]),
                      ![0x2c, 0x3a, 0x5d, 0x7d, 0x5b, 0x7b, 0x22].contains(bytes[cursor]) {
                    cursor += 1
                }
                guard cursor > start else {
                    throw ReaderExtensionError.resultInvalid("JSON token is invalid")
                }
            }
        }
        guard stack.isEmpty else {
            throw ReaderExtensionError.resultInvalid("JSON container is unterminated")
        }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x09 || byte == 0x0a || byte == 0x0d || byte == 0x20
    }
}

enum ReaderExtensionSecurityPolicy {
    static let maximumRepositoryBytes = 4 * 1_024 * 1_024
    static let maximumScriptBytes = 4 * 1_024 * 1_024
    static let maximumResponseBytes = 8 * 1_024 * 1_024
    /// Covers are sometimes published only as original artwork. Keep their
    /// transport budget separate from ordinary HTML/JSON responses so a
    /// moderately large poster does not disappear while general source
    /// operations remain capped at 8 MiB. Pixel/decode bounds still apply
    /// after download.
    static let maximumAssetResponseBytes = 12 * 1_024 * 1_024
    static let maximumPageResponseBytes = 32 * 1_024 * 1_024
    static let maximumRequestBodyBytes = 2 * 1_024 * 1_024
    static let maximumHeaderCount = 64
    static let maximumHeaderBytes = 32 * 1_024
    static let maximumResultRows = 500
    /// Sized against real catalog pages, not synthetic ones. WeebCentral's
    /// One Piece full-chapter-list is a single legitimate 2.2 MiB document
    /// with 17,853 elements and 58,318 attributes; sources with 3,000+
    /// chapters roughly double that. Caps below any of these silently break
    /// mainstream series while looking like provider defects.
    static let maximumDOMBytes = 12 * 1_024 * 1_024
    static let maximumDOMElementsPerDocument = 131_072
    static let maximumDOMDocumentsPerOperation = 16
    static let maximumDOMHandlesPerOperation = 32_768
    static let maximumDOMSelectedRows = 4_096
    static let maximumDOMReturnedBytesPerOperation = 4 * 1_024 * 1_024
    static let maximumFetchesPerOperation = 150
    static let maximumFetchResponseBytesPerOperation = 32 * 1_024 * 1_024
    static let maximumConcurrentFetchesPerOperation = 8
    static let maximumConcurrentRuntimeOperations = 4
    static let operationTimeout: TimeInterval = 60
    static let maximumPreferenceCount = 200
    static let maximumPreferenceKeyBytes = 256
    static let maximumPreferenceValueBytes = 16 * 1_024
    static let maximumPreferenceListCount = 200

    /// Mangayomi extensions commonly target Android HTTP clients that supply
    /// a User-Agent even when the extension omits getHeaders(). Several HTML
    /// sources reject a completely headerless client. Use one stable,
    /// non-device-specific browser token only as a host default; an extension
    /// supplied User-Agent always wins.
    static let defaultReaderUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 EclipseReader/1"

    /// Stable, non-device-specific companions to the default User-Agent.
    /// WAF heuristics score a bare `User-Agent`-only request as automation;
    /// WeebCentral's edge intermittently answered exactly such requests with
    /// a challenge page that parsed as an empty catalog.
    static let defaultReaderAcceptHeader = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8"
    static let defaultReaderAcceptLanguageHeader = "en-US,en;q=0.9"

    static func headersByApplyingHostDefaults(_ input: [String: String]) -> [String: String] {
        var output = input
        let defaults = [
            ("User-Agent", defaultReaderUserAgent),
            ("Accept", defaultReaderAcceptHeader),
            ("Accept-Language", defaultReaderAcceptLanguageHeader)
        ]
        for (name, value) in defaults where !input.keys.contains(where: {
            $0.caseInsensitiveCompare(name) == .orderedSame
        }) {
            output[name] = value
        }
        return output
    }

    private static let credentialQueryNames: Set<String> = [
        "accesstoken", "auth", "authtoken", "authorization", "apikey",
        "bearer", "clientsecret", "cookie", "csrf", "jwt", "password",
        "passwd", "refreshtoken", "session", "sessionid", "sig",
        "signature", "token", "xsrf", "secret", "secrets", "credential",
        "credentials", "xapikey"
    ]

    /// Provider item/chapter identities are durable metadata, not an
    /// authorization channel. Preserve ordinary query identifiers while
    /// rejecting credential-bearing keys before they reach persistence.
    static func persistableProviderContentKey(
        _ rawValue: String,
        maximumBytes: Int = 16 * 1_024
    ) -> String? {
        guard !rawValue.isEmpty, rawValue.utf8.count <= maximumBytes,
              !rawValue.contains("\0"), !rawValue.contains("\r"), !rawValue.contains("\n") else {
            return nil
        }
        guard let components = URLComponents(string: rawValue) else {
            return rawValue.contains("?") || rawValue.contains("://") || rawValue.hasPrefix("//")
                ? nil
                : rawValue
        }
        guard components.user == nil, components.password == nil, components.fragment == nil else {
            return nil
        }
        if components.percentEncodedQuery != nil, components.queryItems == nil { return nil }
        for item in components.queryItems ?? [] where isCredentialLikeQueryName(item.name) {
            return nil
        }
        return rawValue
    }

    static func isCredentialLikeQueryName(_ name: String) -> Bool {
        let normalized = name.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
        return credentialQueryNames.contains(normalized) || isCredentialLikePreferenceKey(name)
    }

    /// Icon URLs are the one metadata field whose query can be the resource
    /// identity itself — Google's favicon service encodes the target site in
    /// `domain=`, and stripping it turns every such icon into a 404. Keep the
    /// query minus credential-bearing parameter names.
    static func sanitizedIconURL(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host != nil else { return nil }
        components.user = nil
        components.password = nil
        components.fragment = nil
        if let items = components.queryItems, !items.isEmpty {
            let safe = items.filter { !isCredentialLikeQueryName($0.name) }
            components.queryItems = safe.isEmpty ? nil : safe
        }
        return components.url
    }

    /// One canonical representation for DNS, consent identities, origins and
    /// cookie-domain comparisons. Foundation's URL host form supplies IDNA
    /// ASCII (punycode); terminal root dots and cookie leading dots do not
    /// create a second consent identity for the same DNS name.
    static func canonicalHost(_ rawHost: String?) -> String? {
        guard var value = rawHost, !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        if value.hasPrefix("["), value.hasSuffix("]") {
            value.removeFirst()
            value.removeLast()
        }
        while value.hasPrefix(".") { value.removeFirst() }
        while value.hasSuffix(".") { value.removeLast() }
        guard !value.isEmpty else { return nil }

        var ipv4 = in_addr()
        if inet_pton(AF_INET, value, &ipv4) == 1 {
            var copy = ipv4
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &copy, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return String(cString: buffer)
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, value, &ipv6) == 1 {
            var copy = ipv6
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &copy, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return String(cString: buffer).lowercased()
        }
        // A colon that was not a valid IPv6 literal cannot be a DNS host.
        guard !value.contains(":") else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = value
        guard var canonical = components.url?.host?.lowercased() else { return nil }
        while canonical.hasPrefix(".") { canonical.removeFirst() }
        while canonical.hasSuffix(".") { canonical.removeLast() }
        let labels = canonical.split(separator: ".", omittingEmptySubsequences: false)
        guard !canonical.isEmpty, canonical.utf8.count <= 253,
              labels.allSatisfy({ label in
                  guard !label.isEmpty, label.utf8.count <= 63,
                        let first = label.utf8.first, let last = label.utf8.last else { return false }
                  let isAlphaNumeric: (UInt8) -> Bool = {
                      (48...57).contains($0) || (97...122).contains($0)
                  }
                  return isAlphaNumeric(first) && isAlphaNumeric(last)
                      && label.utf8.allSatisfy { isAlphaNumeric($0) || $0 == 45 }
              }) else { return nil }
        return canonical
    }

    static func canonicalHost(of url: URL) -> String? { canonicalHost(url.host) }

    static func canonicalHosts<S: Sequence>(_ hosts: S) -> Set<String> where S.Element == String {
        Set(hosts.compactMap(canonicalHost))
    }

    static func canonicalHTTPSURL(forHost rawHost: String) -> URL? {
        guard let host = canonicalHost(rawHost) else { return nil }
        let authority = host.contains(":") ? "[\(host)]" : host
        return URL(string: "https://\(authority)/")
    }

    static func host(_ rawHost: String, isEqualToOrSubdomainOf rawDomain: String) -> Bool {
        guard let host = canonicalHost(rawHost), let domain = canonicalHost(rawDomain) else { return false }
        return host == domain || host.hasSuffix(".\(domain)")
    }

    static func cookie(
        _ cookie: HTTPCookie,
        mayBeSentTo url: URL,
        approvedDomains: Set<String>,
        now: Date = Date()
    ) -> Bool {
        guard let requestHost = canonicalHost(of: url),
              let cookieDomain = canonicalHost(cookie.domain) else { return false }
        let approved = canonicalHosts(approvedDomains)
        let requestPath = url.path.isEmpty ? "/" : url.path
        let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
        return host(requestHost, isEqualToOrSubdomainOf: cookieDomain)
            // Re-check the cookie's own scope against current consent. A broad
            // historical Domain=.example.com cookie must not survive an
            // approval shrink to reader.example.com merely because it matches
            // that request host under ordinary RFC cookie rules.
            && approved.contains(where: {
                host(cookieDomain, isEqualToOrSubdomainOf: $0)
            })
            && (!cookie.isSecure || url.scheme?.lowercased() == "https")
            && (cookie.expiresDate.map { $0 > now } ?? true)
            && (cookiePath == "/" || requestPath == cookiePath
                || requestPath.hasPrefix(cookiePath.hasSuffix("/") ? cookiePath : "\(cookiePath)/"))
    }

    private static let forbiddenRequestHeaders: Set<String> = [
        "connection", "content-length", "cookie", "host", "proxy-authorization",
        "proxy-connection", "set-cookie", "transfer-encoding", "upgrade"
    ]

    /// Only standardized representation-selection, cache, conditional, and
    /// range headers survive an origin change. Unknown `X-*` and vendor
    /// headers are not provably non-secret, so they fail closed even when a
    /// particular spelling does not match the credential heuristic below.
    private static let crossOriginSafeRequestHeaders: Set<String> = [
        "accept", "accept-charset", "accept-language", "cache-control",
        "if-match", "if-modified-since", "if-none-match", "if-range",
        "if-unmodified-since", "pragma", "range", "user-agent"
    ]

    /// Headers that can authorize a request are origin-bound even when an
    /// extension gives them a non-standard name. This deliberately matches
    /// token/secret/credential components instead of maintaining a short list
    /// of vendor spellings such as `X-API-Key` and `X-Auth-Token`.
    static func isCredentialLikeHeader(name: String, value: String) -> Bool {
        let lower = name.lowercased()
        let components = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let credentialComponents: Set<String> = [
            "auth", "authorization", "credential", "credentials", "secret",
            "token", "apikey", "key", "password", "passwd", "session",
            "sessionkey", "signature", "csrf", "xsrf"
        ]
        if components.contains(where: { credentialComponents.contains($0.lowercased()) }) {
            return true
        }
        if lower.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
            .range(of: "(?:authorization|credential|secret|token|apikey|sessionkey|password|passwd|signature)", options: .regularExpression) != nil {
            return true
        }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.range(
            of: "^(?:bearer|basic|digest|token|apikey|api-key|key)\\s+\\S+",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// Preference names are untrusted script input. Treat both schema-declared
    /// secrets and common credential spellings as Keychain-only even when an
    /// extension attempts to write them through ordinary SharedPreferences.
    static func isCredentialLikePreferenceKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        let components = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let credentialComponents: Set<String> = [
            "auth", "authorization", "credential", "credentials", "secret",
            "token", "apikey", "password", "passwd", "session", "sessionkey",
            "cookie", "csrf", "xsrf", "signature"
        ]
        if components.contains(where: { credentialComponents.contains($0) }) { return true }
        let collapsed = lower.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        return collapsed.range(
            of: "(?:authorization|credential|secret|token|apikey|sessionkey|password|passwd|cookie|signature)",
            options: .regularExpression
        ) != nil
    }

    static func validatePreference(key: String, value: ReaderExtensionPreferenceValue) throws {
        try validatePreferenceKey(key)
        guard !value.isSecret else {
            throw ReaderExtensionError.persistenceFailed("Secret values must use Keychain storage")
        }
        let bytes: Int
        switch value {
        case .string(let string):
            bytes = string.utf8.count
        case .bool:
            bytes = 1
        case .number(let number):
            guard number.isFinite else { throw ReaderExtensionError.contentTooLarge }
            bytes = 8
        case .stringList(let list):
            guard list.count <= maximumPreferenceListCount else { throw ReaderExtensionError.contentTooLarge }
            bytes = list.reduce(0) { $0 + $1.utf8.count }
        case .secretReference:
            throw ReaderExtensionError.persistenceFailed("Secret values must use Keychain storage")
        }
        guard bytes <= maximumPreferenceValueBytes else { throw ReaderExtensionError.contentTooLarge }
    }

    static func validatePreferenceSecret(key: String, value: String?) throws {
        try validatePreferenceKey(key)
        guard (value?.utf8.count ?? 0) <= maximumPreferenceValueBytes else {
            throw ReaderExtensionError.contentTooLarge
        }
    }

    private static func validatePreferenceKey(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= maximumPreferenceKeyBytes,
              !key.contains("\0"), !key.contains("\r"), !key.contains("\n") else {
            throw ReaderExtensionError.contentTooLarge
        }
    }

    static func validateRepositoryURL(_ url: URL) throws {
        try validateRepositoryURLSyntax(url)
        try validatePublicURL(url, requireHTTPS: true)
    }

    static func validateRepositoryURLSyntax(_ url: URL) throws {
        try validatePublicURLSyntax(url, requireHTTPS: true)
        guard ["index.json", "novel_index.json"].contains(url.lastPathComponent.lowercased()) else {
            throw ReaderExtensionError.invalidRepositoryURL
        }
        guard url.user == nil, url.password == nil, url.fragment == nil, url.query == nil else {
            throw ReaderExtensionError.invalidRepositoryURL
        }
    }

    static func validateScriptURL(_ url: URL) throws {
        try validateScriptURLSyntax(url)
        try validatePublicURL(url, requireHTTPS: true)
    }

    static func validateScriptURLSyntax(_ url: URL) throws {
        try validatePublicURLSyntax(url, requireHTTPS: true)
        guard url.pathExtension.lowercased() == "js", url.user == nil, url.password == nil,
              url.fragment == nil, url.query == nil else {
            throw ReaderExtensionError.insecureURL
        }
    }

    static func validatePublicURL(_ url: URL, requireHTTPS: Bool = false) throws {
        try validatePublicURLSyntax(url, requireHTTPS: requireHTTPS)
        guard let host = canonicalHost(of: url) else { throw ReaderExtensionError.insecureURL }
        try validateResolvedAddresses(host: host)
    }

    static func validatePublicURLSyntax(_ url: URL, requireHTTPS: Bool = false) throws {
        guard let scheme = url.scheme?.lowercased(), let normalized = canonicalHost(of: url) else {
            throw ReaderExtensionError.insecureURL
        }
        if requireHTTPS {
            guard scheme == "https" else { throw ReaderExtensionError.insecureURL }
        } else {
            guard scheme == "https" || scheme == "http" else { throw ReaderExtensionError.insecureURL }
        }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        // Keep a deliberately tiny explicit allowlist. 8443 is the ordinary
        // alternate HTTPS port used by some reader login endpoints; arbitrary
        // service, proxy, and administration ports remain blocked.
        guard (scheme == "https" && [443, 8443].contains(port))
                || (scheme == "http" && port == 80) else {
            throw ReaderExtensionError.insecureURL
        }
        guard url.user == nil, url.password == nil else { throw ReaderExtensionError.insecureURL }
        guard normalized != "localhost", !normalized.hasSuffix(".localhost"), !normalized.hasSuffix(".local"),
              !normalized.hasSuffix(".internal"), !normalized.hasSuffix(".home"), !normalized.hasSuffix(".lan") else {
            throw ReaderExtensionError.privateNetworkDestination
        }
        if normalized.range(of: "^[0-9.]+$", options: .regularExpression) != nil {
            var address = in_addr()
            guard inet_pton(AF_INET, normalized, &address) == 1, isPublicIPv4(address.s_addr.bigEndian) else {
                throw ReaderExtensionError.privateNetworkDestination
            }
        }
    }

    /// Optional repository/license links are display metadata, never an
    /// authorization channel. Keep only ordinary web URLs with stable,
    /// non-secret components so a crafted backup cannot surface a clickable
    /// file URL or carry credentials in a query/fragment/userinfo field.
    static func sanitizedMetadataDisplayURL(_ url: URL?) -> URL? {
        guard let url,
              url.absoluteString.utf8.count <= 16 * 1_024,
              (try? validatePublicURLSyntax(url)) != nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            return nil
        }
        return url
    }

    static func validateApprovedDomain(_ url: URL, approvedDomains: Set<String>) throws {
        guard let host = canonicalHost(of: url) else { throw ReaderExtensionError.insecureURL }
        let approved = canonicalHosts(approvedDomains)
        guard approved.contains(host) else { throw ReaderExtensionError.domainConsentRequired(host) }
    }

    static func validatedAssetURL(
        _ candidate: URL?,
        sourceID _: ReaderExtensionSourceID,
        approvedDomains _: Set<String>,
        consentScopeID _: String
    ) -> URL? {
        guard let candidate else { return nil }
        do {
            // Covers and thumbnails are passive, cookie-free resources. Keep
            // the URL after cheap structural admission so large result sets do
            // not synchronously resolve DNS or manufacture consent prompts for
            // ordinary image CDNs. The pinned transport still resolves and
            // rejects private destinations immediately before every request.
            guard candidate.absoluteString.utf8.count <= 16 * 1_024 else {
                throw ReaderExtensionError.contentTooLarge
            }
            try validatePublicURLSyntax(candidate)
            try validateNotArchive(data: Data(), response: nil, url: candidate)
            return candidate
        } catch {
            return nil
        }
    }

    static func sanitizedHeaders(_ input: [String: String], crossOrigin: Bool) throws -> [String: String] {
        guard input.count <= maximumHeaderCount else { throw ReaderExtensionError.contentTooLarge }
        var output: [String: String] = [:]
        var bytes = 0
        for (rawName, rawValue) in input {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = name.lowercased()
            guard !name.isEmpty, name.range(of: "^[!#$%&'*+.^_`|~0-9A-Za-z-]+$", options: .regularExpression) != nil,
                  !forbiddenRequestHeaders.contains(lower) else { continue }
            if crossOrigin {
                guard crossOriginSafeRequestHeaders.contains(lower),
                      !isCredentialLikeHeader(name: name, value: rawValue) else { continue }
            }
            let value = rawValue.replacingOccurrences(of: "[\\r\\n]", with: "", options: .regularExpression)
            bytes += name.utf8.count + value.utf8.count
            guard bytes <= maximumHeaderBytes else { throw ReaderExtensionError.contentTooLarge }
            output[name] = String(value.prefix(8 * 1_024))
        }
        return output
    }

    static func hostGeneratedOriginReferer(
        for request: ReaderExtensionNetworkRequest,
        targetURL: URL
    ) throws -> String? {
        guard let candidate = request.hostGeneratedOriginReferer else { return nil }
        // Never add even the source origin to plaintext cross-origin traffic.
        // Native image CDNs use HTTPS; ordinary HTTP requests retain the
        // existing no-credential/no-referrer posture.
        guard targetURL.scheme?.lowercased() == "https" else { return nil }
        try validatePublicURLSyntax(candidate)
        guard candidate.absoluteString.utf8.count <= 16 * 1_024,
              let candidateHost = canonicalHost(of: candidate),
              let baseHost = canonicalHost(request.baseDomain),
              candidateHost == baseHost,
              canonicalHosts(request.approvedDomains).contains(candidateHost),
              var components = URLComponents(url: candidate, resolvingAgainstBaseURL: false) else {
            throw ReaderExtensionError.insecureURL
        }
        components.user = nil
        components.password = nil
        components.path = "/"
        components.query = nil
        components.fragment = nil
        guard let origin = components.url,
              origin.user == nil,
              origin.password == nil,
              origin.query == nil,
              origin.fragment == nil else {
            throw ReaderExtensionError.insecureURL
        }
        return origin.absoluteString
    }

    static func validateNotArchive(data: Data, response: HTTPURLResponse?, url: URL) throws {
        let lowerPath = url.path.lowercased()
        let blockedExtensions = ["epub", "pdf", "zip", "rar", "7z", "cbz", "cbr"]
        if blockedExtensions.contains(where: { lowerPath.hasSuffix(".\($0)") }) {
            throw ReaderExtensionError.unsupportedArchive
        }
        let contentType = response?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let disposition = response?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        let blockedMIMEs = ["application/epub+zip", "application/pdf", "application/zip", "application/x-rar", "application/vnd.rar", "application/x-7z-compressed", "application/x-cbr", "application/x-cbz"]
        if blockedMIMEs.contains(where: contentType.contains) || blockedExtensions.contains(where: { disposition.contains(".\($0)") }) {
            throw ReaderExtensionError.unsupportedArchive
        }
        // A few servers prepend transport/proxy bytes before the real file
        // header. Inspect a bounded prefix instead of trusting byte zero.
        // ZIP also has valid empty-archive and spanned-archive signatures.
        let prefix = [UInt8](data.prefix(1_024))
        let containsSignature: ([UInt8]) -> Bool = { signature in
            guard !signature.isEmpty, prefix.count >= signature.count else { return false }
            return prefix.indices.dropLast(signature.count - 1).contains { start in
                prefix[start..<(start + signature.count)].elementsEqual(signature)
            }
        }
        if containsSignature([0x50, 0x4b, 0x03, 0x04]) || // ZIP local header
            containsSignature([0x50, 0x4b, 0x05, 0x06]) || // empty ZIP
            containsSignature([0x50, 0x4b, 0x07, 0x08]) || // spanned ZIP
            containsSignature([0x25, 0x50, 0x44, 0x46]) || // PDF
            containsSignature([0x52, 0x61, 0x72, 0x21]) || // RAR
            containsSignature([0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c]) { // 7z
            throw ReaderExtensionError.unsupportedArchive
        }
    }

    static func validateScript(_ data: Data) throws -> String {
        guard data.count <= maximumScriptBytes else { throw ReaderExtensionError.contentTooLarge }
        guard let code = String(data: data, encoding: .utf8) else { throw ReaderExtensionError.invalidScriptEncoding }
        let scanner = ReaderExtensionJavaScriptScanner(code: code)
        if let prohibited = scanner.firstProhibitedConstruct {
            throw ReaderExtensionError.prohibitedScriptConstruct(prohibited)
        }
        guard scanner.containsDefaultExtension else {
            throw ReaderExtensionError.invalidManifest("JavaScript must declare DefaultExtension")
        }
        return code
    }

    static func resolvedPublicAddresses(host: String) throws -> [String] {
        let resolved = try resolveAddresses(host: host, family: AF_UNSPEC, flags: AI_ADDRCONFIG)

        // On an IPv6-only access network, DNS64 can return a globally scoped
        // IPv6 address whose embedded IPv4 destination is private.  Resolving
        // ipv4only.arpa through the same system resolver discovers the active,
        // interface-specific RFC 6052 prefix(es), including network-specific
        // /32, /40, /48, /56, /64 and /96 prefixes.  Do this for every lookup
        // instead of caching across network changes.
        let discoveryAddresses = (try? resolveAddresses(
            host: "ipv4only.arpa",
            family: AF_INET6,
            flags: AI_ADDRCONFIG
        ))?.compactMap { $0.family == AF_INET6 ? $0.bytes : nil } ?? []
        let nat64Prefixes = staticallyRecognizedNAT64Prefixes.union(
            discoveredNAT64Prefixes(from: discoveryAddresses)
        )

        // Ask explicitly for A records as a second, fail-closed signal.  This
        // catches private IPv4 answers even when AI_ADDRCONFIG exposes only a
        // synthesized AAAA record to the primary lookup.  These records are
        // policy evidence only; the connection remains pinned to the exact
        // primary result below, so this does not reopen DNS rebinding.
        if let ipv4Records = try? resolveAddresses(host: host, family: AF_INET, flags: 0) {
            for record in ipv4Records where record.family == AF_INET {
                guard let value = ipv4Value(record.bytes), isPublicIPv4(value) else {
                    throw ReaderExtensionError.privateNetworkDestination
                }
            }
        }

        var addresses: [String] = []
        var seen = Set<String>()
        for record in resolved {
            if record.family == AF_INET {
                guard let value = ipv4Value(record.bytes), isPublicIPv4(value) else {
                    throw ReaderExtensionError.privateNetworkDestination
                }
            } else if record.family == AF_INET6 {
                guard isPublicIPv6Bytes(record.bytes, nat64Prefixes: nat64Prefixes) else {
                    throw ReaderExtensionError.privateNetworkDestination
                }
            } else {
                continue
            }
            if seen.insert(record.presentation).inserted { addresses.append(record.presentation) }
        }
        guard !addresses.isEmpty else { throw ReaderExtensionError.insecureURL }
        // A hostile hostname can return a very large RR set to consume work.
        // Every returned record was checked above before the connection pool
        // is bounded, so a private address cannot hide after the eighth row.
        return Array(addresses.prefix(8))
    }

    private struct ResolvedAddress {
        let family: Int32
        let bytes: [UInt8]
        let presentation: String
    }

    private static func resolveAddresses(host: String, family: Int32, flags: Int32) throws -> [ResolvedAddress] {
        var hints = addrinfo(
            ai_flags: flags,
            ai_family: family,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else { throw ReaderExtensionError.insecureURL }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        var addresses: [ResolvedAddress] = []
        while let info = cursor?.pointee {
            if let address = info.ai_addr {
                if info.ai_family == AF_INET {
                    let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var copy = ipv4
                    guard inet_ntop(AF_INET, &copy, &buffer, socklen_t(buffer.count)) != nil else {
                        throw ReaderExtensionError.insecureURL
                    }
                    addresses.append(ResolvedAddress(
                        family: AF_INET,
                        bytes: withUnsafeBytes(of: ipv4) { Array($0) },
                        presentation: String(cString: buffer)
                    ))
                } else if info.ai_family == AF_INET6 {
                    let raw = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    var copy = raw
                    guard inet_ntop(AF_INET6, &copy, &buffer, socklen_t(buffer.count)) != nil else {
                        throw ReaderExtensionError.insecureURL
                    }
                    addresses.append(ResolvedAddress(
                        family: AF_INET6,
                        bytes: withUnsafeBytes(of: raw) { Array($0) },
                        presentation: String(cString: buffer)
                    ))
                }
            }
            cursor = info.ai_next
        }
        guard !addresses.isEmpty else { throw ReaderExtensionError.insecureURL }
        return addresses
    }

    private static func validateResolvedAddresses(host: String) throws {
        _ = try resolvedPublicAddresses(host: host)
    }

    static func isPublicIPv4(_ value: UInt32) -> Bool {
        let a = UInt8((value >> 24) & 0xff), b = UInt8((value >> 16) & 0xff)
        switch a {
        case 0, 10, 127: return false
        case 100 where (64...127).contains(b): return false
        case 169 where b == 254: return false
        case 172 where (16...31).contains(b): return false
        case 192 where b == 0 || b == 168: return false
        case 198 where b == 18 || b == 19 || b == 51: return false
        case 203 where b == 0: return false
        case 224...255: return false
        default: return true
        }
    }

    private static func isPublicIPv6Bytes(
        _ bytes: [UInt8],
        nat64Prefixes: Set<ReaderExtensionNAT64Prefix>
    ) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) { return false }
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return false }
        if bytes[0] & 0xfe == 0xfc ||
            (bytes[0] == 0xfe && (bytes[1] & 0xc0 == 0x80 || bytes[1] & 0xc0 == 0xc0)) ||
            bytes[0] == 0xff { return false }
        if bytes[0...3].elementsEqual([0x20, 0x01, 0x0d, 0xb8]) { return false }
        // Reader extensions have no compatibility need for legacy IPv6
        // transition tunnels.  Reject 6to4 (which embeds IPv4 at bytes 2...5)
        // and Teredo outright so an AAAA-only answer cannot tunnel to a
        // private IPv4 destination outside the NAT64 checks below.
        if bytes[0...1].elementsEqual([0x20, 0x02]) ||
            bytes[0...3].elementsEqual([0x20, 0x01, 0x00, 0x00]) { return false }
        if bytes[0..<12].allSatisfy({ $0 == 0 }) ||
            (bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff) {
            guard let value = ipv4Value(Array(bytes[12..<16])) else { return false }
            return isPublicIPv4(value)
        }
        for prefix in nat64Prefixes where prefix.matches(bytes) {
            // The RFC 6052 u octet is mandatory.  If an address is routed
            // inside an active translation prefix but is not canonically
            // extractable, reject it instead of treating it as native IPv6.
            guard let value = prefix.embeddedIPv4(in: bytes), isPublicIPv4(value) else {
                return false
            }
        }
        return true
    }

    static func isPublicIPv6Bytes(_ bytes: [UInt8]) -> Bool {
        isPublicIPv6Bytes(bytes, nat64Prefixes: staticallyRecognizedNAT64Prefixes)
    }

    /// Testable policy seam for owned, synthetic DNS64 fixtures.  Production
    /// callers discover through the system resolver in resolvedPublicAddresses.
    static func isPublicIPv6Bytes(_ bytes: [UInt8], nat64DiscoveryAddresses: [[UInt8]]) -> Bool {
        isPublicIPv6Bytes(
            bytes,
            nat64Prefixes: staticallyRecognizedNAT64Prefixes.union(
                discoveredNAT64Prefixes(from: nat64DiscoveryAddresses)
            )
        )
    }

    static func discoveredNAT64Prefixes(from addresses: [[UInt8]]) -> Set<ReaderExtensionNAT64Prefix> {
        let discoveryIPv4Values: Set<UInt32> = [0xc00000aa, 0xc00000ab]
        var discovered = Set<ReaderExtensionNAT64Prefix>()
        for address in addresses where address.count == 16 {
            var candidates: [ReaderExtensionNAT64Prefix] = []
            for length in ReaderExtensionNAT64Prefix.supportedLengths {
                guard let prefix = ReaderExtensionNAT64Prefix(address: address, length: length),
                      let embedded = prefix.embeddedIPv4(in: address),
                      discoveryIPv4Values.contains(embedded) else { continue }
                candidates.append(prefix)
            }
            // RFC 7050 requires an unambiguous WKA occurrence at the RFC 6052
            // octet positions.  Either .170 or .171 is sufficient; a record
            // that can be decoded at multiple prefix lengths is ignored.
            if candidates.count == 1 { discovered.insert(candidates[0]) }
        }
        return discovered
    }

    private static let staticallyRecognizedNAT64Prefixes: Set<ReaderExtensionNAT64Prefix> = [
        // RFC 6052 Well-Known Prefix.
        ReaderExtensionNAT64Prefix(prefixBytes: [0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0], length: 96)!,
        // RFC 8215 local-use translation prefix; it follows the RFC 6052 /48
        // placement and must not be decoded from the final four bytes.
        ReaderExtensionNAT64Prefix(prefixBytes: [0x00, 0x64, 0xff, 0x9b, 0x00, 0x01], length: 48)!
    ]

    private static func ipv4Value(_ bytes: [UInt8]) -> UInt32? {
        guard bytes.count == 4 else { return nil }
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }
}

struct ReaderExtensionNAT64Prefix: Hashable, Sendable {
    static let supportedLengths = [32, 40, 48, 56, 64, 96]

    let prefixBytes: [UInt8]
    let length: Int

    init?(prefixBytes: [UInt8], length: Int) {
        guard Self.supportedLengths.contains(length), prefixBytes.count == length / 8 else { return nil }
        // RFC 6052 requires bits 64...71 to be zero even when they are part
        // of a /96 network-specific prefix.
        if length == 96, prefixBytes[8] != 0 { return nil }
        self.prefixBytes = prefixBytes
        self.length = length
    }

    init?(address: [UInt8], length: Int) {
        guard address.count == 16 else { return nil }
        self.init(prefixBytes: Array(address.prefix(length / 8)), length: length)
    }

    func matches(_ address: [UInt8]) -> Bool {
        address.count == 16 && address.prefix(prefixBytes.count).elementsEqual(prefixBytes)
    }

    func embeddedIPv4(in address: [UInt8]) -> UInt32? {
        guard matches(address) else { return nil }
        let octets: [UInt8]
        if length == 96 {
            octets = Array(address[12..<16])
        } else {
            // Removing the reserved u octet at byte eight produces the 120-bit
            // sequence described by RFC 6052; the IPv4 bytes immediately
            // follow the network-specific prefix in that sequence.
            guard address[8] == 0 else { return nil }
            let withoutU = Array(address[0..<8]) + Array(address[9..<16])
            let start = length / 8
            guard start + 4 <= withoutU.count else { return nil }
            octets = Array(withoutU[start..<(start + 4)])
        }
        return UInt32(octets[0]) << 24 | UInt32(octets[1]) << 16 | UInt32(octets[2]) << 8 | UInt32(octets[3])
    }
}

private struct ReaderExtensionJavaScriptScanner {
    let normalized: String

    init(code: String) {
        normalized = Self.strippingCommentsAndLiterals(code)
    }

    var containsDefaultExtension: Bool {
        normalized.range(of: "\\bclass\\s+DefaultExtension\\b", options: .regularExpression) != nil
            || normalized.range(of: "\\bDefaultExtension\\s*=", options: .regularExpression) != nil
    }

    var firstProhibitedConstruct: String? {
        let patterns: [(String, String)] = [
            ("\\beval\\s*\\(", "eval"),
            ("\\bFunction\\s*\\(", "Function"),
            ("\\bnew\\s+Function\\b", "Function"),
            ("\\bWebAssembly\\b", "WebAssembly"),
            ("\\bimport\\s*\\(", "dynamic import"),
            ("\\brequire\\s*\\(", "dynamic module"),
            ("\\.constructor\\s*\\(", "constructor execution"),
            ("\\bReflect\\s*\\.\\s*construct\\s*\\(", "reflective constructor execution"),
            ("\\bReflect\\s*\\[", "reflective constructor execution"),
            ("\\bparseEpub(?:Chapter)?\\s*\\(", "ebook archive helper"),
            ("\\bevaluateJavascriptViaWebview\\s*\\(", "WebView execution")
        ]
        // JavaScript identifier resolution is case-sensitive, so these bans
        // must be too: `EvAl(` cannot reach eval, while a case-insensitive
        // `\bFunction\s*\(` rejects every ordinary anonymous `function (`
        // expression and with it most real Mangayomi community extensions.
        return patterns.first { normalized.range(of: $0.0, options: [.regularExpression]) != nil }?.1
    }

    private static func strippingCommentsAndLiterals(_ input: String) -> String {
        enum State { case code, single, double, template, lineComment, blockComment }
        var state = State.code
        var escaped = false
        var output = ""
        var iterator = input.makeIterator()
        var current = iterator.next()
        while let character = current {
            let next = iterator.next()
            switch state {
            case .code:
                if character == "/", next == "/" { state = .lineComment; output += "  "; current = iterator.next(); continue }
                if character == "/", next == "*" { state = .blockComment; output += "  "; current = iterator.next(); continue }
                if character == "'" { state = .single; output += " "; current = next; continue }
                if character == "\"" { state = .double; output += " "; current = next; continue }
                if character == "`" { state = .template; output += " "; current = next; continue }
                output.append(character)
            case .single:
                if character == "'" && !escaped { state = .code }
                escaped = character == "\\" && !escaped
                if character != "\\" { escaped = false }
                output += character == "\n" ? "\n" : " "
            case .double:
                if character == "\"" && !escaped { state = .code }
                escaped = character == "\\" && !escaped
                if character != "\\" { escaped = false }
                output += character == "\n" ? "\n" : " "
            case .template:
                if character == "`" && !escaped { state = .code }
                escaped = character == "\\" && !escaped
                if character != "\\" { escaped = false }
                output += character == "\n" ? "\n" : " "
            case .lineComment:
                if character == "\n" { state = .code; output += "\n" } else { output += " " }
            case .blockComment:
                if character == "*", next == "/" { state = .code; output += "  "; current = iterator.next(); continue }
                output += character == "\n" ? "\n" : " "
            }
            current = next
        }
        return output
    }
}

enum ReaderExtensionAuthenticationGenerationRegistry {
    private struct Scope: Hashable {
        let sourceID: ReaderExtensionSourceID
        let namespace: String
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var generations: [Scope: UInt64] = [:]
    private nonisolated(unsafe) static var namespaceGenerations: [String: UInt64] = [:]

    static func current(sourceID: ReaderExtensionSourceID, namespace: String) -> UInt64 {
        lock.withReaderExtensionSecurityLock {
            let scope = Scope(sourceID: sourceID, namespace: namespace)
            if let generation = generations[scope] { return generation }
            // Materialize every live scope so a later namespace-wide profile
            // revocation also invalidates stores/clients that captured the
            // initial generation before any source-specific revocation.
            generations[scope] = 0
            return 0
        }
    }

    @discardableResult
    static func revoke(sourceID: ReaderExtensionSourceID, namespace: String) -> UInt64 {
        lock.withReaderExtensionSecurityLock {
            let scope = Scope(sourceID: sourceID, namespace: namespace)
            let next = (generations[scope] ?? 0) &+ 1
            generations[scope] = next
            return next
        }
    }

    /// Invalidates every live authenticated object for a profile namespace.
    /// This is used both when the active profile changes and before a profile
    /// store is removed. Unknown Keychain-only sources are handled by the
    /// namespace cleanup journal; only live in-process scopes need generations.
    static func revokeNamespace(_ namespace: String) {
        lock.withReaderExtensionSecurityLock {
            namespaceGenerations[namespace] = (namespaceGenerations[namespace] ?? 0) &+ 1
            let scopes = generations.keys.filter { $0.namespace == namespace }
            for scope in scopes {
                generations[scope] = (generations[scope] ?? 0) &+ 1
            }
        }
    }

    /// Persists destructive intent and then revokes the affected namespaces
    /// under the same writer fence. Existing authenticated writers either
    /// finish before the durable marker or observe a stale generation.
    static func prepareNamespaceRevocation<T>(
        _ namespaces: Set<String>,
        preparation: () throws -> T
    ) rethrows -> T {
        try lock.withReaderExtensionSecurityLock {
            let result = try preparation()
            for namespace in namespaces {
                namespaceGenerations[namespace] = (namespaceGenerations[namespace] ?? 0) &+ 1
            }
            let scopes = generations.keys.filter { namespaces.contains($0.namespace) }
            for scope in scopes {
                generations[scope] = (generations[scope] ?? 0) &+ 1
            }
            return result
        }
    }

    static func namespaceGeneration(_ namespace: String) -> UInt64 {
        lock.withReaderExtensionSecurityLock {
            namespaceGenerations[namespace] ?? 0
        }
    }

    static func prepareSourceRevocation<T>(
        sourceIDs: Set<ReaderExtensionSourceID>,
        namespaces: Set<String>,
        preparation: () throws -> T
    ) rethrows -> T {
        try lock.withReaderExtensionSecurityLock {
            let result = try preparation()
            for sourceID in sourceIDs {
                for namespace in namespaces {
                    let scope = Scope(sourceID: sourceID, namespace: namespace)
                    generations[scope] = (generations[scope] ?? 0) &+ 1
                }
            }
            return result
        }
    }

    /// Serializes namespace deletion with all generation-checked Keychain
    /// reads and writes. The durable journal prevents any new Manager-created
    /// authenticated object from entering while this fence is released.
    static func withNamespaceMutationFence<T>(
        namespace _: String,
        operation: () throws -> T
    ) rethrows -> T {
        try lock.withReaderExtensionSecurityLock(operation)
    }

    static func isCurrent(
        _ generation: UInt64,
        sourceID: ReaderExtensionSourceID,
        namespace: String
    ) -> Bool {
        current(sourceID: sourceID, namespace: namespace) == generation
    }

    static func withCurrentGeneration<T>(
        _ generation: UInt64,
        sourceID: ReaderExtensionSourceID,
        namespace: String,
        operation: () throws -> T
    ) throws -> T {
        try lock.withReaderExtensionSecurityLock {
            let scope = Scope(sourceID: sourceID, namespace: namespace)
            guard (generations[scope] ?? 0) == generation else {
                throw ReaderExtensionError.persistenceFailed(
                    "Authentication was revoked while this operation was running"
                )
            }
            return try operation()
        }
    }
}

/// A source/profile-scoped fence captured when an authenticated provider or
/// HTTP client is created. Revocation invalidates both Keychain writers and
/// requests that already copied a secret into their own headers or body.
struct ReaderExtensionAuthenticatedRequestAdmission: Sendable {
    let sourceID: ReaderExtensionSourceID
    let namespace: String
    let generation: UInt64

    init(sourceID: ReaderExtensionSourceID, namespace: String) {
        self.sourceID = sourceID
        self.namespace = namespace
        generation = ReaderExtensionAuthenticationGenerationRegistry.current(
            sourceID: sourceID,
            namespace: namespace
        )
    }

    func validate() throws {
        try perform {}
    }

    func perform<T>(_ operation: () throws -> T) throws -> T {
        try ReaderExtensionAuthenticationGenerationRegistry.withCurrentGeneration(
            generation,
            sourceID: sourceID,
            namespace: namespace,
            operation: operation
        )
    }
}

protocol ReaderExtensionKeychainAccess {
    func copyMatching(_ query: [String: Any], result: inout CFTypeRef?) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(_ attributes: [String: Any]) -> OSStatus
}

struct ReaderExtensionSystemKeychainAccess: ReaderExtensionKeychainAccess {
    func copyMatching(_ query: [String: Any], result: inout CFTypeRef?) -> OSStatus {
        SecItemCopyMatching(query as CFDictionary, &result)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }
}

/// Installed source metadata is the network trust boundary after the
/// repository/install admission checks have completed. Its optional durable
/// mirror remains source/profile/device-local in Keychain, but runtime access
/// must not depend on a second per-domain prompt: that left older installs and
/// newly selected profiles with an unusable, empty authorization set.
///
/// Reconciliation deliberately replaces (rather than unions with) the stored
/// set. A stale approval from an older source revision therefore cannot keep
/// authorizing an undeclared redirect, and private/local declarations never
/// become usable even if corrupt device state previously stored them.
enum ReaderExtensionInstalledDomainAuthorizationPolicy {
    struct Decision: Equatable {
        let authorizedDomains: Set<String>
        let declaredMirror: Set<String>
        let requiresPersistence: Bool
    }

    static func decision(
        for source: ReaderExtensionInstalledSource,
        storedDomains: Set<String>,
        userApprovedDomains: Set<String> = []
    ) -> Decision {
        let declared = trustedPublicDeclaredDomains(for: source)
        // Explicit consent grants pass the same public-HTTPS validation as
        // declared hosts on every read, and grant nothing while the source
        // itself is not runnable.
        let userApproved = declared.isEmpty ? [] : validatedPublicHosts(userApprovedDomains)
        return Decision(
            authorizedDomains: declared.union(userApproved),
            declaredMirror: declared,
            requiresPersistence: ReaderExtensionSecurityPolicy.canonicalHosts(storedDomains) != declared
        )
    }

    static func reconcile(
        source: ReaderExtensionInstalledSource,
        store: ReaderExtensionKeychainStore
    ) throws -> Set<String> {
        let result = decision(
            for: source,
            storedDomains: store.approvedDomains(),
            userApprovedDomains: store.userApprovedDomains()
        )
        if result.requiresPersistence {
            try store.setApprovedDomains(result.declaredMirror)
        }
        return result.authorizedDomains
    }

    /// Runtime authority comes only from the currently installed, validated
    /// source record plus the user's explicit consent grants. Keychain is a
    /// device-local mirror used for durability; an unavailable mirror must not
    /// turn an otherwise trusted source into a false domain-consent failure.
    /// Every call retries the exact replacement of the declared mirror, while
    /// the returned set never includes stale stored extras from that mirror.
    static func runtimeAuthorizedDomains(
        source: ReaderExtensionInstalledSource,
        store: ReaderExtensionKeychainStore,
        onPersistenceFailure: () -> Void
    ) -> Set<String> {
        let result = decision(
            for: source,
            storedDomains: store.approvedDomains(),
            userApprovedDomains: store.userApprovedDomains()
        )
        if result.requiresPersistence {
            do {
                try store.setApprovedDomains(result.declaredMirror)
            } catch {
                onPersistenceFailure()
            }
        }
        return result.authorizedDomains
    }

    private static func trustedPublicDeclaredDomains(
        for source: ReaderExtensionInstalledSource
    ) -> Set<String> {
        guard !source.requiresReinstall,
              source.implementation != .unsupportedNative,
              source.license.kind.permitsInstallation,
              source.implementation != .javascript || source.activeContentDigest != nil else {
            return []
        }

        return validatedPublicHosts(Set(source.declaredDomains))
    }

    private static func validatedPublicHosts(_ hosts: Set<String>) -> Set<String> {
        Set(ReaderExtensionSecurityPolicy.canonicalHosts(hosts).filter { host in
            guard let url = ReaderExtensionSecurityPolicy.canonicalHTTPSURL(forHost: host) else {
                return false
            }
            // DNS is resolved and pinned immediately before every request. At
            // this synchronous policy seam, reject private/local syntax and
            // authorize only the canonical HTTPS form of each host.
            return (try? ReaderExtensionSecurityPolicy.validatePublicURLSyntax(
                url,
                requireHTTPS: true
            )) != nil
        })
    }
}

final class ReaderExtensionKeychainStore: ReaderExtensionPreferenceStore, @unchecked Sendable {
    typealias OrdinaryValueWriter = (String, ReaderExtensionPreferenceValue) throws -> Void

    static let maximumStoredCookieCount = 200
    static let maximumStoredCookieBytes = 512 * 1_024
    static let maximumCookieNormalizationRows = 4_096
    static let maximumCookieNameBytes = 256
    static let maximumCookieValueBytes = 4 * 1_024
    static let maximumCookiePathBytes = 2 * 1_024

    private let service: String
    private let sourceID: ReaderExtensionSourceID
    private let namespace: String
    private let valuesLock = NSLock()
    private var values: [String: ReaderExtensionPreferenceValue]
    private let schemaSecretKeys: Set<String>
    private let ordinaryValueWriter: OrdinaryValueWriter?
    private let keychain: any ReaderExtensionKeychainAccess
    private let authenticationGeneration: UInt64

    convenience init(source: ReaderExtensionInstalledSource, namespace: String) {
        self.init(
            sourceID: source.id,
            values: source.preferences,
            namespace: namespace,
            schemaSecretKeys: source.secretPreferenceKeys
        )
    }

    init(
        sourceID: ReaderExtensionSourceID,
        values: [String: ReaderExtensionPreferenceValue] = [:],
        namespace: String,
        schemaSecretKeys: Set<String> = [],
        ordinaryValueWriter: OrdinaryValueWriter? = nil,
        keychain: any ReaderExtensionKeychainAccess = ReaderExtensionSystemKeychainAccess(),
        authenticationGeneration: UInt64? = nil
    ) {
        service = (Bundle.main.bundleIdentifier ?? "app.Eclipse.Soupy") + ".reader-extensions"
        self.sourceID = sourceID
        self.namespace = namespace
        self.values = values
        self.schemaSecretKeys = schemaSecretKeys
        self.ordinaryValueWriter = ordinaryValueWriter
        self.keychain = keychain
        self.authenticationGeneration = authenticationGeneration
            ?? ReaderExtensionAuthenticationGenerationRegistry.current(
                sourceID: sourceID,
                namespace: namespace
            )
    }

    func value(for key: String) -> ReaderExtensionPreferenceValue? {
        valuesLock.withReaderExtensionSecurityLock { values[key] }
    }

    func setValue(_ value: ReaderExtensionPreferenceValue, for key: String) throws {
        try ReaderExtensionSecurityPolicy.validatePreference(key: key, value: value)
        try valuesLock.withReaderExtensionSecurityLock {
            guard values[key] != nil || values.count < ReaderExtensionSecurityPolicy.maximumPreferenceCount else {
                throw ReaderExtensionError.contentTooLarge
            }
        }
        try ordinaryValueWriter?(key, value)
        valuesLock.withReaderExtensionSecurityLock { values[key] = value }
    }

    func secret(for key: String) throws -> String? {
        try withCurrentAuthenticationGeneration {
            guard let data = try data(for: "secret.\(key)") else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    func setSecret(_ value: String?, for key: String) throws {
        try withCurrentAuthenticationGeneration {
            try ReaderExtensionSecurityPolicy.validatePreferenceSecret(key: key, value: value)
            if value != nil {
                let keys = try storedSecretKeys()
                guard keys.contains(key) || keys.count < ReaderExtensionSecurityPolicy.maximumPreferenceCount else {
                    throw ReaderExtensionError.contentTooLarge
                }
            }
            try setData(value.map { Data($0.utf8) }, for: "secret.\(key)")
        }
    }

    func shouldStoreAsSecret(_ key: String) -> Bool {
        schemaSecretKeys.contains(key) || ReaderExtensionSecurityPolicy.isCredentialLikePreferenceKey(key)
    }

    // A key this store would route to the Keychain must also read back from
    // it, or setString/getString stops round-tripping for exactly the login
    // tokens the heuristic protects — the source silently signs itself out on
    // every operation. Reads stay bounded to this source/profile namespace
    // and the current authentication generation.
    func mayReadSecret(_ key: String) -> Bool {
        shouldStoreAsSecret(key)
    }

    /// Removes every secret account in this source/profile namespace. This is
    /// deliberately based on Keychain account enumeration, so script-created
    /// keys are cleared even if they never had a metadata `secretReference`.
    func removeAllSecrets() throws {
        try withCurrentAuthenticationGeneration { try removeAllSecretsUnlocked() }
    }

    private func removeAllSecretsUnlocked() throws {
        for key in try storedSecretKeys() {
            try setData(nil, for: "secret.\(key)")
        }
        guard try storedSecretKeys().isEmpty else {
            throw ReaderExtensionError.persistenceFailed("Keychain secret deletion verification failed")
        }
    }

    func approvedDomains() -> Set<String> {
        (try? withCurrentAuthenticationGeneration {
            guard let data = try data(for: "domains"),
                  let domains = try? JSONDecoder().decode(Set<String>.self, from: data) else { return [] }
            return ReaderExtensionSecurityPolicy.canonicalHosts(domains)
        }) ?? []
    }

    func setApprovedDomains(_ domains: Set<String>) throws {
        try withCurrentAuthenticationGeneration {
            let canonical = ReaderExtensionSecurityPolicy.canonicalHosts(domains)
            guard domains.allSatisfy({ ReaderExtensionSecurityPolicy.canonicalHost($0) != nil }) else {
                throw ReaderExtensionError.insecureURL
            }
            try setData(JSONEncoder().encode(canonical), for: "domains")
        }
    }

    /// Explicit user consent grants live in their own account so declared-
    /// domain reconciliation can keep replacing its mirror without erasing
    /// them. Storing both in one item made every user approval a no-op: the
    /// next runtime read rewrote the item back to the declared set and the
    /// consent prompt returned forever.
    func userApprovedDomains() -> Set<String> {
        (try? withCurrentAuthenticationGeneration {
            guard let data = try data(for: "user-domains"),
                  let domains = try? JSONDecoder().decode(Set<String>.self, from: data) else { return [] }
            return ReaderExtensionSecurityPolicy.canonicalHosts(domains)
        }) ?? []
    }

    func setUserApprovedDomains(_ domains: Set<String>) throws {
        try withCurrentAuthenticationGeneration {
            let canonical = ReaderExtensionSecurityPolicy.canonicalHosts(domains)
            guard domains.allSatisfy({ ReaderExtensionSecurityPolicy.canonicalHost($0) != nil }) else {
                throw ReaderExtensionError.insecureURL
            }
            try setData(JSONEncoder().encode(canonical), for: "user-domains")
        }
    }

    func cookies() -> [HTTPCookie] {
        (try? withCurrentAuthenticationGeneration { try cookiesUnlocked() }) ?? []
    }

    func setCookies(_ cookies: [HTTPCookie]) throws {
        try withCurrentAuthenticationGeneration { try setCookiesUnlocked(cookies) }
    }

    /// Atomically reads, merges, and replaces the source/profile cookie jar
    /// under the authentication-generation fence. Parallel sign-in resource
    /// responses must not overwrite one another with stale whole-jar reads.
    func updateCookies(
        _ transform: ([HTTPCookie]) throws -> [HTTPCookie]?
    ) throws {
        try withCurrentAuthenticationGeneration {
            let current = try cookiesUnlocked()
            guard let updated = try transform(current) else { return }
            try setCookiesUnlocked(updated)
        }
    }

    private func cookiesUnlocked() throws -> [HTTPCookie] {
        guard let data = try data(for: "cookies") else { return [] }
        guard data.count <= Self.maximumStoredCookieBytes else {
            throw ReaderExtensionError.contentTooLarge
        }
        guard let stored = try? JSONDecoder().decode([ReaderExtensionStoredCookie].self, from: data) else {
            throw ReaderExtensionError.persistenceFailed("Stored authentication cookies are unreadable")
        }
        return try Self.cookiesForPersistence(
            stored.compactMap(\.cookie),
            rejectsInvalidCookies: false
        )
    }

    private func setCookiesUnlocked(_ cookies: [HTTPCookie]) throws {
        let bounded = try Self.cookiesForPersistence(
            cookies,
            rejectsInvalidCookies: true
        )
        let data = try JSONEncoder().encode(bounded.map(ReaderExtensionStoredCookie.init))
        guard data.count <= Self.maximumStoredCookieBytes else {
            throw ReaderExtensionError.contentTooLarge
        }
        try setData(data, for: "cookies")
    }

    private static func cookiesForPersistence(
        _ cookies: [HTTPCookie],
        rejectsInvalidCookies: Bool,
        now: Date = Date()
    ) throws -> [HTTPCookie] {
        if rejectsInvalidCookies, cookies.count > maximumCookieNormalizationRows {
            throw ReaderExtensionError.contentTooLarge
        }
        let input = cookies.suffix(maximumCookieNormalizationRows)
        var candidates: [(cookie: HTTPCookie, identity: String, encodedBytes: Int)] = []
        candidates.reserveCapacity(Swift.min(input.count, maximumStoredCookieCount + 1))
        for cookie in input {
            guard cookie.expiresDate.map({ $0 > now }) ?? true else { continue }
            guard let identity = validatedCookieIdentity(cookie) else {
                if rejectsInvalidCookies { throw ReaderExtensionError.contentTooLarge }
                continue
            }
            let encodedBytes = try JSONEncoder().encode(ReaderExtensionStoredCookie(cookie)).count + 1
            guard encodedBytes < maximumStoredCookieBytes else {
                if rejectsInvalidCookies { throw ReaderExtensionError.contentTooLarge }
                continue
            }
            candidates.append((cookie, identity, encodedBytes))
        }

        // The caller orders existing cookies before freshly received ones.
        // Walk newest-first so rotations/current Set-Cookie values win, while
        // duplicates, expired rows, and the oldest existing identities are
        // discarded before the bounded Keychain write.
        var selected: [(cookie: HTTPCookie, encodedBytes: Int)] = []
        var identities = Set<String>()
        var aggregateBytes = 2 // JSON array brackets
        for candidate in candidates.reversed() {
            guard identities.insert(candidate.identity).inserted else { continue }
            guard selected.count < maximumStoredCookieCount,
                  candidate.encodedBytes <= maximumStoredCookieBytes - aggregateBytes else {
                continue
            }
            selected.append((candidate.cookie, candidate.encodedBytes))
            aggregateBytes += candidate.encodedBytes
        }
        return selected.reversed().map { $0.cookie }
    }

    static func validatedCookieIdentity(_ cookie: HTTPCookie) -> String? {
        guard !cookie.name.isEmpty,
              cookie.name.utf8.count <= maximumCookieNameBytes,
              cookie.name.range(
                of: "^[!#$%&'*+.^_`|~0-9A-Za-z-]+$",
                options: .regularExpression
              ) != nil,
              cookie.value.utf8.count <= maximumCookieValueBytes,
              !cookie.value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let domain = ReaderExtensionSecurityPolicy.canonicalHost(cookie.domain),
              cookie.path.hasPrefix("/"),
              cookie.path.utf8.count <= maximumCookiePathBytes,
              !cookie.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return "\(cookie.name)\0\(domain)\0\(cookie.path)"
    }

    func removeAuthenticationState() throws {
        try withCurrentAuthenticationGeneration {
            try setData(nil, for: "cookies")
            try removeAllSecretsUnlocked()
        }
    }

    func removeAllDeviceState() throws {
        try withCurrentAuthenticationGeneration { try removeAllDeviceStateUnlocked() }
    }

    /// Removes every Reader Extension Keychain item owned by one profile UUID,
    /// including state for sources whose metadata store is about to disappear.
    /// The namespace is an exact UUID prefix, so one profile cannot erase a
    /// neighboring namespace with a shared textual prefix.
    static func removeAllDeviceState(
        inNamespace namespace: String,
        keychain: any ReaderExtensionKeychainAccess = ReaderExtensionSystemKeychainAccess()
    ) throws {
        guard UUID(uuidString: namespace)?.uuidString == namespace else {
            throw ReaderExtensionError.persistenceFailed("invalid Reader authentication namespace")
        }
        try ReaderExtensionAuthenticationGenerationRegistry.withNamespaceMutationFence(
            namespace: namespace
        ) {
            try removeMatchingAccounts(
                prefix: "\(namespace).",
                keychain: keychain
            )
        }
    }

    private func removeAllDeviceStateUnlocked() throws {
        try Self.removeMatchingAccounts(
            prefix: accountPrefix + ".",
            keychain: keychain
        )
    }

    private static func removeMatchingAccounts(
        prefix: String,
        keychain: any ReaderExtensionKeychainAccess
    ) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = keychain.copyMatching(query, result: &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else {
            throw ReaderExtensionError.persistenceFailed("Keychain enumeration failed (\(status))")
        }
        let rows = try attributeRows(from: result)
        for row in rows {
            guard let account = row[kSecAttrAccount as String] as? String,
                  account.hasPrefix(prefix) else { continue }
            let delete: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: account
            ]
            try deleteAndVerify(delete, account: account, keychain: keychain)
        }
        let remaining = try storedAccounts(keychain: keychain).filter { $0.hasPrefix(prefix) }
        guard remaining.isEmpty else {
            throw ReaderExtensionError.persistenceFailed("Keychain device-state deletion verification failed")
        }
    }

    private var accountPrefix: String { "\(namespace).\(sourceID.rawValue)" }

    private func withCurrentAuthenticationGeneration<T>(
        _ operation: () throws -> T
    ) throws -> T {
        try ReaderExtensionAuthenticationGenerationRegistry.withCurrentGeneration(
            authenticationGeneration,
            sourceID: sourceID,
            namespace: namespace,
            operation: operation
        )
    }

    private func storedSecretKeys() throws -> Set<String> {
        let prefix = "\(accountPrefix).secret."
        return Set(try storedAccounts().compactMap { account in
            guard account.hasPrefix(prefix) else { return nil }
            return String(account.dropFirst(prefix.count))
        })
    }

    private func storedAccounts() throws -> [String] {
        try Self.storedAccounts(keychain: keychain)
    }

    private static func storedAccounts(
        keychain: any ReaderExtensionKeychainAccess
    ) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = keychain.copyMatching(query, result: &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw ReaderExtensionError.persistenceFailed("Keychain enumeration failed (\(status))")
        }
        return try attributeRows(from: result).compactMap {
            $0[kSecAttrAccount as String] as? String
        }
    }

    private static func attributeRows(from result: CFTypeRef?) throws -> [[String: Any]] {
        if let rows = result as? [[String: Any]] { return rows }
        if let row = result as? [String: Any] { return [row] }
        throw ReaderExtensionError.persistenceFailed("Keychain enumeration returned invalid attributes")
    }

    private func deleteAndVerify(_ query: [String: Any], account: String) throws {
        try Self.deleteAndVerify(query, account: account, keychain: keychain)
    }

    private static func deleteAndVerify(
        _ query: [String: Any],
        account: String,
        keychain: any ReaderExtensionKeychainAccess
    ) throws {
        let status = keychain.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ReaderExtensionError.persistenceFailed("Keychain deletion failed (\(status))")
        }
        var verificationQuery = query
        verificationQuery[kSecReturnData as String] = true
        verificationQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let verification = keychain.copyMatching(verificationQuery, result: &result)
        guard verification == errSecItemNotFound else {
            if verification == errSecSuccess {
                throw ReaderExtensionError.persistenceFailed("Keychain deletion verification failed for \(account)")
            }
            throw ReaderExtensionError.persistenceFailed("Keychain deletion verification failed (\(verification))")
        }
    }

    private func data(for suffix: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(accountPrefix).\(suffix)",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = keychain.copyMatching(query, result: &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ReaderExtensionError.persistenceFailed("Keychain read failed (\(status))")
        }
        return data
    }

    private func setData(_ data: Data?, for suffix: String) throws {
        let account = "\(accountPrefix).\(suffix)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        guard let data else {
            try deleteAndVerify(query, account: account)
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let update = keychain.update(query, attributes: attributes)
        if update == errSecItemNotFound {
            var insert = query
            attributes.forEach { insert[$0.key] = $0.value }
            let status = keychain.add(insert)
            guard status == errSecSuccess else { throw ReaderExtensionError.persistenceFailed("Keychain write failed (\(status))") }
        } else if update != errSecSuccess {
            throw ReaderExtensionError.persistenceFailed("Keychain update failed (\(update))")
        }
    }

    private static var keychainService: String {
        (Bundle.main.bundleIdentifier ?? "app.Eclipse.Soupy") + ".reader-extensions"
    }
}

private struct ReaderExtensionStoredCookie: Codable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expiresDate: Date?
    var isSecure: Bool
    var isHTTPOnly: Bool
    var sameSitePolicy: String?

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        expiresDate = cookie.expiresDate
        isSecure = cookie.isSecure
        isHTTPOnly = cookie.isHTTPOnly
        sameSitePolicy = cookie.sameSitePolicy?.rawValue
    }

    var cookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path
        ]
        if let expiresDate { properties[.expires] = expiresDate }
        if isSecure { properties[.secure] = "TRUE" }
        if isHTTPOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let sameSitePolicy,
           sameSitePolicy == HTTPCookieStringPolicy.sameSiteLax.rawValue
            || sameSitePolicy == HTTPCookieStringPolicy.sameSiteStrict.rawValue {
            properties[.sameSitePolicy] = sameSitePolicy
        }
        return HTTPCookie(properties: properties)
    }
}

enum ReaderExtensionCookieAdmissionPolicy {
    static func allowsCookies(
        for targetURL: URL,
        request: ReaderExtensionNetworkRequest
    ) -> Bool {
        guard request.allowsCookies,
              targetURL.scheme?.lowercased() == "https" else { return false }
        switch request.cookieAccessPolicy {
        case .sourceScoped:
            return true
        case .sameOriginHostOnly:
            guard let initiatorHost = ReaderExtensionSecurityPolicy.canonicalHost(request.baseDomain),
                  let targetHost = ReaderExtensionSecurityPolicy.canonicalHost(of: targetURL) else {
                return false
            }
            return initiatorHost == targetHost
        }
    }
}

final class ReaderExtensionSecureHTTPClient: ReaderExtensionNetworkClient, @unchecked Sendable {
    private let keychainNamespace: String
    private let authenticatedAdmission: ReaderExtensionAuthenticatedRequestAdmission?
    private let emitsDomainConsentRequests: Bool

    init(
        keychainNamespace: String,
        authenticationSourceID: ReaderExtensionSourceID? = nil,
        emitsDomainConsentRequests: Bool = true
    ) {
        self.keychainNamespace = keychainNamespace
        self.emitsDomainConsentRequests = emitsDomainConsentRequests
        authenticatedAdmission = authenticationSourceID.map {
            ReaderExtensionAuthenticatedRequestAdmission(
                sourceID: $0,
                namespace: keychainNamespace
            )
        }
    }

    func request(_ request: ReaderExtensionNetworkRequest) async throws -> ReaderExtensionNetworkResponse {
        // Ledger parity with the removed Aidoku runtime: one line per fetch
        // with host, status, size, and timing. Without it an edge challenge
        // page is indistinguishable from a provider that returned no rows.
        let startedAt = Date()
        let host = ReaderExtensionSecurityPolicy.canonicalHost(of: request.url) ?? "invalid-host"
        do {
            let response = try await performRequest(request)
            ReaderLogger.shared.log(
                "fetch host=\(host) status=\(response.statusCode) bytes=\(response.body.count) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))",
                type: "ReaderExtensionNetwork"
            )
            return response
        } catch {
            let reason = (error as? ReaderExtensionError)?.errorDescription
                ?? (error as? URLError).map { "URLError(\($0.code.rawValue))" }
                ?? String(describing: type(of: error))
            ReaderLogger.shared.log(
                "fetch host=\(host) failed reason=\(reason) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))",
                type: "ReaderExtensionNetwork"
            )
            throw error
        }
    }

    private func performRequest(_ request: ReaderExtensionNetworkRequest) async throws -> ReaderExtensionNetworkResponse {
        let admission = try authenticationAdmission(for: request.sourceID)
        try ReaderExtensionSecurityPolicy.validatePublicURLSyntax(request.url)
        if request.redirectPolicy == .publicHTTPS {
            guard !request.allowsCookies,
                  request.body == nil,
                  request.method == .get || request.method == .head,
                  request.url.scheme?.lowercased() == "https" else {
                throw ReaderExtensionError.insecureURL
            }
        }
        try validateAccess(for: request.url, request: request)
        guard request.body?.count ?? 0 <= ReaderExtensionSecurityPolicy.maximumRequestBodyBytes else {
            throw ReaderExtensionError.contentTooLarge
        }
        guard request.maximumResponseBytes > 0,
              request.maximumResponseBytes <= ReaderExtensionSecurityPolicy.maximumPageResponseBytes else {
            throw ReaderExtensionError.contentTooLarge
        }
        let requestHost = ReaderExtensionSecurityPolicy.canonicalHost(of: request.url)
        let crossOrigin = request.baseDomain.map {
            ReaderExtensionSecurityPolicy.canonicalHost($0) != requestHost
        } ?? false
        // Plain HTTP may be used for public, non-secret provider content, but
        // it must never receive credentials merely because its host matches
        // the configured source host.
        let insecureTransport = request.url.scheme?.lowercased() != "https"
        var headers = ReaderExtensionSecurityPolicy.headersByApplyingHostDefaults(
            try ReaderExtensionSecurityPolicy.sanitizedHeaders(
                request.headers,
                // Consent-free public requests must never carry provider secrets,
                // including on an initial host that happens to match baseDomain.
                crossOrigin: crossOrigin || insecureTransport || request.redirectPolicy == .publicHTTPS
            )
        )
        var method = request.method
        var body = request.body
        var url = request.url
        let deadline = ProcessInfo.processInfo.systemUptime + 35

        let store = ReaderExtensionKeychainStore(
            sourceID: request.sourceID,
            namespace: keychainNamespace,
            authenticationGeneration: admission?.generation
        )
        for redirectCount in 0...10 {
            try Task.checkCancellation()
            try admission?.validate()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw URLError(.timedOut) }
            try ReaderExtensionSecurityPolicy.validatePublicURLSyntax(url)
            try validateAccess(for: url, request: request)

            // The exact numeric endpoints returned here are handed to
            // NWConnection. No later DNS lookup occurs between policy approval
            // and the TCP connection, closing the URLSession rebinding gap.
            guard let canonicalHost = ReaderExtensionSecurityPolicy.canonicalHost(of: url) else {
                throw ReaderExtensionError.insecureURL
            }
            let addresses = try ReaderExtensionSecurityPolicy.resolvedPublicAddresses(host: canonicalHost)
            var hopHeaders = headers
            if let originReferer = try ReaderExtensionSecurityPolicy.hostGeneratedOriginReferer(
                for: request,
                targetURL: url
            ) {
                hopHeaders["Referer"] = originReferer
            }
            let admitsCookies = ReaderExtensionCookieAdmissionPolicy.allowsCookies(
                for: url,
                request: request
            )
            if admitsCookies {
                let matching = store.cookies().filter { cookie in
                    ReaderExtensionSecurityPolicy.cookie(
                        cookie,
                        mayBeSentTo: url,
                        approvedDomains: request.approvedDomains
                    )
                }
                HTTPCookie.requestHeaderFields(with: matching).forEach { hopHeaders[$0.key] = $0.value }
            }

            let result = try await ReaderExtensionPinnedHTTPLoader.load(
                url: url,
                method: method.rawValue,
                headers: hopHeaders,
                body: body,
                addresses: addresses,
                deadline: deadline,
                maximumResponseBytes: request.maximumResponseBytes,
                authenticatedAdmission: admission
            )
            try admission?.validate()
            let flattenedHeaders = result.flattenedHeaders
            guard let http = HTTPURLResponse(
                url: url,
                statusCode: result.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: flattenedHeaders
            ) else { throw ReaderExtensionError.insecureURL }
            try ReaderExtensionSecurityPolicy.validateNotArchive(data: result.body, response: http, url: url)
            if admitsCookies {
                try persistCookies(from: result, responseURL: url, request: request, store: store)
            }

            if Self.redirectStatusCodes.contains(result.statusCode),
               let location = result.firstHeader(named: "location") {
                guard redirectCount < 10,
                      let destination = URL(string: location, relativeTo: url)?.absoluteURL else {
                    throw ReaderExtensionError.insecureURL
                }
                try ReaderExtensionSecurityPolicy.validatePublicURLSyntax(destination)
                if url.scheme?.lowercased() == "https" && destination.scheme?.lowercased() != "https" {
                    throw ReaderExtensionError.insecureURL
                }
                try validateAccess(for: destination, request: request)
                let crossesOrigin = Self.origin(of: url) != Self.origin(of: destination)
                let dropsBody = Self.redirectDropsBody(status: result.statusCode, method: method)
                // A POST body is opaque to the host and may itself contain a
                // password/token. Never replay one to a different origin.
                if crossesOrigin, body != nil, !dropsBody {
                    throw ReaderExtensionError.insecureURL
                }
                headers = try ReaderExtensionSecurityPolicy.sanitizedHeaders(
                    headers,
                    crossOrigin: crossesOrigin || destination.scheme?.lowercased() != "https"
                )
                if crossesOrigin {
                    headers = headers.filter {
                        let lower = $0.key.lowercased()
                        return lower != "referer" && lower != "origin"
                    }
                }
                if dropsBody {
                    method = .get
                    body = nil
                    headers = headers.filter { !Self.entityHeaderNames.contains($0.key.lowercased()) }
                }
                url = destination
                continue
            }

            let visibleHeaders = flattenedHeaders.filter {
                $0.key.caseInsensitiveCompare("Set-Cookie") != .orderedSame
            }
            if ReaderExtensionChallengeDetector.isChallenge(
                status: result.statusCode,
                headers: visibleHeaders,
                body: result.body
            ), let challengeHost = ReaderExtensionSecurityPolicy.canonicalHost(of: url) {
                throw ReaderExtensionError.browserVerificationRequired(challengeHost)
            }

            return ReaderExtensionNetworkResponse(
                statusCode: result.statusCode,
                finalURL: url,
                headers: visibleHeaders,
                body: result.body,
                extensionVisibleRequestHeaders: Self.extensionVisibleRequestHeaders(from: hopHeaders)
            )
        }
        throw ReaderExtensionError.insecureURL
    }

    /// Internal test seam and the first admission check for every bound
    /// request. A client bound to one source must never be reused for another.
    func validateAuthenticationAdmission(for sourceID: ReaderExtensionSourceID) throws {
        _ = try authenticationAdmission(for: sourceID)
    }

    private func authenticationAdmission(
        for sourceID: ReaderExtensionSourceID
    ) throws -> ReaderExtensionAuthenticatedRequestAdmission? {
        guard let authenticatedAdmission else { return nil }
        guard authenticatedAdmission.sourceID == sourceID else {
            throw ReaderExtensionError.insecureURL
        }
        try authenticatedAdmission.validate()
        return authenticatedAdmission
    }

    private func validateConsent(for url: URL, request: ReaderExtensionNetworkRequest) throws {
        do {
            try ReaderExtensionSecurityPolicy.validateApprovedDomain(url, approvedDomains: request.approvedDomains)
        } catch ReaderExtensionError.domainConsentRequired(let host) {
            if emitsDomainConsentRequests {
                ReaderExtensionDomainConsentCoordinator.emit(
                    sourceID: request.sourceID,
                    host: host,
                    scopeID: keychainNamespace
                )
            }
            throw ReaderExtensionError.domainConsentRequired(host)
        }
    }

    private func validateAccess(
        for url: URL,
        request: ReaderExtensionNetworkRequest
    ) throws {
        switch request.redirectPolicy {
        case .publicHTTPS:
            try ReaderExtensionSecurityPolicy.validatePublicURLSyntax(
                url,
                requireHTTPS: true
            )
        case .approvedDomainsThenPublicHTTPS:
            // Passive resources only: an unapproved hop is admitted like a
            // publicHTTPS fetch (cookie policy is approval-gated separately)
            // and deliberately never emits a consent prompt.
            if (try? ReaderExtensionSecurityPolicy.validateApprovedDomain(
                url,
                approvedDomains: request.approvedDomains
            )) != nil { return }
            try ReaderExtensionSecurityPolicy.validatePublicURLSyntax(
                url,
                requireHTTPS: true
            )
        case .approvedDomainsOnly:
            try validateConsent(for: url, request: request)
        }
    }

    private func persistCookies(
        from result: ReaderExtensionPinnedHTTPResult,
        responseURL: URL,
        request: ReaderExtensionNetworkRequest,
        store: ReaderExtensionKeychainStore
    ) throws {
        try store.updateCookies { existing in
            Self.cookiesByMergingResponse(
                result.headerValues(named: "set-cookie"),
                responseURL: responseURL,
                approvedDomains: request.approvedDomains,
                existing: existing
            )
        }
    }

    /// Shared by the authenticated transport and focused sign-in tests. A
    /// response can update only cookies whose declared Domain remains inside
    /// the source's current, device-local approval set.
    static func cookiesByMergingResponse(
        _ setCookieHeaders: [String],
        responseURL: URL,
        approvedDomains: Set<String>,
        existing: [HTTPCookie]
    ) -> [HTTPCookie]? {
        let incoming = setCookieHeaders.flatMap {
            HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": $0], for: responseURL)
        }.filter { cookie in
            guard let host = ReaderExtensionSecurityPolicy.canonicalHost(of: responseURL),
                  let domain = ReaderExtensionSecurityPolicy.canonicalHost(cookie.domain) else { return false }
            let approved = ReaderExtensionSecurityPolicy.canonicalHosts(approvedDomains)
            return ReaderExtensionSecurityPolicy.host(host, isEqualToOrSubdomainOf: domain)
                && approved.contains(where: {
                    ReaderExtensionSecurityPolicy.host(domain, isEqualToOrSubdomainOf: $0)
                })
        }
        guard !incoming.isEmpty else { return nil }
        let identities = Set(incoming.compactMap(
            ReaderExtensionKeychainStore.validatedCookieIdentity
        ))
        guard !identities.isEmpty else { return nil }
        return existing.filter {
            guard let identity = ReaderExtensionKeychainStore.validatedCookieIdentity($0) else {
                return false
            }
            return !identities.contains(identity)
        } + incoming.filter {
            ReaderExtensionKeychainStore.validatedCookieIdentity($0) != nil
        }
    }

    private static func origin(of url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let defaultPort = scheme == "https" ? 443 : 80
        return "\(scheme)://\(ReaderExtensionSecurityPolicy.canonicalHost(of: url) ?? ""):\(url.port ?? defaultPort)"
    }

    private static func redirectDropsBody(status: Int, method: ReaderExtensionNetworkRequest.Method) -> Bool {
        status == 303 && method != .head || (status == 301 || status == 302) && method == .post
    }

    static func extensionVisibleRequestHeaders(
        from effectiveHeaders: [String: String]
    ) -> [String: String] {
        guard let cookie = effectiveHeaders.first(where: {
            $0.key.caseInsensitiveCompare("Cookie") == .orderedSame
        })?.value, !cookie.isEmpty else { return [:] }
        return ["Cookie": String(cookie.prefix(ReaderExtensionSecurityPolicy.maximumHeaderBytes))]
    }

    private static let redirectStatusCodes: Set<Int> = [301, 302, 303, 307, 308]
    private static let entityHeaderNames: Set<String> = [
        "content-encoding", "content-language", "content-location", "content-type", "digest"
    ]
}

private struct ReaderExtensionPinnedHTTPResult: Sendable {
    let statusCode: Int
    let headers: [String: [String]]
    let body: Data

    var flattenedHeaders: [String: String] {
        headers.reduce(into: [:]) { output, entry in output[entry.key] = entry.value.joined(separator: ", ") }
    }

    func headerValues(named name: String) -> [String] {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value ?? []
    }

    func firstHeader(named name: String) -> String? { headerValues(named: name).first }
}

/// Parks framed, cleanly-finished HTTP/1.1 connections for reuse. Keys carry
/// the exact pinned address and SNI host, and `load` only offers a key whose
/// address came from the current request's freshly validated resolution, so
/// reuse can never outlive the DNS-rebinding checks that admitted it.
final class ReaderExtensionHTTPConnectionPool: @unchecked Sendable {
    struct Key: Hashable {
        let scheme: String
        let host: String
        let address: String
        let port: UInt16
    }

    static let shared = ReaderExtensionHTTPConnectionPool()
    private static let maximumParkedConnections = 8
    private static let maximumParkedPerKey = 2
    private static let idleLifetime: TimeInterval = 30

    private let lock = NSLock()
    private var parked: [Key: [(connection: NWConnection, parkedAt: TimeInterval)]] = [:]

    func take(_ key: Key) -> NWConnection? {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        var entries = parked[key] ?? []
        var candidate: NWConnection?
        while let entry = entries.popLast() {
            if now - entry.parkedAt <= Self.idleLifetime, entry.connection.state == .ready {
                candidate = entry.connection
                break
            }
            entry.connection.cancel()
        }
        parked[key] = entries.isEmpty ? nil : entries
        lock.unlock()
        candidate?.stateUpdateHandler = nil
        return candidate
    }

    func park(_ connection: NWConnection, key: Key) {
        guard connection.state == .ready else {
            connection.cancel()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        var entries = parked[key] ?? []
        let totalParked = parked.values.reduce(0) { $0 + $1.count }
        guard entries.count < Self.maximumParkedPerKey,
              totalParked < Self.maximumParkedConnections else {
            lock.unlock()
            connection.cancel()
            return
        }
        entries.append((connection, now))
        parked[key] = entries
        lock.unlock()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed, .cancelled:
                guard let self, let connection else { return }
                self.lock.lock()
                if var entries = self.parked[key] {
                    entries.removeAll { $0.connection === connection }
                    self.parked[key] = entries.isEmpty ? nil : entries
                }
                self.lock.unlock()
            default:
                break
            }
        }
    }
}

private enum ReaderExtensionPinnedHTTPLoader {
    static func load(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        addresses: [String],
        deadline: TimeInterval,
        maximumResponseBytes: Int,
        authenticatedAdmission: ReaderExtensionAuthenticatedRequestAdmission? = nil
    ) async throws -> ReaderExtensionPinnedHTTPResult {
        var finalError: Error = ReaderExtensionError.insecureURL
        let scheme = url.scheme?.lowercased() ?? "https"
        let host = ReaderExtensionSecurityPolicy.canonicalHost(of: url) ?? ""
        let port = UInt16(url.port ?? (scheme == "https" ? 443 : 80))
        // Only idempotent requests ride a parked connection: a stale-socket
        // failure mid-POST cannot be safely replayed.
        let mayReuse = ["GET", "HEAD"].contains(method.uppercased())
        for address in addresses {
            try authenticatedAdmission?.validate()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw URLError(.timedOut) }
            let key = ReaderExtensionHTTPConnectionPool.Key(
                scheme: scheme,
                host: host,
                address: address,
                port: port
            )
            if mayReuse, let parked = ReaderExtensionHTTPConnectionPool.shared.take(key) {
                do {
                    return try await ReaderExtensionPinnedHTTPConnection(
                        url: url,
                        method: method,
                        headers: headers,
                        body: body,
                        address: address,
                        timeout: min(12, remaining),
                        maximumResponseBytes: maximumResponseBytes,
                        authenticatedAdmission: authenticatedAdmission,
                        reusing: parked,
                        poolKey: mayReuse ? key : nil
                    ).run()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                }
            }
            try authenticatedAdmission?.validate()
            let freshRemaining = deadline - ProcessInfo.processInfo.systemUptime
            guard freshRemaining > 0 else { throw URLError(.timedOut) }
            do {
                return try await ReaderExtensionPinnedHTTPConnection(
                    url: url,
                    method: method,
                    headers: headers,
                    body: body,
                    address: address,
                    timeout: min(12, freshRemaining),
                    maximumResponseBytes: maximumResponseBytes,
                    authenticatedAdmission: authenticatedAdmission,
                    poolKey: mayReuse ? key : nil
                ).run()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                finalError = error
            }
        }
        throw finalError
    }
}

/// Minimal, bounded HTTP/1.1 transport over a numeric NWConnection endpoint.
/// HTTPS still uses the original URL hostname for SNI and an explicit system
/// trust policy, so endpoint pinning does not relax hostname validation.
private final class ReaderExtensionPinnedHTTPConnection: @unchecked Sendable {
    private static let maximumHeaderBytes = ReaderExtensionSecurityPolicy.maximumHeaderBytes
    private static let maximumChunkMetadataBytes = 256 * 1_024
    private static let headerBoundary = Data([13, 10, 13, 10])
    private static let lineBoundary = Data([13, 10])

    private let url: URL
    private let method: String
    private let address: String
    private let timeout: TimeInterval
    private let maximumResponseBytes: Int
    private let requestData: Data
    private let authenticatedAdmission: ReaderExtensionAuthenticatedRequestAdmission?
    private let reusedConnection: NWConnection?
    private let poolKey: ReaderExtensionHTTPConnectionPool.Key?
    private let queue = DispatchQueue(label: "app.eclipse.reader-extensions.pinned-http", qos: .utility)
    private let lock = NSLock()
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<ReaderExtensionPinnedHTTPResult, Error>?
    private var buffer = Data()
    private var cancelled = false
    private var finished = false
    private var connectionMayBeParked = false

    init(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        address: String,
        timeout: TimeInterval,
        maximumResponseBytes: Int,
        authenticatedAdmission: ReaderExtensionAuthenticatedRequestAdmission? = nil,
        reusing existingConnection: NWConnection? = nil,
        poolKey: ReaderExtensionHTTPConnectionPool.Key? = nil
    ) throws {
        self.url = url
        self.method = method.uppercased()
        self.address = address
        self.timeout = max(0.25, timeout)
        self.maximumResponseBytes = maximumResponseBytes
        self.authenticatedAdmission = authenticatedAdmission
        reusedConnection = existingConnection
        self.poolKey = poolKey
        requestData = try Self.requestBytes(url: url, method: method, headers: headers, body: body)
    }

    func run() async throws -> ReaderExtensionPinnedHTTPResult {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in start(continuation) }
        }, onCancel: { self.cancel() })
    }

    private func start(_ continuation: CheckedContinuation<ReaderExtensionPinnedHTTPResult, Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()

        if let reusedConnection {
            lock.lock()
            if cancelled || finished {
                lock.unlock()
                reusedConnection.cancel()
                return
            }
            connection = reusedConnection
            lock.unlock()
            reusedConnection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .failed(let error): self.finish(.failure(error))
                case .cancelled:
                    self.finish(.failure(self.cancelled ? CancellationError() : ReaderExtensionError.insecureURL))
                default: break
                }
            }
            sendRequest()
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(URLError(.timedOut)))
            }
            return
        }

        guard let scheme = url.scheme?.lowercased(),
              let host = ReaderExtensionSecurityPolicy.canonicalHost(of: url),
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? (scheme == "https" ? 443 : 80))) else {
            finish(.failure(ReaderExtensionError.insecureURL))
            return
        }
        let endpointHost: NWEndpoint.Host
        if let ipv4 = IPv4Address(address) {
            endpointHost = .ipv4(ipv4)
        } else if let ipv6 = IPv6Address(address) {
            endpointHost = .ipv6(ipv6)
        } else {
            finish(.failure(ReaderExtensionError.insecureURL))
            return
        }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, Int(ceil(timeout)))
        let parameters: NWParameters
        if scheme == "https" {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                let policy = SecPolicyCreateSSL(true, host as CFString)
                guard SecTrustSetPolicies(secTrust, policy) == errSecSuccess else {
                    complete(false)
                    return
                }
                complete(SecTrustEvaluateWithError(secTrust, nil))
            }, queue)
            parameters = NWParameters(tls: tls, tcp: tcp)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcp)
        }
        let connection = NWConnection(host: endpointHost, port: port, using: parameters)
        lock.lock()
        if cancelled || finished {
            lock.unlock()
            connection.cancel()
            return
        }
        self.connection = connection
        lock.unlock()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.sendRequest()
            case .failed(let error): self.finish(.failure(error))
            case .cancelled:
                self.finish(.failure(self.cancelled ? CancellationError() : ReaderExtensionError.insecureURL))
            default: break
            }
        }
        do {
            try withAuthenticatedAdmission { connection.start(queue: queue) }
        } catch {
            finish(.failure(error))
            return
        }
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(URLError(.timedOut)))
        }
    }

    private func sendRequest() {
        guard let connection else { return }
        do {
            try withAuthenticatedAdmission {
                connection.send(content: requestData, completion: .contentProcessed { [weak self] error in
                    if let error { self?.finish(.failure(error)) }
                    else { self?.receiveNext() }
                })
            }
        } catch {
            finish(.failure(error))
        }
    }

    private func withAuthenticatedAdmission<T>(
        _ operation: () throws -> T
    ) throws -> T {
        if let authenticatedAdmission {
            return try authenticatedAdmission.perform(operation)
        }
        return try operation()
    }

    private func receiveNext() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                lock.lock()
                let limit = Self.maximumHeaderBytes + maximumResponseBytes
                    + Self.maximumChunkMetadataBytes
                if data.count <= limit, buffer.count <= limit - data.count { buffer.append(data) }
                else {
                    lock.unlock()
                    finish(.failure(ReaderExtensionError.contentTooLarge))
                    return
                }
                lock.unlock()
            }
            do {
                if let response = try parsedResponse(connectionComplete: complete) {
                    finish(.success(response))
                    return
                }
            } catch {
                finish(.failure(error))
                return
            }
            if let error { finish(.failure(error)) }
            else if complete { finish(.failure(ReaderExtensionError.insecureURL)) }
            else { receiveNext() }
        }
    }

    private func parsedResponse(connectionComplete: Bool) throws -> ReaderExtensionPinnedHTTPResult? {
        lock.lock()
        var bytes = buffer
        lock.unlock()
        while true {
            guard let boundary = bytes.range(of: Self.headerBoundary) else {
                if bytes.count > Self.maximumHeaderBytes { throw ReaderExtensionError.contentTooLarge }
                return nil
            }
            guard boundary.lowerBound <= Self.maximumHeaderBytes,
                  let headerText = String(data: bytes[..<boundary.lowerBound], encoding: .isoLatin1) else {
                throw ReaderExtensionError.insecureURL
            }
            let parsed = try Self.parseHeaders(headerText)
            let bodyStart = boundary.upperBound
            if (100..<200).contains(parsed.statusCode), parsed.statusCode != 101 {
                bytes.removeSubrange(..<bodyStart)
                lock.lock(); buffer = bytes; lock.unlock()
                continue
            }
            guard parsed.statusCode != 101 else { throw ReaderExtensionError.insecureURL }
            let wireBody = Data(bytes[bodyStart...])
            let body: Data
            let framedExactly: Bool
            if Self.hasNoBody(status: parsed.statusCode, method: method) {
                body = Data()
                framedExactly = wireBody.isEmpty
            } else if parsed.isChunked {
                guard parsed.contentLength == nil,
                      let decoded = try Self.decodeChunked(
                        wireBody,
                        maximumResponseBytes: maximumResponseBytes
                      ) else {
                    if connectionComplete { throw ReaderExtensionError.insecureURL }
                    return nil
                }
                body = decoded.body
                framedExactly = decoded.leftoverCount == 0
            } else if let length = parsed.contentLength {
                guard length <= maximumResponseBytes else {
                    throw ReaderExtensionError.contentTooLarge
                }
                guard wireBody.count >= length else {
                    if connectionComplete { throw ReaderExtensionError.insecureURL }
                    return nil
                }
                body = Data(wireBody.prefix(length))
                framedExactly = wireBody.count == length
            } else {
                guard connectionComplete else { return nil }
                body = wireBody
                framedExactly = false
            }
            guard body.count <= maximumResponseBytes else {
                throw ReaderExtensionError.contentTooLarge
            }
            connectionMayBeParked = framedExactly && parsed.permitsReuse && !connectionComplete
            let decodedBody = try ReaderExtensionHTTPBodyDecoder.decode(
                body,
                coding: parsed.contentCoding,
                maximumDecodedBytes: maximumResponseBytes
            )
            return ReaderExtensionPinnedHTTPResult(statusCode: parsed.statusCode, headers: parsed.headers, body: decodedBody)
        }
    }

    private func finish(_ result: Result<ReaderExtensionPinnedHTTPResult, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        let connection = connection
        self.connection = nil
        lock.unlock()
        connection?.stateUpdateHandler = nil
        if case .success = result, connectionMayBeParked, let poolKey, let connection {
            ReaderExtensionHTTPConnectionPool.shared.park(connection, key: poolKey)
        } else {
            connection?.cancel()
        }
        continuation?.resume(with: result)
    }

    private func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(.failure(CancellationError()))
    }

    private struct ParsedHeaders {
        let statusCode: Int
        let headers: [String: [String]]
        let contentLength: Int?
        let isChunked: Bool
        let contentCoding: ReaderExtensionHTTPContentCoding
        let permitsReuse: Bool
    }

    private static func parseHeaders(_ text: String) throws -> ParsedHeaders {
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw ReaderExtensionError.insecureURL }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/1."),
              let status = Int(statusParts[1]), (100...599).contains(status) else {
            throw ReaderExtensionError.insecureURL
        }
        let isHTTP11 = statusParts[0] == "HTTP/1.1"
        var headers: [String: [String]] = [:]
        var headerCount = 0
        for line in lines.dropFirst() {
            guard !line.isEmpty, line.first?.isWhitespace != true, let colon = line.firstIndex(of: ":") else {
                throw ReaderExtensionError.insecureURL
            }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty,
                  name.range(of: "^[!#$%&'*+.^_`|~0-9A-Za-z-]+$", options: .regularExpression) != nil,
                  value.utf8.count <= 16 * 1_024 else { throw ReaderExtensionError.insecureURL }
            headerCount += 1
            guard headerCount <= ReaderExtensionSecurityPolicy.maximumHeaderCount else {
                throw ReaderExtensionError.contentTooLarge
            }
            headers[name, default: []].append(value)
        }
        let lengthTokens = headerValues(headers, named: "content-length")
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let lengths = lengthTokens.compactMap(Int.init)
        guard lengths.count == lengthTokens.count, lengths.allSatisfy({ $0 >= 0 }),
              lengths.isEmpty || Set(lengths).count == 1 else { throw ReaderExtensionError.insecureURL }
        let transfer = headerValues(headers, named: "transfer-encoding").flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        let chunked = transfer.last == "chunked"
        guard transfer.isEmpty || transfer == ["chunked"], !(chunked && !lengths.isEmpty) else {
            throw ReaderExtensionError.insecureURL
        }
        let contentCodings = headerValues(headers, named: "content-encoding").flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty && $0 != "identity" }
        let contentCoding: ReaderExtensionHTTPContentCoding
        switch contentCodings {
        case []: contentCoding = .identity
        case ["gzip"], ["x-gzip"]: contentCoding = .gzip
        case ["deflate"]: contentCoding = .deflate
        default: throw URLError(.cannotDecodeContentData)
        }
        let connectionTokens = headerValues(headers, named: "connection").flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return ParsedHeaders(
            statusCode: status,
            headers: headers,
            contentLength: lengths.first,
            isChunked: chunked,
            contentCoding: contentCoding,
            permitsReuse: isHTTP11 && !connectionTokens.contains("close")
        )
    }

    private static func decodeChunked(
        _ data: Data,
        maximumResponseBytes: Int
    ) throws -> (body: Data, leftoverCount: Int)? {
        var cursor = data.startIndex
        var decoded = Data()
        while true {
            guard let lineEnd = data.range(of: lineBoundary, in: cursor..<data.endIndex) else { return nil }
            guard lineEnd.lowerBound - cursor <= 1_024,
                  let line = String(data: data[cursor..<lineEnd.lowerBound], encoding: .ascii),
                  let token = line.split(separator: ";", maxSplits: 1).first,
                  let length = Int(token.trimmingCharacters(in: .whitespaces), radix: 16), length >= 0 else {
                throw ReaderExtensionError.insecureURL
            }
            cursor = lineEnd.upperBound
            if length == 0 {
                if data.count >= cursor + 2, Data(data[cursor..<(cursor + 2)]) == lineBoundary {
                    return (decoded, data.endIndex - (cursor + 2))
                }
                guard let trailerEnd = data.range(of: headerBoundary, in: cursor..<data.endIndex),
                      trailerEnd.lowerBound - cursor <= maximumChunkMetadataBytes else { return nil }
                return (decoded, data.endIndex - trailerEnd.upperBound)
            }
            guard length <= maximumResponseBytes - decoded.count else {
                throw ReaderExtensionError.contentTooLarge
            }
            guard data.count >= cursor + length + 2 else { return nil }
            let contentEnd = cursor + length
            guard Data(data[contentEnd..<(contentEnd + 2)]) == lineBoundary else {
                throw ReaderExtensionError.insecureURL
            }
            decoded.append(data[cursor..<contentEnd])
            cursor = contentEnd + 2
        }
    }

    private static func hasNoBody(status: Int, method: String) -> Bool {
        method == "HEAD" || (100..<200).contains(status) || status == 204 || status == 304
    }

    private static func headerValues(_ headers: [String: [String]], named name: String) -> [String] {
        headers.filter { $0.key.caseInsensitiveCompare(name) == .orderedSame }.flatMap(\.value)
    }

    private static func requestBytes(url: URL, method: String, headers: [String: String], body: Data?) throws -> Data {
        guard let scheme = url.scheme?.lowercased(),
              let host = ReaderExtensionSecurityPolicy.canonicalHost(of: url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ReaderExtensionError.insecureURL
        }
        let upperMethod = method.uppercased()
        guard ["HEAD", "GET", "POST", "PUT", "PATCH", "DELETE"].contains(upperMethod) else {
            throw ReaderExtensionError.insecureURL
        }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let target = path + (components.percentEncodedQuery.map { "?\($0)" } ?? "")
        guard !target.contains("\r"), !target.contains("\n") else { throw ReaderExtensionError.insecureURL }
        let defaultPort = scheme == "https" ? 443 : 80
        let bracketedHost = host.contains(":") ? "[\(host)]" : host
        let authority = (url.port ?? defaultPort) == defaultPort ? bracketedHost : "\(bracketedHost):\(url.port!)"
        var fields = headers.filter {
            !["host", "content-length", "connection", "proxy-connection", "transfer-encoding", "accept-encoding", "expect"]
                .contains($0.key.lowercased())
        }
        fields["Host"] = authority
        // Browsers always offer compression and keep connections alive; some
        // WAF bot heuristics score `identity` and `Connection: close` as
        // automation. The response decoder inflates gzip/deflate under a hard
        // decoded-size cap, and reuse is offered only for exactly-framed
        // responses on idempotent requests.
        fields["Accept-Encoding"] = "gzip, deflate"
        if let body { fields["Content-Length"] = String(body.count) }
        guard fields.count <= ReaderExtensionSecurityPolicy.maximumHeaderCount else {
            throw ReaderExtensionError.contentTooLarge
        }
        var head = "\(upperMethod) \(target) HTTP/1.1\r\n"
        for (name, value) in fields.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            guard !name.contains("\r"), !name.contains("\n"), !value.contains("\r"), !value.contains("\n") else {
                throw ReaderExtensionError.insecureURL
            }
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        guard head.utf8.count <= ReaderExtensionSecurityPolicy.maximumHeaderBytes else {
            throw ReaderExtensionError.contentTooLarge
        }
        var result = Data(head.utf8)
        if let body { result.append(body) }
        return result
    }
}

enum ReaderExtensionHTTPContentCoding {
    case identity
    case gzip
    case deflate
}

/// Recognizes interstitial bot-verification documents. A challenge answers
/// with a normal-looking 2xx/4xx body that parses to zero rows, so without
/// this the source is indistinguishable from one that is simply dead.
enum ReaderExtensionChallengeDetector {
    static func isChallenge(status: Int, headers: [String: String], body: Data) -> Bool {
        let lowerHeaders = headers.reduce(into: [String: String]()) { result, pair in
            result[pair.key.lowercased()] = pair.value.lowercased()
        }
        if lowerHeaders["cf-mitigated"]?.contains("challenge") == true { return true }
        guard let text = String(data: body.prefix(64 * 1_024), encoding: .utf8)?.lowercased() else {
            return false
        }
        if text.contains("__cf_chl_")
            || text.contains("cf_chl_opt")
            || text.contains("enable javascript and cookies")
            || text.contains("/.well-known/ddos-guard/")
            || (text.contains("just a moment") && text.contains("cloudflare")) {
            return true
        }
        guard [403, 429, 503].contains(status) else { return false }
        return text.contains("challenges.cloudflare.com")
            || text.contains("cf-turnstile")
            || text.contains("challenge-platform")
            || text.contains("jschl")
            || (text.contains("ddos-guard")
                && (text.contains("checking your browser") || text.contains("please wait")))
    }
}

/// Streaming inflate with a hard decoded-size ceiling. NSData.decompressed
/// inflates the whole stream before any size check, so a small hostile body
/// could balloon far past the response budget in one allocation.
enum ReaderExtensionHTTPBodyDecoder {
    static func decode(
        _ body: Data,
        coding: ReaderExtensionHTTPContentCoding,
        maximumDecodedBytes: Int
    ) throws -> Data {
        switch coding {
        case .identity:
            return body
        case .gzip:
            let payload = try deflatePayloadByStrippingGzipContainer(body)
            return try inflateRawDeflate(payload, maximumDecodedBytes: maximumDecodedBytes)
        case .deflate:
            // RFC 9110 deflate is a zlib container, but some origins send a
            // bare deflate stream. Try the container form first and fall back.
            if let first = body.first, first & 0x0f == 8, body.count > 6,
               let inflated = try? inflateRawDeflate(
                Data(body.dropFirst(2).dropLast(4)),
                maximumDecodedBytes: maximumDecodedBytes
               ) {
                return inflated
            }
            return try inflateRawDeflate(body, maximumDecodedBytes: maximumDecodedBytes)
        }
    }

    private static func deflatePayloadByStrippingGzipContainer(_ body: Data) throws -> Data {
        let bytes = [UInt8](body)
        guard bytes.count >= 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else {
            throw URLError(.cannotDecodeContentData)
        }
        let flags = bytes[3]
        var index = 10
        func skip(_ count: Int) throws {
            guard bytes.count - index >= count else { throw URLError(.cannotDecodeContentData) }
            index += count
        }
        if flags & 0x04 != 0 {
            try skip(2)
            try skip(Int(bytes[index - 2]) | Int(bytes[index - 1]) << 8)
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            try skip(1)
        }
        if flags & 0x02 != 0 { try skip(2) }
        guard bytes.count - index > 8 else { throw URLError(.cannotDecodeContentData) }
        return Data(body.dropFirst(index).dropLast(8))
    }

    private static func inflateRawDeflate(_ input: Data, maximumDecodedBytes: Int) throws -> Data {
        guard !input.isEmpty else { return Data() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw URLError(.cannotDecodeContentData)
        }
        defer { compression_stream_destroy(stream) }
        let bufferSize = 64 * 1_024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        var output = Data()
        try input.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw URLError(.cannotDecodeContentData)
            }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = input.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = bufferSize
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status != COMPRESSION_STATUS_ERROR else { throw URLError(.cannotDecodeContentData) }
                let produced = bufferSize - stream.pointee.dst_size
                guard produced <= maximumDecodedBytes - output.count else {
                    throw ReaderExtensionError.contentTooLarge
                }
                output.append(buffer, count: produced)
                if status == COMPRESSION_STATUS_END { break }
                if produced == 0, stream.pointee.src_size == 0 {
                    throw URLError(.cannotDecodeContentData)
                }
            }
        }
        return output
    }
}

private extension NSLock {
    func withReaderExtensionSecurityLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }; return try operation()
    }
}
