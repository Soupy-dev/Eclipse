import Foundation
import CryptoKit

public struct SkyStreamVODValidationIdentity: Sendable, Hashable {
    public let packageID: String
    public let providerID: String
    public let payloadSHA256: String
    public let generation: UInt64
    public let authorityRevision: UUID

    public init(
        packageID: String,
        providerID: String,
        payloadSHA256: String,
        generation: UInt64,
        authorityRevision: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    ) {
        self.packageID = packageID
        self.providerID = providerID
        self.payloadSHA256 = payloadSHA256.lowercased()
        self.generation = generation
        self.authorityRevision = authorityRevision
    }
}

public struct SkyStreamRawSubtitleCandidate: Sendable, Hashable {
    public var url: String
    public var label: String?
    public var language: String?
    public var headers: [String: String]

    public init(
        url: String,
        label: String? = nil,
        language: String? = nil,
        headers: [String: String] = [:]
    ) {
        self.url = url
        self.label = label
        self.language = language
        self.headers = headers
    }
}

public struct SkyStreamRawStreamCandidate: Sendable, Hashable {
    public var url: String
    public var headers: [String: String]
    public var referer: String?
    public var mediaType: String?
    public var subtitles: [SkyStreamRawSubtitleCandidate]
    public var isLive: Bool
    public var infoHash: String?
    public var torrentURL: String?
    public var drmKeyID: String?
    public var drmKey: String?
    public var licenseURL: String?
    public var externalPlayerPolicy: String?
    public var policyHints: [String: String]

    public init(
        url: String,
        headers: [String: String] = [:],
        referer: String? = nil,
        mediaType: String? = nil,
        subtitles: [SkyStreamRawSubtitleCandidate] = [],
        isLive: Bool = false,
        infoHash: String? = nil,
        torrentURL: String? = nil,
        drmKeyID: String? = nil,
        drmKey: String? = nil,
        licenseURL: String? = nil,
        externalPlayerPolicy: String? = nil,
        policyHints: [String: String] = [:]
    ) {
        self.url = url
        self.headers = headers
        self.referer = referer
        self.mediaType = mediaType
        self.subtitles = subtitles
        self.isLive = isLive
        self.infoHash = infoHash
        self.torrentURL = torrentURL
        self.drmKeyID = drmKeyID
        self.drmKey = drmKey
        self.licenseURL = licenseURL
        self.externalPlayerPolicy = externalPlayerPolicy
        self.policyHints = policyHints
    }
}

public enum SkyStreamValidatedMediaKind: String, Sendable, Hashable {
    case direct
    case hls
    case dash
}

public enum SkyStreamValidatedRouteRole: String, Sendable, Hashable {
    case streamRoot
    case manifest
    case mediaSegment
    case encryptionKey
    case initialization
    case subtitle
    case dashResource
}

public struct SkyStreamValidatedProxyOptions: Sendable, Hashable {
    public enum MagicVersion: String, Sendable, Hashable {
        case legacy
        case v1
        case v2
        case generatedM3U8
    }

    public let magicVersion: MagicVersion
    public let mirrorHosts: [String]
    public let retainedCookieNames: [String]
    public let referer: SkyStreamValidatedRemoteURL?

    fileprivate init(
        magicVersion: MagicVersion,
        mirrorHosts: [String],
        retainedCookieNames: [String],
        referer: SkyStreamValidatedRemoteURL?
    ) {
        self.magicVersion = magicVersion
        self.mirrorHosts = mirrorHosts
        self.retainedCookieNames = retainedCookieNames
        self.referer = referer
    }
}

public struct SkyStreamValidatedRoute: Sendable, Hashable {
    public let remoteURL: SkyStreamValidatedRemoteURL
    public let role: SkyStreamValidatedRouteRole
    public let headers: SkyStreamSanitizedHeaders
    public let proxyOptions: SkyStreamValidatedProxyOptions?

    fileprivate init(
        remoteURL: SkyStreamValidatedRemoteURL,
        role: SkyStreamValidatedRouteRole,
        headers: SkyStreamSanitizedHeaders,
        proxyOptions: SkyStreamValidatedProxyOptions? = nil
    ) {
        self.remoteURL = remoteURL
        self.role = role
        self.headers = headers
        self.proxyOptions = proxyOptions
    }
}

public struct SkyStreamAcceptedManifest: Sendable, Hashable {
    public let sourceURL: SkyStreamValidatedRemoteURL?
    public let bytes: Data
    public let mediaKind: SkyStreamValidatedMediaKind

    fileprivate init(
        sourceURL: SkyStreamValidatedRemoteURL?,
        bytes: Data,
        mediaKind: SkyStreamValidatedMediaKind
    ) {
        self.sourceURL = sourceURL
        self.bytes = bytes
        self.mediaKind = mediaKind
    }
}

public struct SkyStreamValidatedSubtitle: Sendable, Hashable {
    public let remoteURL: SkyStreamValidatedRemoteURL
    public let label: String?
    public let language: String?
    public let headers: SkyStreamSanitizedHeaders

    fileprivate init(
        remoteURL: SkyStreamValidatedRemoteURL,
        label: String?,
        language: String?,
        headers: SkyStreamSanitizedHeaders
    ) {
        self.remoteURL = remoteURL
        self.label = label
        self.language = language
        self.headers = headers
    }
}

public struct SkyStreamValidatedPlaybackDescriptor: Sendable, Hashable {
    public let identity: SkyStreamVODValidationIdentity
    public let mediaKind: SkyStreamValidatedMediaKind
    public let underlyingRemoteURL: SkyStreamValidatedRemoteURL
    public let headers: SkyStreamSanitizedHeaders
    public let acceptedManifests: [SkyStreamAcceptedManifest]
    public let routes: [SkyStreamValidatedRoute]
    public let proxyOptions: SkyStreamValidatedProxyOptions?
    public let subtitles: [SkyStreamValidatedSubtitle]
    public let finiteContentLength: Int64?

    public var requiresHeaderProxy: Bool {
        proxyOptions != nil || !headers.values.isEmpty || !acceptedManifests.isEmpty
    }

    fileprivate init(
        identity: SkyStreamVODValidationIdentity,
        mediaKind: SkyStreamValidatedMediaKind,
        underlyingRemoteURL: SkyStreamValidatedRemoteURL,
        headers: SkyStreamSanitizedHeaders,
        acceptedManifests: [SkyStreamAcceptedManifest],
        routes: [SkyStreamValidatedRoute],
        proxyOptions: SkyStreamValidatedProxyOptions?,
        subtitles: [SkyStreamValidatedSubtitle],
        finiteContentLength: Int64?
    ) {
        self.identity = identity
        self.mediaKind = mediaKind
        self.underlyingRemoteURL = underlyingRemoteURL
        self.headers = headers
        self.acceptedManifests = acceptedManifests
        self.routes = routes
        self.proxyOptions = proxyOptions
        self.subtitles = subtitles
        self.finiteContentLength = finiteContentLength
    }
}

public struct SkyStreamVODValidationLimits: Sendable, Hashable {
    public var maximumManifestBytes: Int
    public var maximumManifestDepth: Int
    public var maximumVariants: Int
    public var maximumManifests: Int
    public var maximumRoutes: Int
    public var maximumSubtitles: Int
    public var maximumConcurrentChildChecks: Int

    public init(
        maximumManifestBytes: Int = 2_000_000,
        maximumManifestDepth: Int = 3,
        maximumVariants: Int = 12,
        maximumManifests: Int = 24,
        maximumRoutes: Int = 4_096,
        maximumSubtitles: Int = 16,
        maximumConcurrentChildChecks: Int = 4
    ) {
        self.maximumManifestBytes = max(32_768, min(maximumManifestBytes, 5_000_000))
        self.maximumManifestDepth = max(1, min(maximumManifestDepth, 5))
        self.maximumVariants = max(1, min(maximumVariants, 24))
        self.maximumManifests = max(1, min(maximumManifests, 48))
        self.maximumRoutes = max(32, min(maximumRoutes, 10_000))
        self.maximumSubtitles = max(0, min(maximumSubtitles, 32))
        self.maximumConcurrentChildChecks = max(1, min(maximumConcurrentChildChecks, 6))
    }

    public static let `default` = SkyStreamVODValidationLimits()
}

public enum SkyStreamVODValidationError: Error, Sendable, Equatable {
    case emptyCandidate
    case prohibitedTransport
    case liveContent
    case torrentContent
    case drmContent
    case externalPlayerPolicy
    case malformedMagicDescriptor
    case oversizedMagicDescriptor
    case invalidMagicDescriptor
    case malformedManifest
    case oversizedManifest
    case manifestDepthExceeded
    case tooManyVariants
    case tooManyManifests
    case tooManyRoutes
    case liveHLS
    case lowLatencyHLS
    case drmHLS
    case nonStaticDASH
    case unsafeXML
    case unsupportedDASHTemplate
    case indeterminateDuration
    case nonFiniteMedia
    case unsupportedMediaType
    case invalidSubtitle
    case security(String)
    case network(String)
    case cachedRejection(String)
}

extension SkyStreamVODValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyCandidate: return "The plugin returned an empty stream."
        case .prohibitedTransport: return "Only remote HTTP(S) VOD streams are allowed."
        case .liveContent: return "Live streams are not supported."
        case .torrentContent: return "Torrent-derived streams are not supported."
        case .drmContent: return "DRM-protected streams are not supported."
        case .externalPlayerPolicy: return "Plugin external-player policies are not supported."
        case .malformedMagicDescriptor: return "The MAGIC_PROXY descriptor is malformed."
        case .oversizedMagicDescriptor: return "The MAGIC_PROXY descriptor exceeds the limit."
        case .invalidMagicDescriptor: return "The MAGIC_PROXY descriptor is invalid."
        case .malformedManifest: return "The media manifest is malformed."
        case .oversizedManifest: return "The media manifest exceeds the limit."
        case .manifestDepthExceeded: return "The media manifest nesting limit was exceeded."
        case .tooManyVariants: return "The media manifest has too many variants."
        case .tooManyManifests: return "The media manifest graph is too large."
        case .tooManyRoutes: return "The media manifest has too many resources."
        case .liveHLS: return "The HLS playlist is live or lacks finite VOD markers."
        case .lowLatencyHLS: return "Low-latency HLS is not supported."
        case .drmHLS: return "The HLS playlist uses DRM or SAMPLE-AES."
        case .nonStaticDASH: return "Only static DASH manifests are supported."
        case .unsafeXML: return "The DASH manifest contains unsafe XML features."
        case .unsupportedDASHTemplate: return "The DASH manifest uses a non-enumerable segment template."
        case .indeterminateDuration: return "The media duration could not be proven finite."
        case .nonFiniteMedia: return "The direct media response is not finite and seekable."
        case .unsupportedMediaType: return "The response is not a supported media type."
        case .invalidSubtitle: return "A subtitle URL or header is invalid."
        case .security(let reason), .network(let reason), .cachedRejection(let reason): return reason
        }
    }
}

public struct SkyStreamRawProxyOptions: Sendable, Hashable {
    public var version: SkyStreamValidatedProxyOptions.MagicVersion
    public var mirrorHosts: [String]
    public var retainedCookieNames: [String]
    public var referer: String?

    fileprivate init(
        version: SkyStreamValidatedProxyOptions.MagicVersion,
        mirrorHosts: [String] = [],
        retainedCookieNames: [String] = [],
        referer: String? = nil
    ) {
        self.version = version
        self.mirrorHosts = mirrorHosts
        self.retainedCookieNames = retainedCookieNames
        self.referer = referer
    }
}

public enum SkyStreamDecodedStreamPayload: Sendable, Hashable {
    case remote(url: String, headers: [String: String], proxyOptions: SkyStreamRawProxyOptions?)
    case generatedHLS(bytes: Data, headers: [String: String], proxyOptions: SkyStreamRawProxyOptions)
}

public enum SkyStreamMagicProxyDecoder {
    private static let maximumEncodedBytes = 512_000
    private static let maximumDecodedBytes = 2_000_000

    public static func decode(
        _ rawValue: String,
        fallbackHeaders: [String: String] = [:]
    ) throws -> SkyStreamDecodedStreamPayload {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SkyStreamVODValidationError.emptyCandidate }
        guard trimmed.utf8.count <= maximumEncodedBytes else {
            throw SkyStreamVODValidationError.oversizedMagicDescriptor
        }

        if trimmed.hasPrefix("magic_m3u8:") {
            let encoded = String(trimmed.dropFirst("magic_m3u8:".count))
            let data = try decodeBase64(encoded, maximumBytes: maximumDecodedBytes)
            guard String(data: data, encoding: .utf8) != nil else {
                throw SkyStreamVODValidationError.malformedMagicDescriptor
            }
            return .generatedHLS(
                bytes: data,
                headers: fallbackHeaders,
                proxyOptions: SkyStreamRawProxyOptions(version: .generatedM3U8)
            )
        }

        let legacyPrefix: String?
        let version: SkyStreamValidatedProxyOptions.MagicVersion?
        if trimmed.hasPrefix("MAGIC_PROXY_v1") {
            legacyPrefix = "MAGIC_PROXY_v1"
            version = .v1
        } else if trimmed.hasPrefix("MAGIC_PROXY:") {
            legacyPrefix = "MAGIC_PROXY:"
            version = .legacy
        } else {
            legacyPrefix = nil
            version = nil
        }
        if let legacyPrefix, let version {
            let encoded = String(trimmed.dropFirst(legacyPrefix.count))
            let data = try decodeBase64(encoded, maximumBytes: 32_768)
            guard let url = String(data: data, encoding: .utf8), !url.isEmpty else {
                throw SkyStreamVODValidationError.malformedMagicDescriptor
            }
            return .remote(
                url: url,
                headers: fallbackHeaders,
                proxyOptions: SkyStreamRawProxyOptions(version: version)
            )
        }

        if trimmed.hasPrefix("MAGIC_PROXY_v2") {
            let encoded = String(trimmed.dropFirst("MAGIC_PROXY_v2".count))
            let data = try decodeBase64(encoded, maximumBytes: 256_000)
            try validateJSONShape(data)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let url = object["url"] as? String, !url.isEmpty else {
                throw SkyStreamVODValidationError.invalidMagicDescriptor
            }
            let configuredHeaders = try stringDictionary(object["headers"])
            let headers = configuredHeaders ?? fallbackHeaders
            var mirrorHosts: [String] = []
            var retainedCookieNames: [String] = []
            var referer: String?
            if let options = object["options"] {
                guard let options = options as? [String: Any] else {
                    throw SkyStreamVODValidationError.invalidMagicDescriptor
                }
                mirrorHosts = try stringArray(options["mirrorHosts"], maximumCount: 16)
                retainedCookieNames = try stringArray(options["keepCookies"], maximumCount: 32)
                if let value = options["referer"] {
                    guard let value = value as? String else {
                        throw SkyStreamVODValidationError.invalidMagicDescriptor
                    }
                    referer = value
                }
            }
            return .remote(
                url: url,
                headers: headers,
                proxyOptions: SkyStreamRawProxyOptions(
                    version: .v2,
                    mirrorHosts: mirrorHosts,
                    retainedCookieNames: retainedCookieNames,
                    referer: referer
                )
            )
        }

        return .remote(url: trimmed, headers: fallbackHeaders, proxyOptions: nil)
    }

    private static func validateJSONShape(_ data: Data) throws {

        guard String(data: data, encoding: .utf8) != nil else {
            throw SkyStreamVODValidationError.invalidMagicDescriptor
        }
        do {
            try SkyStreamJSONEnvelopeValidator.validate(
                data,
                limits: .init(
                    maximumDepth: 16,
                    maximumTokens: 8_192,
                    maximumValuesPerContainer: 512,
                    maximumStringBytes: 16 * 1_024,
                    maximumScalarTokenBytes: 128
                )
            )
        } catch {
            throw SkyStreamVODValidationError.invalidMagicDescriptor
        }
    }

    private static func decodeBase64(_ value: String, maximumBytes: Int) throws -> Data {
        guard !value.isEmpty, value.utf8.count <= maximumEncodedBytes,
              !value.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) else {
            throw SkyStreamVODValidationError.malformedMagicDescriptor
        }
        var normalized = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 { normalized += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: normalized), data.count <= maximumBytes else {
            throw SkyStreamVODValidationError.malformedMagicDescriptor
        }
        return data
    }

    private static func stringDictionary(_ value: Any?) throws -> [String: String]? {
        guard let value else { return nil }
        guard let dictionary = value as? [String: Any], dictionary.count <= 64 else {
            throw SkyStreamVODValidationError.invalidMagicDescriptor
        }
        var result: [String: String] = [:]
        for (key, value) in dictionary {
            guard let value = value as? String else {
                throw SkyStreamVODValidationError.invalidMagicDescriptor
            }
            result[key] = value
        }
        return result
    }

    private static func stringArray(_ value: Any?, maximumCount: Int) throws -> [String] {
        guard let value else { return [] }
        guard let array = value as? [Any], array.count <= maximumCount else {
            throw SkyStreamVODValidationError.invalidMagicDescriptor
        }
        return try array.map {
            guard let string = $0 as? String, string.utf8.count <= 512 else {
                throw SkyStreamVODValidationError.invalidMagicDescriptor
            }
            return string
        }
    }
}

private enum SkyStreamVODCachedValue: Sendable {
    case accepted(SkyStreamValidatedPlaybackDescriptor)
    case rejected(String)
}

private actor SkyStreamVODValidationCache {
    private struct Entry: Sendable {
        let value: SkyStreamVODCachedValue
        let expiresAt: Date
        let cost: Int
        let insertedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let maximumEntries = 256
    private let maximumCost = 20_000_000

    func value(for key: String) -> SkyStreamVODCachedValue? {
        guard let entry = entries[key] else { return nil }
        guard entry.expiresAt > Date() else {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.value
    }

    func storeAccepted(_ descriptor: SkyStreamValidatedPlaybackDescriptor, for key: String) {
        let cost = descriptor.acceptedManifests.reduce(0) { $0 + $1.bytes.count }
        entries[key] = Entry(
            value: .accepted(descriptor),
            expiresAt: Date().addingTimeInterval(5 * 60),
            cost: cost,
            insertedAt: Date()
        )
        trim()
    }

    func storeRejected(_ reason: String, for key: String) {
        entries[key] = Entry(
            value: .rejected(String(reason.prefix(500))),
            expiresAt: Date().addingTimeInterval(20),
            cost: 0,
            insertedAt: Date()
        )
        trim()
    }

    private func trim() {
        entries = entries.filter { $0.value.expiresAt > Date() }
        var cost = entries.values.reduce(0) { $0 + $1.cost }
        guard entries.count > maximumEntries || cost > maximumCost else { return }
        for pair in entries.sorted(by: { $0.value.insertedAt < $1.value.insertedAt }) {
            guard entries.count > maximumEntries || cost > maximumCost else { break }
            cost -= entries.removeValue(forKey: pair.key)?.cost ?? 0
        }
    }
}

public final class SkyStreamVODValidator: @unchecked Sendable {
    public static let shared = SkyStreamVODValidator()

    private let policy: SkyStreamRemoteURLPolicy
    private let client: SkyStreamHTTPClient
    private let cache = SkyStreamVODValidationCache()

    public init(
        policy: SkyStreamRemoteURLPolicy = .shared,
        client: SkyStreamHTTPClient = .shared
    ) {
        self.policy = policy
        self.client = client
    }

    public func validate(
        _ candidate: SkyStreamRawStreamCandidate,
        identity: SkyStreamVODValidationIdentity,
        limits: SkyStreamVODValidationLimits = .default,
        bypassCache: Bool = false
    ) async throws -> SkyStreamValidatedPlaybackDescriptor {
        try Task.checkCancellation()
        try Self.rejectForbiddenCandidate(candidate)
        let cacheKey = Self.cacheKey(candidate: candidate, identity: identity, limits: limits)
        if !bypassCache, let cached = await cache.value(for: cacheKey) {
            switch cached {
            case .accepted(let descriptor): return descriptor
            case .rejected(let reason): throw SkyStreamVODValidationError.cachedRejection(reason)
            }
        }

        do {
            let descriptor = try await validateUncached(candidate, identity: identity, limits: limits)
            await cache.storeAccepted(descriptor, for: cacheKey)
            return descriptor
        } catch is CancellationError {
            throw CancellationError()
        } catch SkyStreamSecurityError.cancelled {
            throw CancellationError()
        } catch {
            let safeReason: String
            if let validationError = error as? SkyStreamVODValidationError {
                safeReason = validationError.localizedDescription
            } else if let securityError = error as? SkyStreamSecurityError {
                safeReason = securityError.localizedDescription
            } else {
                safeReason = "Stream validation failed."
            }
            await cache.storeRejected(safeReason, for: cacheKey)
            throw error
        }
    }

    private func validateUncached(
        _ candidate: SkyStreamRawStreamCandidate,
        identity: SkyStreamVODValidationIdentity,
        limits: SkyStreamVODValidationLimits
    ) async throws -> SkyStreamValidatedPlaybackDescriptor {
        try Self.rejectForbiddenCandidate(candidate)
        let decoded = try SkyStreamMagicProxyDecoder.decode(
            candidate.url,
            fallbackHeaders: candidate.headers
        )

        let rawURL: String?
        let generatedHLS: Data?
        let decodedHeaders: [String: String]
        let rawProxyOptions: SkyStreamRawProxyOptions?
        switch decoded {
        case .remote(let url, let headers, let proxyOptions):
            rawURL = url
            generatedHLS = nil
            decodedHeaders = headers
            rawProxyOptions = proxyOptions
        case .generatedHLS(let bytes, let headers, let proxyOptions):
            rawURL = nil
            generatedHLS = bytes
            decodedHeaders = headers
            rawProxyOptions = proxyOptions
        }

        let proxyOptions = try await validateProxyOptions(rawProxyOptions)

        var mergedHeaders = SkyStreamRuntimeHeaderCompatibility.droppingControlled(decodedHeaders)
        let preferredReferer = rawProxyOptions?.referer ?? candidate.referer
        if let preferredReferer,
           !mergedHeaders.keys.contains(where: { $0.caseInsensitiveCompare("Referer") == .orderedSame }),
           let validatedReferer = try? await policy.validate(preferredReferer, purpose: .pluginRequest) {
            mergedHeaders["Referer"] = validatedReferer.url.absoluteString
        }
        let headers = try SkyStreamHeaderSanitizer.sanitize(mergedHeaders, purpose: .stream)

        if let generatedHLS {
            async let subtitleTask = validateSubtitles(
                candidate.subtitles,
                identity: identity,
                limits: limits
            )
            guard generatedHLS.count <= limits.maximumManifestBytes else {
                throw SkyStreamVODValidationError.oversizedManifest
            }
            let context = HLSValidationContext(
                identity: identity,
                defaultHeaders: headers,
                defaultProxyOptions: proxyOptions,
                permitsUnscopedHeaderInheritance: true,
                limits: limits,
                policy: policy,
                client: client
            )
            let visited = HLSVisited(maximumManifests: limits.maximumManifests)
            let result = try await validateHLS(
                data: generatedHLS,
                sourceURL: nil,
                baseURL: nil,
                baseOrigin: nil,
                depth: 0,
                context: context,
                visited: visited
            )
            guard let underlying = result.routes.first(where: {
                $0.role == .mediaSegment || $0.role == .manifest || $0.role == .initialization
            })?.remoteURL else {
                throw SkyStreamVODValidationError.malformedManifest
            }
            let mediaDescriptor = try makePlaybackDescriptor(
                identity: identity,
                mediaKind: .hls,
                underlyingRemoteURL: underlying,
                headers: .empty,
                acceptedManifests: result.manifests,
                routes: result.routes,
                proxyOptions: proxyOptions,
                subtitles: [],
                finiteContentLength: nil
            )
            return try attachingSubtitles(
                try await subtitleTask,
                to: mediaDescriptor,
                maximumRoutes: limits.maximumRoutes
            )
        }

        guard let rawURL else { throw SkyStreamVODValidationError.emptyCandidate }
        let root: SkyStreamValidatedRemoteURL
        do {
            root = try await policy.validate(rawURL, purpose: .streamRoot)
        } catch let error as SkyStreamSecurityError {
            throw SkyStreamVODValidationError.security(error.localizedDescription)
        }

        let lowerPath = root.url.path.lowercased()
        if lowerPath.hasSuffix(".m3u") && !lowerPath.hasSuffix(".m3u8") {
            throw SkyStreamVODValidationError.prohibitedTransport
        }
        let hint = Self.mediaHint(url: root.url, declaredType: candidate.mediaType)
        async let subtitleTask = validateSubtitles(
            candidate.subtitles,
            identity: identity,
            limits: limits
        )

        let mediaDescriptor: SkyStreamValidatedPlaybackDescriptor
        switch hint {
        case .hls:
            mediaDescriptor = try await validateRemoteHLS(
                root: root,
                headers: headers,
                subtitles: [],
                proxyOptions: proxyOptions,
                identity: identity,
                limits: limits
            )
        case .dash:
            mediaDescriptor = try await validateRemoteDASH(
                root: root,
                headers: headers,
                subtitles: [],
                proxyOptions: proxyOptions,
                identity: identity,
                limits: limits
            )
        case .direct, .unknown:
            mediaDescriptor = try await validateSniffedOrDirect(
                root: root,
                headers: headers,
                subtitles: [],
                proxyOptions: proxyOptions,
                identity: identity,
                limits: limits,
                hint: hint
            )
        }
        return try attachingSubtitles(
            try await subtitleTask,
            to: mediaDescriptor,
            maximumRoutes: limits.maximumRoutes
        )
    }

    private func validateRemoteHLS(
        root: SkyStreamValidatedRemoteURL,
        headers: SkyStreamSanitizedHeaders,
        subtitles: [SkyStreamValidatedSubtitle],
        proxyOptions: SkyStreamValidatedProxyOptions?,
        identity: SkyStreamVODValidationIdentity,
        limits: SkyStreamVODValidationLimits
    ) async throws -> SkyStreamValidatedPlaybackDescriptor {
        let fetched = try await fetchManifest(root, headers: headers, identity: identity, limits: limits)
        guard Self.looksLikeHLS(fetched.response.data) else {
            throw SkyStreamVODValidationError.malformedManifest
        }
        let context = HLSValidationContext(
            identity: identity,
            defaultHeaders: fetched.headers,
            defaultProxyOptions: proxyOptions,
            permitsUnscopedHeaderInheritance: proxyOptions != nil,
            limits: limits,
            policy: policy,
            client: client
        )
        let visited = HLSVisited(maximumManifests: limits.maximumManifests)
        _ = try await visited.reserve(fetched.finalURL.url.absoluteString)
        let result = try await validateHLS(
            data: fetched.response.data,
            sourceURL: fetched.finalURL,
            baseURL: fetched.finalURL.url,
            baseOrigin: fetched.finalURL.origin,
            depth: 0,
            context: context,
            visited: visited
        )
        let allRoutes = try Self.mergingRoutes(
            [SkyStreamValidatedRoute(remoteURL: fetched.finalURL, role: .streamRoot, headers: fetched.headers)]
                + result.routes
                + subtitles.map {
                    SkyStreamValidatedRoute(remoteURL: $0.remoteURL, role: .subtitle, headers: $0.headers)
                },
            maximum: limits.maximumRoutes
        )
        return try makePlaybackDescriptor(
            identity: identity,
            mediaKind: .hls,
            underlyingRemoteURL: fetched.finalURL,
            headers: fetched.headers,
            acceptedManifests: result.manifests,
            routes: allRoutes,
            proxyOptions: proxyOptions,
            subtitles: subtitles,
            finiteContentLength: nil
        )
    }

    private func validateRemoteDASH(
        root: SkyStreamValidatedRemoteURL,
        headers: SkyStreamSanitizedHeaders,
        subtitles: [SkyStreamValidatedSubtitle],
        proxyOptions: SkyStreamValidatedProxyOptions?,
        identity: SkyStreamVODValidationIdentity,
        limits: SkyStreamVODValidationLimits
    ) async throws -> SkyStreamValidatedPlaybackDescriptor {
        let fetched = try await fetchManifest(root, headers: headers, identity: identity, limits: limits)
        let parsed = try Self.parseDASH(fetched.response.data, limits: limits)
        let dashRoutes = try await validateDASHReferences(
            parsed,
            manifest: fetched.finalURL,
            headers: fetched.headers,
            proxyOptions: proxyOptions,
            limits: limits
        )
        let allRoutes = try Self.mergingRoutes(
            [SkyStreamValidatedRoute(remoteURL: fetched.finalURL, role: .streamRoot, headers: fetched.headers)]
                + dashRoutes
                + subtitles.map {
                    SkyStreamValidatedRoute(remoteURL: $0.remoteURL, role: .subtitle, headers: $0.headers)
                },
            maximum: limits.maximumRoutes
        )
        return try makePlaybackDescriptor(
            identity: identity,
            mediaKind: .dash,
            underlyingRemoteURL: fetched.finalURL,
            headers: fetched.headers,
            acceptedManifests: [
                SkyStreamAcceptedManifest(sourceURL: fetched.finalURL, bytes: fetched.response.data, mediaKind: .dash)
            ],
            routes: allRoutes,
            proxyOptions: proxyOptions,
            subtitles: subtitles,
            finiteContentLength: nil
        )
    }

    private enum MediaHint: Equatable { case hls, dash, direct, unknown }

    private func validateSniffedOrDirect(
        root: SkyStreamValidatedRemoteURL,
        headers: SkyStreamSanitizedHeaders,
        subtitles: [SkyStreamValidatedSubtitle],
        proxyOptions: SkyStreamValidatedProxyOptions?,
        identity: SkyStreamVODValidationIdentity,
        limits: SkyStreamVODValidationLimits,
        hint: MediaHint
    ) async throws -> SkyStreamValidatedPlaybackDescriptor {
        let probeLimits = SkyStreamHTTPRequestLimits(
            maximumResponseBytes: 70_000,
            maximumRequestBodyBytes: 0,
            maximumRedirects: 5,
            timeout: 20
        )
        let response: SkyStreamHTTPResponse
        do {
            response = try await client.fetch(
                SkyStreamHTTPRequest(
                    url: root,
                    method: "GET",
                    headers: headers,
                    byteRange: 0...65_535
                ),
                packageID: identity.packageID,
                limits: probeLimits
            )
        } catch let error as SkyStreamSecurityError {
            throw SkyStreamVODValidationError.network(error.localizedDescription)
        }
        guard (200...299).contains(response.statusCode) else {
            throw SkyStreamVODValidationError.network("The media server rejected the validation request.")
        }
        let finalURL = try await policy.validate(response.finalURL.absoluteString, purpose: .streamRoot)

        if Self.looksLikeHLS(response.data) || Self.responseIndicatesHLS(response) {
            let complete: ManifestFetch
            if response.statusCode == 200 && response.data.count < limits.maximumManifestBytes {
                complete = ManifestFetch(
                    response: response,
                    finalURL: finalURL,
                    headers: response.effectiveRequestHeaders
                )
            } else {
                complete = try await fetchManifest(
                    finalURL,
                    headers: response.effectiveRequestHeaders,
                    identity: identity,
                    limits: limits
                )
            }
            let context = HLSValidationContext(
                identity: identity,
                defaultHeaders: complete.headers,
                defaultProxyOptions: proxyOptions,
                permitsUnscopedHeaderInheritance: proxyOptions != nil,
                limits: limits,
                policy: policy,
                client: client
            )
            let visited = HLSVisited(maximumManifests: limits.maximumManifests)
            _ = try await visited.reserve(complete.finalURL.url.absoluteString)
            let result = try await validateHLS(
                data: complete.response.data,
                sourceURL: complete.finalURL,
                baseURL: complete.finalURL.url,
                baseOrigin: complete.finalURL.origin,
                depth: 0,
                context: context,
                visited: visited
            )
            let routes = try Self.mergingRoutes(
                [SkyStreamValidatedRoute(remoteURL: complete.finalURL, role: .streamRoot, headers: complete.headers)]
                    + result.routes
                    + subtitles.map {
                        SkyStreamValidatedRoute(remoteURL: $0.remoteURL, role: .subtitle, headers: $0.headers)
                    },
                maximum: limits.maximumRoutes
            )
            return try makePlaybackDescriptor(
                identity: identity,
                mediaKind: .hls,
                underlyingRemoteURL: complete.finalURL,
                headers: complete.headers,
                acceptedManifests: result.manifests,
                routes: routes,
                proxyOptions: proxyOptions,
                subtitles: subtitles,
                finiteContentLength: nil
            )
        }

        if Self.looksLikeDASH(response.data) || Self.responseIndicatesDASH(response) {
            let complete = try await fetchManifest(
                finalURL,
                headers: response.effectiveRequestHeaders,
                identity: identity,
                limits: limits
            )
            let parsed = try Self.parseDASH(complete.response.data, limits: limits)
            let dashRoutes = try await validateDASHReferences(
                parsed,
                manifest: complete.finalURL,
                headers: complete.headers,
                proxyOptions: proxyOptions,
                limits: limits
            )
            let routes = try Self.mergingRoutes(
                [SkyStreamValidatedRoute(remoteURL: complete.finalURL, role: .streamRoot, headers: complete.headers)]
                    + dashRoutes
                    + subtitles.map {
                        SkyStreamValidatedRoute(remoteURL: $0.remoteURL, role: .subtitle, headers: $0.headers)
                    },
                maximum: limits.maximumRoutes
            )
            return try makePlaybackDescriptor(
                identity: identity,
                mediaKind: .dash,
                underlyingRemoteURL: complete.finalURL,
                headers: complete.headers,
                acceptedManifests: [
                    SkyStreamAcceptedManifest(sourceURL: complete.finalURL, bytes: complete.response.data, mediaKind: .dash)
                ],
                routes: routes,
                proxyOptions: proxyOptions,
                subtitles: subtitles,
                finiteContentLength: nil
            )
        }

        let length = try Self.proveFiniteDirectMedia(response, finalURL: finalURL, hint: hint)
        let routes = try Self.mergingRoutes(
            [SkyStreamValidatedRoute(
                remoteURL: finalURL,
                role: .streamRoot,
                headers: response.effectiveRequestHeaders
            )]
                + subtitles.map {
                    SkyStreamValidatedRoute(remoteURL: $0.remoteURL, role: .subtitle, headers: $0.headers)
                },
            maximum: limits.maximumRoutes
        )
        return try makePlaybackDescriptor(
            identity: identity,
            mediaKind: .direct,
            underlyingRemoteURL: finalURL,
            headers: response.effectiveRequestHeaders,
            acceptedManifests: [],
            routes: routes,
            proxyOptions: proxyOptions,
            subtitles: subtitles,
            finiteContentLength: length
        )
    }

    private func makePlaybackDescriptor(
        identity: SkyStreamVODValidationIdentity,
        mediaKind: SkyStreamValidatedMediaKind,
        underlyingRemoteURL: SkyStreamValidatedRemoteURL,
        headers: SkyStreamSanitizedHeaders,
        acceptedManifests: [SkyStreamAcceptedManifest],
        routes: [SkyStreamValidatedRoute],
        proxyOptions: SkyStreamValidatedProxyOptions?,
        subtitles: [SkyStreamValidatedSubtitle],
        finiteContentLength: Int64?
    ) throws -> SkyStreamValidatedPlaybackDescriptor {
        let descriptorCookieSource = proxyOptions?.referer?.url
            ?? headers.values["referer"].flatMap(URL.init(string:))
            ?? underlyingRemoteURL.url

        let candidateSubtitles = try subtitles.map { subtitle in
            SkyStreamValidatedSubtitle(
                remoteURL: subtitle.remoteURL,
                label: subtitle.label,
                language: subtitle.language,
                headers: try materializePlaybackHeaders(
                    subtitle.headers,
                    targetURL: subtitle.remoteURL.url,
                    cookieSourceURL: descriptorCookieSource,
                    proxyOptions: nil,
                    packageID: identity.packageID
                )
            )
        }
        var subtitleHeaders: [String: SkyStreamSanitizedHeaders] = [:]
        var sealedSubtitles: [SkyStreamValidatedSubtitle] = []
        sealedSubtitles.reserveCapacity(candidateSubtitles.count)
        for subtitle in candidateSubtitles {
            let key = subtitle.remoteURL.url.absoluteString
            guard subtitleHeaders[key] == nil else { continue }
            subtitleHeaders[key] = subtitle.headers
            sealedSubtitles.append(subtitle)
        }
        let sealedRoutes = try routes.map { route in
            let routeOptions = route.proxyOptions
                ?? (route.role == .subtitle ? nil : proxyOptions)
            let sealedHeaders: SkyStreamSanitizedHeaders
            if let subtitleHeader = subtitleHeaders[route.remoteURL.url.absoluteString] {
                sealedHeaders = subtitleHeader
            } else {
                sealedHeaders = try materializePlaybackHeaders(
                    route.headers,
                    targetURL: route.remoteURL.url,
                    cookieSourceURL: routeOptions?.referer?.url ?? descriptorCookieSource,
                    proxyOptions: routeOptions,
                    packageID: identity.packageID
                )
            }
            return SkyStreamValidatedRoute(
                remoteURL: route.remoteURL,
                role: route.role,
                headers: sealedHeaders,
                proxyOptions: routeOptions
            )
        }
        let sealedTopHeaders = try materializePlaybackHeaders(
            headers,
            targetURL: underlyingRemoteURL.url,
            cookieSourceURL: descriptorCookieSource,
            proxyOptions: proxyOptions,
            packageID: identity.packageID
        )
        return SkyStreamValidatedPlaybackDescriptor(
            identity: identity,
            mediaKind: mediaKind,
            underlyingRemoteURL: underlyingRemoteURL,
            headers: sealedTopHeaders,
            acceptedManifests: acceptedManifests,
            routes: sealedRoutes,
            proxyOptions: proxyOptions,
            subtitles: sealedSubtitles,
            finiteContentLength: finiteContentLength
        )
    }

    private func attachingSubtitles(
        _ subtitles: [SkyStreamValidatedSubtitle],
        to descriptor: SkyStreamValidatedPlaybackDescriptor,
        maximumRoutes: Int
    ) throws -> SkyStreamValidatedPlaybackDescriptor {
        guard !subtitles.isEmpty else { return descriptor }
        let cookieSource = descriptor.proxyOptions?.referer?.url
            ?? descriptor.headers.values["referer"].flatMap(URL.init(string:))
            ?? descriptor.underlyingRemoteURL.url
        var seenURLs = Set<String>()
        var sealedSubtitles: [SkyStreamValidatedSubtitle] = []
        for subtitle in subtitles {
            let key = subtitle.remoteURL.url.absoluteString
            guard seenURLs.insert(key).inserted else { continue }
            sealedSubtitles.append(SkyStreamValidatedSubtitle(
                remoteURL: subtitle.remoteURL,
                label: subtitle.label,
                language: subtitle.language,
                headers: try materializePlaybackHeaders(
                    subtitle.headers,
                    targetURL: subtitle.remoteURL.url,
                    cookieSourceURL: cookieSource,
                    proxyOptions: nil,
                    packageID: descriptor.identity.packageID
                )
            ))
        }
        let subtitleRoutes = sealedSubtitles.map {
            SkyStreamValidatedRoute(
                remoteURL: $0.remoteURL,
                role: .subtitle,
                headers: $0.headers
            )
        }
        let routes = try Self.mergingRoutes(
            descriptor.routes + subtitleRoutes,
            maximum: maximumRoutes
        )
        return SkyStreamValidatedPlaybackDescriptor(
            identity: descriptor.identity,
            mediaKind: descriptor.mediaKind,
            underlyingRemoteURL: descriptor.underlyingRemoteURL,
            headers: descriptor.headers,
            acceptedManifests: descriptor.acceptedManifests,
            routes: routes,
            proxyOptions: descriptor.proxyOptions,
            subtitles: sealedSubtitles,
            finiteContentLength: descriptor.finiteContentLength
        )
    }

    private func materializePlaybackHeaders(
        _ base: SkyStreamSanitizedHeaders,
        targetURL: URL,
        cookieSourceURL: URL,
        proxyOptions: SkyStreamValidatedProxyOptions?,
        packageID: String
    ) throws -> SkyStreamSanitizedHeaders {
        var raw = base.values
        let explicitCookie = raw.removeValue(forKey: "cookie")
        let targetCookie = try client.cookieHeader(for: targetURL, packageID: packageID)
        let sourceCookie = proxyOptions == nil
            ? nil
            : try client.cookieHeader(for: cookieSourceURL, packageID: packageID)
        var cookies = try Self.mergedCookiePairs([explicitCookie, sourceCookie, targetCookie])

        if let proxyOptions {
            let targetHost = targetURL.host?.lowercased() ?? ""
            let isMirror = proxyOptions.mirrorHosts.contains {
                targetHost == $0 || targetHost.hasSuffix("." + $0)
            }
            if !isMirror {
                let retained = Set(proxyOptions.retainedCookieNames.map { $0.lowercased() })
                cookies = cookies.filter { retained.contains($0.key) }
            }
            if proxyOptions.retainedCookieNames.contains(where: {
                $0.caseInsensitiveCompare("hd") == .orderedSame
            }), cookies["hd"] == nil {
                cookies["hd"] = ("hd", "on")
            }
        }

        if !cookies.isEmpty {
            raw["cookie"] = cookies.keys.sorted().compactMap { key in
                cookies[key].map { "\($0.name)=\($0.value)" }
            }.joined(separator: "; ")
        }
        return try SkyStreamHeaderSanitizer.sanitize(raw, purpose: .stream)
    }

    private static func mergedCookiePairs(
        _ headers: [String?]
    ) throws -> [String: (name: String, value: String)] {
        let validNameCharacters = CharacterSet(
            charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        )
        var result: [String: (name: String, value: String)] = [:]
        for header in headers.compactMap({ $0 }) where !header.isEmpty {
            let components = header.split(separator: ";", omittingEmptySubsequences: true)
            guard components.count <= 128 else {
                throw SkyStreamVODValidationError.invalidMagicDescriptor
            }
            for component in components {
                let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else {
                    throw SkyStreamVODValidationError.invalidMagicDescriptor
                }
                let name = String(pair[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(pair[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.utf8.count <= 128, value.utf8.count <= 8 * 1_024,
                      name.unicodeScalars.allSatisfy({ validNameCharacters.contains($0) }),
                      value.unicodeScalars.allSatisfy({
                          $0.value == 9 || ($0.value >= 32 && $0.value != 127)
                      }) else {
                    throw SkyStreamVODValidationError.invalidMagicDescriptor
                }
                result[name.lowercased()] = (name, value)
            }
        }
        return result
    }

    private struct ManifestFetch {
        let response: SkyStreamHTTPResponse
        let finalURL: SkyStreamValidatedRemoteURL
        let headers: SkyStreamSanitizedHeaders
    }

    private func fetchManifest(
        _ url: SkyStreamValidatedRemoteURL,
        headers: SkyStreamSanitizedHeaders,
        identity: SkyStreamVODValidationIdentity,
        limits: SkyStreamVODValidationLimits
    ) async throws -> ManifestFetch {
        let requestLimits = SkyStreamHTTPRequestLimits(
            maximumResponseBytes: limits.maximumManifestBytes,
            maximumRequestBodyBytes: 0,
            maximumRedirects: 5,
            timeout: 20
        )
        let response: SkyStreamHTTPResponse
        do {
            response = try await client.fetch(
                SkyStreamHTTPRequest(url: url, method: "GET", headers: headers),
                packageID: identity.packageID,
                limits: requestLimits
            )
        } catch let error as SkyStreamSecurityError {
            if error == .responseTooLarge { throw SkyStreamVODValidationError.oversizedManifest }
            throw SkyStreamVODValidationError.network(error.localizedDescription)
        }
        guard (200...299).contains(response.statusCode), response.data.count <= limits.maximumManifestBytes else {
            throw SkyStreamVODValidationError.network("The manifest server rejected the validation request.")
        }
        let finalURL = try await policy.validate(response.finalURL.absoluteString, purpose: .manifest)
        return ManifestFetch(
            response: response,
            finalURL: finalURL,
            headers: response.effectiveRequestHeaders
        )
    }

    private func validateProxyOptions(
        _ rawOptions: SkyStreamRawProxyOptions?
    ) async throws -> SkyStreamValidatedProxyOptions? {
        guard let rawOptions else { return nil }
        var hosts: [String] = []
        var seenHosts = Set<String>()
        for rawHost in rawOptions.mirrorHosts {
            let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty, trimmed.utf8.count <= 253,
                  !trimmed.contains(":"), !trimmed.contains("/"), !trimmed.contains("*") else {
                throw SkyStreamVODValidationError.invalidMagicDescriptor
            }
            let checked = try await policy.validate("https://\(trimmed)/", purpose: .streamRoot)
            if seenHosts.insert(checked.origin.host).inserted { hosts.append(checked.origin.host) }
        }

        let validCookieCharacters = CharacterSet(
            charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        )
        var cookieNames: [String] = []
        var seenCookies = Set<String>()
        for rawName in rawOptions.retainedCookieNames {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.utf8.count <= 128,
                  name.unicodeScalars.allSatisfy({ validCookieCharacters.contains($0) }) else {
                throw SkyStreamVODValidationError.invalidMagicDescriptor
            }
            if seenCookies.insert(name.lowercased()).inserted { cookieNames.append(name) }
        }

        let referer: SkyStreamValidatedRemoteURL?
        if let rawReferer = rawOptions.referer {
            referer = try await policy.validate(rawReferer, purpose: .pluginRequest)
        } else {
            referer = nil
        }
        return SkyStreamValidatedProxyOptions(
            magicVersion: rawOptions.version,
            mirrorHosts: hosts,
            retainedCookieNames: cookieNames,
            referer: referer
        )
    }

    private func validateSubtitles(
        _ candidates: [SkyStreamRawSubtitleCandidate],
        identity: SkyStreamVODValidationIdentity,
        limits: SkyStreamVODValidationLimits
    ) async throws -> [SkyStreamValidatedSubtitle] {
        guard limits.maximumSubtitles > 0 else { return [] }
        _ = identity

        var prepared: [(Int, SkyStreamRawSubtitleCandidate, SkyStreamSanitizedHeaders)] = []
        var seen = Set<String>()
        for candidate in candidates.prefix(256) {
            guard let syntacticURL = try? policy.validateSyntactic(
                candidate.url,
                purpose: .subtitle
            ),
                  let headers = try? SkyStreamHeaderSanitizer.sanitize(
                      SkyStreamRuntimeHeaderCompatibility.droppingControlled(candidate.headers),
                      purpose: .subtitle
                  ) else { continue }

            let key = syntacticURL.url.absoluteString
            guard seen.insert(key).inserted else { continue }
            prepared.append((prepared.count, candidate, headers))
            if prepared.count == limits.maximumSubtitles { break }
        }

        var validated: [(Int, SkyStreamValidatedSubtitle)] = []
        var start = 0
        while start < prepared.count {
            try Task.checkCancellation()
            let end = min(start + limits.maximumConcurrentChildChecks, prepared.count)
            let chunk = Array(prepared[start..<end])
            let values = try await withThrowingTaskGroup(
                of: (Int, SkyStreamValidatedSubtitle?).self,
                returning: [(Int, SkyStreamValidatedSubtitle)].self
            ) { group in
                for (index, candidate, headers) in chunk {
                    group.addTask {
                        do {
                            let url = try await self.policy.validate(
                                candidate.url,
                                purpose: .subtitle
                            )
                            return (index, SkyStreamValidatedSubtitle(
                                remoteURL: url,
                                label: Self.sanitizedDisplayValue(candidate.label, maximumBytes: 200),
                                language: Self.sanitizedDisplayValue(candidate.language, maximumBytes: 32),
                                headers: headers
                            ))
                        } catch {
                            if Task.isCancelled
                                || error is CancellationError
                                || (error as? SkyStreamSecurityError) == .cancelled {
                                throw CancellationError()
                            }
                            return (index, nil)
                        }
                    }
                }
                var result: [(Int, SkyStreamValidatedSubtitle)] = []
                for try await (index, subtitle) in group {
                    if let subtitle { result.append((index, subtitle)) }
                }
                return result
            }
            validated.append(contentsOf: values)
            start = end
        }
        return validated.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private static func sanitizedDisplayValue(_ value: String?, maximumBytes: Int) -> String? {
        guard let value else { return nil }
        let cleaned = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0.value != 0x202e && $0.value != 0x202d
        }
        let string = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else { return nil }
        var output = string
        while output.utf8.count > maximumBytes { output.removeLast() }
        return output
    }

    private static func rejectForbiddenCandidate(_ candidate: SkyStreamRawStreamCandidate) throws {
        let value = candidate.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw SkyStreamVODValidationError.emptyCandidate }
        let lower = value.lowercased()

        if candidate.isLive
            || ["live", "livestream", "channel", "linear"].contains(candidate.mediaType?.lowercased() ?? "")
            || policyHint(candidate.policyHints, keys: ["live", "islive", "livestream"]) {
            throw SkyStreamVODValidationError.liveContent
        }
        if nonempty(candidate.infoHash) || nonempty(candidate.torrentURL)
            || lower.hasPrefix("magnet:") || lower.hasPrefix("torrent:")
            || lower.contains("urn:btih:") || lower.contains("infohash=")
            || lower.contains("info_hash=") || isTorrentURL(value)
            || policyHint(candidate.policyHints, keys: ["torrent", "infohash", "magnet"]) {
            throw SkyStreamVODValidationError.torrentContent
        }
        if nonempty(candidate.drmKeyID) || nonempty(candidate.drmKey) || nonempty(candidate.licenseURL)
            || policyHint(candidate.policyHints, keys: ["drm", "widevine", "playready", "license"]) {
            throw SkyStreamVODValidationError.drmContent
        }
        if nonempty(candidate.externalPlayerPolicy)
            || policyHint(candidate.policyHints, keys: ["externalplayer", "external_player", "external"]) {
            throw SkyStreamVODValidationError.externalPlayerPolicy
        }
        let prohibitedPrefixes = ["file:", "data:", "javascript:", "blob:", "content:", "asset:", "rtmp:", "rtsp:"]
        if prohibitedPrefixes.contains(where: lower.hasPrefix) {
            throw SkyStreamVODValidationError.prohibitedTransport
        }
    }

    private static func policyHint(_ values: [String: String], keys: Set<String>) -> Bool {
        values.contains { key, value in
            keys.contains(key.lowercased().replacingOccurrences(of: "-", with: ""))
                && ["1", "true", "yes", "required", "enabled", "live"].contains(value.lowercased())
        }
    }

    private static func nonempty(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static func isTorrentURL(_ value: String) -> Bool {
        if value.lowercased().hasSuffix(".torrent") { return true }
        guard let components = URLComponents(string: value) else { return false }
        return components.percentEncodedPath.lowercased().hasSuffix(".torrent")
            || components.path.lowercased().hasSuffix(".torrent")
    }

    private static func mediaHint(url: URL, declaredType: String?) -> MediaHint {
        let declared = declaredType?.lowercased() ?? ""
        let path = url.path.lowercased()
        if declared.contains("mpegurl") || declared == "hls" || path.hasSuffix(".m3u8") { return .hls }
        if declared.contains("dash") || declared.contains("mpd") || path.hasSuffix(".mpd") { return .dash }
        let extensions: Set<String> = [
            "mp4", "m4v", "mkv", "webm", "mov", "avi", "ts", "m2ts",
            "mp3", "m4a", "aac", "flac", "ogg", "opus", "wav"
        ]
        if extensions.contains(url.pathExtension.lowercased()) { return .direct }
        return .unknown
    }

    private static func cacheKey(
        candidate: SkyStreamRawStreamCandidate,
        identity: SkyStreamVODValidationIdentity,
        limits: SkyStreamVODValidationLimits
    ) -> String {
        var components = [
            identity.packageID, identity.providerID, identity.payloadSHA256,
            String(identity.generation), identity.authorityRevision.uuidString.lowercased(),
            candidate.url, candidate.referer ?? "", candidate.mediaType ?? "",
            String(limits.maximumManifestBytes), String(limits.maximumManifestDepth),
            String(limits.maximumVariants), String(limits.maximumManifests), String(limits.maximumRoutes),
            String(limits.maximumSubtitles), String(limits.maximumConcurrentChildChecks)
        ]
        components.append(contentsOf: candidate.headers.sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { "\($0.key.lowercased()):\($0.value)" })
        components.append(contentsOf: [
            candidate.isLive ? "live" : "vod",
            candidate.infoHash ?? "", candidate.torrentURL ?? "",
            candidate.drmKeyID ?? "", candidate.drmKey ?? "", candidate.licenseURL ?? "",
            candidate.externalPlayerPolicy ?? ""
        ])
        components.append(contentsOf: candidate.policyHints.sorted { $0.key < $1.key }
            .map { "hint:\($0.key):\($0.value)" })
        for subtitle in candidate.subtitles {
            components.append("subtitle:\(subtitle.url):\(subtitle.label ?? ""):\(subtitle.language ?? "")")
            components.append(contentsOf: subtitle.headers.sorted { $0.key < $1.key }
                .map { "subtitle-header:\($0.key.lowercased()):\($0.value)" })
        }
        let digest = SHA256.hash(data: Data(components.joined(separator: "\u{1f}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func mergingRoutes(
        _ routes: [SkyStreamValidatedRoute],
        maximum: Int
    ) throws -> [SkyStreamValidatedRoute] {
        var seen = Set<String>()
        var result: [SkyStreamValidatedRoute] = []
        for route in routes {
            let headerFingerprint = route.headers.values.sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }.joined(separator: "|")
            let proxyFingerprint = route.proxyOptions.map {
                "\($0.magicVersion.rawValue):\($0.mirrorHosts.joined(separator: ",")):\($0.retainedCookieNames.joined(separator: ","))"
            } ?? "none"
            let key = "\(route.role.rawValue)|\(route.remoteURL.url.absoluteString)|\(headerFingerprint)|\(proxyFingerprint)"
            if seen.insert(key).inserted { result.append(route) }
            guard result.count <= maximum else { throw SkyStreamVODValidationError.tooManyRoutes }
        }
        return result
    }
}

private struct HLSValidationContext: @unchecked Sendable {
    let identity: SkyStreamVODValidationIdentity
    let defaultHeaders: SkyStreamSanitizedHeaders
    let defaultProxyOptions: SkyStreamValidatedProxyOptions?

    let permitsUnscopedHeaderInheritance: Bool
    let limits: SkyStreamVODValidationLimits
    let policy: SkyStreamRemoteURLPolicy
    let client: SkyStreamHTTPClient
}

private actor HLSVisited {
    private var values = Set<String>()
    private let maximumManifests: Int

    init(maximumManifests: Int) {
        self.maximumManifests = maximumManifests
    }

    func reserve(_ value: String) throws -> Bool {
        if values.contains(value) { return false }
        guard values.count < maximumManifests else {
            throw SkyStreamVODValidationError.tooManyManifests
        }
        values.insert(value)
        return true
    }
}

private struct HLSReference: Sendable {
    let rawValue: String
    let role: SkyStreamValidatedRouteRole
    let isNestedManifest: Bool
}

private struct ParsedHLS: Sendable {
    let references: [HLSReference]
    let isMaster: Bool
    let isFiniteMedia: Bool
}

private struct HLSValidationResult: Sendable {
    var manifests: [SkyStreamAcceptedManifest]
    var routes: [SkyStreamValidatedRoute]
    var finiteMediaPlaylistCount: Int
}

private struct ResolvedHLSReference: Sendable {
    let remoteURL: SkyStreamValidatedRemoteURL?
    let generatedManifest: Data?
    let headers: SkyStreamSanitizedHeaders
    let proxyOptions: SkyStreamValidatedProxyOptions?
    let original: HLSReference
}

private struct PendingPlainHLSReference: Sendable {
    let index: Int
    let inheritedURL: String
    let purpose: SkyStreamNetworkPurpose
    let original: HLSReference
}

private extension SkyStreamVODValidator {
    func validateHLS(
        data: Data,
        sourceURL: SkyStreamValidatedRemoteURL?,
        baseURL: URL?,
        baseOrigin: SkyStreamRemoteOrigin?,
        depth: Int,
        context: HLSValidationContext,
        visited: HLSVisited
    ) async throws -> HLSValidationResult {
        try Task.checkCancellation()
        guard data.count <= context.limits.maximumManifestBytes else {
            throw SkyStreamVODValidationError.oversizedManifest
        }
        guard depth <= context.limits.maximumManifestDepth else {
            throw SkyStreamVODValidationError.manifestDepthExceeded
        }
        let parsed = try Self.parseHLS(data)
        let nestedCount = parsed.references.filter(\.isNestedManifest).count
        guard nestedCount <= context.limits.maximumVariants else {
            throw SkyStreamVODValidationError.tooManyVariants
        }
        guard parsed.references.count <= context.limits.maximumRoutes else {
            throw SkyStreamVODValidationError.tooManyRoutes
        }

        var result = HLSValidationResult(
            manifests: [SkyStreamAcceptedManifest(sourceURL: sourceURL, bytes: data, mediaKind: .hls)],
            routes: [],
            finiteMediaPlaylistCount: parsed.isFiniteMedia ? 1 : 0
        )

        let resolvedReferences = try await resolveHLSReferences(
            parsed.references,
            relativeTo: baseURL,
            baseOrigin: baseOrigin,
            context: context
        )

        for resolved in resolvedReferences {
            if let remoteURL = resolved.remoteURL {
                result.routes.append(
                    SkyStreamValidatedRoute(
                        remoteURL: remoteURL,
                        role: resolved.original.role,
                        headers: resolved.headers,
                        proxyOptions: resolved.proxyOptions
                    )
                )
            }
        }

        let nested = resolvedReferences.filter(\.original.isNestedManifest)
        let chunkSize = context.limits.maximumConcurrentChildChecks
        var start = 0
        while start < nested.count {
            try Task.checkCancellation()
            let end = min(start + chunkSize, nested.count)
            let chunk = Array(nested[start..<end])
            let childResults = try await withThrowingTaskGroup(
                of: HLSValidationResult?.self,
                returning: [HLSValidationResult].self
            ) { group in
                for resolved in chunk {
                    group.addTask {
                        try await self.validateNestedHLSReference(
                            resolved,
                            depth: depth,
                            context: context,
                            visited: visited
                        )
                    }
                }
                var values: [HLSValidationResult] = []
                for try await value in group {
                    if let value { values.append(value) }
                }
                return values
            }
            for child in childResults {
                result.manifests.append(contentsOf: child.manifests)
                result.routes.append(contentsOf: child.routes)
                result.finiteMediaPlaylistCount += child.finiteMediaPlaylistCount
            }
            guard result.manifests.count <= context.limits.maximumManifests else {
                throw SkyStreamVODValidationError.tooManyManifests
            }
            guard result.routes.count <= context.limits.maximumRoutes else {
                throw SkyStreamVODValidationError.tooManyRoutes
            }
            start = end
        }

        if parsed.isMaster && result.finiteMediaPlaylistCount == 0 {
            throw SkyStreamVODValidationError.liveHLS
        }
        if !parsed.isMaster && !parsed.isFiniteMedia {
            throw SkyStreamVODValidationError.liveHLS
        }
        result.routes = try Self.mergingRoutes(result.routes, maximum: context.limits.maximumRoutes)
        return result
    }

    func validateNestedHLSReference(
        _ resolved: ResolvedHLSReference,
        depth: Int,
        context: HLSValidationContext,
        visited: HLSVisited
    ) async throws -> HLSValidationResult? {
        guard resolved.original.isNestedManifest else { return nil }
        guard depth < context.limits.maximumManifestDepth else {
            throw SkyStreamVODValidationError.manifestDepthExceeded
        }
        let childContext = HLSValidationContext(
            identity: context.identity,
            defaultHeaders: resolved.headers,
            defaultProxyOptions: resolved.proxyOptions ?? context.defaultProxyOptions,
            permitsUnscopedHeaderInheritance: resolved.proxyOptions != nil
                || resolved.generatedManifest != nil,
            limits: context.limits,
            policy: context.policy,
            client: context.client
        )

        if let generated = resolved.generatedManifest {
            let digest = SHA256.hash(data: generated).map { String(format: "%02x", $0) }.joined()
            guard try await visited.reserve("generated:\(digest)") else { return nil }
            return try await validateHLS(
                data: generated,
                sourceURL: nil,
                baseURL: nil,
                baseOrigin: nil,
                depth: depth + 1,
                context: childContext,
                visited: visited
            )
        }

        guard let remoteURL = resolved.remoteURL else {
            throw SkyStreamVODValidationError.malformedManifest
        }
        guard try await visited.reserve(remoteURL.url.absoluteString) else { return nil }
        let childFetch = try await fetchManifest(
            remoteURL,
            headers: resolved.headers,
            identity: context.identity,
            limits: context.limits
        )
        guard Self.looksLikeHLS(childFetch.response.data) else {
            throw SkyStreamVODValidationError.malformedManifest
        }
        var child = try await validateHLS(
            data: childFetch.response.data,
            sourceURL: childFetch.finalURL,
            baseURL: childFetch.finalURL.url,
            baseOrigin: childFetch.finalURL.origin,
            depth: depth + 1,
            context: HLSValidationContext(
                identity: childContext.identity,
                defaultHeaders: childFetch.headers,
                defaultProxyOptions: childContext.defaultProxyOptions,
                permitsUnscopedHeaderInheritance: childContext.permitsUnscopedHeaderInheritance,
                limits: childContext.limits,
                policy: childContext.policy,
                client: childContext.client
            ),
            visited: visited
        )
        child.routes.insert(
            SkyStreamValidatedRoute(
                remoteURL: childFetch.finalURL,
                role: .manifest,
                headers: childFetch.headers,
                proxyOptions: childContext.defaultProxyOptions
            ),
            at: 0
        )
        return child
    }

    func resolveHLSReferences(
        _ references: [HLSReference],
        relativeTo baseURL: URL?,
        baseOrigin: SkyStreamRemoteOrigin?,
        context: HLSValidationContext
    ) async throws -> [ResolvedHLSReference] {
        var plain: [PendingPlainHLSReference] = []
        plain.reserveCapacity(references.count)
        var exceptional: [(index: Int, reference: HLSReference)] = []

        for (index, reference) in references.enumerated() {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            guard !reference.rawValue.contains("{$") else {
                throw SkyStreamVODValidationError.malformedManifest
            }
            if Self.isMagicHLSReference(reference.rawValue) {
                exceptional.append((index, reference))
                continue
            }
            let purpose = Self.networkPurpose(for: reference.role)
            let inheritedURL = Self.inheritingMirrorQueryIfNeeded(
                reference.rawValue,
                relativeTo: baseURL,
                options: context.defaultProxyOptions
            )
            plain.append(PendingPlainHLSReference(
                index: index,
                inheritedURL: inheritedURL,
                purpose: purpose,
                original: reference
            ))
        }

        let validatedPlain = try await context.policy.validate(
            plain.map {
                SkyStreamRemoteURLValidationRequest(
                    rawValue: $0.inheritedURL,
                    purpose: $0.purpose,
                    relativeTo: baseURL
                )
            },
            maximumConcurrentDNSLookups: context.limits.maximumConcurrentChildChecks
        )
        var indexed: [(Int, ResolvedHLSReference)] = []
        indexed.reserveCapacity(references.count)
        for (pending, url) in zip(plain, validatedPlain) {
            let headers = Self.scopedHLSHeaders(
                context.defaultHeaders,
                baseOrigin: baseOrigin,
                destinationOrigin: url.origin,
                permitsUnscopedInheritance: context.permitsUnscopedHeaderInheritance
            )
            indexed.append((pending.index, ResolvedHLSReference(
                remoteURL: url,
                generatedManifest: nil,
                headers: headers,
                proxyOptions: context.defaultProxyOptions,
                original: pending.original
            )))
        }

        if !exceptional.isEmpty {
            let concurrency = min(
                context.limits.maximumConcurrentChildChecks,
                exceptional.count
            )
            let exceptionalValues = try await withThrowingTaskGroup(
                of: (Int, ResolvedHLSReference).self,
                returning: [(Int, ResolvedHLSReference)].self
            ) { group in
                for item in exceptional.prefix(concurrency) {
                    group.addTask {
                        (item.index, try await self.resolveHLSReference(
                            item.reference,
                            relativeTo: baseURL,
                            baseOrigin: baseOrigin,
                            context: context
                        ))
                    }
                }
                var nextIndex = concurrency
                var values: [(Int, ResolvedHLSReference)] = []
                values.reserveCapacity(exceptional.count)
                while let value = try await group.next() {
                    try Task.checkCancellation()
                    values.append(value)
                    if nextIndex < exceptional.count {
                        let item = exceptional[nextIndex]
                        nextIndex += 1
                        group.addTask {
                            (item.index, try await self.resolveHLSReference(
                                item.reference,
                                relativeTo: baseURL,
                                baseOrigin: baseOrigin,
                                context: context
                            ))
                        }
                    }
                }
                return values
            }
            indexed.append(contentsOf: exceptionalValues)
        }

        try Task.checkCancellation()
        return indexed.sorted { $0.0 < $1.0 }.map(\.1)
    }

    static func isMagicHLSReference(_ value: String) -> Bool {
        value.hasPrefix("magic_m3u8:")
            || value.hasPrefix("MAGIC_PROXY_v1")
            || value.hasPrefix("MAGIC_PROXY_v2")
            || value.hasPrefix("MAGIC_PROXY:")
    }

    static func networkPurpose(
        for role: SkyStreamValidatedRouteRole
    ) -> SkyStreamNetworkPurpose {
        switch role {
        case .manifest: return .manifest
        case .encryptionKey: return .encryptionKey
        case .subtitle: return .subtitle
        case .mediaSegment, .initialization, .dashResource, .streamRoot: return .mediaSegment
        }
    }

    static func scopedHLSHeaders(
        _ headers: SkyStreamSanitizedHeaders,
        baseOrigin: SkyStreamRemoteOrigin?,
        destinationOrigin: SkyStreamRemoteOrigin,
        permitsUnscopedInheritance: Bool
    ) -> SkyStreamSanitizedHeaders {
        if permitsUnscopedInheritance { return headers }
        return baseOrigin.map {
            headers.scopedForRedirect(from: $0, to: destinationOrigin)
        } ?? headers.removingOriginCredentials()
    }

    func resolveHLSReference(
        _ reference: HLSReference,
        relativeTo baseURL: URL?,
        baseOrigin: SkyStreamRemoteOrigin?,
        context: HLSValidationContext
    ) async throws -> ResolvedHLSReference {
        guard !reference.rawValue.contains("{$") else {
            throw SkyStreamVODValidationError.malformedManifest
        }
        let decoded = try SkyStreamMagicProxyDecoder.decode(
            reference.rawValue,
            fallbackHeaders: context.defaultHeaders.values
        )
        switch decoded {
        case .generatedHLS(let bytes, let rawHeaders, let rawOptions):
            guard reference.isNestedManifest, bytes.count <= context.limits.maximumManifestBytes else {
                throw SkyStreamVODValidationError.malformedManifest
            }
            let headers = try SkyStreamHeaderSanitizer.sanitize(
                SkyStreamRuntimeHeaderCompatibility.droppingControlled(rawHeaders),
                purpose: .manifest
            )
            let options = try await validateProxyOptions(rawOptions)
            return ResolvedHLSReference(
                remoteURL: nil,
                generatedManifest: bytes,
                headers: headers,
                proxyOptions: options,
                original: reference
            )
        case .remote(let rawURL, let rawHeaders, let rawOptions):
            let purpose = Self.networkPurpose(for: reference.role)
            let options: SkyStreamValidatedProxyOptions?
            if let rawOptions {
                options = try await validateProxyOptions(rawOptions)
            } else {
                options = context.defaultProxyOptions
            }
            let inheritedURL = Self.inheritingMirrorQueryIfNeeded(
                rawURL,
                relativeTo: baseURL,
                options: options
            )
            let url = try await context.policy.validate(
                inheritedURL,
                purpose: purpose,
                relativeTo: baseURL
            )
            let sanitizedHeaders = try SkyStreamHeaderSanitizer.sanitize(
                SkyStreamRuntimeHeaderCompatibility.droppingControlled(rawHeaders),
                purpose: .manifest
            )
            let headers: SkyStreamSanitizedHeaders
            if rawOptions == nil {
                headers = Self.scopedHLSHeaders(
                    sanitizedHeaders,
                    baseOrigin: baseOrigin,
                    destinationOrigin: url.origin,
                    permitsUnscopedInheritance: context.permitsUnscopedHeaderInheritance
                )
            } else {
                headers = sanitizedHeaders
            }
            return ResolvedHLSReference(
                remoteURL: url,
                generatedManifest: nil,
                headers: headers,
                proxyOptions: options,
                original: reference
            )
        }
    }

    static func inheritingMirrorQueryIfNeeded(
        _ rawURL: String,
        relativeTo baseURL: URL?,
        options: SkyStreamValidatedProxyOptions?
    ) -> String {
        guard let baseURL,
              let baseQuery = URLComponents(
                  url: baseURL,
                  resolvingAgainstBaseURL: false
              )?.percentEncodedQuery,
              !baseQuery.isEmpty,
              let resolved = URL(string: rawURL, relativeTo: baseURL)?.absoluteURL,
              var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false),
              components.query?.isEmpty ?? true,
              let resolvedHost = components.host?.lowercased(),
              let baseHost = baseURL.host?.lowercased() else { return rawURL }
        let isMirror = options?.mirrorHosts.contains(where: {
            resolvedHost == $0 || resolvedHost.hasSuffix("." + $0)
        }) == true
        guard resolvedHost == baseHost || isMirror else { return rawURL }
        components.percentEncodedQuery = baseQuery
        return components.url?.absoluteString ?? rawURL
    }

    static func parseHLS(_ data: Data) throws -> ParsedHLS {
        guard let string = String(data: data, encoding: .utf8) else {
            throw SkyStreamVODValidationError.malformedManifest
        }
        let cleaned = string.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}"))
        )
        guard cleaned.hasPrefix("#EXTM3U") else {
            throw SkyStreamVODValidationError.malformedManifest
        }

        let lines = cleaned.components(separatedBy: .newlines)
        guard lines.count <= 20_000 else { throw SkyStreamVODValidationError.tooManyRoutes }
        var references: [HLSReference] = []
        var pendingVariantURI = false
        var hasMasterTag = false
        var hasMediaDuration = false
        var hasSegment = false
        var hasEndList = false
        var playlistType: String?
        var pendingSegmentDuration = false
        var segmentDurationCount = 0
        var mediaSegmentCount = 0
        var totalDuration: TimeInterval = 0

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            guard line.utf8.count <= 16_384 else {
                throw SkyStreamVODValidationError.malformedManifest
            }
            let upper = line.uppercased()

            if line.hasPrefix("#") {
                if upper.hasPrefix("#EXT-X-PART")
                    || upper.hasPrefix("#EXT-X-PRELOAD-HINT")
                    || upper.hasPrefix("#EXT-X-RENDITION-REPORT")
                    || upper.hasPrefix("#EXT-X-SERVER-CONTROL")
                    || upper.hasPrefix("#EXT-X-SKIP") {
                    throw SkyStreamVODValidationError.lowLatencyHLS
                }
                if upper.hasPrefix("#EXT-X-PLAYLIST-TYPE:") {
                    playlistType = String(upper.dropFirst("#EXT-X-PLAYLIST-TYPE:".count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if playlistType == "EVENT" { throw SkyStreamVODValidationError.liveHLS }
                    if playlistType != "VOD" { throw SkyStreamVODValidationError.malformedManifest }
                }
                if upper == "#EXT-X-ENDLIST" { hasEndList = true }
                if upper.hasPrefix("#EXTINF:") {
                    let valueStart = line.index(line.startIndex, offsetBy: "#EXTINF:".count)
                    let valueEnd = line[valueStart...].firstIndex(of: ",") ?? line.endIndex
                    guard !pendingSegmentDuration,
                          let duration = Double(line[valueStart..<valueEnd]
                            .trimmingCharacters(in: .whitespacesAndNewlines)),
                          duration.isFinite, duration > 0 else {
                        throw SkyStreamVODValidationError.malformedManifest
                    }
                    totalDuration += duration
                    guard totalDuration.isFinite, totalDuration <= 7 * 24 * 60 * 60 else {
                        throw SkyStreamVODValidationError.malformedManifest
                    }
                    hasMediaDuration = true
                    pendingSegmentDuration = true
                    segmentDurationCount += 1
                }
                if upper.hasPrefix("#EXT-X-STREAM-INF:") {
                    pendingVariantURI = true
                    hasMasterTag = true
                }
                if upper.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") { hasMasterTag = true }

                let attributes = try parseHLSAttributes(line)
                if upper.hasPrefix("#EXT-X-KEY:") || upper.hasPrefix("#EXT-X-SESSION-KEY:") {
                    let method = attributes["METHOD"]?.uppercased() ?? ""
                    let keyFormat = attributes["KEYFORMAT"]?.lowercased()
                    if method.hasPrefix("SAMPLE-AES")
                        || (keyFormat != nil && keyFormat != "identity") {
                        throw SkyStreamVODValidationError.drmHLS
                    }
                }

                if let uri = attributes["URI"], !uri.isEmpty {
                    let role: SkyStreamValidatedRouteRole
                    let recurse: Bool
                    if upper.hasPrefix("#EXT-X-STREAM-INF:")
                        || upper.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") {
                        role = .manifest
                        recurse = true
                    } else if upper.hasPrefix("#EXT-X-MEDIA:") {
                        let type = attributes["TYPE"]?.uppercased() ?? ""
                        if type == "SUBTITLES" && !uri.lowercased().contains(".m3u8") {
                            role = .subtitle
                            recurse = false
                        } else {
                            role = .manifest
                            recurse = true
                            hasMasterTag = true
                        }
                    } else if upper.hasPrefix("#EXT-X-KEY:") || upper.hasPrefix("#EXT-X-SESSION-KEY:") {
                        role = .encryptionKey
                        recurse = false
                    } else if upper.hasPrefix("#EXT-X-MAP:") {
                        role = .initialization
                        recurse = false
                    } else {
                        role = .mediaSegment
                        recurse = false
                    }
                    references.append(HLSReference(rawValue: uri, role: role, isNestedManifest: recurse))
                }
                continue
            }

            if pendingVariantURI {
                references.append(HLSReference(rawValue: line, role: .manifest, isNestedManifest: true))
                pendingVariantURI = false
                hasMasterTag = true
            } else {
                guard pendingSegmentDuration else {
                    throw SkyStreamVODValidationError.malformedManifest
                }
                references.append(HLSReference(rawValue: line, role: .mediaSegment, isNestedManifest: false))
                hasSegment = true
                pendingSegmentDuration = false
                mediaSegmentCount += 1
            }
        }

        guard !pendingVariantURI, !pendingSegmentDuration,
              segmentDurationCount == mediaSegmentCount else {
            throw SkyStreamVODValidationError.malformedManifest
        }
        let isFiniteMedia = hasMediaDuration && hasSegment && (hasEndList || playlistType == "VOD")
        guard hasMasterTag || isFiniteMedia else { throw SkyStreamVODValidationError.liveHLS }
        return ParsedHLS(references: references, isMaster: hasMasterTag, isFiniteMedia: isFiniteMedia)
    }

    static func parseHLSAttributes(_ line: String) throws -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        let input = line[line.index(after: colon)...]
        var parts: [Substring] = []
        var start = input.startIndex
        var index = input.startIndex
        var quoted = false
        while index < input.endIndex {
            let character = input[index]
            if character == "\"" { quoted.toggle() }
            if character == "," && !quoted {
                parts.append(input[start..<index])
                start = input.index(after: index)
            }
            index = input.index(after: index)
        }
        parts.append(input[start..<input.endIndex])

        var result: [String: String] = [:]
        for part in parts {
            guard let equals = part.firstIndex(of: "=") else { continue }
            let key = part[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            var value = part[part.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value.removeFirst()
                value.removeLast()
            }
            guard result[key] == nil else {
                throw SkyStreamVODValidationError.malformedManifest
            }
            result[key] = value
        }
        return result
    }
}

private extension SkyStreamVODValidator {
    static func looksLikeHLS(_ data: Data) -> Bool {
        guard let prefix = String(data: data.prefix(4_096), encoding: .utf8) else { return false }
        let trimmed = prefix.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}"))
        )
        return trimmed.hasPrefix("#EXTM3U")
    }

    static func looksLikeDASH(_ data: Data) -> Bool {
        guard let prefix = String(data: data.prefix(65_536), encoding: .utf8)?.lowercased() else { return false }
        return prefix.contains("<mpd") && !prefix.contains("<!doctype")
    }

    static func responseIndicatesHLS(_ response: SkyStreamHTTPResponse) -> Bool {
        let type = response.header("Content-Type")?.lowercased() ?? ""
        return type.contains("mpegurl") || type.contains("vnd.apple.mpegurl")
    }

    static func responseIndicatesDASH(_ response: SkyStreamHTTPResponse) -> Bool {
        let type = response.header("Content-Type")?.lowercased() ?? ""
        return type.contains("dash+xml") || type.contains("application/dash")
    }

    private static func proveFiniteDirectMedia(
        _ response: SkyStreamHTTPResponse,
        finalURL: SkyStreamValidatedRemoteURL,
        hint: MediaHint
    ) throws -> Int64 {
        guard !looksLikeMarkupOrPlaylist(response.data) else {
            throw SkyStreamVODValidationError.unsupportedMediaType
        }
        let contentType = response.header("Content-Type")?
            .split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let explicitlyMedia = contentType.hasPrefix("video/") || contentType.hasPrefix("audio/")
        let genericBinary = contentType == "application/octet-stream" || contentType == "binary/octet-stream"
            || contentType.isEmpty
        guard explicitlyMedia || (genericBinary && (hint == .direct || hasRecognizedMediaSignature(response.data))) else {
            throw SkyStreamVODValidationError.unsupportedMediaType
        }

        if response.statusCode == 206,
           let contentRange = response.header("Content-Range"),
           let total = parseContentRangeTotal(contentRange), total > 0 {
            return total
        }

        if response.statusCode == 200,
           response.header("Accept-Ranges")?.lowercased().contains("bytes") == true,
           let value = response.header("Content-Length"),
           let length = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)),
           length > 0 {
            return length
        }

        throw SkyStreamVODValidationError.nonFiniteMedia
    }

    static func looksLikeMarkupOrPlaylist(_ data: Data) -> Bool {
        guard let text = String(data: data.prefix(1_024), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else { return false }
        return text.hasPrefix("#extm3u")
            || text.hasPrefix("<!doctype")
            || text.hasPrefix("<html")
            || text.hasPrefix("<?xml")
            || text.hasPrefix("<mpd")
            || text.hasPrefix("{")
            || text.hasPrefix("[")
    }

    static func hasRecognizedMediaSignature(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(16))
        if bytes.count >= 8, String(bytes: bytes[4..<8], encoding: .ascii) == "ftyp" { return true }
        if bytes.starts(with: [0x1a, 0x45, 0xdf, 0xa3]) { return true }
        if bytes.starts(with: Array("OggS".utf8)) || bytes.starts(with: Array("fLaC".utf8)) { return true }
        if bytes.starts(with: Array("ID3".utf8)) { return true }
        if bytes.count >= 12,
           String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
           String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE" { return true }
        if bytes.count >= 2, bytes[0] == 0xff, bytes[1] & 0xe0 == 0xe0 { return true }
        if bytes.first == 0x47 { return true }
        return false
    }

    static func parseContentRangeTotal(_ value: String) -> Int64? {

        let components = value.lowercased().split(separator: " ", maxSplits: 1)
        guard components.count == 2, components[0] == "bytes" else { return nil }
        let rangeAndTotal = components[1].split(separator: "/", maxSplits: 1)
        guard rangeAndTotal.count == 2, rangeAndTotal[1] != "*",
              let total = Int64(rangeAndTotal[1]), total > 0 else { return nil }
        let bounds = rangeAndTotal[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start >= 0, end >= start, end < total else { return nil }
        return total
    }
}

private struct DASHReference: Sendable {
    let rawValue: String
    let role: SkyStreamValidatedRouteRole
}

private struct ParsedDASH: Sendable {
    let baseURLs: [String]
    let references: [DASHReference]
}

private final class SkyStreamDASHParserDelegate: NSObject, XMLParserDelegate {
    private let maximumElements: Int
    private let maximumDepth: Int
    private let maximumReferences: Int

    private(set) var baseURLs: [String] = []
    private(set) var references: [DASHReference] = []
    private(set) var failure: SkyStreamVODValidationError?
    private var depth = 0
    private var elementCount = 0
    private var currentTextElement: String?
    private var textBuffer = ""
    private var sawMPD = false
    private var isStatic = false
    private var presentationDuration: TimeInterval?
    private var periodDurations: [TimeInterval] = []
    private var periodCount = 0

    init(limits: SkyStreamVODValidationLimits) {
        maximumElements = min(10_000, limits.maximumRoutes * 4)
        maximumDepth = 32
        maximumReferences = limits.maximumRoutes
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard failure == nil else { parser.abortParsing(); return }
        depth += 1
        elementCount += 1
        guard depth <= maximumDepth, elementCount <= maximumElements else {
            fail(.unsafeXML, parser: parser)
            return
        }

        let name = (qName ?? elementName).lowercased()
        if attributeDict.contains(where: { key, value in
            let key = key.lowercased()
            let value = value.lowercased()
            return key.contains("xlink") || value.hasPrefix("xlink:")
        }) {
            fail(.unsafeXML, parser: parser)
            return
        }
        if name == "contentprotection" || name.hasSuffix(":contentprotection")
            || name == "pssh" || name.hasSuffix(":pssh") {
            fail(.drmContent, parser: parser)
            return
        }

        if name == "mpd" || name.hasSuffix(":mpd") {
            sawMPD = true
            isStatic = attributeValue("type", in: attributeDict)?.lowercased() == "static"
            if let duration = attributeValue("mediaPresentationDuration", in: attributeDict) {
                presentationDuration = SkyStreamVODValidator.parseISO8601Duration(duration)
            }
            if attributeValue("minimumUpdatePeriod", in: attributeDict) != nil {
                fail(.nonStaticDASH, parser: parser)
                return
            }
        }
        if name == "period" || name.hasSuffix(":period") {
            periodCount += 1
            if let duration = attributeValue("duration", in: attributeDict),
               let parsed = SkyStreamVODValidator.parseISO8601Duration(duration) {
                periodDurations.append(parsed)
            }
        }
        if name == "segmenttemplate" || name.hasSuffix(":segmenttemplate") {
            for key in ["media", "initialization", "index"] {
                guard let value = attributeValue(key, in: attributeDict), !value.isEmpty else { continue }
                if value.contains("$") {
                    fail(.unsupportedDASHTemplate, parser: parser)
                    return
                }
                appendReference(value, role: key == "initialization" ? .initialization : .dashResource, parser: parser)
            }
        }
        if name == "s" || name.hasSuffix(":s"),
           attributeValue("r", in: attributeDict) == "-1" {
            fail(.unsupportedDASHTemplate, parser: parser)
            return
        }
        if name == "segmenturl" || name.hasSuffix(":segmenturl") {
            for key in ["media", "index"] {
                if let value = attributeValue(key, in: attributeDict), !value.isEmpty {
                    appendReference(value, role: .dashResource, parser: parser)
                }
            }
        }
        if name == "initialization" || name.hasSuffix(":initialization") {
            if let value = attributeValue("sourceURL", in: attributeDict), !value.isEmpty {
                appendReference(value, role: .initialization, parser: parser)
            }
        }
        for (key, value) in attributeDict where key.lowercased() == "href" {
            appendReference(value, role: .dashResource, parser: parser)
        }

        if name == "baseurl" || name.hasSuffix(":baseurl") {
            currentTextElement = "baseurl"
            textBuffer = ""
        } else if name == "location" || name.hasSuffix(":location")
                    || name == "patchlocation" || name.hasSuffix(":patchlocation")
                    || name == "utctiming" || name.hasSuffix(":utctiming") {

            fail(.nonStaticDASH, parser: parser)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentTextElement != nil, textBuffer.utf8.count < 16_384 else { return }
        textBuffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = (qName ?? elementName).lowercased()
        if currentTextElement == "baseurl", (name == "baseurl" || name.hasSuffix(":baseurl")) {
            let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                if value.contains("$") {
                    fail(.unsupportedDASHTemplate, parser: parser)
                } else if baseURLs.count >= 8 {
                    fail(.tooManyRoutes, parser: parser)
                } else {
                    baseURLs.append(value)
                }
            }
            currentTextElement = nil
            textBuffer = ""
        }
        depth = max(0, depth - 1)
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        guard failure == nil else { return }
        guard sawMPD, isStatic else {
            failure = .nonStaticDASH
            return
        }
        let periodTotal = periodDurations.reduce(0, +)
        let finiteDuration = presentationDuration ?? (periodCount > 0 && periodDurations.count == periodCount ? periodTotal : nil)
        guard let finiteDuration, finiteDuration.isFinite, finiteDuration > 0 else {
            failure = .indeterminateDuration
            return
        }
    }

    func parser(
        _ parser: XMLParser,
        resolveExternalEntityName name: String,
        systemID: String?
    ) -> Data? {
        fail(.unsafeXML, parser: parser)
        return nil
    }

    private func appendReference(
        _ value: String,
        role: SkyStreamValidatedRouteRole,
        parser: XMLParser
    ) {
        guard references.count < maximumReferences, value.utf8.count <= 16_384 else {
            fail(.tooManyRoutes, parser: parser)
            return
        }
        references.append(DASHReference(rawValue: value, role: role))
    }

    private func attributeValue(_ name: String, in values: [String: String]) -> String? {
        values.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func fail(_ error: SkyStreamVODValidationError, parser: XMLParser) {
        if failure == nil { failure = error }
        parser.abortParsing()
    }
}

private extension SkyStreamVODValidator {
    static func parseDASH(
        _ data: Data,
        limits: SkyStreamVODValidationLimits
    ) throws -> ParsedDASH {
        guard data.count <= limits.maximumManifestBytes,
              let text = String(data: data, encoding: .utf8) else {
            throw SkyStreamVODValidationError.oversizedManifest
        }
        let lower = text.lowercased()
        guard lower.contains("<mpd"),
              !lower.contains("<!doctype"), !lower.contains("<!entity"),
              !lower.contains("xlink:"), !lower.contains("contentprotection"),
              !lower.contains("widevine"), !lower.contains("playready"),
              !lower.contains("fairplay"), !lower.contains("cenc:pssh") else {
            throw SkyStreamVODValidationError.unsafeXML
        }

        let delegate = SkyStreamDASHParserDelegate(limits: limits)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        let parsed = parser.parse()
        if let failure = delegate.failure { throw failure }
        guard parsed, parser.parserError == nil else {
            throw SkyStreamVODValidationError.malformedManifest
        }
        return ParsedDASH(baseURLs: delegate.baseURLs, references: delegate.references)
    }

    func validateDASHReferences(
        _ parsedManifest: ParsedDASH,
        manifest: SkyStreamValidatedRemoteURL,
        headers: SkyStreamSanitizedHeaders,
        proxyOptions: SkyStreamValidatedProxyOptions?,
        limits: SkyStreamVODValidationLimits
    ) async throws -> [SkyStreamValidatedRoute] {
        var validatedBases: [SkyStreamValidatedRemoteURL] = []
        for rawBase in parsedManifest.baseURLs {
            validatedBases.append(
                try await policy.validate(rawBase, purpose: .mediaSegment, relativeTo: manifest.url)
            )
        }
        let basedSources: [(url: URL, origin: SkyStreamRemoteOrigin, headers: SkyStreamSanitizedHeaders)]
        if validatedBases.isEmpty {
            basedSources = [(manifest.url, manifest.origin, headers)]
        } else {
            basedSources = validatedBases.map {
                (
                    $0.url,
                    $0.origin,
                    proxyOptions == nil
                        ? headers.scopedForRedirect(from: manifest.origin, to: $0.origin)
                        : headers
                )
            }
        }
        let parsed = try Self.parseDASHBaseAndReferences(
            parsedManifest.references,
            basedSources: basedSources
        )
        guard parsed.count <= limits.maximumRoutes else {
            throw SkyStreamVODValidationError.tooManyRoutes
        }

        var routes: [SkyStreamValidatedRoute] = validatedBases.map {
            SkyStreamValidatedRoute(
                remoteURL: $0,
                role: .dashResource,
                headers: proxyOptions == nil
                    ? headers.scopedForRedirect(from: manifest.origin, to: $0.origin)
                    : headers,
                proxyOptions: proxyOptions
            )
        }
        var start = 0
        while start < parsed.count {
            let end = min(start + limits.maximumConcurrentChildChecks, parsed.count)
            let chunk = Array(parsed[start..<end])
            let values = try await withThrowingTaskGroup(
                of: SkyStreamValidatedRoute.self,
                returning: [SkyStreamValidatedRoute].self
            ) { group in
                for reference in chunk {
                    group.addTask {
                        let url = try await self.policy.validate(
                            reference.rawValue,
                            purpose: .mediaSegment,
                            relativeTo: reference.baseURL
                        )
                        let routeHeaders = proxyOptions == nil
                            ? reference.headers.scopedForRedirect(
                                from: reference.baseOrigin,
                                to: url.origin
                            )
                            : reference.headers
                        return SkyStreamValidatedRoute(
                            remoteURL: url,
                            role: reference.role,
                            headers: routeHeaders,
                            proxyOptions: proxyOptions
                        )
                    }
                }
                var result: [SkyStreamValidatedRoute] = []
                for try await value in group { result.append(value) }
                return result
            }
            routes.append(contentsOf: values)
            start = end
        }
        return try Self.mergingRoutes(routes, maximum: limits.maximumRoutes)
    }

    private struct BasedDASHReference {
        let rawValue: String
        let role: SkyStreamValidatedRouteRole
        let baseURL: URL
        let baseOrigin: SkyStreamRemoteOrigin
        let headers: SkyStreamSanitizedHeaders
    }

    private static func parseDASHBaseAndReferences(
        _ references: [DASHReference],
        basedSources: [(url: URL, origin: SkyStreamRemoteOrigin, headers: SkyStreamSanitizedHeaders)]
    ) throws -> [BasedDASHReference] {

        try basedSources.flatMap { source in
            try references.map { reference in
                guard !reference.rawValue.contains("$") else {
                    throw SkyStreamVODValidationError.unsupportedDASHTemplate
                }
                return BasedDASHReference(
                    rawValue: reference.rawValue,
                    role: reference.role,
                    baseURL: source.url,
                    baseOrigin: source.origin,
                    headers: source.headers
                )
            }
        }
    }

    static func parseISO8601Duration(_ value: String) -> TimeInterval? {
        let pattern = #"^P(?:(\d+(?:\.\d+)?)D)?(?:T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?)?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value)
              ), match.range.location != NSNotFound else { return nil }

        func number(at index: Int) -> Double {
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else { return 0 }
            return Double(value[swiftRange]) ?? 0
        }
        let seconds = number(at: 1) * 86_400 + number(at: 2) * 3_600
            + number(at: 3) * 60 + number(at: 4)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }
}
