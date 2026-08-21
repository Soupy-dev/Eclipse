import Foundation
import CryptoKit
import Network
import Security
import zlib

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

    case nuvioRepository

    case nuvioRequest

    fileprivate var requiresHTTPS: Bool {
        self == .repository || self == .package || self == .icon || self == .nuvioRepository
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
    case configuredOriginViolation
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

extension SkyStreamSecurityError {

    public var isTransientFailure: Bool {
        switch self {
        case .dnsResolutionFailed, .dnsReturnedNoAddresses, .cancelled:
            return true
        default:
            return false
        }
    }
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
        case .configuredOriginViolation: return "The request escaped its configured origin boundary."
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

/// An RFC 6052 IPv4-embedded IPv6 translation prefix. Keeping the extraction
/// rules in a small value type avoids treating arbitrary globally routable
/// IPv6 addresses as IPv4 merely because their final 32 bits look private.
struct SkyStreamNAT64Prefix: Hashable, Sendable {
    static let supportedLengths = [32, 40, 48, 56, 64, 96]

    let prefixBytes: [UInt8]
    let length: Int

    init?(prefixBytes: [UInt8], length: Int) {
        guard Self.supportedLengths.contains(length),
              prefixBytes.count == length / 8 else { return nil }
        // RFC 6052 reserves byte eight as the zero-valued u octet, including
        // when it is part of a network-specific /96 prefix.
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
            guard address[8] == 0 else { return nil }
            let withoutU = Array(address[0..<8]) + Array(address[9..<16])
            let start = length / 8
            guard start + 4 <= withoutU.count else { return nil }
            octets = Array(withoutU[start..<(start + 4)])
        }
        return UInt32(octets[0]) << 24
            | UInt32(octets[1]) << 16
            | UInt32(octets[2]) << 8
            | UInt32(octets[3])
    }
}

/// Opaque authority for a user-configured Stremio addon. It can only be
/// constructed by validating the configured base URL, so callers cannot turn
/// an arbitrary provider result URL into a private-network capability.
struct SkyStreamPinnedOriginAuthority: Sendable, Hashable {
    fileprivate let origin: SkyStreamRemoteOrigin
    fileprivate let baseURL: URL
    fileprivate let canonicalBasePath: String
    let cacheNamespace: String

    private init(
        origin: SkyStreamRemoteOrigin,
        baseURL: URL,
        canonicalBasePath: String
    ) {
        self.origin = origin
        self.baseURL = baseURL
        self.canonicalBasePath = canonicalBasePath
        let identity = "\(origin.scheme)\u{0}\(origin.host)\u{0}\(origin.port)\u{0}\(canonicalBasePath)"
        self.cacheNamespace = SHA256.hash(data: Data(identity.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func stremio(configuredBaseURL rawValue: String) throws -> Self {
        let parsed = try SkyStreamRemoteURLPolicy.configuredHTTPURLParts(
            rawValue,
            relativeTo: nil
        )
        var components = try Self.components(for: parsed.url)
        components.query = nil
        components.fragment = nil

        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/manifest.json") {
            path.removeLast("/manifest.json".count)
        }
        if path.isEmpty { path = "/" }
        components.percentEncodedPath = path == "/" ? "" : path
        guard let baseURL = components.url,
              let canonicalBasePath = canonicalPath(of: baseURL) else {
            throw SkyStreamSecurityError.malformedURL
        }
        return Self(
            origin: parsed.origin,
            baseURL: baseURL,
            canonicalBasePath: canonicalBasePath
        )
    }

    func resolveResourceURL(_ rawValue: String) throws -> URL {
        var directoryComponents = try Self.components(for: baseURL)
        var directoryPath = directoryComponents.percentEncodedPath
        if directoryPath.isEmpty { directoryPath = "/" }
        if !directoryPath.hasSuffix("/") { directoryPath += "/" }
        directoryComponents.percentEncodedPath = directoryPath
        guard let directoryURL = directoryComponents.url else {
            throw SkyStreamSecurityError.malformedURL
        }
        let parsed = try SkyStreamRemoteURLPolicy.configuredHTTPURLParts(
            rawValue,
            relativeTo: directoryURL
        )
        return parsed.url
    }

    func cacheKey(for resourceURL: URL) -> String {
        let value = "\(cacheNamespace)\u{0}\(resourceURL.absoluteString)"
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func contains(_ url: URL) -> Bool {
        guard let parsed = try? SkyStreamRemoteURLPolicy.configuredHTTPURLParts(
            url.absoluteString,
            relativeTo: nil
        ) else {
            return false
        }
        return parsed.origin.isSameOrigin(as: origin)
    }

    fileprivate func matchesOrigin(_ candidate: SkyStreamRemoteOrigin) -> Bool {
        origin.isSameOrigin(as: candidate)
    }

    private static func components(for url: URL) throws -> URLComponents {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw SkyStreamSecurityError.malformedURL
        }
        return components
    }

    private static func canonicalPath(of url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.percentEncodedPath.utf8.count <= 16_384,
              let decoded = components.percentEncodedPath.removingPercentEncoding,
              decoded.isEmpty || decoded.hasPrefix("/"),
              !containsPercentEncodedOctet(decoded),
              !decoded.contains("\\"),
              !decoded.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        var stack: [Substring] = []
        for segment in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            if segment == "." { continue }
            if segment == ".." {
                guard !stack.isEmpty else { return nil }
                stack.removeLast()
            } else {
                stack.append(segment)
            }
        }
        return stack.isEmpty ? "/" : "/" + stack.joined(separator: "/")
    }

    /// A second valid escape sequence after Foundation's first decode is
    /// ambiguous at a server boundary (`%252e%252e`, `%252f`, and similar).
    /// Reject it for the narrow private-origin capability instead of relying on
    /// every configured LAN server to perform exactly one decode pass.
    private static func containsPercentEncodedOctet(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard scalars.count >= 3 else { return false }
        for index in 0..<(scalars.count - 2) where scalars[index].value == 0x25 {
            if isHexDigit(scalars[index + 1]) && isHexDigit(scalars[index + 2]) {
                return true
            }
        }
        return false
    }

    private static func isHexDigit(_ scalar: UnicodeScalar) -> Bool {
        (0x30...0x39).contains(scalar.value)
            || (0x41...0x46).contains(scalar.value)
            || (0x61...0x66).contains(scalar.value)
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
        let usesFreshDispatchPolicy: Bool
        let task: Task<[String], Error>
    }

    private struct NAT64PrefixCacheEntry {
        let prefixes: Set<SkyStreamNAT64Prefix>
        let expiresAt: Date
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
    private let nat64PrefixCondition = NSCondition()
    private let addressResolver: @Sendable (String) throws -> [String]
    private let nat64DiscoveryResolver: @Sendable () throws -> [String]
    private let maximumDNSCacheEntries = 256
    private let nat64PrefixCacheLifetime: TimeInterval = 30
    private var dnsCache: [String: DNSCacheEntry] = [:]
    private var dnsInFlight: [String: DNSInFlightLookup] = [:]
    private var nat64PrefixCache: NAT64PrefixCacheEntry?
    private var nat64DiscoveryInProgress = false
    private var dnsAccessOrdinal: UInt64 = 0
    private var dnsLookupToken: UInt64 = 0

    public init() {
        addressResolver = { host in
            try Self.resolveAddressesSynchronously(host)
        }
        nat64DiscoveryResolver = {
            try Self.resolveAddressesSynchronously(
                "ipv4only.arpa",
                family: AF_INET6
            )
        }
    }

    init(
        addressResolver: @escaping @Sendable (String) throws -> [String],
        nat64DiscoveryResolver: @escaping @Sendable () throws -> [String] = { [] }
    ) {
        self.addressResolver = addressResolver
        self.nat64DiscoveryResolver = nat64DiscoveryResolver
    }

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

    func validateForNetworkDispatch(
        _ rawValue: String,
        purpose: SkyStreamNetworkPurpose,
        stremioAuthority authority: SkyStreamPinnedOriginAuthority,
        relativeTo baseURL: URL? = nil
    ) async throws -> SkyStreamValidatedRemoteURL {
        let parsed = try Self.configuredHTTPURLParts(rawValue, relativeTo: baseURL)
        if purpose.requiresHTTPS, parsed.origin.scheme != "https" {
            throw SkyStreamSecurityError.insecureTransport
        }
        if authority.matchesOrigin(parsed.origin) {
            guard authority.contains(parsed.url) else {
                throw SkyStreamSecurityError.configuredOriginViolation
            }
            let addresses = try await resolveExactConfiguredOriginAddresses(for: parsed.host)
            return SkyStreamValidatedRemoteURL(
                url: parsed.url,
                origin: parsed.origin,
                purpose: purpose,
                checkedAddresses: addresses
            )
        }
        return try await validateForNetworkDispatch(
            parsed.url.absoluteString,
            purpose: purpose
        )
    }

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

    func validateRedirectForNetworkDispatch(
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

    func validateRedirectForNetworkDispatch(
        from sourceURL: URL,
        to destination: URL,
        purpose: SkyStreamNetworkPurpose,
        stremioAuthority authority: SkyStreamPinnedOriginAuthority
    ) async throws -> SkyStreamValidatedRemoteURL {
        let source = try Self.configuredHTTPURLParts(
            sourceURL.absoluteString,
            relativeTo: nil
        )
        let target = try await validateForNetworkDispatch(
            destination.absoluteString,
            purpose: purpose,
            stremioAuthority: authority,
            relativeTo: source.url
        )
        if source.origin.scheme == "https", target.origin.scheme != "https" {
            throw SkyStreamSecurityError.httpsDowngrade
        }
        return target
    }

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

            throw SkyStreamSecurityError.invalidHost
        }

        if let port = components.port, !(1...65_535).contains(port) {
            throw SkyStreamSecurityError.invalidHost
        }

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

    fileprivate static func configuredHTTPURLParts(
        _ rawValue: String,
        relativeTo baseURL: URL?
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
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw SkyStreamSecurityError.unsupportedScheme
        }
        guard components.user == nil, components.password == nil else {
            throw SkyStreamSecurityError.credentialsInURL
        }
        guard let rawHost = components.host, !rawHost.isEmpty else {
            throw SkyStreamSecurityError.invalidHost
        }
        let host = canonicalHost(rawHost)
        guard isSyntacticallyValidHost(host),
              !looksLikeNumericAddress(host) || parsedAddressLiteral(host) != nil else {
            throw SkyStreamSecurityError.invalidHost
        }
        if let port = components.port, !(1...65_535).contains(port) {
            throw SkyStreamSecurityError.invalidHost
        }
        components.scheme = scheme
        components.host = host
        components.fragment = nil
        guard let canonicalURL = components.url else {
            throw SkyStreamSecurityError.malformedURL
        }
        return (
            canonicalURL,
            SkyStreamRemoteOrigin(
                scheme: scheme,
                host: host,
                port: components.port ?? (scheme == "https" ? 443 : 80)
            ),
            host
        )
    }

    private static let legalURICharacters: Set<Character> = {
        var set = Set<Character>("abcdefghijklmnopqrstuvwxyz")
        set.formUnion("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        set.formUnion("0123456789")
        set.formUnion("-._~%")
        set.formUnion(":/?#[]@")
        set.formUnion("!$&'()*+,;=")
        return set
    }()

    public static func deliveryDefect(in rawValue: String) -> String? {
        var illegal: Set<Character> = []
        var hasWhitespace = false
        for character in rawValue {
            guard character.isASCII else { continue }
            if character == " " || character == "\t" || character == "\n" || character == "\r" {
                hasWhitespace = true
                continue
            }
            if !legalURICharacters.contains(character) {
                illegal.insert(character)
            }
        }
        guard hasWhitespace || !illegal.isEmpty else { return nil }
        var tokens: [String] = []
        if hasWhitespace { tokens.append("whitespace") }
        if !illegal.isEmpty {
            tokens.append("illegal:" + illegal.sorted().map(String.init).joined())
        }
        return tokens.joined(separator: "+")
    }

    public static func defectEvidence(of rawValue: String) -> String {
        let withoutQuery = rawValue.split(
            separator: "?",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )[0]
        let shaped = withoutQuery
            .replacingOccurrences(of: " ", with: "\u{2423}")
            .replacingOccurrences(of: "\t", with: "\u{2409}")
            .replacingOccurrences(of: "\n", with: "\u{2424}")
        return String(shaped.prefix(200))
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
        normalizedPublicAddressString(
            value,
            nat64Prefixes: staticallyRecognizedNAT64Prefixes
        )
    }

    static func normalizedNumericAddressString(_ value: String) -> String? {
        guard let parsed = parsedAddressLiteral(canonicalHost(value)) else { return nil }
        let normalized = parsed.description
        return normalized == "invalid-ipv6" ? nil : normalized
    }

    private static func normalizedPublicAddressString(
        _ value: String,
        nat64Prefixes: Set<SkyStreamNAT64Prefix>
    ) -> String? {
        guard let parsed = parsedAddressLiteral(canonicalHost(value)),
              !isProhibitedAddress(parsed, nat64Prefixes: nat64Prefixes) else { return nil }
        return parsed.description
    }

    fileprivate static func isProhibitedAddressString(_ value: String) -> Bool {
        normalizedPublicAddressString(value) == nil
    }

    static func isProhibitedAddressString(
        _ value: String,
        nat64DiscoveryAddresses: [String]
    ) -> Bool {
        normalizedPublicAddressString(
            value,
            nat64Prefixes: staticallyRecognizedNAT64Prefixes.union(
                discoveredNAT64Prefixes(from: nat64DiscoveryAddresses)
            )
        ) == nil
    }

    static func isProhibitedIPv6Bytes(
        _ bytes: [UInt8],
        nat64DiscoveryAddresses: [[UInt8]]
    ) -> Bool {
        isProhibitedAddress(
            .ipv6(bytes),
            nat64Prefixes: staticallyRecognizedNAT64Prefixes.union(
                discoveredNAT64Prefixes(fromIPv6Bytes: nat64DiscoveryAddresses)
            )
        )
    }

    static func ipv6PresentationString(for bytes: [UInt8]) -> String? {
        guard bytes.count == 16 else { return nil }
        let value = ParsedAddress.ipv6(bytes).description
        return value == "invalid-ipv6" ? nil : value
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

    private func resolveExactConfiguredOriginAddresses(for host: String) async throws -> [String] {
        try Task.checkCancellation()
        let resolverQueue = resolverQueue
        let addressResolver = addressResolver
        return try await withCheckedThrowingContinuation { continuation in
            resolverQueue.async {
                do {
                    let rawAddresses = try addressResolver(host)
                    guard !rawAddresses.isEmpty else {
                        throw SkyStreamSecurityError.dnsReturnedNoAddresses
                    }
                    var normalized: [String] = []
                    var seen = Set<String>()
                    for rawAddress in rawAddresses {
                        guard let address = Self.normalizedNumericAddressString(rawAddress) else {
                            throw SkyStreamSecurityError.dnsResolutionFailed
                        }
                        if seen.insert(address).inserted { normalized.append(address) }
                    }
                    guard !normalized.isEmpty else {
                        throw SkyStreamSecurityError.dnsReturnedNoAddresses
                    }
                    continuation.resume(returning: normalized.sorted())
                } catch {
                    continuation.resume(throwing: error)
                }
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

        if let existing = dnsInFlight[host],
           permitsCachedResult || existing.usesFreshDispatchPolicy {
            return .lookup(existing)
        }
        dnsLookupToken &+= 1
        let lookup = DNSInFlightLookup(
            token: dnsLookupToken,
            usesFreshDispatchPolicy: !permitsCachedResult,
            task: makeDNSLookupTask(
                for: host,
                requiresFreshNAT64Discovery: !permitsCachedResult
            )
        )
        dnsInFlight[host] = lookup
        return .lookup(lookup)
    }

    private func makeDNSLookupTask(
        for host: String,
        requiresFreshNAT64Discovery: Bool
    ) -> Task<[String], Error> {
        let resolverQueue = resolverQueue
        let addressResolver = addressResolver
        let policy = self
        return Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                resolverQueue.async {
                    do {
                        let addresses = try addressResolver(host)
                        guard !addresses.isEmpty else {
                            throw SkyStreamSecurityError.dnsReturnedNoAddresses
                        }
                        let nat64Prefixes = policy.activeNAT64Prefixes(
                            forceRefresh: requiresFreshNAT64Discovery
                        )
                        var normalized: [String] = []
                        normalized.reserveCapacity(addresses.count)
                        for address in addresses {
                            guard let publicAddress = Self.normalizedPublicAddressString(
                                address,
                                nat64Prefixes: nat64Prefixes
                            ) else {
                                throw SkyStreamSecurityError.prohibitedAddress("redacted")
                            }
                            normalized.append(publicAddress)
                        }
                        continuation.resume(returning: Array(Set(normalized)).sorted())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func activeNAT64Prefixes(
        forceRefresh: Bool
    ) -> Set<SkyStreamNAT64Prefix> {
        let now = Date()
        nat64PrefixCondition.lock()
        if !forceRefresh,
           let cached = nat64PrefixCache,
           cached.expiresAt > now {
            nat64PrefixCondition.unlock()
            return cached.prefixes
        }
        if nat64DiscoveryInProgress {
            repeat {
                nat64PrefixCondition.wait()
            } while nat64DiscoveryInProgress
            if let cached = nat64PrefixCache {
                nat64PrefixCondition.unlock()
                return cached.prefixes
            }
        }
        nat64DiscoveryInProgress = true
        nat64PrefixCondition.unlock()

        let discoveryAddresses = (try? nat64DiscoveryResolver()) ?? []
        let prefixes = Self.staticallyRecognizedNAT64Prefixes.union(
            Self.discoveredNAT64Prefixes(from: discoveryAddresses)
        )

        nat64PrefixCondition.lock()
        nat64PrefixCache = NAT64PrefixCacheEntry(
            prefixes: prefixes,
            expiresAt: now.addingTimeInterval(nat64PrefixCacheLifetime)
        )
        nat64DiscoveryInProgress = false
        nat64PrefixCondition.broadcast()
        nat64PrefixCondition.unlock()
        return prefixes
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

    private static func resolveAddressesSynchronously(
        _ host: String,
        family: Int32 = AF_UNSPEC
    ) throws -> [String] {
        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG
        hints.ai_family = family
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
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_.")
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
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        return labels.allSatisfy(isIntegerAddressComponent)
    }

    private static func isIntegerAddressComponent(_ label: Substring) -> Bool {
        guard !label.isEmpty else { return false }
        let lowered = label.lowercased()
        if lowered.hasPrefix("0x") {
            let digits = lowered.dropFirst(2)
            return !digits.isEmpty && digits.allSatisfy(\.isHexDigit)
        }
        return lowered.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func parsedAddressLiteral(_ host: String) -> ParsedAddress? {
        if let ipv4 = parseLegacyIPv4(host) { return .ipv4(ipv4) }

        var ipv6 = in6_addr()
        let parsed = host.withCString { inet_pton(AF_INET6, $0, &ipv6) }
        guard parsed == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
        return .ipv6(bytes)
    }

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
        isProhibitedAddress(
            address,
            nat64Prefixes: staticallyRecognizedNAT64Prefixes
        )
    }

    private static func isProhibitedAddress(
        _ address: ParsedAddress,
        nat64Prefixes: Set<SkyStreamNAT64Prefix>
    ) -> Bool {
        switch address {
        case .ipv4(let value):
            return isProhibitedIPv4(value)
        case .ipv6(let bytes):
            guard bytes.count == 16 else { return true }
            if bytes.allSatisfy({ $0 == 0 }) { return true }
            if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return true }
            if bytes[0] & 0xfe == 0xfc { return true }
            if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return true }
            if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0xc0 { return true }
            if bytes[0] == 0xff { return true }
            if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8 {
                return true
            }
            if bytes[0] == 0x01 && bytes.dropFirst().prefix(7).allSatisfy({ $0 == 0 }) {
                return true
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

            for prefix in nat64Prefixes where prefix.matches(bytes) {
                // An address routed inside an active Pref64 must use the exact
                // RFC 6052 placement (including its zero u octet). Malformed
                // encodings fail closed instead of falling back to native IPv6.
                guard let value = prefix.embeddedIPv4(in: bytes) else { return true }
                if isProhibitedIPv4(value) { return true }
            }

            if bytes[0] == 0x20 && bytes[1] == 0x02 {
                let value = bytes[2...5].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                return isProhibitedIPv4(value)
            }
            if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x00 && bytes[3] == 0x00 {
                return true
            }
            if bytes[0] == 0x20 && bytes[1] == 0x01
                && (bytes[2] & 0xf0 == 0x10 || bytes[2] & 0xf0 == 0x20) {
                return true
            }
            if bytes[0...5] == [0x20, 0x01, 0x00, 0x02, 0x00, 0x00] {
                return true
            }
            if bytes[0] == 0x3f && bytes[1] & 0xf0 == 0xf0 {
                return true
            }
            return false
        }
    }

    static func discoveredNAT64Prefixes(
        from addresses: [String]
    ) -> Set<SkyStreamNAT64Prefix> {
        discoveredNAT64Prefixes(fromIPv6Bytes: addresses.compactMap { rawAddress in
            guard case .ipv6(let bytes) = parsedAddressLiteral(canonicalHost(rawAddress)) else {
                return nil
            }
            return bytes
        })
    }

    static func discoveredNAT64Prefixes(
        fromIPv6Bytes addresses: [[UInt8]]
    ) -> Set<SkyStreamNAT64Prefix> {
        let discoveryIPv4Values: Set<UInt32> = [0xc000_00aa, 0xc000_00ab]
        var discovered = Set<SkyStreamNAT64Prefix>()
        for bytes in addresses where bytes.count == 16 {
            var candidates: [SkyStreamNAT64Prefix] = []
            for length in SkyStreamNAT64Prefix.supportedLengths {
                guard let prefix = SkyStreamNAT64Prefix(address: bytes, length: length),
                      let embedded = prefix.embeddedIPv4(in: bytes),
                      discoveryIPv4Values.contains(embedded) else { continue }
                candidates.append(prefix)
            }
            // RFC 7050 discovery is accepted only when a WKA answer has one
            // unambiguous RFC 6052 interpretation.
            if candidates.count == 1 { discovered.insert(candidates[0]) }
        }
        return discovered
    }

    private static let staticallyRecognizedNAT64Prefixes: Set<SkyStreamNAT64Prefix> = [
        // RFC 6052 Well-Known Prefix.
        SkyStreamNAT64Prefix(
            prefixBytes: [0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0],
            length: 96
        )!,
        // RFC 8215 local-use translation prefix, with RFC 6052 /48 placement.
        SkyStreamNAT64Prefix(
            prefixBytes: [0x00, 0x64, 0xff, 0x9b, 0x00, 0x01],
            length: 48
        )!
    ]

    private static func isProhibitedIPv4(_ value: UInt32) -> Bool {
        func inRange(_ network: UInt32, _ prefix: UInt32) -> Bool {
            let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
            return value & mask == network & mask
        }

        return inRange(0x0000_0000, 8)
            || inRange(0x0a00_0000, 8)
            || inRange(0x6440_0000, 10)
            || inRange(0x7f00_0000, 8)
            || inRange(0xa9fe_0000, 16)
            || inRange(0xac10_0000, 12)
            || inRange(0xc000_0000, 24)
            || inRange(0xc000_0200, 24)
            || inRange(0xc058_6300, 24)
            || inRange(0xc0a8_0000, 16)
            || inRange(0xc612_0000, 15)
            || inRange(0xc633_6400, 24)
            || inRange(0xcb00_7100, 24)
            || inRange(0xe000_0000, 4)
            || inRange(0xf000_0000, 4)
    }
}

/// A small HTTP/1.1 client whose TCP/TLS connection is made to one of the
/// numeric addresses approved by `SkyStreamRemoteURLPolicy`. The original
/// hostname is retained for the Host header, TLS SNI, and trust evaluation.
/// This closes the gap between a safe DNS answer and URLSession's later,
/// independent DNS lookup.
enum SkyStreamPinnedNetworkConstraint: Sendable, Hashable {
    case any
    case wifi
}

struct SkyStreamPinnedConnectionIdentity: Sendable, Equatable {
    let numericAddress: String
    let tlsServerName: String
}

enum SkyStreamPinnedTransportSemantics {
    static func connectionIdentity(
        target: SkyStreamValidatedRemoteURL,
        rawAddress: String
    ) -> SkyStreamPinnedConnectionIdentity? {
        guard let address = SkyStreamRemoteURLPolicy.normalizedNumericAddressString(rawAddress),
              target.checkedAddresses.contains(where: {
                  SkyStreamRemoteURLPolicy.normalizedNumericAddressString($0) == address
              }),
              let hostname = target.url.host else { return nil }
        return SkyStreamPinnedConnectionIdentity(
            numericAddress: address,
            tlsServerName: hostname
        )
    }

    static func mergeCookieHeaders(_ explicit: String?, _ jar: String?) -> String? {
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
        let value = pairs.keys.sorted().compactMap { key in
            pairs[key].map { "\(key)=\($0)" }
        }.joined(separator: "; ")
        return value.isEmpty ? nil : value
    }

    static func effectiveHeaders(
        base: SkyStreamSanitizedHeaders,
        jarCookie: String?,
        byteRange: ClosedRange<Int64>?,
        allowsCookies: Bool,
        method: String
    ) throws -> SkyStreamSanitizedHeaders {
        var values = base.values
        if allowsCookies {
            values["cookie"] = mergeCookieHeaders(values["cookie"], jarCookie)
        } else {
            values.removeValue(forKey: "cookie")
        }
        let sanitized = try SkyStreamHeaderSanitizer.sanitize(
            values,
            purpose: .pluginRequest
        )
        var effective = sanitized.values
        if let byteRange {
            guard method.uppercased() == "GET", byteRange.lowerBound >= 0,
                  byteRange.upperBound >= byteRange.lowerBound,
                  byteRange.upperBound - byteRange.lowerBound < 1_000_000 else {
                throw SkyStreamSecurityError.invalidByteRange
            }
            effective["range"] = "bytes=\(byteRange.lowerBound)-\(byteRange.upperBound)"
        }
        return SkyStreamSanitizedHeaders(values: effective)
    }
}

final class SkyStreamPinnedHTTPClient: @unchecked Sendable {
    struct Response: @unchecked Sendable {
        let data: Data
        let response: HTTPURLResponse
        let wasTruncated: Bool
        let effectiveRequestHeaders: SkyStreamSanitizedHeaders
    }

    private let policy: SkyStreamRemoteURLPolicy
    private let cookieJar = SkyStreamPinnedCookieJar()
    private let systemTransport = SkyStreamSystemHTTPTransport()
    private let networkConstraint: SkyStreamPinnedNetworkConstraint
    private let stremioAuthority: SkyStreamPinnedOriginAuthority?

    init(
        policy: SkyStreamRemoteURLPolicy = .shared,
        networkConstraint: SkyStreamPinnedNetworkConstraint = .any
    ) {
        self.policy = policy
        self.networkConstraint = networkConstraint
        self.stremioAuthority = nil
    }

    init(
        stremioAuthority: SkyStreamPinnedOriginAuthority,
        policy: SkyStreamRemoteURLPolicy = .shared,
        networkConstraint: SkyStreamPinnedNetworkConstraint = .any
    ) {
        self.policy = policy
        self.networkConstraint = networkConstraint
        self.stremioAuthority = stremioAuthority
    }

    func fetch(
        _ rawURL: String,
        purpose: SkyStreamNetworkPurpose,
        method rawMethod: String = "GET",
        headers: SkyStreamSanitizedHeaders = .empty,
        body: Data? = nil,
        byteRange: ClosedRange<Int64>? = nil,
        allowsCookies: Bool = true,
        followsRedirects: Bool = true,
        maximumRedirects: Int = 10,
        maximumResponseBytes: Int,
        maximumRequestBodyBytes: Int = 2 * 1024 * 1024,
        permitsTruncatedResponsePrefix: Bool = false,
        timeout: TimeInterval = 30
    ) async throws -> Response {
        let method = rawMethod.uppercased()
        guard ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"].contains(method) else {
            throw SkyStreamSecurityError.invalidMethod
        }
        guard body?.count ?? 0 <= max(0, maximumRequestBodyBytes) else {
            throw SkyStreamSecurityError.requestBodyTooLarge
        }
        guard maximumResponseBytes > 0 else {
            throw SkyStreamSecurityError.responseTooLarge
        }
        if let byteRange {
            guard method == "GET", byteRange.lowerBound >= 0,
                  byteRange.upperBound >= byteRange.lowerBound,
                  byteRange.upperBound - byteRange.lowerBound < 1_000_000 else {
                throw SkyStreamSecurityError.invalidByteRange
            }
        }

        let target: SkyStreamValidatedRemoteURL
        if let stremioAuthority {
            target = try await policy.validateForNetworkDispatch(
                rawURL,
                purpose: purpose,
                stremioAuthority: stremioAuthority
            )
        } else {
            target = try await policy.validateForNetworkDispatch(rawURL, purpose: purpose)
        }
        return try await performValidated(
            target,
            method: method,
            headers: headers,
            body: body,
            byteRange: byteRange,
            allowsCookies: allowsCookies,
            followsRedirects: followsRedirects,
            maximumRedirects: maximumRedirects,
            maximumResponseBytes: maximumResponseBytes,
            permitsTruncatedResponsePrefix: permitsTruncatedResponsePrefix,
            timeout: timeout
        )
    }

    func fetchValidated(
        _ target: SkyStreamValidatedRemoteURL,
        method rawMethod: String = "GET",
        headers: SkyStreamSanitizedHeaders = .empty,
        body: Data? = nil,
        byteRange: ClosedRange<Int64>? = nil,
        allowsCookies: Bool = true,
        followsRedirects: Bool = true,
        maximumRedirects: Int = 10,
        maximumResponseBytes: Int,
        maximumRequestBodyBytes: Int = 2 * 1024 * 1024,
        permitsTruncatedResponsePrefix: Bool = false,
        timeout: TimeInterval = 30
    ) async throws -> Response {
        let method = rawMethod.uppercased()
        guard ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"].contains(method) else {
            throw SkyStreamSecurityError.invalidMethod
        }
        guard body?.count ?? 0 <= max(0, maximumRequestBodyBytes) else {
            throw SkyStreamSecurityError.requestBodyTooLarge
        }
        guard maximumResponseBytes > 0 else {
            throw SkyStreamSecurityError.responseTooLarge
        }
        if let byteRange {
            guard method == "GET", byteRange.lowerBound >= 0,
                  byteRange.upperBound >= byteRange.lowerBound,
                  byteRange.upperBound - byteRange.lowerBound < 1_000_000 else {
                throw SkyStreamSecurityError.invalidByteRange
            }
        }
        let exactConfiguredTarget = stremioAuthority?.contains(target.url) == true
        let addressesAreAuthorized = target.checkedAddresses.allSatisfy { address in
            if exactConfiguredTarget {
                return SkyStreamRemoteURLPolicy.normalizedNumericAddressString(address) != nil
            }
            return SkyStreamRemoteURLPolicy.normalizedPublicAddressString(address) != nil
        }
        guard !target.checkedAddresses.isEmpty, addressesAreAuthorized else {
            throw SkyStreamSecurityError.dnsReturnedNoAddresses
        }
        return try await performValidated(
            target,
            method: method,
            headers: headers,
            body: body,
            byteRange: byteRange,
            allowsCookies: allowsCookies,
            followsRedirects: followsRedirects,
            maximumRedirects: maximumRedirects,
            maximumResponseBytes: maximumResponseBytes,
            permitsTruncatedResponsePrefix: permitsTruncatedResponsePrefix,
            timeout: timeout
        )
    }

    private func performValidated(
        _ initialTarget: SkyStreamValidatedRemoteURL,
        method: String,
        headers: SkyStreamSanitizedHeaders,
        body: Data?,
        byteRange: ClosedRange<Int64>?,
        allowsCookies: Bool,
        followsRedirects: Bool,
        maximumRedirects: Int,
        maximumResponseBytes: Int,
        permitsTruncatedResponsePrefix: Bool,
        timeout: TimeInterval
    ) async throws -> Response {
        var target = initialTarget
        var requestMethod = method
        var requestBody = body
        var requestHeaders = headers
        var redirectCount = 0
        var cookiesRemainAuthorized = allowsCookies

        while true {
            try Task.checkCancellation()
            let effectiveHeaders = try SkyStreamPinnedTransportSemantics.effectiveHeaders(
                base: requestHeaders,
                jarCookie: cookiesRemainAuthorized ? cookieJar.cookieHeader(for: target.url) : nil,
                byteRange: byteRange,
                allowsCookies: cookiesRemainAuthorized,
                method: requestMethod
            )
            let attempt: SkyStreamSystemHTTPTransport.Result
            switch networkConstraint {
            case .any:
                attempt = try await systemTransport.perform(
                    target: target,
                    method: requestMethod,
                    headers: effectiveHeaders,
                    body: requestBody,
                    maximumResponseBytes: maximumResponseBytes,
                    timeout: timeout
                )
            case .wifi:
                let pinned = try await SkyStreamPinnedHTTPRequestOperation.perform(
                    target: target,
                    method: requestMethod,
                    headers: effectiveHeaders,
                    body: requestBody,
                    maximumResponseBytes: maximumResponseBytes,
                    timeout: timeout,
                    networkConstraint: networkConstraint
                )
                attempt = SkyStreamSystemHTTPTransport.Result(
                    data: pinned.data,
                    response: pinned.response,
                    redirectURL: pinned.redirectURL,
                    setCookieValues: pinned.setCookieValues,
                    wasTruncated: pinned.wasTruncated
                )
            }
            if cookiesRemainAuthorized {
                cookieJar.store(setCookieValues: attempt.setCookieValues, responseURL: target.url)
            }

            guard followsRedirects,
                  Self.redirectStatusCodes.contains(attempt.response.statusCode),
                  let destination = attempt.redirectURL else {
                if attempt.wasTruncated && !permitsTruncatedResponsePrefix {
                    throw SkyStreamSecurityError.responseTooLarge
                }
                return Response(
                    data: attempt.data,
                    response: attempt.response,
                    wasTruncated: attempt.wasTruncated,
                    effectiveRequestHeaders: effectiveHeaders
                )
            }
            guard redirectCount < max(0, min(maximumRedirects, 20)) else {
                throw SkyStreamSecurityError.tooManyRedirects
            }
            redirectCount += 1

            let source = target
            if let stremioAuthority {
                target = try await policy.validateRedirectForNetworkDispatch(
                    from: source.url,
                    to: destination,
                    purpose: initialTarget.purpose,
                    stremioAuthority: stremioAuthority
                )
                if !source.origin.isSameOrigin(as: target.origin) {
                    cookiesRemainAuthorized = false
                }
            } else {
                target = try await policy.validateRedirectForNetworkDispatch(
                    from: source.url,
                    to: destination,
                    purpose: initialTarget.purpose
                )
            }
            requestHeaders = requestHeaders.scopedForRedirect(
                from: source.origin,
                to: target.origin
            )
            if Self.redirectChangesToGET(status: attempt.response.statusCode, method: requestMethod) {
                requestMethod = "GET"
                requestBody = nil
            }
        }
    }

    func removeAllCookies() {
        cookieJar.removeAll()
    }

    func invalidate() {
        cookieJar.removeAll()
        systemTransport.invalidate()
    }

    func cookieHeader(for url: URL) -> String? {
        cookieJar.cookieHeader(for: url)
    }

    private static let redirectStatusCodes: Set<Int> = [301, 302, 303, 307, 308]

    static func redirectChangesToGET(status: Int, method: String) -> Bool {
        if status == 303 { return method.uppercased() != "HEAD" }
        return (status == 301 || status == 302) && method.uppercased() == "POST"
    }
}

final class SkyStreamPinnedCookieJar: @unchecked Sendable {
    private struct Key: Hashable {
        let name: String
        let boundHost: String
        let path: String
    }

    private struct StoredCookie {
        let cookie: HTTPCookie
        let boundHost: String
    }

    private let lock = NSLock()
    private var cookies: [Key: StoredCookie] = [:]
    private let maximumCount = 128
    private let maximumBytes = 32 * 1024

    func cookieHeader(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path.isEmpty ? "/" : url.path
        let isHTTPS = url.scheme?.lowercased() == "https"
        let now = Date()
        lock.lock()
        cookies = cookies.filter { $0.value.cookie.expiresDate.map { $0 > now } ?? true }
        let matches = cookies.values.filter { stored in
            let cookie = stored.cookie
            return stored.boundHost == host
                && Self.path(cookie.path, matches: path)
                && (!cookie.isSecure || isHTTPS)
        }.sorted { lhs, rhs in
            if lhs.cookie.path.count == rhs.cookie.path.count {
                return lhs.cookie.name < rhs.cookie.name
            }
            return lhs.cookie.path.count > rhs.cookie.path.count
        }
        lock.unlock()
        let value = matches.map { "\($0.cookie.name)=\($0.cookie.value)" }.joined(separator: "; ")
        return value.isEmpty ? nil : value
    }

    func store(setCookieValues: [String], responseURL: URL) {
        guard let responseHost = responseURL.host?.lowercased(), !setCookieValues.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for rawValue in setCookieValues.prefix(32) {
            let parsed = HTTPCookie.cookies(
                withResponseHeaderFields: ["Set-Cookie": rawValue],
                for: responseURL
            )
            for cookie in parsed.prefix(32) {
                let domain = Self.canonicalDomain(cookie.domain)
                guard responseHost == domain || responseHost.hasSuffix("." + domain),
                      domain.split(separator: ".").count >= 2,
                      !cookie.isSecure || responseURL.scheme?.lowercased() == "https" else {
                    continue
                }
                if cookie.name.hasPrefix("__Host-") {
                    guard cookie.isSecure, cookie.path == "/", domain == responseHost else { continue }
                }
                if cookie.name.hasPrefix("__Secure-"), !cookie.isSecure { continue }
                let key = Key(name: cookie.name, boundHost: responseHost, path: cookie.path)
                if cookie.value.isEmpty || cookie.expiresDate.map({ $0 <= Date() }) == true {
                    cookies.removeValue(forKey: key)
                } else {
                    cookies[key] = StoredCookie(cookie: cookie, boundHost: responseHost)
                }
            }
        }
        enforceQuota()
    }

    func removeAll() {
        lock.lock()
        cookies.removeAll()
        lock.unlock()
    }

    private func enforceQuota() {
        if cookies.count > maximumCount {
            for key in cookies.keys.sorted(by: {
                (cookies[$0]?.cookie.expiresDate ?? .distantFuture)
                    < (cookies[$1]?.cookie.expiresDate ?? .distantFuture)
            }).prefix(cookies.count - maximumCount) {
                cookies.removeValue(forKey: key)
            }
        }
        var byteCount = cookies.values.reduce(0) {
            let cookie = $1.cookie
            return $0 + cookie.name.utf8.count + cookie.value.utf8.count
                + $1.boundHost.utf8.count + cookie.path.utf8.count
        }
        if byteCount > maximumBytes {
            for key in cookies.keys.sorted(by: { $0.name < $1.name }) {
                guard byteCount > maximumBytes, let removed = cookies.removeValue(forKey: key) else { break }
                let cookie = removed.cookie
                byteCount -= cookie.name.utf8.count + cookie.value.utf8.count
                    + removed.boundHost.utf8.count + cookie.path.utf8.count
            }
        }
    }

    private static func canonicalDomain(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }

    private static func path(_ cookiePath: String, matches requestPath: String) -> Bool {
        let cookiePath = cookiePath.isEmpty ? "/" : cookiePath
        guard requestPath.hasPrefix(cookiePath) else { return false }
        return cookiePath.hasSuffix("/") || requestPath.count == cookiePath.count
            || requestPath.dropFirst(cookiePath.count).first == "/"
    }
}

private final class SkyStreamSystemHTTPTransport: @unchecked Sendable {
    struct Result {
        let data: Data
        let response: HTTPURLResponse
        let redirectURL: URL?
        let setCookieValues: [String]
        let wasTruncated: Bool
    }

    private let lock = NSLock()
    private let delegate: FetchDelegate
    private let session: URLSession
    private var invalidated = false

    init() {
        let delegate = FetchDelegate(allowRedirects: false)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = 120
        self.delegate = delegate
        self.session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    func perform(
        target: SkyStreamValidatedRemoteURL,
        method: String,
        headers: SkyStreamSanitizedHeaders,
        body: Data?,
        maximumResponseBytes: Int,
        timeout: TimeInterval
    ) async throws -> Result {
        guard canStartRequest() else { throw SkyStreamSecurityError.cancelled }

        var request = URLRequest(url: target.url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = max(1, min(timeout, 120))
        for (name, value) in headers.values {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await delegate.boundedData(
                in: session,
                for: request,
                maximumResponseBytes: maximumResponseBytes,
                allowRedirects: false,
                returnsRedirectResponseImmediately: true
            )
        } catch is BoundedURLSessionError {
            throw SkyStreamSecurityError.responseTooLarge
        } catch is CancellationError {
            throw SkyStreamSecurityError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw SkyStreamSecurityError.cancelled
        }

        guard let http = response as? HTTPURLResponse else {
            throw SkyStreamSecurityError.invalidResponse
        }
        let redirectURL = http.value(forHTTPHeaderField: "Location").flatMap {
            URL(string: $0, relativeTo: target.url)?.absoluteURL
        }
        let setCookieValues = http.allHeaderFields.compactMap { key, value -> [String]? in
            guard String(describing: key).caseInsensitiveCompare("Set-Cookie") == .orderedSame else {
                return nil
            }
            if let values = value as? [String] { return values }
            return [String(describing: value)]
        }.flatMap { $0 }
        return Result(
            data: data,
            response: http,
            redirectURL: redirectURL,
            setCookieValues: setCookieValues,
            wasTruncated: false
        )
    }

    func invalidate() {
        lock.lock()
        guard !invalidated else {
            lock.unlock()
            return
        }
        invalidated = true
        lock.unlock()
        session.invalidateAndCancel()
    }

    private func canStartRequest() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !invalidated
    }
}

private final class SkyStreamPinnedHTTPRequestOperation: @unchecked Sendable {
    struct Result {
        let data: Data
        let response: HTTPURLResponse
        let redirectURL: URL?
        let setCookieValues: [String]
        let wasTruncated: Bool
    }

    private enum BodyFraming {
        case none
        case contentLength(Int64)
        case chunked
        case untilClose
    }

    private final class BodyInflater {
        private enum Coding { case gzip, deflate }

        private let coding: Coding
        private var stream = z_stream()
        private var isActive = false
        private var didEnd = false
        private var sniffedDeflateBytes = Data()
        private var inputBytes = 0
        private var outputBytes = 0

        init?(contentCoding: String) {
            switch contentCoding {
            case "gzip", "x-gzip": coding = .gzip
            case "deflate": coding = .deflate
            default: return nil
            }
        }

        deinit {
            if isActive { inflateEnd(&stream) }
        }

        func feed(_ data: Data) -> Data? {
            guard !didEnd else { return data.isEmpty ? Data() : nil }
            guard recordInput(data.count) else { return nil }
            var input = data
            if !isActive {
                if coding == .deflate {
                    sniffedDeflateBytes.append(input)
                    guard sniffedDeflateBytes.count >= 2 else { return Data() }
                    input = sniffedDeflateBytes
                    sniffedDeflateBytes.removeAll(keepingCapacity: false)
                }
                guard begin(firstBytes: input) else { return nil }
            }
            guard !input.isEmpty else { return Data() }
            var output = Data()
            let succeeded = input.withUnsafeBytes { raw -> Bool in
                guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return false }
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: base)
                stream.avail_in = uInt(input.count)
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                while stream.avail_in > 0, !didEnd {
                    var status = Z_OK
                    chunk.withUnsafeMutableBufferPointer { buffer in
                        stream.next_out = buffer.baseAddress
                        stream.avail_out = uInt(buffer.count)
                        status = inflate(&stream, Z_NO_FLUSH)
                        let count = buffer.count - Int(stream.avail_out)
                        if let start = buffer.baseAddress, count > 0 {
                            guard output.count <= 8 * 1024 * 1024 - count,
                                  recordOutput(count) else {
                                status = Z_MEM_ERROR
                                return
                            }
                            output.append(start, count: count)
                        }
                    }
                    if status == Z_STREAM_END {
                        guard stream.avail_in == 0 else { return false }
                        didEnd = true
                        break
                    }
                    if status == Z_BUF_ERROR, stream.avail_in == 0 { break }
                    guard status == Z_OK else { return false }
                }
                return true
            }
            return succeeded ? output : nil
        }

        func finish() -> Data? {
            guard isActive else { return sniffedDeflateBytes.isEmpty ? Data() : nil }
            guard !didEnd else { return Data() }
            var output = Data()
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while !didEnd {
                var status = Z_OK
                chunk.withUnsafeMutableBufferPointer { buffer in
                    stream.next_in = nil
                    stream.avail_in = 0
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(buffer.count)
                    status = inflate(&stream, Z_FINISH)
                    let count = buffer.count - Int(stream.avail_out)
                    if let start = buffer.baseAddress, count > 0 {
                        guard output.count <= 8 * 1024 * 1024 - count,
                              recordOutput(count) else {
                            status = Z_MEM_ERROR
                            return
                        }
                        output.append(start, count: count)
                    }
                }
                if status == Z_STREAM_END {
                    didEnd = true
                    break
                }
                guard status == Z_OK else { return nil }
            }
            return output
        }

        private func begin(firstBytes: Data) -> Bool {
            let windowBits: Int32
            switch coding {
            case .gzip:
                windowBits = 15 + 16
            case .deflate:
                let bytes = [UInt8](firstBytes.prefix(2))
                let zlibWrapped = bytes.count == 2
                    && (Int(bytes[0]) & 0x0f) == 8
                    && ((Int(bytes[0]) << 8) | Int(bytes[1])) % 31 == 0
                windowBits = zlibWrapped ? 15 : -15
            }
            guard inflateInit2_(
                &stream,
                windowBits,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            ) == Z_OK else { return false }
            isActive = true
            return true
        }

        private func recordInput(_ count: Int) -> Bool {
            let (next, overflow) = inputBytes.addingReportingOverflow(count)
            guard !overflow else { return false }
            inputBytes = next
            return true
        }

        private func recordOutput(_ count: Int) -> Bool {
            let (next, outputOverflow) = outputBytes.addingReportingOverflow(count)
            let (scaled, ratioOverflow) = inputBytes.multipliedReportingOverflow(by: 256)
            let (limit, allowanceOverflow) = scaled.addingReportingOverflow(1 * 1024 * 1024)
            guard !outputOverflow, !ratioOverflow, !allowanceOverflow, next <= limit else { return false }
            outputBytes = next
            return true
        }
    }

    private struct ParsedHead {
        let response: HTTPURLResponse
        let framing: BodyFraming
        let redirectURL: URL?
        let setCookieValues: [String]
        let contentCoding: String?
    }

    private static let headerTerminator = Data([13, 10, 13, 10])
    private static let lineTerminator = Data([13, 10])
    private static let maximumResponseHeaderBytes = 128 * 1024
    private static let maximumChunkMetadataBytes = 64 * 1024

    private let target: SkyStreamValidatedRemoteURL
    private let method: String
    private let headers: SkyStreamSanitizedHeaders
    private let body: Data?
    private let maximumResponseBytes: Int
    private let timeout: TimeInterval
    private let networkConstraint: SkyStreamPinnedNetworkConstraint
    private let queue = DispatchQueue(
        label: "app.eclipse.skystream.pinned-request.\(UUID().uuidString)",
        qos: .userInitiated
    )

    private var continuation: CheckedContinuation<Result, Error>?
    private var connection: NWConnection?
    private var nextAddressIndex = 0
    private var receivedAnyBytes = false
    private var requestDispatchBegan = false
    private var receiveBuffer = Data()
    private var response: HTTPURLResponse?
    private var redirectURL: URL?
    private var setCookieValues: [String] = []
    private var bodyFraming: BodyFraming = .untilClose
    private var chunkBytesRemaining: Int?
    private var awaitingChunkTerminator = false
    private var readingChunkTrailers = false
    private var output = Data()
    private var bodyInflater: BodyInflater?
    private var wasTruncated = false
    private var finished = false

    private init(
        target: SkyStreamValidatedRemoteURL,
        method: String,
        headers: SkyStreamSanitizedHeaders,
        body: Data?,
        maximumResponseBytes: Int,
        timeout: TimeInterval,
        networkConstraint: SkyStreamPinnedNetworkConstraint
    ) {
        self.target = target
        self.method = method
        self.headers = headers
        self.body = body
        self.maximumResponseBytes = maximumResponseBytes
        self.timeout = max(1, min(timeout, 120))
        self.networkConstraint = networkConstraint
    }

    static func perform(
        target: SkyStreamValidatedRemoteURL,
        method: String,
        headers: SkyStreamSanitizedHeaders,
        body: Data?,
        maximumResponseBytes: Int,
        timeout: TimeInterval,
        networkConstraint: SkyStreamPinnedNetworkConstraint = .any
    ) async throws -> Result {
        let operation = SkyStreamPinnedHTTPRequestOperation(
            target: target,
            method: method,
            headers: headers,
            body: body,
            maximumResponseBytes: maximumResponseBytes,
            timeout: timeout,
            networkConstraint: networkConstraint
        )
        return try await withTaskCancellationHandler {
            try await operation.start()
        } onCancel: {
            operation.cancel()
        }
    }

    private func start() async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.finished else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                self.queue.asyncAfter(deadline: .now() + self.timeout) {
                    guard !self.finished else { return }
                    self.fail(URLError(.timedOut))
                }
                self.startNextAddress()
            }
        }
    }

    private func cancel() {
        queue.async {
            guard !self.finished else { return }
            self.fail(CancellationError())
        }
    }

    private func startNextAddress() {
        guard !finished, nextAddressIndex < target.checkedAddresses.count,
              let scheme = target.url.scheme?.lowercased(),
              let hostname = target.url.host,
              let port = Self.port(for: target.url, scheme: scheme) else {
            fail(URLError(.cannotConnectToHost))
            return
        }
        let rawAddress = target.checkedAddresses[nextAddressIndex]
        nextAddressIndex += 1
        guard let identity = SkyStreamPinnedTransportSemantics.connectionIdentity(
                  target: target,
                  rawAddress: rawAddress
              ),
              let endpointHost = Self.numericEndpointHost(identity.numericAddress) else {
            startNextAddress()
            return
        }

        let parameters: NWParameters
        if scheme == "https" {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(
                tls.securityProtocolOptions,
                identity.tlsServerName
            )
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
            let trustQueue = queue
            sec_protocol_options_set_verify_block(
                tls.securityProtocolOptions,
                { _, trust, complete in
                    let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                    let policy = SecPolicyCreateSSL(true, hostname as CFString)
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
        if networkConstraint == .wifi {
            // "Wi-Fi only" means "not on cellular". Requiring the .wifi interface additionally
            // excludes Ethernet and VPN paths, so the download stalls in .waiting on an iPad on
            // a USB-C adapter rather than proceeding over a perfectly non-cellular link.
            parameters.prohibitedInterfaceTypes = [.cellular]
        }

        let connection = NWConnection(host: endpointHost, port: port, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.connection === connection, !self.finished else { return }
            switch state {
            case .ready:
                self.sendRequest(on: connection)
            case .failed(let error):
                self.handleConnectionFailure(error)
            case .waiting:
                guard !self.requestDispatchBegan, !self.receivedAnyBytes,
                      self.nextAddressIndex < self.target.checkedAddresses.count else { break }
                self.queue.asyncAfter(deadline: .now() + 3) { [weak self, weak connection] in
                    guard let self, let connection, self.connection === connection,
                          !self.finished, !self.requestDispatchBegan, !self.receivedAnyBytes,
                          self.nextAddressIndex < self.target.checkedAddresses.count else { return }
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    self.connection = nil
                    self.startNextAddress()
                }
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func handleConnectionFailure(_ error: NWError) {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        if !requestDispatchBegan, !receivedAnyBytes,
           nextAddressIndex < target.checkedAddresses.count {
            startNextAddress()
        } else {
            fail(error)
        }
    }

    private func sendRequest(on connection: NWConnection) {
        guard let requestBytes = serializedRequest() else {
            fail(URLError(.badURL))
            return
        }
        requestDispatchBegan = true
        connection.send(content: requestBytes, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, self.connection === connection, !self.finished else { return }
            if let error {
                self.handleConnectionFailure(error)
            } else {
                self.receiveNext(on: connection)
            }
        })
    }

    private func receiveNext(on connection: NWConnection) {
        guard self.connection === connection, !finished else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self, weak connection] content, _, isComplete, error in
            guard let self, let connection, self.connection === connection, !self.finished else { return }
            if let content, !content.isEmpty {
                self.receivedAnyBytes = true
                self.receiveBuffer.append(content)
                guard self.consumeAvailableBytes() else { return }
            }
            if let error {
                self.handleConnectionFailure(error)
            } else if isComplete {
                self.handleEndOfStream()
            } else {
                self.receiveNext(on: connection)
            }
        }
    }

    private func consumeAvailableBytes() -> Bool {
        if response == nil {
            while true {
                guard let headerRange = receiveBuffer.range(of: Self.headerTerminator) else {
                    if receiveBuffer.count > Self.maximumResponseHeaderBytes {
                        fail(URLError(.badServerResponse))
                        return false
                    }
                    return true
                }
                let headerData = Data(receiveBuffer[..<headerRange.lowerBound])
                receiveBuffer.removeSubrange(..<headerRange.upperBound)
                guard let parsed = parseResponseHead(headerData) else {
                    fail(URLError(.badServerResponse))
                    return false
                }
                if (100...199).contains(parsed.response.statusCode) { continue }
                response = parsed.response
                redirectURL = parsed.redirectURL
                setCookieValues = parsed.setCookieValues
                bodyFraming = parsed.framing
                if parsed.redirectURL != nil {
                    bodyFraming = .none
                    succeed()
                    return false
                }
                if let coding = parsed.contentCoding {
                    guard let inflater = BodyInflater(contentCoding: coding) else {
                        fail(URLError(.cannotDecodeContentData))
                        return false
                    }
                    bodyInflater = inflater
                }
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
                return appendBody(bytes)
            }
            return true
        case .contentLength(let initialRemaining):
            var remaining = initialRemaining
            guard remaining >= 0 else {
                fail(URLError(.badServerResponse))
                return false
            }
            if remaining == 0 {
                guard receiveBuffer.isEmpty else {
                    fail(URLError(.badServerResponse))
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
            guard appendBody(bytes) else { return false }
            if remaining == 0 {
                guard receiveBuffer.isEmpty else {
                    fail(URLError(.badServerResponse))
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
                    receiveBuffer.removeFirst(2)
                    succeed()
                    return false
                }
                guard let trailerEnd = receiveBuffer.range(of: Self.headerTerminator) else {
                    if receiveBuffer.count > Self.maximumChunkMetadataBytes {
                        fail(URLError(.badServerResponse))
                        return false
                    }
                    return true
                }
                receiveBuffer.removeSubrange(..<trailerEnd.upperBound)
                succeed()
                return false
            }
            if awaitingChunkTerminator {
                guard receiveBuffer.count >= 2 else { return true }
                guard receiveBuffer.prefix(2).elementsEqual(Self.lineTerminator) else {
                    fail(URLError(.badServerResponse))
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
                if count == remaining {
                    chunkBytesRemaining = nil
                    awaitingChunkTerminator = true
                } else {
                    chunkBytesRemaining = remaining - count
                }
                guard appendBody(bytes) else { return false }
                continue
            }
            guard let lineEnd = receiveBuffer.range(of: Self.lineTerminator) else {
                if receiveBuffer.count > Self.maximumChunkMetadataBytes {
                    fail(URLError(.badServerResponse))
                    return false
                }
                return true
            }
            guard let line = String(data: receiveBuffer[..<lineEnd.lowerBound], encoding: .ascii) else {
                fail(URLError(.badServerResponse))
                return false
            }
            receiveBuffer.removeSubrange(..<lineEnd.upperBound)
            let sizeText = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sizeText.isEmpty, let size = UInt64(sizeText, radix: 16), size <= UInt64(Int.max) else {
                fail(URLError(.badServerResponse))
                return false
            }
            if size == 0 { readingChunkTrailers = true }
            else { chunkBytesRemaining = Int(size) }
        }
        return false
    }

    private func appendBody(_ bytes: Data) -> Bool {
        guard !bytes.isEmpty else { return true }
        if let bodyInflater {
            guard let inflated = bodyInflater.feed(bytes) else {
                fail(URLError(.cannotDecodeContentData))
                return false
            }
            guard appendDecodedBody(inflated) else {
                succeed()
                return false
            }
            return true
        }
        guard appendDecodedBody(bytes) else {
            succeed()
            return false
        }
        return true
    }

    private func appendDecodedBody(_ bytes: Data) -> Bool {
        guard !bytes.isEmpty else { return true }
        let remaining = maximumResponseBytes - output.count
        if bytes.count <= remaining {
            output.append(bytes)
            return true
        }
        if remaining > 0 { output.append(bytes.prefix(remaining)) }
        wasTruncated = true
        return false
    }

    private func handleEndOfStream() {
        guard response != nil else {
            fail(URLError(.badServerResponse))
            return
        }
        switch bodyFraming {
        case .untilClose, .none:
            succeed()
        case .contentLength(let remaining):
            remaining == 0 ? succeed() : fail(URLError(.networkConnectionLost))
        case .chunked:
            fail(URLError(.networkConnectionLost))
        }
    }

    private func parseResponseHead(_ data: Data) -> ParsedHead? {
        guard let text = String(data: data, encoding: .isoLatin1) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return nil }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/1."),
              let statusCode = Int(statusParts[1]), (100...599).contains(statusCode) else { return nil }

        var values: [String: [String]] = [:]
        var originalNames: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty, line.first != " ", line.first != "\t",
                  let separator = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isValidHeaderName(name),
                  value.unicodeScalars.allSatisfy({ $0.value == 9 || ($0.value >= 32 && $0.value != 127) }) else {
                return nil
            }
            let lower = name.lowercased()
            originalNames[lower] = originalNames[lower] ?? name
            values[lower, default: []].append(value)
        }
        let transferCodings = (values["transfer-encoding"] ?? [])
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let rawLengths = (values["content-length"] ?? [])
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard transferCodings.isEmpty || transferCodings == ["chunked"] else { return nil }
        if !transferCodings.isEmpty, !rawLengths.isEmpty { return nil }

        var responseHeaders: [String: String] = [:]
        let contentCodings = (values["content-encoding"] ?? [])
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0 != "identity" }
        guard contentCodings.count <= 1,
              contentCodings.isEmpty
                || ["gzip", "x-gzip", "deflate"].contains(contentCodings[0]) else {
            return nil
        }
        let contentCoding = contentCodings.first
        for (lower, headerValues) in values
            where lower != "set-cookie"
                && (contentCoding == nil || (lower != "content-encoding" && lower != "content-length")) {
            guard let name = originalNames[lower] else { continue }
            responseHeaders[name] = headerValues.joined(separator: ", ")
        }
        if let firstCookie = values["set-cookie"]?.first {
            responseHeaders["Set-Cookie"] = firstCookie
        }
        guard let response = HTTPURLResponse(
            url: target.url,
            statusCode: statusCode,
            httpVersion: String(statusParts[0]),
            headerFields: responseHeaders
        ) else { return nil }

        let framing: BodyFraming
        if method == "HEAD" || (100...199).contains(statusCode) || statusCode == 204 || statusCode == 304 {
            framing = .none
        } else if transferCodings == ["chunked"] {
            framing = .chunked
        } else if !rawLengths.isEmpty {
            guard let first = rawLengths.first, rawLengths.allSatisfy({ $0 == first }),
                  let length = Int64(first), length >= 0 else { return nil }
            framing = .contentLength(length)
        } else {
            framing = .untilClose
        }
        let redirectURL: URL? = [301, 302, 303, 307, 308].contains(statusCode)
            ? values["location"]?.first.flatMap {
                URL(string: $0, relativeTo: target.url)?.absoluteURL
            }
            : nil
        return ParsedHead(
            response: response,
            framing: framing,
            redirectURL: redirectURL,
            setCookieValues: Array((values["set-cookie"] ?? []).prefix(32)),
            contentCoding: contentCoding
        )
    }

    private func serializedRequest() -> Data? {
        guard let scheme = target.url.scheme?.lowercased(),
              let host = target.url.host,
              let components = URLComponents(url: target.url, resolvingAgainstBaseURL: false) else { return nil }
        var requestTarget = components.percentEncodedPath
        if requestTarget.isEmpty { requestTarget = "/" }
        if let query = components.percentEncodedQuery { requestTarget += "?\(query)" }
        guard !requestTarget.contains("\r"), !requestTarget.contains("\n") else { return nil }

        let bracketedHost = host.contains(":") ? "[\(host)]" : host
        let defaultPort = scheme == "https" ? 443 : 80
        let authority = target.url.port.map { $0 == defaultPort ? bracketedHost : "\(bracketedHost):\($0)" }
            ?? bracketedHost
        var requestHeaders = headers.values
        requestHeaders["accept-encoding"] = "identity"
        requestHeaders["connection"] = "close"
        if let body { requestHeaders["content-length"] = String(body.count) }
        else { requestHeaders.removeValue(forKey: "content-length") }

        var lines = ["\(method) \(requestTarget) HTTP/1.1", "Host: \(authority)"]
        for name in requestHeaders.keys.sorted() {
            guard let value = requestHeaders[name], Self.isValidHeaderName(name),
                  !value.contains("\r"), !value.contains("\n") else { return nil }
            lines.append("\(name): \(value)")
        }
        lines.append("")
        lines.append("")
        var result = Data(lines.joined(separator: "\r\n").utf8)
        if let body { result.append(body) }
        return result
    }

    private func succeed() {
        guard !finished, let response else {
            if !finished { fail(URLError(.badServerResponse)) }
            return
        }
        if !wasTruncated, let bodyInflater {
            guard let finalBytes = bodyInflater.finish() else {
                fail(URLError(.cannotDecodeContentData))
                return
            }
            _ = appendDecodedBody(finalBytes)
        }
        bodyInflater = nil
        finished = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: Result(
            data: output,
            response: response,
            redirectURL: redirectURL,
            setCookieValues: setCookieValues,
            wasTruncated: wasTruncated
        ))
    }

    private func fail(_ error: Error) {
        guard !finished else { return }
        finished = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(throwing: error)
    }

    private static func numericEndpointHost(_ address: String) -> NWEndpoint.Host? {
        guard IPv4Address(address) != nil || IPv6Address(address) != nil else { return nil }
        return NWEndpoint.Host(address)
    }

    private static func port(for url: URL, scheme: String) -> NWEndpoint.Port? {
        let value = url.port ?? (scheme == "https" ? 443 : 80)
        guard (1...Int(UInt16.max)).contains(value) else { return nil }
        return NWEndpoint.Port(rawValue: UInt16(value))
    }

    private static func isValidHeaderName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        let allowed = CharacterSet(
            charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        )
        return value.unicodeScalars.allSatisfy { $0.value < 128 && allowed.contains($0) }
    }
}

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
            if let existing = result[normalizedName] {
                guard existing == value else { throw SkyStreamSecurityError.duplicateHeader }
                continue
            }
            guard !forbiddenNames.contains(normalizedName), !normalizedName.hasPrefix("proxy-") else {
                throw SkyStreamSecurityError.forbiddenHeader
            }

            if normalizedName == "referer" || normalizedName == "origin" {
                guard (try? SkyStreamRemoteURLPolicy.shared.validateSyntactic(
                    value,
                    purpose: .pluginRequest
                )) != nil else {
                    continue
                }
            }

            totalBytes += normalizedName.utf8.count + value.utf8.count + 4
            guard totalBytes <= maximumTotalBytes else { throw SkyStreamSecurityError.headersTooLarge }
            result[normalizedName] = value
        }
        return SkyStreamSanitizedHeaders(values: result)
    }
}

public struct SkyStreamHTTPRequest: Sendable {
    public let url: SkyStreamValidatedRemoteURL
    public let method: String
    public let headers: SkyStreamSanitizedHeaders
    public let body: Data?

    public let byteRange: ClosedRange<Int64>?

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

        guard ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"].contains(method) else {
            throw SkyStreamSecurityError.invalidMethod
        }
        if let range = request.byteRange {
            guard method == "GET", range.lowerBound >= 0, range.upperBound >= range.lowerBound,
                  range.upperBound - range.lowerBound < 1_000_000 else {
                throw SkyStreamSecurityError.invalidByteRange
            }
        }

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

private final class SkyStreamPackageHTTPSession: @unchecked Sendable {
    private final class StartGate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if isOpen {
                    lock.unlock()
                    continuation.resume()
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }

        func open() {
            lock.lock()
            isOpen = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        }
    }

    private let pinnedClient: SkyStreamPinnedHTTPClient
    private let stateLock = NSLock()
    private var pendingTokens = Set<UUID>()
    private var tasksByToken: [UUID: Task<SkyStreamHTTPResponse, Error>] = [:]
    private var cancelledTokens = Set<UUID>()
    private var invalidated = false
    private let maximumConcurrentRequests = 8

    init(packageID: String, policy: SkyStreamRemoteURLPolicy) {
        _ = packageID
        pinnedClient = SkyStreamPinnedHTTPClient(policy: policy)
    }

    func perform(
        _ request: SkyStreamHTTPRequest,
        limits: SkyStreamHTTPRequestLimits
    ) async throws -> SkyStreamHTTPResponse {
        let token = UUID()
        stateLock.lock()
        guard !invalidated else {
            stateLock.unlock()
            throw SkyStreamSecurityError.cancelled
        }
        guard pendingTokens.count + tasksByToken.count < maximumConcurrentRequests else {
            stateLock.unlock()
            throw SkyStreamSecurityError.tooManyConcurrentRequests
        }
        pendingTokens.insert(token)
        stateLock.unlock()

        return try await withTaskCancellationHandler {
            let startGate = StartGate()
            let task = Task<SkyStreamHTTPResponse, Error> { [pinnedClient] in
                await startGate.wait()
                try Task.checkCancellation()
                let result = try await pinnedClient.fetchValidated(
                    request.url,
                    method: request.method,
                    headers: request.headers,
                    body: request.body,
                    byteRange: request.byteRange,
                    allowsCookies: request.allowsCookies,
                    followsRedirects: true,
                    maximumRedirects: limits.maximumRedirects,
                    maximumResponseBytes: limits.maximumResponseBytes,
                    maximumRequestBodyBytes: limits.maximumRequestBodyBytes,
                    timeout: limits.timeout
                )
                guard !result.wasTruncated else {
                    throw SkyStreamSecurityError.responseTooLarge
                }
                return SkyStreamHTTPResponse(
                    data: result.data,
                    response: result.response,
                    effectiveRequestHeaders: result.effectiveRequestHeaders
                )
            }

            stateLock.lock()
            pendingTokens.remove(token)
            let wasCancelled = cancelledTokens.remove(token) != nil
            guard !invalidated, !wasCancelled else {
                stateLock.unlock()
                task.cancel()
                startGate.open()
                throw SkyStreamSecurityError.cancelled
            }
            tasksByToken[token] = task
            stateLock.unlock()
            startGate.open()

            do {
                let response = try await task.value
                guard finish(token: token) else {
                    throw SkyStreamSecurityError.cancelled
                }
                return response
            } catch {
                let wasCurrent = finish(token: token)
                guard wasCurrent else { throw SkyStreamSecurityError.cancelled }
                if error is CancellationError
                    || (error as? URLError)?.code == .cancelled {
                    throw SkyStreamSecurityError.cancelled
                }
                throw error
            }
        } onCancel: {
            self.cancel(token: token)
        }
    }

    func invalidate() {
        stateLock.lock()
        guard !invalidated else {
            stateLock.unlock()
            return
        }
        invalidated = true
        let tasks = Array(tasksByToken.values)
        pendingTokens.removeAll(keepingCapacity: false)
        tasksByToken.removeAll(keepingCapacity: false)
        cancelledTokens.removeAll(keepingCapacity: false)
        stateLock.unlock()

        tasks.forEach { $0.cancel() }
        pinnedClient.invalidate()
    }

    func cookieHeader(for url: URL) -> String? {
        pinnedClient.cookieHeader(for: url)
    }

    private func cancel(token: UUID) {
        stateLock.lock()
        let task = tasksByToken[token]
        if task != nil || pendingTokens.contains(token) {
            cancelledTokens.insert(token)
        }
        stateLock.unlock()
        task?.cancel()
    }

    private func finish(token: UUID) -> Bool {
        stateLock.lock()
        let existed = tasksByToken.removeValue(forKey: token) != nil
        let wasCancelled = cancelledTokens.remove(token) != nil
        let mayReturn = existed && !wasCancelled && !invalidated
        stateLock.unlock()
        return mayReturn
    }
}
