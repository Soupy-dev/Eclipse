import Foundation
import CryptoKit
import Network

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - URL boundary

/// The reason a remote URL is being opened. Repository metadata and package
/// payloads deliberately have a stricter transport policy than runtime media.
public enum SkyStreamNetworkPurpose: String, Sendable, Hashable {
    case repository
    case package
    case pluginRequest
    case streamRoot
    case manifest
    case mediaSegment
    case encryptionKey
    case subtitle
    case icon
    case redirect

    fileprivate var requiresHTTPS: Bool {
        self == .repository || self == .package || self == .icon
    }
}

public struct SkyStreamRemoteOrigin: Sendable, Hashable {
    public let scheme: String
    public let host: String
    public let port: Int

    fileprivate init(scheme: String, host: String, port: Int) {
        self.scheme = scheme
        self.host = host
        self.port = port
    }

    public func isSameOrigin(as other: SkyStreamRemoteOrigin) -> Bool {
        scheme == other.scheme && host == other.host && port == other.port
    }
}

/// A URL which has passed syntax, literal-address and DNS-result checks. Its
/// initializer is file-private so raw plugin strings cannot manufacture one.
///
/// DNS is checked immediately before a request, but URLSession performs its own
/// later resolution. This value therefore does not claim DNS pinning.
public struct SkyStreamValidatedRemoteURL: Sendable, Hashable {
    public let url: URL
    public let origin: SkyStreamRemoteOrigin
    public let purpose: SkyStreamNetworkPurpose
    public let checkedAddresses: [String]

    fileprivate init(
        url: URL,
        origin: SkyStreamRemoteOrigin,
        purpose: SkyStreamNetworkPurpose,
        checkedAddresses: [String]
    ) {
        self.url = url
        self.origin = origin
        self.purpose = purpose
        self.checkedAddresses = checkedAddresses
    }

    public var redactedDescription: String {
        SkyStreamRemoteURLPolicy.redactedDescription(of: url)
    }
}

/// Internal batch input used when one accepted media manifest references many
/// URLs. Every item still receives the full syntactic policy, while DNS is
/// resolved once per unique host rather than once per route.
struct SkyStreamRemoteURLValidationRequest: Sendable {
    let rawValue: String
    let purpose: SkyStreamNetworkPurpose
    let relativeTo: URL?

    init(
        rawValue: String,
        purpose: SkyStreamNetworkPurpose,
        relativeTo: URL? = nil
    ) {
        self.rawValue = rawValue
        self.purpose = purpose
        self.relativeTo = relativeTo
    }
}

public enum SkyStreamSecurityError: Error, Sendable, Equatable {
    case emptyURL
    case malformedURL
    case unsupportedScheme
    case insecureTransport
    case credentialsInURL
    case invalidHost
    case prohibitedHost
    case prohibitedAddress(String)
    case dnsResolutionFailed
    case dnsReturnedNoAddresses
    case httpsDowngrade
    case tooManyRedirects
    case invalidMethod
    case invalidByteRange
    case requestBodyTooLarge
    case tooManyConcurrentRequests
    case responseTooLarge
    case invalidResponse
    case cancelled
    case invalidPackageID
    case invalidHeaderName
    case invalidHeaderValue
    case duplicateHeader
    case forbiddenHeader
    case tooManyHeaders
    case headersTooLarge
    case cookieQuotaExceeded
}

extension SkyStreamSecurityError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyURL: return "The URL is empty."
        case .malformedURL: return "The URL is malformed."
        case .unsupportedScheme: return "Only HTTP and HTTPS URLs are supported."
        case .insecureTransport: return "This resource requires HTTPS."
        case .credentialsInURL: return "Credentials embedded in URLs are not allowed."
        case .invalidHost: return "The URL host is invalid."
        case .prohibitedHost: return "Local and private hosts are not allowed."
        case .prohibitedAddress: return "The host resolves to a non-public address."
        case .dnsResolutionFailed: return "The host could not be resolved safely."
        case .dnsReturnedNoAddresses: return "The host did not resolve to an address."
        case .httpsDowngrade: return "An HTTPS redirect attempted to downgrade to HTTP."
        case .tooManyRedirects: return "The request exceeded the redirect limit."
        case .invalidMethod: return "The HTTP method is not allowed."
        case .invalidByteRange: return "The requested byte range is invalid."
        case .requestBodyTooLarge: return "The request body exceeds the limit."
        case .tooManyConcurrentRequests: return "The plugin exceeded its concurrent request limit."
        case .responseTooLarge: return "The response exceeds the allowed size."
        case .invalidResponse: return "The server returned an invalid response."
        case .cancelled: return "The request was cancelled."
        case .invalidPackageID: return "The plugin package identifier is invalid."
        case .invalidHeaderName: return "A request header name is invalid."
        case .invalidHeaderValue: return "A request header value is invalid."
        case .duplicateHeader: return "Duplicate request headers are not allowed."
        case .forbiddenHeader: return "A plugin attempted to set a managed request header."
        case .tooManyHeaders: return "The request contains too many headers."
        case .headersTooLarge: return "The request headers exceed the allowed size."
        case .cookieQuotaExceeded: return "The plugin cookie jar exceeded its quota."
        }
    }
}

public final class SkyStreamRemoteURLPolicy: @unchecked Sendable {
    public static let shared = SkyStreamRemoteURLPolicy()

    private struct DNSCacheEntry {
        let addresses: [String]
        let expiresAt: Date
        var accessOrdinal: UInt64
    }

    private struct DNSInFlightLookup {
        let token: UInt64
        let task: Task<[String], Error>
    }

    private enum DNSResolution {
        case cached([String])
        case lookup(DNSInFlightLookup)
    }

    private let resolverQueue = DispatchQueue(
        label: "app.eclipse.skystream.dns",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let dnsCacheLock = NSLock()
    private let addressResolver: @Sendable (String) throws -> [String]
    private let maximumDNSCacheEntries = 256
    private var dnsCache: [String: DNSCacheEntry] = [:]
    private var dnsInFlight: [String: DNSInFlightLookup] = [:]
    private var dnsAccessOrdinal: UInt64 = 0
    private var dnsLookupToken: UInt64 = 0

    public init() {
        addressResolver = { host in
            try Self.resolveAddressesSynchronously(host)
        }
    }

    /// Deterministic resolver seam for security and coalescing tests. Kept
    /// internal so production callers cannot replace the public-address check.
    init(addressResolver: @escaping @Sendable (String) throws -> [String]) {
        self.addressResolver = addressResolver
    }

    /// Performs all URL checks including an asynchronous DNS lookup. The lookup
    /// prevents ordinary hostname-to-private-address requests, but does not pin
    /// URLSession's subsequent DNS result.
    public func validate(
        _ rawValue: String,
        purpose: SkyStreamNetworkPurpose,
        relativeTo baseURL: URL? = nil
    ) async throws -> SkyStreamValidatedRemoteURL {
        let syntactic = try validateSyntactic(rawValue, purpose: purpose, relativeTo: baseURL)
        let addresses = try await resolvePublicAddresses(for: syntactic.host)
        return SkyStreamValidatedRemoteURL(
            url: syntactic.url,
            origin: syntactic.origin,
            purpose: purpose,
            checkedAddresses: addresses
        )
    }

    /// Network dispatches deliberately bypass the short positive DNS cache. Catalog/manifest
    /// parsing can safely coalesce cached lookups, but authorizing an actual GET or POST from a
    /// stale public answer would unnecessarily widen a DNS-rebinding window before URLSession's
    /// independent resolution.
    func validateForNetworkDispatch(
        _ rawValue: String,
        purpose: SkyStreamNetworkPurpose,
        relativeTo baseURL: URL? = nil
    ) async throws -> SkyStreamValidatedRemoteURL {
        let syntactic = try validateSyntactic(rawValue, purpose: purpose, relativeTo: baseURL)
        let addresses = try await resolvePublicAddresses(
            for: syntactic.host,
            permitsCachedResult: false
        )
        return SkyStreamValidatedRemoteURL(
            url: syntactic.url,
            origin: syntactic.origin,
            purpose: purpose,
            checkedAddresses: addresses
        )
    }

    /// Applies the same checks as `validate` to every item, preserving input
    /// order. Syntax and literal-address checks remain per URL. Only the DNS
    /// work is deduplicated by canonical host and concurrency-bounded.
    func validate(
        _ requests: [SkyStreamRemoteURLValidationRequest],
        maximumConcurrentDNSLookups: Int = 6
    ) async throws -> [SkyStreamValidatedRemoteURL] {
        guard !requests.isEmpty else { return [] }

        var syntacticValues: [(url: URL, origin: SkyStreamRemoteOrigin, host: String, purpose: SkyStreamNetworkPurpose)] = []
        syntacticValues.reserveCapacity(requests.count)
        var uniqueHosts: [String] = []
        uniqueHosts.reserveCapacity(min(requests.count, 64))
        var seenHosts = Set<String>()

        for (index, request) in requests.enumerated() {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            let syntactic = try validateSyntactic(
                request.rawValue,
                purpose: request.purpose,
                relativeTo: request.relativeTo
            )
            syntacticValues.append((
                url: syntactic.url,
                origin: syntactic.origin,
                host: syntactic.host,
                purpose: request.purpose
            ))
            if seenHosts.insert(syntactic.host).inserted {
                uniqueHosts.append(syntactic.host)
            }
        }

        let concurrentLimit = max(1, min(maximumConcurrentDNSLookups, 12))
        let addressesByHost = try await withThrowingTaskGroup(
            of: (String, [String]).self,
            returning: [String: [String]].self
        ) { group in
            let initialCount = min(concurrentLimit, uniqueHosts.count)
            for host in uniqueHosts.prefix(initialCount) {
                group.addTask {
                    (host, try await self.resolvePublicAddresses(for: host))
                }
            }

            var nextIndex = initialCount
            var resolved: [String: [String]] = [:]
            resolved.reserveCapacity(uniqueHosts.count)
            while let (host, addresses) = try await group.next() {
                try Task.checkCancellation()
                resolved[host] = addresses
                if nextIndex < uniqueHosts.count {
                    let nextHost = uniqueHosts[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        (nextHost, try await self.resolvePublicAddresses(for: nextHost))
                    }
                }
            }
            return resolved
        }

        try Task.checkCancellation()
        return try syntacticValues.map { syntactic in
            guard let addresses = addressesByHost[syntactic.host], !addresses.isEmpty else {
                throw SkyStreamSecurityError.dnsReturnedNoAddresses
            }
            return SkyStreamValidatedRemoteURL(
                url: syntactic.url,
                origin: syntactic.origin,
                purpose: syntactic.purpose,
                checkedAddresses: addresses
            )
        }
    }

    /// Revalidates every redirect and rejects HTTPS-to-HTTP downgrades.
    public func validateRedirect(
        from source: SkyStreamValidatedRemoteURL,
        to destination: URL,
        purpose: SkyStreamNetworkPurpose? = nil
    ) async throws -> SkyStreamValidatedRemoteURL {
        let nextPurpose = purpose ?? source.purpose
        let validated = try await validate(
            destination.absoluteString,
            purpose: nextPurpose,
            relativeTo: source.url
        )
        if source.origin.scheme == "https" && validated.origin.scheme != "https" {
            throw SkyStreamSecurityError.httpsDowngrade
        }
        return validated
    }

    /// Redirect authorization repeats uncached DNS immediately before URLSession follows the
    /// hop. `sourceURL` is the response URL for this exact hop, so HTTPS downgrade checks remain
    /// correct across a multi-hop HTTP -> HTTPS -> HTTP chain.
    fileprivate func validateRedirectForNetworkDispatch(
        from sourceURL: URL,
        to destination: URL,
        purpose: SkyStreamNetworkPurpose
    ) async throws -> SkyStreamValidatedRemoteURL {
        let source = try validateSyntactic(
            sourceURL.absoluteString,
            purpose: purpose
        )
        let target = try await validateForNetworkDispatch(
            destination.absoluteString,
            purpose: purpose,
            relativeTo: source.url
        )
        if source.origin.scheme == "https" && target.origin.scheme != "https" {
            throw SkyStreamSecurityError.httpsDowngrade
        }
        return target
    }

    /// Synchronous checks used for parsing and headers. Call `validate` before
    /// performing network I/O so DNS results are checked as well.
    public func validateSyntactic(
        _ rawValue: String,
        purpose: SkyStreamNetworkPurpose,
        relativeTo baseURL: URL? = nil
    ) throws -> (url: URL, origin: SkyStreamRemoteOrigin, host: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SkyStreamSecurityError.emptyURL }
        guard trimmed.utf8.count <= 16_384,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !trimmed.contains("\\") else {
            throw SkyStreamSecurityError.malformedURL
        }

        guard let resolvedURL = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL,
              var components = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: false),
              let schemeValue = components.scheme?.lowercased(),
              schemeValue == "http" || schemeValue == "https" else {
            throw SkyStreamSecurityError.unsupportedScheme
        }
        if purpose.requiresHTTPS && schemeValue != "https" {
            throw SkyStreamSecurityError.insecureTransport
        }
        guard components.user == nil, components.password == nil else {
            throw SkyStreamSecurityError.credentialsInURL
        }
        guard let rawHost = components.host, !rawHost.isEmpty else {
            throw SkyStreamSecurityError.invalidHost
        }

        let host = Self.canonicalHost(rawHost)
        guard Self.isSyntacticallyValidHost(host) else {
            throw SkyStreamSecurityError.invalidHost
        }
        guard !Self.isLocalHostname(host) else {
            throw SkyStreamSecurityError.prohibitedHost
        }
        if let address = Self.parsedAddressLiteral(host), Self.isProhibitedAddress(address) {
            throw SkyStreamSecurityError.prohibitedAddress(address.description)
        }
        if Self.looksLikeNumericAddress(host), Self.parsedAddressLiteral(host) == nil {
            // Ambiguous numeric host forms have differed between URL parsers.
            throw SkyStreamSecurityError.invalidHost
        }

        if let port = components.port, !(1...65_535).contains(port) {
            throw SkyStreamSecurityError.invalidHost
        }

        // Fragments never participate in an HTTP request and may contain secrets.
        components.fragment = nil
        guard let canonicalURL = components.url else {
            throw SkyStreamSecurityError.malformedURL
        }
        let effectivePort = components.port ?? (schemeValue == "https" ? 443 : 80)
        return (
            canonicalURL,
            SkyStreamRemoteOrigin(scheme: schemeValue, host: host, port: effectivePort),
            host
        )
    }

    public static func redactedDescription(of rawValue: String?) -> String {
        guard let rawValue, let url = URL(string: rawValue) else { return "invalid-url" }
        return redactedDescription(of: url)
    }

    public static func redactedDescription(of url: URL) -> String {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return "invalid-url"
        }
        let defaultPort = scheme == "https" ? 443 : 80
        let portText = url.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(portText)"
    }

    static func normalizedPublicAddressString(_ value: String) -> String? {
        guard let parsed = parsedAddressLiteral(canonicalHost(value)),
              !isProhibitedAddress(parsed) else { return nil }
        return parsed.description
    }

    fileprivate static func isProhibitedAddressString(_ value: String) -> Bool {
        normalizedPublicAddressString(value) == nil
    }

    private func resolvePublicAddresses(
        for host: String,
        permitsCachedResult: Bool = true
    ) async throws -> [String] {
        try Task.checkCancellation()

        switch dnsResolution(for: host, permitsCachedResult: permitsCachedResult) {
        case .cached(let addresses):
            try Task.checkCancellation()
            return addresses

        case .lookup(let lookup):
            do {
                let addresses = try await lookup.task.value
                finishDNSLookup(addresses, for: host, token: lookup.token)
                try Task.checkCancellation()
                return addresses
            } catch {
                finishDNSLookup(nil, for: host, token: lookup.token)
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        }
    }

    private func dnsResolution(
        for host: String,
        permitsCachedResult: Bool
    ) -> DNSResolution {
        let now = Date()
        dnsCacheLock.lock()
        defer { dnsCacheLock.unlock() }

        if permitsCachedResult,
           var cached = dnsCache[host], cached.expiresAt > now {
            dnsAccessOrdinal &+= 1
            cached.accessOrdinal = dnsAccessOrdinal
            dnsCache[host] = cached
            return .cached(cached.addresses)
        }
        dnsCache.removeValue(forKey: host)

        if let existing = dnsInFlight[host] {
            return .lookup(existing)
        }
        dnsLookupToken &+= 1
        let lookup = DNSInFlightLookup(
            token: dnsLookupToken,
            task: makeDNSLookupTask(for: host)
        )
        dnsInFlight[host] = lookup
        return .lookup(lookup)
    }

    private func makeDNSLookupTask(for host: String) -> Task<[String], Error> {
        let resolverQueue = resolverQueue
        let addressResolver = addressResolver
        return Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                resolverQueue.async {
                    do {
                        let addresses = try addressResolver(host)
                        guard !addresses.isEmpty else {
                            throw SkyStreamSecurityError.dnsReturnedNoAddresses
                        }
                        guard !addresses.contains(where: Self.isProhibitedAddressString) else {
                            throw SkyStreamSecurityError.prohibitedAddress("redacted")
                        }
                        continuation.resume(returning: Array(Set(addresses)).sorted())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func finishDNSLookup(_ addresses: [String]?, for host: String, token: UInt64) {
        dnsCacheLock.lock()
        defer { dnsCacheLock.unlock() }
        guard dnsInFlight[host]?.token == token else { return }
        dnsInFlight.removeValue(forKey: host)
        guard let addresses else { return }

        let now = Date()
        let expiredHosts = dnsCache.compactMap { cachedHost, entry in
            entry.expiresAt <= now ? cachedHost : nil
        }
        for cachedHost in expiredHosts {
            dnsCache.removeValue(forKey: cachedHost)
        }
        dnsCache.removeValue(forKey: host)
        while dnsCache.count >= maximumDNSCacheEntries,
              let oldestHost = dnsCache.min(by: {
                  $0.value.accessOrdinal < $1.value.accessOrdinal
              })?.key {
            dnsCache.removeValue(forKey: oldestHost)
        }
        dnsAccessOrdinal &+= 1
        dnsCache[host] = DNSCacheEntry(
            addresses: addresses,
            expiresAt: now.addingTimeInterval(30),
            accessOrdinal: dnsAccessOrdinal
        )
    }

    private static func resolveAddressesSynchronously(_ host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var resultPointer: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &resultPointer)
        guard status == 0 else { throw SkyStreamSecurityError.dnsResolutionFailed }
        defer { if let resultPointer { freeaddrinfo(resultPointer) } }

        var addresses: [String] = []
        var seen = Set<String>()
        var current = resultPointer
        while let node = current {
            defer { current = node.pointee.ai_next }
            guard let socketAddress = node.pointee.ai_addr else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let lookup = getnameinfo(
                socketAddress,
                node.pointee.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard lookup == 0 else { continue }
            let value = String(cString: buffer)
            guard !isProhibitedAddressString(value) else {
                throw SkyStreamSecurityError.prohibitedAddress(value)
            }
            if seen.insert(value).inserted { addresses.append(value) }
        }
        guard !addresses.isEmpty else { throw SkyStreamSecurityError.dnsReturnedNoAddresses }
        return addresses.sorted()
    }

    private enum ParsedAddress: CustomStringConvertible {
        case ipv4(UInt32)
        case ipv6([UInt8])

        var description: String {
            switch self {
            case .ipv4(let value):
                return [24, 16, 8, 0]
                    .map { String((value >> UInt32($0)) & 0xff) }
                    .joined(separator: ".")
            case .ipv6(let bytes):
                var address = in6_addr()
                withUnsafeMutableBytes(of: &address) { destination in
                    destination.copyBytes(from: bytes)
                }
                var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                return withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: UInt8.self, capacity: 16) { rawPointer in
                        inet_ntop(AF_INET6, rawPointer, &output, socklen_t(output.count))
                    }
                }.map { _ in String(cString: output) } ?? "invalid-ipv6"
            }
        }
    }

    static func canonicalHost(_ rawHost: String) -> String {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        if host.hasSuffix(".") { host.removeLast() }
        return host
    }

    private static func isSyntacticallyValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253,
              !host.contains("%"), !host.contains("/") else { return false }
        if parsedAddressLiteral(host) != nil { return true }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
        }
    }

    private static func isLocalHostname(_ host: String) -> Bool {
        let exact: Set<String> = [
            "localhost", "localhost.localdomain", "broadcasthost", "ip6-localhost", "ip6-loopback"
        ]
        if exact.contains(host) { return true }
        let localSuffixes = [".localhost", ".local", ".localdomain", ".lan", ".home", ".internal"]
        return localSuffixes.contains { host.hasSuffix($0) }
    }

    private static func looksLikeNumericAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let numeric = CharacterSet(charactersIn: "0123456789abcdefxABCDEF.")
        return host.unicodeScalars.allSatisfy { numeric.contains($0) }
            && host.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
    }

    private static func parsedAddressLiteral(_ host: String) -> ParsedAddress? {
        if let ipv4 = parseLegacyIPv4(host) { return .ipv4(ipv4) }

        var ipv6 = in6_addr()
        let parsed = host.withCString { inet_pton(AF_INET6, $0, &ipv6) }
        guard parsed == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
        return .ipv6(bytes)
    }

    /// Parses the historical inet_aton forms accepted by multiple URL stacks:
    /// decimal/octal/hex components and one-, two-, or three-dot forms.
    private static func parseLegacyIPv4(_ host: String) -> UInt32? {
        guard !host.contains(":") else { return nil }
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count), pieces.allSatisfy({ !$0.isEmpty }) else { return nil }

        func component(_ value: Substring) -> UInt64? {
            let string = String(value)
            if string.hasPrefix("0x") || string.hasPrefix("0X") {
                guard string.count > 2 else { return nil }
                return UInt64(string.dropFirst(2), radix: 16)
            }
            if string.count > 1 && string.hasPrefix("0") {
                return UInt64(string.dropFirst(), radix: 8) ?? (string.allSatisfy { $0 == "0" } ? 0 : nil)
            }
            return UInt64(string, radix: 10)
        }

        let values = pieces.compactMap(component)
        guard values.count == pieces.count else { return nil }
        let result: UInt64
        switch values.count {
        case 1:
            guard values[0] <= 0xffff_ffff else { return nil }
            result = values[0]
        case 2:
            guard values[0] <= 0xff, values[1] <= 0x00ff_ffff else { return nil }
            result = (values[0] << 24) | values[1]
        case 3:
            guard values[0] <= 0xff, values[1] <= 0xff, values[2] <= 0xffff else { return nil }
            result = (values[0] << 24) | (values[1] << 16) | values[2]
        case 4:
            guard values.allSatisfy({ $0 <= 0xff }) else { return nil }
            result = (values[0] << 24) | (values[1] << 16) | (values[2] << 8) | values[3]
        default:
            return nil
        }
        return UInt32(result)
    }

    private static func isProhibitedAddress(_ address: ParsedAddress) -> Bool {
        switch address {
        case .ipv4(let value):
            return isProhibitedIPv4(value)
        case .ipv6(let bytes):
            guard bytes.count == 16 else { return true }
            if bytes.allSatisfy({ $0 == 0 }) { return true } // unspecified
            if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return true } // loopback
            if bytes[0] & 0xfe == 0xfc { return true } // unique-local fc00::/7
            if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return true } // link-local fe80::/10
            if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0xc0 { return true } // deprecated site-local fec0::/10
            if bytes[0] == 0xff { return true } // multicast
            if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8 {
                return true // documentation
            }
            if bytes[0] == 0x01 && bytes.dropFirst().prefix(7).allSatisfy({ $0 == 0 }) {
                return true // discard-only 100::/64
            }
            let isMappedIPv4 = bytes.prefix(10).allSatisfy({ $0 == 0 })
                && bytes[10] == 0xff && bytes[11] == 0xff
            if isMappedIPv4 {
                let value = bytes[12...15].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                return isProhibitedIPv4(value)
            }
            let isCompatibleIPv4 = bytes.prefix(12).allSatisfy({ $0 == 0 })
            if isCompatibleIPv4 {
                let value = bytes[12...15].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                return isProhibitedIPv4(value)
            }
            // Well-known and local-use NAT64 prefixes retain an embedded IPv4
            // address in the final 32 bits.
            // The local-use translation prefix is a /48 and can place the embedded IPv4
            // address at different bit offsets. Reject the complete prefix rather than only
            // checking its final 32 bits.
            if bytes[0...5] == [0x00, 0x64, 0xff, 0x9b, 0x00, 0x01] {
                return true // local-use NAT64 64:ff9b:1::/48
            }
            let isNAT64 = bytes[0...3] == [0x00, 0x64, 0xff, 0x9b]
                && bytes[4...11].allSatisfy({ $0 == 0 })
            if isNAT64 {
                let value = bytes[12...15].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                return isProhibitedIPv4(value)
            }
            // 6to4 embeds IPv4 immediately after 2002::/16.
            if bytes[0] == 0x20 && bytes[1] == 0x02 {
                let value = bytes[2...5].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                return isProhibitedIPv4(value)
            }
            if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x00 && bytes[3] == 0x00 {
                return true // Teredo
            }
            if bytes[0] == 0x20 && bytes[1] == 0x01
                && (bytes[2] & 0xf0 == 0x10 || bytes[2] & 0xf0 == 0x20) {
                return true // deprecated ORCHID and ORCHIDv2
            }
            if bytes[0...5] == [0x20, 0x01, 0x00, 0x02, 0x00, 0x00] {
                return true // benchmarking 2001:2::/48
            }
            if bytes[0] == 0x3f && bytes[1] & 0xf0 == 0xf0 {
                return true // documentation 3fff::/20
            }
            return false
        }
    }

    private static func isProhibitedIPv4(_ value: UInt32) -> Bool {
        func inRange(_ network: UInt32, _ prefix: UInt32) -> Bool {
            let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
            return value & mask == network & mask
        }

        return inRange(0x0000_0000, 8)       // current network / unspecified
            || inRange(0x0a00_0000, 8)      // RFC1918
            || inRange(0x6440_0000, 10)     // carrier-grade NAT
            || inRange(0x7f00_0000, 8)      // loopback
            || inRange(0xa9fe_0000, 16)     // link-local
            || inRange(0xac10_0000, 12)     // RFC1918
            || inRange(0xc000_0000, 24)     // IETF protocol assignments
            || inRange(0xc000_0200, 24)     // documentation
            || inRange(0xc058_6300, 24)     // deprecated relay anycast
            || inRange(0xc0a8_0000, 16)     // RFC1918
            || inRange(0xc612_0000, 15)     // benchmark tests
            || inRange(0xc633_6400, 24)     // documentation
            || inRange(0xcb00_7100, 24)     // documentation
            || inRange(0xe000_0000, 4)      // multicast
            || inRange(0xf000_0000, 4)      // reserved / broadcast
    }
}

// MARK: - Header boundary

public enum SkyStreamHeaderPurpose: Sendable, Hashable {
    case pluginRequest
    case stream
    case subtitle
    case manifest
}

public struct SkyStreamSanitizedHeaders: Sendable, Hashable {
    public let values: [String: String]

    fileprivate init(values: [String: String]) {
        self.values = values
    }

    public static let empty = SkyStreamSanitizedHeaders(values: [:])

    /// Removes credentials and plugin-specific headers on a cross-origin
    /// redirect. Same-origin redirects retain the already-sanitized set.
    public func scopedForRedirect(
        from source: SkyStreamRemoteOrigin,
        to destination: SkyStreamRemoteOrigin
    ) -> SkyStreamSanitizedHeaders {
        guard !source.isSameOrigin(as: destination) else { return self }
        let crossOriginSafe: Set<String> = [
            "accept", "accept-language", "cache-control", "dnt", "pragma", "user-agent"
        ]
        return SkyStreamSanitizedHeaders(values: values.filter { crossOriginSafe.contains($0.key) })
    }

    /// Safe subset for a generated manifest that has no trustworthy origin to
    /// which plugin credentials can be scoped.
    public func removingOriginCredentials() -> SkyStreamSanitizedHeaders {
        let safe: Set<String> = [
            "accept", "accept-language", "cache-control", "dnt", "pragma", "user-agent"
        ]
        return SkyStreamSanitizedHeaders(values: values.filter { safe.contains($0.key) })
    }
}

public enum SkyStreamHeaderSanitizer {
    private static let forbiddenNames: Set<String> = [
        "accept-encoding", "connection", "content-length", "host", "keep-alive",
        "proxy-authenticate", "proxy-authorization", "proxy-connection", "range", "te",
        "trailer", "transfer-encoding", "upgrade"
    ]
    private static let validNameCharacters = CharacterSet(
        charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    )

    public static func sanitize(
        _ rawHeaders: [String: String],
        purpose: SkyStreamHeaderPurpose,
        maximumCount: Int = 64,
        maximumTotalBytes: Int = 32 * 1024
    ) throws -> SkyStreamSanitizedHeaders {
        guard rawHeaders.count <= maximumCount else { throw SkyStreamSecurityError.tooManyHeaders }
        var result: [String: String] = [:]
        var totalBytes = 0

        for (rawName, rawValue) in rawHeaders {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.utf8.count <= 128,
                  name.unicodeScalars.allSatisfy({ $0.value < 128 && validNameCharacters.contains($0) }) else {
                throw SkyStreamSecurityError.invalidHeaderName
            }
            guard value.utf8.count <= 8 * 1024,
                  value.unicodeScalars.allSatisfy({ scalar in
                      scalar.value == 9 || (scalar.value >= 32 && scalar.value != 127)
                  }) else {
                throw SkyStreamSecurityError.invalidHeaderValue
            }

            let normalizedName = name.lowercased()
            guard result[normalizedName] == nil else { throw SkyStreamSecurityError.duplicateHeader }
            guard !forbiddenNames.contains(normalizedName), !normalizedName.hasPrefix("proxy-") else {
                throw SkyStreamSecurityError.forbiddenHeader
            }

            if normalizedName == "referer" || normalizedName == "origin" {
                _ = try SkyStreamRemoteURLPolicy.shared.validateSyntactic(
                    value,
                    purpose: .pluginRequest
                )
            }

            totalBytes += normalizedName.utf8.count + value.utf8.count + 4
            guard totalBytes <= maximumTotalBytes else { throw SkyStreamSecurityError.headersTooLarge }
            result[normalizedName] = value
        }
        return SkyStreamSanitizedHeaders(values: result)
    }
}

// MARK: - Bounded package HTTP client

public struct SkyStreamHTTPRequest: Sendable {
    public let url: SkyStreamValidatedRemoteURL
    public let method: String
    public let headers: SkyStreamSanitizedHeaders
    public let body: Data?
    /// A client-managed Range header. Plugin headers cannot set Range directly.
    public let byteRange: ClosedRange<Int64>?
    /// UI metadata such as icons must not participate in a plugin cookie namespace. Runtime HTTP
    /// keeps the default cookie-compatible behavior required by the SkyStream ABI.
    public let allowsCookies: Bool

    public init(
        url: SkyStreamValidatedRemoteURL,
        method: String = "GET",
        headers: SkyStreamSanitizedHeaders = .empty,
        body: Data? = nil,
        byteRange: ClosedRange<Int64>? = nil,
        allowsCookies: Bool = true
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.byteRange = byteRange
        self.allowsCookies = allowsCookies
    }
}

public struct SkyStreamHTTPResponse: @unchecked Sendable {
    public let data: Data
    public let response: HTTPURLResponse
    /// The sanitized plugin headers that remained after the complete redirect chain. Once a
    /// cross-origin hop removes a credential it is never reintroduced by a later redirect.
    public let effectiveRequestHeaders: SkyStreamSanitizedHeaders

    public var statusCode: Int { response.statusCode }
    public var finalURL: URL { response.url ?? URL(string: "about:blank")! }

    public func header(_ name: String) -> String? {
        response.allHeaderFields.first { key, _ in
            (key as? String)?.caseInsensitiveCompare(name) == .orderedSame
        }.map { String(describing: $0.value) }
    }
}

public struct SkyStreamHTTPRequestLimits: Sendable, Hashable {
    public var maximumResponseBytes: Int
    public var maximumRequestBodyBytes: Int
    public var maximumRedirects: Int
    public var timeout: TimeInterval

    public init(
        maximumResponseBytes: Int = 10_000_000,
        maximumRequestBodyBytes: Int = 2_000_000,
        maximumRedirects: Int = 5,
        timeout: TimeInterval = 30
    ) {
        self.maximumResponseBytes = max(1, min(maximumResponseBytes, 20_000_000))
        self.maximumRequestBodyBytes = max(0, min(maximumRequestBodyBytes, 4_000_000))
        self.maximumRedirects = max(0, min(maximumRedirects, 10))
        self.timeout = max(1, min(timeout, 120))
    }

    public static let plugin = SkyStreamHTTPRequestLimits()
    public static let manifest = SkyStreamHTTPRequestLimits(
        maximumResponseBytes: 2_000_000,
        maximumRequestBodyBytes: 0,
        maximumRedirects: 5,
        timeout: 20
    )
    public static let subtitle = SkyStreamHTTPRequestLimits(
        maximumResponseBytes: 4_000_000,
        maximumRequestBodyBytes: 0,
        maximumRedirects: 5,
        timeout: 20
    )
}

/// Shared entry point whose underlying sessions and cookies are isolated by
/// plugin package. URLSession cookies are disabled; a bounded in-memory jar is
/// maintained explicitly for each package.
public final class SkyStreamHTTPClient: @unchecked Sendable {
    public static let shared = SkyStreamHTTPClient()

    private let lock = NSLock()
    private var packageSessions: [String: SkyStreamPackageHTTPSession] = [:]
    private let policy: SkyStreamRemoteURLPolicy
    private let maximumPackageSessions = 64

    public init(policy: SkyStreamRemoteURLPolicy = .shared) {
        self.policy = policy
    }

    public func fetch(
        _ request: SkyStreamHTTPRequest,
        packageID: String,
        limits: SkyStreamHTTPRequestLimits = .plugin
    ) async throws -> SkyStreamHTTPResponse {
        try Task.checkCancellation()
        let packageID = try Self.validatedPackageID(packageID)
        guard request.body?.count ?? 0 <= limits.maximumRequestBodyBytes else {
            throw SkyStreamSecurityError.requestBodyTooLarge
        }
        let method = request.method.uppercased()
        // Match the ordinary HTTP verbs accepted by the SkyStream fetch bridge while
        // continuing to reject tunneling/debug verbs such as CONNECT and TRACE.
        guard ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"].contains(method) else {
            throw SkyStreamSecurityError.invalidMethod
        }
        if let range = request.byteRange {
            guard method == "GET", range.lowerBound >= 0, range.upperBound >= range.lowerBound,
                  range.upperBound - range.lowerBound < 1_000_000 else {
                throw SkyStreamSecurityError.invalidByteRange
            }
        }

        // Repeat URL and DNS validation at the I/O boundary.
        let checkedURL = try await policy.validateForNetworkDispatch(
            request.url.url.absoluteString,
            purpose: request.url.purpose
        )
        let checkedRequest = SkyStreamHTTPRequest(
            url: checkedURL,
            method: method,
            headers: request.headers,
            body: request.body,
            byteRange: request.byteRange,
            allowsCookies: request.allowsCookies
        )
        let session = packageSession(for: packageID)
        return try await session.perform(checkedRequest, limits: limits)
    }

    public func reset(packageID: String) {
        lock.lock()
        let session = packageSessions.removeValue(forKey: packageID)
        lock.unlock()
        session?.invalidate()
    }

    public func resetAll() {
        lock.lock()
        let sessions = Array(packageSessions.values)
        packageSessions.removeAll()
        lock.unlock()
        sessions.forEach { $0.invalidate() }
    }

    /// Returns only cookies from this package's isolated in-memory jar which RFC-match the exact
    /// validated destination. Callers may copy the value into an immutable playback descriptor;
    /// cookie values are never persisted or logged.
    public func cookieHeader(for url: URL, packageID: String) throws -> String? {
        let packageID = try Self.validatedPackageID(packageID)
        lock.lock()
        let session = packageSessions[packageID]
        lock.unlock()
        return session?.cookieHeader(for: url)
    }

    private func packageSession(for packageID: String) -> SkyStreamPackageHTTPSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = packageSessions[packageID] { return existing }
        if packageSessions.count >= maximumPackageSessions, let key = packageSessions.keys.sorted().first {
            packageSessions.removeValue(forKey: key)?.invalidate()
        }
        let created = SkyStreamPackageHTTPSession(packageID: packageID, policy: policy)
        packageSessions[packageID] = created
        return created
    }

    private static func validatedPackageID(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !trimmed.isEmpty, trimmed.utf8.count <= 160,
              trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw SkyStreamSecurityError.invalidPackageID
        }
        return trimmed
    }
}

private final class SkyStreamPackageCookieJar {
    private struct CookieKey: Hashable {
        let name: String
        let domain: String
        let path: String
    }

    private struct StoredCookie {
        let cookie: HTTPCookie
        /// Foundation does not expose a trustworthy Public Suffix List decision for Domain
        /// cookies. Bind every package cookie to the exact response host instead.
        let boundHost: String
    }

    private let lock = NSLock()
    private var cookies: [CookieKey: StoredCookie] = [:]
    private let maximumCookies = 128
    private let maximumCookieBytes = 32 * 1024

    init() {}

    /// A request gets a consistent cookie view. Response cookies remain in this copy until the
    /// complete URLSession transaction is known to have succeeded, so a cancelled, oversized,
    /// or post-metrics-rejected response cannot mutate the package-wide jar.
    init(snapshotOf other: SkyStreamPackageCookieJar) {
        other.lock.lock()
        cookies = other.cookies
        other.lock.unlock()
    }

    func cookieHeader(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let requestPath = url.path.isEmpty ? "/" : url.path
        let isHTTPS = url.scheme?.lowercased() == "https"
        let now = Date()

        lock.lock()
        cookies = cookies.filter { $0.value.cookie.expiresDate.map { $0 > now } ?? true }
        let matches = cookies.values.filter { stored in
            let cookie = stored.cookie
            return stored.boundHost == host && Self.path(cookie.path, matches: requestPath)
                && (!cookie.isSecure || isHTTPS)
        }.sorted { lhs, rhs in
            if lhs.cookie.path.count == rhs.cookie.path.count {
                return lhs.cookie.name < rhs.cookie.name
            }
            return lhs.cookie.path.count > rhs.cookie.path.count
        }
        lock.unlock()

        let header = matches.map { "\($0.cookie.name)=\($0.cookie.value)" }.joined(separator: "; ")
        return header.isEmpty ? nil : header
    }

    func store(response: HTTPURLResponse) {
        guard let url = response.url, let responseHost = url.host?.lowercased() else { return }
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String else { continue }
            fields[key] = String(describing: value)
        }
        let received = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !received.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        for cookie in received.prefix(32) {
            let cookieDomain = Self.canonicalDomain(cookie.domain)
            guard responseHost == cookieDomain || responseHost.hasSuffix("." + cookieDomain),
                  cookieDomain.split(separator: ".").count >= 2 else { continue }
            guard !cookie.isSecure || url.scheme?.lowercased() == "https" else { continue }
            if cookie.name.hasPrefix("__Host-") {
                guard cookie.isSecure, cookie.path == "/",
                      cookieDomain == responseHost, url.scheme?.lowercased() == "https" else { continue }
            }
            if cookie.name.hasPrefix("__Secure-")
                && (!cookie.isSecure || url.scheme?.lowercased() != "https") { continue }
            let key = CookieKey(
                name: cookie.name,
                domain: responseHost,
                path: cookie.path
            )
            if cookie.expiresDate.map({ $0 <= Date() }) == true || cookie.value.isEmpty {
                cookies.removeValue(forKey: key)
            } else {
                cookies[key] = StoredCookie(cookie: cookie, boundHost: responseHost)
            }
        }
        enforceQuotaLocked()
    }

    func removeAll() {
        lock.lock()
        cookies.removeAll()
        lock.unlock()
    }

    private func enforceQuotaLocked() {
        if cookies.count > maximumCookies {
            let sorted = cookies.keys.sorted {
                let lhsExpiry = cookies[$0]?.cookie.expiresDate ?? .distantFuture
                let rhsExpiry = cookies[$1]?.cookie.expiresDate ?? .distantFuture
                return lhsExpiry < rhsExpiry
            }
            for key in sorted.prefix(cookies.count - maximumCookies) { cookies.removeValue(forKey: key) }
        }
        var total = cookies.values.reduce(0) {
            let cookie = $1.cookie
            return $0 + cookie.name.utf8.count + cookie.value.utf8.count
                + cookie.domain.utf8.count + cookie.path.utf8.count
        }
        if total > maximumCookieBytes {
            for key in cookies.keys.sorted(by: { $0.name < $1.name }) {
                guard total > maximumCookieBytes, let removed = cookies.removeValue(forKey: key) else { break }
                let cookie = removed.cookie
                total -= cookie.name.utf8.count + cookie.value.utf8.count
                    + cookie.domain.utf8.count + cookie.path.utf8.count
            }
        }
    }

    private static func canonicalDomain(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }

    private static func path(_ cookiePath: String, matches requestPath: String) -> Bool {
        let normalized = cookiePath.isEmpty ? "/" : cookiePath
        guard requestPath.hasPrefix(normalized) else { return false }
        return normalized.hasSuffix("/") || requestPath.count == normalized.count
            || requestPath.dropFirst(normalized.count).first == "/"
    }
}

private final class SkyStreamPackageHTTPSession: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private final class RequestState {
        let token: UUID
        let sourceURL: SkyStreamValidatedRemoteURL
        let originalHeaders: SkyStreamSanitizedHeaders
        var effectiveHeaders: SkyStreamSanitizedHeaders
        let method: String
        let byteRange: ClosedRange<Int64>?
        let allowsCookies: Bool
        let limits: SkyStreamHTTPRequestLimits
        let continuation: CheckedContinuation<SkyStreamHTTPResponse, Error>
        let requestCookieJar: SkyStreamPackageCookieJar
        var cookieResponses: [HTTPURLResponse] = []
        var response: HTTPURLResponse?
        var buffer = Data()
        var redirectCount = 0
        var terminalError: Error?
        var finished = false
        /// Public numeric addresses approved immediately before dispatch, keyed by the canonical
        /// request host. Metrics must report one of these exact addresses for every transaction.
        var approvedAddressesByHost: [String: Set<String>]

        init(
            token: UUID,
            sourceURL: SkyStreamValidatedRemoteURL,
            originalHeaders: SkyStreamSanitizedHeaders,
            method: String,
            byteRange: ClosedRange<Int64>?,
            allowsCookies: Bool,
            limits: SkyStreamHTTPRequestLimits,
            requestCookieJar: SkyStreamPackageCookieJar,
            continuation: CheckedContinuation<SkyStreamHTTPResponse, Error>
        ) {
            self.token = token
            self.sourceURL = sourceURL
            self.originalHeaders = originalHeaders
            self.effectiveHeaders = originalHeaders
            self.method = method
            self.byteRange = byteRange
            self.allowsCookies = allowsCookies
            self.limits = limits
            self.requestCookieJar = requestCookieJar
            self.continuation = continuation
            self.approvedAddressesByHost = [
                sourceURL.origin.host: Set(
                    sourceURL.checkedAddresses.compactMap(
                        SkyStreamRemoteURLPolicy.normalizedPublicAddressString
                    )
                )
            ]
        }
    }

    private let packageID: String
    private let policy: SkyStreamRemoteURLPolicy
    private let cookieJar = SkyStreamPackageCookieJar()
    private let stateLock = NSLock()
    private var statesByTaskID: [Int: RequestState] = [:]
    private var tasksByToken: [UUID: URLSessionTask] = [:]
    /// Tokens exist here only during the short synchronous interval between entering `perform`
    /// and publishing the URLSession task. Cancellation may leave a marker only for one of these
    /// known tokens; a late cancellation for an already-completed task is deliberately ignored.
    private var pendingRegistrationTokens = Set<UUID>()
    private var cancelledPendingRegistrationTokens = Set<UUID>()
    private var invalidated = false
    private let maximumConcurrentRequests = 8
    private var urlSession: URLSession!

    init(packageID: String, policy: SkyStreamRemoteURLPolicy) {
        self.packageID = packageID
        self.policy = policy
        super.init()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 4
        let delegateQueue = OperationQueue()
        delegateQueue.name = "app.eclipse.skystream.http.\(packageID)"
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .userInitiated
        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    func perform(
        _ skyRequest: SkyStreamHTTPRequest,
        limits: SkyStreamHTTPRequestLimits
    ) async throws -> SkyStreamHTTPResponse {
        let token = UUID()
        try registerPendingToken(token)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let requestCookieJar = skyRequest.allowsCookies
                    ? SkyStreamPackageCookieJar(snapshotOf: cookieJar)
                    : SkyStreamPackageCookieJar()
                var request = URLRequest(url: skyRequest.url.url)
                request.httpMethod = skyRequest.method
                request.httpBody = skyRequest.body
                request.timeoutInterval = limits.timeout
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                if let range = skyRequest.byteRange {
                    request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
                }
                for (name, value) in skyRequest.headers.values {
                    request.setValue(value, forHTTPHeaderField: name)
                }
                if skyRequest.allowsCookies,
                   let jarCookie = requestCookieJar.cookieHeader(for: skyRequest.url.url) {
                    let explicit = request.value(forHTTPHeaderField: "Cookie")
                    request.setValue(Self.mergeCookieHeaders(explicit, jarCookie), forHTTPHeaderField: "Cookie")
                }

                stateLock.lock()
                pendingRegistrationTokens.remove(token)
                let wasCancelled = cancelledPendingRegistrationTokens.remove(token) != nil
                guard !invalidated else {
                    stateLock.unlock()
                    continuation.resume(throwing: SkyStreamSecurityError.cancelled)
                    return
                }
                guard statesByTaskID.count < maximumConcurrentRequests else {
                    stateLock.unlock()
                    continuation.resume(throwing: SkyStreamSecurityError.tooManyConcurrentRequests)
                    return
                }

                let task = urlSession.dataTask(with: request)
                let state = RequestState(
                    token: token,
                    sourceURL: skyRequest.url,
                    originalHeaders: skyRequest.headers,
                    method: skyRequest.method,
                    byteRange: skyRequest.byteRange,
                    allowsCookies: skyRequest.allowsCookies,
                    limits: limits,
                    requestCookieJar: requestCookieJar,
                    continuation: continuation
                )
                statesByTaskID[task.taskIdentifier] = state
                tasksByToken[token] = task
                stateLock.unlock()

                if wasCancelled || Task.isCancelled {
                    cancel(token: token)
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            self.cancel(token: token)
        }
    }

    /// Keep the lock scope synchronous so this lifecycle registry remains valid under Swift 6's
    /// async-safety checks without changing the URLSession delegate's lock-based ownership model.
    private func registerPendingToken(_ token: UUID) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !invalidated else { throw SkyStreamSecurityError.cancelled }
        pendingRegistrationTokens.insert(token)
    }

    func invalidate() {
        stateLock.lock()
        invalidated = true
        let states = Array(statesByTaskID.values)
        statesByTaskID.removeAll()
        let tasks = Array(tasksByToken.values)
        tasksByToken.removeAll()
        pendingRegistrationTokens.removeAll(keepingCapacity: false)
        cancelledPendingRegistrationTokens.removeAll(keepingCapacity: false)
        stateLock.unlock()

        tasks.forEach { $0.cancel() }
        for state in states where !state.finished {
            state.finished = true
            state.continuation.resume(throwing: SkyStreamSecurityError.cancelled)
        }
        cookieJar.removeAll()
        urlSession.invalidateAndCancel()
    }

    func cookieHeader(for url: URL) -> String? {
        cookieJar.cookieHeader(for: url)
    }

    private func cancel(token: UUID) {
        stateLock.lock()
        guard let task = tasksByToken[token] else {
            if pendingRegistrationTokens.contains(token) {
                cancelledPendingRegistrationTokens.insert(token)
            }
            stateLock.unlock()
            return
        }
        if let state = statesByTaskID[task.taskIdentifier] {
            state.terminalError = SkyStreamSecurityError.cancelled
        }
        stateLock.unlock()
        task.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse,
              let state = state(for: dataTask.taskIdentifier) else {
            completionHandler(.cancel)
            return
        }
        if state.method != "HEAD",
           response.expectedContentLength > Int64(state.limits.maximumResponseBytes) {
            fail(task: dataTask, with: SkyStreamSecurityError.responseTooLarge)
            completionHandler(.cancel)
            return
        }
        state.response = http
        if state.allowsCookies {
            state.requestCookieJar.store(response: http)
            state.cookieResponses.append(http)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let state = state(for: dataTask.taskIdentifier) else {
            dataTask.cancel()
            return
        }
        guard state.buffer.count <= state.limits.maximumResponseBytes - data.count else {
            fail(task: dataTask, with: SkyStreamSecurityError.responseTooLarge)
            return
        }
        state.buffer.append(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let state = state(for: task.taskIdentifier), let destination = request.url else {
            completionHandler(nil)
            return
        }
        guard state.redirectCount < state.limits.maximumRedirects else {
            fail(task: task, with: SkyStreamSecurityError.tooManyRedirects)
            completionHandler(nil)
            return
        }
        if state.allowsCookies {
            state.requestCookieJar.store(response: response)
            state.cookieResponses.append(response)
        }
        state.redirectCount += 1

        let sourceString = response.url?.absoluteString ?? state.sourceURL.url.absoluteString
        Task {
            do {
                let source = try policy.validateSyntactic(
                    sourceString,
                    purpose: state.sourceURL.purpose
                )
                let target = try await policy.validateRedirectForNetworkDispatch(
                    from: source.url,
                    to: destination,
                    purpose: state.sourceURL.purpose
                )
                guard self.state(for: task.taskIdentifier) != nil else {
                    completionHandler(nil)
                    return
                }

                var redirected = request
                for name in (redirected.allHTTPHeaderFields ?? [:]).keys {
                    redirected.setValue(nil, forHTTPHeaderField: name)
                }
                redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let scoped = state.effectiveHeaders.scopedForRedirect(
                    from: source.origin,
                    to: target.origin
                )
                guard self.recordApprovedRedirect(
                    target,
                    effectiveHeaders: scoped,
                    taskID: task.taskIdentifier,
                    expectedState: state
                ) else {
                    completionHandler(nil)
                    return
                }
                for (name, value) in scoped.values {
                    redirected.setValue(value, forHTTPHeaderField: name)
                }
                if redirected.httpMethod == "GET", let range = state.byteRange {
                    redirected.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
                }
                if state.allowsCookies,
                   let cookie = state.requestCookieJar.cookieHeader(for: target.url) {
                    let explicit = redirected.value(forHTTPHeaderField: "Cookie")
                    redirected.setValue(Self.mergeCookieHeaders(explicit, cookie), forHTTPHeaderField: "Cookie")
                }
                completionHandler(redirected)
            } catch {
                self.fail(task: task, with: error)
                completionHandler(nil)
            }
        }
    }

    /// Defense in depth only: URLSession reports the connected address after a
    /// transaction. Failing here prevents use of the response, but does not turn
    /// the preflight DNS check into address pinning.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        for transaction in metrics.transactionMetrics {
            guard let remote = transaction.remoteAddress else { continue }
            let requestHost = transaction.request.url?.host.map(
                SkyStreamRemoteURLPolicy.canonicalHost
            )
            let normalizedRemote = SkyStreamRemoteURLPolicy.normalizedPublicAddressString(remote)
            let approved = requestHost.flatMap {
                approvedAddresses(forHost: $0, taskID: task.taskIdentifier)
            }
            guard let normalizedRemote,
                  approved?.contains(normalizedRemote) == true else {
                fail(task: task, with: SkyStreamSecurityError.prohibitedAddress(remote))
                return
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        stateLock.lock()
        guard let state = statesByTaskID.removeValue(forKey: task.taskIdentifier) else {
            stateLock.unlock()
            return
        }
        tasksByToken.removeValue(forKey: state.token)
        guard !state.finished else {
            stateLock.unlock()
            return
        }
        state.finished = true
        let terminalError = state.terminalError
        let response = state.response
        let data = state.buffer
        stateLock.unlock()

        if let terminalError {
            state.continuation.resume(throwing: terminalError)
        } else if let urlError = error as? URLError, urlError.code == .cancelled {
            state.continuation.resume(throwing: SkyStreamSecurityError.cancelled)
        } else if let error {
            state.continuation.resume(throwing: error)
        } else if let response {
            // Commit only after the complete transaction (including the metrics callback) has
            // succeeded. Replaying response mutations avoids overwriting cookies committed by a
            // different concurrent request after this request took its initial snapshot.
            if state.allowsCookies {
                state.cookieResponses.forEach { cookieJar.store(response: $0) }
            }
            state.continuation.resume(
                returning: SkyStreamHTTPResponse(
                    data: data,
                    response: response,
                    effectiveRequestHeaders: state.effectiveHeaders
                )
            )
        } else {
            state.continuation.resume(throwing: SkyStreamSecurityError.invalidResponse)
        }
    }

    private func state(for taskID: Int) -> RequestState? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return statesByTaskID[taskID]
    }

    private func recordApprovedRedirect(
        _ target: SkyStreamValidatedRemoteURL,
        effectiveHeaders: SkyStreamSanitizedHeaders,
        taskID: Int,
        expectedState: RequestState
    ) -> Bool {
        let addresses = Set(
            target.checkedAddresses.compactMap(
                SkyStreamRemoteURLPolicy.normalizedPublicAddressString
            )
        )
        guard !addresses.isEmpty else { return false }
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let state = statesByTaskID[taskID], state === expectedState,
              !state.finished else { return false }
        state.approvedAddressesByHost[target.origin.host, default: []].formUnion(addresses)
        state.effectiveHeaders = effectiveHeaders
        return true
    }

    private func approvedAddresses(forHost host: String, taskID: Int) -> Set<String>? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return statesByTaskID[taskID]?.approvedAddressesByHost[host]
    }

    private func fail(task: URLSessionTask, with error: Error) {
        stateLock.lock()
        statesByTaskID[task.taskIdentifier]?.terminalError = error
        stateLock.unlock()
        task.cancel()
    }

    private static func mergeCookieHeaders(_ explicit: String?, _ jar: String) -> String {
        var pairs: [String: String] = [:]
        for header in [explicit, jar].compactMap({ $0 }) {
            for component in header.split(separator: ";") {
                let parts = component.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                pairs[name] = value
            }
        }
        return pairs.keys.sorted().compactMap { key in pairs[key].map { "\(key)=\($0)" } }.joined(separator: "; ")
    }
}
