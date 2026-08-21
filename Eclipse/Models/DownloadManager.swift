import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

enum DownloadStatus: String, Codable {
    case queued
    case downloading
    case paused
    case completed
    case failed
}

enum DownloadEnqueueResult {
    case enqueued
    case alreadyExists
    case adoptedExistingFile
}

enum DownloadProviderTransportKind: String, Codable {
    case skyStreamDirect
    case skyStreamHLS
}

enum ProtectedDownloadProviderKind: String, Codable {
    case service
    case stremio
    case nuvio
    case skyStream
    case unresolvedLegacy
}

enum ProtectedDownloadTransportKind: String, Codable {
    case direct
    case hls
}

typealias NuvioDownloadTransportKind = ProtectedDownloadTransportKind

enum ProtectedDownloadProfileAuthority: Equatable {
    case authorized
    case waitingForOwner
    case bindLegacyOwner(UUID)
}

typealias NuvioDownloadProfileAuthority = ProtectedDownloadProfileAuthority

struct ProtectedPersistableTransport: Codable, Equatable {
    var streamURL: String
    var headers: [String: String]
    var subtitleURL: String?
    var subtitleHeaders: [String: String]?
    var hlsVariantURL: String?
}

typealias NuvioPersistableTransport = ProtectedPersistableTransport

enum ProtectedDownloadPersistencePolicy {
    static func inferredProviderKind(
        explicitKind: ProtectedDownloadProviderKind? = nil,
        hasLegacyNuvioMarker: Bool = false,
        sourceID: String?,
        reference: ProviderContentReference?
    ) -> ProtectedDownloadProviderKind? {
        if let explicitKind { return explicitKind }
        if hasLegacyNuvioMarker
            || sourceID?.hasPrefix("nuvio:") == true
            || reference?.kind == .nuvio {
            return .nuvio
        }
        if sourceID?.hasPrefix("service:") == true
            || reference?.kind == .service {
            return .service
        }
        if sourceID?.hasPrefix("stremio:") == true
            || reference?.kind == .stremio {
            return .stremio
        }
        return nil
    }

    static func claimsProtectedProvider(
        explicitKind: ProtectedDownloadProviderKind? = nil,
        hasLegacyNuvioMarker: Bool = false,
        sourceID: String?,
        reference: ProviderContentReference?
    ) -> Bool {
        inferredProviderKind(
            explicitKind: explicitKind,
            hasLegacyNuvioMarker: hasLegacyNuvioMarker,
            sourceID: sourceID,
            reference: reference
        ) != nil
    }

    static func claimsNuvio(
        sourceID: String?,
        reference: ProviderContentReference?
    ) -> Bool {
        sourceID?.hasPrefix("nuvio:") == true || reference?.kind == .nuvio
    }

    static func transportKind(for streamURL: String) -> ProtectedDownloadTransportKind {
        streamURL.lowercased().contains(".m3u8") ? .hls : .direct
    }

    static func profileAuthority(
        ownerProfileID: UUID?,
        activeProfileID: UUID
    ) -> ProtectedDownloadProfileAuthority {
        guard let ownerProfileID else { return .bindLegacyOwner(activeProfileID) }
        return ownerProfileID == activeProfileID ? .authorized : .waitingForOwner
    }

    static func sanitizedForPersistence(
        claimsNuvio: Bool,
        transport: ProtectedPersistableTransport
    ) -> ProtectedPersistableTransport {
        guard claimsNuvio else { return transport }
        return ProtectedPersistableTransport(
            streamURL: "",
            headers: [:],
            subtitleURL: nil,
            subtitleHeaders: nil,
            hlsVariantURL: nil
        )
    }

    static func sanitizedForPersistence(
        claimsProtectedProvider: Bool,
        transport: ProtectedPersistableTransport
    ) -> ProtectedPersistableTransport {
        sanitizedForPersistence(
            claimsNuvio: claimsProtectedProvider,
            transport: transport
        )
    }

    static func requiresFreshResolution(claimsNuvio: Bool, streamURL: String) -> Bool {
        claimsNuvio && streamURL.isEmpty
    }

    static func requiresFreshResolution(
        claimsProtectedProvider: Bool,
        streamURL: String
    ) -> Bool {
        claimsProtectedProvider && streamURL.isEmpty
    }

    static func requiresReselectionAfterRelaunch(
        providerKind: ProtectedDownloadProviderKind?,
        hasAuthoritativeReference: Bool,
        streamURL: String
    ) -> Bool {
        (providerKind == .service
            || providerKind == .stremio
            || providerKind == .unresolvedLegacy)
            && !hasAuthoritativeReference
            && streamURL.isEmpty
    }

    static func mayAdoptRestoredBackgroundTask(claimsNuvio: Bool) -> Bool {
        !claimsNuvio
    }

    static func mayAdoptRestoredBackgroundTask(claimsProtectedProvider: Bool) -> Bool {
        !claimsProtectedProvider
    }

    static func mayClaimDirectTaskCallback(
        claimsNuvio: Bool,
        registeredProtectedTaskIdentifier: Int?,
        callbackTaskIdentifier: Int
    ) -> Bool {
        !claimsNuvio || registeredProtectedTaskIdentifier == callbackTaskIdentifier
    }

    static func mayClaimDirectTaskCallback(
        claimsProtectedProvider: Bool,
        registeredProtectedTaskIdentifier: Int?,
        callbackTaskIdentifier: Int
    ) -> Bool {
        !claimsProtectedProvider
            || registeredProtectedTaskIdentifier == callbackTaskIdentifier
    }

    static func validatedEnqueueAuthorityIsCurrent(
        ownerProfileID: UUID,
        capturedScopeGeneration: Int,
        activeProfileID: UUID,
        currentScopeGeneration: Int
    ) -> Bool {
        ownerProfileID == activeProfileID
            && capturedScopeGeneration == currentScopeGeneration
    }

    /// Identifies only the old Stremio rows that carried no provider marker at
    /// all. Matching is exact against the active profile's configured addon
    /// origins so an ordinary Service/manual URL cannot acquire LAN authority.
    static func legacyStremioSourceID(
        serviceBaseURL: String,
        configuredAddons: [UUID: String]
    ) -> String? {
        let candidate = StremioClient.normalizedConfiguredURL(from: serviceBaseURL)
        guard candidate.utf8.count <= 16_384,
              let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else {
            return nil
        }
        let matches = configuredAddons.compactMap { addonID, rawURL -> UUID? in
            StremioClient.normalizedConfiguredURL(from: rawURL) == candidate
                ? addonID
                : nil
        }
        guard matches.count == 1, let addonID = matches.first else { return nil }
        return "stremio:\(addonID.uuidString)"
    }
}

typealias NuvioDownloadPersistencePolicy = ProtectedDownloadPersistencePolicy

enum ProtectedDownloadAttemptLifecycle {
    static func mayReleaseAttempt(mainFinished: Bool, subtitleSessionCount: Int) -> Bool {
        mainFinished && subtitleSessionCount == 0
    }
}

typealias NuvioDownloadAttemptLifecycle = ProtectedDownloadAttemptLifecycle

#if os(iOS) && !targetEnvironment(macCatalyst)
enum NuvioDownloadAuthorityState: Equatable {
    case notNuvio
    case authorized
    case invalid

    static func classify(
        sourceID: String?,
        reference: ProviderContentReference?
    ) -> Self {
        let sourceClaimsNuvio = sourceID?.hasPrefix("nuvio:") == true
        let referenceClaimsNuvio = reference?.kind == .nuvio
        guard sourceClaimsNuvio || referenceClaimsNuvio else { return .notNuvio }
        guard sourceClaimsNuvio,
              referenceClaimsNuvio,
              let sourceID,
              let reference,
              reference.sourceID == sourceID,
              reference.nuvio?.sourceID == sourceID,
              reference.nuvio?.isStructurallyValid == true else {
            return .invalid
        }
        return .authorized
    }
}

enum ProtectedDownloadAuthorityState: Equatable {
    case notProtected
    case authorized(ProtectedDownloadProviderKind)
    case legacyService
    case legacyStremio
    case invalid

    static func classify(
        explicitKind: ProtectedDownloadProviderKind?,
        hasLegacyNuvioMarker: Bool,
        sourceID: String?,
        reference: ProviderContentReference?
    ) -> Self {
        let sourceClaimsNuvio = sourceID?.hasPrefix("nuvio:") == true
        let referenceClaimsNuvio = reference?.kind == .nuvio
        let sourceClaimsService = sourceID?.hasPrefix("service:") == true
        let referenceClaimsService = reference?.kind == .service
        let sourceClaimsStremio = sourceID?.hasPrefix("stremio:") == true
        let referenceClaimsStremio = reference?.kind == .stremio
        let claimsNuvio = explicitKind == .nuvio
            || hasLegacyNuvioMarker
            || sourceClaimsNuvio
            || referenceClaimsNuvio
        let claimsService = explicitKind == .service
            || sourceClaimsService
            || referenceClaimsService
        let claimsStremio = explicitKind == .stremio
            || sourceClaimsStremio
            || referenceClaimsStremio

        if explicitKind == .unresolvedLegacy {
            return .invalid
        }

        if explicitKind == .skyStream {
            guard !claimsNuvio,
                  !claimsService,
                  !claimsStremio,
                  let reference,
                  reference.kind == .skyStream,
                  reference.sourceID == sourceID,
                  reference.skyStream?.sourceID == sourceID,
                  reference.skyStream?.isStructurallyValid == true else {
                return .invalid
            }
            return .authorized(.skyStream)
        }

        let claimedKinds = [claimsNuvio, claimsService, claimsStremio].filter { $0 }.count
        guard claimedKinds > 0 else { return .notProtected }
        guard claimedKinds == 1 else { return .invalid }

        if claimsNuvio {
            guard sourceClaimsNuvio,
                  referenceClaimsNuvio,
                  let sourceID,
                  let reference,
                  reference.sourceID == sourceID,
                  reference.nuvio?.sourceID == sourceID,
                  reference.nuvio?.isStructurallyValid == true else {
                return .invalid
            }
            return .authorized(.nuvio)
        }

        if claimsStremio {
            guard sourceClaimsStremio else { return .invalid }
            guard let reference else { return .legacyStremio }
            guard referenceClaimsStremio,
                  reference.sourceID == sourceID,
                  reference.hasValidStremioSelection else {
                return .invalid
            }
            return .authorized(.stremio)
        }

        guard sourceClaimsService else { return .invalid }
        guard let reference else { return .legacyService }
        guard referenceClaimsService,
              reference.sourceID == sourceID,
              reference.serviceHref?.isEmpty == false else {
            return .invalid
        }
        return .authorized(.service)
    }
}
#endif

struct ProtectedDownloadTransportPlan: Equatable {
    let authoritativeURL: URL
    let authoritativeHeaders: [String: String]
    let dispatchURL: URL
    let dispatchHeaders: [String: String]
    let mayUseResumeData: Bool
    let mustRegenerateHLSCheckpoint: Bool

    static func protectedAttempt(
        authoritativeURL: URL,
        authoritativeHeaders: [String: String],
        proxyURL: URL
    ) -> Self {
        Self(
            authoritativeURL: authoritativeURL,
            authoritativeHeaders: authoritativeHeaders,
            dispatchURL: proxyURL,
            dispatchHeaders: [:],
            mayUseResumeData: false,
            mustRegenerateHLSCheckpoint: true
        )
    }

    static func ordinary(
        url: URL,
        headers: [String: String]
    ) -> Self {
        Self(
            authoritativeURL: url,
            authoritativeHeaders: headers,
            dispatchURL: url,
            dispatchHeaders: headers,
            mayUseResumeData: true,
            mustRegenerateHLSCheckpoint: false
        )
    }
}

typealias NuvioDownloadTransportPlan = ProtectedDownloadTransportPlan

#if os(iOS) && !targetEnvironment(macCatalyst)
private final class NuvioDownloadChallengeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedURL: URL?

    func record(_ url: URL) {
        lock.lock()
        capturedURL = url
        lock.unlock()
    }

    var url: URL? {
        lock.lock()
        defer { lock.unlock() }
        return capturedURL
    }
}

private final class NuvioBoundedSubtitleFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Output {
        let data: Data
        let response: HTTPURLResponse
    }

    private enum FetchError: LocalizedError {
        case invalidResponse
        case rejectedStatus(Int)
        case rejectedContentType(String)
        case responseTooLarge

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "The subtitle server returned an invalid response."
            case .rejectedStatus(let status):
                return "The subtitle server returned HTTP \(status)."
            case .rejectedContentType:
                return "The subtitle server returned unsupported content."
            case .responseTooLarge:
                return "The subtitle exceeded Eclipse's 5 MB safety limit."
            }
        }
    }

    private let maximumBytes: Int
    private let completion: (Result<Output, Error>) -> Void
    private let lock = NSLock()
    private var completed = false
    private var receivedData = Data()
    private var receivedResponse: HTTPURLResponse?
    private var task: URLSessionDataTask?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(maximumBytes: Int = 5_000_000, completion: @escaping (Result<Output, Error>) -> Void) {
        self.maximumBytes = max(1, maximumBytes)
        self.completion = completion
        super.init()
    }

    func start(_ request: URLRequest) {
        let task = session.dataTask(with: request)
        lock.lock()
        self.task = task
        lock.unlock()
        task.resume()
    }

    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
        finish(.failure(URLError(.cancelled)))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(FetchError.invalidResponse))
            return
        }
        guard (200...299).contains(http.statusCode) else {
            completionHandler(.cancel)
            finish(.failure(FetchError.rejectedStatus(http.statusCode)))
            return
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            completionHandler(.cancel)
            finish(.failure(FetchError.responseTooLarge))
            return
        }
        let mimeType = (response.mimeType ?? "application/octet-stream").lowercased()
        let acceptedTypes: Set<String> = [
            "text/plain", "text/vtt", "text/webvtt", "text/srt", "text/x-srt",
            "text/ass", "text/x-ass", "text/ssa", "text/x-ssa",
            "application/octet-stream", "application/vtt", "application/webvtt",
            "application/x-subrip", "application/ass", "application/x-ass",
            "application/ssa", "application/x-ssa", "application/ttml+xml",
            "application/xml"
        ]
        let accepted = acceptedTypes.contains(mimeType)
        guard accepted else {
            completionHandler(.cancel)
            finish(.failure(FetchError.rejectedContentType(mimeType)))
            return
        }
        lock.lock()
        receivedResponse = http
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let exceedsLimit = receivedData.count > maximumBytes - data.count
        if !exceedsLimit {
            receivedData.append(data)
        }
        lock.unlock()
        if exceedsLimit {
            dataTask.cancel()
            finish(.failure(FetchError.responseTooLarge))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        finish(.failure(FetchError.rejectedStatus(response.statusCode)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
            return
        }
        lock.lock()
        let response = receivedResponse
        let data = receivedData
        lock.unlock()
        guard let response else {
            finish(.failure(FetchError.invalidResponse))
            return
        }
        finish(.success(Output(data: data, response: response)))
    }

    private func finish(_ result: Result<Output, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        task = nil
        lock.unlock()
        session.invalidateAndCancel()
        completion(result)
    }
}
#endif

enum AutoModeDownloadValidationResult: Equatable {
    case valid
    case invalid(reason: String)

    case cloudflareChallenge(url: URL)
    case cancelled
}

enum AutoModeDownloadEnqueueResult {
    case accepted(DownloadEnqueueResult)
    case invalid(reason: String)
    case cloudflareChallenge(url: URL)
    case cancelled
}

enum DownloadByteCountFormatter {
    private static let unitNames = ["bytes", "KB", "MB", "GB", "TB", "PB"]
    private static let unitBase = 1_000.0
    private static let displayLocale = Locale(identifier: "en_US_POSIX")

    static func string(fromByteCount byteCount: Int64) -> String {
        let nonnegativeByteCount = max(byteCount, 0)
        guard nonnegativeByteCount >= 1_000 else {
            let unit = nonnegativeByteCount == 1 ? "byte" : "bytes"
            return "\(nonnegativeByteCount) \(unit)"
        }

        var value = Double(nonnegativeByteCount)
        var unitIndex = 0
        while unitIndex < unitNames.count - 1, value >= unitBase {
            value /= unitBase
            unitIndex += 1
        }

        if unitIndex < unitNames.count - 1, value >= 999.995 {
            value /= unitBase
            unitIndex += 1
        }

        let formatter = NumberFormatter()
        formatter.locale = displayLocale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        let number = formatter.string(from: NSNumber(value: value))
            ?? String(format: "%.2f", locale: displayLocale, value)
        return "\(number) \(unitNames[unitIndex])"
    }
}

struct DownloadItem: Codable, Identifiable {
    let id: String
    let tmdbId: Int
    let isMovie: Bool
    let title: String
    let displayTitle: String
    let posterURL: String?
    var seasonNumber: Int?
    var episodeNumber: Int?
    let episodeName: String?
    var streamURL: String
    var headers: [String: String]
    var subtitleURL: String?
    var subtitleHeaders: [String: String]?
    var serviceBaseURL: String

    var sourceId: String? = nil
    var serviceContentHref: String? = nil

    var lastSourceId: String? = nil

    var lastContentReference: ProviderContentReference? = nil
    var providerTransportKind: DownloadProviderTransportKind? = nil

    /// Provider URLs and credentials are deliberately not persisted. These
    /// non-secret markers retain enough authority to re-resolve safely.
    var protectedProviderKind: ProtectedDownloadProviderKind? = nil
    var protectedTransportKind: ProtectedDownloadTransportKind? = nil
    var protectedOwnerProfileID: UUID? = nil

    /// Legacy Nuvio-only marker names are retained for backward-compatible
    /// decoding. New snapshots also carry the provider-neutral markers above.
    var nuvioTransportKind: NuvioDownloadTransportKind? = nil
    var nuvioOwnerProfileID: UUID? = nil

    var validatedExpectedContentLength: Int64? = nil
    var streamName: String? = nil
    var originalAudioLanguage: String? = nil

    var kidsPolicyDetails: KidsPolicyDetails? = nil
    var episodePlaybackContext: EpisodePlaybackContext?
    var status: DownloadStatus
    var progress: Double
    var totalBytes: Int64
    var downloadedBytes: Int64
    var localFileName: String?
    var subtitleFileName: String?

    var reservedVideoFileName: String? = nil
    var reservedSubtitleFileName: String? = nil

    var retryNotBefore: Date? = nil
    var rateLimitRetryCount: Int? = nil
    var error: String?
    var dateAdded: Date
    var dateCompleted: Date?
    let isAnime: Bool

    var hlsResumeSegmentIndex: Int?
    var hlsResumeByteCount: Int64?
    var hlsVariantURL: String?
    var hlsTotalSegments: Int?

    var effectiveProtectedProviderKind: ProtectedDownloadProviderKind? {
        if protectedProviderKind == nil,
           providerTransportKind == .skyStreamDirect,
           lastContentReference?.kind == .skyStream {
            return .skyStream
        }
        return ProtectedDownloadPersistencePolicy.inferredProviderKind(
            explicitKind: protectedProviderKind,
            hasLegacyNuvioMarker: nuvioTransportKind != nil || nuvioOwnerProfileID != nil,
            sourceID: lastSourceId ?? sourceId,
            reference: lastContentReference
        )
    }

    var effectiveProtectedTransportKind: ProtectedDownloadTransportKind? {
        protectedTransportKind ?? nuvioTransportKind
    }

    var effectiveProtectedOwnerProfileID: UUID? {
        protectedOwnerProfileID ?? nuvioOwnerProfileID
    }

    var claimsProtectedProviderTransport: Bool {
        effectiveProtectedProviderKind != nil
    }

    var isHLS: Bool {
        providerTransportKind == .skyStreamHLS
            || protectedTransportKind == .hls
            || nuvioTransportKind == .hls
            || streamURL.lowercased().contains(".m3u8")
    }

    var formattedSize: String {
        if totalBytes > 0 {
            return "\(DownloadByteCountFormatter.string(fromByteCount: downloadedBytes)) / \(DownloadByteCountFormatter.string(fromByteCount: totalBytes))"
        } else if downloadedBytes > 0 {
            return DownloadByteCountFormatter.string(fromByteCount: downloadedBytes)
        }
        return ""
    }

    var playerTitleBase: String {
        guard isAnime else { return title }
        guard !isMovie else { return nonEmptyTrimmed(displayTitle) ?? title }
        return animeDisplayTitleWithoutEpisodeSuffix
    }

    private var animeDisplayTitleWithoutEpisodeSuffix: String {
        var base = nonEmptyTrimmed(displayTitle) ?? title
        let suffixPatterns = [
            #"(?i)\s*-\s*S\d{1,2}E\d{1,4}$"#,
            #"(?i)\s*S\d{1,2}E\d{1,4}$"#,
            #"(?i)\s*-\s*E\d{1,4}$"#,
            #"(?i)\s*E\d{1,4}$"#,
            #"(?i)\s*Episode\s+\d{1,4}$"#
        ]

        for pattern in suffixPatterns {
            if let range = base.range(of: pattern, options: .regularExpression) {
                base.removeSubrange(range)
                break
            }
        }

        return nonEmptyTrimmed(base) ?? title
    }

    private func nonEmptyTrimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    var mediaInfo: MediaInfo {
        if isMovie {
            return .movie(id: tmdbId, title: playerTitleBase, posterURL: posterURL, isAnime: isAnime)
        } else {
            return .episode(
                showId: tmdbId,
                seasonNumber: seasonNumber ?? 1,
                episodeNumber: episodeNumber ?? 1,
                showTitle: playerTitleBase,
                showPosterURL: posterURL,
                isAnime: isAnime
            )
        }
    }
}

enum DownloadMetadataPersistencePolicy {
    enum Bounds {
        /// This file is local restore input, not a trusted database. A normal
        /// library is far smaller; this leaves generous legacy headroom while
        /// bounding the allocation made before decoding.
        static let fileBytes = 8 * 1_024 * 1_024
        static let items = 2_000
        static let identifierBytes = 512
        static let titleBytes = 8 * 1_024
        static let urlBytes = 64 * 1_024
        static let headerCount = 64
        static let headerValueBytes = 8 * 1_024
        static let headerAggregateBytes = 32 * 1_024
        static let relativePathBytes = 4 * 1_024
        static let byteCount: Int64 = 1 << 50
    }

    struct NormalizedItems {
        let items: [DownloadItem]
        let wasChanged: Bool
    }

    private struct LossyDecodedItems: Decodable {
        let items: [DownloadItem]
        let droppedCount: Int

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var decoded: [DownloadItem] = []
            decoded.reserveCapacity(min(container.count ?? 0, Bounds.items))
            var dropped = 0
            while !container.isAtEnd {
                // Taking a child decoder advances the outer array even when
                // that individual DownloadItem is corrupt, so one damaged row
                // cannot make every valid/completed row disappear.
                let itemDecoder = try container.superDecoder()
                do {
                    decoded.append(try DownloadItem(from: itemDecoder))
                } catch {
                    dropped += 1
                }
            }
            items = decoded
            droppedCount = dropped
        }
    }

    static func fileMetadataIsWithinLimit(size: UInt64, isRegularFile: Bool) -> Bool {
        isRegularFile && size <= UInt64(Bounds.fileBytes)
    }

    /// Counts top-level object values without constructing a JSON object
    /// graph. Download metadata is always an array of objects; rejecting any
    /// other top-level element shape lets us enforce the item cap pre-decode.
    static func metadataJSONPassesPreflight(
        _ data: Data,
        maximumItems: Int = Bounds.items
    ) -> Bool {
        guard data.count <= Bounds.fileBytes, maximumItems >= 0 else { return false }
        var arrayDepth = 0
        var objectDepth = 0
        var itemCount = 0
        var inString = false
        var escaped = false
        var sawRoot = false
        var closedRoot = false

        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                continue
            }

            if byte == 0x22 {
                guard sawRoot, !closedRoot, objectDepth > 0 else { return false }
                inString = true
                continue
            }
            if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                continue
            }
            if closedRoot { return false }

            switch byte {
            case 0x5B: // [
                if !sawRoot {
                    sawRoot = true
                    arrayDepth = 1
                } else {
                    guard objectDepth > 0 else { return false }
                    arrayDepth += 1
                }
            case 0x5D: // ]
                guard sawRoot, arrayDepth > 0 else { return false }
                arrayDepth -= 1
                if arrayDepth == 0 {
                    guard objectDepth == 0 else { return false }
                    closedRoot = true
                }
            case 0x7B: // {
                guard sawRoot, arrayDepth > 0 else { return false }
                if arrayDepth == 1 && objectDepth == 0 {
                    itemCount += 1
                    guard itemCount <= maximumItems else { return false }
                }
                objectDepth += 1
            case 0x7D: // }
                guard objectDepth > 0 else { return false }
                objectDepth -= 1
            case 0x2C, 0x3A: // comma, colon
                guard sawRoot, arrayDepth > 0 else { return false }
            default:
                // Scalar tokens are valid only inside an item object. The
                // decoder remains responsible for full JSON grammar checks.
                guard sawRoot, arrayDepth > 0, objectDepth > 0 else { return false }
            }
        }

        return sawRoot && closedRoot && !inString && arrayDepth == 0 && objectDepth == 0
    }

    static func normalizedLoadedItems(_ loaded: [DownloadItem]) -> NormalizedItems {
        var wasChanged = loaded.count > Bounds.items
        var normalized: [DownloadItem] = []
        normalized.reserveCapacity(min(loaded.count, Bounds.items))

        for raw in loaded.prefix(Bounds.items) {
            guard var item = normalizedItem(raw, changed: &wasChanged) else {
                wasChanged = true
                continue
            }
            // A protected provider's old diagnostic can contain its signed
            // URL. Runtime code now emits tokens, and restored legacy text is
            // replaced before it can be persisted again or shown/logged.
            if item.claimsProtectedProviderTransport, item.error != nil {
                item.error = item.status == .failed
                    ? "The provider download must be retried."
                    : nil
                wasChanged = true
            }
            normalized.append(item)
        }
        return NormalizedItems(items: normalized, wasChanged: wasChanged)
    }

    static func decodeAndNormalizeLoadedItems(from data: Data) throws -> NormalizedItems {
        let decoded = try JSONDecoder().decode(LossyDecodedItems.self, from: data)
        let normalized = normalizedLoadedItems(decoded.items)
        return NormalizedItems(
            items: normalized.items,
            wasChanged: normalized.wasChanged || decoded.droppedCount > 0
        )
    }

    private static func normalizedItem(
        _ raw: DownloadItem,
        changed: inout Bool
    ) -> DownloadItem? {
        guard boundedRequired(raw.id, maximumBytes: Bounds.identifierBytes, identifier: true),
              boundedRequired(raw.title, maximumBytes: Bounds.titleBytes, rejectControls: true),
              boundedRequired(raw.displayTitle, maximumBytes: Bounds.titleBytes, rejectControls: true),
              boundedOptional(raw.posterURL, maximumBytes: Bounds.urlBytes, rejectControls: true),
              boundedOptional(raw.episodeName, maximumBytes: Bounds.titleBytes, rejectControls: true),
              (-Int(Int32.max)...Int(Int32.max)).contains(raw.tmdbId) else {
            return nil
        }

        var item = raw
        item.seasonNumber = boundedNumber(item.seasonNumber, range: 0...100_000, changed: &changed)
        item.episodeNumber = boundedNumber(item.episodeNumber, range: 0...100_000, changed: &changed)
        item.streamURL = boundedTransportString(item.streamURL, maximumBytes: Bounds.urlBytes, changed: &changed)
        item.headers = sanitizedHeaders(item.headers, changed: &changed)
        item.subtitleURL = boundedTransportOptional(item.subtitleURL, maximumBytes: Bounds.urlBytes, changed: &changed)
        if let subtitleHeaders = item.subtitleHeaders {
            let sanitized = sanitizedHeaders(subtitleHeaders, changed: &changed)
            item.subtitleHeaders = sanitized.isEmpty ? nil : sanitized
        }
        item.serviceBaseURL = boundedTransportString(
            item.serviceBaseURL,
            maximumBytes: Bounds.urlBytes,
            changed: &changed
        )
        item.sourceId = boundedOptionalValue(
            item.sourceId,
            maximumBytes: 320,
            rejectControls: true,
            changed: &changed
        )
        item.serviceContentHref = boundedOptionalValue(
            item.serviceContentHref,
            maximumBytes: 8 * 1_024,
            rejectControls: true,
            changed: &changed
        )
        item.lastSourceId = boundedOptionalValue(
            item.lastSourceId,
            maximumBytes: 320,
            rejectControls: true,
            changed: &changed
        )
        item.validatedExpectedContentLength = boundedPositiveInt64(
            item.validatedExpectedContentLength,
            changed: &changed
        )
        item.streamName = boundedOptionalValue(item.streamName, maximumBytes: Bounds.titleBytes, changed: &changed)
        item.originalAudioLanguage = boundedOptionalValue(
            item.originalAudioLanguage,
            maximumBytes: 512,
            changed: &changed
        )

        if let details = item.kidsPolicyDetails {
            let genres = Array(details.genreIds.prefix(256))
            let overview = boundedOptionalValue(
                details.overview,
                maximumBytes: 16 * 1_024,
                changed: &changed
            )
            if genres.count != details.genreIds.count { changed = true }
            item.kidsPolicyDetails = KidsPolicyDetails(
                isAdult: details.isAdult,
                genreIds: genres,
                overview: overview
            )
        }
        item.episodePlaybackContext = normalizedPlaybackContext(
            item.episodePlaybackContext,
            changed: &changed
        )

        if !item.progress.isFinite {
            item.progress = 0
            changed = true
        } else {
            let clamped = min(max(item.progress, 0), 1)
            if clamped != item.progress { changed = true }
            item.progress = clamped
        }
        if item.totalBytes < 0 || item.totalBytes > Bounds.byteCount {
            item.totalBytes = 0
            changed = true
        }
        if item.downloadedBytes < 0 || item.downloadedBytes > Bounds.byteCount {
            item.downloadedBytes = 0
            changed = true
        }
        if item.totalBytes > 0, item.downloadedBytes > item.totalBytes {
            item.downloadedBytes = item.totalBytes
            changed = true
        }

        item.localFileName = normalizedRelativePath(item.localFileName, changed: &changed)
        item.subtitleFileName = normalizedRelativePath(item.subtitleFileName, changed: &changed)
        item.reservedVideoFileName = normalizedRelativePath(item.reservedVideoFileName, changed: &changed)
        item.reservedSubtitleFileName = normalizedRelativePath(item.reservedSubtitleFileName, changed: &changed)

        if let retry = item.retryNotBefore,
           !retry.timeIntervalSince1970.isFinite || retry > Date().addingTimeInterval(30 * 24 * 60 * 60) {
            item.retryNotBefore = nil
            changed = true
        }
        item.rateLimitRetryCount = boundedNumber(
            item.rateLimitRetryCount,
            range: 0...100,
            changed: &changed
        )
        item.error = boundedOptionalValue(
            item.error,
            maximumBytes: 2 * 1_024,
            rejectControls: true,
            changed: &changed
        )
        if !item.dateAdded.timeIntervalSince1970.isFinite {
            item.dateAdded = Date()
            changed = true
        }
        if let completed = item.dateCompleted, !completed.timeIntervalSince1970.isFinite {
            item.dateCompleted = nil
            changed = true
        }

        item.hlsResumeSegmentIndex = boundedNumber(
            item.hlsResumeSegmentIndex,
            range: 0...10_000_000,
            changed: &changed
        )
        if let byteCount = item.hlsResumeByteCount,
           byteCount < 0 || byteCount > Bounds.byteCount {
            item.hlsResumeByteCount = nil
            changed = true
        }
        item.hlsVariantURL = boundedTransportOptional(
            item.hlsVariantURL,
            maximumBytes: Bounds.urlBytes,
            changed: &changed
        )
        item.hlsTotalSegments = boundedNumber(
            item.hlsTotalSegments,
            range: 0...10_000_000,
            changed: &changed
        )
        if let index = item.hlsResumeSegmentIndex,
           let total = item.hlsTotalSegments,
           index > total {
            item.hlsResumeSegmentIndex = nil
            changed = true
        }
        return item
    }

    private static func normalizedPlaybackContext(
        _ context: EpisodePlaybackContext?,
        changed: inout Bool
    ) -> EpisodePlaybackContext? {
        guard let context else { return nil }
        guard (0...100_000).contains(context.localSeasonNumber),
              (0...100_000).contains(context.localEpisodeNumber) else {
            changed = true
            return nil
        }
        func boundedID(_ value: Int?) -> Int? {
            guard let value, (-2_000_000_000...2_000_000_000).contains(value) else { return nil }
            return value
        }
        func boundedCoordinate(_ value: Int?) -> Int? {
            guard let value, (-100_000...100_000).contains(value) else { return nil }
            return value
        }
        let normalized = EpisodePlaybackContext(
            localSeasonNumber: context.localSeasonNumber,
            localEpisodeNumber: context.localEpisodeNumber,
            anilistMediaId: boundedID(context.anilistMediaId),
            canonicalAniListMediaId: boundedID(context.canonicalAniListMediaId),
            malMediaId: boundedID(context.malMediaId),
            kitsuMediaId: boundedID(context.kitsuMediaId),
            tmdbSeasonNumber: boundedCoordinate(context.tmdbSeasonNumber),
            tmdbEpisodeNumber: boundedCoordinate(context.tmdbEpisodeNumber),
            tmdbEpisodeOffset: boundedCoordinate(context.tmdbEpisodeOffset),
            animeAbsoluteEpisodeNumber: boundedCoordinate(context.animeAbsoluteEpisodeNumber),
            animeSeasonEpisodeCount: boundedCoordinate(context.animeSeasonEpisodeCount),
            isSpecial: context.isSpecial,
            titleOnlySearch: context.titleOnlySearch
        )
        if normalized != context { changed = true }
        return normalized
    }

    private static func sanitizedHeaders(
        _ raw: [String: String],
        changed: inout Bool
    ) -> [String: String] {
        let validNameCharacters = CharacterSet(
            charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        )
        var result: [String: String] = [:]
        var names = Set<String>()
        var aggregateBytes = 0
        for (name, value) in raw.sorted(by: {
            $0.key.lowercased() == $1.key.lowercased()
                ? $0.key < $1.key
                : $0.key.lowercased() < $1.key.lowercased()
        }) {
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercaseName = normalizedName.lowercased()
            let entryBytes = normalizedName.utf8.count + normalizedValue.utf8.count + 4
            guard result.count < Bounds.headerCount,
                  !normalizedName.isEmpty,
                  normalizedName.utf8.count <= 128,
                  normalizedName.unicodeScalars.allSatisfy({
                      $0.value < 128 && validNameCharacters.contains($0)
                  }),
                  !names.contains(lowercaseName),
                  normalizedValue.utf8.count <= Bounds.headerValueBytes,
                  normalizedValue.unicodeScalars.allSatisfy({
                      $0.value == 9 || ($0.value >= 32 && $0.value != 127)
                  }),
                  entryBytes <= Bounds.headerAggregateBytes - aggregateBytes else {
                changed = true
                continue
            }
            if normalizedName != name || normalizedValue != value { changed = true }
            names.insert(lowercaseName)
            result[normalizedName] = normalizedValue
            aggregateBytes += entryBytes
        }
        if result.count != raw.count { changed = true }
        return result
    }

    private static func boundedRequired(
        _ value: String,
        maximumBytes: Int,
        identifier: Bool = false,
        rejectControls: Bool = false
    ) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumBytes else { return false }
        if identifier {
            return !value.unicodeScalars.contains(where: {
                $0.value < 32 || $0.value == 127 || $0.value == 47 || $0.value == 92
            })
        }
        return !rejectControls || !containsHTTPControl(value)
    }

    private static func boundedOptional(
        _ value: String?,
        maximumBytes: Int,
        rejectControls: Bool = false
    ) -> Bool {
        guard let value else { return true }
        guard value.utf8.count <= maximumBytes else { return false }
        return !rejectControls || !containsHTTPControl(value)
    }

    private static func boundedTransportString(
        _ value: String,
        maximumBytes: Int,
        changed: inout Bool
    ) -> String {
        guard value.utf8.count <= maximumBytes, !containsHTTPControl(value) else {
            changed = true
            return ""
        }
        return value
    }

    private static func boundedTransportOptional(
        _ value: String?,
        maximumBytes: Int,
        changed: inout Bool
    ) -> String? {
        guard let value else { return nil }
        let bounded = boundedTransportString(value, maximumBytes: maximumBytes, changed: &changed)
        return bounded.isEmpty ? nil : bounded
    }

    private static func boundedOptionalValue(
        _ value: String?,
        maximumBytes: Int,
        rejectControls: Bool = false,
        changed: inout Bool
    ) -> String? {
        guard let value else { return nil }
        guard value.utf8.count <= maximumBytes,
              !rejectControls || !containsHTTPControl(value) else {
            changed = true
            return nil
        }
        return value
    }

    private static func boundedNumber(
        _ value: Int?,
        range: ClosedRange<Int>,
        changed: inout Bool
    ) -> Int? {
        guard let value else { return nil }
        guard range.contains(value) else {
            changed = true
            return nil
        }
        return value
    }

    private static func boundedPositiveInt64(
        _ value: Int64?,
        changed: inout Bool
    ) -> Int64? {
        guard let value else { return nil }
        guard value > 0, value <= Bounds.byteCount else {
            changed = true
            return nil
        }
        return value
    }

    private static func normalizedRelativePath(
        _ value: String?,
        changed: inout Bool
    ) -> String? {
        guard let value else { return nil }
        guard value.utf8.count <= Bounds.relativePathBytes,
              !value.hasPrefix("/"),
              !value.contains("\\"),
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              let normalized = DownloadPathIdentityPolicy.normalizedRelativePath(value) else {
            changed = true
            return nil
        }
        if normalized != value { changed = true }
        return normalized
    }

    private static func containsHTTPControl(_ value: String) -> Bool {
        value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    }
}

final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()
    private static let animeProviderAliasesKey = "downloadAnimeProviderAliasesV1"

    private enum RefreshedDownloadTransport {
        case direct(url: URL, headers: [String: String], expectedContentLength: Int64?)
#if os(iOS) && !targetEnvironment(macCatalyst)
        case skyStreamHLS(SkyStreamValidatedPlaybackDescriptor)
#endif
    }

    private struct RefreshedDownloadSource {
        let transport: RefreshedDownloadTransport
        let streamName: String?
        let subtitleURL: String?
        let subtitleHeaders: [String: String]?
        let serviceContentHref: String?
        let lastSourceId: String
        let lastContentReference: ProviderContentReference
        let stremioConfiguredOriginAuthority: SkyStreamPinnedOriginAuthority?

        init(
            transport: RefreshedDownloadTransport,
            streamName: String?,
            subtitleURL: String?,
            subtitleHeaders: [String: String]?,
            serviceContentHref: String?,
            lastSourceId: String,
            lastContentReference: ProviderContentReference,
            stremioConfiguredOriginAuthority: SkyStreamPinnedOriginAuthority? = nil
        ) {
            self.transport = transport
            self.streamName = streamName
            self.subtitleURL = subtitleURL
            self.subtitleHeaders = subtitleHeaders
            self.serviceContentHref = serviceContentHref
            self.lastSourceId = lastSourceId
            self.lastContentReference = lastContentReference
            self.stremioConfiguredOriginAuthority = stremioConfiguredOriginAuthority
        }

        var directURL: URL? {
            guard case .direct(let url, _, _) = transport else { return nil }
            return url
        }
    }

    @Published private(set) var downloads: [DownloadItem] = []

    private var backgroundSession: URLSession!
    private var activeTasks: [String: URLSessionDownloadTask] = [:]

    private var invalidatedDirectTaskIdentifiers = Set<Int>()
    private var pendingResumeDataTaskIdentifiers: [String: Int] = [:]
    private var resumeDataStore: [String: Data] = [:]
    private var lastProgressUpdate: [String: Date] = [:]
    private var lastHLSCheckpointSave: [String: Date] = [:]
    private var activeHLSDownloaders: [String: HLSDownloader] = [:]

    private var activeHLSAttemptIDs: [String: UUID] = [:]
    private var invalidatedHLSAttemptIDs = Set<UUID>()
#if os(iOS) && !targetEnvironment(macCatalyst)

    private var skyStreamHLSDescriptors: [String: SkyStreamValidatedPlaybackDescriptor] = [:]
    private var skyStreamHLSProxyURLs: [String: URL] = [:]
    private var skyStreamHLSPinnedVariantURLs: [String: URL] = [:]
    private var skyStreamRestoringDownloadIDs = Set<String>()

    private struct ProtectedProviderDownloadAttempt {
        let attemptID: UUID
        let providerKind: ProtectedDownloadProviderKind
        let authorityURL: String
        let authorityHeaders: [String: String]
        let authorityReference: ProviderContentReference?
        let stremioConfiguredOriginAuthority: SkyStreamPinnedOriginAuthority?
        let mainProxyURL: URL
        var subtitleProxyURLs = Set<URL>()
        var mainTaskIdentifier: Int?
        var hlsVariantProxyURL: URL?
        var mainFinished = false
    }

    private var protectedProviderAttempts: [String: ProtectedProviderDownloadAttempt] = [:]
    private var stremioConfiguredOriginAuthorities: [String: SkyStreamPinnedOriginAuthority] = [:]
    private var persistenceLoadedDownloadIDs = Set<String>()
    private var nuvioSubtitleFetches: [String: NuvioBoundedSubtitleFetch] = [:]
    private var nuvioRestoringDownloadIDs = Set<String>()
    private var nuvioAutoValidationProxyURLs: [UUID: URL] = [:]
    private var observedNuvioTransportProfileID: UUID?
#endif

    private var nuvioDispatchValidationPendingIDs = Set<String>()
    private var nuvioDispatchApprovedIDs = Set<String>()
    private var nuvioDispatchValidationTokens: [String: UUID] = [:]

    private var cloudflareRecoveringDownloadIDs = Set<String>()
    private var mediaSourceRecoveryAttempts: [String: (count: Int, lastAttempt: Date)] = [:]

    private var animeProviderAliasesByTMDBID: [Int: [Int: Int]] = [:]
    private var scheduledQueueWakeWorkItem: DispatchWorkItem?
    #if canImport(UIKit)
    private var lifecycleObservers: [NSObjectProtocol] = []
    #endif

    private let maxConcurrentDownloads = 2
    private let maxConcurrentHLSDownloads = 1
    private let minimumFreeBytesForHLS: Int64 = 750 * 1024 * 1024
    private let autoModeDirectProbeMinimumBytes = 256 * 1024
    private let autoModeHLSSegmentProbeMinimumBytes = 8 * 1024
    private let autoModePlaylistProbeLimit = 1024 * 1024
    private let fileManager = FileManager.default
    private let accessQueue = DispatchQueue(label: "app.eclipse.soupy.download-manager", attributes: .concurrent)
    private var backgroundHLSPipelineEnabled: Bool {
        UserDefaults.standard.bool(forKey: "backgroundHLSPipelineEnabled")
    }

    private var persistenceURL: URL {
        downloadsDirectory.appendingPathComponent(".downloads_metadata.json")
    }

    private var legacyDownloadsDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads")
    }

    var downloadsDirectory: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = documents.appendingPathComponent("Downloads", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    var backgroundCompletionHandler: (() -> Void)?

    private override init() {
        super.init()

#if os(iOS) && !targetEnvironment(macCatalyst)
        observedNuvioTransportProfileID = ProfileManager.shared.activeProfileID
#endif

        if let data = UserDefaults.standard.data(forKey: Self.animeProviderAliasesKey),
           let decoded = try? JSONDecoder().decode([Int: [Int: Int]].self, from: data) {
            animeProviderAliasesByTMDBID = decoded
        }

        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif

        let config = URLSessionConfiguration.background(withIdentifier: "app.eclipse.soupy.downloads")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.httpMaximumConnectionsPerHost = 4
        backgroundSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        migrateLegacyDownloadsDirectoryIfNeeded()
        loadDownloads()
#if os(iOS) && !targetEnvironment(macCatalyst)
        persistenceLoadedDownloadIDs = Set(downloads.map(\.id))
        migrateLegacyStremioDownloadsIfNeeded(permitsOneLiveAttempt: false)
#endif
        ensureDownloadPathReservations()
        migrateTrackedDownloadsToPublicLayout()
        backfillKidsPolicyDetailsIfNeeded()
        observeAppLifecycle()

        cleanOrphanedFiles()

        resumeInterruptedDownloads()
    }

    deinit {
        #if canImport(UIKit)
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        #endif
#if os(iOS) && !targetEnvironment(macCatalyst)
        invalidateAllProtectedProviderAttempts()
#endif
    }

    private func observeAppLifecycle() {
        #if canImport(UIKit) && !os(watchOS)
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.processQueue()
            }
        )
#if os(iOS) && !targetEnvironment(macCatalyst)
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.suspendProtectedProviderAttempts(
                    message: "Waiting for app to reopen",
                    processWhenPossible: false
                )
            }
        )
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.suspendProtectedProviderAttempts(
                    message: "Waiting for app to reopen",
                    processWhenPossible: false
                )
            }
        )
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: .activeProfileDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                let currentProfileID = ProfileManager.shared.activeProfileID
                guard currentProfileID != self.observedNuvioTransportProfileID else { return }
                self.observedNuvioTransportProfileID = currentProfileID
                self.suspendProtectedProviderAttempts(
                    message: "Refreshing protected download access",
                    processWhenPossible: true
                )
            }
        )
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: .mediaStateWillChangeCurrentUser,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.suspendProtectedProviderAttempts(
                    message: "Refreshing protected download access",
                    processWhenPossible: false
                )
                DispatchQueue.main.async { [weak self] in
                    self?.processQueue()
                }
            }
        )
#endif
        #endif
    }

    private func performOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    var activeDownloads: [DownloadItem] {
        downloads.filter { $0.status == .downloading || $0.status == .queued }
    }

    var completedDownloads: [DownloadItem] {
        downloads.filter { $0.status == .completed }
    }

    var failedDownloads: [DownloadItem] {
        downloads.filter { $0.status == .failed }
    }

    var activeDownloadCount: Int {
        downloads.filter { $0.status == .downloading }.count
    }

    func registerAnimeProviderAliases(
        tmdbId: Int,
        canonicalProviderIDByStoredID aliases: [Int: Int]
    ) {
        guard tmdbId > 0, !aliases.isEmpty else { return }
        var merged = animeProviderAliasesByTMDBID[tmdbId] ?? [:]
        for (storedID, canonicalID) in aliases
        where storedID != 0 && canonicalID != 0 && storedID != canonicalID {
            merged[storedID] = canonicalID
        }
        guard merged != animeProviderAliasesByTMDBID[tmdbId] else { return }
        animeProviderAliasesByTMDBID[tmdbId] = merged
        if let data = try? JSONEncoder().encode(animeProviderAliasesByTMDBID) {
            UserDefaults.standard.set(data, forKey: Self.animeProviderAliasesKey)
        }
    }

    @MainActor
    func reconcileAnimeStructuralContexts(
        tmdbId: Int,
        canonicalContexts: [EpisodePlaybackContext],
        canonicalProviderIDByStoredID aliases: [Int: Int]
    ) {
        guard tmdbId > 0, !canonicalContexts.isEmpty else { return }
        registerAnimeProviderAliases(
            tmdbId: tmdbId,
            canonicalProviderIDByStoredID: aliases
        )

        var didChange = false
        for index in downloads.indices {
            guard !downloads[index].isMovie,
                  downloads[index].tmdbId == tmdbId,
                  downloads[index].isAnime
                    || downloads[index].episodePlaybackContext?.hasAnimeMediaId == true else {
                continue
            }

            let storedContext: EpisodePlaybackContext? = {
                if let context = downloads[index].episodePlaybackContext { return context }
                guard let season = downloads[index].seasonNumber,
                      let providerID = AnimeSyntheticSeasonKey.providerID(from: season),
                      let episode = downloads[index].episodeNumber else { return nil }
                return EpisodePlaybackContext(
                    localSeasonNumber: season,
                    localEpisodeNumber: episode,
                    anilistMediaId: providerID,
                    tmdbSeasonNumber: nil,
                    tmdbEpisodeNumber: nil,
                    tmdbEpisodeOffset: nil,
                    animeAbsoluteEpisodeNumber: nil,
                    animeSeasonEpisodeCount: nil,
                    isSpecial: true,
                    titleOnlySearch: false
                )
            }()
            guard let storedContext,
                  let canonical = canonicalContexts.first(where: {
                      AnimeEpisodeIdentityPolicy.isSameEpisode(
                          storedContext,
                          $0,
                          providerAliases: aliases
                      )
                  }) else {
                continue
            }

            if downloads[index].seasonNumber != canonical.localSeasonNumber
                || downloads[index].episodeNumber != canonical.localEpisodeNumber
                || downloads[index].episodePlaybackContext != canonical {
                downloads[index].seasonNumber = canonical.localSeasonNumber
                downloads[index].episodeNumber = canonical.localEpisodeNumber
                downloads[index].episodePlaybackContext = canonical
                didChange = true
            }
        }

        if didChange {
            saveDownloads()
            Logger.shared.log(
                "DownloadManager: reconciled canonical anime contexts tmdbId=\(tmdbId)",
                type: "Download"
            )
        }
    }

    func validateAutoModeDownload(
        streamURL: String,
        headers: [String: String],
        streamIsHLS: Bool? = nil,
        diagnosticURL: URL? = nil
    ) async -> AutoModeDownloadValidationResult {
        guard let url = URL(string: streamURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .invalid(reason: "The source returned an invalid download URL.")
        }

        let isHLS = streamIsHLS ?? streamURL.lowercased().contains(".m3u8")
        let host = diagnosticURL?.host ?? url.host ?? "unknown host"
        let maximumAttempts = 2

        for attempt in 1...maximumAttempts {
            do {
                try Task.checkCancellation()
                if isHLS {
                    try await validateAutoModeHLSDownload(url: url, headers: headers)
                } else {
                    try await validateAutoModeDirectDownload(url: url, headers: headers)
                }
                try Task.checkCancellation()

                Logger.shared.log(
                    "Auto Mode download validation passed host=\(host) kind=\(isHLS ? "hls" : "direct") attempt=\(attempt)",
                    type: "Download"
                )
                return .valid
            } catch {
                if Task.isCancelled || error is CancellationError {
                    Logger.shared.log("Auto Mode download validation cancelled host=\(host)", type: "Download")
                    return .cancelled
                }

                let failure = autoModeValidationFailure(from: error)

                if let rawChallengeURL = failure.cloudflareChallengeURL {
                    let challengeURL = diagnosticURL ?? rawChallengeURL
                    await CloudflareBypassManager.shared.flagPendingVerification(for: challengeURL)
                    Logger.shared.log(
                        "Auto Mode download hit Cloudflare wall host=\(challengeURL.host ?? "unknown") — routing to verification",
                        type: "Download"
                    )
                    return .cloudflareChallenge(url: challengeURL)
                }

                if attempt < maximumAttempts && failure.isRetryable {
                    Logger.shared.log(
                        "Auto Mode download validation retry host=\(host) reason=\(failure.message)",
                        type: "Download"
                    )
                    do {
                        try await Task.sleep(nanoseconds: 350_000_000)
                    } catch {
                        return .cancelled
                    }
                    continue
                }

                Logger.shared.log(
                    "Auto Mode download validation failed host=\(host) reason=\(failure.message)",
                    type: "Download"
                )
                return .invalid(reason: failure.message)
            }
        }

        return .invalid(reason: "The download stream could not be verified.")
    }

    @MainActor
    func enqueueValidatedAutoModeDownload(
        tmdbId: Int,
        isMovie: Bool,
        title: String,
        displayTitle: String,
        posterURL: String?,
        seasonNumber: Int?,
        episodeNumber: Int?,
        episodeName: String?,
        streamURL: String,
        headers: [String: String],
        subtitleURL: String?,
        subtitleHeaders: [String: String]? = nil,
        serviceBaseURL: String,
        sourceId: String? = nil,
        serviceContentHref: String? = nil,
        lastSourceId: String? = nil,
        lastContentReference: ProviderContentReference? = nil,
        streamName: String? = nil,
        originalAudioLanguage: String? = nil,
        isAnime: Bool,
        episodePlaybackContext: EpisodePlaybackContext? = nil,
        cancellationRequested: @escaping @MainActor () -> Bool = { false }
    ) async -> AutoModeDownloadEnqueueResult {
        guard !cancellationRequested() else { return .cancelled }

        let recoveryMetadata = Self.validatedRecoveryMetadata(
            legacySourceId: sourceId,
            legacyServiceHref: serviceContentHref,
            sourceId: lastSourceId,
            contentReference: lastContentReference
        )

        let id = isMovie
            ? "dl_movie_\(tmdbId)"
            : "dl_ep_\(tmdbId)_s\(seasonNumber ?? 0)_e\(episodeNumber ?? 0)"
        var candidate = DownloadItem(
            id: id,
            tmdbId: tmdbId,
            isMovie: isMovie,
            title: title,
            displayTitle: displayTitle,
            posterURL: posterURL,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            episodeName: episodeName,
            streamURL: streamURL,
            headers: headers,
            subtitleURL: subtitleURL,
            subtitleHeaders: subtitleHeaders,
            serviceBaseURL: serviceBaseURL,
            sourceId: sourceId,
            serviceContentHref: serviceContentHref,
            lastSourceId: recoveryMetadata.sourceId,
            lastContentReference: recoveryMetadata.reference,
            streamName: streamName,
            originalAudioLanguage: originalAudioLanguage,
            episodePlaybackContext: episodePlaybackContext,
            status: .queued,
            progress: 0,
            totalBytes: 0,
            downloadedBytes: 0,
            localFileName: nil,
            subtitleFileName: nil,
            error: nil,
            dateAdded: Date(),
            dateCompleted: nil,
            isAnime: isAnime
        )
#if os(iOS) && !targetEnvironment(macCatalyst)
        if let providerKind = ProtectedDownloadPersistencePolicy.inferredProviderKind(
            sourceID: candidate.lastSourceId,
            reference: candidate.lastContentReference
        ) {
            candidate.protectedProviderKind = providerKind
            candidate.protectedOwnerProfileID = ProfileManager.shared.activeProfileID
            candidate.protectedTransportKind = ProtectedDownloadPersistencePolicy.transportKind(
                for: candidate.streamURL
            )
            if providerKind == .nuvio {
                candidate.nuvioOwnerProfileID = candidate.protectedOwnerProfileID
                candidate.nuvioTransportKind = candidate.protectedTransportKind
            }
        }
#endif

        if let existingResult = existingAutoModeDownloadOutcome(for: candidate) {
            return .accepted(existingResult)
        }

        var validationStreamURL = streamURL
        var validationHeaders = headers
        var validationProxyURL: URL?
        var validationProxyToken: UUID?
        var validationIsHLS: Bool?
        var validationDiagnosticURL: URL?
        var challengeCapture: NuvioDownloadChallengeCapture?
        var validatedProtectedOwnerProfileID: UUID?
        var validatedProtectedScopeGeneration: Int?
#if os(iOS) && !targetEnvironment(macCatalyst)
        var validationNeedsProtectedProxy = false
        var protectedValidationURLString = streamURL
        var protectedValidationHeaders = headers
        var protectedValidationStremioAuthority: SkyStreamPinnedOriginAuthority?
        switch ProtectedDownloadAuthorityState.classify(
            explicitKind: candidate.protectedProviderKind,
            hasLegacyNuvioMarker: candidate.nuvioTransportKind != nil,
            sourceID: candidate.lastSourceId,
            reference: candidate.lastContentReference
        ) {
        case .notProtected:
            break
        case .invalid:
            return .invalid(reason: "The provider download recovery reference is invalid.")
        case .authorized(let providerKind):
            validationNeedsProtectedProxy = true
            validatedProtectedOwnerProfileID = candidate.effectiveProtectedOwnerProfileID
            validatedProtectedScopeGeneration = ServiceStoreScope.generation
            if providerKind == .nuvio {
                guard let reference = candidate.lastContentReference?.nuvio,
                      nuvioDownloadReferenceMatchesItem(reference, item: candidate) else {
                    return .invalid(reason: "The Nuvio download reference no longer matches this title.")
                }
            }
            if providerKind == .stremio {
                guard let reference = candidate.lastContentReference,
                      reference.hasValidStremioSelection,
                      let ownerProfileID = validatedProtectedOwnerProfileID,
                      let scopeGeneration = validatedProtectedScopeGeneration else {
                    return .invalid(reason: "The Stremio download reference is invalid.")
                }
                guard let resolved = await StremioAddonManager.shared.resolveDownloadTransport(
                    reference: reference,
                    ownerProfileID: ownerProfileID,
                    serviceStoreGeneration: scopeGeneration
                ) else {
                    return .invalid(reason: "The Stremio addon could not refresh this download stream.")
                }
                guard !cancellationRequested(),
                      ProtectedDownloadPersistencePolicy.validatedEnqueueAuthorityIsCurrent(
                          ownerProfileID: ownerProfileID,
                          capturedScopeGeneration: scopeGeneration,
                          activeProfileID: ProfileManager.shared.activeProfileID,
                          currentScopeGeneration: ServiceStoreScope.generation
                      ) else {
                    return .cancelled
                }
                protectedValidationURLString = resolved.streamURL
                protectedValidationHeaders = Self.stremioDownloadHeaders(resolved.headers)
                protectedValidationStremioAuthority = resolved.configuredOriginAuthority
            }
        case .legacyService:
            validationNeedsProtectedProxy = true
            validatedProtectedOwnerProfileID = candidate.effectiveProtectedOwnerProfileID
            validatedProtectedScopeGeneration = ServiceStoreScope.generation
        case .legacyStremio:
            return .invalid(reason: "This legacy Stremio download must be selected again.")
        }

        if validationNeedsProtectedProxy {
            guard let originalURL = URL(string: protectedValidationURLString),
                  protectedProviderTransportMayStart else {
                return .invalid(reason: "The protected provider download route is unavailable right now.")
            }
            let capture = NuvioDownloadChallengeCapture()
            guard let proxyURL = MPVHeaderProxy.shared.makeProxyURL(
                for: originalURL,
                headers: protectedValidationHeaders,
                logType: "ProviderDownloadValidation",
                traceID: String(UUID().uuidString.prefix(8)),
                stremioAuthority: protectedValidationStremioAuthority,
                onConfirmedCloudflareChallenge: { url, _, _, _ in
                    capture.record(url)
                }
            ) else {
                return .invalid(reason: "Eclipse could not create a protected provider validation route.")
            }
            challengeCapture = capture
            validationProxyURL = proxyURL
            let proxyToken = UUID()
            validationProxyToken = proxyToken
            nuvioAutoValidationProxyURLs[proxyToken] = proxyURL
            validationStreamURL = proxyURL.absoluteString
            validationHeaders = [:]
            validationIsHLS = ProtectedDownloadPersistencePolicy.transportKind(
                for: protectedValidationURLString
            ) == .hls
            validationDiagnosticURL = originalURL
        }
#endif

        let validation = await validateAutoModeDownload(
            streamURL: validationStreamURL,
            headers: validationHeaders,
            streamIsHLS: validationIsHLS,
            diagnosticURL: validationDiagnosticURL
        )
        if let validationProxyURL {
#if os(iOS) && !targetEnvironment(macCatalyst)
            if let validationProxyToken {
                nuvioAutoValidationProxyURLs.removeValue(forKey: validationProxyToken)
            }
#endif
            MPVHeaderProxy.shared.invalidateSession(for: validationProxyURL)
        }
        guard !cancellationRequested() else { return .cancelled }
#if os(iOS) && !targetEnvironment(macCatalyst)
        if let validatedProtectedOwnerProfileID {
            guard let validatedProtectedScopeGeneration,
                  ProtectedDownloadPersistencePolicy.validatedEnqueueAuthorityIsCurrent(
                      ownerProfileID: validatedProtectedOwnerProfileID,
                      capturedScopeGeneration: validatedProtectedScopeGeneration,
                      activeProfileID: ProfileManager.shared.activeProfileID,
                      currentScopeGeneration: ServiceStoreScope.generation
                  ) else {
                return .cancelled
            }
        }
#endif

        switch validation {
        case .valid:
            let result = enqueueDownload(
                tmdbId: tmdbId,
                isMovie: isMovie,
                title: title,
                displayTitle: displayTitle,
                posterURL: posterURL,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber,
                episodeName: episodeName,
                streamURL: streamURL,
                headers: headers,
                subtitleURL: subtitleURL,
                subtitleHeaders: subtitleHeaders,
                serviceBaseURL: serviceBaseURL,
                sourceId: sourceId,
                serviceContentHref: serviceContentHref,
                lastSourceId: recoveryMetadata.sourceId,
                lastContentReference: recoveryMetadata.reference,
                protectedOwnerProfileID: validatedProtectedOwnerProfileID,
                nuvioOwnerProfileID: candidate.protectedProviderKind == .nuvio
                    ? validatedProtectedOwnerProfileID
                    : nil,
                streamName: streamName,
                originalAudioLanguage: originalAudioLanguage,
                isAnime: isAnime,
                episodePlaybackContext: episodePlaybackContext
            )
            return .accepted(result)
        case .invalid(let reason):
            return .invalid(reason: reason)
        case .cloudflareChallenge(let url):
            return .cloudflareChallenge(
                url: challengeCapture?.url ?? validationDiagnosticURL ?? url
            )
        case .cancelled:
            return .cancelled
        }
    }

#if os(iOS) && !targetEnvironment(macCatalyst)

    @MainActor
    func enqueueValidatedSkyStreamDownload(
        tmdbId: Int,
        isMovie: Bool,
        title: String,
        displayTitle: String,
        posterURL: String?,
        seasonNumber: Int?,
        episodeNumber: Int?,
        episodeName: String?,
        resolved: SkyStreamResolvedStream,
        originalAudioLanguage: String? = nil,
        isAnime: Bool,
        episodePlaybackContext: EpisodePlaybackContext? = nil,
        cancellationRequested: @escaping @MainActor () -> Bool = { false }
    ) -> AutoModeDownloadEnqueueResult {
        guard !cancellationRequested() else { return .cancelled }
        let descriptor = resolved.playback
        guard resolved.contentReference.isStructurallyValid,
              resolved.contentReference.sourceID == resolved.provider.id else {
            return .invalid(reason: "The SkyStream source did not include a valid recovery reference.")
        }

        let transportKind: DownloadProviderTransportKind
        let streamURL: String
        let headers: [String: String]
        let serviceBaseURL: String
        switch descriptor.mediaKind {
        case .direct:
            guard descriptor.proxyOptions == nil,
                  descriptor.acceptedManifests.isEmpty,
                  let contentLength = descriptor.finiteContentLength,
                  contentLength > 0 else {
                return .invalid(
                    reason: "This verified direct source requires a proxy-aware download transport."
                )
            }
            transportKind = .skyStreamDirect
            streamURL = descriptor.underlyingRemoteURL.url.absoluteString
            headers = descriptor.headers.values
            serviceBaseURL = Self.originString(for: descriptor.underlyingRemoteURL.url)
        case .hls:
            if let reason = Self.skyStreamHLSRejectionReason(descriptor) {
                return .invalid(reason: reason)
            }
            transportKind = .skyStreamHLS

            streamURL = ""
            headers = [:]
            serviceBaseURL = ""
        case .dash:
            return .invalid(
                reason: "Static DASH downloads need an MPD-aware segment packager and muxer; Eclipse cannot safely concatenate DASH representations."
            )
        }

        let downloadID = Self.downloadID(
            tmdbId: tmdbId,
            isMovie: isMovie,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber
        )
        if transportKind == .skyStreamHLS {

            skyStreamHLSDescriptors[downloadID] = descriptor
        }

        let result = enqueueDownload(
            tmdbId: tmdbId,
            isMovie: isMovie,
            title: title,
            displayTitle: displayTitle,
            posterURL: posterURL,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            episodeName: episodeName,
            streamURL: streamURL,
            headers: headers,
            subtitleURL: nil,
            subtitleHeaders: nil,
            serviceBaseURL: serviceBaseURL,
            sourceId: nil,
            serviceContentHref: nil,
            lastSourceId: resolved.provider.id,
            lastContentReference: .skyStream(resolved.contentReference),
            providerTransportKind: transportKind,
            validatedExpectedContentLength: descriptor.mediaKind == .direct
                ? descriptor.finiteContentLength
                : nil,
            streamName: resolved.displayName,
            originalAudioLanguage: originalAudioLanguage,
            isAnime: isAnime,
            episodePlaybackContext: episodePlaybackContext
        )
        if transportKind == .skyStreamHLS {
            if case .enqueued = result {

            } else {
                clearSkyStreamDownloadRuntimeState(id: downloadID, discardDescriptor: true)
            }
        }
        return .accepted(result)
    }

    static func skyStreamHLSRejectionReason(
        _ descriptor: SkyStreamValidatedPlaybackDescriptor
    ) -> String? {
        guard descriptor.mediaKind == .hls,
              !descriptor.acceptedManifests.isEmpty,
              !descriptor.routes.isEmpty else {
            return "The SkyStream source did not provide a finite validated HLS route graph."
        }

        for route in descriptor.routes {
            switch route.role {
            case .streamRoot, .manifest, .mediaSegment, .subtitle:
                break
            case .encryptionKey:
                return "Encrypted HLS downloads are not supported by the safe offline packager."
            case .initialization:
                return "Fragmented-MP4 HLS downloads need a container-aware muxer."
            case .dashResource:
                return "The HLS descriptor unexpectedly included a DASH resource."
            }
            if route.role == .mediaSegment {
                let ext = route.remoteURL.url.pathExtension.lowercased()
                guard ext == "ts" || ext == "m2ts" else {
                    return "Only explicit MPEG-TS HLS segments can be packaged safely for offline playback."
                }
            }
        }

        let unsupportedTagPrefixes = [
            "#EXT-X-BYTERANGE", "#EXT-X-DISCONTINUITY", "#EXT-X-GAP",
            "#EXT-X-I-FRAME", "#EXT-X-KEY:", "#EXT-X-SESSION-KEY:",
            "#EXT-X-MAP:", "#EXT-X-MEDIA:", "#EXT-X-PART",
            "#EXT-X-PRELOAD-HINT", "#EXT-X-RENDITION-REPORT",
            "#EXT-X-SERVER-CONTROL", "#EXT-X-SKIP"
        ]

        for accepted in descriptor.acceptedManifests {
            guard accepted.mediaKind == .hls,
                  let text = String(data: accepted.bytes, encoding: .utf8) else {
                return "The validated HLS playlist could not be decoded safely."
            }
            let lines = text.components(separatedBy: .newlines).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            guard lines.first?.trimmingCharacters(
                in: CharacterSet(charactersIn: "\u{feff}")
            ).uppercased() == "#EXTM3U" else {
                return "The validated HLS playlist has an unsupported format."
            }

            let upperLines = lines.map { $0.uppercased() }
            if upperLines.contains(where: { line in
                unsupportedTagPrefixes.contains { line.hasPrefix($0) }
            }) {
                return "This HLS playlist uses features the offline MPEG-TS packager cannot preserve safely."
            }

            let hasMasterEntries = upperLines.contains { $0.hasPrefix("#EXT-X-STREAM-INF:") }
            let hasMediaEntries = upperLines.contains { $0.hasPrefix("#EXTINF:") }
            guard hasMasterEntries != hasMediaEntries else {
                return "The validated HLS playlist mixes or omits master and media entries."
            }
            if hasMasterEntries {
                if upperLines.contains(where: {
                    $0.hasPrefix("#EXT-X-STREAM-INF:")
                        && ($0.contains("AUDIO=") || $0.contains("VIDEO="))
                }) {
                    return "HLS downloads with separate audio or video rendition groups need a muxer."
                }
            } else if !upperLines.contains("#EXT-X-ENDLIST") {
                return "Only explicitly ended VOD HLS playlists can be downloaded."
            }
        }
        return nil
    }
#endif

    private static func downloadID(
        tmdbId: Int,
        isMovie: Bool,
        seasonNumber: Int?,
        episodeNumber: Int?
    ) -> String {
        if isMovie { return "dl_movie_\(tmdbId)" }
        return "dl_ep_\(tmdbId)_s\(seasonNumber ?? 0)_e\(episodeNumber ?? 0)"
    }

    private static func originString(for url: URL) -> String {
        guard let scheme = url.scheme,
              let host = url.host else { return "" }
        if let port = url.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    @MainActor
    private func existingAutoModeDownloadOutcome(for candidate: DownloadItem) -> DownloadEnqueueResult? {
        if let existing = downloads.first(where: { $0.id == candidate.id }) {
            switch existing.status {
            case .completed:
                if localFileURL(for: existing) != nil {
                    Logger.shared.log("Auto Mode download already exists: \(candidate.id)", type: "Download")
                    return .alreadyExists
                }
                if adoptExistingDownloadedFileIfPresent(for: candidate) {
                    Logger.shared.log("Auto Mode adopted existing file: \(candidate.displayTitle)", type: "Download")
                    return .adoptedExistingFile
                }
            case .downloading, .queued, .paused:
                Logger.shared.log("Auto Mode download already active: \(candidate.id)", type: "Download")
                return .alreadyExists
            case .failed:
                if adoptExistingDownloadedFileIfPresent(for: candidate) {
                    Logger.shared.log("Auto Mode adopted existing file: \(candidate.displayTitle)", type: "Download")
                    return .adoptedExistingFile
                }
            }
        } else if adoptExistingDownloadedFileIfPresent(for: candidate) {
            Logger.shared.log("Auto Mode adopted existing file: \(candidate.displayTitle)", type: "Download")
            return .adoptedExistingFile
        }

        return nil
    }

    private static func validatedRecoveryMetadata(
        legacySourceId: String?,
        legacyServiceHref: String?,
        sourceId: String?,
        contentReference: ProviderContentReference?
    ) -> (sourceId: String?, reference: ProviderContentReference?) {
        let normalizedSourceId = (sourceId ?? contentReference?.sourceID ?? legacySourceId)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedSourceId = normalizedSourceId.flatMap { value in
            value.isEmpty || value.utf8.count > 320 ? nil : value
        }

        if let contentReference,
           let boundedSourceId,
           isValidRecoveryReference(contentReference, matchingSourceId: boundedSourceId) {
            return (boundedSourceId, contentReference)
        }

        guard let legacySourceId = legacySourceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              legacySourceId.hasPrefix("service:"),
              legacySourceId.utf8.count <= 320,
              let legacyServiceHref,
              !legacyServiceHref.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {

            return (boundedSourceId, nil)
        }
        let reference = ProviderContentReference.service(
            sourceID: legacySourceId,
            href: legacyServiceHref
        )
        guard reference.serviceHref != nil else { return (boundedSourceId, nil) }
        return (legacySourceId, reference)
    }

    private static func isValidRecoveryReference(
        _ reference: ProviderContentReference,
        matchingSourceId sourceId: String
    ) -> Bool {
        guard reference.schemaVersion == 1,
              reference.sourceID == sourceId else { return false }
        switch reference.kind {
        case .service:
            guard sourceId.hasPrefix("service:"),
                  let href = reference.serviceHref else { return false }
            return !href.isEmpty && href.utf8.count <= 8 * 1_024
        case .stremio:
            return sourceId.hasPrefix("stremio:")
                && reference.hasValidStremioSelection
        case .skyStream:
            return reference.skyStream?.sourceID == sourceId
                && reference.skyStream?.isStructurallyValid == true
        case .nuvio:
            return sourceId.hasPrefix("nuvio:")
                && reference.nuvio?.sourceID == sourceId
                && reference.nuvio?.isStructurallyValid == true
        }
    }

    @discardableResult
    @MainActor
    func enqueueDownload(
        tmdbId: Int,
        isMovie: Bool,
        title: String,
        displayTitle: String,
        posterURL: String?,
        seasonNumber: Int?,
        episodeNumber: Int?,
        episodeName: String?,
        streamURL: String,
        headers: [String: String],
        subtitleURL: String?,
        subtitleHeaders: [String: String]? = nil,
        serviceBaseURL: String,
        sourceId: String? = nil,
        serviceContentHref: String? = nil,
        lastSourceId: String? = nil,
        lastContentReference: ProviderContentReference? = nil,
        providerTransportKind: DownloadProviderTransportKind? = nil,
        validatedExpectedContentLength: Int64? = nil,
        protectedOwnerProfileID: UUID? = nil,
        nuvioOwnerProfileID: UUID? = nil,
        streamName: String? = nil,
        originalAudioLanguage: String? = nil,
        isAnime: Bool,
        episodePlaybackContext: EpisodePlaybackContext? = nil
    ) -> DownloadEnqueueResult {
        let recoveryMetadata = Self.validatedRecoveryMetadata(
            legacySourceId: sourceId,
            legacyServiceHref: serviceContentHref,
            sourceId: lastSourceId,
            contentReference: lastContentReference
        )
        let id = Self.downloadID(
            tmdbId: tmdbId,
            isMovie: isMovie,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber
        )

        var item = DownloadItem(
            id: id,
            tmdbId: tmdbId,
            isMovie: isMovie,
            title: title,
            displayTitle: displayTitle,
            posterURL: posterURL,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            episodeName: episodeName,
            streamURL: streamURL,
            headers: headers,
            subtitleURL: subtitleURL,
            subtitleHeaders: subtitleHeaders,
            serviceBaseURL: serviceBaseURL,
            sourceId: sourceId,
            serviceContentHref: serviceContentHref,
            lastSourceId: recoveryMetadata.sourceId,
            lastContentReference: recoveryMetadata.reference,
            providerTransportKind: providerTransportKind,
            validatedExpectedContentLength: validatedExpectedContentLength,
            streamName: streamName,
            originalAudioLanguage: originalAudioLanguage,
            episodePlaybackContext: episodePlaybackContext,
            status: .queued,
            progress: 0,
            totalBytes: 0,
            downloadedBytes: 0,
            localFileName: nil,
            subtitleFileName: nil,
            error: nil,
            dateAdded: Date(),
            dateCompleted: nil,
            isAnime: isAnime
        )
#if os(iOS) && !targetEnvironment(macCatalyst)
        if let providerKind = ProtectedDownloadPersistencePolicy.inferredProviderKind(
            sourceID: item.lastSourceId,
            reference: item.lastContentReference
        ) {
            item.protectedProviderKind = providerKind
            item.protectedOwnerProfileID = protectedOwnerProfileID
                ?? nuvioOwnerProfileID
                ?? ProfileManager.shared.activeProfileID
            item.protectedTransportKind = ProtectedDownloadPersistencePolicy.transportKind(
                for: item.streamURL
            )
            if providerKind == .nuvio {
                item.nuvioOwnerProfileID = item.protectedOwnerProfileID
                item.nuvioTransportKind = item.protectedTransportKind
            }
        } else if providerTransportKind == .skyStreamDirect,
                  item.lastContentReference?.kind == .skyStream {
            item.protectedProviderKind = .skyStream
            item.protectedOwnerProfileID = protectedOwnerProfileID
                ?? ProfileManager.shared.activeProfileID
            item.protectedTransportKind = .direct
        }
#endif

#if os(iOS)
        if !isMovie,
           let seasonNumber,
           let episodeNumber,
           episodePlaybackContext != nil,
           let equivalent = matchingEpisodeDownloadItem(
               tmdbId: tmdbId,
               seasonNumber: seasonNumber,
               episodeNumber: episodeNumber,
               playbackContext: episodePlaybackContext,
               accepting: { candidate in
                   candidate.status == .downloading || candidate.status == .queued || candidate.status == .paused
                       || (candidate.status == .completed && self.localFileURL(for: candidate) != nil)
               }
           ) {
            Logger.shared.log("Download already exists by provider identity: \(equivalent.id)", type: "Download")
            return .alreadyExists
        }
#endif

        if let existing = downloads.first(where: { $0.id == id }) {
            switch existing.status {
            case .completed:
                if localFileURL(for: existing) != nil {
                    Logger.shared.log("Download already exists: \(id) status=\(existing.status.rawValue)", type: "Download")
                    return .alreadyExists
                }
                if adoptExistingDownloadedFileIfPresent(for: item) {
                    Logger.shared.log("Adopted existing download file for missing metadata path: \(displayTitle)", type: "Download")
                    return .adoptedExistingFile
                }
#if os(iOS) && !targetEnvironment(macCatalyst)
                clearProtectedProviderDownloadRuntimeState(id: id, scrubTransport: false)
#endif
                downloads.removeAll { $0.id == id }
            case .downloading, .queued, .paused:
                Logger.shared.log("Download already exists: \(id) status=\(existing.status.rawValue)", type: "Download")
                return .alreadyExists
            case .failed:
                if adoptExistingDownloadedFileIfPresent(for: item) {
                    Logger.shared.log("Skipped download by adopting existing file: \(displayTitle)", type: "Download")
                    return .adoptedExistingFile
                }
                deleteDownloadFiles(for: existing, includePartial: true, removingIDs: Set([id]))
#if os(iOS) && !targetEnvironment(macCatalyst)
                clearProtectedProviderDownloadRuntimeState(id: id, scrubTransport: false)
#endif
                downloads.removeAll { $0.id == id }
            }
        } else if adoptExistingDownloadedFileIfPresent(for: item) {
            Logger.shared.log("Skipped download by adopting existing file: \(displayTitle)", type: "Download")
            return .adoptedExistingFile
        }

        item = itemByReservingVideoDestination(item)
        downloads.append(item)
        saveDownloads()
        captureKidsPolicyDetails(forDownload: id, tmdbId: tmdbId, isMovie: isMovie)
        processQueue()

        Logger.shared.log("Enqueued download: \(displayTitle) id=\(id)", type: "Download")
        return .enqueued
    }

    private func captureKidsPolicyDetails(forDownload id: String, tmdbId: Int, isMovie: Bool) {
        Task { [weak self] in
            let details: KidsPolicyDetails
            do {
                if isMovie {
                    let detail = try await TMDBService.shared.getMovieDetails(id: tmdbId)
                    details = KidsPolicyDetails(
                        isAdult: detail.adult,
                        genreIds: detail.genres.map(\.id),
                        overview: detail.overview
                    )
                } else {
                    let detail = try await TMDBService.shared.getTVShowDetails(id: tmdbId)
                    details = KidsPolicyDetails(
                        isAdult: detail.adult,
                        genreIds: detail.genres.map(\.id),
                        overview: detail.overview
                    )
                }
            } catch {
                Logger.shared.log(
                    "Download \(id) stored without kids-policy details: \(error.localizedDescription)",
                    type: "Download"
                )
                return
            }
            self?.performOnMain { [weak self] in
                guard let self,
                      let index = downloads.firstIndex(where: { $0.id == id }) else { return }
                downloads[index].kidsPolicyDetails = details
                saveDownloads()
            }
        }
    }

    private func backfillKidsPolicyDetailsIfNeeded() {
        for item in downloads where item.status == .completed && item.kidsPolicyDetails == nil {
            captureKidsPolicyDetails(forDownload: item.id, tmdbId: item.tmdbId, isMovie: item.isMovie)
        }
    }

    func pauseDownload(id: String) {
        performOnMain { [weak self] in
            guard let self,
                  let index = downloads.firstIndex(where: { $0.id == id }),
                  downloads[index].status == .downloading else { return }

#if os(iOS) && !targetEnvironment(macCatalyst)
            let isProtectedProvider = downloads[index].claimsProtectedProviderTransport
            if isProtectedProvider {
                if let task = activeTasks.removeValue(forKey: id) {
                    invalidatedDirectTaskIdentifiers.insert(task.taskIdentifier)
                    task.cancel()
                }
                if let downloader = activeHLSDownloaders.removeValue(forKey: id) {
                    if let attemptID = activeHLSAttemptIDs.removeValue(forKey: id) {
                        invalidatedHLSAttemptIDs.insert(attemptID)
                    }
                    downloader.cancel()
                }
                clearProtectedProviderDownloadRuntimeState(id: id, scrubTransport: true)
                guard let currentIndex = downloads.firstIndex(where: { $0.id == id }) else { return }
                downloads[currentIndex].status = .paused
                saveDownloads()
                processQueue()
                Logger.shared.log("Paused protected provider download: \(id)", type: "Download")
                return
            }
#endif

            if let task = activeTasks[id] {
                let pausedTaskIdentifier = task.taskIdentifier
                pendingResumeDataTaskIdentifiers[id] = pausedTaskIdentifier
                task.cancel(byProducingResumeData: { [weak self] data in
                    guard let data else { return }
                    self?.performOnMain {
                        guard let self,
                              self.pendingResumeDataTaskIdentifiers[id] == pausedTaskIdentifier,
                              self.activeTasks[id] == nil,
                              self.downloads.first(where: { $0.id == id })?.status == .paused else {
                            return
                        }
                        self.pendingResumeDataTaskIdentifiers.removeValue(forKey: id)
                        self.resumeDataStore[id] = data
                    }
                })
                activeTasks.removeValue(forKey: id)
                invalidatedDirectTaskIdentifiers.insert(task.taskIdentifier)
            } else if let downloader = activeHLSDownloaders[id] {

                downloader.cancel()
            }
            guard let currentIndex = downloads.firstIndex(where: { $0.id == id }) else {
                return
            }
            downloads[currentIndex].status = .paused
            saveDownloads()
            processQueue()
            Logger.shared.log("Paused download: \(id)", type: "Download")
        }
    }

    func resumeDownload(id: String) {
        performOnMain { [weak self] in
            guard let self,
                  !cloudflareRecoveringDownloadIDs.contains(id),
                  let index = downloads.firstIndex(where: { $0.id == id }),
                  downloads[index].status == .paused || downloads[index].status == .failed else {
                return
            }

            downloads[index].status = .queued
            pendingResumeDataTaskIdentifiers.removeValue(forKey: id)
            downloads[index].retryNotBefore = nil
            downloads[index].rateLimitRetryCount = nil
            downloads[index].error = nil

            if downloads[index].isHLS && downloads[index].hlsResumeSegmentIndex == nil {
                downloads[index].progress = 0
                downloads[index].downloadedBytes = 0
                downloads[index].totalBytes = 0
            }
            saveDownloads()
            processQueue()
            Logger.shared.log("Resumed download: \(id)", type: "Download")
        }
    }

    func cancelDownload(id: String) {
        performOnMain { [weak self] in
            guard let self else { return }
            if let task = activeTasks[id] {
                task.cancel()
                activeTasks.removeValue(forKey: id)
                invalidatedDirectTaskIdentifiers.insert(task.taskIdentifier)
            }
            if let downloader = activeHLSDownloaders[id] {
                if let attemptID = activeHLSAttemptIDs[id] {
                    invalidatedHLSAttemptIDs.insert(attemptID)
                }
                downloader.cancel()
            }
#if os(iOS) && !targetEnvironment(macCatalyst)
            clearSkyStreamDownloadRuntimeState(id: id, discardDescriptor: true)
            clearProtectedProviderDownloadRuntimeState(id: id, scrubTransport: false)
#endif
            resumeDataStore.removeValue(forKey: id)
            pendingResumeDataTaskIdentifiers.removeValue(forKey: id)
            lastHLSCheckpointSave.removeValue(forKey: id)
            removeDownload(id: id, deleteFile: true)
            processQueue()

            Logger.shared.log("Cancelled download: \(id)", type: "Download")
        }
    }

    func removeDownload(id: String, deleteFile: Bool) {
        let removal = {
#if os(iOS) && !targetEnvironment(macCatalyst)
            self.clearSkyStreamDownloadRuntimeState(id: id, discardDescriptor: true)
            self.clearProtectedProviderDownloadRuntimeState(id: id, scrubTransport: false)
#endif
            if let task = self.activeTasks.removeValue(forKey: id) {
                self.invalidatedDirectTaskIdentifiers.insert(task.taskIdentifier)
                task.cancel()
            }
            self.pendingResumeDataTaskIdentifiers.removeValue(forKey: id)
            if let downloader = self.activeHLSDownloaders[id] {
                if let attemptID = self.activeHLSAttemptIDs[id] {
                    self.invalidatedHLSAttemptIDs.insert(attemptID)
                }

                downloader.cancel()
            }
            if let item = self.downloads.first(where: { $0.id == id }) {
                if deleteFile {
                    self.deleteDownloadFiles(for: item, includePartial: true, removingIDs: Set([id]))
                }
                self.downloads.removeAll { $0.id == id }
                self.saveDownloads()
            }
        }
        if Thread.isMainThread {
            removal()
        } else {
            DispatchQueue.main.sync(execute: removal)
        }
    }

    func deleteAllForShow(tmdbId: Int) {
        let removal = {
            let matchingIds = Set(self.downloads.filter {
                $0.tmdbId == tmdbId && $0.status == .completed
            }.map { $0.id })
            guard !matchingIds.isEmpty else { return }
            for item in self.downloads where matchingIds.contains(item.id) {
#if os(iOS) && !targetEnvironment(macCatalyst)
                self.clearSkyStreamDownloadRuntimeState(id: item.id, discardDescriptor: true)
                self.clearProtectedProviderDownloadRuntimeState(id: item.id, scrubTransport: false)
#endif
                self.deleteDownloadFiles(for: item, includePartial: false, removingIDs: matchingIds)
            }
            self.downloads.removeAll { matchingIds.contains($0.id) }
            self.saveDownloads()
        }
        if Thread.isMainThread {
            removal()
        } else {
            DispatchQueue.main.sync(execute: removal)
        }
    }

    func deleteAllCompleted() {
        let removal = {
            let completedIds = Set(self.downloads.filter { $0.status == .completed }.map { $0.id })
            guard !completedIds.isEmpty else { return }
            for item in self.downloads where completedIds.contains(item.id) {
#if os(iOS) && !targetEnvironment(macCatalyst)
                self.clearSkyStreamDownloadRuntimeState(id: item.id, discardDescriptor: true)
                self.clearProtectedProviderDownloadRuntimeState(id: item.id, scrubTransport: false)
#endif
                self.deleteDownloadFiles(for: item, includePartial: false, removingIDs: completedIds)
            }
            self.downloads.removeAll { completedIds.contains($0.id) }
            self.saveDownloads()
        }
        if Thread.isMainThread {
            removal()
        } else {
            DispatchQueue.main.sync(execute: removal)
        }
    }

    func deleteAll() {

        for (_, task) in activeTasks {
            invalidatedDirectTaskIdentifiers.insert(task.taskIdentifier)
            task.cancel()
        }
        activeTasks.removeAll()
        pendingResumeDataTaskIdentifiers.removeAll()
        for (_, downloader) in activeHLSDownloaders {
            downloader.cancel()
        }
        invalidatedHLSAttemptIDs.formUnion(activeHLSAttemptIDs.values)
#if os(iOS) && !targetEnvironment(macCatalyst)
        for proxyURL in skyStreamHLSProxyURLs.values {
            MPVHeaderProxy.shared.invalidateSession(for: proxyURL)
        }
        skyStreamHLSProxyURLs.removeAll()
        skyStreamHLSPinnedVariantURLs.removeAll()
        skyStreamHLSDescriptors.removeAll()
        invalidateAllProtectedProviderAttempts()
        nuvioRestoringDownloadIDs.removeAll()
#endif
        nuvioDispatchValidationPendingIDs.removeAll()
        nuvioDispatchApprovedIDs.removeAll()
        nuvioDispatchValidationTokens.removeAll()
        resumeDataStore.removeAll()

        let dir = downloadsDirectory
        if let contents = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for fileURL in contents {

                if fileURL.lastPathComponent == ".downloads_metadata.json" { continue }
                try? fileManager.removeItem(at: fileURL)
            }
        }

        DispatchQueue.main.async {
            self.downloads.removeAll()
            self.saveDownloads()
        }
    }

    func pauseAll() {
        let active = downloads.filter { $0.status == .downloading || $0.status == .queued }
        for item in active {
            if item.status == .downloading {
                pauseDownload(id: item.id)
            } else {
                if let index = downloads.firstIndex(where: { $0.id == item.id }),
                   downloads[index].status == .queued {
                    downloads[index].status = .paused
                }
            }
        }
        saveDownloads()
    }

    func resumeAll() {
        let paused = downloads.filter { $0.status == .paused }
        for item in paused {
            resumeDownload(id: item.id)
        }
    }

    func retryAllFailed() {
        let failed = downloads.filter { $0.status == .failed }
        for item in failed {
            resumeDownload(id: item.id)
        }
    }

    func cancelAllActive() {
        let active = downloads.filter { $0.status == .downloading || $0.status == .queued || $0.status == .paused }
        for item in active {
            cancelDownload(id: item.id)
        }
    }

    func localFileURL(for item: DownloadItem) -> URL? {
        guard let fileName = item.localFileName else { return nil }
        return existingDownloadFileURL(relativePath: fileName)
    }

    func localSubtitleURL(for item: DownloadItem) -> URL? {
        guard let fileName = item.subtitleFileName else { return nil }
        return existingDownloadFileURL(relativePath: fileName)
    }

    func isDownloaded(tmdbId: Int, isMovie: Bool, seasonNumber: Int? = nil, episodeNumber: Int? = nil) -> Bool {
        let id: String
        if isMovie {
            id = "dl_movie_\(tmdbId)"
        } else {
            id = "dl_ep_\(tmdbId)_s\(seasonNumber ?? 0)_e\(episodeNumber ?? 0)"
        }
        return downloads.first(where: {
            $0.id == id && $0.status == .completed && localFileURL(for: $0) != nil
        }) != nil
    }

    func isDownloading(tmdbId: Int, isMovie: Bool, seasonNumber: Int? = nil, episodeNumber: Int? = nil) -> Bool {
        let id: String
        if isMovie {
            id = "dl_movie_\(tmdbId)"
        } else {
            id = "dl_ep_\(tmdbId)_s\(seasonNumber ?? 0)_e\(episodeNumber ?? 0)"
        }
        return downloads.first(where: { $0.id == id && ($0.status == .downloading || $0.status == .queued) }) != nil
    }

    func downloadItem(tmdbId: Int, isMovie: Bool, seasonNumber: Int? = nil, episodeNumber: Int? = nil) -> DownloadItem? {
        let id: String
        if isMovie {
            id = "dl_movie_\(tmdbId)"
        } else {
            id = "dl_ep_\(tmdbId)_s\(seasonNumber ?? 0)_e\(episodeNumber ?? 0)"
        }
        return downloads.first(where: { $0.id == id })
    }

    func completedDownloadItem(tmdbId: Int, isMovie: Bool, seasonNumber: Int? = nil, episodeNumber: Int? = nil) -> DownloadItem? {
        guard let item = downloadItem(
            tmdbId: tmdbId,
            isMovie: isMovie,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber
        ),
              item.status == .completed,
              localFileURL(for: item) != nil else {
            return nil
        }
        return item
    }

#if os(iOS)

    func completedEpisodeDownloadItem(
        tmdbId: Int,
        seasonNumber: Int,
        episodeNumber: Int,
        playbackContext: EpisodePlaybackContext?
    ) -> DownloadItem? {
        matchingEpisodeDownloadItem(
            tmdbId: tmdbId,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            playbackContext: playbackContext
        ) { item in
            item.status == .completed && self.localFileURL(for: item) != nil
        }
    }

    func activeEpisodeDownloadItem(
        tmdbId: Int,
        seasonNumber: Int,
        episodeNumber: Int,
        playbackContext: EpisodePlaybackContext?
    ) -> DownloadItem? {
        matchingEpisodeDownloadItem(
            tmdbId: tmdbId,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            playbackContext: playbackContext
        ) { item in
            item.status == .downloading || item.status == .queued || item.status == .paused
        }
    }

    private func matchingEpisodeDownloadItem(
        tmdbId: Int,
        seasonNumber: Int,
        episodeNumber: Int,
        playbackContext: EpisodePlaybackContext?,
        accepting: (DownloadItem) -> Bool
    ) -> DownloadItem? {
        func canonicalProviderID(_ rawID: Int) -> Int {
            animeProviderAliasesByTMDBID[tmdbId]?[rawID] ?? rawID
        }
        let requestedHasProviderIdentity = playbackContext?.anilistMediaId != nil
            || playbackContext?.kitsuMediaId != nil
        let exactID = Self.downloadID(
            tmdbId: tmdbId,
            isMovie: false,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber
        )
        let exactCoordinateItem = downloads.first {
            $0.id == exactID && accepting($0)
        }

        func matchesExactTMDBIdentity(_ candidate: DownloadItem) -> Bool? {
            guard let candidateContext = candidate.episodePlaybackContext,
                  let candidateSeason = candidateContext.resolvedTMDBSeasonNumber,
                  let candidateEpisode = candidateContext.resolvedTMDBEpisodeNumber else {
                return nil
            }
            let requestedSeason = playbackContext?.resolvedTMDBSeasonNumber ?? seasonNumber
            let requestedEpisode = playbackContext?.resolvedTMDBEpisodeNumber ?? episodeNumber
            return candidateSeason == requestedSeason && candidateEpisode == requestedEpisode
        }

        func matchesProviderIdentity(_ candidate: DownloadItem) -> Bool {
            guard let playbackContext else { return false }

            if let candidateContext = candidate.episodePlaybackContext {
                return AnimeEpisodeIdentityPolicy.isSameEpisode(
                    playbackContext,
                    candidateContext,
                    providerAliases: animeProviderAliasesByTMDBID[tmdbId] ?? [:]
                )
            }

            if let requestedAniListID = playbackContext.anilistMediaId,
               let candidateSeason = candidate.seasonNumber,
               let candidateProviderID = AnimeSyntheticSeasonKey.providerID(from: candidateSeason),
               canonicalProviderID(candidateProviderID) == canonicalProviderID(requestedAniListID) {
                return candidate.episodeNumber == playbackContext.localEpisodeNumber
            }
            return false
        }

        if let exactCoordinateItem {
            if requestedHasProviderIdentity {
                if matchesProviderIdentity(exactCoordinateItem) {
                    return exactCoordinateItem
                }

                if exactCoordinateItem.episodePlaybackContext == nil {
                    return exactCoordinateItem
                }
            } else if matchesExactTMDBIdentity(exactCoordinateItem) != false {

                return exactCoordinateItem
            }
        }

        let requestedTMDBSeason = playbackContext?.resolvedTMDBSeasonNumber ?? seasonNumber
        let requestedTMDBEpisode = playbackContext?.resolvedTMDBEpisodeNumber ?? episodeNumber

        return downloads.first { candidate in
            guard !candidate.isMovie,
                  candidate.tmdbId == tmdbId,
                  accepting(candidate) else {
                return false
            }

            if requestedHasProviderIdentity {
                return matchesProviderIdentity(candidate)
            }

            if let candidateContext = candidate.episodePlaybackContext,
               candidateContext.resolvedTMDBSeasonNumber == requestedTMDBSeason,
               candidateContext.resolvedTMDBEpisodeNumber == requestedTMDBEpisode {
                return true
            }
            return false
        }
    }
#endif

    func calculateStorageUsed() -> Int64 {
        var total: Int64 = 0
        for item in downloads where item.status == .completed {
            if let url = localFileURL(for: item) {
                if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? Int64 {
                    total += size
                }
            }
        }
        return total
    }

    private func downloadFileCandidates(relativePath: String) -> [URL] {
        guard let cleanedPath = normalizedDownloadRelativePath(relativePath) else { return [] }

        return uniqueURLs([
            downloadsDirectory.appendingPathComponent(cleanedPath),
            legacyDownloadsDirectory.appendingPathComponent(cleanedPath)
        ])
    }

    private func existingDownloadFileURL(relativePath: String) -> URL? {
        downloadFileCandidates(relativePath: relativePath).first { isRegularFile(at: $0) }
    }

    private func isRegularFile(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return !isDirectory.boolValue
    }

    private func ensureParentDirectoryExists(for url: URL) {
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func deleteFileIfExists(
        relativePath: String,
        removingIDs: Set<String>,
        removeEmptyParents: Bool = true
    ) {
        guard !isRelativePathReferenced(relativePath, excludingIDs: removingIDs) else {
            Logger.shared.log(
                "Kept shared download path while removing \(removingIDs.count) item(s): \(relativePath)",
                type: "Download"
            )
            return
        }

        for url in downloadFileCandidates(relativePath: relativePath) where isRegularFile(at: url) {
            try? fileManager.removeItem(at: url)
            if removeEmptyParents {
                removeEmptyDownloadDirectories(startingAt: url.deletingLastPathComponent())
            }
        }
    }

    private func deleteDownloadFiles(
        for item: DownloadItem,
        includePartial: Bool,
        removingIDs: Set<String>
    ) {
        if let fileName = item.localFileName {
            deleteFileIfExists(relativePath: fileName, removingIDs: removingIDs)
        }
        if let subFile = item.subtitleFileName {
            deleteFileIfExists(relativePath: subFile, removingIDs: removingIDs)
        }
        if includePartial {
            for partialURL in hlsPartialFileCandidates(for: item) where isRegularFile(at: partialURL) {
                guard !isPartialPathReferenced(partialURL, excludingIDs: removingIDs) else { continue }
                try? fileManager.removeItem(at: partialURL)
                removeEmptyDownloadDirectories(startingAt: partialURL.deletingLastPathComponent())
            }
        }
    }

    private func removeEmptyDownloadDirectories(startingAt startDirectory: URL) {
        let rootPath = downloadsDirectory.standardizedFileURL.path
        var directory = startDirectory.standardizedFileURL

        while directory.path.hasPrefix(rootPath + "/") {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: directory.path),
                  contents.isEmpty else {
                return
            }
            try? fileManager.removeItem(at: directory)
            directory = directory.deletingLastPathComponent()
        }
    }

    private func migrateLegacyDownloadsDirectoryIfNeeded() {
        let legacyDir = legacyDownloadsDirectory
        let currentDir = downloadsDirectory
        guard legacyDir.standardizedFileURL.path != currentDir.standardizedFileURL.path,
              fileManager.fileExists(atPath: legacyDir.path),
              let contents = try? fileManager.contentsOfDirectory(at: legacyDir, includingPropertiesForKeys: nil) else {
            return
        }

        for sourceURL in contents {
            let targetURL = currentDir.appendingPathComponent(sourceURL.lastPathComponent)
            if fileManager.fileExists(atPath: targetURL.path) { continue }

            do {
                try fileManager.moveItem(at: sourceURL, to: targetURL)
            } catch {
                do {
                    try fileManager.copyItem(at: sourceURL, to: targetURL)
                } catch {
                    Logger.shared.log("Failed migrating legacy download \(sourceURL.lastPathComponent): \(error.localizedDescription)", type: "Download")
                }
            }
        }

        if let remaining = try? fileManager.contentsOfDirectory(atPath: legacyDir.path), remaining.isEmpty {
            try? fileManager.removeItem(at: legacyDir)
        }
    }

    private func ensureDownloadPathReservations() {
        guard !downloads.isEmpty else { return }

        let priorVideoReservations = downloads.map(\.reservedVideoFileName)
        let priorSubtitleReservations = downloads.map(\.reservedSubtitleFileName)
        var changed = false

        for index in downloads.indices {
            let trackedVideo = downloads[index].localFileName.flatMap(normalizedDownloadRelativePath)
            let trackedSubtitle = downloads[index].subtitleFileName.flatMap(normalizedDownloadRelativePath)
            if downloads[index].reservedVideoFileName != trackedVideo {
                downloads[index].reservedVideoFileName = trackedVideo
                changed = true
            }
            if downloads[index].reservedSubtitleFileName != trackedSubtitle {
                downloads[index].reservedSubtitleFileName = trackedSubtitle
                changed = true
            }
        }

        for index in downloads.indices {
            var item = downloads[index]
            if item.localFileName == nil {
                let prior = priorVideoReservations[index].flatMap(normalizedDownloadRelativePath)
                if let prior, isVideoReservationAvailable(prior, for: item) {
                    item.reservedVideoFileName = prior
                } else {
                    item = itemByReservingVideoDestination(item)
                }
            }
            if item.subtitleFileName == nil,
               let prior = priorSubtitleReservations[index].flatMap(normalizedDownloadRelativePath),
               isExactRelativePathAvailable(prior, for: item.id) {
                item.reservedSubtitleFileName = prior
            }

            if downloads[index].reservedVideoFileName != item.reservedVideoFileName ||
                downloads[index].reservedSubtitleFileName != item.reservedSubtitleFileName {
                downloads[index] = item
                changed = true
            }
        }

        if changed {
            saveDownloads()
        }
    }

    private func migrateTrackedDownloadsToPublicLayout() {
        guard !downloads.isEmpty else { return }
        var changed = false
        var claimedSourcePaths = Set<String>()

        for index in downloads.indices {
            var item = downloads[index]
            guard item.status == .completed else { continue }

            if let trackedPath = item.localFileName,
               let fileURL = migrationSourceURL(
                    relativePath: trackedPath,
                    claimedSourcePaths: &claimedSourcePaths
               ),
               let migratedPath = migrateVideoFileToPublicLayout(fileURL, for: item) {
                downloads[index].localFileName = migratedPath
                downloads[index].reservedVideoFileName = migratedPath
                if let attrs = try? fileManager.attributesOfItem(atPath: downloadFileURL(relativePath: migratedPath).path),
                   let size = attrs[.size] as? Int64 {
                    downloads[index].totalBytes = size
                    downloads[index].downloadedBytes = size
                }
                changed = true
            }

            item = downloads[index]
            if let trackedSubtitlePath = item.subtitleFileName,
               let subtitleURL = migrationSourceURL(
                    relativePath: trackedSubtitlePath,
                    claimedSourcePaths: &claimedSourcePaths
               ),
               let migratedSubtitlePath = migrateSubtitleFileToPublicLayout(subtitleURL, for: item) {
                downloads[index].subtitleFileName = migratedSubtitlePath
                downloads[index].reservedSubtitleFileName = migratedSubtitlePath
                changed = true
            }
        }

        if changed {
            saveDownloads()
        }
    }

    private func migrationSourceURL(
        relativePath: String,
        claimedSourcePaths: inout Set<String>
    ) -> URL? {
        let candidates = downloadFileCandidates(relativePath: relativePath).filter(isRegularFile)
        guard let source = candidates.first(where: {
            !claimedSourcePaths.contains(canonicalAbsolutePath($0))
        }) ?? candidates.first else {
            return nil
        }
        claimedSourcePaths.insert(canonicalAbsolutePath(source))
        return source
    }

    private func migrateVideoFileToPublicLayout(_ fileURL: URL, for item: DownloadItem) -> String? {
        if isInsidePublicDownloadsDirectory(fileURL), let tracked = item.localFileName {
            return normalizedDownloadRelativePath(tracked) ?? relativePathForDownloadFile(fileURL)
        }

        let ext = sanitizedFileExtension(fileURL.pathExtension, fallback: item.isHLS ? "ts" : "mp4")
        let trackedPath = item.localFileName.flatMap(normalizedDownloadRelativePath)
        let targetRelativePath: String
        if let trackedPath,
           safeToCreateVideoDestination(trackedPath, for: item, sourceURL: fileURL) {
            targetRelativePath = trackedPath
        } else {
            targetRelativePath = allocatedVideoRelativePath(
                for: item,
                fileExtension: ext,
                forceIdentitySuffix: true,
                avoidExistingFiles: true
            )
        }
        return moveFileIntoDownloadsIfNeeded(fileURL, targetRelativePath: targetRelativePath)
    }

    private func migrateSubtitleFileToPublicLayout(_ fileURL: URL, for item: DownloadItem) -> String? {
        if isInsidePublicDownloadsDirectory(fileURL), let tracked = item.subtitleFileName {
            return normalizedDownloadRelativePath(tracked) ?? relativePathForDownloadFile(fileURL)
        }

        let ext = sanitizedFileExtension(fileURL.pathExtension, fallback: "srt")
        let trackedPath = item.subtitleFileName.flatMap(normalizedDownloadRelativePath)
        let targetRelativePath: String
        if let trackedPath,
           safeToCreateDestination(trackedPath, for: item.id, sourceURL: fileURL) {
            targetRelativePath = trackedPath
        } else {
            targetRelativePath = allocatedSubtitleRelativePath(
                for: item,
                fileExtension: ext,
                avoidExistingFiles: true
            )
        }
        return moveFileIntoDownloadsIfNeeded(fileURL, targetRelativePath: targetRelativePath)
    }

    private func moveFileIntoDownloadsIfNeeded(_ sourceURL: URL, targetRelativePath: String) -> String? {
        let targetURL = downloadFileURL(relativePath: targetRelativePath)
        if sourceURL.standardizedFileURL.path == targetURL.standardizedFileURL.path {
            return targetRelativePath
        }

        if fileManager.fileExists(atPath: targetURL.path) {

            return relativePathForDownloadFile(sourceURL)
        }

        ensureParentDirectoryExists(for: targetURL)
        do {
            try fileManager.moveItem(at: sourceURL, to: targetURL)
            removeEmptyDownloadDirectories(startingAt: sourceURL.deletingLastPathComponent())
            return targetRelativePath
        } catch {
            do {
                try fileManager.copyItem(at: sourceURL, to: targetURL)
                return targetRelativePath
            } catch {
                Logger.shared.log("Failed moving download into public layout: \(error.localizedDescription)", type: "Download")
                return relativePathForDownloadFile(sourceURL)
            }
        }
    }

    private func adoptExistingDownloadedFileIfPresent(for item: DownloadItem) -> Bool {
        guard let videoURL = findExistingVideoFile(for: item) else { return false }

        var adoptedItem = item
        let adoptedVideoPath = relativePathForDownloadFile(videoURL)
        guard isExactRelativePathAvailable(adoptedVideoPath, for: item.id) else { return false }
        adoptedItem.status = .completed
        adoptedItem.progress = 1.0
        adoptedItem.localFileName = adoptedVideoPath
        adoptedItem.reservedVideoFileName = adoptedVideoPath
        adoptedItem.error = nil

        if let attrs = try? fileManager.attributesOfItem(atPath: videoURL.path) {
            if let size = attrs[.size] as? Int64 {
                adoptedItem.totalBytes = size
                adoptedItem.downloadedBytes = size
            }
            adoptedItem.dateCompleted = (attrs[.modificationDate] as? Date) ?? Date()
        } else {
            adoptedItem.dateCompleted = Date()
        }

        if let subtitleURL = findExistingSubtitleFile(for: adoptedItem, videoURL: videoURL) {
            let subtitlePath = relativePathForDownloadFile(subtitleURL)
            if isExactRelativePathAvailable(subtitlePath, for: item.id) {
                adoptedItem.subtitleFileName = subtitlePath
                adoptedItem.reservedSubtitleFileName = subtitlePath
            }
        }

        let update = {
            if let index = self.downloads.firstIndex(where: { $0.id == item.id }) {

                if adoptedItem.kidsPolicyDetails == nil {
                    adoptedItem.kidsPolicyDetails = self.downloads[index].kidsPolicyDetails
                }
                self.downloads[index] = adoptedItem
            } else {
                self.downloads.append(adoptedItem)
            }
            self.saveDownloads()
            if adoptedItem.kidsPolicyDetails == nil {
                self.captureKidsPolicyDetails(
                    forDownload: adoptedItem.id,
                    tmdbId: adoptedItem.tmdbId,
                    isMovie: adoptedItem.isMovie
                )
            }
        }

        if Thread.isMainThread {
            update()
        } else {

            DispatchQueue.main.sync(execute: update)
        }

        return true
    }

    private func findExistingVideoFile(for item: DownloadItem) -> URL? {

        if let tracked = downloads.first(where: { $0.id == item.id }) {
            for path in uniqueStrings([tracked.localFileName, tracked.reservedVideoFileName].compactMap { $0 }) {
                if let url = existingDownloadFileURL(relativePath: path) {
                    return url
                }
            }
        }

        let extensions = candidateVideoExtensions(for: item)
        let reservedItem = itemByReservingVideoDestination(item)
        let exactPaths = candidateVideoRelativePaths(for: reservedItem, extensions: extensions)

        for path in exactPaths {
            if isExactRelativePathAvailable(path, for: item.id),
               let url = existingDownloadFileURL(relativePath: path) {
                return url
            }
        }

        if reservedItem.isMovie {
            let stem = videoRelativePath(for: reservedItem, fileExtension: "mp4")
                .components(separatedBy: ".")
                .dropLast()
                .joined(separator: ".")
            return findMatchingFile(
                in: downloadsDirectory,
                stemMatches: [stem],
                extensions: extensions,
                claimantID: item.id
            )
        }

        let reservedPath = videoRelativePath(for: reservedItem, fileExtension: "mp4")
        let showFolder = reservedPath.split(separator: "/").first.map(String.init) ?? showFolderName(for: item)
        let showDirectory = downloadsDirectory.appendingPathComponent(showFolder, isDirectory: true)
        let episodeCode = episodeCode(for: item)
        return findMatchingFile(
            in: showDirectory,
            stemMatches: [episodeCode],
            stemPrefixes: ["\(episodeCode) - "],
            extensions: extensions,
            claimantID: item.id
        )
    }

    private func findExistingSubtitleFile(for item: DownloadItem, videoURL: URL) -> URL? {
        let subtitleExtensions = Array(Self.knownSubtitleExtensions).sorted()
        if let tracked = downloads.first(where: { $0.id == item.id }) {
            for path in uniqueStrings([tracked.subtitleFileName, tracked.reservedSubtitleFileName].compactMap { $0 }) {
                if let url = existingDownloadFileURL(relativePath: path) {
                    return url
                }
            }
        }

        let exactPaths = subtitleExtensions.map { subtitleRelativePath(for: item, fileExtension: $0) }
        for path in exactPaths {
            if isExactRelativePathAvailable(path, for: item.id),
               let url = existingDownloadFileURL(relativePath: path) {
                return url
            }
        }

        let videoStem = videoURL.deletingPathExtension().lastPathComponent
        return findMatchingFile(
            in: videoURL.deletingLastPathComponent(),
            stemPrefixes: ["\(videoStem).sub", "\(videoStem) - subtitles", "\(videoStem) subtitles"],
            extensions: subtitleExtensions,
            claimantID: item.id
        )
    }

    private func candidateVideoRelativePaths(for item: DownloadItem, extensions: [String]) -> [String] {
        var paths: [String] = []
        for ext in extensions {
            paths.append(videoRelativePath(for: item, fileExtension: ext, includeEpisodeName: true))
            if !item.isMovie {
                paths.append(videoRelativePath(for: item, fileExtension: ext, includeEpisodeName: false))
            }
            paths.append("\(item.id).\(ext)")
        }
        return uniqueStrings(paths)
    }

    private func candidateVideoExtensions(for item: DownloadItem) -> [String] {
        var extensions: [String] = []
        if let url = URL(string: item.streamURL) {
            let urlExt = sanitizedFileExtension(url.pathExtension, fallback: "")
            if Self.knownVideoExtensions.contains(urlExt) {
                extensions.append(urlExt)
            }
        }
        if item.isHLS {
            extensions.append("ts")
        }
        extensions.append(contentsOf: Self.knownVideoExtensions.sorted())
        return uniqueStrings(extensions)
    }

    private func findMatchingFile(
        in directory: URL,
        stemMatches: [String] = [],
        stemPrefixes: [String] = [],
        extensions: [String],
        claimantID: String
    ) -> URL? {
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return nil
        }

        let extensionSet = Set(extensions.map { $0.lowercased() })
        let exactStems = Set(stemMatches.map { $0.lowercased() })
        let lowercasedPrefixes = stemPrefixes.map { $0.lowercased() }

        return contents.sorted { canonicalAbsolutePath($0) < canonicalAbsolutePath($1) }.first { url in
            guard isRegularFile(at: url),
                  extensionSet.contains(url.pathExtension.lowercased()) else {
                return false
            }

            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            let relativePath = relativePathForDownloadFile(url)
            return isExactRelativePathAvailable(relativePath, for: claimantID) &&
                (exactStems.contains(stem) || lowercasedPrefixes.contains { stem.hasPrefix($0) })
        }
    }

    private func videoRelativePath(for item: DownloadItem, fileExtension: String, includeEpisodeName: Bool = true) -> String {
        let ext = sanitizedFileExtension(fileExtension, fallback: item.isHLS ? "ts" : "mp4")
        if let reservedPath = item.reservedVideoFileName.flatMap(normalizedDownloadRelativePath) {
            let components = reservedPath.split(separator: "/").map(String.init)
            if item.isMovie, let fileName = components.last {
                let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
                return "\(stem).\(ext)"
            }
            if !item.isMovie, let folder = components.first {
                let fileStem: String
                if includeEpisodeName, let fileName = components.last {
                    fileStem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
                } else {
                    fileStem = episodeCode(for: item)
                }
                return "\(folder)/\(fileStem).\(ext)"
            }
        }

        return unreservedVideoRelativePath(for: item, fileExtension: ext, includeEpisodeName: includeEpisodeName)
    }

    private func unreservedVideoRelativePath(
        for item: DownloadItem,
        fileExtension: String,
        includeEpisodeName: Bool = true,
        identitySuffix: String? = nil
    ) -> String {
        let ext = sanitizedFileExtension(fileExtension, fallback: item.isHLS ? "ts" : "mp4")
        if item.isMovie {
            return "\(fileComponent(movieFileStem(for: item), appending: identitySuffix)).\(ext)"
        }

        let folder = fileComponent(showFolderName(for: item), appending: identitySuffix)
        return "\(folder)/\(episodeFileStem(for: item, includeEpisodeName: includeEpisodeName)).\(ext)"
    }

    private func subtitleRelativePath(for item: DownloadItem, fileExtension: String) -> String {
        let ext = sanitizedFileExtension(fileExtension, fallback: "srt")
        if let reservedPath = item.reservedSubtitleFileName.flatMap(normalizedDownloadRelativePath) {
            return "\((reservedPath as NSString).deletingPathExtension).\(ext)"
        }

        let videoPath = videoRelativePath(for: item, fileExtension: "mp4")
        return "\((videoPath as NSString).deletingPathExtension).sub.\(ext)"
    }

    private func showFolderName(for item: DownloadItem) -> String {
        sanitizeFileComponent(item.playerTitleBase, fallback: "Show \(item.tmdbId)")
    }

    private func movieFileStem(for item: DownloadItem) -> String {
        sanitizeFileComponent(item.playerTitleBase, fallback: "Movie \(item.tmdbId)")
    }

    private func episodeFileStem(for item: DownloadItem, includeEpisodeName: Bool = true) -> String {
        let code = episodeCode(for: item)
        guard includeEpisodeName,
              let episodeName = item.episodeName,
              !episodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return code
        }

        return sanitizeFileComponent("\(code) - \(episodeName)", fallback: code)
    }

    private func episodeCode(for item: DownloadItem) -> String {
        String(format: "S%02dE%02d", max(item.seasonNumber ?? 0, 0), max(item.episodeNumber ?? 0, 0))
    }

    private func sanitizeFileComponent(_ value: String, fallback: String) -> String {
        var sanitized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:\n\r\t").union(.controlCharacters)
        sanitized = sanitized.components(separatedBy: invalidCharacters).joined(separator: " ")
        sanitized = sanitized.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "."))

        if sanitized.isEmpty {
            sanitized = fallback
        }
        if sanitized.count > 80 {
            sanitized = String(sanitized.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return sanitized
    }

    private func fileComponent(_ base: String, appending suffix: String?) -> String {
        let cleanBase = sanitizeFileComponent(base, fallback: "download")
        return DownloadPathIdentityPolicy.fileComponent(cleanBase, appending: suffix)
    }

    private func itemByReservingVideoDestination(_ item: DownloadItem) -> DownloadItem {
        var reservedItem = item
        if let reservation = item.reservedVideoFileName.flatMap(normalizedDownloadRelativePath),
           isVideoReservationAvailable(reservation, for: item) {
            reservedItem.reservedVideoFileName = reservation
            return reservedItem
        }

        reservedItem.reservedVideoFileName = allocatedVideoRelativePath(
            for: item,
            fileExtension: preferredReservationExtension(for: item)
        )
        return reservedItem
    }

    private func itemBySecuringFinalVideoDestination(
        _ item: DownloadItem,
        fileExtension: String
    ) -> DownloadItem {
        var securedItem = itemByReservingVideoDestination(item)
        let candidate = videoRelativePath(for: securedItem, fileExtension: fileExtension)
        let destinationExists = existingDownloadFileURL(relativePath: candidate) != nil
        let currentLocalPath = item.localFileName.map(canonicalRelativePath)
        let currentOwnsExistingFile = currentLocalPath == canonicalRelativePath(candidate)

        if isVideoReservationAvailable(candidate, for: item) &&
            (!destinationExists || currentOwnsExistingFile) {
            securedItem.reservedVideoFileName = candidate
            return securedItem
        }

        securedItem.reservedVideoFileName = allocatedVideoRelativePath(
            for: item,
            fileExtension: fileExtension,
            forceIdentitySuffix: true,
            avoidExistingFiles: true,
            blockedCanonicalPaths: [canonicalRelativePath(candidate)]
        )
        return securedItem
    }

    private func reserveFinalVideoFileName(downloadID: String, fileExtension: String) -> String {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                reserveFinalVideoFileName(downloadID: downloadID, fileExtension: fileExtension)
            }
        }
        guard let index = downloads.firstIndex(where: { $0.id == downloadID }) else {
            return "\(downloadID).\(sanitizedFileExtension(fileExtension, fallback: "mp4"))"
        }
        let securedItem = itemBySecuringFinalVideoDestination(downloads[index], fileExtension: fileExtension)
        let fileName = videoRelativePath(for: securedItem, fileExtension: fileExtension)
        downloads[index].reservedVideoFileName = fileName
        saveDownloads()
        return fileName
    }

    private func reserveFinalSubtitleFileName(downloadID: String, fileExtension: String) -> String {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                reserveFinalSubtitleFileName(downloadID: downloadID, fileExtension: fileExtension)
            }
        }
        guard let index = downloads.firstIndex(where: { $0.id == downloadID }) else {
            return "\(downloadID)_sub.\(sanitizedFileExtension(fileExtension, fallback: "srt"))"
        }
        let item = downloads[index]
        let fileName = allocatedSubtitleRelativePath(
            for: item,
            fileExtension: fileExtension,
            avoidExistingFiles: item.subtitleFileName == nil
        )
        downloads[index].reservedSubtitleFileName = fileName
        saveDownloads()
        return fileName
    }

    private func downloadOwnsTrackedPath(
        downloadID: String,
        relativePath: String,
        subtitle: Bool
    ) -> Bool {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                downloadOwnsTrackedPath(
                    downloadID: downloadID,
                    relativePath: relativePath,
                    subtitle: subtitle
                )
            }
        }
        guard let item = downloads.first(where: { $0.id == downloadID }) else { return false }
        let trackedPath = subtitle ? item.subtitleFileName : item.localFileName
        return trackedPath.map(canonicalRelativePath) == canonicalRelativePath(relativePath)
    }

    private func preferredReservationExtension(for item: DownloadItem) -> String {
        if item.isHLS { return "ts" }
        if let url = URL(string: item.streamURL) {
            let ext = sanitizedFileExtension(url.pathExtension, fallback: "")
            if Self.knownVideoExtensions.contains(ext) {
                return ext
            }
        }
        return "mp4"
    }

    private func allocatedVideoRelativePath(
        for item: DownloadItem,
        fileExtension: String,
        forceIdentitySuffix: Bool = false,
        avoidExistingFiles: Bool = false,
        blockedCanonicalPaths: Set<String> = []
    ) -> String {
        let ext = sanitizedFileExtension(fileExtension, fallback: item.isHLS ? "ts" : "mp4")
        return DownloadPathIdentityPolicy.allocateVideoRelativePath(
            request: pathIdentityRequest(for: item),
            owners: pathIdentityOwners,
            fileExtension: ext,
            forceIdentitySuffix: forceIdentitySuffix
        ) { candidate in
            blockedCanonicalPaths.contains(canonicalRelativePath(candidate)) ||
                (avoidExistingFiles && existingDownloadFileURL(relativePath: candidate) != nil)
        }
    }

    private func pathIdentityRequest(for item: DownloadItem) -> DownloadPathIdentityRequest {
        DownloadPathIdentityRequest(
            itemID: item.id,
            mediaIdentity: mediaIdentity(for: item),
            tmdbID: item.tmdbId,
            isMovie: item.isMovie,
            baseComponent: item.isMovie ? movieFileStem(for: item) : showFolderName(for: item),
            episodeComponent: episodeFileStem(for: item)
        )
    }

    private var pathIdentityOwners: [DownloadPathIdentityOwner] {
        downloads.map { item in
            DownloadPathIdentityOwner(
                id: item.id,
                mediaIdentity: mediaIdentity(for: item),
                isMovie: item.isMovie,
                relativePaths: ownedRelativePaths(for: item)
            )
        }
    }

    private func allocatedSubtitleRelativePath(
        for item: DownloadItem,
        fileExtension: String,
        avoidExistingFiles: Bool = false
    ) -> String {
        let ext = sanitizedFileExtension(fileExtension, fallback: "srt")
        let reservedCandidate = subtitleRelativePath(for: item, fileExtension: ext)
        if isExactRelativePathAvailable(reservedCandidate, for: item.id),
           (!avoidExistingFiles || existingDownloadFileURL(relativePath: reservedCandidate) == nil) {
            return reservedCandidate
        }

        for suffix in identitySuffixCandidates(for: item) {
            let videoPath = unreservedVideoRelativePath(
                for: item,
                fileExtension: "mp4",
                identitySuffix: suffix
            )
            let candidate = "\((videoPath as NSString).deletingPathExtension).sub.\(ext)"
            guard isExactRelativePathAvailable(candidate, for: item.id) else { continue }
            if !avoidExistingFiles || existingDownloadFileURL(relativePath: candidate) == nil {
                return candidate
            }
        }

        let stable = stableIdentityToken(for: item)
        for ordinal in 2...999 {
            let suffix = "[ID \(stable)-\(ordinal)]"
            let videoPath = unreservedVideoRelativePath(
                for: item,
                fileExtension: "mp4",
                identitySuffix: suffix
            )
            let candidate = "\((videoPath as NSString).deletingPathExtension).sub.\(ext)"
            if isExactRelativePathAvailable(candidate, for: item.id),
               (!avoidExistingFiles || existingDownloadFileURL(relativePath: candidate) == nil) {
                return candidate
            }
        }
        return reservedCandidate
    }

    private func identitySuffixCandidates(for item: DownloadItem) -> [String] {
        DownloadPathIdentityPolicy.identitySuffixCandidates(request: pathIdentityRequest(for: item))
    }

    private func stableIdentityToken(for item: DownloadItem) -> String {
        DownloadPathIdentityPolicy.stableIdentityToken(mediaIdentity: mediaIdentity(for: item))
    }

    private func mediaIdentity(for item: DownloadItem) -> String {
        if item.tmdbId > 0 {
            return "\(item.isMovie ? "movie" : "show"):tmdb:\(item.tmdbId)"
        }
        if item.isMovie {
            return "movie:id:\(item.id)"
        }
        let showID = item.id.replacingOccurrences(
            of: #"(?i)_s\d+_e\d+$"#,
            with: "",
            options: .regularExpression
        )
        return "show:id:\(showID)"
    }

    private func isVideoReservationAvailable(_ relativePath: String, for item: DownloadItem) -> Bool {
        DownloadPathIdentityPolicy.videoReservationIsAvailable(
            relativePath,
            request: pathIdentityRequest(for: item),
            owners: pathIdentityOwners
        )
    }

    private func ownedRelativePaths(for item: DownloadItem) -> [String] {
        uniqueStrings([
            item.localFileName,
            item.subtitleFileName,
            item.reservedVideoFileName,
            item.reservedSubtitleFileName
        ].compactMap { $0 }.compactMap(normalizedDownloadRelativePath))
    }

    private func isExactRelativePathAvailable(_ relativePath: String, for claimantID: String) -> Bool {
        DownloadPathIdentityPolicy.exactPathIsAvailable(
            relativePath,
            claimantID: claimantID,
            owners: pathIdentityOwners
        )
    }

    private func isRelativePathReferenced(_ relativePath: String, excludingIDs: Set<String>) -> Bool {
        DownloadPathIdentityPolicy.pathIsReferenced(
            relativePath,
            excludingIDs: excludingIDs,
            owners: pathIdentityOwners
        )
    }

    private func isPartialPathReferenced(_ partialURL: URL, excludingIDs: Set<String>) -> Bool {
        let key = canonicalAbsolutePath(partialURL)
        return downloads.contains { item in
            !excludingIDs.contains(item.id) && item.isHLS &&
                hlsPartialFileCandidates(for: item).contains {
                    canonicalAbsolutePath($0) == key
                }
        }
    }

    private func safeToCreateVideoDestination(
        _ relativePath: String,
        for item: DownloadItem,
        sourceURL: URL
    ) -> Bool {
        isVideoReservationAvailable(relativePath, for: item) &&
            safeToCreateDestination(relativePath, for: item.id, sourceURL: sourceURL)
    }

    private func safeToCreateDestination(
        _ relativePath: String,
        for itemID: String,
        sourceURL: URL
    ) -> Bool {
        guard isExactRelativePathAvailable(relativePath, for: itemID) else { return false }
        let destination = downloadFileURL(relativePath: relativePath)
        return !fileManager.fileExists(atPath: destination.path) ||
            canonicalAbsolutePath(destination) == canonicalAbsolutePath(sourceURL)
    }

    private func isInsidePublicDownloadsDirectory(_ url: URL) -> Bool {
        let root = downloadsDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }

    private func canonicalRelativePath(_ relativePath: String) -> String {
        DownloadPathIdentityPolicy.canonicalRelativePath(relativePath)
    }

    private func canonicalAbsolutePath(_ url: URL) -> String {
        canonicalPathComponent(url.standardizedFileURL.path)
    }

    private func canonicalPathComponent(_ value: String) -> String {
        DownloadPathIdentityPolicy.canonicalString(value)
    }

    private func sanitizedFileExtension(_ value: String, fallback: String) -> String {
        let cleaned = value.trimmingCharacters(in: CharacterSet(charactersIn: ". /\\")).lowercased()
        return cleaned.isEmpty ? fallback : cleaned
    }

    private func normalizedDownloadRelativePath(_ relativePath: String) -> String? {
        DownloadPathIdentityPolicy.normalizedRelativePath(relativePath)
    }

    private func downloadFileURL(relativePath: String) -> URL {
        if let cleanedPath = normalizedDownloadRelativePath(relativePath) {
            return downloadsDirectory.appendingPathComponent(cleanedPath)
        }

        let fallbackName = sanitizeFileComponent(
            URL(fileURLWithPath: relativePath).lastPathComponent,
            fallback: "download"
        )
        return downloadsDirectory.appendingPathComponent(fallbackName)
    }

    private func relativePathForDownloadFile(_ fileURL: URL) -> String {
        let filePath = fileURL.standardizedFileURL.path
        for directory in [downloadsDirectory, legacyDownloadsDirectory] {
            let basePath = directory.standardizedFileURL.path
            if filePath.hasPrefix(basePath + "/") {
                return String(filePath.dropFirst(basePath.count + 1))
            }
        }
        return fileURL.lastPathComponent
    }

    private func hlsPartialFileCandidates(for item: DownloadItem) -> [URL] {
        var candidates: [URL] = []

        let expectedDestination = downloadFileURL(relativePath: videoRelativePath(for: item, fileExtension: "ts"))
        candidates.append(hlsPartialURL(forDestinationURL: expectedDestination))

        if let localFileName = item.localFileName {
            let localDestination = downloadFileURL(relativePath: localFileName)
            candidates.append(hlsPartialURL(forDestinationURL: localDestination))
        }

        candidates.append(downloadsDirectory.appendingPathComponent(".\(item.id).ts.partial"))
        candidates.append(legacyDownloadsDirectory.appendingPathComponent(".\(item.id).ts.partial"))

        return uniqueURLs(candidates)
    }

    private func hlsPartialURL(forDestinationURL destinationURL: URL) -> URL {
        destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).partial")
    }

    private func migrateLegacyHLSPartialIfNeeded(
        for item: DownloadItem,
        previousReservationItem: DownloadItem? = nil,
        destinationURL: URL
    ) {
        let targetPartialURL = hlsPartialURL(forDestinationURL: destinationURL)
        guard !isRegularFile(at: targetPartialURL) else { return }

        var sourceCandidates = hlsPartialFileCandidates(for: item)
        if let previousReservationItem {
            sourceCandidates.append(contentsOf: hlsPartialFileCandidates(for: previousReservationItem))
        }
        for partialURL in uniqueURLs(sourceCandidates)
            where canonicalAbsolutePath(partialURL) != canonicalAbsolutePath(targetPartialURL) && isRegularFile(at: partialURL) {
            ensureParentDirectoryExists(for: targetPartialURL)
            do {
                try fileManager.moveItem(at: partialURL, to: targetPartialURL)
            } catch {
                try? fileManager.copyItem(at: partialURL, to: targetPartialURL)
            }
            return
        }
    }

    private func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func uniqueURLs(_ values: [URL]) -> [URL] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func effectiveHeaders(_ headers: [String: String], for url: URL) -> [String: String] {
        CloudflareBypassManager.shared.headersByApplyingCachedBypass(headers, for: url)
    }

    private func headerValue(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func cloudflareHeaderRefreshChanged(base: [String: String], effective: [String: String]) -> Bool {
        headerValue("Cookie", in: base) != headerValue("Cookie", in: effective)
            || headerValue("User-Agent", in: base) != headerValue("User-Agent", in: effective)
    }

    static func shouldInheritDownloadHeadersForSubtitle(
        streamURL: URL,
        subtitleURL: URL
    ) -> Bool {
        func normalizedHTTPOrigin(_ url: URL) -> (scheme: String, host: String, port: Int)? {
            guard let rawScheme = url.scheme?.lowercased(),
                  rawScheme == "http" || rawScheme == "https",
                  let rawHost = url.host?.lowercased(),
                  !rawHost.isEmpty else {
                return nil
            }
            let port = url.port ?? (rawScheme == "https" ? 443 : 80)
            return (rawScheme, rawHost, port)
        }

        guard let streamOrigin = normalizedHTTPOrigin(streamURL),
              let subtitleOrigin = normalizedHTTPOrigin(subtitleURL) else {
            return false
        }
        return streamOrigin.scheme == subtitleOrigin.scheme
            && streamOrigin.host == subtitleOrigin.host
            && streamOrigin.port == subtitleOrigin.port
    }

    private func effectiveSubtitleHeaders(for item: DownloadItem, subtitleURL: URL, streamURL: URL) -> [String: String] {
        let baseHeaders: [String: String]

        if let subtitleHeaders = item.subtitleHeaders {
            baseHeaders = subtitleHeaders
        } else if Self.shouldInheritDownloadHeadersForSubtitle(
            streamURL: streamURL,
            subtitleURL: subtitleURL
        ) {
            baseHeaders = item.headers
        } else {
            baseHeaders = [:]
        }

        return effectiveHeaders(baseHeaders, for: subtitleURL)
    }

    private func downloadBodyPreview(from location: URL, maxBytes: Int = 1_000_000) -> String {
        guard let handle = try? FileHandle(forReadingFrom: location) else { return "" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func challengeFailureMessage(for response: HTTPURLResponse, body: String) -> String? {
        let headers = CloudflareBypassManager.headersDictionary(from: response)
        if CloudflareBypassManager.isChallengeResponse(status: response.statusCode, body: body, headers: headers) {
            return "Cloudflare verification required. Open the source once and try again."
        }

        if !(200...299).contains(response.statusCode) {
            return "HTTP \(response.statusCode) while downloading"
        }

        return nil
    }

    private func validateAutoModeDirectDownload(url: URL, headers: [String: String]) async throws {
        guard !StreamReachabilityProbe.shouldBypassActiveProbe(for: url) else {
            Logger.shared.log(
                "Auto Mode download preflight skipped reason=capability-url host=\(url.host ?? "none")",
                type: "Download"
            )
            return
        }
        let probe = try await autoModeProbe(
            url: url,
            headers: headers,
            byteLimit: autoModeDirectProbeMinimumBytes + 1,
            requestsByteRange: true
        )
        try validateAutoModeProbeResponse(probe)

        if let invalidPayload = obviousInvalidMediaPayload(in: probe) {
            throw AutoModeDownloadValidationFailure(message: invalidPayload, isRetryable: false)
        }

        if autoModePlaylistText(from: probe.data) != nil {
            throw AutoModeDownloadValidationFailure(
                message: "The source returned an HLS playlist where a direct media file was expected.",
                isRetryable: false
            )
        }

        if let advertisedLength = advertisedFullPayloadLength(from: probe.response),
           advertisedLength <= Int64(autoModeDirectProbeMinimumBytes) {
            throw AutoModeDownloadValidationFailure(
                message: "The source advertised only \(formattedValidationByteCount(advertisedLength)), which is too small to be a full media download.",
                isRetryable: false
            )
        }

        guard probe.data.count > autoModeDirectProbeMinimumBytes else {
            throw AutoModeDownloadValidationFailure(
                message: "The source returned only \(formattedValidationByteCount(Int64(probe.data.count))) before ending. Trying another source is safer.",
                isRetryable: true
            )
        }
    }

    private func validateAutoModeHLSDownload(url: URL, headers: [String: String]) async throws {
        guard !StreamReachabilityProbe.shouldBypassActiveProbe(for: url) else {
            Logger.shared.log(
                "Auto Mode HLS preflight skipped reason=capability-url host=\(url.host ?? "none")",
                type: "Download"
            )
            return
        }
        var playlistURL = url
        var playlistText = try await fetchAutoModePlaylist(url: playlistURL, headers: headers)

        for _ in 0..<3 where playlistText.contains("#EXT-X-STREAM-INF") {
            let variants = autoModeHLSVariants(in: playlistText, baseURL: playlistURL)
            guard let selected = variants.max(by: { $0.bandwidth < $1.bandwidth }) else {
                throw AutoModeDownloadValidationFailure(
                    message: "The HLS master playlist did not contain a usable variant.",
                    isRetryable: false
                )
            }
            playlistURL = selected.url
            guard !StreamReachabilityProbe.shouldBypassActiveProbe(for: playlistURL) else {
                Logger.shared.log(
                    "Auto Mode HLS variant preflight skipped reason=capability-url host=\(playlistURL.host ?? "none")",
                    type: "Download"
                )
                return
            }
            playlistText = try await fetchAutoModePlaylist(url: playlistURL, headers: headers)
        }

        guard !playlistText.contains("#EXT-X-STREAM-INF") else {
            throw AutoModeDownloadValidationFailure(
                message: "The HLS playlist redirected through too many nested master playlists.",
                isRetryable: false
            )
        }

        let segments = autoModeHLSSegmentURLs(in: playlistText, baseURL: playlistURL)
        guard let firstSegmentURL = segments.first else {
            throw AutoModeDownloadValidationFailure(
                message: "The HLS playlist did not contain any downloadable media segments.",
                isRetryable: false
            )
        }

        guard !StreamReachabilityProbe.shouldBypassActiveProbe(for: firstSegmentURL) else {
            Logger.shared.log(
                "Auto Mode HLS segment preflight skipped reason=capability-url host=\(firstSegmentURL.host ?? "none")",
                type: "Download"
            )
            return
        }

        let segmentProbe = try await autoModeProbe(
            url: firstSegmentURL,
            headers: headers,
            byteLimit: autoModeHLSSegmentProbeMinimumBytes + 1,
            requestsByteRange: true
        )
        try validateAutoModeProbeResponse(segmentProbe)

        if let invalidPayload = obviousInvalidMediaPayload(in: segmentProbe) {
            throw AutoModeDownloadValidationFailure(message: invalidPayload, isRetryable: false)
        }
        if autoModePlaylistText(from: segmentProbe.data) != nil {
            throw AutoModeDownloadValidationFailure(
                message: "The HLS media segment resolved to another playlist instead of media data.",
                isRetryable: false
            )
        }

        guard segmentProbe.data.count > autoModeHLSSegmentProbeMinimumBytes else {
            throw AutoModeDownloadValidationFailure(
                message: "The first HLS media segment ended after only \(formattedValidationByteCount(Int64(segmentProbe.data.count))).",
                isRetryable: true
            )
        }
    }

    private func fetchAutoModePlaylist(url: URL, headers: [String: String]) async throws -> String {
        let probe = try await autoModeProbe(
            url: url,
            headers: headers,
            byteLimit: autoModePlaylistProbeLimit,
            requestsByteRange: false
        )
        try validateAutoModeProbeResponse(probe)

        guard !probe.reachedByteLimit else {
            throw AutoModeDownloadValidationFailure(
                message: "The HLS playlist was unexpectedly large and could not be safely verified.",
                isRetryable: false
            )
        }
        guard let playlist = autoModePlaylistText(from: probe.data) else {
            throw AutoModeDownloadValidationFailure(
                message: "The source did not return a valid HLS playlist.",
                isRetryable: false
            )
        }
        return playlist
    }

    private func autoModeProbe(
        url: URL,
        headers: [String: String],
        byteLimit: Int,
        requestsByteRange: Bool
    ) async throws -> DownloadStreamProbeResult {
        let refreshedHeaders = effectiveHeaders(headers, for: url)
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (key, value) in refreshedHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if requestsByteRange {
            request.setValue("bytes=0-\(max(byteLimit - 1, 0))", forHTTPHeaderField: "Range")
        }

        let probe = DownloadStreamProbe(byteLimit: byteLimit, redirectHeaders: refreshedHeaders)
        return try await probe.run(request)
    }

    private func validateAutoModeProbeResponse(_ probe: DownloadStreamProbeResult) throws {
        let response = probe.response
        let body = String(data: probe.data.prefix(1_000_000), encoding: .utf8) ?? ""
        let responseHeaders = CloudflareBypassManager.headersDictionary(from: response)

        if CloudflareBypassManager.isChallengeResponse(
            status: response.statusCode,
            body: body,
            headers: responseHeaders
        ) {
            throw AutoModeDownloadValidationFailure(
                message: "Cloudflare verification is required before this source can download.",
                isRetryable: false,
                cloudflareChallengeURL: response.url
            )
        }

        guard (200...299).contains(response.statusCode) else {
            let retryable = response.statusCode == 408
                || response.statusCode == 425
                || response.statusCode == 429
                || (500...599).contains(response.statusCode)
            throw AutoModeDownloadValidationFailure(
                message: "The download source returned HTTP \(response.statusCode).",
                isRetryable: retryable
            )
        }
    }

    private func obviousInvalidMediaPayload(in probe: DownloadStreamProbeResult) -> String? {
        let contentType = (probe.response.value(forHTTPHeaderField: "Content-Type") ?? "")
            .lowercased()
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init) ?? ""

        if contentType == "text/html"
            || contentType == "application/json"
            || contentType.hasSuffix("+json")
            || contentType == "application/xml"
            || contentType == "text/xml"
            || contentType.hasSuffix("+xml") {
            return "The source returned \(contentType.isEmpty ? "an error page" : contentType) instead of media data."
        }

        if contentType.hasPrefix("image/"), payloadLooksLikeImage(probe.data) {
            return "The source returned \(contentType) instead of media data."
        }

        guard let preview = String(data: probe.data.prefix(64 * 1024), encoding: .utf8) else {
            return nil
        }
        let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("<!doctype html")
            || trimmed.hasPrefix("<html")
            || trimmed.hasPrefix("<?xml")
            || trimmed.hasPrefix("{\"error\"")
            || trimmed.hasPrefix("{\"message\"") {
            return "The source returned an error document instead of media data."
        }
        return nil
    }

    private func payloadLooksLikeImage(_ data: Data) -> Bool {
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

    private func advertisedFullPayloadLength(from response: HTTPURLResponse) -> Int64? {
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let slash = contentRange.lastIndex(of: "/") {
            let totalText = contentRange[contentRange.index(after: slash)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if totalText != "*", let total = Int64(totalText) {
                return total
            }
        }

        guard response.statusCode != 206, response.expectedContentLength >= 0 else { return nil }
        return response.expectedContentLength
    }

    private func autoModePlaylistText(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let normalized = text
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
        guard normalized.hasPrefix("#EXTM3U") else { return nil }
        return normalized
    }

    private func autoModeHLSVariants(in playlist: String, baseURL: URL) -> [(url: URL, bandwidth: Int)] {
        let lines = playlist.components(separatedBy: .newlines)
        var variants: [(url: URL, bandwidth: Int)] = []
        var index = 0

        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("#EXT-X-STREAM-INF:") else {
                index += 1
                continue
            }

            let attributes = line.dropFirst("#EXT-X-STREAM-INF:".count)
            let bandwidth = attributes
                .split(separator: ",")
                .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("BANDWIDTH=") })
                .flatMap { attribute -> Int? in
                    let value = attribute.split(separator: "=", maxSplits: 1).last
                    return value.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                } ?? 0

            index += 1
            while index < lines.count {
                let uri = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                if !uri.isEmpty && !uri.hasPrefix("#") {
                    if let resolved = resolveAutoModeHLSURL(uri, relativeTo: baseURL) {
                        variants.append((resolved, bandwidth))
                    }
                    break
                }
                index += 1
            }
            index += 1
        }

        return variants
    }

    private func autoModeHLSSegmentURLs(in playlist: String, baseURL: URL) -> [URL] {
        playlist.components(separatedBy: .newlines).compactMap { line in
            let uri = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !uri.isEmpty, !uri.hasPrefix("#") else { return nil }
            return resolveAutoModeHLSURL(uri, relativeTo: baseURL)
        }
    }

    private func resolveAutoModeHLSURL(_ value: String, relativeTo baseURL: URL) -> URL? {
        if let absolute = URL(string: value), absolute.scheme != nil {
            return absolute
        }
        return URL(string: value, relativeTo: baseURL)?.absoluteURL
    }

    private func formattedValidationByteCount(_ bytes: Int64) -> String {
        DownloadByteCountFormatter.string(fromByteCount: bytes)
    }

    private func autoModeValidationFailure(from error: Error) -> AutoModeDownloadValidationFailure {
        if let failure = error as? AutoModeDownloadValidationFailure {
            return failure
        }
        if let urlError = error as? URLError {
            let retryableCodes: Set<URLError.Code> = [
                .timedOut,
                .cannotFindHost,
                .cannotConnectToHost,
                .networkConnectionLost,
                .dnsLookupFailed,
                .notConnectedToInternet,
                .resourceUnavailable
            ]
            return AutoModeDownloadValidationFailure(
                message: "The download stream could not be reached (network error \(urlError.code.rawValue)).",
                isRetryable: retryableCodes.contains(urlError.code)
            )
        }
        return AutoModeDownloadValidationFailure(
            message: "The download stream could not be verified.",
            isRetryable: true
        )
    }

    private func boundedTransportErrorToken(_ error: Error) -> String {
        let nsError = error as NSError
        let safeDomain = String(nsError.domain.unicodeScalars.filter { scalar in
            scalar.isASCII && (
                CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "." || scalar == "-" || scalar == "_"
            )
        }.prefix(64))
        return "\(safeDomain.isEmpty ? "network" : safeDomain):\(nsError.code)"
    }

    private func boundedDownloadFailureMessage(_ error: Error) -> String {
        "Download failed due to a network or file error (\(boundedTransportErrorToken(error)))."
    }

    private func processQueue() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.processQueue()
            }
            return
        }

#if os(iOS) && !targetEnvironment(macCatalyst)
        migrateLegacyStremioDownloadsIfNeeded(permitsOneLiveAttempt: true)
#endif

        let currentlyDownloading = downloads.filter { $0.status == .downloading }.count

        let reservedValidations = nuvioDispatchValidationPendingIDs.count
        var slotsAvailable = maxConcurrentDownloads - currentlyDownloading - reservedValidations

        guard slotsAvailable > 0 else { return }

        let now = Date()
        let delayedRetryDates = downloads.compactMap { item -> Date? in
            guard item.status == .queued,
                  let retryDate = item.retryNotBefore,
                  retryDate > now else { return nil }
            return retryDate
        }
        if let nextRetryDate = delayedRetryDates.min() {
            scheduleQueueWake(at: nextRetryDate)
        }
        let queued = downloads.filter {
            guard $0.status == .queued,
                  $0.retryNotBefore == nil || $0.retryNotBefore! <= now else {
                return false
            }
            return !nuvioDispatchValidationPendingIDs.contains($0.id)
        }

        for item in queued {
            guard slotsAvailable > 0 else { break }

#if os(iOS) && !targetEnvironment(macCatalyst)
            let protectedAuthority = Self.protectedAuthorityState(for: item)
            if protectedAuthority != .notProtected, !protectedProviderTransportMayStart {
                setQueuedMessage(id: item.id, message: "Waiting for app to reopen")
                continue
            }
            if protectedAuthority != .notProtected,
               !protectedOwnerMatchesActiveProfile(item) {
                setQueuedMessage(id: item.id, message: "Waiting for the download's profile")
                continue
            }
#endif

            if item.isHLS {
                if activeHLSDownloaders.count >= maxConcurrentHLSDownloads {
                    setQueuedMessage(id: item.id, message: "Waiting to package HLS")
                    continue
                }

                if let delayReason = hlsStartDelayReason() {
                    setQueuedMessage(id: item.id, message: delayReason)
                    Logger.shared.log("Delaying HLS packaging for \(item.displayTitle): \(delayReason)", type: "Download")
                    continue
                }
            }

            clearQueuedMessage(id: item.id)
            if let index = downloads.firstIndex(where: { $0.id == item.id }) {
                downloads[index].retryNotBefore = nil
                if downloads[index].error?.hasPrefix("CDN rate limited") == true {
                    downloads[index].error = nil
                }
            }
            startDownload(item)
            slotsAvailable -= 1
        }
    }

    private func scheduleQueueWake(at date: Date) {
        if let scheduledQueueWakeWorkItem,
           !scheduledQueueWakeWorkItem.isCancelled {
            scheduledQueueWakeWorkItem.cancel()
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.scheduledQueueWakeWorkItem = nil
            self?.processQueue()
        }
        scheduledQueueWakeWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, date.timeIntervalSinceNow),
            execute: workItem
        )
    }

    private func startDownload(_ item: DownloadItem) {
#if os(iOS) && !targetEnvironment(macCatalyst)
        if item.providerTransportKind == .skyStreamHLS {
            startValidatedSkyStreamHLSDownload(item)
            return
        }
#endif

#if os(iOS) && !targetEnvironment(macCatalyst)
        let protectedAuthority = Self.protectedAuthorityState(for: item)
        switch protectedAuthority {
        case .notProtected:
            break
        case .invalid:
            markFailed(
                id: item.id,
                error: "The provider download recovery reference is invalid. Please select the source again."
            )
            return
        case .authorized(let providerKind):
            guard protectedOwnerMatchesActiveProfile(item) else {
                setQueuedMessage(id: item.id, message: "Waiting for the download's profile")
                return
            }
            if providerKind == .nuvio, authorizedNuvioReference(for: item) == nil {
                markFailed(id: item.id, error: "The Nuvio download reference no longer matches this title.")
                return
            }
            if providerKind == .stremio,
               item.lastContentReference?.hasValidStremioSelection != true {
                markFailed(id: item.id, error: "The Stremio download reference is no longer valid.")
                return
            }
            guard protectedProviderTransportMayStart else {
                setQueuedMessage(id: item.id, message: "Waiting for app to reopen")
                return
            }
            if ProtectedDownloadPersistencePolicy.requiresFreshResolution(
                claimsProtectedProvider: true,
                streamURL: item.streamURL
            ) || (providerKind == .stremio
                && stremioConfiguredOriginAuthorities[item.id] == nil) {
                restoreProtectedProviderDownload(item, providerKind: providerKind)
                return
            }
            if nuvioDispatchApprovedIDs.remove(item.id) == nil {
                beginValidatedNuvioDispatch(item)
                return
            }
        case .legacyService:
            guard protectedOwnerMatchesActiveProfile(item) else {
                setQueuedMessage(id: item.id, message: "Waiting for the download's profile")
                return
            }
            guard protectedProviderTransportMayStart else {
                setQueuedMessage(id: item.id, message: "Waiting for app to reopen")
                return
            }
            guard !item.streamURL.isEmpty else {
                markFailed(
                    id: item.id,
                    error: "This legacy Service download must be selected again to refresh access securely."
                )
                return
            }
            if nuvioDispatchApprovedIDs.remove(item.id) == nil {
                beginValidatedNuvioDispatch(item)
                return
            }
        case .legacyStremio:
            guard protectedOwnerMatchesActiveProfile(item) else {
                setQueuedMessage(id: item.id, message: "Waiting for the download's profile")
                return
            }
            guard protectedProviderTransportMayStart else {
                setQueuedMessage(id: item.id, message: "Waiting for app to reopen")
                return
            }
            guard !item.streamURL.isEmpty,
                  stremioConfiguredOriginAuthorities[item.id] != nil else {
                markFailed(
                    id: item.id,
                    error: "This legacy Stremio download must be selected again to refresh access securely."
                )
                return
            }
            if nuvioDispatchApprovedIDs.remove(item.id) == nil {
                beginValidatedNuvioDispatch(item)
                return
            }
        }
#else
        if item.lastContentReference?.kind == .nuvio,
           nuvioDispatchApprovedIDs.remove(item.id) == nil {
            beginValidatedNuvioDispatch(item)
            return
        }
#endif
        guard let url = URL(string: item.streamURL) else {
            markFailed(id: item.id, error: "Invalid stream URL")
            return
        }

        let effectiveHeaders = effectiveHeaders(item.headers, for: url)
        let refreshedCloudflareHeaders = cloudflareHeaderRefreshChanged(
            base: item.headers,
            effective: effectiveHeaders
        )
        var transportPlan = NuvioDownloadTransportPlan.ordinary(
            url: url,
            headers: effectiveHeaders
        )
        var protectedNuvioAttemptID: UUID?
#if os(iOS) && !targetEnvironment(macCatalyst)
        if protectedAuthority != .notProtected && protectedAuthority != .invalid {
            guard let protected = beginNuvioProtectedAttempt(
                for: item,
                originalURL: url,
                effectiveHeaders: effectiveHeaders
            ) else {
                markFailed(id: item.id, error: "Eclipse could not create a protected provider download route.")
                return
            }
            transportPlan = protected.plan
            protectedNuvioAttemptID = protected.attemptID
        }
#endif

        if item.isHLS {
            if let delayReason = hlsStartDelayReason() {
#if os(iOS) && !targetEnvironment(macCatalyst)
                if let protectedNuvioAttemptID {
                    invalidateNuvioProtectedAttempt(
                        id: item.id,
                        expectedAttemptID: protectedNuvioAttemptID
                    )
                }
#endif
                setQueuedMessage(id: item.id, message: delayReason)
                Logger.shared.log("HLS queued instead of starting: \(delayReason)", type: "Download")
                return
            }
            let currentItem = downloads.first(where: { $0.id == item.id }) ?? item
            startHLSDownload(
                currentItem,
                streamURLOverride: protectedNuvioAttemptID == nil ? nil : transportPlan.dispatchURL,
                headersOverride: protectedNuvioAttemptID == nil ? nil : transportPlan.dispatchHeaders,
                pinnedVariantOverride: nil,
                persistResolvedVariant: protectedNuvioAttemptID == nil,
                protectedNuvioAttemptID: protectedNuvioAttemptID
            )
            return
        }

        var request = URLRequest(url: transportPlan.dispatchURL)
        for (key, value) in transportPlan.dispatchHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if item.providerTransportKind == .skyStreamDirect {

            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        }

        let task: URLSessionDownloadTask
        if transportPlan.mayUseResumeData,
           let resumeData = resumeDataStore[item.id],
           !refreshedCloudflareHeaders {
            task = backgroundSession.downloadTask(withResumeData: resumeData)
            resumeDataStore.removeValue(forKey: item.id)
        } else {
            if resumeDataStore.removeValue(forKey: item.id) != nil {
                let reason = transportPlan.mayUseResumeData
                    ? "refreshed Cloudflare headers"
                    : "a fresh protected Nuvio route"
                Logger.shared.log("Restarting download with \(reason): \(item.displayTitle)", type: "Download")
            }
            task = backgroundSession.downloadTask(with: request)
        }

        task.taskDescription = item.id
        activeTasks[item.id] = task
#if os(iOS) && !targetEnvironment(macCatalyst)
        if let protectedNuvioAttemptID {
            registerNuvioMainTask(task, id: item.id, attemptID: protectedNuvioAttemptID)
        }
#endif

        if let index = downloads.firstIndex(where: { $0.id == item.id }) {
            downloads[index].status = .downloading
            if refreshedCloudflareHeaders {
                downloads[index].progress = 0
                downloads[index].downloadedBytes = 0
                downloads[index].totalBytes = 0
            }
            saveDownloads()
        }

        task.resume()

        startDownloadSubtitle(
            for: item,
            originalStreamURL: url,
            protectedNuvioAttemptID: protectedNuvioAttemptID
        )

        Logger.shared.log("Started download: \(item.displayTitle)", type: "Download")
    }

    private enum DispatchValidationOutcome {
        case approved
        case rejected
    }

    private static func fragmentStrippedDispatchComparisonString(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.fragment = nil
        return components.url?.absoluteString ?? url.absoluteString
    }

    private func beginValidatedNuvioDispatch(_ item: DownloadItem) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.beginValidatedNuvioDispatch(item)
            }
            return
        }
#if os(iOS) && !targetEnvironment(macCatalyst)
        let authority = Self.protectedAuthorityState(for: item)
        let stremioAuthority = item.effectiveProtectedProviderKind == .stremio
            ? stremioConfiguredOriginAuthorities[item.id]
            : nil
        guard authority != .notProtected,
              authority != .invalid,
              protectedProviderTransportMayStart,
              protectedOwnerMatchesActiveProfile(item),
              item.effectiveProtectedProviderKind != .stremio
                || stremioAuthority != nil,
              item.effectiveProtectedProviderKind != .nuvio
                || authorizedNuvioReference(for: item) != nil else {
            setQueuedMessage(id: item.id, message: "Waiting for protected download access")
            return
        }
#endif
        guard nuvioDispatchValidationPendingIDs.insert(item.id).inserted else { return }
        let validationToken = UUID()
        nuvioDispatchValidationTokens[item.id] = validationToken
        guard let url = URL(string: item.streamURL) else {
            nuvioDispatchValidationPendingIDs.remove(item.id)
            nuvioDispatchValidationTokens.removeValue(forKey: item.id)
            markFailed(id: item.id, error: "Invalid stream URL")
            return
        }

        let expectedURL = item.streamURL
        let expectedHeaders = item.headers
        let expectedSourceID = item.lastSourceId
        let expectedReference = item.lastContentReference
        let comparisonURLString = Self.fragmentStrippedDispatchComparisonString(for: url)
        Task { [weak self] in
            let outcome: DispatchValidationOutcome
            let scheme = url.scheme?.lowercased()
            outcome = (scheme == "http" || scheme == "https")
                && url.host?.isEmpty == false
                && url.absoluteString == comparisonURLString
                ? .approved
                : .rejected

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.nuvioDispatchValidationTokens[item.id] == validationToken else {
                    self.processQueue()
                    return
                }
                self.nuvioDispatchValidationTokens.removeValue(forKey: item.id)
                self.nuvioDispatchValidationPendingIDs.remove(item.id)
                guard let current = self.downloads.first(where: { $0.id == item.id }),
                      current.status == .queued,
                      current.streamURL == expectedURL,
                      current.headers == expectedHeaders,
                      current.lastSourceId == expectedSourceID,
                      current.lastContentReference == expectedReference else {
                    self.processQueue()
                    return
                }
#if os(iOS) && !targetEnvironment(macCatalyst)
                let currentAuthority = Self.protectedAuthorityState(for: current)
                guard currentAuthority != .notProtected,
                      currentAuthority != .invalid,
                      self.protectedProviderTransportMayStart,
                      self.protectedOwnerMatchesActiveProfile(current),
                      current.effectiveProtectedProviderKind != .stremio
                        || self.stremioConfiguredOriginAuthorities[current.id]
                            == stremioAuthority,
                      current.effectiveProtectedProviderKind != .nuvio
                        || self.authorizedNuvioReference(for: current) != nil else {
                    self.processQueue()
                    return
                }
#endif
                switch outcome {
                case .approved:
                    self.nuvioDispatchApprovedIDs.insert(item.id)
                    self.startDownload(current)
                case .rejected:
                    self.markFailed(
                        id: item.id,
                        error: "This download source no longer resolves to an authorized address."
                    )
                }
            }
        }
    }

    private func startHLSDownload(
        _ item: DownloadItem,
        streamURLOverride: URL? = nil,
        headersOverride: [String: String]? = nil,
        pinnedVariantOverride: URL? = nil,
        persistResolvedVariant: Bool = true,
        protectedNuvioAttemptID: UUID? = nil
    ) {
        guard let url = streamURLOverride ?? URL(string: item.streamURL) else {
            markFailed(id: item.id, error: "Invalid stream URL")
            return
        }

        if backgroundHLSPipelineEnabled {
            Logger.shared.log("Background HLS experiment enabled; using guarded single-lane TS packager", type: "Download")
        }

        let securedItem = itemBySecuringFinalVideoDestination(item, fileExtension: "ts")
        let fileName = videoRelativePath(for: securedItem, fileExtension: "ts")
        if let index = downloads.firstIndex(where: { $0.id == item.id }),
           downloads[index].reservedVideoFileName != securedItem.reservedVideoFileName {
            downloads[index].reservedVideoFileName = securedItem.reservedVideoFileName
            saveDownloads()
        }
        let destURL = downloadFileURL(relativePath: fileName)
        ensureParentDirectoryExists(for: destURL)
        migrateLegacyHLSPartialIfNeeded(
            for: securedItem,
            previousReservationItem: item,
            destinationURL: destURL
        )

        let resumeSegment = item.hlsResumeSegmentIndex ?? 0
        let resumeBytes = item.hlsResumeByteCount ?? 0
        let pinnedVariant = pinnedVariantOverride
            ?? item.hlsVariantURL.flatMap { URL(string: $0) }
        let expectedTotal = item.hlsTotalSegments ?? 0
        let refreshedHeaders = headersOverride
            ?? effectiveHeaders(item.headers, for: url)
        let attemptID = UUID()

        let downloader = HLSDownloader(
            streamURL: url,
            headers: refreshedHeaders,
            destinationURL: destURL,
            downloadId: item.id,
            resumeFromSegment: resumeSegment,
            resumeByteCount: resumeBytes,
            pinnedVariantURL: pinnedVariant,
            expectedTotalSegments: expectedTotal,
            minimumRequestStartInterval: streamURLOverride == nil ? nil : 0,
            enforcesConservativeDiskCapacityReserve: item.providerTransportKind == .skyStreamHLS
        )

        downloader.onVariantResolved = { [weak self] variantURL, totalSegments in
            guard let self = self else { return }
            guard self.activeHLSAttemptIDs[item.id] == attemptID,
                  !self.invalidatedHLSAttemptIDs.contains(attemptID) else { return }
            if let index = self.downloads.firstIndex(where: { $0.id == item.id }) {
#if os(iOS) && !targetEnvironment(macCatalyst)
                if let protectedNuvioAttemptID {
                    self.recordNuvioHLSVariantProxyURL(
                        variantURL,
                        id: item.id,
                        attemptID: protectedNuvioAttemptID
                    )
                    self.downloads[index].hlsVariantURL = nil
                } else if persistResolvedVariant {
                    self.downloads[index].hlsVariantURL = variantURL.absoluteString
                } else {
                    self.skyStreamHLSPinnedVariantURLs[item.id] = variantURL
                    self.downloads[index].hlsVariantURL = nil
                }
#else
                self.downloads[index].hlsVariantURL = variantURL.absoluteString
#endif
                self.downloads[index].hlsTotalSegments = totalSegments
                self.saveDownloads()
            }
        }

        downloader.onCheckpoint = { [weak self] segmentsWritten, byteCount in
            guard let self = self else { return }
            guard self.activeHLSAttemptIDs[item.id] == attemptID,
                  !self.invalidatedHLSAttemptIDs.contains(attemptID) else { return }
            guard let index = self.downloads.firstIndex(where: { $0.id == item.id }),
                  self.downloads[index].status == .downloading else { return }
            self.downloads[index].hlsResumeSegmentIndex = segmentsWritten
            self.downloads[index].hlsResumeByteCount = byteCount
            self.downloads[index].downloadedBytes = byteCount
            if segmentsWritten > 0 {
                self.downloads[index].rateLimitRetryCount = nil
            }

            let now = Date()
            if let last = self.lastHLSCheckpointSave[item.id], now.timeIntervalSince(last) < 2.0 {
                return
            }
            self.lastHLSCheckpointSave[item.id] = now
            self.saveDownloads()
        }

        downloader.onProgress = { [weak self] progress in
            guard let self = self else { return }
            guard self.activeHLSAttemptIDs[item.id] == attemptID,
                  !self.invalidatedHLSAttemptIDs.contains(attemptID) else { return }
            if let index = self.downloads.firstIndex(where: { $0.id == item.id }),
               self.downloads[index].status == .downloading {
                self.downloads[index].progress = progress
            }
        }

        downloader.onCompletion = { [weak self] result in
            guard let self = self else { return }

            DispatchQueue.main.async {
                guard self.activeHLSAttemptIDs[item.id] == attemptID else { return }
                self.activeHLSDownloaders.removeValue(forKey: item.id)
                self.activeHLSAttemptIDs.removeValue(forKey: item.id)
                if self.invalidatedHLSAttemptIDs.remove(attemptID) != nil {
                    self.lastHLSCheckpointSave.removeValue(forKey: item.id)
                    self.processQueue()
                    return
                }
                switch result {
                case .success(let fileURL):
                    if let index = self.downloads.firstIndex(where: { $0.id == item.id }) {
                        self.downloads[index].status = .completed
                        self.downloads[index].progress = 1.0
                        self.downloads[index].localFileName = fileName
                        self.downloads[index].dateCompleted = Date()

                        if let attrs = try? self.fileManager.attributesOfItem(atPath: fileURL.path),
                           let size = attrs[.size] as? Int64 {
                            self.downloads[index].totalBytes = size
                            self.downloads[index].downloadedBytes = size
                        }

                        self.downloads[index].hlsResumeSegmentIndex = nil
                        self.downloads[index].hlsResumeByteCount = nil

                        self.downloads[index] = Self.persistedDownloadItem(self.downloads[index])
                        self.saveDownloads()
                    }
#if os(iOS) && !targetEnvironment(macCatalyst)
                    if let protectedNuvioAttemptID {
                        self.finishNuvioMainTransport(
                            id: item.id,
                            attemptID: protectedNuvioAttemptID
                        )
                    }
                    self.clearSkyStreamDownloadRuntimeState(
                        id: item.id,
                        discardDescriptor: true
                    )
#endif
                    self.lastHLSCheckpointSave.removeValue(forKey: item.id)
                    self.processQueue()
                    Logger.shared.log("HLS download completed: \(item.displayTitle) -> \(fileName)", type: "Download")

                case .failure(let error):
#if os(iOS) && !targetEnvironment(macCatalyst)
                    if let protectedNuvioAttemptID {
                        self.invalidateNuvioProtectedAttempt(
                            id: item.id,
                            expectedAttemptID: protectedNuvioAttemptID
                        )
                    }
#endif
                    if let hlsError = error as? HLSError {
                        switch hlsError {
                        case .cancelled:
                            self.handleCancelledHLSDownload(id: item.id)
                            Logger.shared.log("HLS download cancelled: \(item.displayTitle)", type: "Download")
                        case .backgroundTimeExpired:
                            self.requeueInterruptedHLSDownload(id: item.id, message: "Waiting for app to reopen")
                            Logger.shared.log("HLS background time expired for \(item.displayTitle)", type: "Download")
                        case .systemBackoff(let reason):
                            self.scheduleSystemBackoffDownloadRetry(id: item.id, message: reason)
                            Logger.shared.log("HLS packaging paused for \(item.displayTitle): \(reason)", type: "Download")
                        case .rateLimited(let retryAfterSeconds):
                            self.scheduleRateLimitedDownloadRetry(
                                id: item.id,
                                retryAfterSeconds: retryAfterSeconds
                            )
                        case .httpError(let statusCode) where [401, 403, 410, 503].contains(statusCode):
                            self.recoverDownloadAfterMediaRejection(
                                id: item.id,
                                statusCode: statusCode,
                                challengedURL: protectedNuvioAttemptID == nil
                                    ? nil
                                    : URL(string: item.streamURL),
                                rejectedCookieHeader: nil,
                                isInteractiveChallenge: false
                            )
                        case .cloudflareVerificationRequired(let challengeURL, let rejectedCookieHeader):
                            self.recoverDownloadAfterConfirmedChallenge(
                                id: item.id,
                                challengedURL: protectedNuvioAttemptID == nil
                                    ? challengeURL
                                    : (URL(string: item.streamURL) ?? challengeURL),
                                rejectedCookieHeader: rejectedCookieHeader
                            )
                        default:
                            self.markFailed(
                                id: item.id,
                                error: self.boundedDownloadFailureMessage(error)
                            )
                        }
                    } else {
                        self.markFailed(
                            id: item.id,
                            error: self.boundedDownloadFailureMessage(error)
                        )
                    }
                }
            }
        }

        activeHLSDownloaders[item.id] = downloader
        activeHLSAttemptIDs[item.id] = attemptID

        if let index = downloads.firstIndex(where: { $0.id == item.id }) {
            downloads[index].status = .downloading

            if resumeSegment == 0 {
                downloads[index].progress = 0
                downloads[index].downloadedBytes = 0
                downloads[index].totalBytes = 0
            }
            saveDownloads()
        }

        downloader.start()

        let originalStreamURL = URL(string: item.streamURL) ?? url
        startDownloadSubtitle(
            for: item,
            originalStreamURL: originalStreamURL,
            protectedNuvioAttemptID: protectedNuvioAttemptID
        )

        Logger.shared.log("Started HLS download: \(item.displayTitle)", type: "Download")
    }

#if os(iOS) && !targetEnvironment(macCatalyst)
    private func startValidatedSkyStreamHLSDownload(_ item: DownloadItem) {
        guard item.providerTransportKind == .skyStreamHLS,
              item.lastContentReference?.kind == .skyStream else {
            markFailed(id: item.id, error: "The typed HLS recovery metadata is missing.")
            return
        }
        guard let descriptor = skyStreamHLSDescriptors[item.id] else {
            restoreValidatedSkyStreamDownload(item)
            return
        }
        if let reason = Self.skyStreamHLSRejectionReason(descriptor) {
            clearSkyStreamDownloadRuntimeState(id: item.id, discardDescriptor: true)
            markFailed(id: item.id, error: reason)
            return
        }

        var proxyURL = skyStreamHLSProxyURLs[item.id]
        if let existing = proxyURL,
           !MPVHeaderProxy.shared.isManagedSkyStreamSessionURL(existing) {
            MPVHeaderProxy.shared.invalidateSession(for: existing)
            skyStreamHLSProxyURLs.removeValue(forKey: item.id)
            skyStreamHLSPinnedVariantURLs.removeValue(forKey: item.id)
            proxyURL = nil
            resetSkyStreamHLSCheckpoint(id: item.id)
        } else if proxyURL == nil,
                  (item.hlsResumeSegmentIndex ?? 0) > 0 {

            resetSkyStreamHLSCheckpoint(id: item.id)
        }

        if proxyURL == nil {
            proxyURL = MPVHeaderProxy.shared.makeSkyStreamProxyURL(
                for: descriptor,
                traceID: "download-\(item.id)"
            ) { [weak self] challengedURL, statusCode, isInteractiveChallenge in
                DispatchQueue.main.async {
                    self?.recoverDownloadAfterMediaRejection(
                        id: item.id,
                        statusCode: statusCode,
                        challengedURL: challengedURL,
                        rejectedCookieHeader: nil,
                        isInteractiveChallenge: isInteractiveChallenge
                    )
                }
            }
            guard let proxyURL,
                  MPVHeaderProxy.shared.isManagedSkyStreamSessionURL(proxyURL) else {
                markFailed(id: item.id, error: "The validated HLS loopback transport could not start.")
                return
            }
            skyStreamHLSProxyURLs[item.id] = proxyURL
        }

        guard let proxyURL,
              let currentItem = downloads.first(where: { $0.id == item.id }) else { return }
        startHLSDownload(
            currentItem,
            streamURLOverride: proxyURL,
            headersOverride: [:],
            pinnedVariantOverride: skyStreamHLSPinnedVariantURLs[item.id],
            persistResolvedVariant: false
        )
    }

    private func restoreValidatedSkyStreamDownload(_ item: DownloadItem) {
        guard item.lastContentReference?.kind == .skyStream,
              skyStreamRestoringDownloadIDs.insert(item.id).inserted else {
            return
        }
        let expectedReference = item.lastContentReference
        let expectedTransport = item.providerTransportKind
        if let index = downloads.firstIndex(where: { $0.id == item.id }),
           downloads[index].status == .queued {
            downloads[index].error = "Refreshing validated download access"
            saveDownloads()
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.skyStreamRestoringDownloadIDs.remove(item.id)
            }
            let refreshed = await refreshDownloadSource(id: item.id)
            guard let index = downloads.firstIndex(where: { $0.id == item.id }),
                  downloads[index].status == .queued,
                  downloads[index].lastContentReference == expectedReference,
                  downloads[index].providerTransportKind == expectedTransport else {
                processQueue()
                return
            }
            guard let refreshed,
                  installRefreshedDownloadSource(
                      refreshed,
                      id: item.id,
                      resetTransferProgress: true
                  ) != nil else {
                markFailed(
                    id: item.id,
                    error: "The SkyStream provider could not restore validated download access."
                )
                return
            }
            downloads[index].error = nil
            saveDownloads()
            processQueue()
        }
    }

    private func restoreProtectedProviderDownload(
        _ item: DownloadItem,
        providerKind: ProtectedDownloadProviderKind
    ) {
        let expectedReferenceKind: ProviderContentReference.Kind
        switch providerKind {
        case .service:
            expectedReferenceKind = .service
        case .stremio:
            expectedReferenceKind = .stremio
        case .nuvio:
            expectedReferenceKind = .nuvio
        case .skyStream:
            expectedReferenceKind = .skyStream
        case .unresolvedLegacy:
            return
        }
        let authority = Self.protectedAuthorityState(for: item)
        let needsFreshTransport = item.streamURL.isEmpty
            || (providerKind == .stremio
                && stremioConfiguredOriginAuthorities[item.id] == nil)
        guard authority == .authorized(providerKind),
              protectedProviderTransportMayStart,
              protectedOwnerMatchesActiveProfile(item),
              providerKind != .nuvio || authorizedNuvioReference(for: item) != nil,
              needsFreshTransport,
              nuvioRestoringDownloadIDs.insert(item.id).inserted else {
            return
        }
        let expectedReference = item.lastContentReference
        let expectedSourceID = item.lastSourceId
        let expectedOwnerProfileID = item.effectiveProtectedOwnerProfileID
        let expectedStreamURL = item.streamURL
        let expectedScopeGeneration = ServiceStoreScope.generation
        if let index = downloads.firstIndex(where: { $0.id == item.id }),
           downloads[index].status == .queued {
            downloads[index].error = "Refreshing protected download access"
            saveDownloads()
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.nuvioRestoringDownloadIDs.remove(item.id) }
            let refreshed = await self.refreshDownloadSource(id: item.id)
            guard let index = self.downloads.firstIndex(where: { $0.id == item.id }),
                  self.downloads[index].status == .queued,
                  self.downloads[index].streamURL == expectedStreamURL,
                  self.downloads[index].lastContentReference == expectedReference,
                  self.downloads[index].lastSourceId == expectedSourceID,
                  self.downloads[index].effectiveProtectedOwnerProfileID == expectedOwnerProfileID,
                  Self.protectedAuthorityState(for: self.downloads[index]) == .authorized(providerKind) else {
                self.processQueue()
                return
            }
            guard self.protectedProviderTransportMayStart,
                  self.protectedOwnerMatchesActiveProfile(self.downloads[index]),
                  ServiceStoreScope.isCurrent(expectedScopeGeneration) else {
                self.downloads[index].error = "Waiting for the download's profile"
                self.saveDownloads()
                return
            }
            guard let refreshed,
                  refreshed.lastContentReference.kind == expectedReferenceKind,
                  self.installRefreshedDownloadSource(
                      refreshed,
                      id: item.id,
                      resetTransferProgress: true
                  ) != nil else {
                self.scheduleSystemBackoffDownloadRetry(
                    id: item.id,
                    message: "The provider could not refresh protected download access."
                )
                return
            }
            guard let refreshedIndex = self.downloads.firstIndex(where: { $0.id == item.id }),
                  self.protectedOwnerMatchesActiveProfile(self.downloads[refreshedIndex]),
                  ServiceStoreScope.isCurrent(expectedScopeGeneration) else {
                self.scrubProtectedProviderTransportInMemory(id: item.id)
                self.saveDownloads()
                return
            }
            self.downloads[refreshedIndex].error = nil
            self.saveDownloads()
            self.processQueue()
        }
    }

    private func resetSkyStreamHLSCheckpoint(id: String) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        downloads[index].hlsResumeSegmentIndex = nil
        downloads[index].hlsResumeByteCount = nil
        downloads[index].hlsVariantURL = nil
        downloads[index].hlsTotalSegments = nil
        downloads[index].progress = 0
        downloads[index].downloadedBytes = 0
        downloads[index].totalBytes = 0
        lastHLSCheckpointSave.removeValue(forKey: id)
    }

    private func clearSkyStreamDownloadRuntimeState(
        id: String,
        discardDescriptor: Bool
    ) {
        if let proxyURL = skyStreamHLSProxyURLs.removeValue(forKey: id) {
            MPVHeaderProxy.shared.invalidateSession(for: proxyURL)
        }
        skyStreamHLSPinnedVariantURLs.removeValue(forKey: id)
        if discardDescriptor {
            skyStreamHLSDescriptors.removeValue(forKey: id)
        }
    }

    private var nuvioProtectedTransportMayStart: Bool {
#if canImport(UIKit)
        UIApplication.shared.applicationState == .active
#else
        true
#endif
    }

    private var protectedProviderTransportMayStart: Bool {
        nuvioProtectedTransportMayStart
    }

    private static func protectedAuthorityState(
        for item: DownloadItem
    ) -> ProtectedDownloadAuthorityState {
        ProtectedDownloadAuthorityState.classify(
            explicitKind: item.protectedProviderKind,
            hasLegacyNuvioMarker: item.nuvioTransportKind != nil
                || item.nuvioOwnerProfileID != nil,
            sourceID: item.lastSourceId,
            reference: item.lastContentReference
        )
    }

    private func protectedOwnerMatchesActiveProfile(_ item: DownloadItem) -> Bool {
        ProtectedDownloadPersistencePolicy.profileAuthority(
            ownerProfileID: item.effectiveProtectedOwnerProfileID,
            activeProfileID: ProfileManager.shared.activeProfileID
        ) == .authorized
    }

    private func nuvioOwnerMatchesActiveProfile(_ item: DownloadItem) -> Bool {
        protectedOwnerMatchesActiveProfile(item)
    }

    private func authorizedNuvioReference(
        for item: DownloadItem
    ) -> NuvioProviderContentReference? {
        guard NuvioDownloadAuthorityState.classify(
            sourceID: item.lastSourceId,
            reference: item.lastContentReference
        ) == .authorized,
              let reference = item.lastContentReference?.nuvio,
              nuvioDownloadReferenceMatchesItem(reference, item: item) else {
            return nil
        }
        return reference
    }

    /// Migrates the pre-reference Stremio shape by exact configured-addon
    /// identity. Rows read from disk are scrubbed and require reselection;
    /// only a genuinely live, newly-created legacy row may finish one fresh
    /// foreground proxy attempt before its transport is discarded.
    private func migrateLegacyStremioDownloadsIfNeeded(
        permitsOneLiveAttempt: Bool
    ) {
        let candidateIndices = downloads.indices.filter { index in
            let item = downloads[index]
            return item.effectiveProtectedProviderKind == nil
                && item.lastContentReference == nil
                && item.lastSourceId == nil
                && item.sourceId == nil
                && item.serviceContentHref == nil
                && !item.serviceBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !candidateIndices.isEmpty else { return }

        let configuredAddons = StremioAddonStore.shared.getAddons().reduce(
            into: [UUID: String]()
        ) { result, addon in
            if result[addon.id] == nil { result[addon.id] = addon.configuredURL }
        }

        var changed = false
        for index in candidateIndices {
            let item = downloads[index]
            let sourceID = ProtectedDownloadPersistencePolicy.legacyStremioSourceID(
                serviceBaseURL: item.serviceBaseURL,
                configuredAddons: configuredAddons
            )
            let configuredURL = sourceID.flatMap { sourceID -> String? in
                guard let addonID = UUID(
                    uuidString: String(sourceID.dropFirst("stremio:".count))
                ) else { return nil }
                return configuredAddons[addonID]
            }
            downloads[index].lastSourceId = sourceID
            downloads[index].protectedProviderKind = configuredURL == nil
                ? .unresolvedLegacy
                : .stremio
            downloads[index].protectedOwnerProfileID = ProfileManager.shared.activeProfileID
            downloads[index].protectedTransportKind = ProtectedDownloadPersistencePolicy
                .transportKind(for: item.streamURL)
            downloads[index].providerTransportKind = nil
            changed = true

            let mayUseLiveTransport = permitsOneLiveAttempt
                && configuredURL != nil
                && !persistenceLoadedDownloadIDs.contains(item.id)
                && protectedProviderTransportMayStart
                && !item.streamURL.isEmpty
            if mayUseLiveTransport,
               let configuredURL,
               let authority = try? SkyStreamPinnedOriginAuthority.stremio(
                    configuredBaseURL: configuredURL
               ) {
                stremioConfiguredOriginAuthorities[item.id] = authority
            } else {
                if let task = activeTasks.removeValue(forKey: item.id) {
                    invalidatedDirectTaskIdentifiers.insert(task.taskIdentifier)
                    task.cancel()
                }
                scrubProtectedProviderTransportInMemory(id: item.id)
                if downloads[index].status != .completed {
                    downloads[index].status = .failed
                    downloads[index].error =
                        "This legacy provider download must be selected again to refresh access securely."
                }
            }
        }
        if changed { saveDownloadsSynchronously() }
    }

    private func beginNuvioProtectedAttempt(
        for item: DownloadItem,
        originalURL: URL,
        effectiveHeaders: [String: String]
    ) -> (plan: NuvioDownloadTransportPlan, attemptID: UUID)? {
        let providerKind: ProtectedDownloadProviderKind
        switch Self.protectedAuthorityState(for: item) {
        case .authorized(let kind):
            providerKind = kind
        case .legacyService:
            providerKind = .service
        case .legacyStremio:
            providerKind = .stremio
        case .notProtected, .invalid:
            return nil
        }
        if providerKind == .nuvio, authorizedNuvioReference(for: item) == nil {
            return nil
        }
        let authorityReference = Self.protectedAuthorityState(for: item) == .legacyService
            || Self.protectedAuthorityState(for: item) == .legacyStremio
                ? nil
                : item.lastContentReference
        let stremioAuthority = providerKind == .stremio
            ? stremioConfiguredOriginAuthorities[item.id]
            : nil
        guard protectedProviderTransportMayStart,
              providerKind != .stremio || stremioAuthority != nil,
              protectedOwnerMatchesActiveProfile(item),
              let current = downloads.first(where: { $0.id == item.id }),
              current.status == .queued,
              current.streamURL == item.streamURL,
              current.headers == item.headers,
              current.lastSourceId == item.lastSourceId,
              current.lastContentReference == item.lastContentReference else {
            return nil
        }

        invalidateNuvioProtectedAttempt(id: item.id)
        resumeDataStore.removeValue(forKey: item.id)
        pendingResumeDataTaskIdentifiers.removeValue(forKey: item.id)
        if item.isHLS {
            resetProtectedProviderHLSCheckpoint(id: item.id)
        }

        let attemptID = UUID()
        guard let proxyURL = MPVHeaderProxy.shared.makeProxyURL(
            for: originalURL,
            headers: effectiveHeaders,
            logType: "ProviderDownload",
            traceID: "provider-dl-\(String(attemptID.uuidString.prefix(8)))",
            stremioAuthority: stremioAuthority,
            onConfirmedCloudflareChallenge: { [weak self] url, rejectedCookie, interactive, status in
                self?.handleNuvioProxyRejection(
                    id: item.id,
                    attemptID: attemptID,
                    url: url,
                    rejectedCookieHeader: rejectedCookie,
                    isInteractive: interactive,
                    statusCode: status
                )
            }
        ) else {
            return nil
        }

        guard let latest = downloads.first(where: { $0.id == item.id }),
              latest.status == .queued,
              latest.streamURL == item.streamURL,
              latest.headers == item.headers,
              latest.lastSourceId == item.lastSourceId,
              latest.lastContentReference == item.lastContentReference,
              protectedOwnerMatchesActiveProfile(latest),
              latest.effectiveProtectedProviderKind == providerKind else {
            MPVHeaderProxy.shared.invalidateSession(for: proxyURL)
            return nil
        }

        protectedProviderAttempts[item.id] = ProtectedProviderDownloadAttempt(
            attemptID: attemptID,
            providerKind: providerKind,
            authorityURL: originalURL.absoluteString,
            authorityHeaders: item.headers,
            authorityReference: authorityReference,
            stremioConfiguredOriginAuthority: stremioAuthority,
            mainProxyURL: proxyURL
        )
        return (
            NuvioDownloadTransportPlan.protectedAttempt(
                authoritativeURL: originalURL,
                authoritativeHeaders: item.headers,
                proxyURL: proxyURL
            ),
            attemptID
        )
    }

    private func registerNuvioMainTask(
        _ task: URLSessionDownloadTask,
        id: String,
        attemptID: UUID
    ) {
        guard var attempt = protectedProviderAttempts[id],
              attempt.attemptID == attemptID else { return }
        attempt.mainTaskIdentifier = task.taskIdentifier
        protectedProviderAttempts[id] = attempt
    }

    private func makeNuvioSubtitleProxyURL(
        id: String,
        attemptID: UUID,
        subtitleURL: URL,
        headers: [String: String]
    ) -> URL? {
        guard let attempt = protectedProviderAttempts[id],
              attempt.attemptID == attemptID else { return nil }
        guard let proxyURL = MPVHeaderProxy.shared.makeProxyURL(
            for: subtitleURL,
            headers: headers,
            logType: "ProviderDownloadSubtitle",
            traceID: "provider-sub-\(String(attemptID.uuidString.prefix(8)))",
            stremioAuthority: attempt.stremioConfiguredOriginAuthority,
            onConfirmedCloudflareChallenge: { [weak self] url, rejectedCookie, interactive, status in
                self?.handleNuvioProxyRejection(
                    id: id,
                    attemptID: attemptID,
                    url: url,
                    rejectedCookieHeader: rejectedCookie,
                    isInteractive: interactive,
                    statusCode: status
                )
            }
        ) else { return nil }
        guard var current = protectedProviderAttempts[id],
              current.attemptID == attemptID else {
            MPVHeaderProxy.shared.invalidateSession(for: proxyURL)
            return nil
        }
        current.subtitleProxyURLs.insert(proxyURL)
        protectedProviderAttempts[id] = current
        return proxyURL
    }

    private func recordNuvioHLSVariantProxyURL(
        _ url: URL,
        id: String,
        attemptID: UUID
    ) {
        guard var attempt = protectedProviderAttempts[id],
              attempt.attemptID == attemptID else { return }
        attempt.hlsVariantProxyURL = url
        protectedProviderAttempts[id] = attempt
    }

    private func nuvioAttemptIsCurrent(id: String, attemptID: UUID) -> Bool {
        if Thread.isMainThread {
            return protectedProviderAttempts[id]?.attemptID == attemptID
        }
        return DispatchQueue.main.sync {
            protectedProviderAttempts[id]?.attemptID == attemptID
        }
    }

    private func finishNuvioSubtitleProxy(
        id: String,
        attemptID: UUID,
        proxyURL: URL
    ) {
        MPVHeaderProxy.shared.invalidateSession(for: proxyURL)
        performOnMain { [weak self] in
            guard let self,
                  var attempt = protectedProviderAttempts[id],
                  attempt.attemptID == attemptID else { return }
            attempt.subtitleProxyURLs.remove(proxyURL)
            nuvioSubtitleFetches.removeValue(forKey: id)
            if NuvioDownloadAttemptLifecycle.mayReleaseAttempt(
                mainFinished: attempt.mainFinished,
                subtitleSessionCount: attempt.subtitleProxyURLs.count
            ) {
                protectedProviderAttempts.removeValue(forKey: id)
            } else {
                protectedProviderAttempts[id] = attempt
            }
        }
    }

    private func finishNuvioMainTransport(id: String, attemptID: UUID) {
        guard var attempt = protectedProviderAttempts[id],
              attempt.attemptID == attemptID else { return }
        MPVHeaderProxy.shared.invalidateSession(for: attempt.mainProxyURL)
        if let variantURL = attempt.hlsVariantProxyURL {
            MPVHeaderProxy.shared.invalidateSession(for: variantURL)
        }
        attempt.mainFinished = true
        attempt.mainTaskIdentifier = nil
        attempt.hlsVariantProxyURL = nil
        resumeDataStore.removeValue(forKey: id)
        pendingResumeDataTaskIdentifiers.removeValue(forKey: id)
        nuvioDispatchApprovedIDs.remove(id)
        stremioConfiguredOriginAuthorities.removeValue(forKey: id)
        if NuvioDownloadAttemptLifecycle.mayReleaseAttempt(
            mainFinished: attempt.mainFinished,
            subtitleSessionCount: attempt.subtitleProxyURLs.count
        ) {
            protectedProviderAttempts.removeValue(forKey: id)
        } else {
            protectedProviderAttempts[id] = attempt
        }
    }

    private func handleNuvioProxyRejection(
        id: String,
        attemptID: UUID,
        url: URL,
        rejectedCookieHeader: String?,
        isInteractive: Bool,
        statusCode: Int
    ) {
        performOnMain { [weak self] in
            guard let self,
                  protectedProviderAttempts[id]?.attemptID == attemptID else { return }
            recoverDownloadAfterMediaRejection(
                id: id,
                statusCode: statusCode,
                challengedURL: url,
                rejectedCookieHeader: rejectedCookieHeader,
                isInteractiveChallenge: isInteractive
            )
        }
    }

    private func invalidateNuvioProtectedAttempt(
        id: String,
        expectedAttemptID: UUID? = nil
    ) {
        guard let attempt = protectedProviderAttempts[id],
              expectedAttemptID == nil || attempt.attemptID == expectedAttemptID else { return }
        protectedProviderAttempts.removeValue(forKey: id)
        MPVHeaderProxy.shared.invalidateSession(for: attempt.mainProxyURL)
        if let variantURL = attempt.hlsVariantProxyURL {
            MPVHeaderProxy.shared.invalidateSession(for: variantURL)
        }
        for proxyURL in attempt.subtitleProxyURLs {
            MPVHeaderProxy.shared.invalidateSession(for: proxyURL)
        }
        if let subtitleFetch = nuvioSubtitleFetches.removeValue(forKey: id) {
            subtitleFetch.cancel()
        }
        resumeDataStore.removeValue(forKey: id)
        pendingResumeDataTaskIdentifiers.removeValue(forKey: id)
        nuvioDispatchApprovedIDs.remove(id)
        stremioConfiguredOriginAuthorities.removeValue(forKey: id)
    }

    private func invalidateAllProtectedProviderAttempts() {
        for id in Array(protectedProviderAttempts.keys) {
            invalidateNuvioProtectedAttempt(id: id)
        }
        for proxyURL in nuvioAutoValidationProxyURLs.values {
            MPVHeaderProxy.shared.invalidateSession(for: proxyURL)
        }
        nuvioAutoValidationProxyURLs.removeAll()
        stremioConfiguredOriginAuthorities.removeAll()
    }

    private func clearProtectedProviderDownloadRuntimeState(id: String, scrubTransport: Bool) {
        nuvioDispatchValidationPendingIDs.remove(id)
        nuvioDispatchValidationTokens.removeValue(forKey: id)
        nuvioDispatchApprovedIDs.remove(id)
        nuvioRestoringDownloadIDs.remove(id)
        stremioConfiguredOriginAuthorities.removeValue(forKey: id)
        invalidateNuvioProtectedAttempt(id: id)
        resumeDataStore.removeValue(forKey: id)
        pendingResumeDataTaskIdentifiers.removeValue(forKey: id)
        if scrubTransport {
            resetProtectedProviderHLSCheckpoint(id: id)
            scrubProtectedProviderTransportInMemory(id: id)
        }
    }

    private func suspendProtectedProviderAttempts(
        message: String,
        processWhenPossible: Bool
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        let protectedIDs = Set(protectedProviderAttempts.keys).union(
            downloads.compactMap { $0.claimsProtectedProviderTransport ? $0.id : nil }
        )
        for proxyURL in nuvioAutoValidationProxyURLs.values {
            MPVHeaderProxy.shared.invalidateSession(for: proxyURL)
        }
        nuvioAutoValidationProxyURLs.removeAll()
        for id in protectedIDs {
            nuvioDispatchValidationPendingIDs.remove(id)
            nuvioDispatchValidationTokens.removeValue(forKey: id)
            nuvioDispatchApprovedIDs.remove(id)
            nuvioRestoringDownloadIDs.remove(id)
            stremioConfiguredOriginAuthorities.removeValue(forKey: id)
            if let task = activeTasks.removeValue(forKey: id) {
                invalidatedDirectTaskIdentifiers.insert(task.taskIdentifier)
                task.cancel()
            }
            if let downloader = activeHLSDownloaders.removeValue(forKey: id) {
                if let hlsAttemptID = activeHLSAttemptIDs.removeValue(forKey: id) {
                    invalidatedHLSAttemptIDs.insert(hlsAttemptID)
                }
                downloader.cancel()
            }
            invalidateNuvioProtectedAttempt(id: id)
            resetProtectedProviderHLSCheckpoint(id: id)
            scrubProtectedProviderTransportInMemory(id: id)
            if let index = downloads.firstIndex(where: { $0.id == id }),
               downloads[index].status == .downloading {
                downloads[index].status = .queued
                downloads[index].error = message
            }
        }
        if !protectedIDs.isEmpty { saveDownloads() }
        if processWhenPossible, protectedProviderTransportMayStart {
            processQueue()
        }
    }

    private func resetNuvioHLSCheckpoint(id: String) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        let transferIsCompleted = downloads[index].status == .completed
        downloads[index].hlsResumeSegmentIndex = nil
        downloads[index].hlsResumeByteCount = nil
        downloads[index].hlsVariantURL = nil
        downloads[index].hlsTotalSegments = nil
        if !transferIsCompleted {
            downloads[index].progress = 0
            downloads[index].downloadedBytes = 0
            downloads[index].totalBytes = 0
        }
        lastHLSCheckpointSave.removeValue(forKey: id)
    }

    private func resetProtectedProviderHLSCheckpoint(id: String) {
        resetNuvioHLSCheckpoint(id: id)
    }

    private func scrubNuvioTransportInMemory(id: String) {
        guard let index = downloads.firstIndex(where: { $0.id == id }),
              NuvioDownloadPersistencePolicy.claimsNuvio(
                  sourceID: downloads[index].lastSourceId,
                  reference: downloads[index].lastContentReference
              ) else { return }
        if downloads[index].nuvioTransportKind == nil, !downloads[index].streamURL.isEmpty {
            downloads[index].nuvioTransportKind = NuvioDownloadPersistencePolicy.transportKind(
                for: downloads[index].streamURL
            )
        }
        downloads[index].streamURL = ""
        downloads[index].headers = [:]
        downloads[index].subtitleURL = nil
        downloads[index].subtitleHeaders = nil
        downloads[index].serviceBaseURL = ""
        downloads[index].sourceId = nil
        downloads[index].serviceContentHref = nil
        downloads[index].hlsVariantURL = nil
        resumeDataStore.removeValue(forKey: id)
        pendingResumeDataTaskIdentifiers.removeValue(forKey: id)
    }

    private func scrubProtectedProviderTransportInMemory(id: String) {
        guard let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].claimsProtectedProviderTransport else { return }
        if downloads[index].protectedTransportKind == nil,
           !downloads[index].streamURL.isEmpty {
            downloads[index].protectedTransportKind = ProtectedDownloadPersistencePolicy
                .transportKind(for: downloads[index].streamURL)
        }
        if downloads[index].effectiveProtectedProviderKind == .nuvio {
            downloads[index].nuvioTransportKind = downloads[index].protectedTransportKind
        }
        downloads[index].streamURL = ""
        downloads[index].headers = [:]
        downloads[index].subtitleURL = nil
        downloads[index].subtitleHeaders = nil
        downloads[index].serviceBaseURL = ""
        downloads[index].sourceId = nil
        downloads[index].serviceContentHref = nil
        downloads[index].hlsVariantURL = nil
        resumeDataStore.removeValue(forKey: id)
        pendingResumeDataTaskIdentifiers.removeValue(forKey: id)
    }
#endif

    private func hlsStartDelayReason() -> String? {
        #if canImport(UIKit)
        if !backgroundHLSPipelineEnabled && UIApplication.shared.applicationState != .active {
            return "Waiting for app to reopen"
        }

        let thermalState = ProcessInfo.processInfo.thermalState
        if thermalState == .serious || thermalState == .critical {
            return "Paused for thermal state"
        }

        let device = UIDevice.current
        if device.batteryState == .unplugged && device.batteryLevel >= 0 && device.batteryLevel < 0.15 {
            return "Paused for low battery"
        }
        #endif

        if let freeBytes = availableDownloadCapacity(), freeBytes < minimumFreeBytesForHLS {
            return "Paused for low disk space"
        }

        return nil
    }

    private func availableDownloadCapacity() -> Int64? {
        do {
            let values = try downloadsDirectory.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey
            ])

            if let importantUsage = values.volumeAvailableCapacityForImportantUsage {
                return importantUsage
            }
            if let capacity = values.volumeAvailableCapacity {
                return Int64(capacity)
            }
        } catch {
            Logger.shared.log("Could not read free disk space for HLS: \(error.localizedDescription)", type: "Download")
        }

        return nil
    }

    private func setQueuedMessage(id: String, message: String) {
        DispatchQueue.main.async {
            guard let index = self.downloads.firstIndex(where: { $0.id == id }),
                  self.downloads[index].status == .queued,
                  self.downloads[index].error != message else { return }
            self.downloads[index].error = message
            self.saveDownloads()
        }
    }

    private func clearQueuedMessage(id: String) {
        DispatchQueue.main.async {
            guard let index = self.downloads.firstIndex(where: { $0.id == id }),
                  self.downloads[index].error != nil else { return }
            self.downloads[index].error = nil
            self.saveDownloads()
        }
    }

    private static let knownVideoExtensions: Set<String> = [
        "mp4", "mkv", "webm", "mov", "avi", "wmv", "flv", "ts", "m2ts",
        "mpg", "mpeg", "ogv", "3gp", "m4v", "vob", "divx", "asf", "rm",
        "rmvb", "f4v", "mts"
    ]

    private static let knownSubtitleExtensions: Set<String> = [
        "srt", "vtt", "ass", "ssa", "sub", "idx", "sup", "smi", "mks", "dfxp", "ttml"
    ]

    private func startDownloadSubtitle(
        for item: DownloadItem,
        originalStreamURL: URL,
        protectedNuvioAttemptID: UUID?
    ) {
        guard let subtitleURLString = item.subtitleURL,
              let subtitleURL = URL(string: subtitleURLString) else { return }
        let subtitleHeaders = effectiveSubtitleHeaders(
            for: item,
            subtitleURL: subtitleURL,
            streamURL: originalStreamURL
        )
#if os(iOS) && !targetEnvironment(macCatalyst)
        if let protectedNuvioAttemptID {
            guard let proxyURL = makeNuvioSubtitleProxyURL(
                id: item.id,
                attemptID: protectedNuvioAttemptID,
                subtitleURL: subtitleURL,
                headers: subtitleHeaders
            ) else {
                Logger.shared.log(
                    "Nuvio subtitle skipped because its protected route could not start id=\(item.id)",
                    type: "Download"
                )
                return
            }
            downloadProtectedNuvioSubtitle(
                for: item.id,
                from: proxyURL,
                extensionSourceURL: subtitleURL,
                attemptID: protectedNuvioAttemptID
            )
            return
        }
#endif
        downloadSubtitle(for: item.id, from: subtitleURL, headers: subtitleHeaders)
    }

#if os(iOS) && !targetEnvironment(macCatalyst)
    private func downloadProtectedNuvioSubtitle(
        for downloadId: String,
        from proxyURL: URL,
        extensionSourceURL: URL,
        attemptID: UUID
    ) {
        guard protectedProviderAttempts[downloadId]?.attemptID == attemptID,
              let item = downloads.first(where: { $0.id == downloadId }),
              nuvioOwnerMatchesActiveProfile(item) else {
            finishNuvioSubtitleProxy(id: downloadId, attemptID: attemptID, proxyURL: proxyURL)
            return
        }
        var request = URLRequest(url: proxyURL)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let fetch = NuvioBoundedSubtitleFetch(maximumBytes: 5_000_000) { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                defer {
                    self.finishNuvioSubtitleProxy(
                        id: downloadId,
                        attemptID: attemptID,
                        proxyURL: proxyURL
                    )
                }
                guard self.nuvioAttemptIsCurrent(id: downloadId, attemptID: attemptID),
                      let item = self.downloads.first(where: { $0.id == downloadId }),
                      self.nuvioOwnerMatchesActiveProfile(item) else { return }
                guard case .success(let output) = result, !output.data.isEmpty else {
                    if case .failure(let error) = result,
                       (error as? URLError)?.code != .cancelled {
                        Logger.shared.log(
                            "Nuvio subtitle skipped id=\(downloadId)"
                                + " reason=\(self.boundedTransportErrorToken(error))",
                            type: "Download"
                        )
                    }
                    return
                }

                var ext = extensionSourceURL.pathExtension.lowercased()
                if ext.isEmpty || !Self.knownSubtitleExtensions.contains(ext) {
                    let contentType = output.response.mimeType?.lowercased() ?? ""
                    if contentType.contains("vtt") || contentType.contains("webvtt") {
                        ext = "vtt"
                    } else if contentType.contains("ass") || contentType.contains("ssa") {
                        ext = "ass"
                    } else if contentType.contains("ttml") {
                        ext = "ttml"
                    } else {
                        ext = "srt"
                    }
                }
                let fileName = self.reserveFinalSubtitleFileName(
                    downloadID: downloadId,
                    fileExtension: ext
                )
                let destination = self.downloadFileURL(relativePath: fileName)
                self.ensureParentDirectoryExists(for: destination)
                if self.isRegularFile(at: destination),
                   !self.downloadOwnsTrackedPath(
                       downloadID: downloadId,
                       relativePath: fileName,
                       subtitle: true
                   ) {
                    Logger.shared.log(
                        "Protected provider subtitle destination became occupied id=\(downloadId)",
                        type: "Download"
                    )
                    return
                }
                do {
                    try output.data.write(to: destination, options: .atomic)
                    guard self.nuvioAttemptIsCurrent(id: downloadId, attemptID: attemptID),
                          let index = self.downloads.firstIndex(where: { $0.id == downloadId }),
                          self.nuvioOwnerMatchesActiveProfile(self.downloads[index]) else {
                        try? self.fileManager.removeItem(at: destination)
                        return
                    }
                    self.downloads[index].subtitleFileName = fileName
                    self.downloads[index].reservedSubtitleFileName = fileName
                    self.saveDownloads()
                    Logger.shared.log("Downloaded protected provider subtitle id=\(downloadId)", type: "Download")
                } catch {
                    Logger.shared.log(
                        "Failed to save protected provider subtitle id=\(downloadId) reason=\(self.boundedTransportErrorToken(error))",
                        type: "Download"
                    )
                }
            }
        }
        nuvioSubtitleFetches[downloadId]?.cancel()
        nuvioSubtitleFetches[downloadId] = fetch
        fetch.start(request)
    }
#endif

    private func downloadSubtitle(
        for downloadId: String,
        from url: URL,
        headers: [String: String]
    ) {
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let subtitleTask = URLSession.shared.downloadTask(with: request) { [weak self] tempURL, response, error in
            guard let self = self, let tempURL = tempURL, error == nil else { return }

            if let httpResponse = response as? HTTPURLResponse {
                let body = self.downloadBodyPreview(from: tempURL)
                if let message = self.challengeFailureMessage(for: httpResponse, body: body) {
                    Logger.shared.log("Subtitle download skipped for \(downloadId): \(message)", type: "Download")
                    return
                }
            }

            var ext = url.pathExtension.lowercased()
            if ext.isEmpty || !Self.knownSubtitleExtensions.contains(ext) {

                if let httpResp = response as? HTTPURLResponse,
                   let contentType = httpResp.value(forHTTPHeaderField: "Content-Type")?.lowercased() {
                    if contentType.contains("vtt") || contentType.contains("webvtt") {
                        ext = "vtt"
                    } else if contentType.contains("ass") || contentType.contains("ssa") {
                        ext = "ass"
                    } else if contentType.contains("subrip") {
                        ext = "srt"
                    } else {
                        ext = "srt"
                    }
                } else {
                    ext = "srt"
                }
            }
            let fileName = self.reserveFinalSubtitleFileName(
                downloadID: downloadId,
                fileExtension: ext
            )
            let destURL = self.downloadFileURL(relativePath: fileName)
            self.ensureParentDirectoryExists(for: destURL)

            if self.isRegularFile(at: destURL) {
                let currentOwnsDestination = self.downloadOwnsTrackedPath(
                    downloadID: downloadId,
                    relativePath: fileName,
                    subtitle: true
                )
                guard currentOwnsDestination else {
                    Logger.shared.log(
                        "Subtitle destination became occupied before save for \(downloadId)",
                        type: "Download"
                    )
                    return
                }
                try? self.fileManager.removeItem(at: destURL)
            }
            do {
                try self.fileManager.moveItem(at: tempURL, to: destURL)
                DispatchQueue.main.async {
                    if let index = self.downloads.firstIndex(where: { $0.id == downloadId }) {
                        self.downloads[index].subtitleFileName = fileName
                        self.downloads[index].reservedSubtitleFileName = fileName
                        self.saveDownloads()
                    }
                }
                Logger.shared.log("Downloaded subtitle for \(downloadId)", type: "Download")
            } catch {
                Logger.shared.log("Failed to save subtitle for \(downloadId): \(error)", type: "Download")
            }
        }
        subtitleTask.resume()
    }

    private func handleCancelledHLSDownload(id: String) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else {
            processQueue()
            return
        }

        if downloads[index].status == .downloading {
            downloads[index].status = .paused
        }

        saveDownloads()
        processQueue()
    }

    private func requeueInterruptedHLSDownload(id: String, message: String) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else {
            processQueue()
            return
        }

        if downloads[index].status == .downloading || downloads[index].status == .queued {
            downloads[index].status = .queued
            downloads[index].error = message
        }

        saveDownloads()
        processQueue()
    }

    private func scheduleRateLimitedDownloadRetry(id: String, retryAfterSeconds: TimeInterval?) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else {
            processQueue()
            return
        }
        var retryAuthorityURL = URL(string: downloads[index].streamURL)
#if os(iOS) && !targetEnvironment(macCatalyst)
        retryAuthorityURL = protectedProviderAttempts[id]
            .flatMap { URL(string: $0.authorityURL) } ?? retryAuthorityURL
        if downloads[index].claimsProtectedProviderTransport {
            clearProtectedProviderDownloadRuntimeState(id: id, scrubTransport: true)
        }
#endif

        if let task = activeTasks.removeValue(forKey: id) {
            invalidatedDirectTaskIdentifiers.insert(task.taskIdentifier)
            task.cancel()
        }
        activeHLSDownloaders.removeValue(forKey: id)
        let retryCount = (downloads[index].rateLimitRetryCount ?? 0) + 1
        downloads[index].rateLimitRetryCount = retryCount
        if retryCount > 3 {
            downloads[index].retryNotBefore = nil
            if hasRefreshableProviderReference(downloads[index]) {
                recoverDownloadAfterMediaRejection(
                    id: id,
                    statusCode: 429,
                    challengedURL: retryAuthorityURL,
                    rejectedCookieHeader: nil,
                    isInteractiveChallenge: false
                )
            } else {
                markFailed(id: id, error: "The CDN kept rate limiting this download.")
            }
            return
        }
        let finiteRetryAfter = retryAfterSeconds.flatMap { $0.isFinite ? $0 : nil }
        let delay = min(max(finiteRetryAfter ?? 8, 8), 30)
        let retryDate = Date().addingTimeInterval(delay)
        downloads[index].status = .queued
        downloads[index].retryNotBefore = retryDate
        downloads[index].error = "CDN rate limited this download. Retrying automatically..."
        saveDownloads()
        processQueue()
        Logger.shared.log(
            "Download rate limited; scheduled retry id=\(id) delay=\(String(format: "%.1f", delay))s",
            type: "Download"
        )

    }

    private func scheduleSystemBackoffDownloadRetry(id: String, message: String) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else {
            processQueue()
            return
        }
#if os(iOS) && !targetEnvironment(macCatalyst)
        if downloads[index].claimsProtectedProviderTransport {
            clearProtectedProviderDownloadRuntimeState(id: id, scrubTransport: true)
        }
#endif
        if let task = activeTasks.removeValue(forKey: id) {
            invalidatedDirectTaskIdentifiers.insert(task.taskIdentifier)
            task.cancel()
        }
        activeHLSDownloaders.removeValue(forKey: id)
        downloads[index].status = .queued

        downloads[index].retryNotBefore = Date().addingTimeInterval(60)
        downloads[index].error = message
        saveDownloads()
        processQueue()
    }

    private func recoverDownloadAfterConfirmedChallenge(
        id: String,
        challengedURL: URL,
        rejectedCookieHeader: String?
    ) {
        recoverDownloadAfterMediaRejection(
            id: id,
            statusCode: 403,
            challengedURL: challengedURL,
            rejectedCookieHeader: rejectedCookieHeader,
            isInteractiveChallenge: true
        )
    }

    private func recoverDownloadAfterMediaRejection(
        id: String,
        statusCode: Int,
        challengedURL: URL?,
        rejectedCookieHeader: String?,
        isInteractiveChallenge: Bool
    ) {
        performOnMain { [weak self] in
            guard let self,
                  let index = downloads.firstIndex(where: { $0.id == id }),
                  cloudflareRecoveringDownloadIDs.insert(id).inserted else { return }

            guard beginMediaSourceRecoveryAttempt(id: id) else {
                cloudflareRecoveringDownloadIDs.remove(id)
                markFailed(
                    id: id,
                    error: "The media source could not be refreshed after repeated HTTP \(statusCode) responses."
                )
                return
            }

            if let task = activeTasks.removeValue(forKey: id) {
                invalidatedDirectTaskIdentifiers.insert(task.taskIdentifier)
                task.cancel()
            }
            if let downloader = activeHLSDownloaders[id] {
                if let attemptID = activeHLSAttemptIDs[id] {
                    invalidatedHLSAttemptIDs.insert(attemptID)
                }
                downloader.cancel()
            }
#if os(iOS) && !targetEnvironment(macCatalyst)
            if downloads[index].providerTransportKind == .skyStreamHLS {
                clearSkyStreamDownloadRuntimeState(id: id, discardDescriptor: true)
            }
            if downloads[index].claimsProtectedProviderTransport {
                clearProtectedProviderDownloadRuntimeState(id: id, scrubTransport: true)
            }
#endif
            downloads[index].status = .paused
            downloads[index].error = "Refreshing expired media source"
#if os(iOS) && !targetEnvironment(macCatalyst)
            let recoveringProtectedOwnerProfileID = downloads[index]
                .claimsProtectedProviderTransport
                ? downloads[index].effectiveProtectedOwnerProfileID
                : nil
            let recoveringServiceScopeGeneration = ServiceStoreScope.generation
#endif
            saveDownloads()
            processQueue()

            Logger.shared.log(
                "Download media access rejected; re-resolving provider id=\(id) status=\(statusCode) interactiveChallenge=\(isInteractiveChallenge) host=\(challengedURL?.host ?? "unknown")",
                type: "Download"
            )

            Task { @MainActor [weak self] in
                guard let self else { return }
                var refreshed = await refreshDownloadSource(id: id)
#if os(iOS) && !targetEnvironment(macCatalyst)
                if let recoveringProtectedOwnerProfileID,
                   (ProfileManager.shared.activeProfileID != recoveringProtectedOwnerProfileID
                    || !ServiceStoreScope.isCurrent(recoveringServiceScopeGeneration)) {
                    if let currentIndex = downloads.firstIndex(where: { $0.id == id }) {
                        downloads[currentIndex].status = .queued
                        downloads[currentIndex].error = "Waiting for the download's profile"
                        scrubProtectedProviderTransportInMemory(id: id)
                    }
                    cloudflareRecoveringDownloadIDs.remove(id)
                    saveDownloads()
                    processQueue()
                    return
                }
#endif
                var solvedMediaChallenge = false
                let rejectedStreamURL = downloads.first(where: { $0.id == id })?.streamURL
                let recoveryKind = downloads.first(where: { $0.id == id })?
                    .lastContentReference?.kind
                let permitsLegacyInteractiveSolve = recoveryKind != .skyStream
                    && recoveryKind != .nuvio
                    && recoveryKind != .stremio

                if isInteractiveChallenge,
                   permitsLegacyInteractiveSolve,
                   refreshed == nil || refreshed?.directURL?.absoluteString == rejectedStreamURL,
                   let challengedURL {
                    solvedMediaChallenge = await CloudflareBypassManager.shared.refreshSessionAfterChallenge(
                        for: challengedURL,
                        rejectedCookieHeader: rejectedCookieHeader
                    )
                    if solvedMediaChallenge {
                        refreshed = await refreshDownloadSource(id: id) ?? refreshed
                    }
                }

                guard let currentIndex = downloads.firstIndex(where: { $0.id == id }),
                      downloads[currentIndex].status == .paused else {
                    cloudflareRecoveringDownloadIDs.remove(id)
                    processQueue()
                    return
                }

                if let refreshed,
                   let installed = installRefreshedDownloadSource(
                       refreshed,
                       id: id,
                       resetTransferProgress: true
                   ) {
                    downloads[currentIndex].status = .queued
                    downloads[currentIndex].rateLimitRetryCount = nil
                    downloads[currentIndex].error = nil
                    cloudflareRecoveringDownloadIDs.remove(id)
                    saveDownloads()
                    Logger.shared.log(
                        "Download provider re-resolved source id=\(id) changedTransport=\(installed.changed) kind=\(installed.kind)",
                        type: "Download"
                    )
                    processQueue()
                } else if solvedMediaChallenge {

                    downloads[currentIndex].status = .queued
                    downloads[currentIndex].error = nil
                    cloudflareRecoveringDownloadIDs.remove(id)
                    saveDownloads()
                    processQueue()
                } else {
                    let isSkyStream = downloads[currentIndex].lastContentReference?.kind == .skyStream
                    cloudflareRecoveringDownloadIDs.remove(id)
                    markFailed(
                        id: id,
                        error: isSkyStream
                            ? "The SkyStream provider could not produce a validated refreshed source."
                            : isInteractiveChallenge
                                ? "Cloudflare verification did not produce a usable refreshed source."
                                : "The media URL expired and the provider could not refresh it."
                    )
                }
            }
        }
    }

    @MainActor
    private func installRefreshedDownloadSource(
        _ refreshed: RefreshedDownloadSource,
        id: String,
        resetTransferProgress: Bool
    ) -> (changed: Bool, kind: String)? {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return nil }
#if os(iOS) && !targetEnvironment(macCatalyst)
        let refreshReplacesProtectedTransport = refreshed.lastContentReference.kind == .nuvio
            || refreshed.lastContentReference.kind == .service
            || refreshed.lastContentReference.kind == .stremio
            || (refreshed.lastContentReference.kind == .skyStream
                && downloads[index].effectiveProtectedProviderKind == .skyStream)
        if refreshReplacesProtectedTransport {
            guard protectedOwnerMatchesActiveProfile(downloads[index]) else { return nil }
            if refreshed.lastContentReference.kind == .stremio,
               refreshed.stremioConfiguredOriginAuthority == nil {
                return nil
            }
            invalidateNuvioProtectedAttempt(id: id)
        }
#endif
        let previousURL = downloads[index].streamURL
        let previousWasHLS = downloads[index].isHLS
        let changed: Bool
        let kind: String
#if os(iOS) && !targetEnvironment(macCatalyst)
        if refreshed.lastContentReference.kind != .stremio {
            stremioConfiguredOriginAuthorities.removeValue(forKey: id)
        }
#endif

        switch refreshed.transport {
        case .direct(let url, let headers, let expectedContentLength):
#if os(iOS) && !targetEnvironment(macCatalyst)
            if downloads[index].providerTransportKind == .skyStreamHLS {
                clearSkyStreamDownloadRuntimeState(id: id, discardDescriptor: true)
            }
#endif
            downloads[index].streamURL = url.absoluteString
            downloads[index].headers = headers
            if refreshed.lastContentReference.kind == .skyStream {
                downloads[index].providerTransportKind = .skyStreamDirect
                downloads[index].protectedProviderKind = .skyStream
                downloads[index].protectedTransportKind = ProtectedDownloadPersistencePolicy.transportKind(
                    for: url.absoluteString
                )
                if downloads[index].protectedOwnerProfileID == nil {
                    downloads[index].protectedOwnerProfileID = ProfileManager.shared.activeProfileID
                }
                downloads[index].subtitleURL = refreshed.subtitleURL
                downloads[index].subtitleHeaders = refreshed.subtitleHeaders
            } else if refreshed.lastContentReference.kind == .nuvio
                || refreshed.lastContentReference.kind == .service
                || refreshed.lastContentReference.kind == .stremio {
                downloads[index].providerTransportKind = nil
                let providerKind: ProtectedDownloadProviderKind
                switch refreshed.lastContentReference.kind {
                case .nuvio: providerKind = .nuvio
                case .stremio: providerKind = .stremio
                default: providerKind = .service
                }
                downloads[index].protectedProviderKind = providerKind
                downloads[index].protectedTransportKind = ProtectedDownloadPersistencePolicy.transportKind(
                    for: url.absoluteString
                )
                if providerKind == .nuvio {
                    downloads[index].nuvioTransportKind = downloads[index].protectedTransportKind
                    downloads[index].nuvioOwnerProfileID = downloads[index]
                        .effectiveProtectedOwnerProfileID
                }
#if os(iOS) && !targetEnvironment(macCatalyst)
                if providerKind == .stremio,
                   let authority = refreshed.stremioConfiguredOriginAuthority {
                    stremioConfiguredOriginAuthorities[id] = authority
                } else {
                    stremioConfiguredOriginAuthorities.removeValue(forKey: id)
                }
#endif
                downloads[index].subtitleURL = refreshed.subtitleURL
                downloads[index].subtitleHeaders = refreshed.subtitleHeaders
            }
            downloads[index].validatedExpectedContentLength = expectedContentLength
            changed = previousWasHLS || previousURL != url.absoluteString
            kind = refreshed.lastContentReference.kind == .skyStream ? "sky-direct" : "direct"
#if os(iOS) && !targetEnvironment(macCatalyst)
        case .skyStreamHLS(let descriptor):
            guard Self.skyStreamHLSRejectionReason(descriptor) == nil else { return nil }
            clearSkyStreamDownloadRuntimeState(id: id, discardDescriptor: true)
            skyStreamHLSDescriptors[id] = descriptor
            downloads[index].streamURL = ""
            downloads[index].headers = [:]
            downloads[index].providerTransportKind = .skyStreamHLS
            downloads[index].validatedExpectedContentLength = nil
            changed = true
            kind = "sky-hls"
#endif
        }

        downloads[index].streamName = refreshed.streamName
        downloads[index].serviceContentHref = refreshed.serviceContentHref
        downloads[index].lastSourceId = refreshed.lastSourceId
        downloads[index].lastContentReference = refreshed.lastContentReference
        downloads[index].retryNotBefore = nil
        downloads[index].rateLimitRetryCount = nil

        if resetTransferProgress,
           (changed || downloads[index].isHLS
                || downloads[index].claimsProtectedProviderTransport) {
            downloads[index].hlsResumeSegmentIndex = nil
            downloads[index].hlsResumeByteCount = nil
            downloads[index].hlsVariantURL = nil
            downloads[index].hlsTotalSegments = nil
            downloads[index].progress = 0
            downloads[index].downloadedBytes = 0
            downloads[index].totalBytes = 0
            resumeDataStore.removeValue(forKey: id)
        }
        return (changed, kind)
    }

    private func beginMediaSourceRecoveryAttempt(id: String) -> Bool {
        let now = Date()
        let previous = mediaSourceRecoveryAttempts[id]
        let count: Int
        if let previous,
           now.timeIntervalSince(previous.lastAttempt) <= 30 {
            count = previous.count
        } else {
            count = 0
        }
        guard count < 2 else { return false }
        mediaSourceRecoveryAttempts[id] = (count + 1, now)
        return true
    }

    private func hasRefreshableProviderReference(_ item: DownloadItem) -> Bool {
        if let sourceId = item.lastSourceId,
           let reference = item.lastContentReference,
           Self.isValidRecoveryReference(reference, matchingSourceId: sourceId) {
            switch reference.kind {
            case .service:
                return reference.serviceHref?.isEmpty == false
            case .skyStream:
                return reference.skyStream?.isStructurallyValid == true
            case .stremio:
                return reference.hasValidStremioSelection
            case .nuvio:
#if os(iOS) && !targetEnvironment(macCatalyst)
                return reference.nuvio?.isStructurallyValid == true
#else
                return false
#endif
            }
        }
        return item.sourceId?.hasPrefix("service:") == true
            && item.serviceContentHref?.isEmpty == false
    }

    @MainActor
    private func refreshDownloadSource(id: String) async -> RefreshedDownloadSource? {
        guard let item = downloads.first(where: { $0.id == id }) else { return nil }
        if let sourceId = item.lastSourceId,
           let reference = item.lastContentReference,
           Self.isValidRecoveryReference(reference, matchingSourceId: sourceId) {
            switch reference.kind {
            case .service:
                return await refreshServiceDownloadSource(id: id)
            case .skyStream:
#if os(iOS) && !targetEnvironment(macCatalyst)
                return await refreshSkyStreamDownloadSource(item: item, reference: reference)
#else
                return nil
#endif
            case .stremio:
#if os(iOS) && !targetEnvironment(macCatalyst)
                return await refreshStremioDownloadSource(item: item, reference: reference)
#else
                return nil
#endif
            case .nuvio:
#if os(iOS) && !targetEnvironment(macCatalyst)
                return await refreshNuvioDownloadSource(item: item, reference: reference)
#else
                return nil
#endif
            }
        }
        return await refreshServiceDownloadSource(id: id)
    }

    private static func stremioDownloadHeaders(
        _ headers: [String: String]
    ) -> [String: String] {
        var result = headers
        if !result.keys.contains(where: {
            $0.caseInsensitiveCompare("User-Agent") == .orderedSame
        }) {
            result["User-Agent"] = URLSession.randomUserAgent
        }
        return result
    }

#if os(iOS) && !targetEnvironment(macCatalyst)
    @MainActor
    private func refreshStremioDownloadSource(
        item: DownloadItem,
        reference: ProviderContentReference
    ) async -> RefreshedDownloadSource? {
        guard reference.kind == .stremio,
              reference.sourceID == item.lastSourceId,
              reference.hasValidStremioSelection,
              Self.protectedAuthorityState(for: item) == .authorized(.stremio),
              let ownerProfileID = item.effectiveProtectedOwnerProfileID,
              ownerProfileID == ProfileManager.shared.activeProfileID else {
            return nil
        }
        let scopeGeneration = ServiceStoreScope.generation
        guard let resolved = await StremioAddonManager.shared.resolveDownloadTransport(
            reference: reference,
            ownerProfileID: ownerProfileID,
            serviceStoreGeneration: scopeGeneration
        ),
              !Task.isCancelled,
              ownerProfileID == ProfileManager.shared.activeProfileID,
              ServiceStoreScope.isCurrent(scopeGeneration),
              resolved.refreshedReference.sourceID == reference.sourceID,
              resolved.refreshedReference.hasValidStremioSelection,
              let streamURL = URL(string: resolved.streamURL),
              let scheme = streamURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              streamURL.user == nil,
              streamURL.password == nil else {
            return nil
        }

        let subtitleURL: String?
        if let rawSubtitle = resolved.subtitleURL,
           let parsed = URL(string: rawSubtitle),
           let subtitleScheme = parsed.scheme?.lowercased(),
           subtitleScheme == "http" || subtitleScheme == "https",
           parsed.user == nil,
           parsed.password == nil {
            subtitleURL = parsed.absoluteString
        } else {
            subtitleURL = nil
        }

        return RefreshedDownloadSource(
            transport: .direct(
                url: streamURL,
                headers: Self.stremioDownloadHeaders(resolved.headers),
                expectedContentLength: nil
            ),
            streamName: item.streamName,
            subtitleURL: subtitleURL,
            subtitleHeaders: nil,
            serviceContentHref: nil,
            lastSourceId: reference.sourceID,
            lastContentReference: resolved.refreshedReference,
            stremioConfiguredOriginAuthority: resolved.configuredOriginAuthority
        )
    }
#endif

    @MainActor
    private func refreshServiceDownloadSource(id: String) async -> RefreshedDownloadSource? {
        guard let item = downloads.first(where: { $0.id == id }),
              let sourceId = (item.lastContentReference?.kind == .service
                  ? item.lastSourceId
                  : nil) ?? item.sourceId,
              let contentHref = (item.lastContentReference?.kind == .service
                  ? item.lastContentReference?.serviceHref
                  : nil) ?? item.serviceContentHref,
              !contentHref.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              contentHref.utf8.count <= 8 * 1_024,
              !contentHref.isEmpty,
              let service = ServiceManager.shared.activeServices.first(where: {
                  SourceHealth.serviceId($0) == sourceId
              }) else {
            return nil
        }

        let jsController = JSController()
        jsController.loadScript(service.jsScript, service: service)
        let episodes: [EpisodeLink] = await withCheckedContinuation { continuation in
            jsController.fetchEpisodesJS(url: contentHref, module: service) { [jsController] episodes in
                _ = jsController
                continuation.resume(returning: episodes)
            }
        }
        guard !Task.isCancelled,
              let streamHref = refreshedDownloadEpisodeHref(episodes: episodes, item: item) else {
            return nil
        }

        let extraction: ServiceStreamExtractionResult = await withCheckedContinuation { continuation in
            jsController.fetchStreamUrlJS(
                episodeUrl: streamHref,
                softsub: service.metadata.softsub ?? false,
                module: service
            ) { [jsController] result in
                _ = jsController
                continuation.resume(returning: result)
            }
        }
        guard !Task.isCancelled,
              let selected = selectRefreshedDownloadStream(
                  streams: extraction.streams,
                  sources: extraction.sources,
                  item: item,
                  sourceId: sourceId
              ),
              let url = URL(string: selected.url),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }

        var headers: [String: String] = [
            "Origin": service.metadata.baseUrl,
            "Referer": service.metadata.baseUrl,
            "User-Agent": URLSession.randomUserAgent
        ]
        for (key, value) in selected.headers {
            headers[key] = value
        }
        let refreshedSubtitleURL = extraction.subtitles?
            .compactMap { rawValue -> String? in
                guard let url = URL(string: rawValue),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                    return nil
                }
                return url.absoluteString
            }
            .first
        return RefreshedDownloadSource(
            transport: .direct(url: url, headers: headers, expectedContentLength: nil),
            streamName: selected.label,
            subtitleURL: refreshedSubtitleURL,
            subtitleHeaders: refreshedSubtitleURL == item.subtitleURL
                ? item.subtitleHeaders
                : nil,
            serviceContentHref: contentHref,
            lastSourceId: sourceId,
            lastContentReference: .service(sourceID: sourceId, href: contentHref)
        )
    }

#if os(iOS) && !targetEnvironment(macCatalyst)
    @MainActor
    private func refreshSkyStreamDownloadSource(
        item: DownloadItem,
        reference: ProviderContentReference
    ) async -> RefreshedDownloadSource? {
        guard reference.kind == .skyStream,
              let skyReference = reference.skyStream,
              reference.sourceID == skyReference.sourceID,
              skyDownloadReferenceMatchesItem(skyReference, item: item) else {
            return nil
        }

        do {
            let refreshed = try await SkyStreamResolver.shared.refresh(
                skyReference,
                mode: .downloadRefresh,
                originalAudioLanguage: item.originalAudioLanguage
            )
            guard !Task.isCancelled,
                  let resolved = refreshed.first,
                  resolved.provider.id == reference.sourceID,
                  resolved.contentReference.sourceID == reference.sourceID else {
                return nil
            }
            let descriptor = resolved.playback
            let transport: RefreshedDownloadTransport
            switch descriptor.mediaKind {
            case .direct:
                guard item.providerTransportKind != .skyStreamHLS,
                      descriptor.proxyOptions == nil,
                      descriptor.acceptedManifests.isEmpty,
                      let contentLength = descriptor.finiteContentLength,
                      contentLength > 0 else {
                    Logger.shared.log(
                        "SkyStream: download refresh rejected unsafe direct descriptor source=\(reference.sourceID)",
                        type: "Download"
                    )
                    return nil
                }
                transport = .direct(
                    url: descriptor.underlyingRemoteURL.url,
                    headers: descriptor.headers.values,
                    expectedContentLength: contentLength
                )
            case .hls:
                guard item.providerTransportKind == .skyStreamHLS,
                      Self.skyStreamHLSRejectionReason(descriptor) == nil else {
                    Logger.shared.log(
                        "SkyStream: download refresh rejected unsupported HLS descriptor source=\(reference.sourceID)",
                        type: "Download"
                    )
                    return nil
                }
                transport = .skyStreamHLS(descriptor)
            case .dash:
                Logger.shared.log(
                    "SkyStream: download refresh rejected DASH descriptor source=\(reference.sourceID)",
                    type: "Download"
                )
                return nil
            }
            let refreshedReference = ProviderContentReference.skyStream(resolved.contentReference)
            guard refreshedReference.sourceID == reference.sourceID else { return nil }
            return RefreshedDownloadSource(
                transport: transport,
                streamName: resolved.displayName,
                subtitleURL: nil,
                subtitleHeaders: nil,
                serviceContentHref: nil,
                lastSourceId: reference.sourceID,
                lastContentReference: refreshedReference
            )
        } catch is CancellationError {
            return nil
        } catch {
            let errorType = String(reflecting: type(of: error))
            Logger.shared.log(
                "SkyStream: validated download refresh failed source=\(reference.sourceID) errorType=\(errorType)",
                type: "Download"
            )
            return nil
        }
    }

#if os(iOS) && !targetEnvironment(macCatalyst)

    @MainActor
    private func refreshNuvioDownloadSource(
        item: DownloadItem,
        reference: ProviderContentReference
    ) async -> RefreshedDownloadSource? {
        guard reference.kind == .nuvio,
              let nuvioReference = reference.nuvio,
              reference.sourceID == nuvioReference.sourceID,
              nuvioDownloadReferenceMatchesItem(nuvioReference, item: item),
              nuvioOwnerMatchesActiveProfile(item) else {
            return nil
        }
        let ownerProfileID = item.nuvioOwnerProfileID
        let scopeGeneration = ServiceStoreScope.generation

        let streams = await NuvioPluginManager.shared.resolveStreams(
            scraperID: nuvioReference.scraperID,
            tmdbId: nuvioReference.tmdbID,
            mediaType: nuvioReference.mediaType,
            season: nuvioReference.season,
            episode: nuvioReference.episode
        )
        guard !Task.isCancelled,
              ServiceStoreScope.isCurrent(scopeGeneration),
              ProfileManager.shared.activeProfileID == ownerProfileID else { return nil }

        let previousLabel = item.streamName ?? item.title
        let preferred = streams.first { $0.displayName == previousLabel } ?? streams.first
        guard let chosen = preferred,
              chosen.isDirectHTTP,
              chosen.scraperId == nuvioReference.scraperID,
              let url = URL(string: chosen.url) else {
            Logger.shared.log(
                "Nuvio: download refresh produced no playable stream source=\(reference.sourceID)",
                type: "Download"
            )
            return nil
        }

        let subtitle = chosen.subtitles?.first(where: {
            URL(string: $0.url).map { ["http", "https"].contains($0.scheme?.lowercased() ?? "") } == true
        })
        return RefreshedDownloadSource(
            transport: .direct(
                url: url,
                headers: chosen.sanitizedHeaders ?? [:],
                expectedContentLength: nil
            ),
            streamName: chosen.displayName,
            subtitleURL: subtitle?.url,
            subtitleHeaders: subtitle?.sanitizedHeaders,
            serviceContentHref: nil,
            lastSourceId: reference.sourceID,
            lastContentReference: reference
        )
    }
#endif

    private func nuvioDownloadReferenceMatchesItem(
        _ reference: NuvioProviderContentReference,
        item: DownloadItem
    ) -> Bool {
        guard reference.isStructurallyValid else { return false }
        if item.isMovie {
            return reference.mediaType == "movie"
        }
        guard reference.mediaType == "tv",
              let referenceSeason = reference.season,
              let referenceEpisode = reference.episode,
              referenceSeason >= 0,
              referenceEpisode > 0 else {
            return false
        }

        var acceptedCoordinates = Set<String>()
        if let season = item.seasonNumber, let episode = item.episodeNumber {
            acceptedCoordinates.insert("\(season):\(episode)")
        }
        if let context = item.episodePlaybackContext {
            if let season = context.resolvedTMDBSeasonNumber,
               let episode = context.resolvedTMDBEpisodeNumber {
                acceptedCoordinates.insert("\(season):\(episode)")
            }
            if let absolute = context.animeAbsoluteEpisodeNumber, absolute > 0 {
                acceptedCoordinates.insert("1:\(absolute)")
            }
        }
        return acceptedCoordinates.contains("\(referenceSeason):\(referenceEpisode)")
    }

    private func skyDownloadReferenceMatchesItem(
        _ reference: SkyStreamProviderContentReference,
        item: DownloadItem
    ) -> Bool {
        guard reference.isStructurallyValid else { return false }
        if item.isMovie {
            return reference.season == nil && reference.episode == nil
        }
        guard let referenceSeason = reference.season,
              let referenceEpisode = reference.episode,
              referenceSeason >= 0,
              referenceEpisode > 0 else {
            return false
        }

        var acceptedCoordinates = Set<String>()
        if let season = item.seasonNumber, let episode = item.episodeNumber {
            acceptedCoordinates.insert("\(season):\(episode)")
        }
        if let context = item.episodePlaybackContext {
            if let season = context.resolvedTMDBSeasonNumber,
               let episode = context.resolvedTMDBEpisodeNumber {
                acceptedCoordinates.insert("\(season):\(episode)")
            }
            if let absolute = context.animeAbsoluteEpisodeNumber, absolute > 0 {
                acceptedCoordinates.insert("1:\(absolute)")
            }
        }
        return acceptedCoordinates.contains("\(referenceSeason):\(referenceEpisode)")
    }
#endif

    private func refreshedDownloadEpisodeHref(
        episodes: [EpisodeLink],
        item: DownloadItem
    ) -> String? {
        guard !episodes.isEmpty else { return nil }
        if item.isMovie { return episodes.first?.href ?? item.serviceContentHref }

        let localSeason = item.seasonNumber ?? 1
        let localEpisode = item.episodeNumber ?? 1
        var seasons: [[EpisodeLink]] = []
        var current: [EpisodeLink] = []
        var lastNumber = 0
        for episode in episodes {
            if episode.number == 1 || episode.number <= lastNumber {
                if !current.isEmpty {
                    seasons.append(current)
                    current.removeAll(keepingCapacity: true)
                }
            }
            current.append(episode)
            lastNumber = episode.number
        }
        if !current.isEmpty { seasons.append(current) }

        let seasonIndex = localSeason - 1
        if seasons.indices.contains(seasonIndex),
           let exact = seasons[seasonIndex].first(where: { $0.number == localEpisode }) {
            return exact.href
        }

        let allEpisodes = seasons.flatMap { $0 }
        let context = item.episodePlaybackContext
        var candidates: [Int] = []
        if context?.isSpecial == true {
            candidates.append(contentsOf: [
                context?.resolvedTMDBEpisodeNumber,
                item.episodeNumber
            ].compactMap { $0 })
        } else {
            candidates.append(contentsOf: [
                context?.animeAbsoluteEpisodeNumber,
                context?.resolvedTMDBEpisodeNumber,
                item.episodeNumber
            ].compactMap { $0 })
        }
        var seen = Set<Int>()
        for number in candidates where number > 0 && seen.insert(number).inserted {
            let matches = allEpisodes.filter { $0.number == number }
            if matches.count == 1 { return matches[0].href }
        }
        return nil
    }

    private func selectRefreshedDownloadStream(
        streams: [String]?,
        sources: [[String: Any]]?,
        item: DownloadItem,
        sourceId: String
    ) -> (url: String, headers: [String: String], label: String)? {
        var candidates: [(url: String, headers: [String: String], label: String, scoreLabel: String)] = []
        if let sources, !sources.isEmpty {
            for source in sources {
                guard let url = ["streamUrl", "url", "file", "src", "link", "stream"]
                    .lazy
                    .compactMap({ source[$0] as? String })
                    .first(where: { !$0.isEmpty }) else { continue }
                let metadata = ["title", "name", "label", "quality", "provider", "server"]
                    .compactMap { source[$0] as? String }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                guard !StreamLanguageFilter.shouldHide(
                    languageHints: [],
                    metadata: metadata + [url],
                    sourceId: sourceId,
                    originalAudioLanguage: item.originalAudioLanguage,
                    isAnime: item.isAnime
                ) else { continue }
                candidates.append((
                    url,
                    refreshedDownloadHeaders(from: source["headers"]),
                    metadata.first ?? "Stream",
                    (metadata + [url]).joined(separator: " ")
                ))
            }
        } else if let streams {
            var index = 0
            while index < streams.count {
                let value = streams[index]
                let url: String
                let label: String
                if value.lowercased().hasPrefix("http") {
                    url = value
                    label = "Stream"
                    index += 1
                } else if index + 1 < streams.count,
                          streams[index + 1].lowercased().hasPrefix("http") {
                    url = streams[index + 1]
                    label = value
                    index += 2
                } else {
                    index += 1
                    continue
                }
                guard !StreamLanguageFilter.shouldHide(
                    languageHints: [],
                    metadata: [label, url],
                    sourceId: sourceId,
                    originalAudioLanguage: item.originalAudioLanguage,
                    isAnime: item.isAnime
                ) else { continue }
                candidates.append((url, [:], label, value))
            }
        }

        guard !candidates.isEmpty else { return nil }
        if let preferred = item.streamName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !preferred.isEmpty,
           let exact = candidates.first(where: {
               $0.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == preferred
           }) {
            return (exact.url, exact.headers, exact.label)
        }
        if candidates.count == 1 {
            let only = candidates[0]
            return (only.url, only.headers, only.label)
        }

        let preference = AutoModeQualityPreference.current
        guard preference.usesAutomaticSelection,
              candidates.contains(where: {
                  AutoModeStreamSelection.streamLabelHasDetectedQuality($0.scoreLabel)
              }),
              let best = candidates.enumerated().max(by: {
                  AutoModeStreamSelection.streamPreferenceScore(
                      label: $0.element.scoreLabel,
                      preference: preference,
                      index: $0.offset
                  ) < AutoModeStreamSelection.streamPreferenceScore(
                      label: $1.element.scoreLabel,
                      preference: preference,
                      index: $1.offset
                  )
              })?.element else {
            return nil
        }
        return (best.url, best.headers, best.label)
    }

    private func refreshedDownloadHeaders(from value: Any?) -> [String: String] {
        if let headers = value as? [String: String] { return headers }
        guard let headers = value as? [String: Any] else { return [:] }
        return headers.reduce(into: [:]) { result, pair in
            guard let value = pair.value as? String,
                  !pair.key.isEmpty,
                  !value.isEmpty else { return }
            result[pair.key] = value
        }
    }

    private func markFailed(id: String, error: String) {
        performOnMain { [weak self] in
            guard let self else { return }
            if let task = activeTasks.removeValue(forKey: id) {
                invalidatedDirectTaskIdentifiers.insert(task.taskIdentifier)
                task.cancel()
            }
            if let index = downloads.firstIndex(where: { $0.id == id }) {
#if os(iOS) && !targetEnvironment(macCatalyst)
                if downloads[index].providerTransportKind == .skyStreamHLS {
                    clearSkyStreamDownloadRuntimeState(id: id, discardDescriptor: true)
                }
                if downloads[index].claimsProtectedProviderTransport {
                    if let downloader = activeHLSDownloaders.removeValue(forKey: id) {
                        if let attemptID = activeHLSAttemptIDs.removeValue(forKey: id) {
                            invalidatedHLSAttemptIDs.insert(attemptID)
                        }
                        downloader.cancel()
                    }
                    clearProtectedProviderDownloadRuntimeState(id: id, scrubTransport: true)
                }
#endif
                downloads[index].status = .failed
                downloads[index].error = error
                saveDownloads()
                processQueue()
            }
            Logger.shared.log("Download failed: \(id) - \(error)", type: "Download")
        }
    }

    private func resumeInterruptedDownloads() {
        backgroundSession.getAllTasks { [weak self] tasks in
            guard let self else { return }
            self.performOnMain { [weak self] in
                guard let self else { return }
#if os(iOS) && !targetEnvironment(macCatalyst)
                self.migrateLegacyStremioDownloadsIfNeeded(permitsOneLiveAttempt: false)
#endif
                var retainedTaskIDs = Set<String>()

                for case let task as URLSessionDownloadTask in tasks {
                    if let id = task.taskDescription,
                       let index = downloads.firstIndex(where: { $0.id == id }),
                       !ProtectedDownloadPersistencePolicy.mayAdoptRestoredBackgroundTask(
                           claimsProtectedProvider: downloads[index]
                               .claimsProtectedProviderTransport
                       ) {
                        invalidatedDirectTaskIdentifiers.insert(task.taskIdentifier)
                        task.cancel()
#if os(iOS) && !targetEnvironment(macCatalyst)
                        invalidateNuvioProtectedAttempt(id: id)
                        scrubProtectedProviderTransportInMemory(id: id)
#endif
                        if downloads[index].status == .downloading {
                            downloads[index].status = .queued
                            downloads[index].error = "Refreshing protected download access"
                        }
                        continue
                    }
                    guard task.state == .running || task.state == .suspended,
                          let id = task.taskDescription,
                          let index = downloads.firstIndex(where: { $0.id == id }),
                          !downloads[index].isHLS,
                          (downloads[index].status == .downloading
                            || downloads[index].status == .queued),
                          !invalidatedDirectTaskIdentifiers.contains(task.taskIdentifier) else {
                        invalidatedDirectTaskIdentifiers.insert(task.taskIdentifier)
                        task.cancel()
                        continue
                    }
                    guard retainedTaskIDs.insert(id).inserted else {

                        invalidatedDirectTaskIdentifiers.insert(task.taskIdentifier)
                        task.cancel()
                        continue
                    }
                    if let newlyStartedTask = activeTasks[id],
                       newlyStartedTask !== task,
                       newlyStartedTask.taskIdentifier != task.taskIdentifier {

                        invalidatedDirectTaskIdentifiers.insert(newlyStartedTask.taskIdentifier)
                        newlyStartedTask.cancel()
                    }
                    activeTasks[id] = task
                    downloads[index].status = .downloading
                    downloads[index].error = nil
                    if task.state == .suspended {
                        task.resume()
                    }
                }

                retainedTaskIDs.formUnion(activeTasks.keys)

                for index in downloads.indices
                where downloads[index].status == .downloading
                    && !retainedTaskIDs.contains(downloads[index].id) {
                    downloads[index].status = .queued
                }
                saveDownloads()
                processQueue()
            }
        }
    }

    private func cleanOrphanedFiles() {
        let directory = downloadsDirectory
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let candidates = self.orphanedPartialCandidates(in: directory)
            guard !candidates.isEmpty else { return }

            DispatchQueue.main.async { [weak self] in
                self?.removeOrphanedPartialCandidates(candidates)
            }
        }
    }

    private struct OrphanedPartialCandidate {
        let url: URL
        let size: Int64
    }

    private func orphanedPartialCandidates(in directory: URL) -> [OrphanedPartialCandidate] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        var candidates: [OrphanedPartialCandidate] = []
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            guard name.hasPrefix("."), name.hasSuffix(".partial") else { continue }
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile != false else { continue }
            candidates.append(
                OrphanedPartialCandidate(
                    url: fileURL,
                    size: Int64(values?.fileSize ?? 0)
                )
            )
        }
        return candidates
    }

    private func removeOrphanedPartialCandidates(_ candidates: [OrphanedPartialCandidate]) {
        let activePartialPaths = Set(
            downloads
                .filter { $0.isHLS && $0.status != .completed }
                .flatMap { hlsPartialFileCandidates(for: $0).map(canonicalAbsolutePath) }
        )

        var removedCount = 0
        var freedBytes: Int64 = 0
        for candidate in candidates where !activePartialPaths.contains(canonicalAbsolutePath(candidate.url)) {
            guard fileManager.fileExists(atPath: candidate.url.path) else { continue }
            do {
                try fileManager.removeItem(at: candidate.url)
            } catch {
                continue
            }
            freedBytes += candidate.size
            removeEmptyDownloadDirectories(startingAt: candidate.url.deletingLastPathComponent())
            removedCount += 1
        }

        if removedCount > 0 {
            Logger.shared.log(
                "Cleaned \(removedCount) orphaned file(s), freed \(DownloadByteCountFormatter.string(fromByteCount: freedBytes))",
                type: "Download"
            )
        }
    }

    static func persistedDownloadItem(_ item: DownloadItem) -> DownloadItem {
        var persisted = item
        let containedSkyStreamMetadata = item.lastContentReference?.kind == .skyStream
        let protectedProviderKind = item.effectiveProtectedProviderKind
        let containedProtectedProviderMetadata = protectedProviderKind != nil
        let recovery = validatedRecoveryMetadata(
            legacySourceId: item.sourceId,
            legacyServiceHref: item.serviceContentHref,
            sourceId: item.lastSourceId,
            contentReference: item.lastContentReference
        )
        persisted.lastSourceId = recovery.sourceId
        persisted.lastContentReference = recovery.reference

        if let protectedProviderKind {
            persisted.protectedProviderKind = protectedProviderKind
            persisted.protectedOwnerProfileID = item.effectiveProtectedOwnerProfileID
        }
        if containedProtectedProviderMetadata,
           persisted.protectedTransportKind == nil,
           !item.streamURL.isEmpty {
            persisted.protectedTransportKind = ProtectedDownloadPersistencePolicy.transportKind(
                for: item.streamURL
            )
        }
        if protectedProviderKind == .nuvio {
            persisted.nuvioOwnerProfileID = persisted.protectedOwnerProfileID
            persisted.nuvioTransportKind = persisted.protectedTransportKind
        }

        let persistedTransport = ProtectedDownloadPersistencePolicy.sanitizedForPersistence(
            claimsProtectedProvider: containedProtectedProviderMetadata,
            transport: ProtectedPersistableTransport(
                streamURL: persisted.streamURL,
                headers: persisted.headers,
                subtitleURL: persisted.subtitleURL,
                subtitleHeaders: persisted.subtitleHeaders,
                hlsVariantURL: persisted.hlsVariantURL
            )
        )
        persisted.streamURL = persistedTransport.streamURL
        persisted.headers = persistedTransport.headers
        persisted.subtitleURL = persistedTransport.subtitleURL
        persisted.subtitleHeaders = persistedTransport.subtitleHeaders
        persisted.hlsVariantURL = persistedTransport.hlsVariantURL
        if containedProtectedProviderMetadata {
            persisted.serviceBaseURL = ""
            persisted.sourceId = nil
            persisted.serviceContentHref = nil
            persisted.error = persisted.status == .failed
                ? "The provider download must be retried."
                : nil
            persisted.hlsResumeSegmentIndex = nil
            persisted.hlsResumeByteCount = nil
            persisted.hlsTotalSegments = nil
            if persisted.status != .completed {
                persisted.progress = 0
                persisted.downloadedBytes = 0
                persisted.totalBytes = 0
            }
        }

        if !containedProtectedProviderMetadata,
           containedSkyStreamMetadata || item.providerTransportKind != nil {

            persisted.streamURL = ""
            persisted.headers = [:]
            persisted.subtitleURL = nil
            persisted.subtitleHeaders = nil
            persisted.hlsVariantURL = nil
        }
        return persisted
    }

    private func saveDownloads() {

        let rawSnapshot = self.downloads.map(Self.persistedDownloadItem)
        guard rawSnapshot.count <= DownloadMetadataPersistencePolicy.Bounds.items else {
            Logger.shared.log("Download metadata item count exceeded its storage bound", type: "Download")
            return
        }
        let snapshot = DownloadMetadataPersistencePolicy.normalizedLoadedItems(rawSnapshot).items
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            do {
                let data = try JSONEncoder().encode(snapshot)
                guard data.count <= DownloadMetadataPersistencePolicy.Bounds.fileBytes else {
                    Logger.shared.log("Download metadata snapshot exceeded its storage bound", type: "Download")
                    return
                }
                try data.write(to: self.persistenceURL, options: .atomic)
            } catch {
                Logger.shared.log("Failed to save download metadata", type: "Download")
            }
        }
    }

    /// Used only by credential-scrubbing migrations that must reach disk
    /// before any legacy background task can be inspected or resumed.
    private func saveDownloadsSynchronously() {
        let rawSnapshot = downloads.map(Self.persistedDownloadItem)
        guard rawSnapshot.count <= DownloadMetadataPersistencePolicy.Bounds.items else {
            Logger.shared.log("Download metadata item count exceeded its storage bound", type: "Download")
            return
        }
        let snapshot = DownloadMetadataPersistencePolicy.normalizedLoadedItems(rawSnapshot).items
        accessQueue.sync(flags: .barrier) {
            do {
                let data = try JSONEncoder().encode(snapshot)
                guard data.count <= DownloadMetadataPersistencePolicy.Bounds.fileBytes else {
                    Logger.shared.log(
                        "Download metadata snapshot exceeded its storage bound",
                        type: "Download"
                    )
                    return
                }
                try data.write(to: persistenceURL, options: .atomic)
            } catch {
                Logger.shared.log("Failed to save download metadata", type: "Download")
            }
        }
    }

    private func loadDownloads() {
        guard fileManager.fileExists(atPath: persistenceURL.path) else { return }
        do {
            let attributes = try fileManager.attributesOfItem(atPath: persistenceURL.path)
            guard let fileType = attributes[.type] as? FileAttributeType,
                  let fileSize = attributes[.size] as? NSNumber,
                  DownloadMetadataPersistencePolicy.fileMetadataIsWithinLimit(
                      size: fileSize.uint64Value,
                      isRegularFile: fileType == .typeRegular
                  ) else {
                Logger.shared.log("Download metadata was oversized or not a regular file", type: "Download")
                return
            }
            let handle = try FileHandle(forReadingFrom: persistenceURL)
            defer { try? handle.close() }
            guard let data = try handle.read(
                upToCount: DownloadMetadataPersistencePolicy.Bounds.fileBytes + 1
            ),
                  DownloadMetadataPersistencePolicy.metadataJSONPassesPreflight(data) else {
                Logger.shared.log("Download metadata failed its bounded preflight", type: "Download")
                return
            }
            let bounded = try DownloadMetadataPersistencePolicy.decodeAndNormalizeLoadedItems(
                from: data
            )
            var migrated = bounded.items
            var migratedProtectedMetadata = bounded.wasChanged
#if os(iOS) && !targetEnvironment(macCatalyst)
            for index in migrated.indices where migrated[index].claimsProtectedProviderTransport {
                let providerKind = migrated[index].effectiveProtectedProviderKind
                if migrated[index].protectedProviderKind == nil {
                    migrated[index].protectedProviderKind = providerKind
                    migratedProtectedMetadata = true
                }
                if migrated[index].protectedOwnerProfileID == nil {
                    migrated[index].protectedOwnerProfileID = migrated[index].nuvioOwnerProfileID
                        ?? ProfileManager.shared.activeProfileID
                    migratedProtectedMetadata = true
                }
                if migrated[index].protectedTransportKind == nil,
                   !migrated[index].streamURL.isEmpty {
                    migrated[index].protectedTransportKind = ProtectedDownloadPersistencePolicy.transportKind(
                        for: migrated[index].streamURL
                    )
                    migratedProtectedMetadata = true
                }
                if providerKind == .nuvio {
                    migrated[index].nuvioOwnerProfileID = migrated[index].protectedOwnerProfileID
                    migrated[index].nuvioTransportKind = migrated[index].protectedTransportKind
                }
                if migrated[index].status == .downloading {
                    migrated[index].status = .queued
                    migrated[index].error = "Refreshing protected download access"
                    migratedProtectedMetadata = true
                }
            }
#endif
            let normalized = migrated.map(Self.persistedDownloadItem)

            self.downloads = normalized
            if migratedProtectedMetadata || bounded.items.contains(where: { item in
                (item.lastContentReference?.kind == .skyStream
                    || item.providerTransportKind != nil
                    || item.claimsProtectedProviderTransport)
                    && (!item.streamURL.isEmpty
                        || !item.headers.isEmpty
                        || item.subtitleURL != nil
                        || item.subtitleHeaders != nil
                        || item.hlsVariantURL != nil
                        || (item.claimsProtectedProviderTransport
                            && (item.hlsResumeSegmentIndex != nil
                            || item.hlsResumeByteCount != nil
                            || item.hlsTotalSegments != nil)))
            }) {

                saveDownloads()
            }
        } catch {
            Logger.shared.log("Failed to load download metadata", type: "Download")
        }
    }

    private func claimDirectDownloadTaskIfCurrent(
        _ task: URLSessionDownloadTask,
        downloadID: String
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard task.taskDescription == downloadID,
              !invalidatedDirectTaskIdentifiers.contains(task.taskIdentifier) else {
            return false
        }

        guard let item = downloads.first(where: { $0.id == downloadID }) else {
            return false
        }
#if os(iOS) && !targetEnvironment(macCatalyst)
        let claimsProtectedProvider = item.claimsProtectedProviderTransport
        let registeredProtectedTaskIdentifier = protectedProviderAttempts[downloadID]?
            .mainTaskIdentifier
        guard ProtectedDownloadPersistencePolicy.mayClaimDirectTaskCallback(
            claimsProtectedProvider: claimsProtectedProvider,
            registeredProtectedTaskIdentifier: registeredProtectedTaskIdentifier,
            callbackTaskIdentifier: task.taskIdentifier
        ) else {
            invalidatedDirectTaskIdentifiers.insert(task.taskIdentifier)
            task.cancel()
            return false
        }
#endif

        if let active = activeTasks[downloadID] {
            return active === task || active.taskIdentifier == task.taskIdentifier
        }

        guard !item.isHLS,
              item.status == .downloading || item.status == .queued,
              item.retryNotBefore.map({ $0 <= Date() }) ?? true,
              !cloudflareRecoveringDownloadIDs.contains(downloadID) else {
            return false
        }
#if os(iOS) && !targetEnvironment(macCatalyst)
        guard !skyStreamRestoringDownloadIDs.contains(downloadID) else { return false }
#endif
        activeTasks[downloadID] = task
        return true
    }

}

private struct AutoModeDownloadValidationFailure: Error {
    let message: String
    let isRetryable: Bool

    var cloudflareChallengeURL: URL? = nil
}

private struct DownloadStreamProbeResult {
    let response: HTTPURLResponse
    let data: Data
    let reachedByteLimit: Bool
}

private final class DownloadStreamProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let byteLimit: Int
    private let redirectHeaders: [String: String]
    private let stateLock = NSLock()

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<DownloadStreamProbeResult, Error>?
    private var response: HTTPURLResponse?
    private var receivedData = Data()
    private var didFinish = false

    init(byteLimit: Int, redirectHeaders: [String: String]) {
        self.byteLimit = max(byteLimit, 1)
        self.redirectHeaders = redirectHeaders
        super.init()
    }

    func run(_ request: URLRequest) async throws -> DownloadStreamProbeResult {
        try Task.checkCancellation()

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.begin(request, continuation: continuation)
            }
        }, onCancel: {
            self.complete(.failure(CancellationError()))
        })
    }

    private func begin(
        _ request: URLRequest,
        continuation: CheckedContinuation<DownloadStreamProbeResult, Error>
    ) {
        stateLock.lock()
        if didFinish {
            stateLock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil

        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .userInitiated

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        let task = session.dataTask(with: request)
        self.session = session
        self.task = task
        self.continuation = continuation
        receivedData.reserveCapacity(byteLimit)
        stateLock.unlock()

        task.resume()
    }

    private func complete(_ result: Result<DownloadStreamProbeResult, Error>) {
        let continuation: CheckedContinuation<DownloadStreamProbeResult, Error>?
        let session: URLSession?

        stateLock.lock()
        guard !didFinish else {
            stateLock.unlock()
            return
        }
        didFinish = true
        continuation = self.continuation
        session = self.session
        self.continuation = nil
        self.task = nil
        self.session = nil
        stateLock.unlock()

        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            complete(.failure(URLError(.badServerResponse)))
            return
        }

        stateLock.lock()
        self.response = httpResponse
        stateLock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var completedResult: DownloadStreamProbeResult?

        stateLock.lock()
        guard !didFinish else {
            stateLock.unlock()
            return
        }

        let remaining = max(byteLimit - receivedData.count, 0)
        if remaining > 0 {
            receivedData.append(data.prefix(remaining))
        }
        if receivedData.count >= byteLimit, let response {
            completedResult = DownloadStreamProbeResult(
                response: response,
                data: receivedData,
                reachedByteLimit: true
            )
        }
        stateLock.unlock()

        if let completedResult {
            complete(.success(completedResult))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            complete(.failure(error))
            return
        }

        stateLock.lock()
        let response = self.response
        let data = receivedData
        stateLock.unlock()

        guard let response else {
            complete(.failure(URLError(.badServerResponse)))
            return
        }
        complete(.success(DownloadStreamProbeResult(
            response: response,
            data: data,
            reachedByteLimit: false
        )))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let destination = request.url else {
            completionHandler(nil)
            return
        }
        var redirectedRequest = request
        for (key, value) in redirectHeaders {
            let lowercasedKey = key.lowercased()
            if lowercasedKey == "cookie" || lowercasedKey == "user-agent" {
                redirectedRequest.setValue(value, forHTTPHeaderField: key)
            } else if redirectedRequest.value(forHTTPHeaderField: key) == nil {
                redirectedRequest.setValue(value, forHTTPHeaderField: key)
            }
        }

        guard let scheme = destination.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              destination.host?.isEmpty == false else {
            completionHandler(nil)
            return
        }
        completionHandler(redirectedRequest)
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let downloadId = downloadTask.taskDescription else { return }
        let finishCurrentAttempt = { [self] in
            guard self.claimDirectDownloadTaskIfCurrent(downloadTask, downloadID: downloadId) else {
                return
            }
#if os(iOS) && !targetEnvironment(macCatalyst)
            let protectedNuvioAttemptID: UUID?
            let authoritativeNuvioURL: URL?
            if let attempt = self.protectedProviderAttempts[downloadId],
               attempt.mainTaskIdentifier == downloadTask.taskIdentifier {
                protectedNuvioAttemptID = attempt.attemptID
                authoritativeNuvioURL = URL(string: attempt.authorityURL)
            } else {
                protectedNuvioAttemptID = nil
                authoritativeNuvioURL = nil
            }
#else
            let authoritativeNuvioURL: URL? = nil
#endif

            if let httpResponse = downloadTask.response as? HTTPURLResponse {
            let body = self.downloadBodyPreview(from: location)
            let responseHeaders = CloudflareBypassManager.headersDictionary(from: httpResponse)
            if CloudflareBypassManager.isChallengeResponse(
                status: httpResponse.statusCode,
                body: body,
                headers: responseHeaders
            ) {
                let challengeURL = authoritativeNuvioURL
                    ?? httpResponse.url
                    ?? downloadTask.currentRequest?.url
                    ?? downloadTask.originalRequest?.url
                if let challengeURL {
                    let rejectedCookieHeader = downloadTask.currentRequest?.value(forHTTPHeaderField: "Cookie")
                        ?? downloadTask.originalRequest?.value(forHTTPHeaderField: "Cookie")
                    self.recoverDownloadAfterConfirmedChallenge(
                        id: downloadId,
                        challengedURL: challengeURL,
                        rejectedCookieHeader: rejectedCookieHeader
                    )
                    return
                }
            }
            if httpResponse.statusCode == 429 {
                self.scheduleRateLimitedDownloadRetry(
                    id: downloadId,
                    retryAfterSeconds: httpResponse.value(forHTTPHeaderField: "Retry-After")
                        .flatMap(TimeInterval.init)
                )
                return
            }
            if [401, 403, 410, 503].contains(httpResponse.statusCode),
               let item = self.downloads.first(where: { $0.id == downloadId }),
               self.hasRefreshableProviderReference(item) {
                self.recoverDownloadAfterMediaRejection(
                    id: downloadId,
                    statusCode: httpResponse.statusCode,
                    challengedURL: authoritativeNuvioURL ?? httpResponse.url,
                    rejectedCookieHeader: nil,
                    isInteractiveChallenge: false
                )
                return
            }
            if (300...399).contains(httpResponse.statusCode),
               let item = self.downloads.first(where: { $0.id == downloadId }),
               item.lastContentReference?.kind == .skyStream {
                self.recoverDownloadAfterMediaRejection(
                    id: downloadId,
                    statusCode: httpResponse.statusCode,
                    challengedURL: httpResponse.url,
                    rejectedCookieHeader: nil,
                    isInteractiveChallenge: false
                )
                return
            }
            if let message = self.challengeFailureMessage(for: httpResponse, body: body) {
                self.markFailed(id: downloadId, error: message)
                return
            }
            }

            if let expectedLength = self.downloads.first(where: { $0.id == downloadId })?
            .validatedExpectedContentLength,
           expectedLength > 0 {
            let actualLength = (try? self.fileManager.attributesOfItem(atPath: location.path)[.size])
                .flatMap { $0 as? NSNumber }?.int64Value ?? -1
            guard actualLength == expectedLength else {
                self.markFailed(
                    id: downloadId,
                    error: "The validated direct download size changed before completion."
                )
                return
            }
        }

        let ext: String
        let urlExt = (authoritativeNuvioURL?.pathExtension
            ?? downloadTask.currentRequest?.url?.pathExtension
            ?? downloadTask.originalRequest?.url?.pathExtension
            ?? "").lowercased()
        if let mimeType = downloadTask.response?.mimeType?.lowercased() {
            switch mimeType {

            case "video/mp4":                                       ext = "mp4"
            case "video/x-matroska":                                ext = "mkv"
            case "video/webm":                                      ext = "webm"
            case "video/quicktime":                                  ext = "mov"
            case "video/x-msvideo":                                  ext = "avi"
            case "video/x-ms-wmv":                                   ext = "wmv"
            case "video/x-flv", "video/flv":                         ext = "flv"
            case "video/mp2t", "video/m2ts", "video/vnd.dlna.mpeg-tts": ext = "ts"
            case "video/3gpp":                                       ext = "3gp"
            case "video/ogg":                                        ext = "ogv"
            case "video/mpeg":                                       ext = "mpg"

            case "application/x-mpegurl", "application/vnd.apple.mpegurl": ext = "m3u8"

            case "application/octet-stream":
                ext = Self.knownVideoExtensions.contains(urlExt) ? urlExt : (urlExt.isEmpty ? "mp4" : urlExt)
            default:

                ext = Self.knownVideoExtensions.contains(urlExt) ? urlExt : "mp4"
            }
        } else {
            ext = Self.knownVideoExtensions.contains(urlExt) ? urlExt : (urlExt.isEmpty ? "mp4" : urlExt)
        }

            let fileName = self.reserveFinalVideoFileName(downloadID: downloadId, fileExtension: ext)
            let destURL = self.downloadFileURL(relativePath: fileName)
            self.ensureParentDirectoryExists(for: destURL)

            if self.isRegularFile(at: destURL) {
                let currentOwnsDestination = self.downloadOwnsTrackedPath(
                downloadID: downloadId,
                relativePath: fileName,
                subtitle: false
            )
                guard currentOwnsDestination else {
                    self.markFailed(id: downloadId, error: "The reserved destination became occupied before the download completed.")
                    return
                }
                try? self.fileManager.removeItem(at: destURL)
            }

            do {
                try self.fileManager.moveItem(at: location, to: destURL)

                if let index = self.downloads.firstIndex(where: { $0.id == downloadId }) {
                    self.downloads[index].status = .completed
                    self.downloads[index].progress = 1.0
                    self.downloads[index].localFileName = fileName
                    self.downloads[index].dateCompleted = Date()

                    if let attrs = try? self.fileManager.attributesOfItem(atPath: destURL.path),
                       let size = attrs[.size] as? Int64 {
                        self.downloads[index].totalBytes = size
                        self.downloads[index].downloadedBytes = size
                    }

                    self.downloads[index] = Self.persistedDownloadItem(self.downloads[index])
                    self.saveDownloads()
                    if let task = self.activeTasks.removeValue(forKey: downloadId) {
                        self.invalidatedDirectTaskIdentifiers.insert(task.taskIdentifier)
                    }
#if os(iOS) && !targetEnvironment(macCatalyst)
                    if let protectedNuvioAttemptID {
                        self.finishNuvioMainTransport(
                            id: downloadId,
                            attemptID: protectedNuvioAttemptID
                        )
                    }
#endif
                    self.processQueue()
                }

                Logger.shared.log("Download completed: \(downloadId) -> \(fileName)", type: "Download")
            } catch {
                self.markFailed(id: downloadId, error: "Failed to save file: \(error.localizedDescription)")
            }
        }

        if Thread.isMainThread {
            finishCurrentAttempt()
        } else {
            DispatchQueue.main.sync(execute: finishCurrentAttempt)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let downloadId = downloadTask.taskDescription else { return }
        let responseWasSuccessful = (downloadTask.response as? HTTPURLResponse)
            .map { (200...299).contains($0.statusCode) } ?? false
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0

        DispatchQueue.main.async {
            guard self.claimDirectDownloadTaskIfCurrent(downloadTask, downloadID: downloadId),
                  let index = self.downloads.firstIndex(where: { $0.id == downloadId }) else {
                return
            }
            if responseWasSuccessful,
               let expectedLength = self.downloads[index].validatedExpectedContentLength,
               expectedLength > 0,
               (totalBytesWritten > expectedLength
                    || (totalBytesExpectedToWrite > 0 && totalBytesExpectedToWrite > expectedLength)) {
                self.invalidatedDirectTaskIdentifiers.insert(downloadTask.taskIdentifier)
                self.activeTasks.removeValue(forKey: downloadId)
                downloadTask.cancel()
                self.markFailed(
                    id: downloadId,
                    error: "The validated direct download exceeded its verified size."
                )
                return
            }

            let now = Date()
            if let lastUpdate = self.lastProgressUpdate[downloadId],
               now.timeIntervalSince(lastUpdate) < 0.5 {
                return
            }
            self.lastProgressUpdate[downloadId] = now
            self.downloads[index].progress = progress
            self.downloads[index].downloadedBytes = totalBytesWritten
            self.downloads[index].totalBytes = totalBytesExpectedToWrite

            if responseWasSuccessful && totalBytesWritten > 0 {
                self.downloads[index].rateLimitRetryCount = nil
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let downloadId = task.taskDescription,
              let downloadTask = task as? URLSessionDownloadTask else { return }

        DispatchQueue.main.async {

            if self.invalidatedDirectTaskIdentifiers.remove(task.taskIdentifier) != nil {
                return
            }
            guard self.claimDirectDownloadTaskIfCurrent(downloadTask, downloadID: downloadId) else {
                return
            }
            if let error = error as NSError? {
                if error.code == NSURLErrorCancelled {
                    self.activeTasks.removeValue(forKey: downloadId)
#if os(iOS) && !targetEnvironment(macCatalyst)
                    if let item = self.downloads.first(where: { $0.id == downloadId }),
                       item.claimsProtectedProviderTransport {
                        self.clearProtectedProviderDownloadRuntimeState(
                            id: downloadId,
                            scrubTransport: true
                        )
                    }
#endif
                    if let index = self.downloads.firstIndex(where: { $0.id == downloadId }),
                       self.downloads[index].status == .downloading {
                        self.downloads[index].status = .queued
                        self.downloads[index].error = "Download was interrupted; retrying"
                        self.saveDownloads()
                        self.processQueue()
                    }
                    return
                }
                self.markFailed(
                    id: downloadId,
                    error: self.boundedDownloadFailureMessage(error)
                )
                self.invalidatedDirectTaskIdentifiers.remove(task.taskIdentifier)
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let downloadId = task.taskDescription,
              let downloadTask = task as? URLSessionDownloadTask else {
            completionHandler(nil)
            return
        }

        DispatchQueue.main.async {
            guard self.claimDirectDownloadTaskIfCurrent(downloadTask, downloadID: downloadId),
                  let item = self.downloads.first(where: { $0.id == downloadId }) else {

                completionHandler(nil)
                return
            }

            if item.lastContentReference?.kind == .skyStream {
                completionHandler(nil)
                return
            }

            guard let destination = request.url else {
                completionHandler(nil)
                return
            }

            var updatedRequest = request
            let refreshedHeaders = self.effectiveHeaders(item.headers, for: destination)
            for (key, value) in refreshedHeaders {
                let lowerKey = key.lowercased()
                if lowerKey == "cookie" || lowerKey == "user-agent" {
                    updatedRequest.setValue(value, forHTTPHeaderField: key)
                } else if updatedRequest.value(forHTTPHeaderField: key) == nil {
                    updatedRequest.setValue(value, forHTTPHeaderField: key)
                }
            }

            guard let scheme = destination.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  destination.host?.isEmpty == false else {
                completionHandler(nil)
                return
            }
            completionHandler(updatedRequest)
        }
    }
}
